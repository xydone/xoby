const log = std.log.scoped(.fetchers);

pub const TMDB = @import("tmdb/tmdb.zig").Fetcher;

const Response = struct {
    tmdb: ?TMDB.Response = null,
};

pub inline fn init() !void {
    try curl.globalInit();
}

pub inline fn deinit() void {
    curl.globalDeinit();
}

pub const Fetcher = enum { tmdb };

pub const Manager = struct {
    mutex: std.Thread.Mutex = .{},
    active_tmdb: ?*TMDB.SharedState = null,

    pub fn cancel(self: *Manager, fetcher: Fetcher) void {
        self.mutex.lock();
        switch (fetcher) {
            .tmdb => {
                if (self.active_tmdb) |state| {
                    state.is_cancelled.store(true, .monotonic);
                    self.mutex.unlock();
                    state.thread.join();
                    self.active_tmdb = null;
                }
            },
        }
    }

    pub fn register(self: *Manager, state: *TMDB.SharedState, fetcher: Fetcher) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        switch (fetcher) {
            .tmdb => {
                if (self.active_tmdb != null) return error.AlreadyRunning;
                self.active_tmdb = state;
            },
        }
    }

    /// WARNING: Does not set is_cancelled to false, all it does is null the pointer
    pub fn unregister(self: *Manager, fetcher: Fetcher) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        switch (fetcher) {
            .tmdb => {
                self.active_tmdb = null;
            },
        }
    }
};

pub fn fetch(
    allocator: Allocator,
    manager: *Manager,
    database: *Database,
    config: Config,
    user_id: []const u8,
    collectors: []Collector,
) !Response {
    var response: Response = .{};
    for (collectors) |collector| {
        switch (collector) {
            .tmdb => if (config.collectors.tmdb.enable == false) continue else {
                const api_key = if (config.collectors.tmdb.api_key) |key| key else continue;
                const tmdb: ?TMDB.Response = TMDB.fetch(
                    allocator,
                    manager,
                    database,
                    user_id,
                    api_key,
                    config.collectors.tmdb.requests_per_second,
                    config.collectors.tmdb.batch_size,
                ) catch |err| {
                    log.err("TMDB failed! {}", .{err});
                    continue;
                };
                response.tmdb = tmdb;
            },
        }
    }
    return response;
}

pub const HandlePool = struct {
    mutex: std.Thread.Mutex = .{},
    handles: std.ArrayList(*curl.Easy),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, size: usize, ca_bundle: std.array_list.Managed(u8)) !HandlePool {
        var handles = std.ArrayList(*curl.Easy).empty;
        errdefer {
            for (handles.items) |h| {
                h.deinit();
                allocator.destroy(h);
            }
            handles.deinit(allocator);
        }

        for (0..size) |_| {
            const h = try allocator.create(curl.Easy);
            h.* = try curl.Easy.init(.{ .ca_bundle = ca_bundle });
            try handles.append(allocator, h);
        }

        return .{
            .handles = handles,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *HandlePool) void {
        for (self.handles.items) |h| {
            h.deinit();
            self.allocator.destroy(h);
        }
        self.handles.deinit(self.allocator);
    }

    pub fn acquire(self: *HandlePool) ?*curl.Easy {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.handles.pop();
    }

    pub fn release(self: *HandlePool, handle: *curl.Easy) !void {
        handle.reset();

        self.mutex.lock();
        defer self.mutex.unlock();
        try self.handles.append(self.allocator, handle);
    }
};

const Collector = @import("collectors.zig").Collector;

const Config = @import("../config/config.zig");

const Database = @import("../database.zig").Pool;

const curl = @import("curl");

const Allocator = std.mem.Allocator;
const std = @import("std");
