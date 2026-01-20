const std = @import("std");

pub const RateLimiter = struct {
    mutex: std.Thread.Mutex,
    allocator: std.mem.Allocator,
    interval: i64,
    max_requests_per_interval: u64,
    request_timestamps: std.PriorityDequeue(i64, void, compare),

    pub fn init(allocator: std.mem.Allocator, interval: i64, max_requests_per_interval: u64) RateLimiter {
        return RateLimiter{
            .allocator = allocator,
            .interval = interval,
            .max_requests_per_interval = max_requests_per_interval,
            .mutex = std.Thread.Mutex{},
            .request_timestamps = std.PriorityDequeue(i64, void, compare).init(allocator, {}),
        };
    }

    pub fn deinit(self: RateLimiter) void {
        self.request_timestamps.deinit();
    }
    fn compare(_: void, a: i64, b: i64) std.math.Order {
        return std.math.order(a, b);
    }

    /// Returns miliseconds.
    pub fn waitTime(self: *RateLimiter, cutoff_time: i64) i64 {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.canSendRequest(cutoff_time - self.interval) == true) return 0;
        const wait_time = (self.request_timestamps.peekMin().? + self.interval) - std.time.milliTimestamp();
        return wait_time;
    }
    /// Adds the latest request. Does NOT prune requests out of interval.
    pub fn addRequest(self: *RateLimiter, time: i64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.request_timestamps.add(time);
    }

    /// Removes all requests older than the cutoff time
    fn pruneStale(self: *RateLimiter, cutoff_time: i64) void {
        const oldest_timestamp = self.request_timestamps.peekMin() orelse return;
        if (oldest_timestamp > cutoff_time) return;
        _ = self.request_timestamps.removeMinOrNull();
        pruneStale(self, cutoff_time);
    }

    /// Prunes old requests and responds if a request can be sent
    fn canSendRequest(self: *RateLimiter, cutoff_time: i64) bool {
        self.pruneStale(cutoff_time);
        return self.request_timestamps.len < self.max_requests_per_interval;
    }
};
pub const RateLimiterConfig = struct { interval: i64, max_requests_per_interval: u64 };

pub const MultiRateLimiter = struct {
    rate_limiters: []*RateLimiter,
    allocator: std.mem.Allocator,

    requests_made: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, rate_limiter_configs: []RateLimiterConfig) !MultiRateLimiter {
        var rate_limiters = std.ArrayList(*RateLimiter).init(allocator);
        for (rate_limiter_configs) |ctx| {
            const rate_limiter = try allocator.create(RateLimiter);
            rate_limiter.* = RateLimiter.init(allocator, ctx.interval, ctx.max_requests_per_interval);
            try rate_limiters.append(rate_limiter);
        }
        return MultiRateLimiter{
            .rate_limiters = try rate_limiters.toOwnedSlice(),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: MultiRateLimiter) void {
        for (self.rate_limiters) |rate_limiter| {
            rate_limiter.*.deinit();
            self.allocator.destroy(rate_limiter);
        }
        self.allocator.free(self.rate_limiters);
    }

    /// Returns miliseconds.
    pub fn waitTime(self: MultiRateLimiter, cutoff_time: i64) i64 {
        var biggest_wait_time: i64 = 0;
        for (self.rate_limiters) |rate_limiter| {
            const wait_time = rate_limiter.waitTime(cutoff_time);
            if (wait_time > biggest_wait_time) biggest_wait_time = wait_time;
        }
        return biggest_wait_time;
    }

    /// Adds the latest request. Does NOT prune requests out of interval.
    pub fn addRequest(self: *MultiRateLimiter, time: i64) !void {
        self.requests_made += 1;
        for (self.rate_limiters) |rate_limiter| {
            try rate_limiter.request_timestamps.add(time);
        }
    }
};
