const log = std.log.scoped(.mangabaka_anilist);

pub fn insert(
    arena_alloc: Allocator,
    request: Request,
    response: APIResponse,
    manga: *std.MultiArrayList(DatabaseRepresentation.Manga),
    staff: *std.MultiArrayList(DatabaseRepresentation.Staff),
    genres: *std.MultiArrayList(DatabaseRepresentation.Genre),
    images: *std.MultiArrayList(DatabaseRepresentation.Image),
) !void {
    const anilist_id = try std.fmt.allocPrint(arena_alloc, "{}", .{response.source.anilist.id.?});
    try manga.append(request.state.allocator, .{
        .id = anilist_id,
        .provider = "anilist",
        .release_date = null,
        .title = try arena_alloc.dupe(u8, response.title),
        .description = if (response.description) |desc| try arena_alloc.dupe(u8, desc) else null,
        .total_chapters = if (response.total_chapters) |str| try std.fmt.parseInt(i32, str, 10) else null,
    });
    const raw_response = response.source.anilist.response orelse {
        log.err("raw response not present! mangabaka id: {} | title: {s} | anilist id {s}. Skipping...", .{ response.id, response.title, anilist_id });
        return;
    };

    for (raw_response.staff.edges) |edge| {
        try staff.append(request.state.allocator, .{
            .name = try arena_alloc.dupe(u8, edge.node.name.full),
            .external_id = try std.fmt.allocPrint(arena_alloc, "{}", .{edge.id}),
            .bio = null,
            .provider = "anilist",
            .media_id = anilist_id,
            .role_name = try arena_alloc.dupe(u8, edge.role),
            .character_name = null,
        });
    }

    genres_blk: {
        const list = response.genres orelse break :genres_blk;

        for (list) |genre| {
            try genres.append(request.state.allocator, .{
                .name = try arena_alloc.dupe(u8, genre),
                .external_id = anilist_id,
            });
        }
    }

    images_blk: {
        const cover_image = raw_response.coverImage orelse break :images_blk;
        try images.append(request.state.allocator, .{
            .path = try arena_alloc.dupe(u8, cover_image.large),
            .provider = "anilist",
            .is_primary = true,
            .image_type = .cover,
            .external_media_id = anilist_id,
        });
    }
}

pub const AniList = struct {
    id: ?u32,
    rating: ?f32,
    response: ?Response,

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
