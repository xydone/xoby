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

pub fn init(allocator: std.mem.Allocator, config: Config) !*Pool {
    const pool = try pg.Pool.init(allocator, .{ .size = 5, .connect = .{
        .port = config.database.port,
        .host = config.database.host,
    }, .auth = .{
        .username = config.database.username,
        .database = config.database.name,
        .password = config.database.password,
        .timeout = 10_000,
    } });
    return pool;
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

const Config = @import("config/config.zig");

const pg = @import("pg");

const std = @import("std");
