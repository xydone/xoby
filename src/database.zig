pub const Pool = pg.Pool;
pub const Conn = pg.Conn;

pub const DatabaseErrors = error{
    GenericDatabaseError,
    CannotAcquireConnection,
};

const log = std.log.scoped(.database);

pub const Connection = union(enum) {
    database: *Pool,
    conn: *pg.Conn,

    pub fn acquire(self: Connection) !*pg.Conn {
        return switch (self) {
            .database => |db| db.acquire() catch return error.CannotAcquireConnection,
            .conn => |c| c,
        };
    }

    pub fn release(self: Connection, conn: *pg.Conn) void {
        switch (self) {
            .database => conn.release(),
            else => {},
        }
    }
};

pub fn init(allocator: Allocator, config: Config) !*Pool {
    const pool = try pg.Pool.init(allocator, .{ .size = 5, .connect = .{
        .port = config.database.port,
        .host = config.database.host,
    }, .auth = .{
        .username = config.database.username,
        .database = config.database.name,
        .password = config.database.password,
        .timeout = 10_000,
    } });

    try hasAdmin(allocator, pool);

    return pool;
}

/// Checks if the database contains an admin account.
pub fn hasAdmin(allocator: Allocator, pool: *Pool) !void {
    const has_admin = try HasAdmin.call(pool);

    if (has_admin) return;

    var stdout_buf: [1024]u8 = undefined;
    var stdin_buf: [1024]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&stdout_buf);
    var stdin = std.fs.File.stdin().reader(&stdin_buf);

    _ = try stdout.interface.write("The database does not contain an account with an admin role. Create one:\nUsername: ");
    try stdout.interface.flush();

    const username = try allocator.dupe(u8, try stdin.interface.takeDelimiter('\n') orelse return error.UsernameIsNull);
    defer allocator.free(username);

    _ = try stdout.interface.write("Password: ");
    try stdout.interface.flush();

    // hide output from the user
    try setTerminalEcho(false);
    const password = try allocator.dupe(u8, try stdin.interface.takeDelimiter('\n') orelse return error.PasswordIsNull);
    defer {
        std.crypto.secureZero(u8, password);
        allocator.free(password);
    }
    try setTerminalEcho(true);

    const request = CreateUser.Request{
        .display_name = username,
        .username = username,
        .password = password,
        .role = .admin,
    };

    const response = try CreateUser.call(allocator, pool, request);
    response.deinit(allocator);

    _ = try stdout.interface.write("\nAccount created!\n");
    try stdout.interface.flush();
}

pub const ErrorHandler = struct {
    conn: *pg.Conn,

    pub fn handle(self: ErrorHandler, err: anyerror) ?pg.Error {
        if (err == error.PG) {
            if (self.conn.err) |pge| {
                return pge;
            }
        }
        return null;
    }

    pub fn printErr(err: pg.Error) void {
        std.log.err("severity: {s} |code: {s} | failure: {s}", .{ err.severity, err.code, err.message });
    }
};

const HasAdmin = @import("models/auth/auth.zig").HasAdmin;
const CreateUser = @import("models/auth/auth.zig").CreateUser;

const setTerminalEcho = @import("util/setTerminalEcho.zig").setEcho;
const Config = @import("config/config.zig");

const pg = @import("pg");

const Allocator = std.mem.Allocator;
const std = @import("std");
