const log = std.log.scoped(.collectors_model);

const Status = enum { completed, pending, todo };

pub const Create = struct {
    pub const Request = struct {
        provider: []const u8,
        media_type: MediaType,
        id_list: []i64,
        popularity: []f64,
    };

    pub const Errors = error{
        CannotCreate,
        OutOfMemory,
        CannotParseID,
    } || DatabaseErrors;

    pub fn call(connection: Connection, request: Request) Errors!void {
        var conn = try connection.acquire();
        defer connection.release(conn);
        _ = conn.exec(
            query_string,
            .{
                request.provider,
                request.id_list,
                request.media_type,
                request.popularity,
            },
        ) catch |err| {
            const error_handler = ErrorHandler{ .conn = conn };
            const error_data = error_handler.handle(err);
            if (error_data) |data| {
                ErrorHandler.printErr(data);
            }
        };
    }

    const query_string = @embedFile("queries/create_many.sql");
};

test "Model | Collectors | Create" {
    const allocator = std.testing.allocator;

    const test_env = Tests.test_env;
    const test_name = "Model | Collectors | Create";
    var setup = try TestSetup.init(test_env.database_pool, test_name);
    defer setup.deinit(allocator);

    const count = 10;
    var ids = try allocator.alloc(i64, count);
    var popularity = try allocator.alloc(f64, count);
    defer {
        allocator.free(ids);
        allocator.free(popularity);
    }

    for (0..count) |i| {
        ids[i] = 1234;
        popularity[i] = 0.5;
    }

    const request: Create.Request = .{
        .provider = test_name ++ "'s provider",
        .media_type = .movie,
        .id_list = ids,
        .popularity = popularity,
    };

    try Create.call(
        .{ .database = test_env.database_pool },
        request,
    );
}

pub const GetNotCompleted = struct {
    pub const Request = struct {
        provider: []const u8,
        limit: u32 = 1_000,
    };

    pub const Response = []u8;

    pub const Errors = error{
        CannotGet,
        InvalidLimit,
        OutOfMemory,
        CannotParseID,
    } || DatabaseErrors;

    /// Caller must free slice and contents.
    pub fn call(allocator: Allocator, connection: Connection, request: Request) Errors![]Response {
        var conn = try connection.acquire();
        defer connection.release(conn);

        var query = conn.queryOpts(
            query_string,
            .{
                request.provider,
                std.math.cast(u32, request.limit) orelse return error.InvalidLimit,
            },
            .{
                .column_names = true,
            },
        ) catch |err| {
            const error_handler = ErrorHandler{ .conn = conn };
            const error_data = error_handler.handle(err);
            if (error_data) |data| {
                ErrorHandler.printErr(data);
            }
            return error.CannotGet;
        };
        defer query.deinit();

        const DatabaseResponse = struct {
            external_id: []u8,
        };
        var mapper = query.mapper(DatabaseResponse, .{});

        var id_list: std.ArrayList([]u8) = .empty;
        defer id_list.deinit(allocator);
        errdefer for (id_list.items) |id| allocator.free(id);

        while (mapper.next() catch return error.CannotGet) |response| {
            const id = allocator.dupe(u8, response.external_id) catch return error.OutOfMemory;
            errdefer allocator.free(id);
            id_list.append(allocator, id) catch return error.OutOfMemory;
        }

        return id_list.toOwnedSlice(allocator);
    }

    const query_string = @embedFile("queries/get_not_completed.sql");
};

test "Model | Collectors | GetNotCompleted" {
    const allocator = std.testing.allocator;

    const test_env = Tests.test_env;
    const test_name = "Model | Collectors | GetNotCompleted";
    var setup = try TestSetup.init(test_env.database_pool, test_name);
    defer setup.deinit(allocator);

    const count = 10;
    var ids = try allocator.alloc(i64, count);
    var popularity = try allocator.alloc(f64, count);
    defer {
        allocator.free(ids);
        allocator.free(popularity);
    }

    for (0..count) |i| {
        ids[i] = 1234;
        popularity[i] = 0.5;
    }

    {
        const request: Create.Request = .{
            .provider = test_name ++ "'s provider",
            .media_type = .movie,
            .id_list = ids,
            .popularity = popularity,
        };

        try Create.call(
            .{ .database = test_env.database_pool },
            request,
        );
    }

    const request: GetNotCompleted.Request = .{
        .provider = test_name ++ "'s provider",
        .limit = 10,
    };

    const responses = try GetNotCompleted.call(allocator, .{ .database = test_env.database_pool }, request);
    defer {
        for (responses) |response| allocator.free(response);
        allocator.free(responses);
    }

    try std.testing.expectEqual(1, responses.len);
}

test "Model | Collectors | GetNotCompleted | Allocation Failures" {
    const allocator = std.testing.allocator;

    const test_env = Tests.test_env;
    const test_name = "Model | Collectors | GetNotCompleted | Allocation Failures";
    var setup = try TestSetup.init(test_env.database_pool, test_name);
    defer setup.deinit(allocator);

    const count = 10;
    var ids = try allocator.alloc(i64, count);
    var popularity = try allocator.alloc(f64, count);
    defer {
        allocator.free(ids);
        allocator.free(popularity);
    }

    for (0..count) |i| {
        ids[i] = 1234;
        popularity[i] = 0.5;
    }

    {
        const request: Create.Request = .{
            .provider = test_name ++ "'s provider",
            .media_type = .movie,
            .id_list = ids,
            .popularity = popularity,
        };

        try Create.call(
            .{ .database = test_env.database_pool },
            request,
        );
    }

    const request: GetNotCompleted.Request = .{
        .provider = test_name ++ "'s provider",
        .limit = 10,
    };

    try std.testing.checkAllAllocationFailures(
        allocator,
        struct {
            fn call(alloc: Allocator, c: Connection, req: GetNotCompleted.Request) !void {
                // NOTE: this is important, because checkAllAllocationFailures runs the function multiple times.
                // after the first iteration, it takes note of all memory allocated.
                // the second iteration will allocate more memory, as we are in fact creating more elements each time.
                // as this is not a deterministic test, we rollback any changes made
                const conn = try c.acquire();
                defer conn.release();
                try conn.begin();
                defer conn.rollback() catch @panic("failed to rollback");

                const responses = try GetNotCompleted.call(alloc, .{ .conn = conn }, req);
                for (responses) |response| alloc.free(response);
                alloc.free(responses);
            }
        }.call,
        .{
            Connection{ .database = test_env.database_pool },
            request,
        },
    );
}

pub const GetStatusCount = struct {
    pub const Request = struct {
        provider: []const u8,
        status: Status,
    };

    pub const Response = i64;

    pub const Errors = error{
        CannotGet,
        OutOfMemory,
        CannotParseID,
    } || DatabaseErrors;

    pub fn call(connection: Connection, request: Request) Errors!Response {
        var conn = try connection.acquire();
        defer connection.release(conn);

        var row = conn.row(
            query_string,
            .{
                request.provider,
                request.status,
            },
        ) catch |err| {
            const error_handler = ErrorHandler{ .conn = conn };
            const error_data = error_handler.handle(err);
            if (error_data) |data| {
                ErrorHandler.printErr(data);
            }
            return error.CannotGet;
        } orelse return error.CannotGet;
        defer row.deinit() catch {};

        const amount = row.get(i64, 0);

        return amount;
    }

    const query_string = @embedFile("queries/get_not_completed_count.sql");
};

test "Model | Collectors | GetStatusCount" {
    const allocator = std.testing.allocator;

    const test_env = Tests.test_env;
    const test_name = "Model | Collectors | GetStatusCount";
    var setup = try TestSetup.init(test_env.database_pool, test_name);
    defer setup.deinit(allocator);

    const count = 10;
    var ids = try allocator.alloc(i64, count);
    var popularity = try allocator.alloc(f64, count);
    defer {
        allocator.free(ids);
        allocator.free(popularity);
    }

    for (0..count) |i| {
        ids[i] = 1234;
        popularity[i] = 0.5;
    }

    {
        const request: Create.Request = .{
            .provider = test_name ++ "'s provider",
            .media_type = .movie,
            .id_list = ids,
            .popularity = popularity,
        };

        try Create.call(
            .{ .database = test_env.database_pool },
            request,
        );
    }

    const request: GetStatusCount.Request = .{
        .provider = test_name ++ "'s provider",
        .status = .todo,
    };

    const not_completed = try GetStatusCount.call(.{ .database = test_env.database_pool }, request);

    try std.testing.expectEqual(1, not_completed);
}

// TODO: test
pub const EditStatus = struct {
    pub const Request = struct {
        provider: []const u8,
        external_id: [][]const u8,
        status: Status,
    };

    pub const Response = void;

    pub const Errors = error{
        CannotUpdate,
        OutOfMemory,
    } || DatabaseErrors;

    pub fn call(connection: Connection, request: Request) Errors!Response {
        var conn = try connection.acquire();
        defer connection.release(conn);

        _ = conn.exec(
            query_string,
            .{
                request.provider,
                request.external_id,
                request.status,
            },
        ) catch |err| {
            const error_handler = ErrorHandler{ .conn = conn };
            const error_data = error_handler.handle(err);
            if (error_data) |data| {
                ErrorHandler.printErr(data);
            }
            return error.CannotUpdate;
        } orelse return error.CannotUpdate;
    }

    const query_string = @embedFile("queries/edit_status.sql");
};

test "Model | Collectors | EditStatus" {
    const allocator = std.testing.allocator;

    const test_env = Tests.test_env;
    const test_name = "Model | Collectors | EditStatus";
    var setup = try TestSetup.init(test_env.database_pool, test_name);
    defer setup.deinit(allocator);

    const count = 10;
    var ids = try allocator.alloc(i64, count);
    var popularity = try allocator.alloc(f64, count);
    defer {
        allocator.free(ids);
        allocator.free(popularity);
    }

    for (0..count) |i| {
        ids[i] = 1234;
        popularity[i] = 0.5;
    }

    {
        const request: Create.Request = .{
            .provider = test_name ++ "'s provider",
            .media_type = .movie,
            .id_list = ids,
            .popularity = popularity,
        };

        try Create.call(
            .{ .database = test_env.database_pool },
            request,
        );
    }

    var external_ids = std.ArrayList([]const u8).empty;
    defer {
        for (external_ids.items) |id| allocator.free(id);
        external_ids.deinit(allocator);
    }
    for (ids) |id| try external_ids.append(allocator, try std.fmt.allocPrint(allocator, "{}", .{id}));
    const request: EditStatus.Request = .{
        .provider = test_name ++ "'s provider",
        .external_id = external_ids.items,
        .status = .completed,
    };

    try EditStatus.call(.{ .database = test_env.database_pool }, request);
}

// TODO: test
pub const GetDistribution = struct {
    pub const Distribution = struct {
        todo: i64,
        pending: i64,
        completed: i64,
        stale: i64,
    };
    pub const Response = struct {
        map: *std.StringHashMap(Distribution),
        pub fn deinit(self: @This(), allocator: Allocator) void {
            self.map.deinit();
            allocator.destroy(self.map);
        }
    };

    pub const Errors = error{
        CannotGet,
        OutOfMemory,
        CannotParseID,
    } || DatabaseErrors;

    /// Caller must destroy response
    pub fn call(allocator: Allocator, connection: Connection) Errors!Response {
        var conn = try connection.acquire();
        defer connection.release(conn);

        var query = conn.queryOpts(
            query_string,
            .{},
            .{ .column_names = true },
        ) catch |err| {
            const error_handler = ErrorHandler{ .conn = conn };
            const error_data = error_handler.handle(err);
            if (error_data) |data| {
                ErrorHandler.printErr(data);
            }
            return error.CannotGet;
        };
        defer query.deinit();

        var response = allocator.create(std.StringHashMap(Distribution)) catch return error.OutOfMemory;
        errdefer allocator.destroy(response);
        response.* = .init(allocator);
        errdefer response.deinit();

        const DatabaseResponse = struct {
            provider: []const u8,
            todo: i64,
            pending: i64,
            completed: i64,
            stale: i64,
        };

        const mapper = query.mapper(DatabaseResponse, .{});
        while (mapper.next() catch return error.CannotGet) |db_response| {
            response.put(db_response.provider, .{
                .todo = db_response.todo,
                .pending = db_response.pending,
                .completed = db_response.completed,
                .stale = db_response.stale,
            }) catch return error.OutOfMemory;
        }

        return .{
            .map = response,
        };
    }

    const query_string = @embedFile("queries/get_distribution.sql");
};

test "Model | Collectors | GetDistribution" {
    const allocator = std.testing.allocator;

    const test_env = Tests.test_env;
    const test_name = "Model | Collectors | GetDistribution";
    var setup = try TestSetup.init(test_env.database_pool, test_name);
    defer setup.deinit(allocator);

    const count = 10;
    var ids = try allocator.alloc(i64, count);
    var popularity = try allocator.alloc(f64, count);
    defer {
        allocator.free(ids);
        allocator.free(popularity);
    }

    for (0..count) |i| {
        ids[i] = @intCast(i);
        popularity[i] = 0.5;
    }

    const provider = test_name ++ "'s provider";
    {
        const request: Create.Request = .{
            .provider = provider,
            .media_type = .movie,
            .id_list = ids,
            .popularity = popularity,
        };

        try Create.call(
            .{ .database = test_env.database_pool },
            request,
        );
    }

    const response = try GetDistribution.call(allocator, .{ .database = test_env.database_pool });
    defer response.deinit(allocator);
    const distribution = response.map.get(provider) orelse return error.NotFound;

    try std.testing.expectEqual(count, distribution.todo);
    try std.testing.expectEqual(0, distribution.completed);
    try std.testing.expectEqual(0, distribution.pending);
    try std.testing.expectEqual(0, distribution.stale);
}

test "Model | Collectors | GetDistribution | Allocation Failures" {
    const allocator = std.testing.allocator;

    const test_env = Tests.test_env;
    const test_name = "Model | Collectors | GetDistribution | Allocation Failures";
    var setup = try TestSetup.init(test_env.database_pool, test_name);
    defer setup.deinit(allocator);

    const count = 10;
    var ids = try allocator.alloc(i64, count);
    var popularity = try allocator.alloc(f64, count);
    defer {
        allocator.free(ids);
        allocator.free(popularity);
    }

    for (0..count) |i| {
        ids[i] = @intCast(i);
        popularity[i] = 0.5;
    }

    const provider = test_name ++ "'s provider";
    {
        const request: Create.Request = .{
            .provider = provider,
            .media_type = .movie,
            .id_list = ids,
            .popularity = popularity,
        };

        try Create.call(
            .{ .database = test_env.database_pool },
            request,
        );
    }

    try std.testing.checkAllAllocationFailures(allocator, struct {
        fn call(alloc: Allocator, conn: Connection) !void {
            const response = try GetDistribution.call(alloc, conn);
            response.deinit(allocator);
        }
    }.call, .{
        Connection{ .database = test_env.database_pool },
    });
}

const MediaType = @import("../content/content.zig").MediaType;

const Conn = @import("pg").Conn;
const Pool = @import("../../database.zig").Pool;
const Connection = @import("../../database.zig").Connection;
const DatabaseErrors = @import("../../database.zig").DatabaseErrors;
const ErrorHandler = @import("../../database.zig").ErrorHandler;

const Tests = @import("../../tests/setup.zig");
const TestSetup = Tests.TestSetup;

const Handler = @import("../../handler.zig");

const Allocator = std.mem.Allocator;
const std = @import("std");
