const Setup = @This();

var test_env: TestEnvironment = undefined;

pub const TestEnvironment = struct {
    database_pool: *Database.Pool,
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

        const database = Database.init(allocator, config) catch return InitErrors.CouldntInitializeDB;

        test_env = TestEnvironment{
            .database_pool = database,
            .config = config,
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
            \\string_agg(quote_ident(table_name), ', ') ||
            \\' RESTART IDENTITY CASCADE;' AS sql_to_run
            \\FROM information_schema.tables
            \\WHERE table_schema = 'public' 
            \\AND table_type = 'BASE TABLE';
        , .{});
        const string = row.?.get([]u8, 0);
        try clean_db.?.deinit();

        _ = try conn.exec(string, .{});
    }

    /// Allocator should NOT be a testing allocator, that gets cleared before the deinit() statement can get called.
    pub fn deinit(self: *TestEnvironment, allocator: Allocator) void {
        self.database_pool.deinit();
        self.config.deinit(allocator);
    }
};

pub const RequestContext = struct {
    pub fn init(database_pool: *Database.Pool, config: Config, user_id: ?i64) !Handler.RequestContext {
        return Handler.RequestContext{
            .user_id = user_id,
            .database_pool = database_pool,
            .config = config,
        };
    }
};

const Database = @import("../database.zig");
const Config = @import("../config/config.zig");
const Handler = @import("../handler.zig");

const Allocator = std.mem.Allocator;
const std = @import("std");
