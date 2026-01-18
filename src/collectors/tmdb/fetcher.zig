const log = std.log.scoped(.tmdb_fetcher);

pub fn fetch(allocator: Allocator, database: *Database) !void {
    const request = GetNotCompleted.Request{
        .provider = "tmdb",
        .limit = 1_000,
    };

    const id_list = GetNotCompleted.call(allocator, database, request) catch |err| {
        log.err("GetNotCompleted failed! {}", .{err});
        return err;
    };
    defer {
        defer allocator.free(id_list);
        for (id_list) |id| allocator.free(id);
    }
    // TODO: fetch from tmdb's API
}

const GetNotCompleted = @import("../../models/collectors/collectors.zig").GetNotCompleted;

const Database = @import("../../database.zig").Pool;

const Allocator = std.mem.Allocator;
const std = @import("std");
