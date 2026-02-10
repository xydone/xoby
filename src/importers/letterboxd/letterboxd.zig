pub const Import = struct {
    pub const Response = struct {
        watchlist_fails: []Movie,
        progress_fails: []Movie,
        ratings_fails: []Movie,

        pub fn deinit(self: @This(), allocator: Allocator) void {
            for (self.watchlist_fails) |fail| fail.deinit(allocator);
            allocator.free(self.watchlist_fails);
            for (self.progress_fails) |fail| fail.deinit(allocator);
            allocator.free(self.progress_fails);
            for (self.ratings_fails) |fail| fail.deinit(allocator);
            allocator.free(self.ratings_fails);
        }

        const Movie = struct {
            title: []const u8,
            year: ?i64,
            reason: []const u8,

            pub fn deinit(self: @This(), allocator: Allocator) void {
                allocator.free(self.title);
                allocator.free(self.reason);
            }
        };
    };

    const log = std.log.scoped(.letterboxd_import);
    pub fn call(
        allocator: Allocator,
        pool: *Pool,
        user_id: []const u8,
        file: []const u8,
    ) !Response {
        var error_ptr: zip.zip_error_t = undefined;
        zip.zip_error_init(&error_ptr);
        defer zip.zip_error_fini(&error_ptr);

        const source = zip.zip_source_buffer_create(file.ptr, file.len, 0, &error_ptr);
        if (source == null) {
            std.debug.print("Failed to create source: {s}\n", .{zip.zip_error_strerror(&error_ptr)});
            return error.ZipSourceError;
        }

        const zip_handle = zip.zip_open_from_source(source, zip.ZIP_RDONLY, &error_ptr) orelse {
            zip.zip_source_free(source);
            return error.FailedToGetHandle;
        };
        defer _ = zip.zip_close(zip_handle);

        const conn = try Connection.acquire(.{ .database = pool });
        defer conn.release();

        try conn.begin();
        errdefer conn.rollback() catch {};

        const connection: Connection = .{ .conn = conn };

        const watchlist = try extractFile(allocator, zip_handle, "watchlist.csv");
        const watchlist_fail = try Progress.call(
            allocator,
            connection,
            user_id,
            watchlist,
            .planned,
            .{ .is_watchlist = true },
        );
        var watchlist_response: std.ArrayList(Response.Movie) = try .initCapacity(allocator, watchlist_fail.len);
        for (watchlist_fail) |fail| {
            try watchlist_response.append(allocator, .{
                .title = fail.title,
                .year = fail.release_year,
                .reason = fail.reason,
            });
        }

        const progress = try extractFile(allocator, zip_handle, "diary.csv");
        const progress_fail = try Progress.call(
            allocator,
            connection,
            user_id,
            progress,
            .completed,
            .{},
        );
        var progress_response: std.ArrayList(Response.Movie) = try .initCapacity(allocator, progress_fail.len);
        for (progress_fail) |fail| {
            try progress_response.append(allocator, .{
                .title = fail.title,
                .year = fail.release_year,
                .reason = fail.reason,
            });
        }

        const ratings = try extractFile(allocator, zip_handle, "ratings.csv");
        const ratings_fail = try Ratings.call(
            allocator,
            connection,
            user_id,
            ratings,
        );
        var ratings_response: std.ArrayList(Response.Movie) = try .initCapacity(allocator, ratings_fail.len);
        for (ratings_fail) |fail| {
            try ratings_response.append(allocator, .{
                .title = fail.title,
                .year = fail.release_year,
                .reason = fail.reason,
            });
        }

        conn.commit() catch {
            log.err("Transaction did not go through!", .{});
            try conn.rollback();
        };

        return .{
            .watchlist_fails = try watchlist_response.toOwnedSlice(allocator),
            .progress_fails = try progress_response.toOwnedSlice(allocator),
            .ratings_fails = try ratings_response.toOwnedSlice(allocator),
        };
    }
};

pub const Progress = struct {
    const log = std.log.scoped(.letterboxd_progress);
    pub const Response = Model.Response;
    pub const Options = struct {
        is_watchlist: bool = false,
    };

    const Model = ImportLetterboxdListToProgress;
    pub fn call(
        allocator: Allocator,
        connection: Connection,
        user_id: []const u8,
        buf: []const u8,
        status: ProgressStatus,
        options: Options,
    ) ![]Response {
        var writer = try std.Io.Writer.Allocating.initCapacity(allocator, 1024);
        defer writer.deinit();

        var reader = try toReader(buf);

        var list_items: std.MultiArrayList(Items) = .empty;
        defer {
            const slice = list_items.slice();
            for (0..slice.len) |i| slice.get(i).deinit(allocator);
            list_items.deinit(allocator);
        }

        while (reader.streamDelimiter(&writer.writer, '\n')) |size| {
            defer writer.clearRetainingCapacity();
            reader.toss(1);
            if (size == 0) break;
            var line = writer.written();

            var date = try nextField(&line);
            const name = try nextField(&line);
            const year = try nextField(&line);
            const uri = try nextField(&line);
            // if we are not in a watch list, treat this like diary and try to find the watched date
            if (options.is_watchlist == false) {
                // rating
                _ = try nextField(&line);
                // rewatch
                _ = try nextField(&line);
                // tags
                _ = try nextField(&line);
                // watched date
                date = try nextField(&line);
            }

            try list_items.append(allocator, .{
                .created_at = try allocator.dupe(u8, date),
                .name = try allocator.dupe(u8, name),
                .uri = try allocator.dupe(u8, uri),
                .year = blk: {
                    if (year.len == 0) break :blk null;
                    break :blk std.fmt.parseInt(u32, year, 10) catch |err| {
                        log.err("failed to parse \"{s}\" due to {}", .{ year, err });
                        return err;
                    };
                },
            });
        } else |_| {}

        if (list_items.len == 0) return error.EmptyList;

        const request: Model.Request = .{
            .titles = list_items.items(.name),
            .created_at = list_items.items(.created_at),
            .years = list_items.items(.year),
            .uris = list_items.items(.uri),
            .user_id = user_id,
            .status = status,
        };

        return Model.call(
            allocator,
            connection,
            request,
        );
    }

    const Items = struct {
        created_at: []const u8,
        year: ?i64,
        name: []const u8,
        uri: []const u8,

        pub fn deinit(self: @This(), allocator: Allocator) void {
            allocator.free(self.name);
            allocator.free(self.created_at);
            allocator.free(self.uri);
        }
    };
};

pub const Ratings = struct {
    const log = std.log.scoped(.letterboxd_ratings);
    pub const Response = Model.Response;

    const Model = ImportLetterboxdRatings;
    pub fn call(
        allocator: Allocator,
        connection: Connection,
        user_id: []const u8,
        buf: []const u8,
    ) ![]Response {
        var writer = try std.Io.Writer.Allocating.initCapacity(allocator, 1024);
        defer writer.deinit();

        var reader = try toReader(buf);

        var list_items: std.MultiArrayList(Items) = .empty;
        defer {
            const slice = list_items.slice();
            for (0..slice.len) |i| slice.get(i).deinit(allocator);
            list_items.deinit(allocator);
        }

        while (reader.streamDelimiter(&writer.writer, '\n')) |size| {
            defer writer.clearRetainingCapacity();
            reader.toss(1);
            if (size == 0) break;
            var line = writer.written();

            const date = try nextField(&line);
            const name = try nextField(&line);
            const year = try nextField(&line);
            // letterboxd_uri
            _ = try nextField(&line);
            // rating
            const rating = blk: {
                const field = try nextField(&line);
                break :blk std.mem.trimEnd(u8, field, "\r");
            };

            try list_items.append(allocator, .{
                .created_at = try allocator.dupe(u8, date),
                .name = try allocator.dupe(u8, name),
                .year = blk: {
                    if (year.len == 0) break :blk null;
                    break :blk std.fmt.parseInt(u32, year, 10) catch |err| {
                        log.err("failed to parse int \"{s}\" due to {}", .{ year, err });
                        return err;
                    };
                },
                .rating_score = blk: {
                    const float = std.fmt.parseFloat(f32, rating) catch |err| {
                        log.err("failed to parse float \"{s}\" due to {}", .{ rating, err });
                        return err;
                    };
                    break :blk @intFromFloat(float * 2);
                },
            });
        } else |_| {}

        if (list_items.len == 0) return error.EmptyList;

        const request: Model.Request = .{
            .titles = list_items.items(.name),
            .items_created_at = list_items.items(.created_at),
            .years = list_items.items(.year),
            .user_id = user_id,
            .ratings = list_items.items(.rating_score),
        };

        return Model.call(
            allocator,
            connection,
            request,
        );
    }
    const Items = struct {
        created_at: []const u8,
        year: ?i64,
        name: []const u8,
        rating_score: i32,

        pub fn deinit(self: @This(), allocator: Allocator) void {
            allocator.free(self.name);
            allocator.free(self.created_at);
        }
    };
};

/// format:
/// Date,Name,Year,Letterboxd URI
pub const List = struct {
    const log = std.log.scoped(.letterboxd_watchlist);

    pub const Response = ImportLetterboxdListToList.Response;

    pub fn import(
        allocator: Allocator,
        connection: Connection,
        user_id: []const u8,
        list: []const u8,
        list_id: []const u8,
    ) ![]Response {
        var writer = try std.Io.Writer.Allocating.initCapacity(allocator, 1024);
        defer writer.deinit();

        var reader = try toReader(list);

        var list_items: std.MultiArrayList(ListItems) = .empty;
        defer {
            const slice = list_items.slice();
            for (0..slice.len) |i| slice.get(i).deinit(allocator);
            list_items.deinit(allocator);
        }

        while (reader.streamDelimiter(&writer.writer, '\n')) |size| {
            defer writer.clearRetainingCapacity();
            reader.toss(1);
            if (size == 0) break;
            var line = writer.written();

            const date = try nextField(&line);
            const name = try nextField(&line);
            const year_str = try nextField(&line);

            try list_items.append(allocator, .{
                .created_at = try allocator.dupe(u8, date),
                .name = try allocator.dupe(u8, name),
                .year = blk: {
                    if (year_str.len == 0) break :blk null;
                    break :blk std.fmt.parseInt(u32, year_str, 10) catch |err| {
                        log.err("failed to parse \"{s}\" due to {}", .{ year_str, err });
                        return err;
                    };
                },
            });
        } else |_| {}

        if (list_items.len == 0) return error.EmptyList;

        const request: ImportLetterboxdListToList.Request = .{
            .user_id = user_id,
            .list_id = list_id,
            .titles = list_items.items(.name),
            .years = list_items.items(.year),
            .items_created_at = list_items.items(.created_at),
        };

        return ImportLetterboxdListToList.call(allocator, connection, request);
    }
    const ListItems = struct {
        created_at: []const u8,
        year: ?i64,
        name: []const u8,

        pub fn deinit(self: @This(), allocator: Allocator) void {
            allocator.free(self.name);
            allocator.free(self.created_at);
        }
    };
};

fn toReader(buf: []const u8) !std.Io.Reader {
    const start_idx = blk: {
        const first_new_line = std.mem.indexOfScalar(u8, buf, '\n') orelse return error.EmptyList;
        break :blk first_new_line + 1;
    };
    return std.Io.Reader.fixed(buf[start_idx..]);
}

fn nextField(remainder: *[]u8) ![]const u8 {
    const current = remainder.*;
    if (current.len == 0) return error.EmptyField;

    if (current[0] == '"') {
        const closing_quote = std.mem.indexOfScalarPos(u8, current, 1, '"') orelse return error.MalformedCsv;
        const result = current[1..closing_quote];

        var next_pos = closing_quote + 1;
        if (next_pos < current.len and current[next_pos] == ',') next_pos += 1;

        remainder.* = current[next_pos..];
        return result;
    } else {
        if (std.mem.indexOfScalar(u8, current, ',')) |comma_idx| {
            const result = current[0..comma_idx];
            remainder.* = current[comma_idx + 1 ..];
            return result;
        } else {
            const result = current;
            remainder.* = current[current.len..];
            return result;
        }
    }
}

/// Caller must free response
fn extractFile(allocator: std.mem.Allocator, zip_handle: *zip.zip_t, target_name: [:0]const u8) ![]u8 {
    const index = zip.zip_name_locate(zip_handle, target_name, 0);
    if (index < 0) return error.FileNotFound;

    var sb: zip.zip_stat_t = undefined;
    zip.zip_stat_init(&sb);
    if (zip.zip_stat_index(zip_handle, @intCast(index), 0, &sb) != 0) {
        return error.StatFailed;
    }

    if ((sb.valid & zip.ZIP_STAT_SIZE) == 0) return error.SizeUnknown;
    const size: usize = @intCast(sb.size);

    const buffer = try allocator.alloc(u8, size);
    errdefer allocator.free(buffer);

    const zf = zip.zip_fopen_index(zip_handle, @intCast(index), 0);
    if (zf == null) return error.FileOpenFailed;
    defer _ = zip.zip_fclose(zf);

    const read_bytes = zip.zip_fread(zf, buffer.ptr, size);
    if (read_bytes < 0 or @as(usize, @intCast(read_bytes)) != size) {
        return error.ReadError;
    }

    return buffer;
}

const ImportLetterboxdRatings = @import("../../models/profiles/profiles.zig").Ratings.ImportLetterboxd;
const ImportLetterboxdListToProgress = @import("../../models/profiles/profiles.zig").Progress.ImportLetterboxd;
const ImportLetterboxdListToList = @import("../../models/profiles/profiles.zig").List.ImportLetterboxd;
const ProgressStatus = @import("../../models/content/media.zig").ProgressStatus;

const Config = @import("../../config/config.zig");

const Connection = @import("../../database.zig").Connection;
const Pool = @import("../../database.zig").Pool;

const zip = @cImport({
    @cInclude("zip.h");
});

const Allocator = std.mem.Allocator;
const std = @import("std");
