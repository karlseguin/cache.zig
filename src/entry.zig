const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn Entry(comptime T: type) type {
	return struct {
		key: []const u8,
		value: T,
		size: u32,
		expires: u32,
		prev: ?*Entry(T),
		next: ?*Entry(T),
		hits: u8,

		const Self = @This();

		pub fn init(key: []const u8, value: T) Self {
			return .{
				.hits = 0,
				.prev = null,
				.next = null,
				.key = key,
				.value = value,
				.size = 1,
				.expires = 0,
			};
		}

		pub fn deinit(self: *Self, allocator: Allocator) void {
			if (comptime std.meta.trait.hasFn("deinit")(T)) {
				return self.value.deinit(allocator);
			}
		}

		pub fn expired(self: *Self) bool {
			return self.ttl() <= 0;
		}

		pub fn ttl(self: *Self) i64 {
			return self.expires - std.time.timestamp();
		}

		pub fn hit(self: *Self) u8 {
			// wrapping back to 0 is fine.
			return @atomicRmw(u8, &self.hits, .Add, 1, .SeqCst) + 1;
		}
	};
}
