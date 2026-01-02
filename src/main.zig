var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
const log = std.log.scoped(.main);

pub fn main() !void {
    const allocator, const is_debug = gpa: {
        break :gpa switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
        };
    };

    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };

    var config = try Config.init(allocator);
    defer config.deinit(allocator);

    var database = try Database.init(allocator, config);
    defer database.deinit();

    var handler = Handler{
        .database_pool = database,
        .config = config,
    };

    var server = try httpz.Server(*Handler).init(allocator, .{
        .port = config.port,
        .address = config.address,
    }, &handler);
    defer {
        server.deinit();
        server.stop();
    }

    const router = try server.router(.{});

    API.init(router);

    log.info("Listening on http://{s}:{d}/", .{ config.address, config.port });
    try server.listen();
}

test "tests:beforeAll" {
    // Things that should be initialized before all tests are ran.
    // Usually things like database interfaces.

    // Eventually will be removed from stdlib, but for now, we make due with what we have.
    std.testing.refAllDecls(@This());
    _ = @import("endpoint.zig");
}

test "tests:afterAll" {
    // Things that should be called after all tests are done.
    // Usually done to deinitialize things from the beforeAll call.
}

const API = @import("routes/routes.zig");

const Database = @import("database.zig");
const Config = @import("config/config.zig");

const Handler = @import("handler.zig");

const httpz = @import("httpz");

const builtin = @import("builtin");
const std = @import("std");
