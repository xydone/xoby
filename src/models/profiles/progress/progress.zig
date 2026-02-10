pub const GetAll = struct {
    pub const Request = struct {
        user_id: []const u8,
        limit: u32,
    };

    pub const Response = struct {
        id: []const u8,
        user_id: []const u8,
        media_id: []const u8,
        status: ProgressStatus,
        created_at: i64,

        pub fn deinit(self: Response, allocator: Allocator) void {
            allocator.free(self.id);
            allocator.free(self.user_id);
            allocator.free(self.media_id);
        }
    };

    pub const Errors = error{
        CannotGet,
        OutOfMemory,
        CannotParseID,
    } || DatabaseErrors;

    pub fn call(allocator: std.mem.Allocator, database: *Pool, request: Request) Errors![]Response {
        var conn = database.acquire() catch return error.CannotAcquireConnection;
        defer conn.release();
        const error_handler = ErrorHandler{ .conn = conn };
        var query = conn.queryOpts(
            query_string,
            .{
                request.user_id,
                request.limit,
            },
            .{
                .column_names = true,
            },
        ) catch |err| {
            const error_data = error_handler.handle(err);
            if (error_data) |data| {
                ErrorHandler.printErr(data);
            }
            return error.CannotGet;
        };
        defer query.deinit();

        var responses: std.ArrayList(Response) = .empty;
        defer responses.deinit(allocator);

        var mapper = query.mapper(Response, .{});

        while (mapper.next() catch return error.CannotGet) |response| {
            responses.append(allocator, .{
                .id = try UUID.toStringAlloc(allocator, response.id),
                .user_id = try UUID.toStringAlloc(allocator, response.user_id),
                .media_id = allocator.dupe(u8, response.media_id) catch return error.OutOfMemory,
                .status = response.status,
                .created_at = response.created_at,
            }) catch return error.OutOfMemory;
        }

        return responses.toOwnedSlice(allocator);
    }

    const query_string = @embedFile("queries/get_all_progress.sql");
};

pub const GetAllStatus = struct {
    pub const Request = struct {
        user_id: []const u8,
        status: ProgressStatus,
    };

    pub const Response = struct {
        progress_id: []const u8,
        media_id: []const u8,
        media_title: []const u8,
        media_type: []const u8,
        status: ProgressStatus,
        progress_value: f64,
        completion_percentage: f64,
        progress_unit: ProgressUnit,
        created_at: i64,

        pub fn deinit(self: Response, allocator: Allocator) void {
            allocator.free(self.progress_id);
            allocator.free(self.media_id);
            allocator.free(self.media_title);
            allocator.free(self.media_type);
        }
    };

    pub const Errors = error{
        CannotGet,
        OutOfMemory,
        CannotParseID,
    } || DatabaseErrors;

    pub fn call(allocator: std.mem.Allocator, database: *Pool, request: Request) Errors![]Response {
        var conn = database.acquire() catch return error.CannotAcquireConnection;
        defer conn.release();
        const error_handler = ErrorHandler{ .conn = conn };
        var query = conn.queryOpts(
            query_string,
            .{
                request.user_id,
                request.status,
            },
            .{
                .column_names = true,
            },
        ) catch |err| {
            const error_data = error_handler.handle(err);
            if (error_data) |data| {
                ErrorHandler.printErr(data);
            }
            return error.CannotGet;
        };
        defer query.deinit();

        var responses: std.ArrayList(Response) = .empty;
        defer responses.deinit(allocator);

        var mapper = query.mapper(Response, .{});

        while (mapper.next() catch return error.CannotGet) |response| {
            responses.append(allocator, .{
                .progress_id = try UUID.toStringAlloc(allocator, response.progress_id),
                .media_id = allocator.dupe(u8, response.media_id) catch return error.OutOfMemory,
                .status = response.status,
                .media_title = try allocator.dupe(u8, response.media_title),
                .media_type = try allocator.dupe(u8, response.media_type),
                .progress_value = response.progress_value,
                .completion_percentage = response.completion_percentage,
                .progress_unit = response.progress_unit,
                .created_at = response.created_at,
            }) catch return error.OutOfMemory;
        }

        return responses.toOwnedSlice(allocator);
    }

    const query_string = @embedFile("queries/get_all_status.sql");
};

/// Turns a letterboxd list into a progress entry.
/// Tries to match by [name,year] but if year is null, tries to match name only
pub const ImportLetterboxd = struct {
    pub const Request = struct {
        user_id: []const u8,
        titles: [][]const u8,
        created_at: [][]const u8,
        uris: [][]const u8,
        status: ProgressStatus,
        years: []?i64,
    };

    /// the movies that were not imported, due to either 0 movies that matched or more than 1 movies that matched
    pub const Response = struct {
        title: []const u8,
        release_year: ?i64,
        reason: []const u8,

        pub fn deinit(self: @This(), allocator: Allocator) void {
            allocator.free(self.title);
            allocator.free(self.reason);
        }
    };

    pub const Errors = error{
        CannotCreate,
        OutOfMemory,
        CannotParseID,
    } || DatabaseErrors;

    pub fn call(allocator: std.mem.Allocator, connection: Connection, request: Request) Errors![]Response {
        assertAllSameLength(request, .{ "titles", "years", "created_at" });
        var conn = try connection.acquire();
        defer connection.release(conn);
        const error_handler = ErrorHandler{ .conn = conn };
        var query = conn.queryOpts(
            query_string,
            .{
                request.titles,
                request.years,
                request.created_at,
                request.uris,
                request.user_id,
                request.status,
                "letterboxd",
            },
            .{
                .column_names = true,
            },
        ) catch |err| {
            const error_data = error_handler.handle(err);
            if (error_data) |data| {
                ErrorHandler.printErr(data);
            }
            return error.CannotCreate;
        };
        defer query.deinit();

        var responses: std.ArrayList(Response) = .empty;
        defer responses.deinit(allocator);

        var mapper = query.mapper(Response, .{});

        while (mapper.next() catch return error.CannotCreate) |response| {
            responses.append(allocator, .{
                .title = allocator.dupe(u8, response.title) catch return error.OutOfMemory,
                .release_year = response.release_year,
                .reason = allocator.dupe(u8, response.reason) catch return error.OutOfMemory,
            }) catch return error.OutOfMemory;
        }

        return responses.toOwnedSlice(allocator);
    }

    const query_string = @embedFile("queries/import_letterboxd_progress.sql");
};

const assertAllSameLength = @import("../../../util/assertSameLength.zig").assertAllSameLength;
const Connection = @import("../../../database.zig").Connection;
const Pool = @import("../../../database.zig").Pool;
const DatabaseErrors = @import("../../../database.zig").DatabaseErrors;
const ErrorHandler = @import("../../../database.zig").ErrorHandler;

const Tests = @import("../../../tests/setup.zig");
const TestSetup = Tests.TestSetup;

const ProgressStatus = @import("../../content/media.zig").ProgressStatus;
const ProgressUnit = @import("../../content/media.zig").ProgressUnit;

const UUID = @import("../../../util/uuid.zig");

const Allocator = std.mem.Allocator;
const std = @import("std");
