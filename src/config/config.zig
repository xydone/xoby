port: u16,
address: []u8,
database: struct {
    port: u16,
    host: []const u8,
    username: []const u8,
    name: []const u8,
    password: []const u8,
},
redis: struct {
    address: []const u8,
    port: u16,
},
jwt_secret: []u8,

const path = "config/config.zon";
const log = std.log.scoped(.config);

const Config = @This();

// This is the contract the config file must fulfill.
// It is different from the root level struct as it allows us to enforce better safety against misconfigurations.
const ConfigFile = struct {
    port: u16,
    address: []const u8,
    jwt_secret: ?[]const u8,
};

pub const InitErrors = error{
    CouldntReadFile,
    CouldntReadEnv,
    MissingJWTSecret,
};

pub fn init(allocator: Allocator) InitErrors!Config {
    // WARNING: the config file is freed at the end of the scope.
    // You must guarantee that the values that leave the scope do not depend on values that will be freed.
    const config_file = readFileZon(ConfigFile, allocator, path, 1024 * 5) catch |err| {
        log.err("readFileZon failed with {}", .{err});
        return error.CouldntReadFile;
    };
    defer zon.parse.free(allocator, config_file);

    const env = Env.init(allocator) catch |err| {
        log.err("env failed with {}", .{err});
        return error.CouldntReadEnv;
    };
    return .{
        .port = config_file.port,
        .address = allocator.dupe(u8, config_file.address) catch @panic("OOM"),
        .database = .{
            .port = env.DATABASE_PORT,
            .host = env.DATABASE_HOST,
            .username = env.DATABASE_USERNAME,
            .name = env.DATABASE_NAME,
            .password = env.DATABASE_PASSWORD,
        },
        .redis = .{
            .port = env.REDIS_PORT,
            .address = env.REDIS_ADDRESS,
        },
        .jwt_secret = blk: {
            if (config_file.jwt_secret) |jwt_secret| break :blk allocator.dupe(u8, jwt_secret) catch @panic("OOM");
            // if this code is reached, jwt_secret was null, thus probably not changed from the default
            log.err("\"jwt_secret\" inside config.zon is null. Please set it to a correct value.", .{});
            return error.MissingJWTSecret;
        },
    };
}

pub fn deinit(self: *Config, allocator: Allocator) void {
    allocator.free(self.address);
    allocator.free(self.jwt_secret);
    // database
    {
        allocator.free(self.database.host);
        allocator.free(self.database.username);
        allocator.free(self.database.name);
        allocator.free(self.database.password);
    }
    // redis
    {
        allocator.free(self.redis.address);
    }
}

const readFileZon = @import("common.zig").readFileZon;
const Env = @import("env.zig");

const zon = std.zon;
const Allocator = std.mem.Allocator;
const std = @import("std");
