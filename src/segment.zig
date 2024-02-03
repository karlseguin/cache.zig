const std = @import("std");
const cache = @import("cache.zig");

const Allocator = std.mem.Allocator;

pub fn Segment(comptime T: type) type {
	const Entry = cache.Entry(T);
	const List = @import("list.zig").List(*Entry);
	const IS_SIZED = comptime std.meta.hasFn(T, "size");

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
		lookup: std.StringHashMap(*Entry),

		const Self = @This();

		pub fn init(allocator: Allocator, config: anytype) Self{
			return .{
				.size = 0,
				.mutex = .{},
				.max_size = config.max_size,
				.target_size = config.target_size,
				.gets_per_promote = config.gets_per_promote,
				.list = List.init(),
				.lookup = std.StringHashMap(*Entry).init(allocator),
			};
		}

		pub fn deinit(self: *Self) void {
			var list = &self.list;
			var it = self.lookup.iterator();
			while (it.next()) |kv| {
				const entry = kv.value_ptr.*;
				list.remove(entry._node);
				entry.release();
			}
			self.lookup.deinit();
		}

		pub fn contains(self: *Self, key: []const u8) bool {
			self.mutex.lockShared();
			defer self.mutex.unlockShared();
			return self.lookup.contains(key);
		}

		pub fn get(self: *Self, key: []const u8) ?*Entry {
			const entry = self.getEntry(key) orelse return null;
			if (entry.expired()) {
				// release getEntry's borrow
				entry.release();

				self.mutex.lock();
				_ = self.lookup.remove(key);
				self.size -= entry._size;
				self.mutex.unlock();
				self.list.remove(entry._node);
				// and now release the cache's implicit borrow
				entry.release();
				return null;
			}
			return entry;
		}

		pub fn getEntry(self: *Self, key: []const u8) ?*Entry {
			self.mutex.lockShared();
			const optional_entry = self.lookup.get(key);
			const entry = optional_entry orelse {
				self.mutex.unlockShared();
				return null;
			};
			// Even though entry.borrow() increments entry._gc atomically, it has to
			// be called under the mutex. If we move the call to entry.borrow() after
			// releating the mutex, a del or put could slip in, see that _gc == 0
			// and call removedFromCache.
			// (And, we want _gc incremented atomically, because this is a shared
			// read lock and multiple threads could be accessing the entry concurrently)
			entry.borrow();
			self.mutex.unlockShared();

			if (!entry.expired() and @rem(entry.hit(), self.gets_per_promote) == 0) {
				self.list.moveToFront(entry._node);
			}

			return entry;
		}

		pub fn put(self: *Self, allocator: Allocator, key: []const u8, value: T, config: cache.PutConfig) !*Entry {
			const entry_size = if (IS_SIZED) T.size(value) else config.size;
			const expires = @as(u32, @intCast(std.time.timestamp())) + config.ttl;

			const owned_key = try allocator.dupe(u8, key);
			const entry = try allocator.create(Entry);
			const node = try allocator.create(List.Node);
			node.* = List.Node{.value = entry};
			entry.* = Entry.init(allocator, owned_key, value, entry_size, expires);
			entry._node = node;

			var list = &self.list;
			var lookup = &self.lookup;
			const mutex = &self.mutex;
			var existing_entry: ?*Entry = null;

			mutex.lock();
			var segment_size = self.size;
			const gop = try lookup.getOrPut(key);
			if (gop.found_existing) {
				existing_entry = gop.value_ptr.*;
				gop.value_ptr.* = entry;
				gop.key_ptr.* = owned_key; // aka, entry.key
				segment_size = segment_size - existing_entry.?._size + entry_size;
			} else {
				gop.key_ptr.* = owned_key;
				gop.value_ptr.* = entry;
				segment_size = segment_size + entry_size;
			}
			self.size = segment_size;
			mutex.unlock();

			if (existing_entry) |existing| {
				list.remove(existing._node);
				existing.release();
			}
			list.insert(entry._node);

			if (segment_size <= self.max_size) {
				// we're still under our max_size
				return entry;
			}

			// we need to free some space, we're going to free until our segment size
			// is under our target_size
			const target_size = self.target_size;

			mutex.lock();
			// recheck
			segment_size = self.size;
			while (segment_size > target_size) {
				const removed_node = list.removeTail() orelse break;
				const removed_entry = removed_node.value;

				const existed_in_lookup = lookup.remove(removed_entry.key);
				std.debug.assert(existed_in_lookup == true);

				segment_size -= removed_entry._size;
				removed_entry.release();
			}
			// we're still under lock
			self.size = segment_size;
			mutex.unlock();

			return entry;
		}

		// TOOD: singleflight
		pub fn fetch(self: *Self, comptime S: type, allocator: Allocator, key: []const u8, loader: *const fn(state: S, key: []const u8) anyerror!?T, state: S, config: cache.PutConfig) !?*Entry {
			if (self.get(key)) |v| {
				return v;
			}
			if (try loader(state, key)) |value| {
				const entry = try self.put(allocator, key, value, config);
				entry.borrow();
				return entry;
			}
			return null;
		}

		pub fn del(self: *Self, key: []const u8) bool {
			self.mutex.lock();
			const existing = self.lookup.fetchRemove(key);
			const map_entry = existing orelse {
				self.mutex.unlock();
				return false;
			};
			const entry = map_entry.value;
			self.size -= entry._size;
			self.mutex.unlock();

			self.list.remove(entry._node);
			entry.release();
			return true;
		}

		// This is an expensive call (even more so since we know this is being called
		// on each segment). We optimize what we can, by first collecting the matching
		// entries under a shared lock. This is nice since the expensive prefix match
		// won'ts block concurrent gets.
		pub fn delPrefix(self: *Self, allocator: Allocator, prefix: []const u8) !usize {
			var matching = std.ArrayList(*Entry).init(allocator);
			defer matching.deinit();

			self.mutex.lockShared();
			var it = self.lookup.iterator();
			while (it.next()) |map_entry| {
				if (std.mem.startsWith(u8, map_entry.key_ptr.*, prefix)) {
					try matching.append(map_entry.value_ptr.*);
				}
			}
			self.mutex.unlockShared();

			const entries = matching.items;
			if (entries.len == 0) {
				return 0;
			}

			var lookup = &self.lookup;
			self.mutex.lock();
			for (entries) |entry| {
				self.size -= entry._size;
				_ = lookup.remove(entry.key);
			}
			self.mutex.unlock();

			// list and entry have their own thread safety
			var list = &self.list;
			for (entries) |entry| {
				list.remove(entry._node);
				entry.release();
			}

			return entries.len;
		}
	};
}
