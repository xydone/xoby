const Schema = @This();

title: ?[]const u8 = null,
default: ?[]const u8 = null,
multipleOf: ?f64 = null,
maximum: ?f64 = null,
properties: ?std.StringHashMap(Schema) = null,
exclusiveMaximum: ?bool = null,
minimum: ?f64 = null,
exclusiveMinimum: ?bool = null,
maxLength: ?i64 = null,
minLength: ?i64 = null,
pattern: ?[]const u8 = null,
items: ?*Schema = null,
minProperties: ?i64 = null,
required: ?[]const []const u8 = null,
@"enum": ?[][]const u8 = null,
type: ?Types = null,
description: ?[]const u8 = null,
format: ?[]const u8 = null,
nullable: ?bool = null,
readOnly: ?bool = null,
writeOnly: ?bool = null,
deprecated: ?bool = null,

pub fn init(T: type, allocator: std.mem.Allocator) Schema {
    const @"type" = Types.parse(T);
    const type_info = @typeInfo(T);

    return .{
        .type = @"type",
        .@"enum" = if (type_info == .@"enum") blk: {
            var values = std.ArrayList([]const u8).empty;
            inline for (type_info.@"enum".fields) |field| {
                values.append(allocator, field.name) catch @panic("OOM");
            }
            break :blk values.items;
        } else null,
        .items = if (@"type" == .array) blk: {
            const child_type = switch (type_info) {
                .optional => inner_blk: {
                    if (@typeInfo(type_info.optional.child) == .pointer) {
                        const child = @typeInfo(type_info.optional.child).pointer.child;
                        if (child == u8) {
                            break :inner_blk []u8;
                        }
                        break :inner_blk child;
                    }

                    break :inner_blk type_info.optional.child;
                },
                .pointer => inner_blk: {
                    const child = type_info.pointer.child;
                    break :inner_blk if (child == u8 and type_info.pointer.size == .slice) []u8 else child;
                },
                else => T,
            };
            const schema = allocator.create(Schema) catch @panic("OOM");
            const parsed_type = Types.parse(child_type);

            var properties_map: ?std.StringHashMap(Schema) = null;

            if (parsed_type == .object) {
                var map = std.StringHashMap(Schema).init(allocator);
                const child_type_info = @typeInfo(child_type);
                const struct_info = switch (child_type_info) {
                    .optional => @typeInfo(child_type_info.optional.child),
                    else => child_type_info,
                };

                if (struct_info == .@"struct") {
                    inline for (struct_info.@"struct".fields) |field| {
                        // recursively generate each field element
                        const field_schema = Schema.init(field.type, allocator);
                        map.put(field.name, field_schema) catch @panic("OOM");
                    }
                }
                properties_map = map;
            }

            schema.* = Schema{
                .type = parsed_type,
                .properties = properties_map,
            };
            break :blk schema;
        } else null,
    };
}

pub const Types = enum {
    array,
    boolean,
    integer,
    number,
    object,
    string,
    pub fn parse(T: type) Types {
        const type_info = blk: {
            const t = @typeInfo(T);
            if (t == .optional) break :blk @typeInfo(t.optional.child) else break :blk t;
        };

        switch (type_info) {
            .@"struct" => {
                return .object;
            },
            .@"enum" => return .string,
            .pointer => |ptr| {
                if (ptr.size == .slice and ptr.child != u8) return .array else return .string;
            },
            else => {},
        }
        return switch (T) {
            i8,
            u8,
            i16,
            u16,
            i32,
            u32,
            i64,
            u64,
            f32,
            f64,
            ?i16,
            ?u16,
            ?i32,
            ?u32,
            ?i64,
            ?u64,
            ?f32,
            ?f64,
            => .number,
            []const u8, []u8, ?[]const u8, ?[]u8 => .string,
            []i32 => .array,
            bool => .boolean,
            else => |t| @compileError(std.fmt.comptimePrint("{} not supported | {}", .{ t, type_info })),
        };
    }
};

pub fn jsonStringify(self: Schema, jws: *std.json.Stringify) !void {
    try jsonStringifyWithoutNull(self, jws);
}

const std = @import("std");
const jsonStringifyWithoutNull = @import("common.zig").jsonStringifyWithoutNull;
