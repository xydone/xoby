pub const Create = struct {
    pub const Request = struct {
        user_id: []const u8,
        media_id: []const u8,
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
        InvalidRatingScore,
        OutOfMemory,
        CannotParseID,
    } || DatabaseErrors;

    pub fn call(allocator: std.mem.Allocator, connection: Connection, request: Request) Errors!Response {
        var conn = try connection.acquire();
        defer connection.release(conn);
        const error_handler = ErrorHandler{ .conn = conn };
        var row = conn.rowOpts(
            query_string,
            .{
                request.user_id,
                request.media_id,
                request.rating_score,
            },
            .{},
        ) catch |err| {
            const error_data = error_handler.handle(err);
            if (error_data) |data| {
                ErrorHandler.printErr(data);
            }
            return error.CannotCreate;
        } orelse return error.CannotCreate;
        defer row.deinit() catch {};

        const id = try UUID.toStringAlloc(allocator, row.get([]u8, 0));
        errdefer allocator.free(id);

        return .{
            .id = id,
        };
    }

    const query_string = @embedFile("queries/create.sql");
};

test "Model | Profile | Ratings | Create" {
    const allocator = std.testing.allocator;

    const test_env = Tests.test_env;
    const test_name = "Model | Profile | Ratings | Create";
    var setup = try TestSetup.init(test_env.database_pool, test_name);
    defer setup.deinit(allocator);

    const BookModel = @import("../../models.zig").Content.Books;
    const media_id = blk: {
        const request = BookModel.Create.Request{
            .title = test_name,
            .user_id = setup.user.id,
            .release_date = null,
            .total_pages = null,
            .description = null,
        };
        const response = try BookModel.Create.call(
            allocator,
            .{ .database = test_env.database_pool },
            request,
        );
        allocator.free(response.title);

        break :blk response.id;
    };
    defer allocator.free(media_id);

    const request: Create.Request = .{
        .user_id = setup.user.id,
        .media_id = media_id,
        .rating_score = 8,
    };

    const response = try Create.call(
        allocator,
        .{ .database = test_env.database_pool },
        request,
    );
    response.deinit(allocator);
}

test "Model | Profile | Ratings | Create | Allocation Failure" {
    const allocator = std.testing.allocator;

    const test_env = Tests.test_env;
    const test_name = "Model | Profile | Ratings | Create | Allocation Failure";
    var setup = try TestSetup.init(test_env.database_pool, test_name);
    defer setup.deinit(allocator);

    const BookModel = @import("../../models.zig").Content.Books;
    const media_id = blk: {
        const request = BookModel.Create.Request{
            .title = test_name,
            .user_id = setup.user.id,
            .release_date = null,
            .total_pages = null,
            .description = null,
        };
        const response = try BookModel.Create.call(
            allocator,
            .{ .database = test_env.database_pool },
            request,
        );
        allocator.free(response.title);

        break :blk response.id;
    };
    defer allocator.free(media_id);

    const request: Create.Request = .{
        .user_id = setup.user.id,
        .media_id = media_id,
        .rating_score = 8,
    };

    try std.testing.checkAllAllocationFailures(
        allocator,
        struct {
            fn call(alloc: Allocator, conn: Connection, req: Create.Request) !void {
                const response = try Create.call(alloc, conn, req);
                response.deinit(allocator);
            }
        }.call,
        .{
            Connection{ .database = test_env.database_pool },
            request,
        },
    );
}

pub const GetAll = struct {
    pub const Request = struct {
        user_id: []const u8,
    };

    pub const Response = struct {
        id: []const u8,
        user_id: []const u8,
        media_id: []const u8,
        rating_score: u8,
        created_at: i64,

        pub fn deinit(self: Response, allocator: Allocator) void {
            allocator.free(self.id);
            allocator.free(self.user_id);
            allocator.free(self.media_id);
        }
    };

    pub const Errors = error{
        CannotGet,
        InvalidRatingScore,
        OutOfMemory,
        CannotParseID,
    } || DatabaseErrors;

    const log = std.log.scoped(.get_all_ratings_model);
    pub fn call(allocator: std.mem.Allocator, connection: Connection, request: Request) Errors![]Response {
        var conn = try connection.acquire();
        defer connection.release(conn);
        const error_handler = ErrorHandler{ .conn = conn };
        var query = conn.queryOpts(
            query_string,
            .{
                request.user_id,
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

        var responses: std.ArrayList(Response) = .empty;
        defer responses.deinit(allocator);
        errdefer for (responses.items) |response| response.deinit(allocator);

        const DatabaseResponse = struct {
            id: []const u8,
            user_id: []const u8,
            media_id: []const u8,
            // need to do this due to manual parsing of the rating score
            rating_score: i32,
            created_at: i64,
        };

        var mapper = query.mapper(DatabaseResponse, .{});

        while (mapper.next() catch return error.CannotGet) |response| {
            const id = try UUID.toStringAlloc(allocator, response.id);
            errdefer allocator.free(id);
            const user_id = try UUID.toStringAlloc(allocator, response.user_id);
            errdefer allocator.free(user_id);
            const media_id = try UUID.toStringAlloc(allocator, response.media_id);
            errdefer allocator.free(media_id);
            responses.append(allocator, .{
                .id = id,
                .user_id = user_id,
                .media_id = media_id,
                .rating_score = std.math.cast(u8, response.rating_score) orelse return error.InvalidRatingScore,
                .created_at = response.created_at,
            }) catch return error.OutOfMemory;
        }

        return responses.toOwnedSlice(allocator);
    }

    const query_string = @embedFile("queries/get.sql");
};

test "Model | Profile | Ratings | GetAll" {
    const allocator = std.testing.allocator;

    const test_env = Tests.test_env;
    const test_name = "Model | Profile | Ratings | GetAll";
    var setup = try TestSetup.init(test_env.database_pool, test_name);
    defer setup.deinit(allocator);

    const BookModel = @import("../../models.zig").Content.Books;
    const media_id = blk: {
        const request = BookModel.Create.Request{
            .title = test_name,
            .user_id = setup.user.id,
            .release_date = null,
            .total_pages = null,
            .description = null,
        };
        const response = try BookModel.Create.call(
            allocator,
            .{ .database = test_env.database_pool },
            request,
        );
        allocator.free(response.title);

        break :blk response.id;
    };
    defer allocator.free(media_id);

    const rating_request: Create.Request = .{
        .user_id = setup.user.id,
        .media_id = media_id,
        .rating_score = 8,
    };

    const rating_id = rating_blk: {
        const response = try Create.call(
            allocator,
            .{ .database = test_env.database_pool },
            rating_request,
        );

        break :rating_blk response.id;
    };
    defer allocator.free(rating_id);

    const request: GetAll.Request = .{
        .user_id = setup.user.id,
    };

    const responses = try GetAll.call(allocator, .{ .database = test_env.database_pool }, request);
    defer {
        for (responses) |response| response.deinit(allocator);
        allocator.free(responses);
    }
    try std.testing.expectEqual(1, responses.len);
    const resp = responses[0];
    try std.testing.expectEqualStrings(media_id, resp.media_id);
    try std.testing.expectEqualStrings(rating_id, resp.id);
    try std.testing.expectEqualStrings(setup.user.id, resp.user_id);
    try std.testing.expectEqual(rating_request.rating_score, resp.rating_score);
}

test "Model | Profile | Ratings | GetAll | Allocation Failure" {
    const allocator = std.testing.allocator;

    const test_env = Tests.test_env;
    const test_name = "Model | Profile | Ratings | GetAll | Allocation Failure";
    var setup = try TestSetup.init(test_env.database_pool, test_name);
    defer setup.deinit(allocator);

    const BookModel = @import("../../models.zig").Content.Books;
    const media_id = blk: {
        const request = BookModel.Create.Request{
            .title = test_name,
            .user_id = setup.user.id,
            .release_date = null,
            .total_pages = null,
            .description = null,
        };
        const response = try BookModel.Create.call(
            allocator,
            .{ .database = test_env.database_pool },
            request,
        );
        allocator.free(response.title);

        break :blk response.id;
    };
    defer allocator.free(media_id);

    const rating_request: Create.Request = .{
        .user_id = setup.user.id,
        .media_id = media_id,
        .rating_score = 8,
    };

    const rating_id = rating_blk: {
        const response = try Create.call(
            allocator,
            .{ .database = test_env.database_pool },
            rating_request,
        );

        break :rating_blk response.id;
    };
    defer allocator.free(rating_id);

    const request: GetAll.Request = .{
        .user_id = setup.user.id,
    };

    try std.testing.checkAllAllocationFailures(
        allocator,
        struct {
            fn call(alloc: Allocator, conn: Connection, req: GetAll.Request) !void {
                const responses = try GetAll.call(alloc, conn, req);
                for (responses) |response| response.deinit(allocator);
                allocator.free(responses);
            }
        }.call,
        .{
            Connection{ .database = test_env.database_pool },
            request,
        },
    );
}

/// Tries to match by [name,year] but if year is null, tries to match name only
pub const ImportLetterboxd = struct {
    pub const Request = struct {
        user_id: []const u8,
        titles: [][]const u8,
        years: []?i64,
        items_created_at: [][]const u8,
        ratings: []i32,
    };

    /// the movies that were not imported, due to either 0 movies that matched or more than 1 movies that matched
    pub const Response = struct {
        title: []const u8,
        release_year: ?i64,
        reason: []const u8,

        pub fn deinit(self: @This(), allocator: Allocator) void {
            allocator.free(self.title);
            allocator.free(self.reason);
        }
    };

    pub const Errors = error{
        CannotCreate,
        OutOfMemory,
        CannotParseID,
    } || DatabaseErrors;

    pub fn call(allocator: std.mem.Allocator, connection: Connection, request: Request) Errors![]Response {
        assertAllSameLength(request, .{ "titles", "years", "items_created_at", "ratings" });
        var conn = try connection.acquire();
        defer connection.release(conn);
        const error_handler = ErrorHandler{ .conn = conn };

        var query = conn.queryOpts(
            query_string,
            .{
                request.user_id,
                request.titles,
                request.years,
                request.items_created_at,
                request.ratings,
            },
            .{
                .column_names = true,
            },
        ) catch |err| {
            const error_data = error_handler.handle(err);
            if (error_data) |data| {
                ErrorHandler.printErr(data);
            }
            return error.CannotCreate;
        };
        defer query.deinit();

        var responses: std.ArrayList(Response) = .empty;
        defer responses.deinit(allocator);
        errdefer for (responses.items) |response| response.deinit(allocator);

        var mapper = query.mapper(Response, .{});

        while (mapper.next() catch return error.CannotCreate) |response| {
            const title = allocator.dupe(u8, response.title) catch return error.OutOfMemory;
            errdefer allocator.free(title);
            const reason = allocator.dupe(u8, response.reason) catch return error.OutOfMemory;
            errdefer allocator.free(reason);
            responses.append(allocator, .{
                .title = title,
                .release_year = response.release_year,
                .reason = reason,
            }) catch return error.OutOfMemory;
        }

        return responses.toOwnedSlice(allocator);
    }

    const query_string = @embedFile("queries/import_letterboxd_ratings.sql");
};

test "Model | Profile | Ratings | ImportLetterboxd" {
    const allocator = std.testing.allocator;

    const test_env = Tests.test_env;
    const test_name = "Model | Profile | Ratings | ImportLetterboxd";
    var setup = try TestSetup.init(test_env.database_pool, test_name);
    defer setup.deinit(allocator);

    const count = 10;
    var titles = try allocator.alloc([]const u8, count);
    var years = try allocator.alloc(?i64, count);
    var ratings = try allocator.alloc(i32, count);
    var created_at = try allocator.alloc([]const u8, count);
    defer {
        for (titles) |title| allocator.free(title);
        allocator.free(titles);
        allocator.free(years);
        allocator.free(ratings);
        allocator.free(created_at);
    }

    for (0..count) |i| {
        titles[i] = try std.fmt.allocPrint(allocator, "{s} | Movie {d}", .{ test_name, i });
        years[i] = 2000 + @as(u32, @intCast(i));
        // TODO: test this too
        created_at[i] = "01-01-2000";
        ratings[i] = 5;
    }

    const request: ImportLetterboxd.Request = .{
        .user_id = setup.user.id,
        .titles = titles,
        .items_created_at = created_at,
        .ratings = ratings,
        .years = years,
    };

    const responses = try ImportLetterboxd.call(
        allocator,
        .{ .database = test_env.database_pool },
        request,
    );
    defer {
        for (responses) |response| response.deinit(allocator);
        allocator.free(responses);
    }
    try std.testing.expectEqual(count, responses.len);
    for (0..count) |i| {
        try std.testing.expectEqualStrings(request.titles[i], responses[i].title);
        try std.testing.expectEqual(request.years[i], responses[i].release_year);
        // NOTE: we expect this to occur every time as there are no such matching movies
        // TODO: test successful behavior and the different failure states
        try std.testing.expectEqualStrings("Movie not found", responses[i].reason);
    }
}

test "Model | Profile | Ratings | ImportLetterboxd | Allocation Failures" {
    const allocator = std.testing.allocator;

    const test_env = Tests.test_env;
    const test_name = "Model | Profile | Ratings | ImportLetterboxd | Allocation Failures";
    var setup = try TestSetup.init(test_env.database_pool, test_name);
    defer setup.deinit(allocator);

    const count = 10;
    var titles = try allocator.alloc([]const u8, count);
    var years = try allocator.alloc(?i64, count);
    var ratings = try allocator.alloc(i32, count);
    var created_at = try allocator.alloc([]const u8, count);
    defer {
        for (titles) |title| allocator.free(title);
        allocator.free(titles);
        allocator.free(years);
        allocator.free(ratings);
        allocator.free(created_at);
    }

    for (0..count) |i| {
        titles[i] = try std.fmt.allocPrint(allocator, "{s} | Movie {d}", .{ test_name, i });
        years[i] = 2000 + @as(u32, @intCast(i));
        // TODO: test this too
        created_at[i] = "01-01-2000";
        ratings[i] = 5;
    }

    const request: ImportLetterboxd.Request = .{
        .user_id = setup.user.id,
        .titles = titles,
        .items_created_at = created_at,
        .ratings = ratings,
        .years = years,
    };

    try std.testing.checkAllAllocationFailures(
        allocator,
        struct {
            fn call(alloc: Allocator, conn: Connection, req: ImportLetterboxd.Request) !void {
                const responses = try ImportLetterboxd.call(alloc, conn, req);
                for (responses) |response| response.deinit(allocator);
                allocator.free(responses);
            }
        }.call,
        .{
            Connection{ .database = test_env.database_pool },
            request,
        },
    );
}

const assertAllSameLength = @import("../../../util/assertSameLength.zig").assertAllSameLength;

const Connection = @import("../../../database.zig").Connection;
const Pool = @import("../../../database.zig").Pool;
const DatabaseErrors = @import("../../../database.zig").DatabaseErrors;
const ErrorHandler = @import("../../../database.zig").ErrorHandler;

const Tests = @import("../../../tests/setup.zig");
const TestSetup = Tests.TestSetup;

const ProgressStatus = @import("../../content/content.zig").Media.ProgressStatus;
const ProgressUnit = @import("../../content/content.zig").Media.ProgressUnit;

const UUID = @import("../../../util/uuid.zig");

const Allocator = std.mem.Allocator;
const std = @import("std");
