DATABASE_HOST: []u8,
DATABASE_USERNAME: []u8,
DATABASE_NAME: []u8,
DATABASE_PASSWORD: []u8,
DATABASE_PORT: u16,

const log = std.log.scoped(.env);
const Env = @This();

pub fn init(allocator: Allocator) !Env {
    const file_name = if (!builtin.is_test) ".env" else ".testing.env";
    var env_file = Dotenv.init(allocator, file_name) catch return error.OutOfMemory;
    defer env_file.deinit();

    var env: Env = undefined;

    inline for (@typeInfo(Env).@"struct".fields) |field| loop: {
        const type_info = @typeInfo(field.type);
        const result = env_file.get(field.name) orelse {
            if (type_info == .optional) {
                @field(env, field.name) = field.defaultValue() orelse @compileError(std.fmt.comptimePrint("{s} is an optional and must have a default value, it currently doesn't.", .{@typeName(field.type)}));
                break :loop;
            } else {
                log.err("The .env file is missing a \"{s}\" parameter, please add it and try again!", .{field.name});
                return error.MissingFields;
            }
        };
        const field_type = blk: {
            if (type_info == .optional) break :blk type_info.optional.child else break :blk field.type;
        };
        switch (field_type) {
            []const u8, []u8 => {
                @field(env, field.name) = allocator.dupe(u8, result) catch return error.OutOfMemory;
            },
            u16, u32, u64 => |T| {
                @field(env, field.name) = std.fmt.parseInt(T, result, 10) catch return error.CouldntParse;
            },
            else => @compileError(std.fmt.comptimePrint("{s} is not supported!", .{@typeName(field_type)})),
        }
    }
    return env;
}

pub fn deinit(self: Env, allocator: Allocator) void {
    inline for (@typeInfo(Env).@"struct".fields) |field| {
        switch (field.type) {
            []const u8 => {
                allocator.free(@field(self, field.name));
            },
            else => {},
        }
    }
}

// https://github.com/zigster64/dotenv.zig/
pub const Dotenv = struct {
    map: std.process.EnvMap = undefined,

    pub fn init(allocator: Allocator, filename: ?[]const u8) !Dotenv {
        var map = try std.process.getEnvMap(allocator);

        if (filename) |f| {
            var file = std.fs.cwd().openFile(f, .{}) catch {
                return .{ .map = map };
            };
            defer file.close();
            var buf: [1024]u8 = undefined;
            var reader = file.reader(&buf);
            while (parse(&reader.interface, '\n')) |slice| {
                const line = std.mem.trimEnd(u8, slice, "\r");
                // ignore commented out lines
                if (line.len > 0 and line[0] == '#') {
                    continue;
                }
                // split into KEY and Value
                if (std.mem.indexOf(u8, line, "=")) |index| {
                    const key = line[0..index];
                    const value = line[index + 1 ..];
                    try map.put(key, value);
                }
            }
        }
        return .{
            .map = map,
        };
    }

    fn parse(r: *std.io.Reader, delimiter: u8) ?[]u8 {
        // https://github.com/ziglang/zig/issues/25597#issuecomment-3410445340
        if (builtin.zig_version.major == 0 and builtin.zig_version.minor == 15 and builtin.zig_version.patch == 1) {
            return std.io.Reader.takeDelimiterExclusive(r, delimiter) catch null;
        } else {
            return std.io.Reader.takeDelimiter(r, delimiter) catch null;
        }
    }

    pub fn deinit(self: *Dotenv) void {
        self.map.deinit();
    }

    pub fn get(self: Dotenv, key: []const u8) ?[]const u8 {
        return self.map.get(key);
    }

    pub fn put(self: *Dotenv, key: []const u8, value: []const u8) !void {
        return self.map.put(key, value);
    }
};

const testing = std.testing;
const Allocator = std.mem.Allocator;

const std = @import("std");
const builtin = @import("builtin");
