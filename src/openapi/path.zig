get: ?Operation = null,
delete: ?Operation = null,
post: ?Operation = null,
put: ?Operation = null,
head: ?Operation = null,
patch: ?Operation = null,
options: ?Operation = null,
connect: ?Operation = null,

pub fn jsonStringify(self: @This(), jws: *std.json.Stringify) !void {
    try jsonStringifyWithoutNull(self, jws);
}

pub const Operation = struct {
    tags: ?[]const []const u8 = null,
    summary: ?[]const u8 = null,
    description: ?[]const u8 = null,
    requestBody: ?RequestBody = null,
    parameters: ?[]Parameter = null,
    responses: std.StringHashMap(Response),

    pub fn jsonStringify(self: @This(), jws: *std.json.Stringify) !void {
        try jsonStringifyWithoutNull(self, jws);
    }

    pub const RequestBody = struct {
        description: ?[]const u8 = null,
        required: bool,
        content: struct {
            @"application/json": struct {
                schema: Schema,
            },
        },
        pub fn jsonStringify(self: @This(), jws: *std.json.Stringify) !void {
            try jsonStringifyWithoutNull(self, jws);
        }
    };

    pub const Parameter = struct {
        name: []const u8,
        in: In,
        description: ?[]const u8 = null,
        required: bool,
        // explode: bool,
        schema: Schema,

        pub fn jsonStringify(self: @This(), jws: *std.json.Stringify) !void {
            try jsonStringifyWithoutNull(self, jws);
        }
    };
};

pub const In = enum { path, query };
const std = @import("std");
const jsonStringifyWithoutNull = @import("common.zig").jsonStringifyWithoutNull;
const Schema = @import("schema.zig");
const Response = @import("response.zig");
