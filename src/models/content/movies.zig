pub const Create = struct {
    pub const Request = struct {
        title: []const u8,
        user_id: i64,
        release_date: ?[]const u8,
        director: []const u8,
        runtime_minutes: u64,
        studio: []const u8,
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
            request.director,
            request.runtime_minutes,
            request.studio,
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

        const title = allocator.dupe(u8, row.get([]u8, 1)) catch return error.OutOfMemory;

        return Response{
            .id = id,
            .title = title,
        };
    }

    const query_string =
        \\ WITH new_media AS (
        \\   INSERT INTO content.media_items (title, user_id, release_date, media_type)
        \\   VALUES ($1, $2, $3::date, 'movie')
        \\   RETURNING id, title
        \\ )
        \\ INSERT INTO content.movies (media_id, director, runtime_minutes, studio)
        \\ VALUES ((SELECT id FROM new_media), $4, $5, $6)
        \\ RETURNING (SELECT id FROM new_media), (SELECT title FROM new_media);
    ;
};

const Tests = @import("../../tests/setup.zig");
const TestSetup = Tests.TestSetup;

const Pool = @import("../../database.zig").Pool;
const DatabaseErrors = @import("../../database.zig").DatabaseErrors;
const ErrorHandler = @import("../../database.zig").ErrorHandler;

const Handler = @import("../../handler.zig");

const UUID = @import("../../util/uuid.zig");
const JWTClaims = @import("../../auth/tokens.zig").JWTClaims;

const Allocator = std.mem.Allocator;
const std = @import("std");
