const log = std.log.scoped(.collectors_model);
pub const Create = struct {
    pub const Request = struct {
        provider: []const u8,
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

pub const GetNotCompleted = struct {
    pub const Request = struct {
        provider: []const u8,
        limit: i32 = 1_000,
    };

    pub const Response = []u8;

    pub const Errors = error{
        CannotGet,
        OutOfMemory,
        CannotParseID,
    } || DatabaseErrors;

    /// Caller must free slice and contents.
    pub fn call(allocator: Allocator, database: *Pool, request: Request) Errors![]Response {
        var conn = database.acquire() catch return error.CannotAcquireConnection;
        defer conn.release();
        var query = conn.queryOpts(
            query_string,
            .{
                request.provider,
                request.limit,
            },
            .{
                .column_names = true,
            },
        ) catch |err| {
            const error_handler = ErrorHandler{ .conn = conn };
            const error_data = error_handler.handle(err);
            if (error_data) |data| {
                ErrorHandler.printErr(data);
            }
            return error.CannotGet;
        };
        defer query.deinit();

        const DatabaseResponse = struct {
            external_id: []u8,
        };
        var mapper = query.mapper(DatabaseResponse, .{ .allocator = allocator });

        var id_list: std.ArrayList([]u8) = .empty;
        errdefer {
            for (id_list.items) |id| allocator.free(id);
            id_list.deinit(allocator);
        }

        while (mapper.next() catch return error.CannotGet) |response| {
            id_list.append(allocator, response.external_id) catch return error.OutOfMemory;
        }

        return id_list.toOwnedSlice(allocator);
    }

    // WARN: this query is not guaranteed to be deterministic
    const query_string =
        \\ UPDATE collectors.list
        \\ SET status = 'pending', updated_at = now()
        \\ WHERE (provider,external_id) IN (
        \\ SELECT provider,external_id
        \\ FROM collectors.list
        \\ WHERE provider = $1
        \\ AND status = 'todo'
        \\ ORDER BY created_at ASC
        \\ LIMIT $2
        \\ FOR UPDATE SKIP LOCKED
        \\ )
        \\ RETURNING external_id;
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
