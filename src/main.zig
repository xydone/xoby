var debug_allocator: std.heap.DebugAllocator(.{
    .thread_safe = true,
}) = .init;
const log = std.log.scoped(.main);

var server_instance: ?*httpz.Server(*Handler) = null;

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

    var redis_client = try redis.Client.init(allocator, config.redis.address, config.redis.port);
    defer redis_client.deinit();

    try Collectors.init();
    defer Collectors.deinit();

    var handler = try Handler.init(
        allocator,
        database,
        &redis_client,
        config,
    );
    defer handler.deinit();

    var server = try httpz.Server(*Handler).init(allocator, .{
        .port = config.port,
        .address = config.address,
    }, &handler);
    defer {
        server.deinit();
        if (builtin.os.tag == .windows) server.stop();
    }

    const cors = try server.middleware(CORS, .{
        .origin = "*",
        .headers = "*",
        .methods = "*",
    });

    const router = try server.router(
        .{
            .middlewares = &.{cors},
        },
    );

    API.init(router);

    log.info("Listening on http://{s}:{d}/", .{ config.address, config.port });
    // shutdown only available on posix
    if (builtin.os.tag != .windows) {
        std.posix.sigaction(std.posix.SIG.INT, &.{
            .handler = .{ .handler = shutdown },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        }, null);
        std.posix.sigaction(std.posix.SIG.TERM, &.{
            .handler = .{ .handler = shutdown },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        }, null);
        log.info("To shutdown, run: kill -s int {d}", .{std.c.getpid()});
        server_instance = &server;
    }

    try server.listen();
}

fn shutdown(_: c_int) callconv(.c) void {
    if (server_instance) |server| {
        server_instance = null;
        server.stop();
    }
}

test "tests:beforeAll" {
    // Things that should be initialized before all tests are ran.
    // Usually things like database interfaces.
    const allocator = std.heap.smp_allocator;
    try Tests.TestEnvironment.init(allocator);

    // Eventually will be removed from stdlib, but for now, we make due with what we have.
    std.testing.refAllDecls(@This());
    _ = @import("endpoint.zig");
}

test "tests:afterAll" {
    // Things that should be called after all tests are done.
    // Usually done to deinitialize things from the beforeAll call.

    const allocator = std.heap.smp_allocator;
    Tests.test_env.deinit(allocator);
}

const Tests = @import("tests/setup.zig");

const API = @import("routes/routes.zig");

const redis = @import("redis.zig");
const Database = @import("database.zig");
const Config = @import("config/config.zig");
const Collectors = @import("collectors/collectors.zig");

const CORS = @import("middleware/cors.zig");
const Handler = @import("handler.zig");

const httpz = @import("httpz");

const builtin = @import("builtin");
const std = @import("std");
