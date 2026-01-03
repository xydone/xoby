const CreateResult = struct {
    full_key: []u8,
    public_id: []u8,
    secret_hash: []u8,

    pub fn deinit(self: CreateResult, allocator: Allocator) void {
        allocator.free(self.full_key);
        allocator.free(self.public_id);
        allocator.free(self.secret_hash);
    }
};

pub fn create(allocator: Allocator) !CreateResult {
    const prefix = "xoby_";

    var public_id_bytes: [8]u8 = undefined;
    std.crypto.random.bytes(&public_id_bytes);
    const public_id_hex = try std.fmt.allocPrint(allocator, "{s}", .{std.fmt.bytesToHex(public_id_bytes, .lower)});
    errdefer allocator.free(public_id_hex);

    var secret_bytes: [32]u8 = undefined;
    std.crypto.random.bytes(&secret_bytes);

    var secret_hex_buf: [64]u8 = undefined;
    const secret_hex = std.fmt.bufPrint(&secret_hex_buf, "{s}", .{std.fmt.bytesToHex(secret_bytes, .lower)}) catch std.debug.panic("bufPrint failed?", .{});

    const full_key = try std.fmt.allocPrint(allocator, "{s}{s}_{s}", .{ prefix, public_id_hex, secret_hex });
    errdefer allocator.free(full_key);

    var hash_out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(secret_hex, &hash_out, .{});
    const secret_hash = try allocator.dupe(u8, &hash_out);
    errdefer allocator.free(secret_hash);

    return .{
        .full_key = full_key,
        .public_id = public_id_hex,
        .secret_hash = secret_hash,
    };
}

pub fn verify(stored_hash: [32]u8, secret: []const u8) bool {
    var computed_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(secret, &computed_hash, .{});

    return std.crypto.timing_safe.eql([32]u8, computed_hash, stored_hash);
}

const Allocator = std.mem.Allocator;
const std = @import("std");
