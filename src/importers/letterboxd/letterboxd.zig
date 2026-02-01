/// Expected list format is a csv
/// format:
/// Date,Name,Year,Letterboxd URI
pub const Watchlist = struct {
    const log = std.log.scoped(.letterboxd_watchlist);

    pub const Response = ImportLetterboxdList.Response;

    pub fn import(
        allocator: Allocator,
        pool: *Pool,
        user_id: []const u8,
        list: []const u8,
        list_id: []const u8,
    ) ![]Response {
        var writer = try std.Io.Writer.Allocating.initCapacity(allocator, 1024);
        defer writer.deinit();
        const start_idx = blk: {
            const first_new_line = std.mem.indexOfScalar(u8, list, '\n') orelse return error.EmptyList;
            break :blk first_new_line + 1;
        };
        var reader = std.Io.Reader.fixed(list[start_idx..]);

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
            const line = writer.written();

            const first_comma = std.mem.indexOfScalar(u8, line, ',') orelse return error.DateNotFound;
            const date = line[0..first_comma];
            var remainder = line[first_comma + 1 ..];

            const name: []const u8 = blk: {
                // extract name by handling quotes
                if (remainder.len > 0 and remainder[0] == '"') {
                    const closing_quote = std.mem.indexOfScalarPos(u8, remainder, 1, '"') orelse return error.NameNotFound;
                    const result = remainder[1..closing_quote];
                    remainder = if (remainder.len > closing_quote + 1) remainder[closing_quote + 2 ..] else "";
                    break :blk result;
                } else {
                    // no quotes
                    const next_comma = std.mem.indexOfScalar(u8, remainder, ',') orelse return error.NameNotFound;
                    const result = remainder[0..next_comma];
                    remainder = remainder[next_comma + 1 ..];
                    break :blk result;
                }
            };

            const year_end = std.mem.indexOfScalar(u8, remainder, ',') orelse remainder.len;
            const year_str = remainder[0..year_end];

            try list_items.append(allocator, .{
                .item_created_at = try allocator.dupe(u8, date),
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

        const request: ImportLetterboxdList.Request = .{
            .user_id = user_id,
            .list_id = list_id,
            .titles = list_items.items(.name),
            .years = list_items.items(.year),
            .items_created_at = list_items.items(.item_created_at),
        };

        return ImportLetterboxdList.call(allocator, .{ .database = pool }, request);
    }
};

const ListItems = struct {
    item_created_at: []const u8,
    year: ?i64,
    name: []const u8,

    pub fn deinit(self: @This(), allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.item_created_at);
    }
};
const ImportLetterboxdList = @import("../../models/profiles/profiles.zig").ImportLetterboxdList;

const Config = @import("../../config/config.zig");

const Pool = @import("../../database.zig").Pool;

const Allocator = std.mem.Allocator;
const std = @import("std");
