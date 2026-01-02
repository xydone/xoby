openapi: []const u8,
info: struct {
    title: []const u8,
    version: []const u8,
},
paths: std.StringHashMap(Path),

pub fn jsonStringify(self: @This(), jws: *std.json.Stringify) !void {
    try jsonStringifyWithoutNull(self, jws);
}
const std = @import("std");

const jsonStringifyWithoutNull = @import("common.zig").jsonStringifyWithoutNull;

const Path = @import("path.zig");
