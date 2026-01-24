pub const MediaType = enum {
    movie,
    book,
    comic,
    manga,
};

pub const Media = @import("media.zig");
pub const Books = @import("books.zig");
pub const Movies = @import("movies.zig");

const log = std.log.scoped(.content_model);

pub const CreateStaff = struct {
    pub const Request = struct {
        full_name: []const u8,
        bio: ?[]const u8,
        provider: []const u8,
        external_id: []const u8,
        media_id: []const u8,
        role_name: []const u8,
    };

    const Response = struct {
        id: []u8,
        pub fn deinit(self: @This(), allocator: Allocator) void {
            allocator.free(self.id);
        }
    };

    pub const Errors = error{
        CouldntCreate,
        CannotAcquireConnection,
        MismatchedInputLengths,
    } || DatabaseErrors;

    pub fn call(allocator: Allocator, database: *Pool, request: Request) Errors!Response {
        var conn = database.acquire() catch return error.CannotAcquireConnection;
        defer conn.release();

        const error_handler = ErrorHandler{ .conn = conn };

        const row = conn.row(query_string, .{
            request.full_name,
            request.bio,
            request.provider,
            request.external_id,
        }) catch |err| {
            if (error_handler.handle(err)) |data| {
                ErrorHandler.printErr(data);
            }

            return error.CouldntCreate;
        } orelse return error.CouldntCreate;

        const id = row.to([]u8, 0) catch return error.CouldntCreate;

        return .{
            .id = UUID.toStringAlloc(allocator, id) catch return error.OutOfMemory,
        };
    }

    const query_string = @embedFile("./queries/create_staff.sql");
};

pub const CreateMultiplePeople = struct {
    pub const Request = struct {
        full_names: [][]const u8,
        bios: []?[]const u8,
        provider: [][]const u8,
        external_ids: [][]const u8,
    };

    const Response = struct {
        external_id: []const u8,
        person_id: []const u8,

        pub fn deinit(self: @This(), allocator: Allocator) void {
            allocator.free(self.external_id);
            allocator.free(self.person_id);
        }
    };

    pub const Errors = error{
        CouldntCreate,
        CannotAcquireConnection,
        MismatchedInputLengths,
        OutOfMemory,
    } || DatabaseErrors;

    pub fn call(allocator: Allocator, database: *Pool, request: Request) Errors![]Response {
        var conn = database.acquire() catch return error.CannotAcquireConnection;
        defer conn.release();

        const error_handler = ErrorHandler{ .conn = conn };

        var query = conn.query(query_string, .{
            request.full_names,
            request.bios,
            request.provider,
            request.external_ids,
        }) catch |err| {
            if (error_handler.handle(err)) |data| {
                ErrorHandler.printErr(data);
            }
            return error.CouldntCreate;
        };
        defer query.deinit();

        var responses = std.ArrayList(Response).empty;
        defer responses.deinit(allocator);

        while (query.next() catch return error.CouldntCreate) |row| {
            const person_id = UUID.toStringAlloc(allocator, row.get([]u8, 0)) catch return error.CouldntCreate;
            const external_id = row.get([]u8, 1);

            try responses.append(allocator, .{
                .external_id = try allocator.dupe(u8, external_id),
                .person_id = person_id,
            });
        }

        return responses.toOwnedSlice(allocator);
    }

    const query_string = @embedFile("./queries/create_multiple_people.sql");
};

pub const CreateMultipleMediaStaff = struct {
    pub const Request = struct {
        person_ids: [][]const u8,
        media_ids: [][]const u8,
        role_names: [][]const u8,
    };

    const Response = void;

    pub const Errors = error{
        CouldntCreate,
        CannotAcquireConnection,
        MismatchedInputLengths,
    } || DatabaseErrors;

    pub fn call(database: *Pool, request: Request) Errors!Response {
        var conn = database.acquire() catch return error.CannotAcquireConnection;
        defer conn.release();

        const error_handler = ErrorHandler{ .conn = conn };

        _ = conn.exec(query_string, .{
            request.media_ids,
            request.person_ids,
            request.role_names,
        }) catch |err| {
            if (error_handler.handle(err)) |data| {
                ErrorHandler.printErr(data);
            }

            return error.CouldntCreate;
        } orelse return error.CouldntCreate;
    }

    const query_string = @embedFile("./queries/create_multiple_media_staff.sql");
};

const Pool = @import("../../database.zig").Pool;

const DatabaseErrors = @import("../../database.zig").DatabaseErrors;
const ErrorHandler = @import("../../database.zig").ErrorHandler;

const UUID = @import("../../util/uuid.zig");

const Allocator = std.mem.Allocator;
const std = @import("std");
