const log = std.log.scoped(.media_model);

pub const ProgressStatus = enum {
    planned,
    in_progress,
    completed,
    dropped,
};

pub const ProgressUnit = enum {
    quantity,
    percentage,
};

pub const GetInformation = struct {
    pub const Request = struct {
        media_id: []const u8,
    };

    pub const MediaType = enum { movie, book };

    pub const Response = struct {
        id: []u8,
        title: []u8,
        media_type: MediaType,
        release_date: ?i64,
        data: union(MediaType) {
            movie: MovieData,
            book: BookData,
        },

        pub const MovieData = struct {
            // movie specific fields
            runtime_minutes: ?i64,

            pub fn deinit(self: MovieData, allocator: Allocator) void {
                _ = self;
                _ = allocator;
            }
        };

        /// book specific fields
        pub const BookData = struct {
            total_pages: ?i32,

            pub fn deinit(self: BookData, allocator: Allocator) void {
                _ = self;
                _ = allocator;
            }
        };

        pub fn deinit(self: Response, allocator: Allocator) void {
            allocator.free(self.id);
            allocator.free(self.title);
            switch (self.data) {
                inline else => |data| {
                    data.deinit(allocator);
                },
            }
        }
    };

    pub const Errors = error{
        CannotGet,
        NotFound,
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
                request.media_id,
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
            id: []u8,
            title: []u8,
            media_type: MediaType,
            release_date: ?i64,
            // movie specific fields
            runtime_minutes: ?i64,
            // book specific fields
            total_pages: ?i32,
        };

        const response = row.to(DatabaseResponse, .{}) catch |err| {
            log.err("Couldn't parse response! {}", .{err});
            return error.CannotGet;
        };

        const id = try UUID.toStringAlloc(allocator, response.id);
        errdefer allocator.free(id);

        const title = allocator.dupe(u8, response.title) catch return error.OutOfMemory;
        errdefer allocator.free(title);

        return Response{
            .id = id,
            .title = title,
            .media_type = response.media_type,
            .release_date = response.release_date,
            .data = switch (response.media_type) {
                .movie => blk: {
                    break :blk .{
                        .movie = .{
                            .runtime_minutes = response.runtime_minutes,
                        },
                    };
                },
                .book => blk: {
                    break :blk .{
                        .book = .{
                            .total_pages = response.total_pages,
                        },
                    };
                },
            },
        };
    }

    const query_string = @embedFile("queries/get_media.sql");
};

test "Model | Media | Get" {
    const allocator = std.testing.allocator;

    const test_env = Tests.test_env;
    const test_name = "Model | Media | Get";
    var setup = try TestSetup.init(test_env.database_pool, test_name);
    defer setup.deinit(allocator);
    const connection: Connection = .{ .database = test_env.database_pool };

    const BookCreate = @import("../books/books.zig").Create;
    const book_request: BookCreate.Request = .{
        .title = test_name,
        .user_id = setup.user.id,
        .release_date = "01-01-2000",
        .total_pages = 100,
        .description = null,
    };

    const book_response = try BookCreate.call(
        allocator,
        connection,
        book_request,
    );
    defer book_response.deinit(allocator);

    const request: GetInformation.Request = .{
        .media_id = book_response.id,
    };

    const response = try GetInformation.call(allocator, connection, request);
    defer response.deinit(allocator);

    try std.testing.expectEqualStrings(book_response.id, response.id);
    try std.testing.expectEqual(GetInformation.MediaType.book, response.media_type);
    try std.testing.expectEqualStrings(book_request.title, response.title);
}

test "Model | Media | Get | Allocation Failures" {
    const allocator = std.testing.allocator;

    const test_env = Tests.test_env;
    const test_name = "Model | Media | Get | Allocation Failures";
    var setup = try TestSetup.init(test_env.database_pool, test_name);
    defer setup.deinit(allocator);
    const connection: Connection = .{ .database = test_env.database_pool };

    const BookCreate = @import("../books/books.zig").Create;
    const book_request: BookCreate.Request = .{
        .title = test_name,
        .user_id = setup.user.id,
        .release_date = "01-01-2000",
        .total_pages = 100,
        .description = null,
    };

    const book_response = try BookCreate.call(
        allocator,
        connection,
        book_request,
    );
    defer book_response.deinit(allocator);

    const request: GetInformation.Request = .{
        .media_id = book_response.id,
    };

    try std.testing.checkAllAllocationFailures(
        allocator,
        struct {
            fn call(alloc: Allocator, conn: Connection, req: GetInformation.Request) !void {
                const response = try GetInformation.call(alloc, conn, req);
                response.deinit(allocator);
            }
        }.call,
        .{ connection, request },
    );
}

// TODO: test
pub const Search = struct {
    pub const Request = struct {
        search: []const u8,
        limit: i64 = 50,
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
        CannotGet,
        NotFound,
        OutOfMemory,
        CannotParseID,
    } || DatabaseErrors;

    /// Caller owns slice.
    pub fn call(allocator: std.mem.Allocator, connection: Connection, request: Request) Errors![]Response {
        var conn = try connection.acquire();
        defer connection.release(conn);

        const error_handler = ErrorHandler{ .conn = conn };
        var query = conn.query(query_string, .{
            request.search,
            request.limit,
        }) catch |err| {
            const error_data = error_handler.handle(err);
            if (error_data) |data| {
                ErrorHandler.printErr(data);
            }
            return error.CannotGet;
        };
        defer query.deinit();

        var responses: std.ArrayList(Response) = try .initCapacity(allocator, @intCast(request.limit));
        defer responses.deinit(allocator);

        while (query.next() catch return error.NotFound) |row| {
            responses.appendAssumeCapacity(.{
                .id = try UUID.toStringAlloc(allocator, row.get([]u8, 0)),
                .title = try allocator.dupe(u8, row.get([]u8, 1)),
            });
        }

        if (responses.items.len == 0) return error.NotFound;

        return responses.toOwnedSlice(allocator);
    }

    const query_string = @embedFile("queries/search_media.sql");
};

// TODO: test
pub const CreateRating = struct {
    pub const Request = struct {
        user_id: []const u8,
        media_id: []const u8,
        /// [0,10]
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
        OutOfMemory,
        CannotParseID,
    } || DatabaseErrors;

    pub fn call(allocator: std.mem.Allocator, database: *Pool, request: Request) Errors!Response {
        var conn = database.acquire() catch return error.CannotAcquireConnection;
        defer conn.release();
        const error_handler = ErrorHandler{ .conn = conn };
        var row = conn.row(query_string, .{
            request.user_id,
            request.media_id,
            request.rating_score,
        }) catch |err| {
            const error_data = error_handler.handle(err);
            if (error_data) |data| {
                ErrorHandler.printErr(data);
            }
            return error.CannotCreate;
        } orelse return error.CannotCreate;
        defer row.deinit() catch {};

        const id = blk: {
            const buf = UUID.toString(row.get([]u8, 0)) catch return error.CannotParseID;
            break :blk allocator.dupe(u8, &buf) catch return error.OutOfMemory;
        };

        return Response{
            .id = id,
        };
    }

    const query_string = @embedFile("queries/create_rating.sql");
};

// TODO: test
pub const GetRating = struct {
    pub const Request = struct {
        user_id: []const u8,
        media_id: []const u8,
    };

    pub const Response = struct {
        id: []const u8,
        rating_score: u8,
        created_at: i64,

        pub fn deinit(self: Response, allocator: Allocator) void {
            allocator.free(self.id);
        }
    };

    pub const Errors = error{
        CannotGet,
        NotFound,
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
                request.media_id,
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

        // NOTE: needed as rating_score validation is done on the server and not in the database
        const DatabaseResponse = struct {
            id: []u8,
            rating_score: i32,
            created_at: i64,
        };

        var responses: std.ArrayList(Response) = .empty;
        defer responses.deinit(allocator);

        var mapper = query.mapper(DatabaseResponse, .{});
        while (mapper.next() catch return error.CannotGet) |response| {
            responses.append(allocator, .{
                .id = try UUID.toStringAlloc(allocator, response.id),
                .created_at = response.created_at,
                .rating_score = std.math.cast(u8, response.rating_score) orelse return error.InvalidRatingScore,
            }) catch return error.OutOfMemory;
        }

        return responses.toOwnedSlice(allocator) catch return error.OutOfMemory;
    }

    const query_string = @embedFile("queries/get_rating.sql");
};

// TODO: test
pub const EditRating = struct {
    pub const Request = struct {
        user_id: []const u8,
        rating_id: []const u8,
        /// [0,10]
        rating_score: u8,
    };

    pub const Response = struct {
        id: []const u8,
        rating_score: u8,
        created_at: i64,

        pub fn deinit(self: Response, allocator: Allocator) void {
            allocator.free(self.id);
        }
    };

    pub const Errors = error{
        CannotEdit,
        NotFound,
        InvalidRatingScore,
        OutOfMemory,
        CannotParseID,
    } || DatabaseErrors;

    pub fn call(allocator: std.mem.Allocator, database: *Pool, request: Request) Errors!Response {
        var conn = database.acquire() catch return error.CannotAcquireConnection;
        defer conn.release();
        const error_handler = ErrorHandler{ .conn = conn };
        var row = conn.rowOpts(query_string, .{
            request.rating_id,
            request.user_id,
            request.rating_score,
        }, .{
            .column_names = true,
        }) catch |err| {
            const error_data = error_handler.handle(err);
            if (error_data) |data| {
                ErrorHandler.printErr(data);
            }
            return error.CannotEdit;
        } orelse return error.NotFound;
        defer row.deinit() catch {};

        // NOTE: needed as rating_score validation is done on the server and not in the database
        const DatabaseResponse = struct {
            id: []u8,
            rating_score: i32,
            created_at: i64,
        };

        var response = row.to(DatabaseResponse, .{
            .map = .name,
        }) catch |err| {
            log.err("Get Rating row.to failed! {}", .{err});
            return error.CannotEdit;
        };

        response.id = try UUID.toStringAlloc(allocator, response.id);

        return Response{
            .id = response.id,
            .rating_score = std.math.cast(u8, response.rating_score) orelse return error.InvalidRatingScore,
            .created_at = response.created_at,
        };
    }

    const query_string = @embedFile("queries/edit_rating.sql");
};

// TODO: test
pub const CreateProgress = struct {
    pub const Request = struct {
        user_id: []const u8,
        media_id: []const u8,
        status: ProgressStatus,
        progress_value: f64,
        progress_unit: ProgressUnit,
    };

    pub const Response = struct {
        id: []const u8,
        user_id: []const u8,
        media_id: []const u8,
        status: ProgressStatus,
        progress_value: f64,
        progress_unit: ProgressUnit,
        created_at: i64,

        pub fn deinit(self: Response, allocator: Allocator) void {
            allocator.free(self.id);
            allocator.free(self.user_id);
            allocator.free(self.media_id);
        }
    };

    pub const Errors = error{
        CannotCreate,
        OutOfMemory,
        CannotParseID,
    } || DatabaseErrors;

    pub fn call(allocator: Allocator, database: *Pool, request: Request) Errors!Response {
        var conn = database.acquire() catch return error.CannotAcquireConnection;
        defer conn.release();

        const error_handler = ErrorHandler{ .conn = conn };
        var row = conn.rowOpts(query_string, .{
            request.user_id,
            request.media_id,
            request.status,
            request.progress_value,
            request.progress_unit,
        }, .{
            .column_names = true,
        }) catch |err| {
            const error_data = error_handler.handle(err);
            if (error_data) |data| {
                ErrorHandler.printErr(data);
            }

            return error.CannotCreate;
        } orelse return error.CannotCreate;
        defer row.deinit() catch {};

        var response = row.to(Response, .{ .map = .name }) catch |err| {
            log.err("Failed to parse progress response! {}", .{err});
            return error.CannotCreate;
        };

        response.id = try UUID.toStringAlloc(allocator, response.id);
        response.media_id = try UUID.toStringAlloc(allocator, response.media_id);
        response.user_id = try UUID.toStringAlloc(allocator, response.user_id);

        return response;
    }

    const query_string = @embedFile("queries/create_progress.sql");
};

// TODO: test
pub const GetProgress = struct {
    pub const Request = struct {
        user_id: []const u8,
        media_id: []const u8,
    };

    pub const Response = struct {
        user_id: []const u8,
        media_id: []const u8,
        status: []const u8,
        progress_value: f64,
        progress_unit: ProgressUnit,
        completion_percentage: f64,
        updated_at: i64,

        pub fn deinit(self: Response, allocator: std.mem.Allocator) void {
            allocator.free(self.user_id);
            allocator.free(self.media_id);
            allocator.free(self.status);
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
        var row = conn.row(query_string, .{
            request.user_id,
            request.media_id,
        }) catch |err| {
            const error_data = error_handler.handle(err);
            if (error_data) |data| {
                ErrorHandler.printErr(data);
            }
            return error.CannotGet;
        } orelse return error.NotFound;
        defer row.deinit() catch {};

        var response = row.to(Response, .{ .allocator = allocator }) catch return error.CannotGet;
        const raw_id = response.media_id;
        defer allocator.free(raw_id);
        response.media_id = try UUID.toStringAlloc(allocator, raw_id);

        return response;
    }

    const query_string = @embedFile("queries/get_progress.sql");
};

// TODO: test
pub const CreateMultiplePeople = struct {
    pub const Request = struct {
        full_names: [][]const u8,
        bios: []?[]const u8,
        provider: [][]const u8,
        external_ids: [][]const u8,
    };

    pub const Response = struct {
        external_id: []const u8,
        person_id: []const u8,

        pub fn deinit(self: @This(), allocator: Allocator) void {
            allocator.free(self.external_id);
            allocator.free(self.person_id);
        }
    };

    pub const Errors = error{
        CouldntCreate,
        CannotAcquireConnection,
        MismatchedInputLengths,
        OutOfMemory,
    } || DatabaseErrors;

    pub fn call(allocator: Allocator, connection: Connection, request: Request) Errors![]Response {
        var conn = try connection.acquire();
        defer connection.release(conn);

        const error_handler = ErrorHandler{ .conn = conn };

        var query = conn.query(query_string, .{
            request.full_names,
            request.bios,
            request.provider,
            request.external_ids,
        }) catch |err| {
            if (error_handler.handle(err)) |data| {
                ErrorHandler.printErr(data);
            }
            return error.CouldntCreate;
        };
        defer query.deinit();

        var responses = std.ArrayList(Response).empty;
        defer responses.deinit(allocator);

        while (query.next() catch return error.CouldntCreate) |row| {
            const person_id = UUID.toStringAlloc(allocator, row.get([]u8, 0)) catch return error.CouldntCreate;
            const external_id = row.get([]u8, 1);

            try responses.append(allocator, .{
                .external_id = try allocator.dupe(u8, external_id),
                .person_id = person_id,
            });
        }

        return responses.toOwnedSlice(allocator);
    }

    const query_string = @embedFile("./queries/create_multiple_people.sql");
};

// TODO: test
pub const CreateMultipleMediaStaff = struct {
    pub const Request = struct {
        person_ids: [][]const u8,
        media_ids: [][]const u8,
        role_names: [][]const u8,
        character_names: []?[]const u8,
    };

    const Response = void;

    pub const Errors = error{
        CouldntCreate,
        CannotAcquireConnection,
        MismatchedInputLengths,
    } || DatabaseErrors;

    pub fn call(connection: Connection, request: Request) Errors!Response {
        var conn = try connection.acquire();
        defer connection.release(conn);

        const error_handler = ErrorHandler{ .conn = conn };

        _ = conn.exec(query_string, .{
            request.media_ids,
            request.person_ids,
            request.role_names,
            request.character_names,
        }) catch |err| {
            if (error_handler.handle(err)) |data| {
                ErrorHandler.printErr(data);
            }

            return error.CouldntCreate;
        } orelse return error.CouldntCreate;
    }

    const query_string = @embedFile("./queries/create_multiple_media_staff.sql");
};

// TODO: test
pub const CreateMultipleImages = struct {
    pub const Request = struct {
        media_ids: [][]const u8,
        image_type: []ImageType,
        provider_id: [][]const u8,
        path: [][]const u8,
        is_primary: []bool,
    };

    const Response = void;

    pub const Errors = error{
        CouldntCreate,
        CannotAcquireConnection,
        MismatchedInputLengths,
    } || DatabaseErrors;

    pub fn call(connection: Connection, request: Request) Errors!Response {
        var conn = try connection.acquire();
        defer connection.release(conn);

        const error_handler = ErrorHandler{ .conn = conn };

        _ = conn.exec(query_string, .{
            request.media_ids,
            request.image_type,
            request.provider_id,
            request.path,
            request.is_primary,
        }) catch |err| {
            if (error_handler.handle(err)) |data| {
                ErrorHandler.printErr(data);
            }

            return error.CouldntCreate;
        } orelse return error.CouldntCreate;
    }

    const query_string = @embedFile("./queries/create_multiple_images.sql");
};

// TODO: test
pub const CreateMultipleGenres = struct {
    pub const Request = struct {
        media_ids: [][]const u8,
        names: [][]const u8,
    };

    const Response = void;

    pub const Errors = error{
        CouldntCreate,
        CannotAcquireConnection,
        MismatchedInputLengths,
    } || DatabaseErrors;

    pub fn call(connection: Connection, request: Request) Errors!Response {
        var conn = try connection.acquire();
        defer connection.release(conn);

        const error_handler = ErrorHandler{ .conn = conn };

        _ = conn.exec(query_string, .{
            request.media_ids,
            request.names,
        }) catch |err| {
            if (error_handler.handle(err)) |data| {
                ErrorHandler.printErr(data);
            }

            return error.CouldntCreate;
        } orelse return error.CouldntCreate;
    }

    const query_string = @embedFile("./queries/create_multiple_genres.sql");
};

const ImageType = @import("../content.zig").ImageType;

const Connection = @import("../../../database.zig").Connection;
const Pool = @import("../../../database.zig").Pool;
const DatabaseErrors = @import("../../../database.zig").DatabaseErrors;
const ErrorHandler = @import("../../../database.zig").ErrorHandler;

const Tests = @import("../../../tests/setup.zig");
const TestSetup = Tests.TestSetup;

const UUID = @import("../../../util/uuid.zig");
const JWTClaims = @import("../../../auth/tokens.zig").JWTClaims;

const Allocator = std.mem.Allocator;
const std = @import("std");
