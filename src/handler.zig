database_pool: *Database.Pool,
redis_client: *redis.Client,
config: Config,
/// Handler is initalized with data, available at handler instantiation, at the main entry point of the program.
const Handler = @This();

const log = std.log.scoped(.handler);

pub const Router = httpz.Router(*Handler, *const fn (*Handler.RequestContext, *httpz.request.Request, *httpz.response.Response) anyerror!void);

/// Gives information about what the route is to the dispatch function and middleware.
pub const RouteData = struct {
    /// Requires authentication.
    signed_in: bool = false,
    /// Requires a refresh token.
    refresh: bool = false,
    /// Requires elevated permissions.
    admin: bool = false,
};

/// This will be passed to every request, should include things that would be needed inside a request but cannot/shouldn't be initialized every time.
/// The difference between RequestContext and Handler is that the RequestContext can contain information that is provided by the dispatch function and middleware.
pub const RequestContext = struct {
    user_id: ?[]const u8,
    user_role: ?Roles,
    refresh_token: ?[]const u8,
    database_pool: *Database.Pool,
    redis_client: *redis.Client,
    config: Config,
};

pub fn dispatch(self: *Handler, action: httpz.Action(*RequestContext), req: *httpz.Request, res: *httpz.Response) !void {
    const allocator = req.arena;
    var timer = try std.time.Timer.start();

    var ctx = RequestContext{
        .user_id = null,
        .refresh_token = null,
        .user_role = null,
        .database_pool = self.database_pool,
        .redis_client = self.redis_client,
        .config = self.config,
    };

    authenticateRequest(allocator, &ctx, req, res) catch {
        return try Logging.print(Logging{
            .allocator = allocator,
            .req = req.*,
            .res = res.*,
            .timer = &timer,
            .url_path = req.url.path,
        });
    };

    try action(&ctx, req, res);

    try Logging.print(Logging{
        .allocator = allocator,
        .req = req.*,
        .res = res.*,
        .timer = &timer,
        .url_path = req.url.path,
    });
}

fn authenticateRequest(allocator: Allocator, ctx: *RequestContext, req: *httpz.Request, res: *httpz.Response) !void {
    // Should be used for all failure states in this function, as to minimize information leakage.
    const handleRejection = struct {
        fn handleRejection(response: *httpz.Response) !void {
            handleResponse(response, .unauthorized, "Permission denied!");
            return error.AuthenticationFailed;
        }
    }.handleRejection;

    if (req.route_data) |rd| {
        const route_data: *const RouteData = @ptrCast(@alignCast(rd));

        const api_key = req.header("x-api-key");
        const access_token = req.header("authorization");

        if (route_data.signed_in) {
            const is_valid = verifyAllKeys(allocator, ctx, .{
                .access_token = access_token,
                .api_key = api_key,
            });
            if (is_valid == false) try handleRejection(res);
        }
        if (route_data.refresh) {
            verifyRefresh(allocator, ctx, req) catch {
                try handleRejection(res);
            };
        }
        if (route_data.admin) {
            const is_valid = verifyAllKeys(allocator, ctx, .{
                .access_token = access_token,
                .api_key = api_key,
            });

            if (is_valid == false) try handleRejection(res);

            if (ctx.user_role.? != .admin) try handleRejection(res);
        }
    }
}

const AllKeys = struct {
    api_key: ?[]const u8,
    access_token: ?[]const u8,
};

fn verifyAllKeys(allocator: Allocator, ctx: *RequestContext, all_keys: AllKeys) bool {
    if (all_keys.api_key) |key| {
        verifyAPIKey(allocator, ctx, key) catch {
            return false;
        };
    } else if (all_keys.access_token) |token| {
        verifyJWT(allocator, ctx, token) catch {
            return false;
        };
    } else return false;
    return true;
}

fn verifyJWT(allocator: std.mem.Allocator, ctx: *RequestContext, access_token: []const u8) error{ InvalidJWT, InvalidToken }!void {
    const JWTClaims = @import("auth/tokens.zig").JWTClaims;

    const prefix = "Bearer ";
    if (access_token.len == 0 or !std.mem.startsWith(u8, access_token, prefix)) {
        return error.InvalidToken;
    }
    const token = access_token[prefix.len..];
    var decoded = jwt.decode(
        allocator,
        JWTClaims,
        token,
        .{ .secret = ctx.config.jwt_secret },
        //NOTE: there is a leeway by default in the validation struct
        .{},
    ) catch {
        return error.InvalidJWT;
    };
    defer decoded.deinit();

    ctx.user_id = decoded.claims.user_id;
}

fn verifyAPIKey(allocator: Allocator, ctx: *RequestContext, api_key: []const u8) error{CannotGet}!void {
    const GetUserByAPIKey = AuthModel.GetUserByAPIKey;
    const response = GetUserByAPIKey.call(allocator, ctx.database_pool, api_key) catch return error.CannotGet;
    ctx.user_id = response.id;
    ctx.user_role = response.permissions;
}

fn verifyRefresh(allocator: Allocator, ctx: *RequestContext, req: *httpz.Request) error{ MissingBody, InvalidBodyJSON }!void {
    const body = req.body() orelse {
        return error.MissingBody;
    };

    const RefreshToken = struct {
        refresh_token: []const u8,
    };

    const json = std.json.parseFromSliceLeaky(RefreshToken, allocator, body, .{}) catch {
        return error.InvalidBodyJSON;
    };
    ctx.refresh_token = json.refresh_token;
}

const Logging = struct {
    allocator: std.mem.Allocator,
    timer: *std.time.Timer,
    req: httpz.Request,
    res: httpz.Response,
    url_path: []const u8,
    pub fn print(self: Logging) !void {
        const time = self.timer.read();
        const locale = try zdt.Timezone.tzLocal(self.allocator);
        const now = try zdt.Datetime.now(.{ .tz = &locale });

        var writer = std.Io.Writer.Allocating.init(self.allocator);
        defer writer.deinit();
        // https://github.com/FObersteiner/zdt/wiki/String-parsing-and-formatting-directives
        try now.toString("[%Y-%m-%d %H:%M:%S]", &writer.writer);
        const datetime = try writer.toOwnedSlice();
        std.debug.print("{s} {s} {s} {s}{d}\x1b[0m in {d:.2}ms ({d}ns)\n", .{
            datetime,
            @tagName(self.req.method),
            self.url_path,
            //ansi coloring (https://gist.github.com/fnky/458719343aabd01cfb17a3a4f7296797)
            switch (self.res.status / 100) {
                //green
                2 => "\x1b[32m",
                //red
                4 => "\x1b[31m",
                // if its not a 2XX or 3XX, yellow
                else => "\x1b[33m",
            },
            self.res.status,
            //in ms
            @as(f64, @floatFromInt(time)) / std.time.ns_per_ms,
            //in nanoseconds
            time,
        });
    }
};

pub const ResponseError = struct {
    code: u16,
    message: []const u8,
    details: ?[]const u8 = null,

    // 400
    pub const bad_request: ResponseError = .{
        .code = 400,
        .message = "Bad request.",
    };
    pub const body_missing: ResponseError = .{
        .code = 400,
        .message = "The request body is not found.",
    };
    pub const body_missing_fields: ResponseError = .{
        .code = 400,
        .message = "The request body is missing required fields.",
    };
    pub const unauthorized: ResponseError = .{
        .code = 401,
        .message = "You are not authorized to make this request.",
    };
    pub const forbidden: ResponseError = .{
        .code = 403,
        .message = "Forbidden.",
    };
    pub const not_found: ResponseError = .{
        .code = 404,
        .message = "Not found.",
    };

    // 500
    pub const internal_server_error: ResponseError = .{
        .code = 500,
        .message = "An unexpected error occurred on the server. Please try again later.",
    };
};

pub fn handleResponse(httpz_res: *httpz.Response, response_error: ResponseError, details: ?[]const u8) void {
    var response = response_error;
    response.details = details orelse null;
    httpz_res.status = response.code;
    httpz_res.json(response, .{ .emit_null_optional_fields = false }) catch @panic("Couldn't parse error response.");
    return;
}

const Roles = AuthModel.Roles;
const AuthModel = @import("models/auth/auth.zig");

const redis = @import("redis.zig");
const Database = @import("database.zig");
const Config = @import("config/config.zig");

const jwt = @import("jwt");
const zdt = @import("zdt");
const httpz = @import("httpz");

const Allocator = std.mem.Allocator;
const std = @import("std");
