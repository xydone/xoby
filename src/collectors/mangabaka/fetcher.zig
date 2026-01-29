const log = std.log.scoped(.mangabaka_fetcher);

pub fn run(
    allocator: Allocator,
    pool: *Pool,
    file_path: []const u8,
    user_id: []const u8,
    batch_size: u32,
    manager: *Manager,
) !void {
    const state = try allocator.create(State);

    state.* = .{
        .allocator = allocator,
        .pool = pool,
        .file_path = file_path,
        .user_id = user_id,
        .batch_size = batch_size,
        .manager = manager,
        .thread = undefined,
    };

    try manager.register(.mangabaka, state);

    state.thread = try std.Thread.spawn(
        .{ .allocator = allocator },
        Fetch.callSupressError,
        .{
            Fetch.Request{
                .state = state,
            },
        },
    );
}

const Fetch = struct {
    pub const Request = struct {
        state: *State,
    };
    pub fn callSupressError(request: Request) void {
        defer request.state.allocator.destroy(request.state);

        call(request) catch |err| {
            switch (err) {
                // if it was cancelled, exit early and do not unregister
                error.Cancelled => return,
                else => log.err("Fetch failed! {}", .{err}),
            }
        };

        // this will only be reached if the cancellation was reached "naturally" (end of stream)
        // or non-cancellation error
        request.state.manager.unregister(.mangabaka);
    }
    pub fn call(
        request: Request,
    ) !void {
        const file = try std.fs.openFileAbsolute(request.state.file_path, .{});
        defer file.close();

        var buf: [1024 * 10]u8 = undefined;
        var reader = file.reader(&buf);
        var writer = try std.Io.Writer.Allocating.initCapacity(request.state.allocator, 1024 * 5);
        defer writer.deinit();

        var arena = std.heap.ArenaAllocator.init(request.state.allocator);
        var arena_alloc = arena.allocator();
        defer arena.deinit();

        const Data = struct {
            title: []const u8,
            release_date: ?[]const u8,
            description: ?[]const u8,
            total_chapters: ?i32,
        };
        var data: std.MultiArrayList(Data) = .empty;
        defer data.deinit(request.state.allocator);

        var parser = Parser.init;
        defer parser.deinit(request.state.allocator);

        var i: u64 = 0;
        while (reader.interface.streamDelimiter(&writer.writer, '\n')) |_| : (i += 1) {
            defer writer.clearRetainingCapacity();
            if (request.state.is_cancelled.load(.monotonic)) return error.Cancelled;
            if (i == request.state.batch_size) {
                i = 0;
                const req: CreateManyManga.Request = .{
                    .title = data.items(.title),
                    .release_date = data.items(.release_date),
                    .description = data.items(.description),
                    .total_chapters = data.items(.total_chapters),
                    .user_id = request.state.user_id,
                };
                _ = try CreateManyManga.call(arena_alloc, request.state.pool, req);

                data.clearRetainingCapacity();
                _ = arena.reset(.retain_capacity);
            }
            reader.interface.toss(1);
            const document: Parser.Document = parser.parseFromSlice(request.state.allocator, writer.written()) catch |err| {
                log.err("Parser failed! {}", .{err});
                return err;
            };

            const title: []const u8 = blk: {
                const str = document.at("title").asString() catch |err| {
                    log.err("Title failed! {}", .{err});
                    return err;
                };

                break :blk try arena_alloc.dupe(u8, str);
            };
            const description = blk: {
                const desc: ?[]const u8 = document.at("description").asLeaky(?[]const u8, arena_alloc, .{}) catch |err| {
                    log.err("Description failed! {}", .{err});
                    return err;
                };

                break :blk if (desc) |value| try arena_alloc.dupe(u8, value) else null;
            };
            const total_chapters = blk: {
                const chapters_str: ?[]const u8 = document.at("total_chapters").asLeaky(?[]const u8, arena_alloc, .{}) catch |err| {
                    log.err("Chapters failed! {}", .{err});
                    return err;
                };

                break :blk if (chapters_str) |value| try std.fmt.parseInt(i32, value, 10) else null;
            };

            try data.append(request.state.allocator, .{
                .release_date = null,
                .title = title,
                .description = description,
                .total_chapters = total_chapters,
            });
        } else |_| {}
        // check if there have been any leftovers
        if (data.len != 0) {
            const req: CreateManyManga.Request = .{
                .title = data.items(.title),
                .release_date = data.items(.release_date),
                .description = data.items(.description),
                .total_chapters = data.items(.total_chapters),
                .user_id = request.state.user_id,
            };
            _ = try CreateManyManga.call(arena_alloc, request.state.pool, req);
        }
    }
};
pub const State = struct {
    allocator: Allocator,
    pool: *Pool,
    file_path: []const u8,
    user_id: []const u8,
    batch_size: u32,

    is_cancelled: std.atomic.Value(bool) = .init(false),
    thread: std.Thread,
    manager: *Manager,
};

const CreateManyManga = @import("../../models/content/manga/manga.zig").CreateMany;
const Pool = @import("../../database.zig").Pool;
const Manager = @import("../fetchers.zig").Manager;

const Parser = zimdjson.ondemand.FullParser(.default);
const zimdjson = @import("zimdjson");

const Allocator = std.mem.Allocator;
const std = @import("std");
