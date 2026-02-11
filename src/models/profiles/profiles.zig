pub const List = @import("list/list.zig");
pub const Ratings = @import("ratings/ratings.zig");
pub const Progress = @import("progress/progress.zig");

// TODO: test
pub const Summary = struct {
    pub const Request = struct {
        user_id: []const u8,
    };

    pub const Response = struct {
        movies_completed: i64,
        books_completed: i64,
        manga_completed: i64,
        hours_watched: f64,
        pages_read: i64,
        average_rating: f64,
        ratings: []i64,
        longest_streak: i64,
        current_streak: i64,

        pub fn deinit(self: @This(), allocator: Allocator) void {
            allocator.free(self.ratings);
        }
    };

    pub const Errors = error{
        CannotGet,
        InvalidRatingScore,
        OutOfMemory,
        CannotParseID,
    } || DatabaseErrors;

    const log = std.log.scoped(.profile_summary);
    pub fn call(allocator: std.mem.Allocator, database: *Pool, request: Request) Errors!Response {
        var conn = database.acquire() catch return error.CannotAcquireConnection;
        defer conn.release();

        const error_handler = ErrorHandler{ .conn = conn };

        var row = conn.rowOpts(
            query_string,
            .{request.user_id},
            .{ .column_names = true },
        ) catch |err| {
            if (error_handler.handle(err)) |data| ErrorHandler.printErr(data);
            return error.CannotGet;
        } orelse return error.CannotGet;
        defer row.deinit() catch {};

        const DatabaseResponse = struct {
            movies_completed: i64,
            books_completed: i64,
            manga_completed: i64,
            comics_completed: i64,
            hours_watched: f64,
            pages_read: i64,
            avg_rating: f64,
            // Individual fields for the distribution
            rating_1: i64,
            rating_2: i64,
            rating_3: i64,
            rating_4: i64,
            rating_5: i64,
            rating_6: i64,
            rating_7: i64,
            rating_8: i64,
            rating_9: i64,
            rating_10: i64,
            longest_streak: i64,
            current_streak: i64,
        };

        const response = row.to(DatabaseResponse, .{}) catch |err| {
            log.err("failed to parse response! {}", .{err});
            return error.CannotGet;
        };
        const AMOUNT_OF_RATINGS = 10;
        const ratings = try allocator.alloc(i64, AMOUNT_OF_RATINGS);
        errdefer allocator.free(ratings);

        inline for (0..AMOUNT_OF_RATINGS) |i| {
            const field_name = std.fmt.comptimePrint("rating_{d}", .{i + 1});

            ratings[i] = @field(response, field_name);
        }

        return .{
            .movies_completed = response.movies_completed,
            .books_completed = response.books_completed,
            .manga_completed = response.manga_completed,
            .hours_watched = response.hours_watched,
            .pages_read = response.pages_read,
            .average_rating = response.avg_rating,
            .ratings = ratings,
            .current_streak = response.current_streak,
            .longest_streak = response.longest_streak,
        };
    }

    const query_string = @embedFile("queries/get_summary.sql");
};

const Connection = @import("../../database.zig").Connection;
const Pool = @import("../../database.zig").Pool;
const DatabaseErrors = @import("../../database.zig").DatabaseErrors;
const ErrorHandler = @import("../../database.zig").ErrorHandler;

const Tests = @import("../../tests/setup.zig");
const TestSetup = Tests.TestSetup;

const ProgressStatus = @import("../content/content.zig").Media.ProgressStatus;
const ProgressUnit = @import("../content/content.zig").Media.ProgressUnit;

const UUID = @import("../../util/uuid.zig");

const Allocator = std.mem.Allocator;
const std = @import("std");
