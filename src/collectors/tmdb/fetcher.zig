const log = std.log.scoped(.tmdb_fetcher);

const AMOUNT_OF_THREADS = 10;

pub const Response = struct {
    total_amount: i64,
};

/// Callers have the responsibility of registering the active job to the manager.
pub fn fetch(
    allocator: Allocator,
    manager: *Manager,
    database: *Database,
    user_id: []const u8,
    api_key: []const u8,
    requests_per_second: u32,
    batch_size: u32,
) !Response {
    const state = try allocator.create(SharedState);

    const headers = try std.fmt.allocPrintSentinel(allocator, "Authorization: Bearer {s}", .{api_key}, 0);

    const ca_bundle = try allocator.create(std.array_list.Managed(u8));
    ca_bundle.* = try curl.allocCABundle(allocator);

    const handle_pool = try HandlePool.init(allocator, AMOUNT_OF_THREADS, ca_bundle.*);

    state.* = SharedState{
        .allocator = allocator,
        .database = database,
        .user_id = try allocator.dupe(u8, user_id),
        .pool = undefined,
        .handle_pool = handle_pool,
        .requests_per_second = requests_per_second,
        .movie_list = std.MultiArrayList(Movie).empty,
        .staff_list = std.MultiArrayList(Staff).empty,
        .image_list = std.MultiArrayList(Image).empty,
        .headers = headers,
        .ca_bundle = ca_bundle,
        .batch_size = batch_size,
        .manager = manager,
        .thread = undefined,
    };

    state.thread = try std.Thread.spawn(
        .{ .allocator = allocator },
        spawnFetchThread,
        .{
            state,
        },
    );

    try state.pool.init(.{
        .allocator = allocator,
        .n_jobs = AMOUNT_OF_THREADS,
    });

    const total_amount = try GetNotCompletedCount.call(database, .{ .provider = "tmdb", .status = .todo });

    try manager.register(state, .tmdb);

    return .{
        .total_amount = total_amount,
    };
}

fn spawnFetchThread(state: *SharedState) void {
    defer state.deinit();
    fetchImpl(state) catch {};
}

fn fetchImpl(state: *SharedState) !void {
    while (true) {
        if (state.is_cancelled.load(.monotonic)) return;
        const request = GetNotCompleted.Request{
            .provider = "tmdb",
            .limit = state.batch_size,
        };

        var handled_id_count: usize = 0;
        // the contents of id_list are allocated strings
        const id_list = GetNotCompleted.call(state.allocator, state.database, request) catch |err| {
            log.err("GetNotCompleted failed! {}", .{err});
            return err;
        };
        defer {
            for (id_list[handled_id_count..]) |id| state.allocator.free(id);
            state.allocator.free(id_list);
        }

        if (id_list.len == 0) break;

        var rate_limiter = RateLimiter.init(
            state.allocator,
            1 * std.time.ms_per_s,
            state.requests_per_second,
        );
        defer rate_limiter.deinit();

        for (id_list) |id| {
            if (state.is_cancelled.load(.monotonic)) return;
            handled_id_count += 1;
            state.checkBackoff();
            const wait_time = rate_limiter.waitTime(std.time.milliTimestamp());
            if (wait_time > 0) std.Thread.sleep(@intCast(wait_time * std.time.ns_per_ms));

            const url = try std.fmt.allocPrintSentinel(state.allocator, "https://api.themoviedb.org/3/movie/{s}?append_to_response=credits,images", .{id}, 0);
            rate_limiter.addRequest(std.time.milliTimestamp()) catch |err| {
                log.err("rate limited failed to add request! {}", .{err});
                return err;
            };

            state.wg.start();
            try state.pool.spawn(spawnRequestThread, .{
                state,
                id,
                url,
                state.headers,
            });
        }

        state.mutex.lock();
        try state.flushLocked();

        state.mutex.unlock();
    }
    std.debug.print("exited!\n", .{});
}

fn spawnRequestThread(state: *SharedState, id: []u8, url: [:0]u8, headers: [:0]u8) void {
    handleRequest(state, id, url, headers) catch |err| {
        log.debug("Request thread failed! {}", .{err});
    };
}

fn handleRequest(state: *SharedState, id: []u8, url: [:0]u8, headers: [:0]u8) !void {
    var id_owned = true;
    defer {
        if (id_owned) state.allocator.free(id);
        state.wg.finish();
        state.allocator.free(url);
    }

    const easy = state.handle_pool.acquire() orelse {
        @panic("no handles!");
    };
    defer state.handle_pool.release(easy) catch |err| {
        std.debug.panic("error releasing: {}", .{err});
    };

    const max_retries = 5;
    var attempt: u32 = 0;

    while (attempt < max_retries) : (attempt += 1) {
        if (state.is_cancelled.load(.monotonic)) return;

        state.checkBackoff();

        var writer = std.Io.Writer.Allocating.init(state.allocator);

        defer writer.deinit();

        const resp = try easy.fetch(
            url,
            .{
                .headers = &.{headers},
                .writer = &writer.writer,
            },
        );

        if (resp.status_code != 200) {
            log.debug("status code: {}", .{resp.status_code});
            continue;
        }
        if (resp.status_code == 429) {
            const base_delay: u64 = @as(u64, 1) << @intCast(attempt);
            const delay_ms = base_delay * 1000;

            const jitter = std.crypto.random.intRangeAtMost(u64, 0, 500);
            const total_wait = delay_ms + jitter;

            log.warn("429 received. Backing off for {}ms (Attempt {}/{})", .{ total_wait, attempt + 1, max_retries });

            const new_wait_until = std.time.milliTimestamp() + @as(i64, @intCast(total_wait));

            var current = state.backoff.load(.monotonic);
            while (new_wait_until > current) {
                current = state.backoff.cmpxchgStrong(current, new_wait_until, .monotonic, .monotonic) orelse break;
            }
            continue;
        }

        var scanner = std.json.Scanner.initCompleteInput(state.allocator, writer.written());
        defer scanner.deinit();
        var diag = std.json.Diagnostics{};
        scanner.enableDiagnostics(&diag);

        const response: std.json.Parsed(MovieIDResponse) = std.json.parseFromTokenSource(
            MovieIDResponse,
            state.allocator,
            &scanner,
            .{
                .ignore_unknown_fields = true,
                .allocate = .alloc_always,
            },
        ) catch |err| {
            log.err("failed to parse response for {s}! {}", .{ url, err });
            std.debug.print("byte offset: {d}\n", .{diag.getByteOffset()});
            std.debug.print("column: {d}\n", .{diag.getColumn()});
            std.debug.print("line: {d}\n", .{diag.getLine()});
            return err;
        };

        defer response.deinit();

        const title = try state.allocator.dupe(u8, response.value.title);
        errdefer state.allocator.free(title);

        const release_date = try state.allocator.dupe(u8, response.value.release_date);
        errdefer state.allocator.free(release_date);

        const runtime_minute: ?i64 = if (response.value.runtime == 0) null else @intCast(response.value.runtime);

        const description = try state.allocator.dupe(u8, response.value.overview);
        errdefer state.allocator.free(description);

        state.mutex.lock();

        defer state.mutex.unlock();

        try state.movie_list.append(state.allocator, .{
            .id = id,
            .release_date = release_date,
            .title = title,
            .runtime_minutes = runtime_minute,
            .description = description,
            .provider = "tmdb",
        });

        for (response.value.credits.cast) |cast| {
            try state.staff_list.append(state.allocator, .{
                .full_name = try state.allocator.dupe(u8, cast.name),
                .id = try std.fmt.allocPrint(state.allocator, "{}", .{cast.id}),
                .media_id = id,
                .role_name = "Cast",
                .bio = null,
                .character_name = try state.allocator.dupe(u8, cast.character),
                .provider = "tmdb",
            });
        }

        for (response.value.credits.crew) |crew| {
            try state.staff_list.append(state.allocator, .{
                .full_name = try state.allocator.dupe(u8, crew.name),
                .id = try std.fmt.allocPrint(state.allocator, "{}", .{crew.id}),
                .media_id = id,
                .bio = null,
                .role_name = "Crew",
                .character_name = null,
                .provider = "tmdb",
            });
        }

        inline for (@typeInfo(MovieIDResponse.Images.ImageType).@"enum".fields) |field| {
            for (@field(response.value.images, field.name)) |img| {
                const image: MovieIDResponse.Images.Img = img;
                try state.image_list.append(state.allocator, .{
                    .width = image.width,
                    .height = image.height,
                    .path = try state.allocator.dupe(u8, image.file_path),
                    .image_type = switch (@as(MovieIDResponse.Images.ImageType, @enumFromInt(field.value))) {
                        .backdrops => .backdrop,
                        .posters => .poster,
                        .logos => .logo,
                    },
                    .provider = "tmdb",
                    .media_id = id,
                    // TODO: some default primary logic
                    .is_primary = false,
                });
            }
        }
        if (state.movie_list.items(.id).len >= state.batch_size) {
            try state.flushLocked();
        }
        id_owned = false;
        // if we are here, congratulations, the request went through
        return;
    }
    log.err("Giving up on {s} after {} tries", .{ url, attempt });
}

fn spawnModelThread(state: *SharedState, movie: std.MultiArrayList(Movie), staff: std.MultiArrayList(Staff), images: std.MultiArrayList(Image)) void {
    handleModel(state, movie, staff, images) catch |err| {
        log.err("model failed! {}", .{err});
    };
}
fn handleModel(state: *SharedState, data: std.MultiArrayList(Movie), staff: std.MultiArrayList(Staff), images: std.MultiArrayList(Image)) !void {
    defer {
        defer state.wg.finish();
        {
            var mutable_data = data;
            const sl = data.slice();
            for (0..sl.len) |i| sl.get(i).deinit(state.allocator);
            mutable_data.deinit(state.allocator);
        }
        {
            var mutable_data = staff;
            const sl = staff.slice();
            for (0..sl.len) |i| sl.get(i).deinit(state.allocator);
            mutable_data.deinit(state.allocator);
        }
        {
            var mutable_data = images;
            const sl = images.slice();
            for (0..sl.len) |i| sl.get(i).deinit(state.allocator);
            mutable_data.deinit(state.allocator);
        }
    }

    var arena = std.heap.ArenaAllocator.init(state.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var timer = try std.time.Timer.start();
    defer log.debug("writing to database took {}", .{timer.lap() / 1_000_000});

    const conn = state.database.acquire() catch return error.CannotAcquireConnection;
    defer conn.release();

    try conn.begin();

    const movies_request: CreateMultipleMovies.Request = .{
        .external_ids = data.items(.id),
        .titles = data.items(.title),
        .user_id = state.user_id,
        .release_dates = data.items(.release_date),
        .runtime_minutes = data.items(.runtime_minutes),
        .descriptions = data.items(.description),
        .providers = data.items(.provider),
    };

    const movie_ids = CreateMultipleMovies.call(allocator, .{ .conn = conn }, movies_request) catch |err| {
        log.err("creating movie failed! {}", .{err});
        return err;
    };

    var external_media_id_to_db_id = std.StringHashMap([]u8).init(allocator);
    for (data.items(.id), movie_ids.ids) |external_id, db_id| {
        try external_media_id_to_db_id.put(external_id, db_id);
    }

    const staff_request: CreateMultiplePeople.Request = .{
        .full_names = staff.items(.full_name),
        .bios = staff.items(.bio),
        .provider = staff.items(.provider),
        .external_ids = staff.items(.id),
    };

    // WARNING: doesn't return duplicates
    const people_response = CreateMultiplePeople.call(allocator, .{ .conn = conn }, staff_request) catch |err| {
        log.err("creating staff failed! {}", .{err});
        return err;
    };

    const person_ids = blk: {
        const ids = try allocator.alloc([]const u8, staff.len);

        var map = std.StringHashMap([]const u8).init(allocator);

        for (people_response) |res| {
            try map.put(res.external_id, res.person_id);
        }

        for (staff.items(.id), 0..) |external_id, i| {
            ids[i] = map.get(external_id) orelse {
                log.err("external id not in map!", .{});
                return error.ExternalIDNotInMap;
            };
        }
        break :blk ids;
    };

    const staff_media_ids = blk: {
        const ids = try allocator.alloc([]const u8, staff.len);

        for (staff.items(.media_id), 0..) |external_id, i| {
            ids[i] = external_media_id_to_db_id.get(external_id) orelse {
                log.debug("Staff: Movie {s} doesnt have an id inside the map!", .{external_id});
                return error.MovieNotInsideMap;
            };
        }
        break :blk ids;
    };

    const media_staff_request: CreateMultipleMediaStaff.Request = .{
        .media_ids = staff_media_ids,
        .role_names = staff.items(.role_name),
        .person_ids = person_ids,
        .character_names = staff.items(.character_name),
    };
    CreateMultipleMediaStaff.call(.{ .conn = conn }, media_staff_request) catch |err| {
        log.debug("Couldn't create staff! {}", .{err});
        return err;
    };

    const image_media_ids = blk: {
        const ids = try allocator.alloc([]const u8, images.len);

        for (images.items(.media_id), 0..) |external_id, i| {
            ids[i] = external_media_id_to_db_id.get(external_id) orelse {
                log.debug("Images: Movie {s} doesnt have an id inside the map!", .{external_id});
                return error.MovieNotInsideMap;
            };
        }
        break :blk ids;
    };

    const images_request: CreateMultipleImages.Request = .{
        .media_ids = image_media_ids,
        .image_type = images.items(.image_type),
        .width = images.items(.width),
        .height = images.items(.height),
        .provider_id = images.items(.provider),
        .path = images.items(.path),
        .is_primary = images.items(.is_primary),
    };
    CreateMultipleImages.call(.{ .conn = conn }, images_request) catch |err| {
        log.debug("Couldn't create images! {}", .{err});
        return err;
    };

    const edit_status_request: EditStatus.Request = .{
        .provider = "tmdb",
        .external_id = data.items(.id),
        .status = .completed,
    };
    EditStatus.call(.{ .conn = conn }, edit_status_request) catch |err| {
        log.err("updating status failed! {}", .{err});
        return err;
    };

    conn.commit() catch {
        log.err("Transaction did not go through!", .{});
        try conn.rollback();
    };
}

const MovieIDResponse = struct {
    adult: bool,
    backdrop_path: ?[]const u8,
    // belongs_to_collection: struct {
    //     id: i64,
    //     name: []const u8,
    //     poster_path: []const u8,
    //     backdrop_path: []const u8,
    // },
    budget: i64,
    genres: []Genre,
    homepage: []const u8,
    id: i64,
    // TODO: not sure if this can actually be null?
    imdb_id: ?[]const u8,
    origin_country: [][]const u8,
    original_language: []const u8,
    original_title: []const u8,
    overview: []const u8,
    popularity: f32,
    poster_path: ?[]const u8,
    production_companies: []ProductionCompany,
    production_countries: []ProductionCountry,
    release_date: []const u8,
    revenue: i64,
    runtime: i64,
    spoken_languages: []SpokenLanguage,
    // TODO: enum?
    status: []const u8,
    tagline: ?[]const u8,
    title: []const u8,
    video: bool,
    vote_average: f32,
    vote_count: i64,
    credits: Credits,
    images: Images,

    pub const Genre = struct {
        id: i64,
        name: []const u8,
    };

    pub const ProductionCompany = struct {
        id: i64,
        logo_path: ?[]const u8,
        name: []const u8,
        origin_country: []const u8,
    };

    pub const ProductionCountry = struct {
        iso_3166_1: []const u8,
        name: []const u8,
    };

    pub const SpokenLanguage = struct {
        english_name: []const u8,
        iso_639_1: []const u8,
        name: []const u8,
    };

    pub const Credits = struct {
        cast: []Cast,
        crew: []Crew,

        pub const Cast = struct {
            adult: bool,
            gender: u16,
            id: u64,
            known_for_department: ?[]const u8,
            name: []const u8,
            original_name: []const u8,
            popularity: f32,
            profile_path: ?[]const u8,
            cast_id: u64,
            character: []const u8,
            credit_id: []const u8,
            order: u64,
        };

        pub const Crew = struct {
            adult: bool,
            gender: u16,
            id: u64,
            known_for_department: ?[]const u8,
            name: []const u8,
            original_name: []const u8,
            popularity: f32,
            profile_path: ?[]const u8,
            credit_id: []const u8,
            department: []const u8,
            job: []const u8,
        };
    };

    pub const Images = struct {
        backdrops: []Img,
        logos: []Img,
        posters: []Img,

        const ImageType = enum { backdrops, logos, posters };

        pub const Img = struct {
            aspect_ratio: f32,
            height: i32,
            iso_3166_1: ?[]const u8,
            iso_639_1: ?[]const u8,
            file_path: []const u8,
            vote_average: f32,
            vote_count: u64,
            width: i32,
        };
    };
};

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

pub const SharedState = struct {
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
    movie_list: std.MultiArrayList(Movie),
    image_list: std.MultiArrayList(Image),
    staff_list: std.MultiArrayList(Staff),
    backoff: std.atomic.Value(i64) = .init(0),

    is_cancelled: std.atomic.Value(bool) = .init(false),
    manager: *Manager,

    fn flushLocked(self: *SharedState) !void {
        if (self.is_cancelled.load(.monotonic)) return;

        if (self.movie_list.len == 0) return;
        const movie = self.movie_list;
        self.movie_list = std.MultiArrayList(Movie).empty;

        const image = self.image_list;
        self.image_list = std.MultiArrayList(Image).empty;

        const staff = self.staff_list;
        self.staff_list = std.MultiArrayList(Staff).empty;

        self.wg.start();
        self.pool.spawn(spawnModelThread, .{
            self,
            movie,
            staff,
            image,
        }) catch |err| {
            self.wg.finish();
            return err;
        };
    }
    fn checkBackoff(self: *SharedState) void {
        while (true) {
            const now = std.time.milliTimestamp();
            const wait_until = self.backoff.load(.monotonic);
            if (now >= wait_until) break;

            const diff = wait_until - now;
            std.Thread.sleep(@intCast(diff * std.time.ns_per_ms));
        }
    }
    pub fn deinit(self: *SharedState) void {
        self.is_cancelled.store(true, .monotonic);

        self.wg.wait();

        self.pool.deinit();

        // clean up leftover data, in case this is a cancellation deinit
        var movie_slice = self.movie_list.slice();
        for (0..movie_slice.len) |i| movie_slice.get(i).deinit(self.allocator);
        self.movie_list.deinit(self.allocator);

        var staff_slice = self.staff_list.slice();
        for (0..staff_slice.len) |i| staff_slice.get(i).deinit(self.allocator);
        self.staff_list.deinit(self.allocator);

        var image_slice = self.image_list.slice();
        for (0..image_slice.len) |i| image_slice.get(i).deinit(self.allocator);
        self.image_list.deinit(self.allocator);

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
const CreateMultiplePeople = @import("../../models/content/content.zig").CreateMultiplePeople;
const CreateMultipleMediaStaff = @import("../../models/content/content.zig").CreateMultipleMediaStaff;
const CreateMultipleImages = @import("../../models/content/content.zig").CreateMultipleImages;

const Manager = @import("../fetchers.zig").Manager;

const Database = @import("../../database.zig").Pool;

const curl = @import("curl");

const Allocator = std.mem.Allocator;
const std = @import("std");
