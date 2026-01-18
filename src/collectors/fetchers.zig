const log = std.log.scoped(.fetchers);

pub fn fetch(
    allocator: Allocator,
    database: *Database,
    config: Config,
) !void {
    if (config.collectors.tmdb.enable) {
        TMDB.fetch(allocator, database) catch |err| {
            log.err("TMDB failed! {}", .{err});
        };
    }
}

const TMDB = @import("tmdb/tmdb.zig").Fetcher;

const Config = @import("../config/config.zig");

const Database = @import("../database.zig").Pool;

const Allocator = std.mem.Allocator;
const std = @import("std");
