const log = std.log.scoped(.auth_model);

pub const Roles = enum { user, admin };

/// what is stored on redis
const UserSession = struct {
    id: []const u8,
    role: Roles,
};

const ACCESS_TOKEN_EXPIRY = 15 * 60;
const REFRESH_TOKEN_EXPIRY = 7 * 24 * 60 * 60;

inline fn generateAccessTokenExpiry() i64 {
    return std.time.timestamp() + ACCESS_TOKEN_EXPIRY;
}

pub const CreateUser = struct {
    pub const Request = struct {
        display_name: []const u8,
        username: []const u8,
        password: []const u8,
    };
    pub const Response = struct {
        id: []const u8,
        display_name: []const u8,
        username: []const u8,
        pub fn deinit(self: Response, allocator: std.mem.Allocator) void {
            allocator.free(self.id);
            allocator.free(self.display_name);
            allocator.free(self.username);
        }
    };
    pub const Errors = error{
        CannotCreate,
        UsernameNotUnique,
        HashingError,
        CannotParseID,
        OutOfMemory,
    } || DatabaseErrors;
    pub fn call(allocator: std.mem.Allocator, database: *Pool, request: Request) Errors!Response {
        var conn = database.acquire() catch return error.CannotAcquireConnection;
        defer conn.release();
        const error_handler = ErrorHandler{ .conn = conn };

        const hashed_password = hashPassword(allocator, request.password) catch return error.HashingError;
        defer allocator.free(hashed_password);
        var row = conn.row(query_string, .{ request.display_name, request.username, hashed_password }) catch |err| {
            const error_data = error_handler.handle(err);
            if (error_data) |data| {
                if (data.isUnique()) return Errors.UsernameNotUnique;
                ErrorHandler.printErr(data);
            }

            return error.CannotCreate;
        } orelse return error.CannotCreate;
        defer row.deinit() catch {};

        const id = try UUID.toStringAlloc(allocator, row.get([]u8, 0));
        const display_name = allocator.dupe(u8, row.get([]u8, 1)) catch return error.OutOfMemory;
        const username = allocator.dupe(u8, row.get([]u8, 2)) catch return error.OutOfMemory;

        return Response{
            .id = id,
            .display_name = display_name,
            .username = username,
        };
    }
    const query_string = "INSERT INTO auth.users (display_name, username, password) VALUES ($1,$2,$3) returning id,display_name,username";
};

pub const DeleteUser = struct {
    pub const Response = bool;
    pub const Errors = error{NoUser} || DatabaseErrors;
    pub fn call(database: *Pool, user_id: []const u8) Errors!void {
        var conn = database.acquire() catch return error.CannotAcquireConnection;
        defer conn.release();
        const error_handler = ErrorHandler{ .conn = conn };

        const rows = conn.exec(query_string, .{user_id}) catch |err| {
            const error_data = error_handler.handle(err);
            if (error_data) |data| ErrorHandler.printErr(data);
            return error.NoUser;
        } orelse return error.NoUser;
        if (rows != 1) return error.NoUser;
    }
    const query_string = "DELETE FROM auth.users WHERE id=$1";
};

pub const CreateToken = struct {
    pub const Request = struct {
        username: []const u8,
        password: []const u8,
    };
    pub const Response = struct {
        access_token: []const u8,
        refresh_token: []const u8,
        expires_in: i32,

        pub fn deinit(self: Response, allocator: std.mem.Allocator) void {
            allocator.free(self.access_token);
            allocator.free(self.refresh_token);
        }
    };

    pub const Props = struct {
        allocator: std.mem.Allocator,
        database_pool: *Pool,
        jwt_secret: []const u8,
        redis_client: *redis.Client,
    };

    pub const Errors = error{
        CannotCreate,
        InvalidPassword,
        UserNotFound,
        CannotParseID,
        RedisError,
        OutOfMemory,
    } || DatabaseErrors;
    pub fn call(props: Props, request: Request) Errors!Response {
        var conn = props.database_pool.acquire() catch return error.CannotAcquireConnection;
        defer conn.release();
        const error_handler = ErrorHandler{ .conn = conn };

        var row = conn.row(
            query_string,
            .{request.username},
        ) catch |err| {
            const error_data = error_handler.handle(err);
            if (error_data) |data| {
                ErrorHandler.printErr(data);
            }

            return error.CannotCreate;
        } orelse return error.UserNotFound;
        defer row.deinit() catch {};

        const id = try UUID.toStringAlloc(props.allocator, row.get([]u8, 0));
        defer props.allocator.free(id);

        const hash = row.get([]u8, 1);

        const role = row.get(Roles, 2);

        const isValidPassword = verifyPassword(props.allocator, hash, request.password) catch return error.CannotCreate;
        const claims = JWTClaims{
            .user_id = id,
            .exp = generateAccessTokenExpiry(),
            .role = role,
        };

        if (!isValidPassword) return error.InvalidPassword;
        const access_token = createJWT(props.allocator, claims, props.jwt_secret) catch return error.CannotCreate;

        const refresh_token = createSessionToken(props.allocator) catch return error.CannotCreate;

        const session: UserSession = .{
            .id = id,
            .role = role,
        };

        const value_string = jsonStringify(props.allocator, session) catch return error.OutOfMemory;
        defer props.allocator.free(value_string);

        const response = props.redis_client.setWithExpiry(props.allocator, refresh_token, value_string, REFRESH_TOKEN_EXPIRY) catch return error.RedisError;
        defer props.allocator.free(response);

        return Response{
            .access_token = access_token,
            .refresh_token = refresh_token,
            .expires_in = ACCESS_TOKEN_EXPIRY,
        };
    }

    const query_string = "SELECT id, password, role FROM auth.users WHERE username=$1;";
};

pub const RefreshToken = struct {
    pub const Response = struct {
        access_token: []const u8,
        refresh_token: []const u8,
        expires_in: i32,

        pub fn deinit(self: Response, allocator: std.mem.Allocator) void {
            allocator.free(self.access_token);
        }
    };

    pub const Errors = error{
        CannotCreateJWT,
        UserNotFound,
        RedisError,
        ParseError,
        CannotParseID,
        OutOfMemory,
    };
    pub fn call(allocator: std.mem.Allocator, redis_client: *redis.Client, refresh_token: []const u8, jwt_secret: []const u8) Errors!Response {
        const value = redis_client.get(allocator, refresh_token) catch |err| switch (err) {
            error.KeyValuePairNotFound => return error.UserNotFound,
            else => return error.RedisError,
        };
        defer allocator.free(value);

        const parsed_session: std.json.Parsed(UserSession) = std.json.parseFromSlice(UserSession, allocator, value, .{}) catch return error.ParseError;
        defer parsed_session.deinit();

        const session = parsed_session.value;

        const claims = JWTClaims{
            .user_id = session.id,
            .exp = generateAccessTokenExpiry(),
            .role = session.role,
        };

        const access_token = createJWT(allocator, claims, jwt_secret) catch return error.CannotCreateJWT;

        return Response{
            .access_token = access_token,
            .refresh_token = refresh_token,
            .expires_in = ACCESS_TOKEN_EXPIRY,
        };
    }
};

pub const InvalidateToken = struct {
    pub const Props = struct {
        allocator: std.mem.Allocator,
        refresh_token: []const u8,
        redis_client: *redis.Client,
    };

    pub fn call(props: Props) anyerror!bool {
        const response = try props.redis_client.delete(props.allocator, props.refresh_token);
        defer props.allocator.free(response);
        return if (std.mem.eql(u8, response, ":0")) false else true;
    }
};

// NOTE: currently this does not handle a potential collision and just errors. This *should* be unlikely though.
pub const CreateAPIKey = struct {
    pub const Request = struct {
        user_id: []const u8,
        role: Roles,
    };
    pub const Response = struct {
        api_key: []const u8,

        pub fn deinit(self: Response, allocator: std.mem.Allocator) void {
            allocator.free(self.api_key);
        }
    };

    pub const Errors = error{
        CannotCreate,
        UserNotFound,
        MissingPermissions,
    } || DatabaseErrors;
    pub fn call(allocator: std.mem.Allocator, database: *Pool, request: Request) Errors!Response {
        var conn = database.acquire() catch return error.CannotAcquireConnection;
        defer conn.release();
        const error_handler = ErrorHandler{ .conn = conn };

        const api_key_response = createAPIKey(allocator) catch return error.CannotCreate;
        defer {
            allocator.free(api_key_response.public_id);
            allocator.free(api_key_response.secret_hash);
        }
        errdefer allocator.free(api_key_response.full_key);

        const rows = conn.exec(
            query_string,
            .{
                request.user_id,
                request.role,
                api_key_response.public_id,
                api_key_response.secret_hash,
            },
        ) catch |err| {
            const error_data = error_handler.handle(err);
            if (error_data) |data| {
                ErrorHandler.printErr(data);
            }

            return error.CannotCreate;
        } orelse return error.CannotCreate;

        if (rows == 0) {
            return error.MissingPermissions;
        }

        return .{
            .api_key = api_key_response.full_key,
        };
    }
    const query_string =
        \\ INSERT INTO auth.api_keys (user_id, permissions, public_id, secret_hash)
        \\ SELECT p.id, $2, $3, $4
        \\ FROM auth.users p
        \\ WHERE p.id = $1 
        \\ AND p.role >= $2;
    ;
};

pub const GetUserByAPIKey = struct {
    pub const Response = struct {
        id: []const u8,
        permissions: Roles,

        pub fn deinit(self: @This(), allocator: Allocator) void {
            allocator.free(self.id);
        }
    };
    pub const Errors = error{
        OutOfMemory,
        CannotGet,
        InvalidAPIKey,
        UserNotFound,
        CannotParseID,
    } || DatabaseErrors;
    pub fn call(allocator: std.mem.Allocator, database: *Pool, api_key: []const u8) Errors!Response {
        var conn = database.acquire() catch return error.CannotAcquireConnection;
        defer conn.release();
        const error_handler = ErrorHandler{ .conn = conn };

        var it = std.mem.tokenizeScalar(u8, api_key, '_');
        _ = it.next(); // skip the prefix

        const public_id = it.next() orelse return error.InvalidAPIKey;

        const secret = it.next() orelse return error.InvalidAPIKey;

        var row = conn.row(query_string, //
            .{public_id}) catch |err| {
            const error_data = error_handler.handle(err);
            if (error_data) |data| {
                ErrorHandler.printErr(data);
            }

            return error.CannotGet;
        } orelse return error.UserNotFound;
        defer row.deinit() catch {};

        const response = row.to(struct {
            user_id: []u8,
            secret_hash: []u8,
            permissions: Roles,
        }, .{}) catch return error.CannotGet;
        std.debug.assert(response.secret_hash.len == 32);
        const hash = response.secret_hash[0..32].*;

        if (!verifyAPIKey(hash, secret)) return error.CannotGet;

        const id = try UUID.toStringAlloc(allocator, row.get([]u8, 0));

        return .{
            .id = id,
            .permissions = response.permissions,
        };
    }
    const query_string =
        \\SELECT user_id, secret_hash,permissions 
        \\FROM auth.api_keys
        \\WHERE public_id = $1;
    ;
};

test "Model | Auth | Create User" {
    // SETUP
    const test_name = "Model | Auth | Create User";
    const test_env = Tests.test_env;
    const allocator = std.testing.allocator;

    const display_name = try std.fmt.allocPrint(allocator, "Display {s}", .{test_name});
    defer allocator.free(display_name);
    const password = try std.fmt.allocPrint(allocator, "Testing password", .{});
    defer allocator.free(password);

    const request = CreateUser.Request{
        .display_name = display_name,
        .username = test_name,
        .password = password,
    };

    // TEST
    {
        var response = try CreateUser.call(
            allocator,
            test_env.database_pool,
            request,
        );
        defer response.deinit(allocator);

        try std.testing.expectEqualStrings(test_name, response.username);
        try std.testing.expectEqualStrings(display_name, response.display_name);
    }
}

test "Model | Auth | Duplicate" {
    // SETUP
    const test_name = "Model | Auth | Duplicate";
    const test_env = Tests.test_env;
    const allocator = std.testing.allocator;

    const display_name = try std.fmt.allocPrint(allocator, "Display {s}", .{test_name});
    defer allocator.free(display_name);
    const password = try std.fmt.allocPrint(allocator, "Testing password", .{});
    defer allocator.free(password);

    const request = CreateUser.Request{
        .display_name = display_name,
        .username = test_name,
        .password = password,
    };
    var user = try CreateUser.call(
        allocator,
        test_env.database_pool,
        request,
    );
    defer user.deinit(allocator);

    // TEST
    {
        if (CreateUser.call(
            allocator,
            test_env.database_pool,
            request,
        )) |*duplicate_user| {
            const usr = @constCast(duplicate_user);
            usr.deinit(allocator);
        } else |err| {
            try std.testing.expectEqual(CreateUser.Errors.UsernameNotUnique, err);
        }
    }
}

test "Model | Auth | Delete User" {
    // SETUP
    const test_name = "Model | Auth | Delete User";
    const test_env = Tests.test_env;
    const allocator = std.testing.allocator;

    const display_name = try std.fmt.allocPrint(allocator, "Display {s}", .{test_name});
    defer allocator.free(display_name);
    const password = try std.fmt.allocPrint(allocator, "Testing password", .{});
    defer allocator.free(password);

    const request = CreateUser.Request{
        .display_name = display_name,
        .username = test_name,
        .password = password,
    };

    const user = try CreateUser.call(
        allocator,
        test_env.database_pool,
        request,
    );
    defer user.deinit(allocator);

    // TEST
    {
        _ = try DeleteUser.call(
            test_env.database_pool,
            user.id,
        );
    }
}

test "Model | Auth | Create" {
    //SETUP
    const allocator = std.testing.allocator;
    const jwt = @import("jwt");
    const test_env = Tests.test_env;
    const test_name = "Model | Auth | Create";
    var setup = try TestSetup.init(test_env.database_pool, test_name);
    defer setup.deinit(allocator);

    const jwt_secret = test_env.config.jwt_secret;
    const props = CreateToken.Props{
        .allocator = allocator,
        .database_pool = test_env.database_pool,
        .jwt_secret = jwt_secret,
        .redis_client = test_env.redis_client,
    };

    const password = try std.fmt.allocPrint(allocator, "Testing password", .{});
    defer allocator.free(password);

    // TEST
    var access_token: ?[]u8 = null;
    var refresh_token: ?[]u8 = null;
    defer {
        if (access_token) |token| allocator.free(token);
        if (refresh_token) |token| allocator.free(token);
    }

    // Create test
    {
        var create_response = try CreateToken.call(props, .{
            .username = test_name,
            .password = password,
        });
        defer create_response.deinit(allocator);

        access_token = try allocator.dupe(u8, create_response.access_token);
        refresh_token = try allocator.dupe(u8, create_response.refresh_token);

        var decoded = try jwt.decode(allocator, JWTClaims, create_response.access_token, .{ .secret = jwt_secret }, .{});
        defer decoded.deinit();

        try std.testing.expectEqualStrings(setup.user.id, decoded.claims.user_id);
    }
}

test "Model | Auth | Refresh" {
    //SETUP
    const allocator = std.testing.allocator;

    const test_env = Tests.test_env;
    const test_name = "Model | Auth | Refresh";
    var setup = try TestSetup.init(test_env.database_pool, test_name);
    defer setup.deinit(allocator);

    const password = try std.fmt.allocPrint(allocator, "Testing password", .{});
    defer allocator.free(password);
    const jwt_secret = test_env.config.jwt_secret;
    const props = CreateToken.Props{
        .allocator = allocator,
        .database_pool = test_env.database_pool,
        .jwt_secret = jwt_secret,
        .redis_client = test_env.redis_client,
    };
    var create = try CreateToken.call(props, .{
        .username = test_name,
        .password = password,
    });
    defer create.deinit(allocator);

    const access_token = try allocator.dupe(u8, create.access_token);
    defer allocator.free(access_token);
    const refresh_token = try allocator.dupe(u8, create.refresh_token);
    defer allocator.free(refresh_token);

    // TEST
    {
        const refresh = try allocator.dupe(u8, refresh_token);
        defer allocator.free(refresh);

        const refresh_response = try RefreshToken.call(allocator, test_env.redis_client, refresh, jwt_secret);
        defer refresh_response.deinit(allocator);

        try std.testing.expectEqualStrings(refresh_response.refresh_token, refresh_token);
    }
}

test "Model | Auth | Invalidate" {
    //SETUP
    const allocator = std.testing.allocator;

    const test_env = Tests.test_env;
    const test_name = "Model | Auth | Invalidate";
    var setup = try TestSetup.init(test_env.database_pool, test_name);
    defer setup.deinit(allocator);

    const password = try std.fmt.allocPrint(allocator, "Testing password", .{});
    defer allocator.free(password);
    const jwt_secret = test_env.config.jwt_secret;
    const props = CreateToken.Props{
        .allocator = allocator,
        .database_pool = test_env.database_pool,
        .jwt_secret = jwt_secret,
        .redis_client = test_env.redis_client,
    };
    var create = try CreateToken.call(props, .{
        .username = test_name,
        .password = password,
    });
    defer create.deinit(allocator);

    const access_token = try allocator.dupe(u8, create.access_token);
    defer allocator.free(access_token);
    const refresh_token = try allocator.dupe(u8, create.refresh_token);
    defer allocator.free(refresh_token);

    // TEST
    {
        const invalidate_response = try InvalidateToken.call(.{
            .allocator = allocator,
            .redis_client = test_env.redis_client,
            .refresh_token = refresh_token,
        });
        try std.testing.expect(invalidate_response);
    }
}

test "Model | Auth | Create API Key" {
    //SETUP
    const allocator = std.testing.allocator;

    const test_env = Tests.test_env;
    const test_name = "Model | Auth | Create API Key";
    var setup = try TestSetup.init(test_env.database_pool, test_name);
    defer setup.deinit(allocator);

    const password = try std.fmt.allocPrint(allocator, "Testing password", .{});
    defer allocator.free(password);
    const jwt_secret = test_env.config.jwt_secret;
    const props = CreateToken.Props{
        .allocator = allocator,
        .database_pool = test_env.database_pool,
        .jwt_secret = jwt_secret,
        .redis_client = test_env.redis_client,
    };
    var create = try CreateToken.call(props, .{
        .username = test_name,
        .password = password,
    });
    defer create.deinit(allocator);

    const access_token = try allocator.dupe(u8, create.access_token);
    defer allocator.free(access_token);
    const refresh_token = try allocator.dupe(u8, create.refresh_token);
    defer allocator.free(refresh_token);

    // TEST
    {
        const request: CreateAPIKey.Request = .{
            .user_id = setup.user.id,
            .role = .user,
        };
        const response = try CreateAPIKey.call(allocator, test_env.database_pool, request);
        defer response.deinit(allocator);
    }
}

test "Model | Auth | Create API Key with incorrect permissions" {
    //SETUP
    const allocator = std.testing.allocator;

    const test_env = Tests.test_env;
    const test_name = "Model | Auth | Create API Key with incorrect permissions";
    var setup = try TestSetup.init(test_env.database_pool, test_name);
    defer setup.deinit(allocator);

    const password = try std.fmt.allocPrint(allocator, "Testing password", .{});
    defer allocator.free(password);
    const jwt_secret = test_env.config.jwt_secret;
    const props = CreateToken.Props{
        .allocator = allocator,
        .database_pool = test_env.database_pool,
        .jwt_secret = jwt_secret,
        .redis_client = test_env.redis_client,
    };
    var create = try CreateToken.call(props, .{
        .username = test_name,
        .password = password,
    });
    defer create.deinit(allocator);

    const access_token = try allocator.dupe(u8, create.access_token);
    defer allocator.free(access_token);
    const refresh_token = try allocator.dupe(u8, create.refresh_token);
    defer allocator.free(refresh_token);

    // TEST
    {
        const request: CreateAPIKey.Request = .{
            .user_id = setup.user.id,
            .role = .admin,
        };
        const response = CreateAPIKey.call(allocator, test_env.database_pool, request) catch |err| {
            try std.testing.expectEqual(CreateAPIKey.Errors.MissingPermissions, err);
            return;
        };
        defer response.deinit(allocator);
    }
}

/// WARNING: This does NOT validate if the request is valid. This can be used by a non-authorized user to promote themselves to the any role.
/// Caller is responsible for handling authorization.
///
/// The database will handle culling of now invalid API keys.
/// If a user gets demoted from Admin -> User, all of their Admin scoped keys are invalidated.
pub const EditUserRole = struct {
    pub const Request = struct {
        target_user_id: []const u8,
        role: Roles,
    };

    pub const Response = struct {
        id: []const u8,
        display_name: []const u8,
        username: []const u8,
        role: Roles,

        pub fn deinit(self: Response, allocator: std.mem.Allocator) void {
            allocator.free(self.id);
            allocator.free(self.display_name);
            allocator.free(self.username);
        }
    };

    pub const Errors = error{
        UserNotFound,
        CannotUpdate,
        CannotParseID,
        OutOfMemory,
        CannotAcquireConnection,
    } || DatabaseErrors;

    pub fn call(allocator: std.mem.Allocator, database: *Pool, request: Request) Errors!Response {
        var conn = database.acquire() catch return error.CannotAcquireConnection;
        defer conn.release();
        const error_handler = ErrorHandler{ .conn = conn };

        var row = conn.row(query_string, .{ request.target_user_id, request.role }) catch |err| {
            const error_data = error_handler.handle(err);
            if (error_data) |data| {
                ErrorHandler.printErr(data);
            }
            return error.CannotUpdate;
        } orelse return error.UserNotFound;

        defer row.deinit() catch {};

        const id = try UUID.toStringAlloc(allocator, row.get([]u8, 0));
        const display_name = allocator.dupe(u8, row.get([]u8, 1)) catch return error.OutOfMemory;
        const username = allocator.dupe(u8, row.get([]u8, 2)) catch return error.OutOfMemory;
        const role = row.get(Roles, 3);

        return Response{
            .id = id,
            .display_name = display_name,
            .username = username,
            .role = role,
        };
    }

    const query_string =
        \\UPDATE auth.users 
        \\SET role = $2
        \\WHERE id = $1
        \\RETURNING id, display_name, username, role
    ;
};

const Tests = @import("../../tests/setup.zig");
const TestSetup = Tests.TestSetup;

const redis = @import("../../redis.zig");
const Pool = @import("../../database.zig").Pool;
const DatabaseErrors = @import("../../database.zig").DatabaseErrors;
const ErrorHandler = @import("../../database.zig").ErrorHandler;

const Handler = @import("../../handler.zig");

const UUID = @import("../../util/uuid.zig");
const JWTClaims = @import("../../auth/tokens.zig").JWTClaims;

const jsonStringify = @import("../../util/jsonStringify.zig").jsonStringify;

const verifyPassword = @import("../../auth/password.zig").verifyPassword;
const hashPassword = @import("../../auth/password.zig").hashPassword;
const createJWT = @import("../../auth/tokens.zig").createJWT;
const createSessionToken = @import("../../auth/tokens.zig").createSessionToken;
const createAPIKey = @import("../../auth/api_keys.zig").create;
const verifyAPIKey = @import("../../auth/api_keys.zig").verify;

const Allocator = std.mem.Allocator;
const std = @import("std");
