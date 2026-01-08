const log = std.log.scoped(.profiles_model);

pub const CreateList = struct {
    pub const Request = struct {
        user_id: []const u8,
        name: []const u8,
        is_public: bool,
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
            request.name,
            request.is_public,
        }) catch |err| {
            const error_data = error_handler.handle(err);
            if (error_data) |data| {
                ErrorHandler.printErr(data);
            }
            return error.CannotCreate;
        } orelse return error.CannotCreate;
        defer row.deinit() catch {};

        const id = try UUID.toStringAlloc(allocator, row.get([]u8, 0));

        return Response{
            .id = id,
        };
    }

    const query_string =
        \\ INSERT INTO profiles.lists (user_id, name, is_public)
        \\ VALUES ($1, $2, $3)
        \\ RETURNING id;
    ;
};

pub const GetList = struct {
    pub const Request = struct {
        user_id: []const u8,
        list_id: []const u8,
    };

    pub const Response = struct {
        id: []const u8,
        user_id: []const u8,
        name: []const u8,
        is_public: bool,
        created_at: i64,
        items: []Item,

        pub const Item = struct {
            media_id: []const u8,

            pub fn deinit(self: Item, allocator: Allocator) void {
                allocator.free(self.media_id);
            }
        };

        pub fn deinit(self: Response, allocator: Allocator) void {
            defer allocator.free(self.items);
            allocator.free(self.id);
            allocator.free(self.user_id);
            allocator.free(self.name);
            for (self.items) |item| {
                item.deinit(allocator);
            }
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
        var row = conn.rowOpts(
            query_string,
            .{
                request.user_id,
                request.list_id,
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
        } orelse return error.NotFound;
        defer row.deinit() catch {};

        const DatabaseResponse = struct {
            id: []const u8,
            user_id: []const u8,
            name: []const u8,
            is_public: bool,
            created_at: i64,
            // have to do this in order to parse the json
            items: []u8,
        };

        const database_response = row.to(
            DatabaseResponse,
            .{ .map = .name },
        ) catch |err| {
            log.err("GetList failed to parse row! {}", .{err});
            return error.CannotGet;
        };

        // TODO: does this leak when used with a non arena allocator?
        const items = std.json.parseFromSliceLeaky(
            []Response.Item,
            allocator,
            database_response.items,
            .{
                .allocate = .alloc_always,
            },
        ) catch |err| {
            log.err("GetList failed to parse json! {}", .{err});
            return error.CannotGet;
        };

        return Response{
            .id = try UUID.toStringAlloc(allocator, database_response.id),
            .user_id = try UUID.toStringAlloc(allocator, database_response.user_id),
            .name = database_response.name,
            .is_public = database_response.is_public,
            .created_at = database_response.created_at,
            .items = items,
        };
    }

    const query_string =
        \\ SELECT 
        \\ l.*,
        \\ COALESCE(
        \\ json_agg(
        \\ json_build_object(
        \\ 'media_id', li.media_id
        \\ )
        \\ ) FILTER (WHERE li.media_id IS NOT NULL), 
        \\ '[]'
        \\ ) AS items
        \\ FROM profiles.lists l
        \\ LEFT JOIN profiles.lists_items li ON l.id = li.list_id
        \\ WHERE l.id = $2 
        \\ AND (l.user_id = $1 OR l.is_public = true)
        \\ GROUP BY l.id;
    ;
};

const Pool = @import("../../database.zig").Pool;
const DatabaseErrors = @import("../../database.zig").DatabaseErrors;
const ErrorHandler = @import("../../database.zig").ErrorHandler;

const UUID = @import("../../util/uuid.zig");

const Allocator = std.mem.Allocator;
const std = @import("std");
