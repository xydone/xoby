description: ?[]const u8 = null,
content: ?struct {
    @"application/json": struct {
        schema: Schema,
    },
} = null,
pub fn jsonStringify(self: @This(), jws: *std.json.Stringify) !void {
    try jsonStringifyWithoutNull(self, jws);
}

const std = @import("std");

const Schema = @import("schema.zig");
const jsonStringifyWithoutNull = @import("common.zig").jsonStringifyWithoutNull;
