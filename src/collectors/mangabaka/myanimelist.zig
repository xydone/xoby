const log = std.log.scoped(.mangabaka_mal);

pub fn insert(
    arena_alloc: Allocator,
    request: Request,
    response: APIResponse,
    manga: *std.MultiArrayList(DatabaseRepresentation.Manga),
    staff: *std.MultiArrayList(DatabaseRepresentation.Staff),
    genres: *std.MultiArrayList(DatabaseRepresentation.Genre),
    images: *std.MultiArrayList(DatabaseRepresentation.Image),
) !void {
    const id = try std.fmt.allocPrint(arena_alloc, "{}", .{response.source.my_anime_list.?.id});
    try manga.append(request.state.allocator, .{
        .id = id,
        .provider = "myanimelist",
        .release_date = null,
        .title = try arena_alloc.dupe(u8, response.title),
        .description = if (response.description) |desc| try arena_alloc.dupe(u8, desc) else null,
        .total_chapters = if (response.total_chapters) |str| try std.fmt.parseInt(i32, str, 10) else null,
    });
    const raw_response = response.source.my_anime_list.?.response orelse {
        log.err("raw response not present! mangabaka id: {} | title: {s} | mal id {s}. Skipping...", .{ response.id, response.title, id });
        return;
    };

    // TODO: use an actual role, has to be fixed upstream
    // tracking https://github.com/jikan-me/jikan/issues/569
    for (raw_response.authors, 0..) |author, i| {
        const role_name = if (raw_response.authors.len == 1)
            "Author"
        else
            try std.fmt.allocPrint(arena_alloc, "Author {d}", .{i + 1});

        try staff.append(request.state.allocator, .{
            .name = try arena_alloc.dupe(u8, author.name),
            .external_id = try std.fmt.allocPrint(arena_alloc, "{}", .{author.mal_id}),
            .bio = null,
            .provider = "myanimelist",
            .media_id = id,
            .role_name = role_name,
            .character_name = null,
        });
    }

    genres_blk: {
        const list = response.genres orelse break :genres_blk;

        for (list) |genre| {
            try genres.append(request.state.allocator, .{
                .name = try arena_alloc.dupe(u8, genre),
                .external_id = id,
            });
        }
    }

    images_blk: {
        const img = raw_response.images orelse break :images_blk;
        const jpg = img.jpg orelse break :images_blk;
        try images.append(request.state.allocator, .{
            .path = try arena_alloc.dupe(u8, jpg.image_url),
            .provider = "myanimelist",
            .is_primary = true,
            .image_type = .cover,
            .external_media_id = id,
        });
    }
}

pub const MyAnimeList = struct {
    id: u32,
    response: ?Response,

    const Response = struct {
        authors: []Author,
        images: ?ImageList,
    };

    const Author = struct {
        name: []const u8,
        mal_id: u32,
    };

    const ImageList = struct {
        jpg: ?Image,
        // webp: Image,
        const Image = struct {
            image_url: []const u8,
        };
    };
};

const DatabaseRepresentation = @import("fetcher.zig").DatabaseRepresentation;
const APIResponse = @import("types.zig").APIResponse;
const Request = @import("fetcher.zig").Fetch.Request;

const ImageType = @import("../../models/content/content.zig").ImageType;

const Config = @import("../../config/config.zig").Collectors.MangaBaka;

const Connection = @import("../../database.zig").Connection;
const Pool = @import("../../database.zig").Pool;
const Manager = @import("../fetchers.zig").Manager;

const Parser = zimdjson.ondemand.FullParser(.default);
const zimdjson = @import("zimdjson");

const Allocator = std.mem.Allocator;
const std = @import("std");
