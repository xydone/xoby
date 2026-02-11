// TODO: test
pub const CreateMultiple = struct {
    pub const Request = struct {
        title: [][]const u8,
        release_date: []?[]const u8,
        description: []?[]const u8,
        total_chapters: []?i32,
        user_id: []const u8,
        providers: [][]const u8,
        external_ids: [][]const u8,
    };

    pub const Response = struct {
        ids: [][]u8,

        pub fn deinit(self: @This(), allocator: Allocator) void {
            for (self.ids) |id| allocator.free(id);
            allocator.free(self.ids);
        }
    };

    pub const Errors = error{
        CannotCreate,
        OutOfMemory,
        CannotParseID,
    } || DatabaseErrors;

    pub fn call(allocator: std.mem.Allocator, connection: Connection, request: Request) Errors!Response {
        assertSameLength(request, .{ "title", "release_date", "description", "total_chapters" });
        var conn = try connection.acquire();
        defer connection.release(conn);
        const error_handler = ErrorHandler{ .conn = conn };
        var query = conn.query(query_string, .{
            request.title,
            request.release_date,
            request.description,
            request.total_chapters,
            request.user_id,
            request.providers,
            request.external_ids,
        }) catch |err| {
            const error_data = error_handler.handle(err);
            if (error_data) |data| {
                ErrorHandler.printErr(data);
            }
            return error.CannotCreate;
        };
        defer query.deinit();

        var ids: std.ArrayList([]u8) = try .initCapacity(allocator, request.title.len);
        defer ids.deinit(allocator);

        while (query.next() catch return error.CannotCreate) |row| {
            const id = try UUID.toStringAlloc(allocator, row.get([]u8, 0));

            ids.append(allocator, id) catch return error.OutOfMemory;
        }

        return Response{
            .ids = ids.toOwnedSlice(allocator) catch return error.OutOfMemory,
        };
    }

    const query_string = @embedFile("queries/create_many.sql");
};

const Pool = @import("../../../database.zig").Pool;
const Connection = @import("../../../database.zig").Connection;
const DatabaseErrors = @import("../../../database.zig").DatabaseErrors;
const ErrorHandler = @import("../../../database.zig").ErrorHandler;

const Handler = @import("../../../handler.zig");

const UUID = @import("../../../util/uuid.zig");
const JWTClaims = @import("../../../auth/tokens.zig").JWTClaims;

const assertSameLength = @import("../../../util/assertSameLength.zig").assertAllSameLength;

const Allocator = std.mem.Allocator;
const std = @import("std");
