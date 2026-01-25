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
pub fn fetch(
    allocator: Allocator,
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

const Collector = @import("collectors.zig").Collector;

const Config = @import("../config/config.zig");

const Database = @import("../database.zig").Pool;

const curl = @import("curl");

const Allocator = std.mem.Allocator;
const std = @import("std");
