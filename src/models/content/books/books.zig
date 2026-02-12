pub const Create = struct {
    pub const Request = struct {
        title: []const u8,
        user_id: []const u8,
        release_date: ?[]const u8,
        total_pages: ?i32,
        description: ?[]const u8,
    };

    pub const Response = struct {
        id: []const u8,
        title: []const u8,

        pub fn deinit(self: Response, allocator: Allocator) void {
            allocator.free(self.id);
            allocator.free(self.title);
        }
    };

    pub const Errors = error{
        CannotCreate,
        OutOfMemory,
        CannotParseID,
    } || DatabaseErrors;

    pub fn call(allocator: std.mem.Allocator, connection: Connection, request: Request) Errors!Response {
        var conn = try connection.acquire();
        defer connection.release(conn);
        const error_handler = ErrorHandler{ .conn = conn };
        var row = conn.row(query_string, .{
            request.title,
            request.user_id,
            request.release_date,
            request.total_pages,
            request.description,
        }) catch |err| {
            const error_data = error_handler.handle(err);
            if (error_data) |data| {
                ErrorHandler.printErr(data);
            }
            return error.CannotCreate;
        } orelse return error.CannotCreate;
        defer row.deinit() catch {};

        const id = try UUID.toStringAlloc(allocator, row.get([]u8, 0));
        errdefer allocator.free(id);

        const title = allocator.dupe(u8, row.get([]u8, 1)) catch return error.OutOfMemory;
        errdefer allocator.free(title);

        return Response{
            .id = id,
            .title = title,
        };
    }

    const query_string = @embedFile("queries/create.sql");
};

test "Model | Books | Create" {
    const allocator = std.testing.allocator;

    const test_env = Tests.test_env;
    const test_name = "Model | Books | Create";
    var setup = try TestSetup.init(test_env.database_pool, test_name);
    defer setup.deinit(allocator);

    const request: Create.Request = .{
        .title = test_name,
        .release_date = "01-01-2000",
        .description = test_name ++ "'s test",
        .user_id = setup.user.id,
        .total_pages = 100,
    };

    const response = try Create.call(allocator, .{ .database = test_env.database_pool }, request);
    defer response.deinit(allocator);

    try std.testing.expectEqualStrings(request.title, response.title);
}

test "Model | Books | Create | Allocation Failure" {
    const allocator = std.testing.allocator;

    const test_env = Tests.test_env;
    const test_name = "Model | Books | Create | Allocation Failure";
    var setup = try TestSetup.init(test_env.database_pool, test_name);
    defer setup.deinit(allocator);

    const request: Create.Request = .{
        .title = test_name,
        .release_date = "01-01-2000",
        .description = test_name ++ "'s test",
        .user_id = setup.user.id,
        .total_pages = 100,
    };

    try std.testing.checkAllAllocationFailures(
        allocator,
        struct {
            fn call(alloc: Allocator, conn: Connection, req: Create.Request) !void {
                const response = try Create.call(alloc, conn, req);
                response.deinit(allocator);
            }
        }.call,
        .{
            Connection{ .database = test_env.database_pool },
            request,
        },
    );
}

const Connection = @import("../../../database.zig").Connection;
const DatabaseErrors = @import("../../../database.zig").DatabaseErrors;
const ErrorHandler = @import("../../../database.zig").ErrorHandler;

const Tests = @import("../../../tests/setup.zig");
const TestSetup = Tests.TestSetup;

const Handler = @import("../../../handler.zig");

const UUID = @import("../../../util/uuid.zig");
const JWTClaims = @import("../../../auth/tokens.zig").JWTClaims;

const Allocator = std.mem.Allocator;
const std = @import("std");
