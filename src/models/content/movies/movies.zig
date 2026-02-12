const log = std.log.scoped(.movies_model);
// TODO: test
pub const Create = struct {
    pub const Request = struct {
        title: []const u8,
        user_id: []const u8,
        release_date: ?[]const u8,
        runtime_minutes: ?u64,
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

    pub fn call(allocator: std.mem.Allocator, database: *Pool, request: Request) Errors!Response {
        var conn = database.acquire() catch return error.CannotAcquireConnection;
        defer conn.release();
        const error_handler = ErrorHandler{ .conn = conn };
        var row = conn.row(query_string, .{
            request.title,
            request.user_id,
            request.release_date,
            request.runtime_minutes,
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

        const title = allocator.dupe(u8, row.get([]u8, 1)) catch return error.OutOfMemory;

        return Response{
            .id = id,
            .title = title,
        };
    }

    const query_string = @embedFile("queries/create.sql");
};

// TODO: test
pub const CreateMultiple = struct {
    pub const Request = struct {
        titles: [][]const u8,
        user_id: []const u8,
        release_dates: [][]const u8,
        runtime_minutes: []?i64,
        descriptions: []?[]const u8,
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
        CreateFailed,
        RequestTooShort,
        OutOfMemory,
        CannotAcquireConnection,
        MismatchedInputLengths,
    } || DatabaseErrors;

    pub fn call(allocator: Allocator, connection: Connection, request: Request) Errors!Response {
        const len = request.titles.len;
        if (len == 0) return error.RequestTooShort;
        if (request.release_dates.len != len or request.runtime_minutes.len != len or request.descriptions.len != len) {
            return error.MismatchedInputLengths;
        }

        var conn = try connection.acquire();
        defer connection.release(conn);

        const error_handler = ErrorHandler{ .conn = conn };

        const query = conn.query(query_string, .{
            request.titles,
            request.user_id,
            request.release_dates,
            request.runtime_minutes,
            request.descriptions,
            request.providers,
            request.external_ids,
        }) catch |err| {
            if (error_handler.handle(err)) |data| {
                ErrorHandler.printErr(data);
            }
            log.err("Query failed!", .{});

            return error.CreateFailed;
        };
        defer query.deinit();

        var ids = std.ArrayList([]u8).initCapacity(allocator, request.titles.len) catch return error.OutOfMemory;
        defer ids.deinit(allocator);

        while (query.next() catch return error.CreateFailed) |row| {
            const id = row.get([]u8, 0);
            ids.append(allocator, UUID.toStringAlloc(allocator, id) catch return error.OutOfMemory) catch return error.OutOfMemory;
        }

        return .{
            .ids = ids.toOwnedSlice(allocator) catch return error.OutOfMemory,
        };
    }

    const query_string = @embedFile("queries/create_multiple_movies.sql");
};

const Tests = @import("../../../tests/setup.zig");
const TestSetup = Tests.TestSetup;

const Pool = @import("../../../database.zig").Pool;
const Connection = @import("../../../database.zig").Connection;
const DatabaseErrors = @import("../../../database.zig").DatabaseErrors;
const ErrorHandler = @import("../../../database.zig").ErrorHandler;

const Handler = @import("../../../handler.zig");

const UUID = @import("../../../util/uuid.zig");
const JWTClaims = @import("../../../auth/tokens.zig").JWTClaims;

const Allocator = std.mem.Allocator;
const std = @import("std");
