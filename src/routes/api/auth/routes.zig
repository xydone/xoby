const log = std.log.scoped(.auth_route);

const Endpoints = EndpointGroup(.{
    Register,
    Login,
    CreateAPIKey,
    Refresh,
    EditUserRole,
});

pub const endpoint_data = Endpoints.endpoint_data;
pub const init = Endpoints.init;

const Register = Endpoint(struct {
    const Body = struct {
        display_name: []const u8,
        username: []const u8,
        password: []const u8,
    };
    const Response = struct {
        id: []const u8,
        display_name: []const u8,
        username: []const u8,
    };
    pub const endpoint_data: EndpointData = .{
        .Request = .{
            .Body = Body,
        },
        .Response = Response,
        .method = .POST,
        .route_data = .{},
        .path = "/api/auth/register",
    };

    pub fn call(ctx: *Handler.RequestContext, req: EndpointRequest(Body, void, void), res: *httpz.Response) anyerror!void {
        const allocator = res.arena;
        const request = AuthModel.CreateUser.Request{
            .display_name = req.body.display_name,
            .username = req.body.username,
            .password = req.body.password,
        };
        const response = AuthModel.CreateUser.call(allocator, ctx.database_pool, request) catch |err| {
            log.err("AuthModel Create failed! {}\n", .{err});
            handleResponse(res, .internal_server_error, "Couldn't create user!");
            return;
        };
        defer response.deinit(allocator);

        res.status = 200;
        try res.json(Response{
            .id = response.id,
            .display_name = response.display_name,
            .username = response.username,
        }, .{});
    }
});

const Login = Endpoint(struct {
    const Body = struct {
        username: []const u8,
        password: []const u8,
    };
    const Response = struct {
        access_token: []const u8,
        refresh_token: []const u8,
        expires_in: i32,
    };
    pub const endpoint_data: EndpointData = .{
        .Request = .{
            .Body = Body,
        },
        .Response = struct {},
        .method = .POST,
        .route_data = .{},
        .path = "/api/auth/login",
    };

    pub fn call(ctx: *Handler.RequestContext, req: EndpointRequest(Body, void, void), res: *httpz.Response) anyerror!void {
        const allocator = res.arena;
        const jwt_secret = ctx.config.jwt_secret;

        const Model = AuthModel.CreateToken;

        const create_props = Model.Props{
            .allocator = allocator,
            .database_pool = ctx.database_pool,
            .jwt_secret = jwt_secret,
            .redis_client = ctx.redis_client,
        };

        const request: Model.Request = .{
            .username = req.body.username,
            .password = req.body.password,
        };

        var response = Model.call(create_props, request) catch |err| switch (err) {
            Model.Errors.UserNotFound, Model.Errors.InvalidPassword => {
                handleResponse(res, .unauthorized, null);
                return;
            },
            else => {
                log.err("Create Token failed! {s}", .{@errorName(err)});
                handleResponse(res, .internal_server_error, null);
                return;
            },
        };
        defer response.deinit(allocator);
        res.status = 200;

        try res.json(Response{
            .access_token = response.access_token,
            .expires_in = response.expires_in,
            .refresh_token = response.refresh_token,
        }, .{});
    }
});

const CreateAPIKey = Endpoint(struct {
    const Body = struct {
        permissions: AuthModel.Roles,
    };
    const Response = struct {
        api_key: []const u8,
    };
    pub const endpoint_data: EndpointData = .{
        .Request = .{
            .Body = Body,
        },
        .Response = Response,
        .method = .POST,
        .route_data = .{
            .signed_in = true,
        },
        .path = "/api/auth/keys",
    };

    pub fn call(ctx: *Handler.RequestContext, req: EndpointRequest(Body, void, void), res: *httpz.Response) anyerror!void {
        const Model = AuthModel.CreateAPIKey;
        const allocator = res.arena;

        const request: Model.Request = .{
            .role = req.body.permissions,
            .user_id = ctx.user_id.?,
        };

        const response = Model.call(allocator, ctx.database_pool, request) catch |err| {
            switch (err) {
                Model.Errors.MissingPermissions => handleResponse(res, .forbidden, "You cannot create an API key with permissions that you do not have access to!"),
                else => handleResponse(res, .internal_server_error, null),
            }
            return;
        };
        defer response.deinit(res.arena);

        res.status = 200;
        try res.json(Response{
            .api_key = response.api_key,
        }, .{});
    }
});

const Refresh = Endpoint(struct {
    const Response = struct {
        access_token: []const u8,
        refresh_token: []const u8,
        expires_in: i32,
    };
    pub const endpoint_data: EndpointData = .{
        .Request = .{},
        .Response = Response,
        .method = .POST,
        .path = "/api/auth/refresh",
        .route_data = .{
            .refresh = true,
        },
    };
    pub fn call(ctx: *Handler.RequestContext, _: EndpointRequest(void, void, void), res: *httpz.Response) anyerror!void {
        const allocator = res.arena;
        const jwt_secret = ctx.config.jwt_secret;
        const Model = AuthModel.RefreshToken;

        const response = Model.call(
            allocator,
            ctx.redis_client,
            ctx.refresh_token.?,
            jwt_secret,
        ) catch |err| switch (err) {
            Model.Errors.UserNotFound => {
                handleResponse(res, .unauthorized, null);
                return;
            },
            else => {
                log.err("Refresh Token model failed! {s}", .{@errorName(err)});
                handleResponse(res, .internal_server_error, null);
                return;
            },
        };
        defer response.deinit(allocator);
        res.status = 200;

        try res.json(Response{
            .access_token = response.access_token,
            .refresh_token = response.refresh_token,
            .expires_in = response.expires_in,
        }, .{});
    }
});

const EditUserRole = Endpoint(struct {
    const Body = struct {
        target_user_id: []const u8,
        role: AuthModel.Roles,
    };
    const Response = struct {
        id: []const u8,
        display_name: []const u8,
        username: []const u8,
        role: AuthModel.Roles,
    };
    pub const endpoint_data: EndpointData = .{
        .Request = .{
            .Body = Body,
        },
        .Response = Response,
        .method = .PATCH,
        .route_data = .{
            .admin = true,
        },
        .path = "/api/auth/users/",
    };

    pub fn call(ctx: *Handler.RequestContext, req: EndpointRequest(Body, void, void), res: *httpz.Response) anyerror!void {
        const allocator = res.arena;
        const Model = AuthModel.EditUserRole;
        const request = Model.Request{
            .target_user_id = req.body.target_user_id,
            .role = req.body.role,
        };
        const response = Model.call(allocator, ctx.database_pool, request) catch |err| {
            log.err("EditUserRole model failed! {}\n", .{err});
            handleResponse(res, .internal_server_error, "Couldn't create user!");
            return;
        };
        defer response.deinit(allocator);

        res.status = 200;
        try res.json(Response{
            .id = response.id,
            .display_name = response.display_name,
            .username = response.username,
            .role = response.role,
        }, .{});
    }
});

const AuthModel = @import("../../../models/models.zig").Auth;

const Endpoint = @import("../../../endpoint.zig").Endpoint;
const EndpointRequest = @import("../../../endpoint.zig").EndpointRequest;
const EndpointData = @import("../../../endpoint.zig").EndpointData;
const EndpointGroup = @import("../../../endpoint.zig").EndpointGroup;
const handleResponse = @import("../../../endpoint.zig").handleResponse;

const Handler = @import("../../../handler.zig");
const httpz = @import("httpz");

const std = @import("std");
