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
/// Absolute path to the folder where assets, such as cover arts, are stored.
assets_dir: []u8,
collectors: Collectors,

pub const Collectors = struct {
    tmdb: TMDB,

    pub const TMDB = struct {
        enable: bool,
        path: ?[]u8,

        pub fn deinit(self: @This(), allocator: Allocator) void {
            if (self.path) |p| allocator.free(p);
        }
    };

    pub fn deinit(self: @This(), allocator: Allocator) void {
        self.tmdb.deinit(allocator);
    }
};

const path = "config/config.zon";
const log = std.log.scoped(.config);

const Config = @This();

// This is the contract the config file must fulfill.
// It is different from the root level struct as it allows us to enforce better safety against misconfigurations.
const ConfigFile = struct {
    port: u16,
    address: []const u8,
    jwt_secret: ?[]const u8,
    assets_dir: ?[]const u8,
    collectors: Collectors,
};

pub const InitErrors = error{
    CouldntReadFile,
    CouldntReadEnv,
    RequiredNullableFieldMissing,
    OutOfMemory,
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
    errdefer env.deinit(allocator);

    const jwt_secret = blk: {
        if (config_file.jwt_secret) |jwt_secret| break :blk allocator.dupe(u8, jwt_secret) catch @panic("OOM");
        log.err("\"jwt_secret\" inside config.zon is null. Please set it to a correct value.", .{});
        return error.RequiredNullableFieldMissing;
    };
    errdefer allocator.free(jwt_secret);

    const assets_dir = blk: {
        if (config_file.assets_dir) |dir| break :blk allocator.dupe(u8, dir) catch @panic("OOM");
        log.err("\"assets_dir\" inside config.zon is null. Please set it to a correct value.", .{});
        return error.RequiredNullableFieldMissing;
    };
    errdefer allocator.free(assets_dir);

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
        .jwt_secret = jwt_secret,
        .assets_dir = assets_dir,
        .collectors = .{
            .tmdb = .{
                .enable = config_file.collectors.tmdb.enable,
                .path = blk: {
                    if (config_file.collectors.tmdb.enable == false) break :blk null;

                    if (config_file.collectors.tmdb.path) |p| {
                        break :blk allocator.dupe(u8, p) catch return error.OutOfMemory;
                    } else {
                        log.err("Collector \"TMDB\" is enabled, but path is missing.", .{});
                        return error.RequiredNullableFieldMissing;
                    }
                },
            },
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
    self.collectors.deinit(allocator);
}

const readFileZon = @import("common.zig").readFileZon;
const Env = @import("env.zig");

const zon = std.zon;
const Allocator = std.mem.Allocator;
const std = @import("std");
