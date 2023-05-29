const std = @import("std");
const cache = @import("cache.zig");

const Allocator = std.mem.Allocator;

pub fn Segment(comptime T: type) type {
	const Entry = cache.Entry(T);
	const List = @import("list.zig").List(T);
	const NOTIFY_REMOVAL = comptime std.meta.trait.hasFn("removedFromCache")(T);
	const NOTIFY_BATCH = if (NOTIFY_REMOVAL) [16]T else [0]T;

	return struct {
		// the current size.
		size: u32,

		// the maximum size we should allow this segment to grow to
		max_size: u32,

		// the size we should rougly trim to when we've reached max_size
		target_size: u32,

		// items only get promoted on every N gets.
		gets_per_promote: u8,

		// a double linked list with most recently used items at the head
		// has its own internal mutex for thread-safety.
		list: List,

		// mutex for lookup and size
		mutex: std.Thread.RwLock,

		// key => entry
		lookup: std.StringHashMap(Entry),

		const Self = @This();

		pub fn init(allocator: Allocator, config: anytype) Self{
			return .{
				.size = 0,
				.mutex = .{},
				.max_size = config.max_size,
				.target_size = config.target_size,
				.gets_per_promote = config.gets_per_promote,
				.list = List.init(),
				.lookup = std.StringHashMap(Entry).init(allocator),
			};
		}

		pub fn deinit(self: *Self, allocator: Allocator) void {
			var it = self.lookup.iterator();
			while (it.next()) |entry| {
				allocator.free(entry.key_ptr.*);
				notifyRemoval(allocator, entry.value_ptr.value);
			}
			self.lookup.deinit();
		}

		pub fn contains(self: *Self, key: []const u8) bool {
			self.mutex.lockShared();
			defer self.mutex.unlockShared();
			return self.lookup.contains(key);
		}

		pub fn get(self: *Self, allocator: Allocator, key: []const u8) ?*Entry {
			const entry = self.getEntry(key) orelse return null;
			if (entry.expired()) {
				_ = self.del(allocator, key);
				return null;
			}
			return entry;
		}

		pub fn getEntry(self: *Self, key: []const u8) ?*Entry {
			self.mutex.lockShared();
			const optional_entry = self.lookup.getPtr(key);
			self.mutex.unlockShared();

			const entry = optional_entry orelse return null;
			if (entry.expired()) {
				self.list.moveToTail(entry);
				return entry;
			}

			if (@rem(entry.hit(), self.gets_per_promote) == 0) {
				self.list.moveToFront(entry);
			}

			return entry;
		}

		pub fn put(self: *Self, allocator: Allocator, key: []const u8, value: T, config: cache.PutConfig) !*Entry {
			var list = &self.list;
			var lookup = &self.lookup;
			const mutex = &self.mutex;

			const entry_size = config.size;
			var size_to_add: i32 = @intCast(i32, entry_size);

			var existing_value: ?T = null;
			const expires = @intCast(u32, std.time.timestamp()) + config.ttl;

			mutex.lock();
			const gop = try lookup.getOrPut(key);
			if (gop.found_existing) {
				// An entry with this key already exists. We want to re-use the Entry(T)
				// as much as possible (because it's already in our List(T) and HashMap
				// at the right place

				const existing = gop.value_ptr;

				// We want to keep the Entry, but we'll need to call deinit on the value
				// (if it implements deinit). We don't want to do that under lock, so
				// just grap a copy of it here.
				existing_value = existing.value;

				// The amount of space that we're going to use up is going to be the
				// difference between the old and new. This could be negative
				// if the new is smaller than the old, 0 if they're the same size, or
				// positive if the new is larger than the old.
				size_to_add = size_to_add - @intCast(i32, existing.size);

				// Overwrite the existing entry's size, value and expires with the new ones
				// keep everything else (e.g. the next/prev linked list pointer, and the
				// key, the sames)
				existing.size = entry_size;
				existing.value = value;
				existing.expires = expires;

			} else {
				// This key is new, shame to do this under lock!
				const owned_key = try allocator.dupe(u8, key);
				gop.key_ptr.* = owned_key;
				var entry = Entry.init(owned_key, value);
				entry.expires = expires;
				entry.size = entry_size;
				gop.value_ptr.* = entry;
			}

			var size = @intCast(i32, self.size) + size_to_add;
			self.size = @intCast(u32, size);
			mutex.unlock();


			// we don't want to do either of these under our lock
			if (existing_value) |existing| {
				notifyRemoval(allocator, existing);
			} else {
				// list has its own lock
				list.insert(gop.value_ptr);
			}


			if (size <= self.max_size) {
				// we're still under our max_size
				return gop.value_ptr;
			}

			// we need to free some space, we're going to free until our segment size
			// is under our target_size
			const target_size = self.target_size;


			var values_removed: NOTIFY_BATCH = undefined;
			var removed_count: usize = 0;

			mutex.lock();
			// recheck
			var cache_size = self.size;
			while (cache_size > target_size) {
				const entry = list.removeTail() orelse break;
				const k = entry.key;
				cache_size -= entry.size;

				if (NOTIFY_REMOVAL) {
					values_removed[removed_count] = entry.value;
					removed_count += 1;
				}

				const existed_in_lookup = lookup.remove(k);
				std.debug.assert(existed_in_lookup == true);
				allocator.free(k);

				// I think this (unlocking and relocking) is safe. I really hate the idea
				// of removedFromCache being called under lock (we have no control over
				// what it does).
				if (NOTIFY_REMOVAL and removed_count == values_removed.len) {
					mutex.unlock();
					for (values_removed) |vr| {
						vr.removedFromCache(allocator);
					}
					removed_count = 0;
					mutex.lock();

					// This is why I think we're being safe. Under lock, we re-acquire
					// the cache size in case another thread has done some cleanup
					cache_size = self.size;
				}
			}
			// we're still under lock
			self.size = cache_size;
			mutex.unlock();

			if (NOTIFY_REMOVAL and removed_count > 0) {
				for (values_removed[0..removed_count]) |vr| {
					vr.removedFromCache(allocator);
				}
			}

			return gop.value_ptr;
		}

		// TOOD: singleflight
		pub fn fetch(self: *Self, comptime S: type, allocator: Allocator, key: []const u8, loader: *const fn(key: []const u8, state: S) anyerror!?T, state: S, config: cache.PutConfig) !?*Entry {
			if (self.get(allocator, key)) |v| {
				return v;
			}
			if (try loader(key, state)) |value| {
				return self.put(allocator, key, value, config);
			}
			return null;
		}

		pub fn del(self: *Self, allocator: Allocator, key: []const u8) bool {
			self.mutex.lock();
			var existing = self.lookup.fetchRemove(key);

			const map_entry = existing orelse {
				self.mutex.unlock();
				return false;
			};

			var entry = map_entry.value;
			self.size -= entry.size;
			self.mutex.unlock();

			allocator.free(map_entry.key);
			self.list.remove(&entry);

			notifyRemoval(allocator, entry.value);

			return true;
		}

		fn notifyRemoval(allocator: Allocator, value: T) void {
			if (NOTIFY_REMOVAL) {
				value.removedFromCache(allocator);
			}
		}

	};
}
