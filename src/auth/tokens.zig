pub const JWTClaims = struct {
    user_id: []const u8,
    role: Roles,
    exp: i64,
};

pub fn createJWT(allocator: Allocator, claims: anytype, secret: []const u8) ![]const u8 {
    return try jwt.encode(
        allocator,
        .{ .alg = .HS256 },
        claims,
        .{ .secret = secret },
    );
}

pub fn createSessionToken(allocator: Allocator) ![]const u8 {
    //NOTE: is this actually secure?
    var buf: [128]u8 = undefined;
    std.crypto.random.bytes(&buf);
    var dest: [172]u8 = undefined;
    const temp = std.base64.Base64Encoder.init(std.base64.standard_alphabet_chars, '=').encode(&dest, &buf);

    return allocator.dupe(u8, temp);
}

const Roles = @import("../models/auth/auth.zig").Roles;

const jwt = @import("jwt");

const Allocator = std.mem.Allocator;
const std = @import("std");
