const Setup = @This();

pub var test_env: TestEnvironment = undefined;

pub const TestEnvironment = struct {
    database_pool: *Database.Pool,
    redis_client: *redis.Client,
    config: Config,

    const InitErrors = error{
        CouldntInitializeDB,
        NotRunningOnTestDB,
    } || anyerror;

    /// Initializes the struct and clears all data from the database *only if* it is the test database
    ///
    /// Allocator should NOT be a testing allocator, that gets cleared before the deinit() statement can get called.
    pub fn init(allocator: Allocator) InitErrors!void {
        const config = try Config.init(allocator);

        const database = Database.init(
            allocator,
            config,
            .{ .check_for_admin = false },
        ) catch return InitErrors.CouldntInitializeDB;

        const redis_client = try allocator.create(redis.Client);
        redis_client.* = try redis.Client.init(allocator, config.redis.address, config.redis.port);

        test_env = TestEnvironment{
            .database_pool = database,
            .config = config,
            .redis_client = redis_client,
        };

        const conn = try database.acquire();
        defer conn.release();

        var row = try conn.row("SELECT current_database();", .{});
        const name = row.?.get([]u8, 0);
        try row.?.deinit();

        // check if the database is a test database
        if (!std.mem.startsWith(u8, name, "TEST_")) return InitErrors.NotRunningOnTestDB;

        // Clear database
        var clean_db = try conn.row(
            \\SELECT 'TRUNCATE TABLE ' || 
            \\string_agg(quote_ident(table_schema) || '.' || quote_ident(table_name), ', ') || 
            \\' RESTART IDENTITY CASCADE;' AS sql_to_run
            \\FROM information_schema.tables 
            \\WHERE table_type = 'BASE TABLE'
            \\AND table_schema NOT IN ('information_schema', 'pg_catalog');
        , .{});
        const string = row.?.get([]u8, 0);
        try clean_db.?.deinit();

        _ = try conn.exec(string, .{});
    }

    /// Allocator should NOT be a testing allocator, that gets cleared before the deinit() statement can get called.
    pub fn deinit(self: *TestEnvironment, allocator: Allocator) void {
        self.database_pool.deinit();
        self.config.deinit(allocator);
        self.redis_client.deinit();
        allocator.destroy(self.redis_client);
    }
};
pub const TestSetup = struct {
    user: User,

    const User = @import("../models/auth/auth.zig").CreateUser.Response;
    pub fn init(database: *Database.Pool, unique_name: []const u8) !TestSetup {
        const user = try createUser(database, unique_name);

        return TestSetup{
            .user = user,
        };
    }

    pub fn createUser(database: *Database.Pool, name: []const u8) !User {
        const allocator = std.testing.allocator;
        const Create = @import("../models/auth/auth.zig").CreateUser;

        const username = try std.fmt.allocPrint(allocator, "{s}", .{name});
        defer allocator.free(username);
        const display_name = try std.fmt.allocPrint(allocator, "Display {s}", .{name});
        defer allocator.free(display_name);
        const password = try std.fmt.allocPrint(allocator, "Testing password", .{});
        defer allocator.free(password);

        const request = Create.Request{
            .display_name = display_name,
            .username = username,
            .password = password,
        };
        const user = try Create.call(
            allocator,
            database,
            request,
        );
        return user;
    }

    pub fn deinit(self: *TestSetup, allocator: std.mem.Allocator) void {
        self.user.deinit(allocator);
    }
};

pub const RequestContext = struct {
    pub fn init(allocator: Allocator, config: Config, user_id: ?[]const u8) !Handler.RequestContext {
        return Handler.RequestContext{
            .allocator = allocator,
            .user_id = user_id,
            .user_role = null,
            .refresh_token = null,
            .database_pool = test_env.database_pool,
            .redis_client = test_env.redis_client,
            .config = config,
            .collectors_fetchers = undefined,
        };
    }
};

const Database = @import("../database.zig");
const Config = @import("../config/config.zig");
const Handler = @import("../handler.zig");

const redis = @import("../redis.zig");

const Allocator = std.mem.Allocator;
const std = @import("std");
