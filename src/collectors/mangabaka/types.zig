pub const APIResponse = struct {
    id: u32,
    title: []const u8,
    description: ?[]const u8,
    genres: ?[][]const u8,
    total_chapters: ?[]const u8,
    state: APIResponse.State,
    source: Source,
    content_rating: ContentRating,

    pub const State = enum { active, merged };
    pub const Source = struct {
        anilist: ?AniList,
        my_anime_list: ?MyAnimeList,
    };
};

pub const ContentRating = enum {
    suggestive,
    erotica,
    pornographic,
};

const AniList = @import("anilist.zig").AniList;
const MyAnimeList = @import("myanimelist.zig").MyAnimeList;
