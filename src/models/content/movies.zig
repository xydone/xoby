const log = std.log.scoped(.movies_model);
pub const Create = struct {
    pub const Request = struct {
        title: []const u8,
        user_id: []const u8,
        release_date: ?[]const u8,
        runtime_minutes: ?u64,
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
        \\   VALUES ($1, $2, $3::date, 'movie')
        \\   RETURNING id, title
        \\ )
        \\ INSERT INTO content.movies (media_id, runtime_minutes)
        \\ VALUES ((SELECT id FROM new_media), $4)
        \\ RETURNING (SELECT id FROM new_media), (SELECT title FROM new_media);
    ;
};

pub const CreateMultiple = struct {
    pub const Request = struct {
        titles: [][]const u8,
        user_id: []const u8,
        release_dates: [][]const u8,
        runtime_minutes: []?i64,
    };

    pub const Errors = error{
        BatchCreateFailed,
        CannotAcquireConnection,
        MismatchedInputLengths,
    } || DatabaseErrors;

    pub fn call(database: *Pool, request: Request) Errors!void {
        // make sure all are of equal length
        const len = request.titles.len;
        if (len == 0) return;
        if (request.release_dates.len != len or request.runtime_minutes.len != len) {
            return error.MismatchedInputLengths;
        }

        var conn = database.acquire() catch return error.CannotAcquireConnection;
        defer conn.release();

        const error_handler = ErrorHandler{ .conn = conn };

        _ = conn.exec(query_string, .{
            request.titles,
            request.user_id,
            request.release_dates,
            request.runtime_minutes,
        }) catch |err| {
            if (error_handler.handle(err)) |data| {
                ErrorHandler.printErr(data);
            }

            return error.BatchCreateFailed;
        };
    }

    const query_string =
        \\ WITH input_rows AS (
        \\ SELECT 
        \\ gen_random_uuid() AS new_id,
        \\ val.title,
        \\ NULLIF(val.rel_date, '')::date AS release_date,
        \\ val.runtime::integer AS runtime
        \\ FROM UNNEST($1::text[], $3::text[], $4::bigint[]) 
        \\ AS val(title, rel_date, runtime)
        \\ ),
        \\ inserted_media AS (
        \\ INSERT INTO content.media_items (id, user_id, title, release_date, media_type)
        \\ SELECT 
        \\ new_id, 
        \\ $2::uuid, 
        \\ title, 
        \\ release_date, 
        \\ 'movie'::content.media_type
        \\ FROM input_rows
        \\ RETURNING id, title
        \\ )
        \\ INSERT INTO content.movies (media_id, runtime_minutes)
        \\ SELECT 
        \\ new_id, 
        \\ runtime
        \\ FROM input_rows
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
