const log = std.log.scoped(.redis);

pub const Client = struct {
    connection: std.net.Stream,

    pub fn init(allocator: std.mem.Allocator, host: []const u8, port: u16) !Client {
        const conn = try std.net.tcpConnectToHost(allocator, host, port);
        return Client{
            .connection = conn,
        };
    }

    pub fn deinit(self: *Client) void {
        self.connection.close();
    }

    fn trimResponse(response: []u8) ![]u8 {
        if (response.len == 0) return error.ResponseTooShort;
        return response[0 .. response.len - 2];
    }
    /// Caller must free slice.
    pub fn sendCommand(self: *Client, allocator: std.mem.Allocator, command: []const u8) ![]u8 {
        var writer = self.connection.writer(&.{});
        try writer.interface.writeAll(command);

        var stream_buf: [1024]u8 = undefined;

        var stream_reader: std.net.Stream.Reader = self.connection.reader(&stream_buf);
        var reader: *std.Io.Reader = stream_reader.interface();

        var slice: [1024]u8 = undefined;
        var slices = [_][]u8{&slice};
        const read_bytes = try reader.readVec(&slices);

        return allocator.dupe(u8, try trimResponse(slice[0..read_bytes])) catch @panic("OOM");
    }

    /// Caller must free slice.
    pub fn set(self: *Client, allocator: std.mem.Allocator, key: []const u8, value: []const u8) ![]u8 {
        var buf: [1024]u8 = undefined;
        const command = try std.fmt.bufPrint(&buf, "*3\r\n$3\r\nSET\r\n${d}\r\n{s}\r\n${d}\r\n{s}\r\n$2\r\n", .{ key.len, key, value.len, value });
        return try self.sendCommand(allocator, command);
    }

    /// Caller must free slice.
    pub fn setWithExpiry(self: *Client, allocator: std.mem.Allocator, key: []const u8, value: []const u8, expiry: u32) ![]u8 {
        if (expiry == 0) return error.BadExpiry;
        var buf: [1024]u8 = undefined;
        const command = try std.fmt.bufPrint(&buf, "*5\r\n$3\r\nSET\r\n${d}\r\n{s}\r\n${d}\r\n{s}\r\n$2\r\nEX\r\n${d}\r\n{}\r\n", .{ key.len, key, value.len, value, std.math.log10(expiry) + 1, expiry });
        return try self.sendCommand(allocator, command);
    }

    /// Caller must free slice.
    pub fn get(self: *Client, allocator: std.mem.Allocator, key: []const u8) ![]u8 {
        var buf: [1024]u8 = undefined;
        const command = try std.fmt.bufPrint(&buf, "*2\r\n$3\r\nGET\r\n${d}\r\n{s}\r\n", .{ key.len, key });
        const response = try self.sendCommand(allocator, command);
        defer allocator.free(response);
        var it = std.mem.tokenizeSequence(u8, response, "\r\n");
        const length = it.next().?;
        if (std.mem.eql(u8, length, "$-1")) return error.KeyValuePairNotFound;
        return allocator.dupe(u8, it.next() orelse return error.RedisError);
    }
    /// Caller must free slice.
    pub fn delete(self: *Client, allocator: std.mem.Allocator, key: []const u8) ![]u8 {
        var buf: [1024]u8 = undefined;
        const command = try std.fmt.bufPrint(&buf, "*2\r\n$3\r\nDEL\r\n${d}\r\n{s}\r\n", .{ key.len, key });
        return try self.sendCommand(allocator, command);
    }
};

const std = @import("std");
