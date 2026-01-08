pub inline fn toString(uuid: []const u8) ![36]u8 {
    return pg.uuidToHex(uuid);
}

pub inline fn toStringAlloc(allocator: Allocator, uuid: []const u8) error{ CannotParseID, OutOfMemory }![]u8 {
    const buf = toString(uuid) catch return error.CannotParseID;
    return allocator.dupe(u8, &buf) catch return error.OutOfMemory;
}

pub inline fn toBytes(string: []const u8) ![16]u8 {
    return pg.types.UUID.toBytes(string);
}

const pg = @import("pg");

const Allocator = std.mem.Allocator;
const std = @import("std");
