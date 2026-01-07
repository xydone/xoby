const log = std.log.scoped(.media_model);

pub const ProgressStatus = enum {
    planned,
    in_progress,
    completed,
    dropped,
};

pub const CreateRating = struct {
    pub const Request = struct {
        user_id: []const u8,
        media_id: []const u8,
        /// [0,10]
        rating_score: u8,
    };

    pub const Response = struct {
        id: []const u8,

        pub fn deinit(self: Response, allocator: Allocator) void {
            allocator.free(self.id);
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
            request.user_id,
            request.media_id,
            request.rating_score,
        }) catch |err| {
            const error_data = error_handler.handle(err);
            if (error_data) |data| {
                ErrorHandler.printErr(data);
            }
            return error.CannotCreate;
        } orelse return error.CannotCreate;
        defer row.deinit() catch {};

        const id = blk: {
            const buf = UUID.toString(row.get([]u8, 0)) catch return error.CannotParseID;
            break :blk allocator.dupe(u8, &buf) catch return error.OutOfMemory;
        };

        return Response{
            .id = id,
        };
    }

    const query_string =
        \\ INSERT INTO profiles.ratings (user_id, media_id, rating_score)
        \\ VALUES ($1, $2, $3)
        \\ RETURNING id;
    ;
};

pub const GetRating = struct {
    pub const Request = struct {
        user_id: []const u8,
        media_id: []const u8,
    };

    pub const Response = struct {
        id: []const u8,
        rating_score: u8,
        created_at: i64,

        pub fn deinit(self: Response, allocator: Allocator) void {
            allocator.free(self.id);
        }
    };

    pub const Errors = error{
        CannotGet,
        NotFound,
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
                request.media_id,
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

        // NOTE: needed as rating_score validation is done on the server and not in the database
        const DatabaseResponse = struct {
            id: []u8,
            rating_score: i32,
            created_at: i64,
        };

        var responses: std.ArrayList(Response) = .empty;
        defer responses.deinit(allocator);

        var mapper = query.mapper(DatabaseResponse, .{});
        while (mapper.next() catch return error.CannotGet) |response| {
            responses.append(allocator, .{
                .id = blk: {
                    const buf = UUID.toString(response.id) catch return error.CannotParseID;
                    break :blk allocator.dupe(u8, &buf) catch return error.OutOfMemory;
                },
                .created_at = response.created_at,
                .rating_score = std.math.cast(u8, response.rating_score) orelse return error.InvalidRatingScore,
            }) catch return error.OutOfMemory;
        }

        return responses.toOwnedSlice(allocator) catch return error.OutOfMemory;
    }

    const query_string =
        \\ SELECT id, rating_score, created_at
        \\ FROM profiles.ratings
        \\ WHERE user_id = $1 AND media_id = $2;
    ;
};

pub const EditRating = struct {
    pub const Request = struct {
        user_id: []const u8,
        rating_id: []const u8,
        /// [0,10]
        rating_score: u8,
    };

    pub const Response = struct {
        id: []const u8,
        rating_score: u8,
        created_at: i64,

        pub fn deinit(self: Response, allocator: Allocator) void {
            allocator.free(self.id);
        }
    };

    pub const Errors = error{
        CannotEdit,
        NotFound,
        InvalidRatingScore,
        OutOfMemory,
        CannotParseID,
    } || DatabaseErrors;

    pub fn call(allocator: std.mem.Allocator, database: *Pool, request: Request) Errors!Response {
        var conn = database.acquire() catch return error.CannotAcquireConnection;
        defer conn.release();
        const error_handler = ErrorHandler{ .conn = conn };
        var row = conn.rowOpts(query_string, .{
            request.rating_id,
            request.user_id,
            request.rating_score,
        }, .{
            .column_names = true,
        }) catch |err| {
            const error_data = error_handler.handle(err);
            if (error_data) |data| {
                ErrorHandler.printErr(data);
            }
            return error.CannotEdit;
        } orelse return error.NotFound;
        defer row.deinit() catch {};

        // NOTE: needed as rating_score validation is done on the server and not in the database
        const DatabaseResponse = struct {
            id: []u8,
            rating_score: i32,
            created_at: i64,
        };

        var response = row.to(DatabaseResponse, .{
            .map = .name,
        }) catch |err| {
            log.err("Get Rating row.to failed! {}", .{err});
            return error.CannotEdit;
        };

        response.id = blk: {
            const buf = UUID.toString(response.id) catch return error.CannotParseID;
            break :blk allocator.dupe(u8, &buf) catch return error.OutOfMemory;
        };

        return Response{
            .id = response.id,
            .rating_score = std.math.cast(u8, response.rating_score) orelse return error.InvalidRatingScore,
            .created_at = response.created_at,
        };
    }

    const query_string =
        \\ UPDATE profiles.ratings
        \\ SET 
        \\ rating_score = $3,
        \\ created_at = now()
        \\ WHERE id = $1 AND user_id = $2
        \\ RETURNING *;
    ;
};

pub const CreateProgress = struct {
    pub const Request = struct {
        user_id: []const u8,
        media_id: []const u8,
        status: ProgressStatus,
        progress_value: i32,
    };

    pub const Response = struct {
        id: []const u8,
        user_id: []const u8,
        media_id: []const u8,
        status: ProgressStatus,
        progress_value: i32,
        created_at: i64,

        pub fn deinit(self: Response, allocator: Allocator) void {
            allocator.free(self.id);
            allocator.free(self.user_id);
            allocator.free(self.media_id);
        }
    };

    pub const Errors = error{
        CannotCreate,
        OutOfMemory,
        CannotParseID,
    } || DatabaseErrors;

    pub fn call(allocator: Allocator, database: *Pool, request: Request) Errors!Response {
        var conn = database.acquire() catch return error.CannotAcquireConnection;
        defer conn.release();

        const error_handler = ErrorHandler{ .conn = conn };
        var row = conn.rowOpts(query_string, .{
            request.user_id,
            request.media_id,
            request.status,
            request.progress_value,
        }, .{
            .column_names = true,
        }) catch |err| {
            const error_data = error_handler.handle(err);
            if (error_data) |data| {
                ErrorHandler.printErr(data);
            }

            return error.CannotCreate;
        } orelse return error.CannotCreate;
        defer row.deinit() catch {};

        var response = row.to(Response, .{ .map = .name }) catch |err| {
            log.err("Failed to parse progress response! {}", .{err});
            return error.CannotCreate;
        };

        response.id = blk: {
            const buf = UUID.toString(response.id) catch return error.CannotParseID;
            break :blk allocator.dupe(u8, &buf) catch return error.OutOfMemory;
        };

        response.media_id = blk: {
            const buf = UUID.toString(response.media_id) catch return error.CannotParseID;
            break :blk allocator.dupe(u8, &buf) catch return error.OutOfMemory;
        };

        response.user_id = blk: {
            const buf = UUID.toString(response.user_id) catch return error.CannotParseID;
            break :blk allocator.dupe(u8, &buf) catch return error.OutOfMemory;
        };

        return response;
    }

    const query_string =
        \\ INSERT INTO profiles.progress (user_id, media_id, status, progress_value)
        \\ VALUES ($1, $2, $3, $4)
        \\ RETURNING *;
    ;
};

pub const GetProgress = struct {
    pub const Request = struct {
        user_id: []const u8,
        media_id: []const u8,
    };

    pub const Response = struct {
        user_id: []const u8,
        media_id: []const u8,
        status: []const u8,
        progress_value: i32,
        updated_at: i64,

        pub fn deinit(self: Response, allocator: std.mem.Allocator) void {
            allocator.free(self.user_id);
            allocator.free(self.media_id);
            allocator.free(self.status);
        }
    };

    pub const Errors = error{
        CannotGet,
        NotFound,
        OutOfMemory,
        CannotParseID,
    } || DatabaseErrors;

    pub fn call(allocator: std.mem.Allocator, database: *Pool, request: Request) Errors!Response {
        var conn = database.acquire() catch return error.CannotAcquireConnection;
        defer conn.release();
        const error_handler = ErrorHandler{ .conn = conn };
        var row = conn.row(query_string, .{
            request.user_id,
            request.media_id,
        }) catch |err| {
            const error_data = error_handler.handle(err);
            if (error_data) |data| {
                ErrorHandler.printErr(data);
            }
            return error.CannotGet;
        } orelse return error.NotFound;
        defer row.deinit() catch {};

        var response = row.to(Response, .{ .allocator = allocator }) catch return error.CannotGet;

        response.media_id = blk: {
            const buf = UUID.toString(response.media_id) catch return error.CannotParseID;
            break :blk allocator.dupe(u8, &buf) catch return error.OutOfMemory;
        };

        return response;
    }

    const query_string =
        \\ SELECT * 
        \\ FROM profiles.progress
        \\ WHERE user_id = $1 AND media_id = $2
        \\ ORDER BY created_at DESC
        \\ LIMIT 1;
    ;
};

const Pool = @import("../../database.zig").Pool;
const DatabaseErrors = @import("../../database.zig").DatabaseErrors;
const ErrorHandler = @import("../../database.zig").ErrorHandler;

const Handler = @import("../../handler.zig");

const UUID = @import("../../util/uuid.zig");
const JWTClaims = @import("../../auth/tokens.zig").JWTClaims;

const Allocator = std.mem.Allocator;
const std = @import("std");
