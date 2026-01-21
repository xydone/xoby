const log = std.log.scoped(.tmdb_fetcher);

const BATCH_SIZE = 1_000;
const AMOUNT_OF_THREADS = 10;

const Data = struct {
    id: []u8,
    title: []u8,
    release_date: []u8,
    runtime_minutes: ?i64,
    description: ?[]u8,
    fn deinit(self: Data, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.title);
        allocator.free(self.release_date);
        if (self.description) |description| allocator.free(description);
    }
};

const SharedState = struct {
    allocator: Allocator,
    database: *Database,
    user_id: []const u8,
    requests_per_second: u32,
    pool: std.Thread.Pool,
    headers: [:0]u8,
    ca_bundle: *std.array_list.Managed(u8),

    handle_pool: HandlePool,

    mutex: std.Thread.Mutex = .{},
    wg: std.Thread.WaitGroup = .{},
    data_list: std.ArrayList(Data),
    backoff: std.atomic.Value(i64) = .init(0),

    fn flushLocked(self: *SharedState) !void {
        log.debug("Making database call due to flush.", .{});
        if (self.data_list.items.len == 0) return;

        const batch_to_save = self.data_list;
        self.data_list = try std.ArrayList(Data).initCapacity(self.allocator, BATCH_SIZE);

        self.wg.start();
        self.pool.spawn(spawnModelThread, .{ self, batch_to_save }) catch |err| {
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
    fn deinit(self: *SharedState) void {
        self.wg.wait();
        self.pool.deinit();
        self.data_list.deinit(self.allocator);
        self.allocator.free(self.headers);
        self.allocator.free(self.user_id);
        self.handle_pool.deinit();
        self.ca_bundle.deinit();
        self.allocator.destroy(self.ca_bundle);
        self.allocator.destroy(self);
    }
};

const HandlePool = struct {
    mutex: std.Thread.Mutex = .{},
    handles: std.ArrayList(*curl.Easy),
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator, size: usize, ca_bundle: std.array_list.Managed(u8)) !HandlePool {
        var handles = std.ArrayList(*curl.Easy).empty;
        errdefer {
            for (handles.items) |h| {
                h.deinit();
                allocator.destroy(h);
            }
            handles.deinit(allocator);
        }

        for (0..size) |_| {
            const h = try allocator.create(curl.Easy);
            h.* = try curl.Easy.init(.{ .ca_bundle = ca_bundle });
            try handles.append(allocator, h);
        }

        return .{
            .handles = handles,
            .allocator = allocator,
        };
    }

    fn deinit(self: *HandlePool) void {
        for (self.handles.items) |h| {
            h.deinit();
            self.allocator.destroy(h);
        }
        self.handles.deinit(self.allocator);
    }

    fn acquire(self: *HandlePool) ?*curl.Easy {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.handles.pop();
    }

    fn release(self: *HandlePool, handle: *curl.Easy) !void {
        handle.reset();

        self.mutex.lock();
        defer self.mutex.unlock();
        try self.handles.append(self.allocator, handle);
    }
};

pub const Response = struct {
    total_amount: i64,
};

pub fn fetch(
    allocator: Allocator,
    database: *Database,
    user_id: []const u8,
    api_key: []const u8,
    requests_per_second: u32,
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
        .data_list = try std.ArrayList(Data).initCapacity(allocator, BATCH_SIZE),
        .headers = headers,
        .ca_bundle = ca_bundle,
    };

    try state.pool.init(.{
        .allocator = allocator,
        .n_jobs = AMOUNT_OF_THREADS,
    });

    const total_amount = try GetNotCompletedCount.call(database, .{ .provider = "tmdb", .status = .todo });

    const thread = try std.Thread.spawn(
        .{ .allocator = allocator },
        spawnFetchThread,
        .{
            state,
        },
    );
    thread.detach();

    return .{ .total_amount = total_amount };
}

fn spawnFetchThread(state: *SharedState) void {
    defer state.deinit();

    fetchImpl(state) catch {};
}

fn fetchImpl(state: *SharedState) !void {
    while (true) {
        const request = GetNotCompleted.Request{
            .provider = "tmdb",
            .limit = 1_000,
        };

        const id_list = GetNotCompleted.call(state.allocator, state.database, request) catch |err| {
            log.err("GetNotCompleted failed! {}", .{err});
            return err;
        };
        defer {
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
            state.checkBackoff();
            const wait_time = rate_limiter.waitTime(std.time.milliTimestamp());
            if (wait_time > 0) std.Thread.sleep(@intCast(wait_time * std.time.ns_per_ms));

            const url = try std.fmt.allocPrintSentinel(state.allocator, "https://api.themoviedb.org/3/movie/{s}", .{id}, 0);
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
        break;
    }
}

fn spawnRequestThread(state: *SharedState, id: []u8, url: [:0]u8, headers: [:0]u8) void {
    defer {
        state.wg.finish();
        state.allocator.free(url);
    }

    const easy = state.handle_pool.acquire() orelse @panic("no handles in pool");
    defer state.handle_pool.release(easy) catch |err| std.debug.panic("error releasing: {}", .{err});

    const max_retries = 5;
    var attempt: u32 = 0;

    while (attempt < max_retries) : (attempt += 1) {
        state.checkBackoff();

        var writer = std.Io.Writer.Allocating.init(state.allocator);
        defer writer.deinit();

        const resp = easy.fetch(
            url,
            .{
                .headers = &.{headers},
                .writer = &writer.writer,
            },
        ) catch return;
        if (resp.status_code != 200) log.debug("status code: {}", .{resp.status_code});
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

        const response: std.json.Parsed(MovieIDResponse) = std.json.parseFromSlice(MovieIDResponse, state.allocator, writer.written(), .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch |err| {
            log.err("failed to parse response for {s}! {}", .{ url, err });
            return;
        };
        defer response.deinit();
        const title = state.allocator.dupe(u8, response.value.title) catch return;

        const release_date = state.allocator.dupe(u8, response.value.release_date) catch {
            state.allocator.free(title);
            return;
        };

        const runtime_minute: ?i64 = if (response.value.runtime == 0) null else @intCast(response.value.runtime);

        const description = state.allocator.dupe(u8, response.value.overview) catch {
            state.allocator.free(title);
            state.allocator.free(release_date);
            return;
        };

        state.mutex.lock();
        defer state.mutex.unlock();

        state.data_list.append(state.allocator, .{
            .id = id,
            .release_date = release_date,
            .title = title,
            .runtime_minutes = runtime_minute,
            .description = description,
        }) catch |err| {
            log.err("failed to append! {}", .{err});
            state.allocator.free(title);
            state.allocator.free(release_date);
        };
        if (state.data_list.items.len >= BATCH_SIZE) {
            state.flushLocked() catch |err| log.err("Batch flush failed! {}", .{err});
        }

        // if we are here, congratulations, the request went through
        return;
    }
    log.err("Giving up on {s} after {} tries", .{ url, attempt });
}

fn spawnModelThread(state: *SharedState, data: std.ArrayList(Data)) void {
    defer state.wg.finish();
    defer {
        for (data.items) |item| {
            item.deinit(state.allocator);
        }
        var mutable_data = data;
        mutable_data.deinit(state.allocator);
    }

    var ids = state.allocator.alloc([]const u8, data.items.len) catch return;
    defer state.allocator.free(ids);

    var titles = state.allocator.alloc([]const u8, data.items.len) catch return;
    defer state.allocator.free(titles);

    var dates = state.allocator.alloc([]const u8, data.items.len) catch return;
    defer state.allocator.free(dates);

    var runtimes = state.allocator.alloc(?i64, data.items.len) catch return;
    defer state.allocator.free(runtimes);

    var descriptions = state.allocator.alloc(?[]const u8, data.items.len) catch return;
    defer state.allocator.free(descriptions);

    for (data.items, 0..) |item, i| {
        ids[i] = item.id;
        titles[i] = item.title;
        dates[i] = item.release_date;
        runtimes[i] = item.runtime_minutes;
        descriptions[i] = item.description;
    }

    const create_request: CreateMultipleMovies.Request = .{
        .titles = titles,
        .user_id = state.user_id,
        .release_dates = dates,
        .runtime_minutes = runtimes,
        .descriptions = descriptions,
    };

    CreateMultipleMovies.call(state.database, create_request) catch |err| {
        log.err("creating movie failed! {}", .{err});
        return;
    };

    const edit_status_request: EditStatus.Request = .{
        .provider = "tmdb",
        .external_id = ids,
        .status = .completed,
    };
    EditStatus.call(state.database, edit_status_request) catch |err| {
        log.err("updating status failed! {}", .{err});
        return;
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
};

const RateLimiter = @import("../../rate_limiter.zig").RateLimiter;

const curl = @import("curl");

const GetNotCompleted = @import("../../models/collectors/collectors.zig").GetNotCompleted;
const GetNotCompletedCount = @import("../../models/collectors/collectors.zig").GetNotCompletedCount;
const EditStatus = @import("../../models/collectors/collectors.zig").EditStatus;

const CreateMultipleMovies = @import("../../models/content/content.zig").Movies.CreateMultiple;

const Database = @import("../../database.zig").Pool;

const Allocator = std.mem.Allocator;
const std = @import("std");
