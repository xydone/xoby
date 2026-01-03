const log = std.log.scoped(.auth_route);

pub inline fn init(router: *Handler.Router) void {
    Register.init(router);
    Login.init(router);
    CreateAPIKey.init(router);
}

const Register = Endpoint(struct {
    const Body = struct {
        display_name: []const u8,
        username: []const u8,
        password: []const u8,
    };
    const Response = struct {
        id: i32,
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
        .path = "/api/register",
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
    pub const endpoint_data: EndpointData = .{
        .Request = .{},
        .Response = struct {},
        .method = .POST,
        .route_data = .{},
        .path = "/api/login",
    };

    pub fn call(ctx: *Handler.RequestContext, req: EndpointRequest(void, void, void), res: *httpz.Response) anyerror!void {
        _ = ctx;
        _ = req;
        _ = res;
    }
});

const CreateAPIKey = Endpoint(struct {
    pub const endpoint_data: EndpointData = .{
        .Request = .{},
        .Response = struct {},
        .method = .POST,
        .route_data = .{},
        .path = "/api/keys",
    };

    pub fn call(ctx: *Handler.RequestContext, req: EndpointRequest(void, void, void), res: *httpz.Response) anyerror!void {
        _ = ctx;
        _ = req;
        _ = res;
    }
});

const AuthModel = @import("../../../models/models.zig").Auth;

const Endpoint = @import("../../../endpoint.zig").Endpoint;
const EndpointRequest = @import("../../../endpoint.zig").EndpointRequest;
const EndpointData = @import("../../../endpoint.zig").EndpointData;
const handleResponse = @import("../../../endpoint.zig").handleResponse;

const Handler = @import("../../../handler.zig");
const httpz = @import("httpz");

const std = @import("std");
