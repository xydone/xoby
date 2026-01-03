pub fn verifyPassword(allocator: Allocator, hash: []const u8, password: []const u8) !bool {
    const verify_error = std.crypto.pwhash.argon2.strVerify(
        hash,
        password,
        .{ .allocator = allocator },
    );

    return if (verify_error)
        true
    else |err| switch (err) {
        error.AuthenticationFailed, error.PasswordVerificationFailed => false,
        else => err,
    };
}

// https://github.com/thienpow/zui/blob/467c84de15259956a2139bba4a863ac0285a8a22/src/app/utils/password.zig#L37-L64
pub fn hashPassword(allocator: Allocator, password: []const u8) ![]const u8 {
    // Argon2id output format: $argon2id$v=19$m=32,t=3,p=4$salt$hash
    // Typical max length: ~108 bytes with default salt (16 bytes) and hash (32 bytes)
    // Using 128 as a safe upper bound
    const buf_size = 128;
    const buf = try allocator.alloc(u8, buf_size);

    const hashed = try std.crypto.pwhash.argon2.strHash(
        password,
        .{
            .allocator = allocator,
            .params = .{
                .t = 1, // Time cost
                .m = 32, // Memory cost (32 KiB)
                .p = 4, // Parallelism
            },
            .mode = .argon2id, // Explicitly specify for consistency
        },
        buf,
    );

    // Trim the buffer to actual size
    const actual_len = hashed.len;
    if (actual_len < buf_size) {
        return try allocator.realloc(buf, actual_len);
    }
    return hashed;
}

const Allocator = std.mem.Allocator;
const std = @import("std");
