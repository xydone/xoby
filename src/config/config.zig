port: u16,
address: []u8,
database: Database,
redis: Redis,
jwt_secret: []u8,
/// Absolute path to the folder where assets, such as cover arts, are stored.
assets_dir: []u8,
collectors: Collectors,

const Database = struct {
    port: u16,
    host: []const u8,
    username: []const u8,
    name: []const u8,
    password: []const u8,

    pub fn deinit(self: @This(), allocator: Allocator) void {
        allocator.free(self.host);
        allocator.free(self.username);
        allocator.free(self.name);
        allocator.free(self.password);
    }
};

const Redis = struct {
    address: []const u8,
    port: u16,

    pub fn deinit(self: @This(), allocator: Allocator) void {
        allocator.free(self.address);
    }
};

pub const Collectors = struct {
    tmdb: TMDB,

    pub const TMDB = struct {
        enable: bool,
        api_key: ?[]const u8,
        indexer_path: ?[]const u8,
        requests_per_second: u32,
        batch_size: u32,

        pub fn deinit(self: @This(), allocator: Allocator) void {
            if (self.indexer_path) |p| allocator.free(p);
            if (self.api_key) |key| allocator.free(key);
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
    env_file_dir: ?[]const u8,
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

    const env_file_dir = if (config_file.env_file_dir) |dir| allocator.dupe(u8, dir) catch return error.OutOfMemory else std.fs.cwd().realpathAlloc(allocator, ".") catch return error.OutOfMemory;
    defer allocator.free(env_file_dir);

    const env = Env.init(allocator, env_file_dir) catch |err| {
        log.err("env failed with {}", .{err});
        return error.CouldntReadEnv;
    };
    defer env.deinit(allocator);

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
            .host = allocator.dupe(u8, env.DATABASE_HOST) catch return error.OutOfMemory,
            .username = allocator.dupe(u8, env.DATABASE_USERNAME) catch return error.OutOfMemory,
            .name = allocator.dupe(u8, env.DATABASE_NAME) catch return error.OutOfMemory,
            .password = allocator.dupe(u8, env.DATABASE_PASSWORD) catch return error.OutOfMemory,
        },
        .redis = .{
            .port = env.REDIS_PORT,
            .address = allocator.dupe(u8, env.REDIS_ADDRESS) catch return error.OutOfMemory,
        },
        .jwt_secret = jwt_secret,
        .assets_dir = assets_dir,
        .collectors = .{
            .tmdb = .{
                .enable = config_file.collectors.tmdb.enable,
                .indexer_path = blk: {
                    if (config_file.collectors.tmdb.enable == false) break :blk null;

                    if (config_file.collectors.tmdb.indexer_path) |p| {
                        break :blk allocator.dupe(u8, p) catch return error.OutOfMemory;
                    } else {
                        log.err("Collector \"TMDB\" is enabled, but indexer_path is missing.", .{});
                        return error.RequiredNullableFieldMissing;
                    }
                },
                .api_key = blk: {
                    if (config_file.collectors.tmdb.enable == false) break :blk null;

                    if (config_file.collectors.tmdb.api_key) |key| {
                        break :blk allocator.dupe(u8, key) catch return error.OutOfMemory;
                    } else {
                        log.warn("Collector \"TMDB\" is enabled, but api_key is missing. This will cause requests that require the API key to fail. It will not interfere with the other parts of the collector.", .{});
                        break :blk null;
                    }
                },
                .requests_per_second = config_file.collectors.tmdb.requests_per_second,
                .batch_size = config_file.collectors.tmdb.batch_size,
            },
        },
    };
}

pub fn deinit(self: *Config, allocator: Allocator) void {
    allocator.free(self.address);
    allocator.free(self.jwt_secret);
    allocator.free(self.assets_dir);
    self.redis.deinit(allocator);
    self.database.deinit(allocator);
    self.collectors.deinit(allocator);
}

const readFileZon = @import("common.zig").readFileZon;
const Env = @import("env.zig");

const zon = std.zon;
const Allocator = std.mem.Allocator;
const std = @import("std");
