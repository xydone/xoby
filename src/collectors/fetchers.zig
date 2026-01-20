const log = std.log.scoped(.fetchers);

pub fn fetch(
    allocator: Allocator,
    database: *Database,
    config: Config,
    user_id: []const u8,
) !void {
    if (config.collectors.tmdb.enable) blk: {
        const api_key = if (config.collectors.tmdb.api_key) |key| key else break :blk;
        TMDB.fetch(
            allocator,
            database,
            user_id,
            api_key,
            config.collectors.tmdb.requests_per_second,
        ) catch |err| {
            log.err("TMDB failed! {}", .{err});
        };
    }
}

const TMDB = @import("tmdb/tmdb.zig").Fetcher;

const Config = @import("../config/config.zig");

const Database = @import("../database.zig").Pool;

const Allocator = std.mem.Allocator;
const std = @import("std");
