const log = std.log.scoped(.indexers);

pub fn fetch(
    allocator: Allocator,
    database: *Database,
    config: Config,
) !void {
    if (config.collectors.tmdb.enable) {
        TMDB.fetch(allocator, database, config.collectors.tmdb.indexer_path.?) catch |err| {
            log.err("TMDB failed! {}", .{err});
        };
    }
}

const TMDB = @import("tmdb/tmdb.zig").Indexer;

const Config = @import("../config/config.zig");

const Database = @import("../database.zig").Pool;

const Allocator = std.mem.Allocator;
const std = @import("std");
