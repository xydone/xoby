const log = std.log.scoped(.indexers);

pub fn init(config: Config, allocator: Allocator) !void {
    if (config.collectors.tmdb.enable) {
        TMDB.init(allocator, .{ .file = .{ .absolute_path = config.collectors.tmdb.path.? } }) catch |err| {
            log.err("TMDB failed! {}", .{err});
        };
    }
}

const TMDB = @import("tmdb/tmdb.zig").Indexer;

const Config = @import("../config/config.zig");

const Allocator = std.mem.Allocator;
const std = @import("std");
