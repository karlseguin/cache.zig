const std = @import("std");
const cache = @import("cache.zig");
const List = @import("list.zig").List;

pub const expect = std.testing.expect;
pub const allocator = std.testing.allocator;

pub const expectEqual = std.testing.expectEqual;
pub const expectError = std.testing.expectError;
pub const expectString = std.testing.expectEqualStrings;

pub const Entry = cache.Entry(i32);

pub fn initCache() cache.Cache(i32) {
	return cache.Cache(i32).init(allocator, .{.segment_buckets = 2}) catch unreachable;
}

pub fn testList(list: List(i32), expected: []const []const u8) !void {
	var node = list.head;
	for (expected) |e| {
		try expectString(e, node.?.key);
		node = node.?.next;
	}
	try expectEqual(@as(?*Entry, null), node);

	node = list.tail;
	var i: usize = expected.len;
	while (i > 0) : (i -= 1) {
		try expectString(expected[i-1], node.?.key);
		node = node.?.prev;
	}
	try expectEqual(@as(?*Entry, null), node);
}
