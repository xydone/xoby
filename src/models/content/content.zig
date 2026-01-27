pub const MediaType = enum {
    movie,
    book,
    comic,
    manga,
};

pub const ImageType = enum {
    backdrop,
    logo,
    poster,
};

pub const Media = @import("media.zig");
pub const Books = @import("books.zig");
pub const Movies = @import("movies.zig");

const log = std.log.scoped(.content_model);

pub const CreateMultiplePeople = struct {
    pub const Request = struct {
        full_names: [][]const u8,
        bios: []?[]const u8,
        provider: [][]const u8,
        external_ids: [][]const u8,
    };

    pub const Response = struct {
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

    pub fn call(allocator: Allocator, connection: Connection, request: Request) Errors![]Response {
        var conn = try connection.acquire();
        defer connection.release(conn);

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
        character_names: []?[]const u8,
    };

    const Response = void;

    pub const Errors = error{
        CouldntCreate,
        CannotAcquireConnection,
        MismatchedInputLengths,
    } || DatabaseErrors;

    pub fn call(connection: Connection, request: Request) Errors!Response {
        var conn = try connection.acquire();
        defer connection.release(conn);

        const error_handler = ErrorHandler{ .conn = conn };

        _ = conn.exec(query_string, .{
            request.media_ids,
            request.person_ids,
            request.role_names,
            request.character_names,
        }) catch |err| {
            if (error_handler.handle(err)) |data| {
                ErrorHandler.printErr(data);
            }

            return error.CouldntCreate;
        } orelse return error.CouldntCreate;
    }

    const query_string = @embedFile("./queries/create_multiple_media_staff.sql");
};

pub const CreateMultipleImages = struct {
    pub const Request = struct {
        media_ids: [][]const u8,
        image_type: []ImageType,
        width: []i32,
        height: []i32,
        provider_id: [][]const u8,
        path: [][]const u8,
        is_primary: []bool,
    };

    const Response = void;

    pub const Errors = error{
        CouldntCreate,
        CannotAcquireConnection,
        MismatchedInputLengths,
    } || DatabaseErrors;

    pub fn call(connection: Connection, request: Request) Errors!Response {
        var conn = try connection.acquire();
        defer connection.release(conn);

        const error_handler = ErrorHandler{ .conn = conn };

        _ = conn.exec(query_string, .{
            request.media_ids,
            request.image_type,
            request.width,
            request.height,
            request.provider_id,
            request.path,
            request.is_primary,
        }) catch |err| {
            if (error_handler.handle(err)) |data| {
                ErrorHandler.printErr(data);
            }

            return error.CouldntCreate;
        } orelse return error.CouldntCreate;
    }

    const query_string = @embedFile("./queries/create_multiple_images.sql");
};

pub const CreateMultipleGenres = struct {
    pub const Request = struct {
        media_ids: [][]const u8,
        names: [][]const u8,
    };

    const Response = void;

    pub const Errors = error{
        CouldntCreate,
        CannotAcquireConnection,
        MismatchedInputLengths,
    } || DatabaseErrors;

    pub fn call(connection: Connection, request: Request) Errors!Response {
        var conn = try connection.acquire();
        defer connection.release(conn);

        const error_handler = ErrorHandler{ .conn = conn };

        _ = conn.exec(query_string, .{
            request.media_ids,
            request.names,
        }) catch |err| {
            if (error_handler.handle(err)) |data| {
                ErrorHandler.printErr(data);
            }

            return error.CouldntCreate;
        } orelse return error.CouldntCreate;
    }

    const query_string = @embedFile("./queries/create_multiple_genres.sql");
};

const Pool = @import("../../database.zig").Pool;
const Connection = @import("../../database.zig").Connection;

const DatabaseErrors = @import("../../database.zig").DatabaseErrors;
const ErrorHandler = @import("../../database.zig").ErrorHandler;

const UUID = @import("../../util/uuid.zig");

const Allocator = std.mem.Allocator;
const std = @import("std");
