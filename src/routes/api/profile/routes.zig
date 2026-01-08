const log = std.log.scoped(.profile_route);

const Endpoints = EndpointGroup(.{
    CreateList,
    ChangeList,
    GetList,
    GetLists,
    GetProgress,
    GetRatings,
});

pub const endpoint_data = Endpoints.endpoint_data;
pub const init = Endpoints.init;

const CreateList = Endpoint(struct {
    const Body = struct {
        name: []const u8,
        is_public: bool,
    };

    const Response = struct {
        id: []const u8,
    };

    pub const endpoint_data: EndpointData = .{
        .Request = .{
            .Body = Body,
        },
        .Response = Response,
        .method = .POST,
        .route_data = .{
            .restricted = true,
        },
        .path = "/api/profile/list",
    };

    pub fn call(ctx: *Handler.RequestContext, req: EndpointRequest(Body, void, void), res: *httpz.Response) anyerror!void {
        const allocator = res.arena;
        const Model = ProfileModel.CreateList;

        const request = Model.Request{
            .user_id = ctx.user_id.?,
            .name = req.body.name,
            .is_public = req.body.is_public,
        };

        const response = Model.call(allocator, ctx.database_pool, request) catch |err| {
            log.err("Create List Model failed! {}", .{err});
            handleResponse(res, .internal_server_error, null);
            return;
        };
        defer response.deinit(allocator);

        res.status = 200;
        try res.json(Response{
            .id = response.id,
        }, .{});
    }
});

const GetList = Endpoint(struct {
    const Params = struct {
        id: []const u8,
    };

    const Response = struct {
        id: []const u8,
        user_id: []const u8,
        name: []const u8,
        is_public: bool,
        created_at: i64,
        items: []ProfileModel.GetList.Response.Item,
    };

    pub const endpoint_data: EndpointData = .{
        .Request = .{
            .Params = Params,
        },
        .Response = Response,
        .method = .GET,
        .route_data = .{
            .restricted = true,
        },
        .path = "/api/profile/list/:id",
    };

    pub fn call(ctx: *Handler.RequestContext, req: EndpointRequest(void, Params, void), res: *httpz.Response) anyerror!void {
        const allocator = res.arena;
        const Model = ProfileModel.GetList;

        const request = Model.Request{
            .user_id = ctx.user_id.?,
            .list_id = req.params.id,
        };

        const response = Model.call(allocator, ctx.database_pool, request) catch |err| {
            log.err("Get List Model failed! {}", .{err});
            handleResponse(res, .internal_server_error, null);
            return;
        };
        defer response.deinit(allocator);

        res.status = 200;
        try res.json(Response{
            .id = response.id,
            .user_id = response.user_id,
            .name = response.name,
            .is_public = response.is_public,
            .created_at = response.created_at,
            .items = response.items,
        }, .{});
    }
});

const GetLists = Endpoint(struct {
    const Body = struct {};

    const Response = struct {};

    pub const endpoint_data: EndpointData = .{
        .Request = .{
            .Body = Body,
        },
        .Response = Response,
        .method = .GET,
        .route_data = .{
            .restricted = true,
        },
        .path = "/api/profile/lists",
    };

    pub fn call(ctx: *Handler.RequestContext, req: EndpointRequest(Body, void, void), res: *httpz.Response) anyerror!void {
        _ = ctx;
        _ = req;
        _ = res;
    }
});

const ChangeList = Endpoint(struct {
    const Body = struct {};

    const Response = struct {};

    pub const endpoint_data: EndpointData = .{
        .Request = .{
            .Body = Body,
        },
        .Response = Response,
        .method = .PATCH,
        .route_data = .{
            .restricted = true,
        },
        .path = "/api/profile/list",
    };

    pub fn call(ctx: *Handler.RequestContext, req: EndpointRequest(Body, void, void), res: *httpz.Response) anyerror!void {
        _ = ctx;
        _ = req;
        _ = res;
    }
});

const GetRatings = Endpoint(struct {
    const Body = struct {};

    const Response = struct {};

    pub const endpoint_data: EndpointData = .{
        .Request = .{
            .Body = Body,
        },
        .Response = Response,
        .method = .GET,
        .route_data = .{
            .restricted = true,
        },
        .path = "/api/profile/ratings/",
    };

    pub fn call(ctx: *Handler.RequestContext, req: EndpointRequest(Body, void, void), res: *httpz.Response) anyerror!void {
        _ = ctx;
        _ = req;
        _ = res;
    }
});

const GetProgress = Endpoint(struct {
    const Body = struct {};

    const Response = struct {};

    pub const endpoint_data: EndpointData = .{
        .Request = .{
            .Body = Body,
        },
        .Response = Response,
        .method = .GET,
        .route_data = .{
            .restricted = true,
        },
        .path = "/api/profile/progress",
    };

    pub fn call(ctx: *Handler.RequestContext, req: EndpointRequest(Body, void, void), res: *httpz.Response) anyerror!void {
        _ = ctx;
        _ = req;
        _ = res;
    }
});

const ProfileModel = @import("../../../models/profiles/profiles.zig");

const Endpoint = @import("../../../endpoint.zig").Endpoint;
const EndpointRequest = @import("../../../endpoint.zig").EndpointRequest;
const EndpointData = @import("../../../endpoint.zig").EndpointData;
const EndpointGroup = @import("../../../endpoint.zig").EndpointGroup;
const handleResponse = @import("../../../endpoint.zig").handleResponse;

const Handler = @import("../../../handler.zig");
const httpz = @import("httpz");

const std = @import("std");
