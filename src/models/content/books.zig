pub const Create = struct {
    pub const Request = struct {
        title: []const u8,
        user_id: []const u8,
        release_date: ?[]const u8,
        page_count: ?i32,
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
            request.page_count,
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

    const query_string =
        \\ WITH new_media AS (
        \\   INSERT INTO content.media_items (title, user_id, release_date, media_type)
        \\   VALUES ($1, $2, $3::date, 'book')
        \\   RETURNING id, title
        \\ )
        \\ INSERT INTO content.books (media_id, page_count)
        \\ VALUES ((SELECT id FROM new_media), $4)
        \\ RETURNING (SELECT id FROM new_media), (SELECT title FROM new_media);
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
