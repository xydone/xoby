pub const Create = struct {
    pub const Request = struct {
        user_id: []const u8,
        media_id: []const u8,
        status: ProgressStatus,
        progress_value: f64,
        progress_unit: ProgressUnit,
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

    pub fn call(allocator: std.mem.Allocator, connection: Connection, request: Request) Errors!Response {
        var conn = try connection.acquire();
        defer connection.release(conn);
        const error_handler = ErrorHandler{ .conn = conn };
        var row = conn.rowOpts(
            query_string,
            .{
                request.user_id,
                request.media_id,
                request.status,
                request.progress_value,
                request.progress_unit,
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

test "Model | Profile | Progress | Create" {
    const allocator = std.testing.allocator;

    const test_env = Tests.test_env;
    const test_name = "Model | Profile | Progress | Create";
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
        .status = .in_progress,
        .progress_value = 0.13,
        .progress_unit = .percentage,
    };

    const response = try Create.call(
        allocator,
        .{ .database = test_env.database_pool },
        request,
    );
    response.deinit(allocator);
}

test "Model | Profile | Progress | Create | Allocation Failures" {
    const allocator = std.testing.allocator;

    const test_env = Tests.test_env;
    const test_name = "Model | Profile | Progress | Create | Allocation Failure";
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
        .status = .in_progress,
        .progress_value = 0.13,
        .progress_unit = .percentage,
    };

    try std.testing.checkAllAllocationFailures(allocator, struct {
        fn call(alloc: Allocator, conn: Connection, req: Create.Request) !void {
            const response = try Create.call(alloc, conn, req);
            response.deinit(allocator);
        }
    }.call, .{
        Connection{ .database = test_env.database_pool },
        request,
    });
}

pub const GetAll = struct {
    pub const Request = struct {
        user_id: []const u8,
        limit: u32,
    };

    pub const Response = struct {
        progress_id: []const u8,
        user_id: []const u8,
        media_id: []const u8,
        progress_value: f64,
        completion_percentage: f64,
        status: ProgressStatus,
        created_at: i64,

        pub fn deinit(self: Response, allocator: Allocator) void {
            allocator.free(self.progress_id);
            allocator.free(self.user_id);
            allocator.free(self.media_id);
        }
    };

    pub const Errors = error{
        CannotGet,
        OutOfMemory,
        CannotParseID,
    } || DatabaseErrors;

    pub fn call(allocator: std.mem.Allocator, connection: Connection, request: Request) Errors![]Response {
        var conn = try connection.acquire();
        defer connection.release(conn);
        const error_handler = ErrorHandler{ .conn = conn };
        var query = conn.queryOpts(
            query_string,
            .{
                request.user_id,
                request.limit,
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

        var mapper = query.mapper(Response, .{});

        while (mapper.next() catch return error.CannotGet) |response| {
            const id = try UUID.toStringAlloc(allocator, response.progress_id);
            errdefer allocator.free(id);
            const user_id = try UUID.toStringAlloc(allocator, response.user_id);
            errdefer allocator.free(user_id);
            const media_id = allocator.dupe(u8, response.media_id) catch return error.OutOfMemory;
            errdefer allocator.free(media_id);
            responses.append(allocator, .{
                .progress_id = id,
                .user_id = user_id,
                .media_id = media_id,
                .status = response.status,
                .created_at = response.created_at,
                .progress_value = response.progress_value,
                .completion_percentage = response.completion_percentage,
            }) catch return error.OutOfMemory;
        }

        return responses.toOwnedSlice(allocator);
    }

    const query_string = @embedFile("queries/get_all_progress.sql");
};

test "Model | Profile | Progress | GetAll" {
    const allocator = std.testing.allocator;

    const test_env = Tests.test_env;
    const test_name = "Model | Profile | Progress | GetAll";
    var setup = try TestSetup.init(test_env.database_pool, test_name);
    defer setup.deinit(allocator);

    const progress_id = blk: {
        const BookModel = @import("../../models.zig").Content.Books;
        const media_id = media: {
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

            break :media response.id;
        };
        defer allocator.free(media_id);

        const request: Create.Request = .{
            .user_id = setup.user.id,
            .media_id = media_id,
            .status = .in_progress,
            .progress_value = 0.13,
            .progress_unit = .percentage,
        };

        const response = try Create.call(
            allocator,
            .{ .database = test_env.database_pool },
            request,
        );
        break :blk response.id;
    };
    defer allocator.free(progress_id);

    const request: GetAll.Request = .{
        .user_id = setup.user.id,
        .limit = 50,
    };

    const responses = try GetAll.call(
        allocator,
        .{ .database = test_env.database_pool },
        request,
    );
    defer {
        for (responses) |response| response.deinit(allocator);
        allocator.free(responses);
    }

    try std.testing.expectEqual(1, responses.len);
    try std.testing.expectEqualStrings(setup.user.id, responses[0].user_id);
    try std.testing.expectEqualStrings(progress_id, responses[0].progress_id);
}

test "Model | Profile | Progress | GetAll | Allocation Failures" {
    const allocator = std.testing.allocator;

    const test_env = Tests.test_env;
    const test_name = "Model | Profile | Progress | GetAll | Allocation Failures";
    var setup = try TestSetup.init(test_env.database_pool, test_name);
    defer setup.deinit(allocator);

    {
        const BookModel = @import("../../models.zig").Content.Books;
        const media_id = media: {
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

            break :media response.id;
        };
        defer allocator.free(media_id);

        const request: Create.Request = .{
            .user_id = setup.user.id,
            .media_id = media_id,
            .status = .in_progress,
            .progress_value = 0.13,
            .progress_unit = .percentage,
        };

        const response = try Create.call(
            allocator,
            .{ .database = test_env.database_pool },
            request,
        );
        response.deinit(allocator);
    }

    const request: GetAll.Request = .{
        .user_id = setup.user.id,
        .limit = 50,
    };

    try std.testing.checkAllAllocationFailures(
        allocator,
        struct {
            fn call(alloc: Allocator, conn: Connection, req: GetAll.Request) !void {
                const responses = try GetAll.call(alloc, conn, req);
                defer {
                    for (responses) |response| response.deinit(allocator);
                    allocator.free(responses);
                }
            }
        }.call,
        .{
            Connection{ .database = test_env.database_pool },
            request,
        },
    );
}

pub const GetAllStatus = struct {
    pub const Request = struct {
        user_id: []const u8,
        status: ProgressStatus,
    };

    pub const Response = struct {
        progress_id: []const u8,
        media_id: []const u8,
        media_title: []const u8,
        media_type: []const u8,
        status: ProgressStatus,
        progress_value: f64,
        completion_percentage: f64,
        progress_unit: ProgressUnit,
        created_at: i64,

        pub fn deinit(self: Response, allocator: Allocator) void {
            allocator.free(self.progress_id);
            allocator.free(self.media_id);
            allocator.free(self.media_title);
            allocator.free(self.media_type);
        }
    };

    pub const Errors = error{
        CannotGet,
        OutOfMemory,
        CannotParseID,
    } || DatabaseErrors;

    pub fn call(allocator: std.mem.Allocator, connection: Connection, request: Request) Errors![]Response {
        var conn = try connection.acquire();
        defer connection.release(conn);
        const error_handler = ErrorHandler{ .conn = conn };
        var query = conn.queryOpts(
            query_string,
            .{
                request.user_id,
                request.status,
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

        var mapper = query.mapper(Response, .{});

        while (mapper.next() catch return error.CannotGet) |response| {
            responses.append(allocator, .{
                .progress_id = try UUID.toStringAlloc(allocator, response.progress_id),
                .media_id = allocator.dupe(u8, response.media_id) catch return error.OutOfMemory,
                .status = response.status,
                .media_title = try allocator.dupe(u8, response.media_title),
                .media_type = try allocator.dupe(u8, response.media_type),
                .progress_value = response.progress_value,
                .completion_percentage = response.completion_percentage,
                .progress_unit = response.progress_unit,
                .created_at = response.created_at,
            }) catch return error.OutOfMemory;
        }

        return responses.toOwnedSlice(allocator);
    }

    const query_string = @embedFile("queries/get_all_status.sql");
};

test "Model | Profile | Progress | GetAllStatus" {
    const allocator = std.testing.allocator;

    const test_env = Tests.test_env;
    const test_name = "Model | Profile | Progress | GetAllStatus";
    var setup = try TestSetup.init(test_env.database_pool, test_name);
    defer setup.deinit(allocator);

    const progress_id = blk: {
        const BookModel = @import("../../models.zig").Content.Books;
        const media_id = media: {
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

            break :media response.id;
        };
        defer allocator.free(media_id);

        const request: Create.Request = .{
            .user_id = setup.user.id,
            .media_id = media_id,
            .status = .in_progress,
            .progress_value = 0.13,
            .progress_unit = .percentage,
        };

        const response = try Create.call(
            allocator,
            .{ .database = test_env.database_pool },
            request,
        );

        const second_request: Create.Request = .{
            .user_id = setup.user.id,
            .media_id = media_id,
            .status = .completed,
            .progress_value = 1,
            .progress_unit = .percentage,
        };

        const second_response = try Create.call(
            allocator,
            .{ .database = test_env.database_pool },
            second_request,
        );

        break :blk &.{ response.id, second_response.id };
    };
    defer {
        allocator.free(progress_id.@"0");
        allocator.free(progress_id.@"1");
    }

    const request: GetAllStatus.Request = .{
        .user_id = setup.user.id,
        .status = .completed,
    };

    const responses = try GetAllStatus.call(
        allocator,
        .{ .database = test_env.database_pool },
        request,
    );
    defer {
        for (responses) |response| response.deinit(allocator);
        allocator.free(responses);
    }

    try std.testing.expectEqual(1, responses.len);
    try std.testing.expectEqualStrings(progress_id.@"1", responses[0].progress_id);
}

test "Model | Profile | Progress | GetAllStatus | Allocation Failures" {
    const allocator = std.testing.allocator;

    const test_env = Tests.test_env;
    const test_name = "Model | Profile | Progress | GetAllStatus | Allocation Failures";
    var setup = try TestSetup.init(test_env.database_pool, test_name);
    defer setup.deinit(allocator);

    const progress_id = blk: {
        const BookModel = @import("../../models.zig").Content.Books;
        const media_id = media: {
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

            break :media response.id;
        };
        defer allocator.free(media_id);

        const request: Create.Request = .{
            .user_id = setup.user.id,
            .media_id = media_id,
            .status = .in_progress,
            .progress_value = 0.13,
            .progress_unit = .percentage,
        };

        const response = try Create.call(
            allocator,
            .{ .database = test_env.database_pool },
            request,
        );

        break :blk response.id;
    };
    defer allocator.free(progress_id);

    const request: GetAllStatus.Request = .{
        .user_id = setup.user.id,
        .status = .completed,
    };

    try std.testing.checkAllAllocationFailures(
        allocator,
        struct {
            fn call(alloc: Allocator, conn: Connection, req: GetAllStatus.Request) !void {
                const responses = try GetAllStatus.call(alloc, conn, req);

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

/// Turns a letterboxd list into a progress entry.
/// Tries to match by [name,year] but if year is null, tries to match name only
pub const ImportLetterboxd = struct {
    pub const Request = struct {
        user_id: []const u8,
        titles: [][]const u8,
        created_at: [][]const u8,
        uris: [][]const u8,
        status: ProgressStatus,
        years: []?i64,
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

    const log = std.log.scoped(.progress_importletterboxd_model);
    pub fn call(allocator: std.mem.Allocator, connection: Connection, request: Request) Errors![]Response {
        assertAllSameLength(request, .{ "titles", "years", "created_at" });
        var conn = try connection.acquire();
        defer connection.release(conn);
        const error_handler = ErrorHandler{ .conn = conn };
        var query = conn.queryOpts(
            query_string,
            .{
                request.titles,
                request.years,
                request.created_at,
                request.uris,
                request.user_id,
                request.status,
                "letterboxd",
            },
            .{
                .column_names = true,
            },
        ) catch |err| {
            const error_data = error_handler.handle(err);
            if (error_data) |data| {
                ErrorHandler.printErr(data);
            }
            log.debug("query failed! {}", .{err});
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

    const query_string = @embedFile("queries/import_letterboxd_progress.sql");
};

test "Model | Profile | Progress | ImportLetterboxd" {
    const allocator = std.testing.allocator;

    const test_env = Tests.test_env;
    const test_name = "Model | Profile | Progress | ImportLetterboxd";
    var setup = try TestSetup.init(test_env.database_pool, test_name);
    defer setup.deinit(allocator);

    const count = 10;
    var titles = try allocator.alloc([]const u8, count);
    var years = try allocator.alloc(?i64, count);
    var uris = try allocator.alloc([]const u8, count);
    var created_at = try allocator.alloc([]const u8, count);
    defer {
        for (titles) |title| allocator.free(title);
        for (uris) |uri| allocator.free(uri);
        allocator.free(titles);
        allocator.free(years);
        allocator.free(uris);
        allocator.free(created_at);
    }

    for (0..count) |i| {
        titles[i] = try std.fmt.allocPrint(allocator, "{s} | Movie {d}", .{ test_name, i });
        years[i] = 2000 + @as(u32, @intCast(i));
        uris[i] = try std.fmt.allocPrint(allocator, "{s} | Movie {d} 's uri", .{ test_name, i });
        // TODO: test this too
        created_at[i] = "01-01-2000";
    }

    const request: ImportLetterboxd.Request = .{
        .user_id = setup.user.id,
        .status = .completed,
        .titles = titles,
        .created_at = created_at,
        .uris = uris,
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
}

test "Model | Profile | Progress | ImportLetterboxd | Allocation Failures" {
    const allocator = std.testing.allocator;

    const test_env = Tests.test_env;
    const test_name = "Model | Profile | Progress | ImportLetterboxd | Allocation Failures";
    var setup = try TestSetup.init(test_env.database_pool, test_name);
    defer setup.deinit(allocator);

    const count = 10;
    var titles = try allocator.alloc([]const u8, count);
    var years = try allocator.alloc(?i64, count);
    var uris = try allocator.alloc([]const u8, count);
    var created_at = try allocator.alloc([]const u8, count);
    defer {
        for (titles) |title| allocator.free(title);
        for (uris) |uri| allocator.free(uri);
        allocator.free(titles);
        allocator.free(years);
        allocator.free(uris);
        allocator.free(created_at);
    }

    for (0..count) |i| {
        titles[i] = try std.fmt.allocPrint(allocator, "{s} | Movie {d}", .{ test_name, i });
        years[i] = 2000 + @as(u32, @intCast(i));
        uris[i] = try std.fmt.allocPrint(allocator, "{s} | Movie {d} 's uri", .{ test_name, i });
        // TODO: test this too
        created_at[i] = "01-01-2000";
    }

    const request: ImportLetterboxd.Request = .{
        .user_id = setup.user.id,
        .status = .completed,
        .titles = titles,
        .created_at = created_at,
        .uris = uris,
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
