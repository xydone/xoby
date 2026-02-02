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
            .name = allocator.dupe(u8, database_response.name) catch return error.OutOfMemory,
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

    pub fn call(allocator: std.mem.Allocator, database: *Pool, request: Request) Errors![]Response {
        var conn = database.acquire() catch return error.CannotAcquireConnection;
        defer conn.release();
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

        var mapper = query.mapper(Response, .{});

        while (mapper.next() catch return error.CannotGet) |response| {
            responses.append(allocator, .{
                .id = try UUID.toStringAlloc(allocator, response.id),
                .user_id = try UUID.toStringAlloc(allocator, response.user_id),
                .name = allocator.dupe(u8, response.name) catch return error.OutOfMemory,
                .is_public = response.is_public,
                .created_at = response.created_at,
            }) catch return error.OutOfMemory;
        }

        return responses.toOwnedSlice(allocator);
    }

    const query_string =
        \\ SELECT *
        \\ FROM profiles.lists
        \\ WHERE user_id = $1;
    ;
};

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

    pub fn call(allocator: std.mem.Allocator, database: *Pool, request: Request) Errors!Response {
        var conn = database.acquire() catch return error.CannotAcquireConnection;
        defer conn.release();

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

    const query_string =
        \\ UPDATE profiles.lists 
        \\ SET name = $3, is_public = $4
        \\ WHERE id = $1 AND user_id = $2
        \\ RETURNING id;
    ;
};

pub const GetRatings = struct {
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

    pub fn call(allocator: std.mem.Allocator, database: *Pool, request: Request) Errors![]Response {
        var conn = database.acquire() catch return error.CannotAcquireConnection;
        defer conn.release();
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
            responses.append(allocator, .{
                .id = try UUID.toStringAlloc(allocator, response.id),
                .user_id = try UUID.toStringAlloc(allocator, response.user_id),
                .media_id = allocator.dupe(u8, response.media_id) catch return error.OutOfMemory,
                .rating_score = std.math.cast(u8, response.rating_score) orelse return error.InvalidRatingScore,
                .created_at = response.created_at,
            }) catch return error.OutOfMemory;
        }

        return responses.toOwnedSlice(allocator);
    }

    const query_string =
        \\ SELECT *
        \\ FROM profiles.ratings
        \\ WHERE user_id = $1;
    ;
};

pub const GetAllProgress = struct {
    pub const Request = struct {
        user_id: []const u8,
    };

    pub const Response = struct {
        id: []const u8,
        user_id: []const u8,
        media_id: []const u8,
        status: ProgressStatus,
        created_at: i64,

        pub fn deinit(self: Response, allocator: Allocator) void {
            allocator.free(self.id);
            allocator.free(self.user_id);
            allocator.free(self.media_id);
        }
    };

    pub const Errors = error{
        CannotGet,
        OutOfMemory,
        CannotParseID,
    } || DatabaseErrors;

    pub fn call(allocator: std.mem.Allocator, database: *Pool, request: Request) Errors![]Response {
        var conn = database.acquire() catch return error.CannotAcquireConnection;
        defer conn.release();
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

        var mapper = query.mapper(Response, .{});

        while (mapper.next() catch return error.CannotGet) |response| {
            responses.append(allocator, .{
                .id = try UUID.toStringAlloc(allocator, response.id),
                .user_id = try UUID.toStringAlloc(allocator, response.user_id),
                .media_id = allocator.dupe(u8, response.media_id) catch return error.OutOfMemory,
                .status = response.status,
                .created_at = response.created_at,
            }) catch return error.OutOfMemory;
        }

        return responses.toOwnedSlice(allocator);
    }

    const query_string =
        \\ SELECT *
        \\ FROM profiles.ratings
        \\ WHERE user_id = $1;
    ;
};

/// Tries to match by [name,year] but if year is null, tries to match name only
pub const ImportLetterboxdListToList = struct {
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

        var mapper = query.mapper(Response, .{});

        while (mapper.next() catch return error.CannotCreate) |response| {
            responses.append(allocator, .{
                .title = allocator.dupe(u8, response.title) catch return error.OutOfMemory,
                .release_year = response.release_year,
            }) catch return error.OutOfMemory;
        }

        return responses.toOwnedSlice(allocator);
    }

    const query_string = @embedFile("queries/import_letterboxd_list.sql");
};

/// Turns a letterboxd list into a progress entry.
/// Tries to match by [name,year] but if year is null, tries to match name only
pub const ImportLetterboxdListToProgress = struct {
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
            return error.CannotCreate;
        };
        defer query.deinit();

        var responses: std.ArrayList(Response) = .empty;
        defer responses.deinit(allocator);

        var mapper = query.mapper(Response, .{});

        while (mapper.next() catch return error.CannotCreate) |response| {
            responses.append(allocator, .{
                .title = allocator.dupe(u8, response.title) catch return error.OutOfMemory,
                .release_year = response.release_year,
                .reason = allocator.dupe(u8, response.reason) catch return error.OutOfMemory,
            }) catch return error.OutOfMemory;
        }

        return responses.toOwnedSlice(allocator);
    }

    const query_string = @embedFile("queries/import_letterboxd_progress.sql");
};

/// Tries to match by [name,year] but if year is null, tries to match name only
pub const ImportLetterboxdRatings = struct {
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

        var mapper = query.mapper(Response, .{});

        while (mapper.next() catch return error.CannotCreate) |response| {
            responses.append(allocator, .{
                .title = allocator.dupe(u8, response.title) catch return error.OutOfMemory,
                .release_year = response.release_year,
                .reason = allocator.dupe(u8, response.reason) catch return error.OutOfMemory,
            }) catch return error.OutOfMemory;
        }

        return responses.toOwnedSlice(allocator);
    }

    const query_string = @embedFile("queries/import_letterboxd_ratings.sql");
};

const assertAllSameLength = @import("../../util/assertSameLength.zig").assertAllSameLength;

const Connection = @import("../../database.zig").Connection;
const Pool = @import("../../database.zig").Pool;
const DatabaseErrors = @import("../../database.zig").DatabaseErrors;
const ErrorHandler = @import("../../database.zig").ErrorHandler;

const ProgressStatus = @import("../content/media.zig").ProgressStatus;

const UUID = @import("../../util/uuid.zig");

const Allocator = std.mem.Allocator;
const std = @import("std");
