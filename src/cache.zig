const std = @import("std");

pub const Entry = @import("entry.zig").Entry;
const Segment = @import("segment.zig").Segment;

const Allocator = std.mem.Allocator;

pub const Config = struct {
	max_size: u32 = 8000,
	segment_count: u16 = 8,
	gets_per_promote: u8 = 5,
	shrink_ratio: f32 = 0.2,
};

pub const PutConfig = struct {
	ttl: u32 = 300,
	size: u32 = 1,
};

pub fn Cache(comptime T: type) type {
	return struct {
		allocator: Allocator,
		segment_mask: u16,
		segments: []Segment(T),

		const Self = @This();

		pub fn init(allocator: Allocator, config: Config) !Self {
			const segment_count = config.segment_count;
			if (segment_count == 0) return error.SegmentBucketNotPower2;
			// has to be a power of 2
			if ((segment_count & (segment_count - 1)) != 0) return error.SegmentBucketNotPower2;

			const shrink_ratio = config.shrink_ratio;
			if (shrink_ratio == 0 or shrink_ratio > 1) return error.SpaceToFreeInvalid;

			const segment_max_size = config.max_size / segment_count;
			const segment_config = .{
				.max_size = segment_max_size,
				.target_size = segment_max_size - @floatToInt(u32, @intToFloat(f32, segment_max_size) * shrink_ratio),
				.gets_per_promote = config.gets_per_promote,
			};

			const segments = try allocator.alloc(Segment(T), segment_count);
			for (0..segment_count) |i| {
				segments[i] = Segment(T).init(allocator, segment_config);
			}

			return .{
				.allocator = allocator,
				.segments = segments,
				.segment_mask = segment_count - 1,
			};
		}

		pub fn deinit(self: *Self) void {
			const allocator = self.allocator;
			for (self.segments) |*segment| {
				segment.deinit(allocator);
			}
			allocator.free(self.segments);
		}

		pub fn contains(self: *const Self, key: []const u8) bool {
			return self.getSegment(key).contains(key);
		}

		pub fn get(self: *Self, key: []const u8) ?*Entry(T) {
			return self.getSegment(key).get(self.allocator, key);
		}

		pub fn getEntry(self: *const Self, key: []const u8) ?*Entry(T) {
			return self.getSegment(key).getEntry(key);
		}

		pub fn put(self: *Self, key: []const u8, value: T, config: PutConfig) !void {
			_ = try self.getSegment(key).put(self.allocator, key, value, config);
		}

		pub fn del(self: *Self, key: []const u8) bool {
			return self.getSegment(key).del(self.allocator, key);
		}

		pub fn fetch(self: *Self, comptime S: type, key: []const u8, loader: *const fn(key: []const u8, state: S) anyerror!?T, state: S, config: PutConfig) !?*Entry(T) {
			return self.getSegment(key).fetch(S, self.allocator, key, loader, state, config);
		}

		fn getSegment(self: *const Self, key: []const u8) *Segment(T) {
			const hash_code = std.hash.Wyhash.hash(0, key);
			return &self.segments[hash_code & self.segment_mask];
		}
	};
}

test {
	std.testing.refAllDecls(@This());
}

const t = @import("t.zig");
test "cache: invalid config" {
	try t.expectError(error.SegmentBucketNotPower2, Cache(u8).init(t.allocator, .{.segment_count = 0}));
	try t.expectError(error.SegmentBucketNotPower2, Cache(u8).init(t.allocator, .{.segment_count = 3}));
	try t.expectError(error.SegmentBucketNotPower2, Cache(u8).init(t.allocator, .{.segment_count = 10}));
	try t.expectError(error.SegmentBucketNotPower2, Cache(u8).init(t.allocator, .{.segment_count = 30}));
}

test "cache: get null" {
	var cache = t.initCache();
	defer cache.deinit();
	try t.expectEqual(@as(?*t.Entry, null), cache.get("nope"));
}

test "cache: get / set / del" {
	var cache = t.initCache();
	defer cache.deinit();
	try t.expectEqual(false, cache.contains("k1"));

	try cache.put("k1", 1, .{});
	const e1 = cache.get("k1").?;
	try t.expectEqual(false, e1.expired());
	try t.expectEqual(@as(i32, 1), e1.value);
	try t.expectEqual(true, cache.contains("k1"));

	try cache.put("k2", 2, .{});
	const e2 = cache.get("k2").?;
	try t.expectEqual(false, e2.expired());
	try t.expectEqual(@as(i32, 2), e2.value);
	try t.expectEqual(true, cache.contains("k2"));

	try cache.put("k1", 1, .{});
	var e1a = cache.get("k1").?;
	try t.expectEqual(false, e1a.expired());
	try t.expectEqual(@as(i32, 1), e1a.value);
	try t.expectEqual(true, cache.contains("k2"));

	try t.expectEqual(true, cache.del("k1"));
	try t.expectEqual(false, cache.contains("k1"));
	try t.expectEqual(true, cache.contains("k2"));

	// delete on non-key is no-op
	try t.expectEqual(false, cache.del("k1"));
	try t.expectEqual(false, cache.contains("k1"));
	try t.expectEqual(true, cache.contains("k2"));

	try t.expectEqual(true, cache.del("k2"));
	try t.expectEqual(false, cache.contains("k1"));
	try t.expectEqual(false, cache.contains("k2"));
}

test "cache: get expired" {
	var cache = t.initCache();
	defer cache.deinit();

	try cache.put("k1", 1, .{.ttl = 0});
	const e1a = cache.getEntry("k1").?;
	try t.expectEqual(true, e1a.expired());
	try t.expectEqual(@as(i32, 1), e1a.value);

	// getEntry on expired won't remove it, it's like a peek
	const e1b = cache.getEntry("k1").?;
	try t.expectEqual(true, e1b.expired());
	try t.expectEqual(@as(i32, 1), e1b.value);

	// contains on expired won't remove it either
	try t.expectEqual(true, cache.contains("k1"));
	try t.expectEqual(true, cache.contains("k1"));

	// but a get on an expired does remove it
	try t.expectEqual(@as(?*t.Entry, null), cache.get("k1"));
	try t.expectEqual(false, cache.contains("k1"));
}

test "cache: ttl" {
	var cache = t.initCache();
	defer cache.deinit();

	// default ttl
	try cache.put("k1", 1, .{});
	const ttl1 = cache.get("k1").?.ttl();
	try t.expectEqual(true, ttl1 >= 299 and ttl1 <= 300);

	// explicit ttl
	try cache.put("k2", 1, .{.ttl = 60});
	const ttl2 = cache.get("k2").?.ttl();
	try t.expectEqual(true, ttl2 >= 59 and ttl2 <= 60);
}

test "cache: get promotion" {
	var cache = try Cache(i32).init(t.allocator, .{.segment_count = 1, .gets_per_promote = 3});
	defer cache.deinit();

	try cache.put("k1", 1, .{});
	try cache.put("k2", 2, .{});
	try cache.put("k3", 3, .{});
	try testSingleSegmentCache(cache, &[_][]const u8{"k3", "k2", "k1"});

	// must get $gets_per_promote before it promotes, none of these reach that
	_ = cache.get("k1");
	_ = cache.get("k1");
	_ = cache.get("k2");
	_ = cache.get("k2");
	_ = cache.get("k3");
	try testSingleSegmentCache(cache, &[_][]const u8{"k3", "k2", "k1"});

	// should be promoted now
	_ = cache.get("k1");
	try testSingleSegmentCache(cache, &[_][]const u8{"k1", "k3", "k2"});

	// should be promoted now
	_ = cache.get("k2");
	try testSingleSegmentCache(cache, &[_][]const u8{"k2", "k1", "k3"});
}

test "cache: get promotion expired" {
	var cache = try Cache(i32).init(t.allocator, .{.segment_count = 1, .gets_per_promote = 3});
	defer cache.deinit();

	try cache.put("k1", 1, .{.ttl = 0});
	try cache.put("k2", 2, .{});
	try testSingleSegmentCache(cache, &[_][]const u8{"k2", "k1"});

	// expired items never get promoted
	_ = cache.getEntry("k1");
	_ = cache.getEntry("k1");
	_ = cache.getEntry("k1");
	_ = cache.getEntry("k1");
	try testSingleSegmentCache(cache, &[_][]const u8{"k2", "k1"});

	// but they do get demoted!
	try cache.put("k3", 3, .{.ttl = 0});
	try testSingleSegmentCache(cache, &[_][]const u8{"k3", "k2", "k1"});
	_ = cache.getEntry("k3");
	_ = cache.getEntry("k3");
	_ = cache.getEntry("k3");
	try testSingleSegmentCache(cache, &[_][]const u8{"k2", "k1", "k3"});
}

test "cache: fetch" {
	var cache = t.initCache();
	defer cache.deinit();

	var fetch_state = FetchState{.called = 0};
	try t.expectString("k1", (try cache.fetch(*FetchState, "k1", &doFetch, &fetch_state, .{})).?.key);
	try t.expectEqual(@as(i32, 1), fetch_state.called);

	// same key, fetch_state.called doesn't increment because doFetch isn't called!
	try t.expectString("k1", (try cache.fetch(*FetchState, "k1", &doFetch, &fetch_state, .{})).?.key);
	try t.expectEqual(@as(i32, 1), fetch_state.called);

	// different key
	try t.expectString("k2", (try cache.fetch(*FetchState, "k2", &doFetch, &fetch_state, .{})).?.key);
	try t.expectEqual(@as(i32, 2), fetch_state.called);

	// this key makes doFetch return null
	try t.expectEqual(@as(?*t.Entry, null), try cache.fetch(*FetchState, "return null", &doFetch, &fetch_state, .{}));
	try t.expectEqual(@as(i32, 3), fetch_state.called);

	// we don't cache null, so this will hit doFetch again
	try t.expectEqual(@as(?*t.Entry, null), try cache.fetch(*FetchState, "return null", &doFetch, &fetch_state, .{}));
	try t.expectEqual(@as(i32, 4), fetch_state.called);

	// this will return an error
	try t.expectError(error.FetchFail, cache.fetch(*FetchState, "return error", &doFetch, &fetch_state, .{}));
	try t.expectEqual(@as(i32, 5), fetch_state.called);
}

test "cache: max_size" {
	var cache = try Cache(i32).init(t.allocator, .{.max_size = 5, .segment_count = 1});
	defer cache.deinit();

	try cache.put("k1", 1, .{});
	try cache.put("k2", 2, .{});
	try cache.put("k3", 3, .{});
	try cache.put("k4", 4, .{});
	try cache.put("k5", 5, .{});
	try testSingleSegmentCache(cache, &[_][]const u8{"k5", "k4", "k3", "k2", "k1"});

	try cache.put("k6", 6, .{});
	try testSingleSegmentCache(cache, &[_][]const u8{"k6", "k5", "k4", "k3"});

	try cache.put("k7", 7, .{});
	try testSingleSegmentCache(cache, &[_][]const u8{"k7", "k6", "k5", "k4", "k3"});

	try cache.put("k6", 6, .{});
	try testSingleSegmentCache(cache, &[_][]const u8{"k7", "k6", "k5", "k4", "k3"});

	try cache.put("k8", 8, .{.size = 3});
	try testSingleSegmentCache(cache, &[_][]const u8{"k8", "k7"});
}

// if DeinitValue.deinit isn't called, we expect a memory leak to be detected
test "cache: entry has deinit" {
	var cache = try Cache(DeinitValue).init(t.allocator, .{.segment_count = 1, .max_size = 2});
	defer cache.deinit();

	try cache.put("k1", DeinitValue.init("abc"), .{});

	// overwriting should free the old
	try cache.put("k1", DeinitValue.init("new"), .{});

	// delete should free
	_ = cache.del("k1");

	// max_size enforcerr should free
	try cache.put("k1", DeinitValue.init("abc"), .{});
	try cache.put("k2", DeinitValue.init("abc"), .{});
	try cache.put("k3", DeinitValue.init("abc"), .{});
	try t.expectEqual(false, cache.contains("k1")); // make sure max_size enforcer really did run
}

fn testSingleSegmentCache(cache: Cache(i32), expected: []const []const u8) !void {
	for (expected) |e| {
		try t.expectEqual(true, cache.contains(e));
	}
	// only works for caches with 1 segment, else we don't know how the keys
	// are distributed (I mean, we know the hashing algorithm, so we could
	// figure it out, but we're testing this assuming that if 1 segment works
	// N segment works. This seems reasonable since there's no real link between
	// segments)
	try t.testList(cache.segments[0].list, expected);
}

const DeinitValue = struct {
	data: []const u8,

	fn init(data: []const u8) DeinitValue {
		return .{.data = t.allocator.dupe(u8, data) catch unreachable};
	}

	pub fn deinit(self: DeinitValue, allocator: Allocator) void {
		allocator.free(self.data);
	}
};

const FetchState = struct {
	called: i32,
};

fn doFetch(key: []const u8, state: *FetchState) !?i32 {
	state.called += 1;
	if (std.mem.eql(u8, key, "return null")) {
		return null;
	}
	if (state.called == 5) {
		return error.FetchFail;
	}
	return state.called;
}
