pub const MediaType = enum {
    movie,
    book,
    comic,
    manga,
};

pub const ImageType = enum {
    backdrop,
    logo,
    poster,
    cover,
};

pub const Media = @import("media/media.zig");
pub const Books = @import("books/books.zig");
pub const Movies = @import("movies/movies.zig");

const log = std.log.scoped(.content_model);

const Pool = @import("../../database.zig").Pool;
const Connection = @import("../../database.zig").Connection;

const DatabaseErrors = @import("../../database.zig").DatabaseErrors;
const ErrorHandler = @import("../../database.zig").ErrorHandler;

const UUID = @import("../../util/uuid.zig");

const Allocator = std.mem.Allocator;
const std = @import("std");
