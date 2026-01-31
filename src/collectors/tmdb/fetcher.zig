const log = std.log.scoped(.tmdb_fetcher);

const AMOUNT_OF_THREADS = 10;

pub const Response = struct {
    total_amount: i64,
};

/// Callers have the responsibility of registering the active job to the manager.
pub fn run(
    allocator: Allocator,
    manager: *Manager,
    database: *Database,
    user_id: []const u8,
    api_key: []const u8,
    requests_per_second: u32,
    batch_size: u32,
) !Response {
    const state = try allocator.create(State);

    const headers = try std.fmt.allocPrintSentinel(allocator, "Authorization: Bearer {s}", .{api_key}, 0);

    const ca_bundle = try allocator.create(std.array_list.Managed(u8));
    ca_bundle.* = try curl.allocCABundle(allocator);

    const handle_pool = try HandlePool.init(allocator, AMOUNT_OF_THREADS, ca_bundle.*);

    state.* = State{
        .allocator = allocator,
        .database = database,
        .user_id = try allocator.dupe(u8, user_id),
        .pool = undefined,
        .handle_pool = handle_pool,
        .requests_per_second = requests_per_second,
        .movie_list = std.MultiArrayList(DatabaseRepresentation.Movie).empty,
        .staff_list = std.MultiArrayList(DatabaseRepresentation.Staff).empty,
        .image_list = std.MultiArrayList(DatabaseRepresentation.Image).empty,
        .genre_list = std.MultiArrayList(DatabaseRepresentation.Genre).empty,
        .headers = headers,
        .ca_bundle = ca_bundle,
        .batch_size = batch_size,
        .manager = manager,
        .thread = undefined,
    };

    state.thread = try std.Thread.spawn(
        .{ .allocator = allocator },
        Fetch.callSupressError,
        .{
            Fetch.Req{
                .state = state,
            },
        },
    );

    try state.pool.init(.{
        .allocator = allocator,
        .n_jobs = AMOUNT_OF_THREADS,
    });

    const total_amount = try GetNotCompletedCount.call(database, .{ .provider = "tmdb", .status = .todo });

    try manager.register(.tmdb, state);

    return .{
        .total_amount = total_amount,
    };
}

const Fetch = struct {
    const Req = struct {
        state: *State,
    };
    pub fn callSupressError(request: Req) void {
        defer request.state.deinit();
        call(request) catch |err| {
            switch (err) {
                // if it was cancelled, exit early and do not unregister
                error.Cancelled => return,
                else => log.err("Fetch failed! {}", .{err}),
            }
        };

        // this will only be reached if the cancellation was reached "naturally" (end of stream)
        // or non-cancellation error
        request.state.manager.unregister(.tmdb);
    }

    pub fn call(request: Req) !void {
        while (true) {
            if (request.state.is_cancelled.load(.monotonic)) return error.Cancelled;

            var batch_wg: std.Thread.WaitGroup = .{};
            const not_completed_request = GetNotCompleted.Request{
                .provider = "tmdb",
                .limit = request.state.batch_size,
            };

            var handled_id_count: usize = 0;
            // the contents of id_list are allocated strings
            const id_list = GetNotCompleted.call(request.state.allocator, request.state.database, not_completed_request) catch |err| {
                log.err("GetNotCompleted failed! {}", .{err});
                return err;
            };
            defer {
                for (id_list[handled_id_count..]) |id| request.state.allocator.free(id);
                request.state.allocator.free(id_list);
            }

            if (id_list.len == 0) break;

            var rate_limiter = RateLimiter.init(
                request.state.allocator,
                1 * std.time.ms_per_s,
                request.state.requests_per_second,
            );
            defer rate_limiter.deinit();

            for (id_list) |id| {
                if (request.state.is_cancelled.load(.monotonic)) return error.Cancelled;
                handled_id_count += 1;
                request.state.checkBackoff();
                const wait_time = rate_limiter.waitTime(std.time.milliTimestamp());
                if (wait_time > 0) std.Thread.sleep(@intCast(wait_time * std.time.ns_per_ms));

                const url = try std.fmt.allocPrintSentinel(request.state.allocator, "https://api.themoviedb.org/3/movie/{s}?append_to_response=credits,images", .{id}, 0);
                rate_limiter.addRequest(std.time.milliTimestamp()) catch |err| {
                    log.err("rate limited failed to add request! {}", .{err});
                    return err;
                };

                batch_wg.start();
                try request.state.pool.spawn(Request.callSupressError, .{
                    Request.Req{
                        .state = request.state,
                        .wg = &batch_wg,
                        .id = id,
                        .url = url,
                        .headers = request.state.headers,
                    },
                });
            }

            batch_wg.wait();
            request.state.mutex.lock();
            try request.state.flushLocked();

            request.state.mutex.unlock();
        }
    }
};

const Request = struct {
    const Req = struct {
        state: *State,
        wg: *std.Thread.WaitGroup,
        id: []u8,
        url: [:0]u8,
        headers: [:0]u8,
    };
    pub fn callSupressError(request: Req) void {
        call(request) catch |err| {
            log.err("Request failed! {}", .{err});
        };
    }

    pub fn call(request: Req) !void {
        var id_owned = true;
        defer {
            if (id_owned) request.state.allocator.free(request.id);
            request.wg.finish();
            request.state.allocator.free(request.url);
        }

        const easy = request.state.handle_pool.acquire() orelse {
            @panic("no handles!");
        };
        defer request.state.handle_pool.release(easy) catch |err| {
            std.debug.panic("error releasing: {}", .{err});
        };

        const max_retries = 5;
        var attempt: u32 = 0;

        while (attempt < max_retries) : (attempt += 1) {
            if (request.state.is_cancelled.load(.monotonic)) return error.Cancelled;

            request.state.checkBackoff();

            // 5kb
            var writer = try std.Io.Writer.Allocating.initCapacity(request.state.allocator, 1024 * 5);

            defer writer.deinit();

            const resp = try easy.fetch(
                request.url,
                .{
                    .headers = &.{request.headers},
                    .writer = &writer.writer,
                },
            );

            switch (resp.status_code) {
                200 => {},
                429 => {
                    const base_delay: u64 = @as(u64, 1) << @intCast(attempt);
                    const delay_ms = base_delay * 1000;

                    const jitter = std.crypto.random.intRangeAtMost(u64, 0, 500);
                    const total_wait = delay_ms + jitter;

                    log.warn("429 received. Backing off for {}ms (Attempt {}/{})", .{ total_wait, attempt + 1, max_retries });

                    const new_wait_until = std.time.milliTimestamp() + @as(i64, @intCast(total_wait));

                    var current = request.state.backoff.load(.monotonic);
                    while (new_wait_until > current) {
                        current = request.state.backoff.cmpxchgStrong(current, new_wait_until, .monotonic, .monotonic) orelse break;
                    }
                    continue;
                },
                404 => {
                    log.debug("Status code {}, {s} was not found!", .{ resp.status_code, request.url });
                    return;
                },
                else => {
                    log.err("Status code: {} on {s}", .{ resp.status_code, request.url });
                    break;
                },
            }

            var scanner = std.json.Scanner.initCompleteInput(request.state.allocator, writer.written());
            defer scanner.deinit();

            const response: std.json.Parsed(MovieIDResponse) = std.json.parseFromTokenSource(
                MovieIDResponse,
                request.state.allocator,
                &scanner,
                .{
                    .ignore_unknown_fields = true,
                    .allocate = .alloc_always,
                },
            ) catch |err| {
                log.err("failed to parse response for {s}! {}", .{ request.url, err });
                return err;
            };

            defer response.deinit();

            {
                request.state.mutex.lock();

                defer request.state.mutex.unlock();

                try Request.insertMovie(request, response.value);

                try Request.insertStaff(request, response.value);

                try Request.insertImages(request, response.value);

                try Request.insertGenres(request, response.value);

                if (request.state.movie_list.items(.id).len >= request.state.batch_size) {
                    try request.state.flushLocked();
                }
            }

            id_owned = false;
            // if we are here, congratulations, the request went through
            return;
        }
        log.err("Giving up on {s} after {} tries", .{ request.url, attempt });
    }

    fn insertMovie(request: Req, response: MovieIDResponse) !void {
        const title = try request.state.allocator.dupe(u8, response.title);
        errdefer request.state.allocator.free(title);

        const release_date = try request.state.allocator.dupe(u8, response.release_date);
        errdefer request.state.allocator.free(release_date);

        const runtime_minute: ?i64 = if (response.runtime == 0) null else @intCast(response.runtime);

        const description = try request.state.allocator.dupe(u8, response.overview);
        errdefer request.state.allocator.free(description);

        try request.state.movie_list.append(request.state.allocator, .{
            .id = request.id,
            .release_date = release_date,
            .title = title,
            .runtime_minutes = runtime_minute,
            .description = description,
            .provider = "tmdb",
        });
    }

    fn insertStaff(request: Req, response: MovieIDResponse) !void {
        for (response.credits.cast) |cast| {
            try request.state.staff_list.append(request.state.allocator, .{
                .full_name = try request.state.allocator.dupe(u8, cast.name),
                .id = try std.fmt.allocPrint(request.state.allocator, "{}", .{cast.id}),
                .media_id = request.id,
                .role_name = "Cast",
                .bio = null,
                .character_name = try request.state.allocator.dupe(u8, cast.character),
                .provider = "tmdb",
            });
        }

        for (response.credits.crew) |crew| {
            try request.state.staff_list.append(request.state.allocator, .{
                .full_name = try request.state.allocator.dupe(u8, crew.name),
                .id = try std.fmt.allocPrint(request.state.allocator, "{}", .{crew.id}),
                .media_id = request.id,
                .bio = null,
                .role_name = "Crew",
                .character_name = null,
                .provider = "tmdb",
            });
        }
    }

    fn insertImages(request: Req, response: MovieIDResponse) !void {
        inline for (@typeInfo(MovieIDResponse.Images.ImageType).@"enum".fields) |field| {
            for (@field(response.images, field.name)) |img| {
                const image: MovieIDResponse.Images.Image = img;
                try request.state.image_list.append(request.state.allocator, .{
                    .width = image.width,
                    .height = image.height,
                    .path = try request.state.allocator.dupe(u8, image.file_path),
                    .image_type = switch (@as(MovieIDResponse.Images.ImageType, @enumFromInt(field.value))) {
                        .backdrops => .backdrop,
                        .posters => .poster,
                        .logos => .logo,
                    },
                    .provider = "tmdb",
                    .media_id = request.id,
                    // TODO: some default primary logic
                    .is_primary = false,
                });
            }
        }
    }

    fn insertGenres(request: Req, response: MovieIDResponse) !void {
        for (response.genres) |genre| {
            try request.state.genre_list.append(request.state.allocator, .{
                .name = try request.state.allocator.dupe(u8, genre.name),
                .media_id = request.id,
            });
        }
    }
};

const Model = struct {
    const Req = struct {
        state: *State,
        movies: std.MultiArrayList(DatabaseRepresentation.Movie),
        staff: std.MultiArrayList(DatabaseRepresentation.Staff),
        images: std.MultiArrayList(DatabaseRepresentation.Image),
        genres: std.MultiArrayList(DatabaseRepresentation.Genre),
    };
    pub fn callSupressError(request: Req) void {
        call(request) catch |err| {
            log.err("Model failed! {}", .{err});
        };
    }

    pub fn call(request: Req) !void {
        defer {
            defer request.state.wg.finish();
            const items = .{
                request.movies,
                request.staff,
                request.images,
                request.genres,
            };
            inline for (items) |item| {
                var mutable_data = item;
                const sl = item.slice();
                for (0..sl.len) |i| sl.get(i).deinit(request.state.allocator);
                mutable_data.deinit(request.state.allocator);
            }
        }

        var arena = std.heap.ArenaAllocator.init(request.state.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var timer = try std.time.Timer.start();
        defer log.debug("writing to database took {}", .{timer.lap() / 1_000_000});

        const conn = request.state.database.acquire() catch return error.CannotAcquireConnection;
        defer conn.release();

        try conn.begin();

        const movie_ids = try Model.createMovies(allocator, conn, request);

        var external_media_id_to_db_id = std.StringHashMap([]u8).init(allocator);
        for (request.movies.items(.id), movie_ids.ids) |external_id, db_id| {
            try external_media_id_to_db_id.put(external_id, db_id);
        }

        const people_response = try Model.createPeople(allocator, conn, request);

        try Model.createStaff(allocator, conn, people_response, external_media_id_to_db_id, request);

        try Model.createImages(allocator, conn, external_media_id_to_db_id, request);

        try Model.createGenres(allocator, conn, external_media_id_to_db_id, request);

        try Model.editStatus(conn, request);

        conn.commit() catch {
            log.err("Transaction did not go through!", .{});
            try conn.rollback();
        };
    }

    fn createMovies(allocator: Allocator, conn: *Conn, request: Req) !CreateMultipleMovies.Response {
        const movies_request: CreateMultipleMovies.Request = .{
            .external_ids = request.movies.items(.id),
            .titles = request.movies.items(.title),
            .user_id = request.state.user_id,
            .release_dates = request.movies.items(.release_date),
            .runtime_minutes = request.movies.items(.runtime_minutes),
            .descriptions = request.movies.items(.description),
            .providers = request.movies.items(.provider),
        };

        return CreateMultipleMovies.call(allocator, .{ .conn = conn }, movies_request) catch |err| {
            log.err("creating movie failed! {}", .{err});
            return err;
        };
    }

    fn createPeople(allocator: Allocator, conn: *Conn, request: Req) ![]CreateMultiplePeople.Response {
        const staff_request: CreateMultiplePeople.Request = .{
            .full_names = request.staff.items(.full_name),
            .bios = request.staff.items(.bio),
            .provider = request.staff.items(.provider),
            .external_ids = request.staff.items(.id),
        };

        // WARNING: doesn't return duplicates
        return CreateMultiplePeople.call(allocator, .{ .conn = conn }, staff_request) catch |err| {
            log.err("creating staff failed! {}", .{err});
            return err;
        };
    }

    fn createStaff(
        allocator: Allocator,
        conn: *Conn,
        people: []CreateMultiplePeople.Response,
        media_id_map: std.StringHashMap([]u8),
        request: Req,
    ) !void {
        const person_ids = blk: {
            const ids = try allocator.alloc([]const u8, request.staff.len);

            var map = std.StringHashMap([]const u8).init(allocator);

            for (people) |res| {
                try map.put(res.external_id, res.person_id);
            }

            for (request.staff.items(.id), 0..) |external_id, i| {
                ids[i] = map.get(external_id) orelse {
                    log.err("external id not in map!", .{});
                    return error.ExternalIDNotInMap;
                };
            }
            break :blk ids;
        };

        const staff_media_ids = blk: {
            const ids = try allocator.alloc([]const u8, request.staff.len);

            for (request.staff.items(.media_id), 0..) |external_id, i| {
                ids[i] = media_id_map.get(external_id) orelse {
                    log.debug("Staff: Movie {s} doesnt have an id inside the map!", .{external_id});
                    return error.MovieNotInsideMap;
                };
            }
            break :blk ids;
        };

        const media_staff_request: CreateMultipleMediaStaff.Request = .{
            .media_ids = staff_media_ids,
            .role_names = request.staff.items(.role_name),
            .person_ids = person_ids,
            .character_names = request.staff.items(.character_name),
        };
        CreateMultipleMediaStaff.call(.{ .conn = conn }, media_staff_request) catch |err| {
            log.debug("Couldn't create staff! {}", .{err});
            return err;
        };
    }
    fn createImages(
        allocator: Allocator,
        conn: *Conn,
        media_id_map: std.StringHashMap([]u8),
        request: Req,
    ) !void {
        const image_media_ids = blk: {
            const ids = try allocator.alloc([]const u8, request.images.len);

            for (request.images.items(.media_id), 0..) |external_id, i| {
                ids[i] = media_id_map.get(external_id) orelse {
                    log.debug("Images: Movie {s} doesnt have an id inside the map!", .{external_id});
                    return error.MovieNotInsideMap;
                };
            }
            break :blk ids;
        };

        const images_request: CreateMultipleImages.Request = .{
            .media_ids = image_media_ids,
            .image_type = request.images.items(.image_type),
            .width = request.images.items(.width),
            .height = request.images.items(.height),
            .provider_id = request.images.items(.provider),
            .path = request.images.items(.path),
            .is_primary = request.images.items(.is_primary),
        };
        CreateMultipleImages.call(.{ .conn = conn }, images_request) catch |err| {
            log.debug("Couldn't create images! {}", .{err});
            return err;
        };
    }

    fn createGenres(
        allocator: Allocator,
        conn: *Conn,
        media_id_map: std.StringHashMap([]u8),
        request: Req,
    ) !void {
        const genre_media_id = blk: {
            const ids = try allocator.alloc([]const u8, request.genres.len);

            for (request.genres.items(.media_id), 0..) |external_id, i| {
                ids[i] = media_id_map.get(external_id) orelse {
                    log.debug("Genre: Movie {s} doesnt have an id inside the map!", .{external_id});
                    return error.MovieNotInsideMap;
                };
            }
            break :blk ids;
        };

        const genres_request: CreateMultipleGenres.Request = .{
            .media_ids = genre_media_id,
            .names = request.genres.items(.name),
        };

        CreateMultipleGenres.call(.{ .conn = conn }, genres_request) catch |err| {
            log.debug("Couldn't create genres! {}", .{err});
            return err;
        };
    }

    fn editStatus(conn: *Conn, request: Req) !void {
        const edit_status_request: EditStatus.Request = .{
            .provider = "tmdb",
            .external_id = request.movies.items(.id),
            .status = .completed,
        };
        EditStatus.call(.{ .conn = conn }, edit_status_request) catch |err| {
            log.err("updating status failed! {}", .{err});
            return err;
        };
    }
};

/// Trimmed down version of the original schema (located in ./types.zig) which contains only the information we need
const MovieIDResponse = struct {
    genres: []MovieIDResponse.Genre,
    overview: []const u8,
    release_date: []const u8,
    runtime: i64,
    title: []const u8,
    credits: Credits,
    images: Images,

    pub const Credits = struct {
        cast: []Cast,
        crew: []Crew,

        pub const Cast = struct {
            id: u64,
            name: []const u8,
            original_name: []const u8,
            cast_id: u64,
            character: []const u8,
        };

        pub const Crew = struct {
            adult: bool,
            id: u64,
            name: []const u8,
            credit_id: []const u8,
            job: []const u8,
        };
    };

    pub const Images = struct {
        backdrops: []Image,
        logos: []Image,
        posters: []Image,

        const ImageType = enum { backdrops, logos, posters };

        pub const Image = struct {
            height: i32,
            file_path: []const u8,
            width: i32,
        };
    };

    pub const Genre = struct {
        id: i64,
        name: []const u8,
    };
};

const DatabaseRepresentation = struct {
    const Movie = struct {
        id: []const u8,
        title: []const u8,
        release_date: []const u8,
        runtime_minutes: ?i64,
        description: ?[]const u8,
        provider: []const u8,

        fn deinit(self: @This(), allocator: std.mem.Allocator) void {
            allocator.free(self.id);
            allocator.free(self.title);
            allocator.free(self.release_date);
            if (self.description) |description| allocator.free(description);
        }
    };

    pub const Staff = struct {
        id: []const u8,
        full_name: []const u8,
        provider: []const u8,
        bio: ?[]const u8,
        role_name: []const u8,
        character_name: ?[]const u8,
        /// The TMDB ID of the movie the staff participates in
        media_id: []const u8,

        fn deinit(self: @This(), allocator: std.mem.Allocator) void {
            allocator.free(self.full_name);
            allocator.free(self.id);
            if (self.character_name) |character_name| allocator.free(character_name);
        }
    };

    pub const Image = struct {
        width: i32,
        height: i32,
        path: []const u8,
        image_type: ImageType,
        is_primary: bool,
        provider: []const u8,
        /// The TMDB ID of the movie the staff participates in
        media_id: []const u8,

        pub fn deinit(self: @This(), allocator: Allocator) void {
            allocator.free(self.path);
        }
    };

    pub const Genre = struct {
        name: []const u8,
        /// The TMDB ID of the movie the staff participates in
        media_id: []const u8,
        pub fn deinit(self: @This(), allocator: Allocator) void {
            allocator.free(self.name);
        }
    };
};
pub const State = struct {
    allocator: Allocator,
    database: *Database,
    user_id: []const u8,
    requests_per_second: u32,
    batch_size: u32,
    headers: [:0]u8,
    ca_bundle: *std.array_list.Managed(u8),

    pool: std.Thread.Pool,
    thread: std.Thread,
    handle_pool: HandlePool,

    mutex: std.Thread.Mutex = .{},
    wg: std.Thread.WaitGroup = .{},
    movie_list: std.MultiArrayList(DatabaseRepresentation.Movie),
    image_list: std.MultiArrayList(DatabaseRepresentation.Image),
    staff_list: std.MultiArrayList(DatabaseRepresentation.Staff),
    genre_list: std.MultiArrayList(DatabaseRepresentation.Genre),
    backoff: std.atomic.Value(i64) = .init(0),

    is_cancelled: std.atomic.Value(bool) = .init(false),
    manager: *Manager,

    fn flushLocked(self: *State) !void {
        if (self.is_cancelled.load(.monotonic)) return error.Cancelled;

        if (self.movie_list.len == 0) return;

        const movie = self.movie_list;
        self.movie_list = std.MultiArrayList(DatabaseRepresentation.Movie).empty;

        const image = self.image_list;
        self.image_list = std.MultiArrayList(DatabaseRepresentation.Image).empty;

        const staff = self.staff_list;
        self.staff_list = std.MultiArrayList(DatabaseRepresentation.Staff).empty;

        const genre = self.genre_list;
        self.genre_list = std.MultiArrayList(DatabaseRepresentation.Genre).empty;

        self.wg.start();
        self.pool.spawn(Model.callSupressError, .{Model.Req{
            .state = self,
            .movies = movie,
            .staff = staff,
            .images = image,
            .genres = genre,
        }}) catch |err| {
            self.wg.finish();
            return err;
        };
    }
    fn checkBackoff(self: *State) void {
        while (true) {
            const now = std.time.milliTimestamp();
            const wait_until = self.backoff.load(.monotonic);
            if (now >= wait_until) break;

            const diff = wait_until - now;
            std.Thread.sleep(@intCast(diff * std.time.ns_per_ms));
        }
    }
    pub fn deinit(self: *State) void {
        self.is_cancelled.store(true, .monotonic);

        self.wg.wait();

        self.pool.deinit();

        // clean up leftover data, in case this is a cancellation deinit
        const items = .{
            &self.movie_list,
            &self.staff_list,
            &self.image_list,
            &self.genre_list,
        };
        inline for (items) |item| {
            var movie_slice = item.slice();
            for (0..movie_slice.len) |i| movie_slice.get(i).deinit(self.allocator);
            item.deinit(self.allocator);
        }

        self.allocator.free(self.headers);
        self.allocator.free(self.user_id);

        self.handle_pool.deinit();
        self.ca_bundle.deinit();

        self.allocator.destroy(self.ca_bundle);
        self.allocator.destroy(self);
    }
};

const RateLimiter = @import("../../rate_limiter.zig").RateLimiter;
const HandlePool = @import("../fetchers.zig").HandlePool;

const ImageType = @import("../../models/content/content.zig").ImageType;

const GetNotCompleted = @import("../../models/collectors/collectors.zig").GetNotCompleted;
const GetNotCompletedCount = @import("../../models/collectors/collectors.zig").GetNotCompletedCount;
const EditStatus = @import("../../models/collectors/collectors.zig").EditStatus;

const CreateMultipleMovies = @import("../../models/content/content.zig").Movies.CreateMultiple;
const CreateMultipleGenres = @import("../../models/content/content.zig").CreateMultipleGenres;
const CreateMultiplePeople = @import("../../models/content/content.zig").CreateMultiplePeople;
const CreateMultipleMediaStaff = @import("../../models/content/content.zig").CreateMultipleMediaStaff;
const CreateMultipleImages = @import("../../models/content/content.zig").CreateMultipleImages;

const Manager = @import("../fetchers.zig").Manager;

const Conn = @import("../../database.zig").Conn;
const Database = @import("../../database.zig").Pool;

const curl = @import("curl");

const Allocator = std.mem.Allocator;
const std = @import("std");
