// TODO: test
pub const Get = struct {
    pub const Request = struct {
        user_id: []const u8,
    };

    pub const Response = struct {
        id: []const u8,
        user_id: []const u8,
        media_id: []const u8,
        rating_score: u8,
        created_at: i64,

        pub fn deinit(self: Response, allocator: Allocator) void {
            allocator.free(self.id);
            allocator.free(self.user_id);
            allocator.free(self.media_id);
        }
    };

    pub const Errors = error{
        CannotGet,
        InvalidRatingScore,
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

        const DatabaseResponse = struct {
            id: []const u8,
            user_id: []const u8,
            media_id: []const u8,
            // need to do this due to manual parsing of the rating score
            rating_score: i32,
            created_at: i64,
        };

        var mapper = query.mapper(DatabaseResponse, .{});

        while (mapper.next() catch return error.CannotGet) |response| {
            responses.append(allocator, .{
                .id = try UUID.toStringAlloc(allocator, response.id),
                .user_id = try UUID.toStringAlloc(allocator, response.user_id),
                .media_id = allocator.dupe(u8, response.media_id) catch return error.OutOfMemory,
                .rating_score = std.math.cast(u8, response.rating_score) orelse return error.InvalidRatingScore,
                .created_at = response.created_at,
            }) catch return error.OutOfMemory;
        }

        return responses.toOwnedSlice(allocator);
    }

    const query_string = @embedFile("queries/get_ratings.sql");
};

// TODO: test
/// Tries to match by [name,year] but if year is null, tries to match name only
pub const ImportLetterboxd = struct {
    pub const Request = struct {
        user_id: []const u8,
        titles: [][]const u8,
        years: []?i64,
        items_created_at: [][]const u8,
        ratings: []i32,
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
        assertAllSameLength(request, .{ "titles", "years", "items_created_at", "ratings" });
        var conn = try connection.acquire();
        defer connection.release(conn);
        const error_handler = ErrorHandler{ .conn = conn };

        var query = conn.queryOpts(
            query_string,
            .{
                request.user_id,
                request.titles,
                request.years,
                request.items_created_at,
                request.ratings,
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

    const query_string = @embedFile("queries/import_letterboxd_ratings.sql");
};

const assertAllSameLength = @import("../../../util/assertSameLength.zig").assertAllSameLength;

const Connection = @import("../../../database.zig").Connection;
const Pool = @import("../../../database.zig").Pool;
const DatabaseErrors = @import("../../../database.zig").DatabaseErrors;
const ErrorHandler = @import("../../../database.zig").ErrorHandler;

const Tests = @import("../../../tests/setup.zig");
const TestSetup = Tests.TestSetup;

const ProgressStatus = @import("../../content/content.zig").Media.ProgressStatus;
const ProgressUnit = @import("../../content/content.zig").Media.ProgressUnit;

const UUID = @import("../../../util/uuid.zig");

const Allocator = std.mem.Allocator;
const std = @import("std");
