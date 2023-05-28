A thread-safe, expiration-aware, LRU(ish) cache for Zig


```zig
// package available using Zig's built-in package manager
const user_cache = @import("cache");

var user_cache = try cache.Cache(User).init(allocator, .{.max_size = 10000});
defer user_cache.deinit();

try user_cache.put("user1", user1, .{.ttl = 300});
...

if (user_cache.get("user1")) |entry| {
    const user1 = entry.value;
} else {
    // not in the cache
}

// del will return true if the item existed
_ = user_cache.del("user1");
```

`get` will return `null` if the key is not found, or if the entry associated with the key has expired. If the entry has expired, it will be removed.

`getEntry` can be used to return the entry even if it has expired and will not remove the entry from the cache. However, such entries will become prime candidates for collection should the cache exceed its configured size.

In either case, the entry's `ttl() i64` method can be used to return the number of seconds until the entry expires. This will be negative if the entry has already expired. The `expired() bool` method will return `true` if the entry is expired.

## Implementation
This is a typical LRU cache which combines a hashmap to lookup values and doubly linked list to track recency.

To improve throughput, the cache is divided into a configured number of segments (defaults to 8). Locking only happens at the segment level. Furthermore, items are only promoted to the head of the recency linked list after a configured number of gets. This not only reduces the locking on the linked list, but also introduces a frequency bias to the eviction policy (which I think is welcome addition).

The downside of this approach is that size enforcement and the eviction policy is done on a per-segment basis. Given a `max_size` of 8000 and a `segment_count` of 8, each segment will enforce its own `max_size` of 1000 and maintain its own recency list. Should keys be poorly distributed across segments, the cache will only reach a fraction of its configured max size. Only lease-recently used items within a segment are considered for eviction.

## Configuration
The 2nd argument to init is (including defaults):

```zig
{
    // The max size of the cache. By default, each value has a size of 1, but 
    // this can be configured, on a per value basis, when using `cache.put`
    max_size: u32 = 8000,

    // The number of segments to use. Must be a power of 2. A value of 1 is valid.
    segment_count: u16 = 8,

    // The number of times get or getEntry must be called on a key before 
    // it's promoted to the head of the recency list
    gets_per_promote: u8 = 5,

    // When a segment is full, the ratio of the segment's max_size to free.
    shrink_ratio: f32 = 0.2,
}
```
Given the above, each segment will enforce its own `max_size` of 1000 (i.e. `8000 / 8`). When a segment grows beyond 1000 entries will be removed until its size becomes less than or equal to 800 (i.e. `1000 - (1000 * 0.2)`)

## Put
The `cache.put(key: []const u8, value: T, config: cache.PutConfig) !void` has a number of consideration.

First, the key will be cloned and managed by the cache. The caller does not have to guarantee its validity after `put` returns.

`value` will be similarly managed by the cache. If `T` defines a method `deinit`, the cache will call `value.deinit(allocator: std.mem.Allocator)` whenever an item is removed from the cache (for whatever reason, including expiration, an explicit call to `cache.del`, or if the cache frees space when it is full). The `Allocator` passed to `deinit` is the `Allocator` that the cache was created with - this may or may not be an allocator that is meaningful to the value.

The third parameter is a `cache.PutConfig`: 

```zig
{
    .size: u32 = 1,
    .ttl: u32 = 300,
}
```

`size` is the size of the value. This doesn't have to be the actual memory used by the value being cached. In many cases, the default of `1` is reasonable. However, if enforcement of the memory used by the cache is important, giving an approximate size (as memory usage or as a weighted value) will help. For example, if you're caching a string, the length of the string could make a reasonable argument for `size`. 

`ttl` is the length, in second, to keep the value in the cache.
