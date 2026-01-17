const log = std.log.scoped(.tmdb_indexer);

// NOTE: some fields are commented out as we don't need them currently, but may in the future
// This is done as to save memory during parsing.
pub const Data = struct {
    // adult: bool,
    id: i64,
    // original_title: []u8,
    // popularity: f32,
    // video: bool,
};

const IngestType = enum { file, request };

const AMOUNT_OF_PREALLOCATED_DATA = 500_000;

pub fn init(allocator: Allocator, database: *Database, absolute_path: []const u8) !void {
    const Model = CollectorsModel.Create;

    var id_list = try std.ArrayList(i64).initCapacity(allocator, AMOUNT_OF_PREALLOCATED_DATA);
    defer id_list.deinit(allocator);

    var json_string_writer = std.Io.Writer.Allocating.init(allocator);
    defer json_string_writer.deinit();

    var dir = try std.fs.openDirAbsolute(absolute_path, .{ .iterate = true });
    defer dir.close();

    var iter = dir.iterate();
    // get the name of the most recently modified index file inside the directory
    const newest_name: []u8 = blk: {
        var max_mtime: i128 = -1;
        var name: ?[]u8 = null;

        errdefer if (name) |n| allocator.free(n);

        while (try iter.next()) |entry| {
            if (entry.kind != .file) continue;

            const stats = try dir.statFile(entry.name);

            if (stats.mtime > max_mtime) {
                max_mtime = stats.mtime;

                if (name) |old_name| allocator.free(old_name);

                name = try allocator.dupe(u8, entry.name);
            }
        }

        if (name) |n| {
            break :blk n;
        } else {
            log.warn("TMDB indexer folder is empty or contains no files!", .{});
            return error.FolderEmpty;
        }
    };

    var data_file = try dir.openFile(newest_name, .{});
    defer data_file.close();

    var buf: [1024 * 64]u8 = undefined;
    var reader = data_file.reader(&buf);

    while (true) {
        id_list.clearRetainingCapacity();
        const amount_written = parse(&reader.interface, &id_list, &json_string_writer) catch |err| {
            log.err("Failed to parse data! {}", .{err});
            return error.ParserFailed;
        };
        if (amount_written == 0) break;

        const request: Model.Request = .{
            .provider = "tmdb",
            .id_list = id_list.items,
            .media_type = .movie,
        };

        Model.call(database, request) catch |err| {
            log.err("create call failed! {}", .{err});
            return err;
        };
    }
}

fn parse(
    reader: *std.Io.Reader,
    temp_list: *std.ArrayList(i64),
    writer: *std.Io.Writer.Allocating,
) !usize {
    var i: usize = 0;
    // repeat the preallocated memory is filled
    while (i <= AMOUNT_OF_PREALLOCATED_DATA - 1) {
        defer i += 1;
        const size = reader.streamDelimiter(&writer.writer, '\n') catch |err| {
            switch (err) {
                error.EndOfStream => return i,
                else => return err,
            }
        };
        // toss is here because we need to actually skip the newline for future iterations
        reader.toss(1);

        defer writer.clearRetainingCapacity();

        if (size == 0) {
            return i;
        }

        const id = parseID(writer.written()) orelse {
            log.err("can't find id in line: {s}", .{writer.written()});
            return error.MissingID;
        };

        temp_list.appendAssumeCapacity(id);
    }
    return i;
}

fn parseID(line: []const u8) ?i64 {
    const key = "\"id\":";
    const index = std.mem.indexOf(u8, line, key) orelse return null;

    var start = index + key.len;

    while (start < line.len and (line[start] == ' ' or line[start] == ':')) : (start += 1) {}

    var end = start;
    while (end < line.len and std.ascii.isDigit(line[end])) : (end += 1) {}

    if (start == end) return null;

    return std.fmt.parseInt(i64, line[start..end], 10) catch null;
}

const CollectorsModel = @import("../../models/collectors/collectors.zig");

const Database = @import("../../database.zig").Pool;

const Allocator = std.mem.Allocator;
const std = @import("std");
