const log = std.log.scoped(.collectors_model);
pub const Create = struct {
    pub const Request = struct {
        provider: []u8,
        id_list: []i64,
        media_type: MediaType,
    };

    pub const Errors = error{
        CannotCreate,
        OutOfMemory,
        CannotParseID,
    } || DatabaseErrors;

    pub fn call(database: *Pool, request: Request) Errors!void {
        var conn = database.acquire() catch return error.CannotAcquireConnection;
        defer conn.release();
        _ = conn.exec(
            query_string,
            .{
                request.provider,
                request.id_list,
                request.media_type,
            },
        ) catch |err| {
            const error_handler = ErrorHandler{ .conn = conn };
            const error_data = error_handler.handle(err);
            if (error_data) |data| {
                ErrorHandler.printErr(data);
            }
        };
    }

    const query_string =
        \\ INSERT INTO collectors.list (provider, external_id, media_type)
        \\ SELECT $1, unnest($2::bigint[]), $3
        \\ ON CONFLICT DO NOTHING
    ;
};

const MediaType = @import("../content/content.zig").MediaType;

const Conn = @import("pg").Conn;
const Pool = @import("../../database.zig").Pool;
const DatabaseErrors = @import("../../database.zig").DatabaseErrors;
const ErrorHandler = @import("../../database.zig").ErrorHandler;

const Handler = @import("../../handler.zig");

const Allocator = std.mem.Allocator;
const std = @import("std");
