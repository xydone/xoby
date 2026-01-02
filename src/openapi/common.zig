pub fn jsonStringifyWithoutNull(self: anytype, jws: *std.json.Stringify) !void {
    try jws.beginObject();
    inline for (@typeInfo(@TypeOf(self)).@"struct".fields) |field| {
        const field_type_name = @typeName(field.type);
        if (comptime std.mem.containsAtLeast(u8, field_type_name, 1, "hash_map")) blk: {
            // making optionals work
            var it = if (field_type_name[0] == '?') it_blk: {
                var f = @field(self, field.name) orelse break :blk;
                break :it_blk f.iterator();
            } else @field(self, field.name).iterator();

            try jws.objectField(field.name);
            try jws.beginObject();
            while (it.next()) |kv| {
                try jws.objectField(kv.key_ptr.*);
                try jws.write(kv.value_ptr.*);
            }
            try jws.endObject();
        } else {
            if (@typeInfo(field.type) == .optional) {
                if (@field(self, field.name)) |_| {
                    try jws.objectField(field.name);
                    try jws.write(@field(self, field.name));
                }
            } else {
                try jws.objectField(field.name);
                try jws.write(@field(self, field.name));
            }
        }
    }

    try jws.endObject();
}

const std = @import("std");

const Response = @import("response.zig");
