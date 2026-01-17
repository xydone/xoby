pub const MediaType = enum {
    movie,
    book,
    comic,
    manga,
};

pub const Media = @import("media.zig");
pub const Books = @import("books.zig");
pub const Movies = @import("movies.zig");
