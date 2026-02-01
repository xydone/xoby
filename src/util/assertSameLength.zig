/// asserts that all fields in a given struct have the same length
/// WARNING: only asserts in debug mode, removed for release
pub fn assertAllSameLength(instance: anytype, comptime fields_to_check: anytype) void {
    if (builtin.mode != .Debug) return;
    const T = @TypeOf(instance);
    const type_info = @typeInfo(T);

    if (type_info != .@"struct") {
        @compileError("assertAllSameLength expected struct, found " ++ @typeName(T));
    }

    const fields = type_info.@"struct".fields;

    if (fields.len == 0) return;

    const first_field_name = fields_to_check[0];
    const first_len = @field(instance, first_field_name).len;

    inline for (fields_to_check) |field_name| {
        const current_field = @field(instance, field_name);

        if (!@hasField(@TypeOf(current_field), "len")) {
            @compileError("Field '" ++ field_name ++ "' in " ++ @typeName(T) ++ " does not have a .len property.");
        }

        std.debug.assert(current_field.len == first_len);
    }
}

const builtin = @import("builtin");
const std = @import("std");
