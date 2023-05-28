const std = @import("std");

const Allocator = std.mem.Allocator;

pub fn List(comptime T: type) type {
	const Entry = @import("entry.zig").Entry(T);

	return struct {
		head: ?*Entry,
		tail: ?*Entry,
		mutex: std.Thread.Mutex,

		const Self = @This();

		pub fn init() Self {
			return .{
				.head = null,
				.tail = null,
				.mutex = .{},
			};
		}

		pub fn insert(self: *Self, entry: *Entry) void {
			self.mutex.lock();
			defer self.mutex.unlock();
			self.moveToFrontLocked(entry);
		}

		pub fn moveToFront(self: *Self, entry: *Entry) void {
			self.mutex.lock();
			defer self.mutex.unlock();
			self.removeLocked(entry);
			self.moveToFrontLocked(entry);
		}

		pub fn moveToTail(self: *Self, entry: *Entry) void {
			self.mutex.lock();
			defer self.mutex.unlock();
			self.removeLocked(entry);
			self.moveToTailLocked(entry);
		}

		pub fn remove(self: *Self, entry: *Entry) void {
			self.mutex.lock();
			self.removeLocked(entry);
			self.mutex.unlock();
			entry.next = null;
			entry.prev = null;
		}

		pub fn removeTail(self: *Self) ?*Entry {
			if (self.tail) |entry| {
				if (entry.prev) |prev| {
					self.tail = prev;
					prev.next = null;
				} else {
					self.tail = null;
					self.head = null;
				}
				return entry;
			} else {
				return null;
			}
		}

		fn moveToFrontLocked(self: *Self, entry: *Entry) void {
			if (self.head) |head| {
				head.prev = entry;
				entry.next = head;
				self.head = entry;
			} else {
				self.head = entry;
				self.tail = entry;
			}
			entry.prev = null;
		}

		fn moveToTailLocked(self: *Self, entry: *Entry) void {
			if (self.tail) |tail| {
				tail.next = entry;
				entry.prev = tail;
				self.tail = entry;
			} else {
				self.head = entry;
				self.tail = entry;
			}
			entry.next = null;
		}

		fn removeLocked(self: *Self, entry: *Entry) void {
			if (entry.prev) |prev| {
				prev.next = entry.next;
			} else {
				self.head = entry.next;
			}

			if (entry.next) |next| {
				next.prev = entry.prev;
			} else {
				self.tail = entry.prev;
			}
		}
	};
}

const t = @import("t.zig");

test "list: insert/remove" {
	var list = List(i32).init();
	try t.testList(list, &[_][]const u8{});

	var e1 = t.Entry.init("e1", 0);
	list.insert(&e1);
	try t.testList(list, &[_][]const u8{"e1"});
	list.remove(&e1);
	try t.testList(list, &[_][]const u8{});
	list.insert(&e1);

	var e2 = t.Entry.init("e2", 0);
	list.insert(&e2);
	try t.testList(list, &[_][]const u8{"e2", "e1"});
	list.remove(&e2);
	try t.testList(list, &[_][]const u8{"e1"});
	list.insert(&e2);

	var e3 = t.Entry.init("e3", 0);
	list.insert(&e3);
	try t.testList(list, &[_][]const u8{"e3", "e2", "e1"});
	list.remove(&e1);
	try t.testList(list, &[_][]const u8{"e3", "e2"});
	list.remove(&e2);
	try t.testList(list, &[_][]const u8{"e3"});
	list.remove(&e3);
	try t.testList(list, &[_][]const u8{});
}

test "list: moveToFront" {
	var list = List(i32).init();

	var e1 = t.Entry.init("e1", 0);
	list.insert(&e1);
	list.moveToFront(&e1);
	try t.testList(list, &[_][]const u8{"e1"});

	var e2 = t.Entry.init("e2", 0);
	list.insert(&e2);
	list.moveToFront(&e2);
	try t.testList(list, &[_][]const u8{"e2", "e1"});
	list.moveToFront(&e1);
	try t.testList(list, &[_][]const u8{"e1", "e2"});
	list.moveToFront(&e2);
	try t.testList(list, &[_][]const u8{"e2", "e1"});

	var e3 = t.Entry.init("e3", 0);
	list.insert(&e3);
	list.moveToFront(&e3);
	try t.testList(list, &[_][]const u8{"e3", "e2", "e1"});
	list.moveToFront(&e1);
	try t.testList(list, &[_][]const u8{"e1", "e3", "e2"});
	list.moveToFront(&e2);
	try t.testList(list, &[_][]const u8{"e2", "e1", "e3"});
}

test "list: moveToTail" {
	var list = List(i32).init();

	var e1 = t.Entry.init("e1", 0);
	list.insert(&e1);
	list.moveToTail(&e1);
	try t.testList(list, &[_][]const u8{"e1"});

	var e2 = t.Entry.init("e2", 0);
	list.insert(&e2);
	list.moveToTail(&e2);
	try t.testList(list, &[_][]const u8{"e1", "e2"});
	list.moveToTail(&e1);
	try t.testList(list, &[_][]const u8{"e2", "e1"});
	list.moveToTail(&e2);
	try t.testList(list, &[_][]const u8{"e1", "e2"});

	var e3 = t.Entry.init("e3", 0);
	list.insert(&e3);
	list.moveToTail(&e3);
	try t.testList(list, &[_][]const u8{"e1", "e2", "e3"});
	list.moveToTail(&e1);
	try t.testList(list, &[_][]const u8{"e2", "e3", "e1"});
	list.moveToTail(&e2);
	try t.testList(list, &[_][]const u8{"e3", "e1", "e2"});
}

test "list: removeTail" {
	var list = List(i32).init();

	var e1 = t.Entry.init("e1", 0);
	var e2 = t.Entry.init("e2", 0);
	var e3 = t.Entry.init("e3", 0);
	list.insert(&e1);
	try t.expectString("e1", list.removeTail().?.key);
	try t.testList(list, &[_][]const u8{});

	list.insert(&e1); list.insert(&e2); list.insert(&e3);
	try t.expectString("e1", list.removeTail().?.key);
	try t.testList(list, &[_][]const u8{"e3", "e2"});

	try t.expectString("e2", list.removeTail().?.key);
	try t.testList(list, &[_][]const u8{"e3"});

	try t.expectString("e3", list.removeTail().?.key);
	try t.testList(list, &[_][]const u8{});

	try t.expectEqual(@as(?*t.Entry, null), list.removeTail());
}
