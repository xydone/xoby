const log = std.log.scoped(.mangabaka_fetcher);

pub fn run(
    allocator: Allocator,
    pool: *Pool,
    config: Config,
    user_id: []const u8,
    manager: *Manager,
) !void {
    const state = try allocator.create(State);

    state.* = .{
        .allocator = allocator,
        .pool = pool,
        .config = config,
        .user_id = try allocator.dupe(u8, user_id),
        .manager = manager,
        .thread = undefined,
    };

    try manager.register(.mangabaka, state);

    state.thread = try std.Thread.spawn(
        .{ .allocator = allocator },
        Fetch.callSupressError,
        .{
            Fetch.Request{
                .state = state,
            },
        },
    );
}

pub const Fetch = struct {
    pub const Request = struct {
        state: *State,
    };
    pub fn callSupressError(request: Request) void {
        defer {
            request.state.deinit(request.state.allocator);
            request.state.allocator.destroy(request.state);
        }

        call(request) catch |err| {
            switch (err) {
                // if it was cancelled, exit early and do not unregister
                error.Cancelled => return,
                else => log.err("Fetch failed! {}", .{err}),
            }
        };

        // this will only be reached if the cancellation was reached "naturally" (end of stream)
        // or non-cancellation error
        request.state.manager.unregister(.mangabaka);
    }
    pub fn call(
        request: Request,
    ) !void {
        const file = try std.fs.openFileAbsolute(request.state.config.database_path.?, .{});
        defer file.close();

        var buf: [1024 * 10]u8 = undefined;
        var reader = file.reader(&buf);
        var writer = try std.Io.Writer.Allocating.initCapacity(request.state.allocator, 1024 * 5);
        defer writer.deinit();

        var arena = std.heap.ArenaAllocator.init(request.state.allocator);
        const arena_alloc = arena.allocator();
        defer arena.deinit();

        var manga: std.MultiArrayList(DatabaseRepresentation.Manga) = .empty;
        defer manga.deinit(request.state.allocator);

        var staff: std.MultiArrayList(DatabaseRepresentation.Staff) = .empty;
        defer staff.deinit(request.state.allocator);

        var genres: std.MultiArrayList(DatabaseRepresentation.Genre) = .empty;
        defer genres.deinit(request.state.allocator);

        var images: std.MultiArrayList(DatabaseRepresentation.Image) = .empty;
        defer images.deinit(request.state.allocator);

        var parser = Parser.init;
        defer parser.deinit(request.state.allocator);

        var i: u64 = 0;
        while (reader.interface.streamDelimiter(&writer.writer, '\n')) |_| {
            defer writer.clearRetainingCapacity();
            if (request.state.is_cancelled.load(.monotonic)) return error.Cancelled;
            if (i == request.state.config.batch_size) {
                i = 0;

                try saveToDatabase(
                    arena_alloc,
                    request,
                    manga,
                    staff,
                    genres,
                    images,
                );

                manga.clearRetainingCapacity();
                staff.clearRetainingCapacity();
                genres.clearRetainingCapacity();
                images.clearRetainingCapacity();
                _ = arena.reset(.retain_capacity);
            }
            reader.interface.toss(1);
            const document: Parser.Document = parser.parseFromSlice(request.state.allocator, writer.written()) catch |err| {
                log.err("Parser failed! {}", .{err});
                return err;
            };

            const response: APIResponse = try document.asLeaky(APIResponse, arena_alloc, .{});

            if (response.state != .active) continue;

            for (request.state.config.allowed_sources) |source| {
                switch (source) {
                    .anilist => {
                        const anilist = response.source.anilist orelse continue;
                        _ = anilist.id orelse continue;
                        i += 1;
                        try AniListHandler.insert(
                            arena_alloc,
                            request,
                            response,
                            &manga,
                            &staff,
                            &genres,
                            &images,
                        );
                    },
                    else => {},
                }
            }
        } else |_| {}
        // check if there have been any leftovers
        if (manga.len != 0) {
            try saveToDatabase(
                arena_alloc,
                request,
                manga,
                staff,
                genres,
                images,
            );
        }
    }

    fn saveToDatabase(
        arena_alloc: Allocator,
        request: Request,
        manga: std.MultiArrayList(DatabaseRepresentation.Manga),
        staff: std.MultiArrayList(DatabaseRepresentation.Staff),
        genres: std.MultiArrayList(DatabaseRepresentation.Genre),
        images: std.MultiArrayList(DatabaseRepresentation.Image),
    ) !void {
        const conn = request.state.pool.acquire() catch return error.CannotAcquireConnection;
        defer conn.release();

        try conn.begin();

        const manga_response = try createManga(
            arena_alloc,
            .{
                .conn = conn,
            },
            request,
            manga,
        );

        var external_media_id_to_db_id = std.StringHashMap([]u8).init(arena_alloc);
        for (manga.items(.id), manga_response.ids) |external_id, db_id| {
            try external_media_id_to_db_id.put(external_id, db_id);
        }

        const people_response = try createPeople(
            arena_alloc,
            .{
                .conn = conn,
            },
            staff,
        );

        try createMediaStaff(
            arena_alloc,
            .{
                .conn = conn,
            },
            staff,
            people_response,
            external_media_id_to_db_id,
        );

        try createGenres(
            arena_alloc,
            .{
                .conn = conn,
            },
            genres,
            external_media_id_to_db_id,
        );

        try createImages(
            arena_alloc,
            .{
                .conn = conn,
            },
            images,
            external_media_id_to_db_id,
        );

        conn.commit() catch {
            log.err("Transaction did not go through!", .{});
            try conn.rollback();
        };
    }

    fn createManga(
        arena_alloc: Allocator,
        connection: Connection,
        request: Request,
        manga: std.MultiArrayList(DatabaseRepresentation.Manga),
    ) !CreateMultipleManga.Response {
        const req: CreateMultipleManga.Request = .{
            .external_ids = manga.items(.id),
            .providers = manga.items(.provider),
            .title = manga.items(.title),
            .release_date = manga.items(.release_date),
            .description = manga.items(.description),
            .total_chapters = manga.items(.total_chapters),
            .user_id = request.state.user_id,
        };
        return CreateMultipleManga.call(arena_alloc, connection, req);
    }

    fn createGenres(
        arena_alloc: Allocator,
        connection: Connection,
        genres: std.MultiArrayList(DatabaseRepresentation.Genre),
        media_id_map: std.StringHashMap([]u8),
    ) !void {
        const genre_media_ids = blk: {
            const ids = try arena_alloc.alloc([]const u8, genres.len);

            for (genres.items(.external_id), 0..) |external_id, i| {
                ids[i] = media_id_map.get(external_id) orelse {
                    log.debug("Genre: Movie {s} doesnt have an id inside the map!", .{external_id});
                    return error.MovieNotInsideMap;
                };
            }
            break :blk ids;
        };
        const req: CreateMultipleGenres.Request = .{
            .names = genres.items(.name),
            .media_ids = genre_media_ids,
        };
        try CreateMultipleGenres.call(connection, req);
    }

    fn createPeople(
        arena_alloc: Allocator,
        connection: Connection,
        staff: std.MultiArrayList(DatabaseRepresentation.Staff),
    ) ![]CreateMultiplePeople.Response {
        const req: CreateMultiplePeople.Request = .{
            .full_names = staff.items(.name),
            .bios = staff.items(.bio),
            .provider = staff.items(.provider),
            .external_ids = staff.items(.external_id),
        };
        return CreateMultiplePeople.call(arena_alloc, connection, req);
    }

    fn createMediaStaff(
        arena_alloc: Allocator,
        connection: Connection,
        staff: std.MultiArrayList(DatabaseRepresentation.Staff),
        people_response: []CreateMultiplePeople.Response,
        media_id_map: std.StringHashMap([]u8),
    ) !void {
        const person_ids = blk: {
            const ids = try arena_alloc.alloc([]const u8, staff.len);

            var map = std.StringHashMap([]const u8).init(arena_alloc);

            for (people_response) |res| {
                try map.put(res.external_id, res.person_id);
            }

            for (staff.items(.external_id), 0..) |external_id, i| {
                ids[i] = map.get(external_id) orelse {
                    log.err("external id not in map!", .{});
                    return error.ExternalIDNotInMap;
                };
            }
            break :blk ids;
        };

        const staff_media_ids = blk: {
            const ids = try arena_alloc.alloc([]const u8, staff.len);

            for (staff.items(.media_id), 0..) |external_id, i| {
                ids[i] = media_id_map.get(external_id) orelse {
                    log.debug("Staff: {s} doesnt have an id inside the map!", .{external_id});
                    return error.MovieNotInsideMap;
                };
            }
            break :blk ids;
        };
        const req: CreateMultipleMediaStaff.Request = .{
            .person_ids = person_ids,
            .media_ids = staff_media_ids,
            .role_names = staff.items(.role_name),
            .character_names = staff.items(.character_name),
        };
        _ = try CreateMultipleMediaStaff.call(connection, req);
    }

    fn createImages(
        arena_alloc: Allocator,
        connection: Connection,
        images: std.MultiArrayList(DatabaseRepresentation.Image),
        media_id_map: std.StringHashMap([]u8),
    ) !void {
        const media_ids = blk: {
            const ids = try arena_alloc.alloc([]const u8, images.len);

            for (images.items(.external_media_id), 0..) |external_id, i| {
                ids[i] = media_id_map.get(external_id) orelse {
                    return error.MovieNotInsideMap;
                };
            }
            break :blk ids;
        };
        const req: CreateMultipleImages.Request = .{
            .media_ids = media_ids,
            .image_type = images.items(.image_type),
            .provider_id = images.items(.provider),
            .path = images.items(.path),
            .is_primary = images.items(.is_primary),
        };
        try CreateMultipleImages.call(connection, req);
    }
};

pub const DatabaseRepresentation = struct {
    pub const Staff = struct {
        name: []const u8,
        external_id: []const u8,
        bio: ?[]const u8,
        provider: []const u8,
        media_id: []const u8,
        role_name: []const u8,
        character_name: ?[]const u8,
    };

    pub const Manga = struct {
        id: []const u8,
        title: []const u8,
        release_date: ?[]const u8,
        description: ?[]const u8,
        total_chapters: ?i32,
        provider: []const u8,
    };

    pub const Genre = struct {
        name: []const u8,
        external_id: []const u8,
        pub fn deinit(self: @This(), allocator: Allocator) void {
            allocator.free(self.name);
        }
    };

    pub const Image = struct {
        path: []const u8,
        provider: []const u8,
        is_primary: bool,
        image_type: ImageType,
        external_media_id: []const u8,
    };
};

pub const State = struct {
    allocator: Allocator,
    pool: *Pool,
    config: Config,
    user_id: []const u8,

    is_cancelled: std.atomic.Value(bool) = .init(false),
    thread: std.Thread,
    manager: *Manager,

    pub fn deinit(self: @This(), allocator: Allocator) void {
        allocator.free(self.user_id);
    }
};

pub const APIResponse = struct {
    id: u32,
    title: []const u8,
    description: ?[]const u8,
    genres: ?[][]const u8,
    total_chapters: ?[]const u8,
    state: APIResponse.State,
    source: Source,

    pub const State = enum { active, merged };
    pub const Source = struct {
        anilist: ?AniList,

        pub const AniList = struct {
            id: ?u32,
            rating: ?f32,
            response: ?Response,
        };

        pub const Response = struct {
            id: u32,
            staff: Staff,
            coverImage: ?CoverImage,
        };

        pub const Staff = struct {
            edges: []StaffEdge,
        };

        pub const CoverImage = struct {
            large: []const u8,
        };

        pub const StaffEdge = struct {
            id: i32,
            node: StaffNode,
            role: []const u8,
        };

        pub const StaffNode = struct {
            name: Names,
            pub const Names = struct {
                full: []const u8,
            };
        };
    };
};

const CreateMultipleImages = @import("../../models/content/content.zig").CreateMultipleImages;
const CreateMultipleGenres = @import("../../models/content/content.zig").CreateMultipleGenres;
const CreateMultiplePeople = @import("../../models/content/content.zig").CreateMultiplePeople;
const CreateMultipleMediaStaff = @import("../../models/content/content.zig").CreateMultipleMediaStaff;
const CreateMultipleManga = @import("../../models/content/manga/manga.zig").CreateMultiple;
const Conn = @import("../../database.zig").Conn;
const Database = @import("../../database.zig");

const ImageType = @import("../../models/content/content.zig").ImageType;

const AniListHandler = @import("anilist.zig");

const Config = @import("../../config/config.zig").Collectors.MangaBaka;

const Connection = @import("../../database.zig").Connection;
const Pool = @import("../../database.zig").Pool;
const Manager = @import("../fetchers.zig").Manager;

const Parser = zimdjson.ondemand.FullParser(.default);
const zimdjson = @import("zimdjson");

const Allocator = std.mem.Allocator;
const std = @import("std");
