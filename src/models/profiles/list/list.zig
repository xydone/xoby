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

    pub fn call(allocator: std.mem.Allocator, connection: Connection, request: Request) Errors!Response {
        var conn = try connection.acquire();
        defer connection.release(conn);
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

    const query_string = @embedFile("queries/create_list.sql");
};

test "Model | Profile | CreateList" {
    const allocator = std.testing.allocator;

    const test_env = Tests.test_env;
    const test_name = "Model | Profile | CreateList";
    var setup = try TestSetup.init(test_env.database_pool, test_name);
    defer setup.deinit(allocator);

    const request: CreateList.Request = .{
        .user_id = setup.user.id,
        .name = test_name,
        .is_public = true,
    };

    const response = try CreateList.call(
        allocator,
        .{ .database = test_env.database_pool },
        request,
    );
    defer response.deinit(allocator);
}

test "Model | Profile | CreateList | Allocation Failures" {
    const allocator = std.testing.allocator;

    const test_env = Tests.test_env;
    const test_name = "Model | Profile | CreateList | Allocation Failures";
    var setup = try TestSetup.init(test_env.database_pool, test_name);
    defer setup.deinit(allocator);

    const request: CreateList.Request = .{
        .user_id = setup.user.id,
        .name = test_name,
        .is_public = true,
    };

    try std.testing.checkAllAllocationFailures(
        allocator,
        struct {
            fn call(alloc: Allocator, conn: Connection, req: CreateList.Request) !void {
                const response = try CreateList.call(alloc, conn, req);
                response.deinit(allocator);
            }
        }.call,
        .{
            Connection{ .database = test_env.database_pool },
            request,
        },
    );
}

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

    const log = std.log.scoped(.get_list_model);
    pub fn call(allocator: std.mem.Allocator, connection: Connection, request: Request) Errors!Response {
        var conn = try connection.acquire();
        defer connection.release(conn);
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
            switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    log.err("GetList failed to parse row! {}", .{err});
                    return error.CannotGet;
                },
            }
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
            switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    log.err("GetList failed to parse json! {}", .{err});
                    return error.CannotGet;
                },
            }
        };

        const id = try UUID.toStringAlloc(allocator, database_response.id);
        errdefer allocator.free(id);
        const user_id = try UUID.toStringAlloc(allocator, database_response.user_id);
        errdefer allocator.free(user_id);
        const name = allocator.dupe(u8, database_response.name) catch return error.OutOfMemory;
        errdefer allocator.free(name);
        return Response{
            .id = id,
            .user_id = user_id,
            .name = name,
            .is_public = database_response.is_public,
            .created_at = database_response.created_at,
            .items = items,
        };
    }

    const query_string = @embedFile("queries/get_list.sql");
};

test "Model | Profile | GetList" {
    const allocator = std.testing.allocator;

    const test_env = Tests.test_env;
    const test_name = "Model | Profile | GetList";
    var setup = try TestSetup.init(test_env.database_pool, test_name);
    defer setup.deinit(allocator);

    const list_id = blk: {
        const request: CreateList.Request = .{
            .user_id = setup.user.id,
            .name = test_name,
            .is_public = true,
        };

        const response = try CreateList.call(
            allocator,
            .{ .database = test_env.database_pool },
            request,
        );
        break :blk response.id;
    };
    defer allocator.free(list_id);

    const request: GetList.Request = .{
        .user_id = setup.user.id,
        .list_id = list_id,
    };

    const response = try GetList.call(
        allocator,
        .{ .database = test_env.database_pool },
        request,
    );
    defer response.deinit(allocator);
}

test "Model | Profile | GetList | Allocation Failures" {
    const allocator = std.testing.allocator;

    const test_env = Tests.test_env;
    const test_name = "Model | Profile | GetList | Allocation Failures";
    var setup = try TestSetup.init(test_env.database_pool, test_name);
    defer setup.deinit(allocator);

    const list_id = blk: {
        const request: CreateList.Request = .{
            .user_id = setup.user.id,
            .name = test_name,
            .is_public = true,
        };

        const response = try CreateList.call(
            allocator,
            .{ .database = test_env.database_pool },
            request,
        );
        break :blk response.id;
    };
    defer allocator.free(list_id);

    const request: GetList.Request = .{
        .user_id = setup.user.id,
        .list_id = list_id,
    };

    try std.testing.checkAllAllocationFailures(
        allocator,
        struct {
            fn call(alloc: Allocator, conn: Connection, req: GetList.Request) !void {
                const response = try GetList.call(alloc, conn, req);
                response.deinit(alloc);
            }
        }.call,
        .{
            Connection{ .database = test_env.database_pool },
            request,
        },
    );
}

pub const GetLists = struct {
    pub const Request = struct {
        user_id: []const u8,
    };

    pub const Response = struct {
        id: []const u8,
        user_id: []const u8,
        name: []const u8,
        is_public: bool,
        created_at: i64,

        pub fn deinit(self: Response, allocator: Allocator) void {
            allocator.free(self.id);
            allocator.free(self.user_id);
            allocator.free(self.name);
        }
    };

    pub const Errors = error{
        CannotGet,
        NotFound,
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
        errdefer {
            for (responses.items) |response| {
                allocator.free(response.id);
                allocator.free(response.user_id);
                allocator.free(response.name);
            }
        }

        var mapper = query.mapper(Response, .{});

        while (mapper.next() catch return error.CannotGet) |response| {
            const id = try UUID.toStringAlloc(allocator, response.id);
            errdefer allocator.free(id);
            const user_id = try UUID.toStringAlloc(allocator, response.user_id);
            errdefer allocator.free(user_id);
            const name = try allocator.dupe(u8, response.name);
            errdefer allocator.free(name);

            try responses.append(allocator, .{
                .id = id,
                .user_id = user_id,
                .name = name,
                .is_public = response.is_public,
                .created_at = response.created_at,
            });
        }

        return responses.toOwnedSlice(allocator);
    }

    const query_string = @embedFile("queries/get_lists.sql");
};

test "Model | Profile | GetLists" {
    const allocator = std.testing.allocator;

    const test_env = Tests.test_env;
    const test_name = "Model | Profile | GetLists";
    var setup = try TestSetup.init(test_env.database_pool, test_name);
    defer setup.deinit(allocator);

    const list_ids = blk: {
        var list_ids_buf: [5][]const u8 = undefined;
        const list_connection: Connection = .{ .database = test_env.database_pool };

        const conn = try list_connection.acquire();
        defer list_connection.release(conn);

        for (0..5) |i| {
            const response = try CreateList.call(
                allocator,
                .{ .conn = conn },
                .{
                    .user_id = setup.user.id,
                    .name = test_name,
                    .is_public = true,
                },
            );
            list_ids_buf[i] = response.id;
        }
        break :blk list_ids_buf;
    };
    defer for (list_ids) |id| allocator.free(id);

    const request: GetLists.Request = .{
        .user_id = setup.user.id,
    };

    const responses = try GetLists.call(
        allocator,
        .{ .database = test_env.database_pool },
        request,
    );
    defer {
        for (responses) |response| response.deinit(allocator);
        allocator.free(responses);
    }

    try std.testing.expectEqual(list_ids.len, responses.len);

    for (responses, 0..) |response, i| {
        try std.testing.expectEqualStrings(list_ids[i], response.id);
    }
}

test "Model | Profile | GetLists | Allocation Failures" {
    const allocator = std.testing.allocator;

    const test_env = Tests.test_env;
    const test_name = "Model | Profile | GetLists | Allocation Failures";
    var setup = try TestSetup.init(test_env.database_pool, test_name);
    defer setup.deinit(allocator);

    const list_ids = blk: {
        var list_ids_buf: [5][]const u8 = undefined;
        const list_connection: Connection = .{ .database = test_env.database_pool };

        const conn = try list_connection.acquire();
        defer list_connection.release(conn);

        for (0..5) |i| {
            const response = try CreateList.call(
                allocator,
                .{ .conn = conn },
                .{
                    .user_id = setup.user.id,
                    .name = test_name,
                    .is_public = true,
                },
            );
            list_ids_buf[i] = response.id;
        }
        break :blk list_ids_buf;
    };
    defer for (list_ids) |id| allocator.free(id);

    const request: GetLists.Request = .{
        .user_id = setup.user.id,
    };

    try std.testing.checkAllAllocationFailures(
        allocator,
        struct {
            fn call(alloc: Allocator, conn: Connection, req: GetLists.Request) !void {
                const responses = try GetLists.call(alloc, conn, req);
                for (responses) |response| response.deinit(allocator);
                alloc.free(responses);
            }
        }.call,
        .{
            Connection{ .database = test_env.database_pool },
            request,
        },
    );
}

pub const ChangeList = struct {
    pub const Request = struct {
        id: []const u8,
        user_id: []const u8,
        name: []const u8,
        is_public: bool,
    };

    pub const Response = struct {
        id: []const u8,

        pub fn deinit(self: Response, allocator: std.mem.Allocator) void {
            allocator.free(self.id);
        }
    };

    pub const Errors = error{
        NotFound,
        CannotUpdate,
        OutOfMemory,
        CannotParseID,
        CannotAcquireConnection,
    } || DatabaseErrors;

    pub fn call(allocator: std.mem.Allocator, connection: Connection, request: Request) Errors!Response {
        var conn = try connection.acquire();
        defer connection.release(conn);

        const error_handler = ErrorHandler{ .conn = conn };

        var row = conn.row(query_string, .{
            request.id,
            request.user_id,
            request.name,
            request.is_public,
        }) catch |err| {
            const error_data = error_handler.handle(err);
            if (error_data) |data| {
                ErrorHandler.printErr(data);
            }
            return error.CannotUpdate;
        } orelse return error.NotFound;

        defer row.deinit() catch {};

        const id = try UUID.toStringAlloc(allocator, row.get([]u8, 0));

        return Response{
            .id = id,
        };
    }

    const query_string = @embedFile("queries/change_list.sql");
};

test "Model | Profile | ChangeList" {
    const allocator = std.testing.allocator;

    const test_env = Tests.test_env;
    const test_name = "Model | Profile | ChangeList";
    var setup = try TestSetup.init(test_env.database_pool, test_name);
    defer setup.deinit(allocator);

    const list_id = blk: {
        const request: CreateList.Request = .{
            .user_id = setup.user.id,
            .name = test_name,
            .is_public = true,
        };

        const response = try CreateList.call(
            allocator,
            .{ .database = test_env.database_pool },
            request,
        );
        break :blk response.id;
    };
    defer allocator.free(list_id);

    const request: ChangeList.Request = .{
        .user_id = setup.user.id,
        .id = list_id,
        .name = test_name ++ " changed",
        .is_public = false,
    };

    const response = try ChangeList.call(
        allocator,
        .{ .database = test_env.database_pool },
        request,
    );
    defer response.deinit(allocator);

    try std.testing.expectEqualStrings(request.id, response.id);
}

test "Model | Profile | ChangeList | Allocation Failures" {
    const allocator = std.testing.allocator;

    const test_env = Tests.test_env;
    const test_name = "Model | Profile | ChangeList | Allocation Failures";
    var setup = try TestSetup.init(test_env.database_pool, test_name);
    defer setup.deinit(allocator);

    const list_id = blk: {
        const request: CreateList.Request = .{
            .user_id = setup.user.id,
            .name = test_name,
            .is_public = true,
        };

        const response = try CreateList.call(
            allocator,
            .{ .database = test_env.database_pool },
            request,
        );
        break :blk response.id;
    };
    defer allocator.free(list_id);

    const request: ChangeList.Request = .{
        .user_id = setup.user.id,
        .id = list_id,
        .name = test_name ++ " changed",
        .is_public = false,
    };

    try std.testing.checkAllAllocationFailures(
        allocator,
        struct {
            fn call(alloc: Allocator, conn: Connection, req: ChangeList.Request) !void {
                const response = try ChangeList.call(alloc, conn, req);
                response.deinit(alloc);
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
        list_id: []const u8,
        titles: [][]const u8,
        years: []?i64,
        items_created_at: [][]const u8,
    };

    /// the movies that were not imported, due to either 0 movies that matched or more than 1 movies that matched
    pub const Response = struct {
        title: []const u8,
        release_year: ?i64,

        pub fn deinit(self: @This(), allocator: Allocator) void {
            allocator.free(self.title);
        }
    };

    pub const Errors = error{
        CannotCreate,
        OutOfMemory,
        CannotParseID,
    } || DatabaseErrors;

    pub fn call(allocator: std.mem.Allocator, connection: Connection, request: Request) Errors![]Response {
        assertAllSameLength(request, .{ "titles", "years", "items_created_at" });
        var conn = try connection.acquire();
        defer connection.release(conn);
        const error_handler = ErrorHandler{ .conn = conn };
        var query = conn.queryOpts(
            query_string,
            .{
                request.user_id,
                request.list_id,
                request.titles,
                request.years,
                request.items_created_at,
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
        errdefer {
            for (responses.items) |item| allocator.free(item.title);
        }

        var mapper = query.mapper(Response, .{});

        while (mapper.next() catch return error.CannotCreate) |response| {
            const title = allocator.dupe(u8, response.title) catch return error.OutOfMemory;
            errdefer allocator.free(title);
            responses.append(allocator, .{
                .title = title,
                .release_year = response.release_year,
            }) catch return error.OutOfMemory;
        }

        return responses.toOwnedSlice(allocator);
    }

    const query_string = @embedFile("queries/import_letterboxd_list.sql");
};

test "Model | Profile | List | ImportLetterboxd" {
    const allocator = std.testing.allocator;

    const test_env = Tests.test_env;
    const test_name = "Model | Profile | ImportLetterboxd";
    var setup = try TestSetup.init(test_env.database_pool, test_name);
    defer setup.deinit(allocator);

    const list_id = blk: {
        const request: CreateList.Request = .{
            .user_id = setup.user.id,
            .name = test_name,
            .is_public = true,
        };

        const response = try CreateList.call(
            allocator,
            .{ .database = test_env.database_pool },
            request,
        );
        break :blk response.id;
    };
    defer allocator.free(list_id);

    const count = 10;
    var titles = try allocator.alloc([]const u8, count);
    var years = try allocator.alloc(?i64, count);
    var items_created_at = try allocator.alloc([]const u8, count);
    defer {
        for (titles) |title| allocator.free(title);
        allocator.free(titles);
        allocator.free(years);
        allocator.free(items_created_at);
    }

    for (0..count) |i| {
        titles[i] = try std.fmt.allocPrint(allocator, "{s} | Movie {d}", .{ test_name, i });
        years[i] = 2000 + @as(u32, @intCast(i));
        // TODO: test this too
        items_created_at[i] = "01-01-2000";
    }

    const request: ImportLetterboxd.Request = .{
        .user_id = setup.user.id,
        .list_id = list_id,
        .titles = titles,
        .years = years,
        .items_created_at = items_created_at,
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

    for (responses, 0..) |response, i| {
        // NOTE: expected behaviour is to have the values return in the same order they came in
        try std.testing.expectEqualStrings(request.titles[i], response.title);
        try std.testing.expectEqual(request.years[i], response.release_year);
    }
}

test "Model | Profile | List | ImportLetterboxd | Allocation Failures" {
    const allocator = std.testing.allocator;

    const test_env = Tests.test_env;
    const test_name = "Model | Profile | ImportLetterboxd | Allocation Failures";
    var setup = try TestSetup.init(test_env.database_pool, test_name);
    defer setup.deinit(allocator);

    const list_id = blk: {
        const request: CreateList.Request = .{
            .user_id = setup.user.id,
            .name = test_name,
            .is_public = true,
        };

        const response = try CreateList.call(
            allocator,
            .{ .database = test_env.database_pool },
            request,
        );
        break :blk response.id;
    };
    defer allocator.free(list_id);

    const count = 10;
    var titles = try allocator.alloc([]const u8, count);
    var years = try allocator.alloc(?i64, count);
    var items_created_at = try allocator.alloc([]const u8, count);
    defer {
        for (titles) |title| allocator.free(title);
        allocator.free(titles);
        allocator.free(years);
        allocator.free(items_created_at);
    }

    for (0..count) |i| {
        titles[i] = try std.fmt.allocPrint(allocator, "{s} | Movie {d}", .{ test_name, i });
        years[i] = 2000 + @as(u32, @intCast(i));
        // TODO: test this too
        items_created_at[i] = "01-01-2000";
    }

    const request: ImportLetterboxd.Request = .{
        .user_id = setup.user.id,
        .list_id = list_id,
        .titles = titles,
        .years = years,
        .items_created_at = items_created_at,
    };

    try std.testing.checkAllAllocationFailures(
        allocator,
        struct {
            fn call(alloc: Allocator, conn: Connection, req: ImportLetterboxd.Request) !void {
                const responses = try ImportLetterboxd.call(alloc, conn, req);
                for (responses) |response| response.deinit(alloc);
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

const ProgressStatus = @import("../../content/media.zig").ProgressStatus;
const ProgressUnit = @import("../../content/media.zig").ProgressUnit;

const UUID = @import("../../../util/uuid.zig");

const Allocator = std.mem.Allocator;
const std = @import("std");
