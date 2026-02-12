pub const CreateMultiple = struct {
    pub const Request = struct {
        title: [][]const u8,
        release_date: []?[]const u8,
        description: []?[]const u8,
        total_chapters: []?i32,
        user_id: []const u8,
        providers: [][]const u8,
        external_ids: [][]const u8,
    };

    pub const Response = struct {
        ids: [][]u8,

        pub fn deinit(self: @This(), allocator: Allocator) void {
            for (self.ids) |id| allocator.free(id);
            allocator.free(self.ids);
        }
    };

    pub const Errors = error{
        CannotCreate,
        OutOfMemory,
        CannotParseID,
    } || DatabaseErrors;

    pub fn call(allocator: std.mem.Allocator, connection: Connection, request: Request) Errors!Response {
        assertSameLength(request, .{ "title", "release_date", "description", "total_chapters" });
        var conn = try connection.acquire();
        defer connection.release(conn);
        const error_handler = ErrorHandler{ .conn = conn };
        var query = conn.query(query_string, .{
            request.title,
            request.release_date,
            request.description,
            request.total_chapters,
            request.user_id,
            request.providers,
            request.external_ids,
        }) catch |err| {
            const error_data = error_handler.handle(err);
            if (error_data) |data| {
                ErrorHandler.printErr(data);
            }
            return error.CannotCreate;
        };
        defer query.deinit();

        var ids: std.ArrayList([]u8) = try .initCapacity(allocator, request.title.len);
        defer ids.deinit(allocator);
        errdefer for (ids.items) |id| allocator.free(id);

        while (query.next() catch return error.CannotCreate) |row| {
            const id = try UUID.toStringAlloc(allocator, row.get([]u8, 0));
            errdefer allocator.free(id);

            ids.append(allocator, id) catch return error.OutOfMemory;
        }

        return Response{
            .ids = ids.toOwnedSlice(allocator) catch return error.OutOfMemory,
        };
    }

    const query_string = @embedFile("queries/create_many.sql");
};

test "Model | Manga | Create Multiple" {
    const allocator = std.testing.allocator;

    const test_env = Tests.test_env;
    const test_name = "Model | Manga | Create Multiple";
    var setup = try TestSetup.init(test_env.database_pool, test_name);
    defer setup.deinit(allocator);

    const count = 10;
    var titles = try allocator.alloc([]const u8, count);
    var release_dates = try allocator.alloc(?[]const u8, count);
    var descriptions = try allocator.alloc(?[]const u8, count);
    var chapters = try allocator.alloc(?i32, count);
    var providers = try allocator.alloc([]const u8, count);
    var external_ids = try allocator.alloc([]const u8, count);
    defer {
        for (0..count) |i| {
            allocator.free(titles[i]);
            allocator.free(descriptions[i].?);
            allocator.free(providers[i]);
            allocator.free(external_ids[i]);
        }
        allocator.free(titles);
        allocator.free(descriptions);
        allocator.free(providers);
        allocator.free(external_ids);
        allocator.free(release_dates);
        allocator.free(chapters);
    }

    for (0..count) |i| {
        titles[i] = try std.fmt.allocPrint(allocator, "{s} | Movie {d}", .{ test_name, i });
        descriptions[i] = try std.fmt.allocPrint(allocator, "{s} | Movie {d}'s description", .{ test_name, i });
        release_dates[i] = null;
        chapters[i] = 100;
        providers[i] = try std.fmt.allocPrint(allocator, "{s} | Movie {d}'s provider", .{ test_name, i });
        external_ids[i] = try std.fmt.allocPrint(allocator, "{s} | Movie {d}'s external id", .{ test_name, i });
    }

    const request: CreateMultiple.Request = .{
        .title = titles,
        .release_date = release_dates,
        .description = descriptions,
        .total_chapters = chapters,
        .user_id = setup.user.id,
        .providers = providers,
        .external_ids = external_ids,
    };

    const response = try CreateMultiple.call(allocator, .{ .database = test_env.database_pool }, request);
    defer response.deinit(allocator);

    try std.testing.expectEqual(count, response.ids.len);
}

test "Model | Manga | Create Multiple | Allocation Failures" {
    const allocator = std.testing.allocator;

    const test_env = Tests.test_env;
    const test_name = "Model | Manga | Create Multiple | Allocation Failures";
    var setup = try TestSetup.init(test_env.database_pool, test_name);
    defer setup.deinit(allocator);

    const count = 10;
    var titles = try allocator.alloc([]const u8, count);
    var release_dates = try allocator.alloc(?[]const u8, count);
    var descriptions = try allocator.alloc(?[]const u8, count);
    var chapters = try allocator.alloc(?i32, count);
    var providers = try allocator.alloc([]const u8, count);
    var external_ids = try allocator.alloc([]const u8, count);
    defer {
        for (0..count) |i| {
            allocator.free(titles[i]);
            allocator.free(descriptions[i].?);
            allocator.free(providers[i]);
            allocator.free(external_ids[i]);
        }
        allocator.free(titles);
        allocator.free(descriptions);
        allocator.free(providers);
        allocator.free(external_ids);
        allocator.free(release_dates);
        allocator.free(chapters);
    }

    for (0..count) |i| {
        titles[i] = try std.fmt.allocPrint(allocator, "{s} | Movie {d}", .{ test_name, i });
        descriptions[i] = try std.fmt.allocPrint(allocator, "{s} | Movie {d}'s description", .{ test_name, i });
        release_dates[i] = null;
        chapters[i] = 100;
        providers[i] = try std.fmt.allocPrint(allocator, "{s} | Movie {d}'s provider", .{ test_name, i });
        external_ids[i] = try std.fmt.allocPrint(allocator, "{s} | Movie {d}'s external id", .{ test_name, i });
    }

    const request: CreateMultiple.Request = .{
        .title = titles,
        .release_date = release_dates,
        .description = descriptions,
        .total_chapters = chapters,
        .user_id = setup.user.id,
        .providers = providers,
        .external_ids = external_ids,
    };

    try std.testing.checkAllAllocationFailures(
        allocator,
        struct {
            fn call(alloc: Allocator, conn: Connection, req: CreateMultiple.Request) !void {
                const response = try CreateMultiple.call(alloc, conn, req);
                response.deinit(allocator);
            }
        }.call,
        .{
            Connection{ .database = test_env.database_pool },
            request,
        },
    );
}

const Pool = @import("../../../database.zig").Pool;
const Connection = @import("../../../database.zig").Connection;
const DatabaseErrors = @import("../../../database.zig").DatabaseErrors;
const ErrorHandler = @import("../../../database.zig").ErrorHandler;
const Tests = @import("../../../tests/setup.zig");
const TestSetup = Tests.TestSetup;

const Handler = @import("../../../handler.zig");

const UUID = @import("../../../util/uuid.zig");
const JWTClaims = @import("../../../auth/tokens.zig").JWTClaims;

const assertSameLength = @import("../../../util/assertSameLength.zig").assertAllSameLength;

const Allocator = std.mem.Allocator;
const std = @import("std");
