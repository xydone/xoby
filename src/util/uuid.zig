pub inline fn toString(uuid: []const u8) ![36]u8 {
    return pg.uuidToHex(uuid);
}

pub inline fn toBytes(string: []const u8) ![16]u8 {
    return pg.types.UUID.toBytes(string);
}

const pg = @import("pg");
