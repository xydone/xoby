pub inline fn toString(uuid: []const u8) ![36]u8 {
    return pg.uuidToHex(uuid);
}

const pg = @import("pg");
