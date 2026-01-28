pub inline fn init() !void {
    try Fetchers.init();
}

pub inline fn deinit() void {
    Fetchers.deinit();
}

pub const Indexers = @import("indexers.zig");
pub const Fetchers = @import("fetchers.zig");
pub const Collector = enum { tmdb, mangabaka };
