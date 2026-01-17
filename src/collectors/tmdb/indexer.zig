const log = std.log.scoped(.tmdb_indexer);

// NOTE: some fields are commented out as we don't need them currently, but may in the future
// This is done as to save memory during parsing.
pub const Data = struct {
    // adult: bool,
    id: u64,
    // original_title: []u8,
    // popularity: f32,
    // video: bool,
};

const IngestType = enum { file, request };

const AMOUNT_OF_PREALLOCATED_DATA = 1_000;
pub fn init(allocator: Allocator, absolute_path: []u8) !void {
    var id_list = try std.ArrayList(u64).initCapacity(allocator, AMOUNT_OF_PREALLOCATED_DATA);
    defer id_list.deinit(allocator);

    var json_string_writer = std.Io.Writer.Allocating.init(allocator);
    defer json_string_writer.deinit();

    var is_first_run = true;

    const data_file = try std.fs.openFileAbsolute(absolute_path, .{});
    var buf: [1024 * 64]u8 = undefined;
    var reader = data_file.reader(&buf);

    const started = std.time.milliTimestamp();

    var i: usize = 0;

    // if there were items returned in the last call, try to parse again
    while (id_list.items.len != 0 or is_first_run == true) {
        if (i % 10 == 0) {
            if (is_first_run == false) {
                log.debug("runnin here! {}", .{id_list.items[id_list.items.len - 1]});
            }
        }
        i += 1;

        if (is_first_run == true) is_first_run = false;
        // clear the old results
        id_list.clearRetainingCapacity();
        parse(&reader.interface, &id_list, &json_string_writer) catch |err| {
            log.err("Failed to parse data! {}", .{err});
            return error.ParserFailed;
        };
    }

    log.info("took {}ms", .{std.time.milliTimestamp() - started});
}

fn parse(reader: *std.Io.Reader, id_list: *std.ArrayList(u64), writer: *std.Io.Writer.Allocating) !void {
    // repeat the preallocated memory is filled
    while (id_list.items.len <= AMOUNT_OF_PREALLOCATED_DATA - 1) {
        const size = reader.streamDelimiter(&writer.writer, '\n') catch |err| {
            switch (err) {
                error.EndOfStream => return,
                else => return err,
            }
        };
        // toss is here because we need to actually skip the newline for future iterations
        reader.toss(1);

        defer writer.clearRetainingCapacity();

        if (size == 0) {
            return;
        }

        const id = parseID(writer.written()) orelse {
            log.err("can't find id in line: {s}", .{writer.written()});
            return error.MissingID;
        };

        id_list.appendAssumeCapacity(id);
    }
}

fn parseID(line: []const u8) ?u64 {
    const key = "\"id\":";
    const index = std.mem.indexOf(u8, line, key) orelse return null;

    var start = index + key.len;

    while (start < line.len and (line[start] == ' ' or line[start] == ':')) : (start += 1) {}

    var end = start;
    while (end < line.len and std.ascii.isDigit(line[end])) : (end += 1) {}

    if (start == end) return null;

    return std.fmt.parseInt(u64, line[start..end], 10) catch null;
}

const Allocator = std.mem.Allocator;
const std = @import("std");
