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
    const Body = struct {};

    const Response = struct {};

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
        _ = ctx;
        _ = req;
        _ = res;
    }
});

const GetList = Endpoint(struct {
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
        .path = "/api/profile/list",
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

const Endpoint = @import("../../../endpoint.zig").Endpoint;
const EndpointRequest = @import("../../../endpoint.zig").EndpointRequest;
const EndpointData = @import("../../../endpoint.zig").EndpointData;
const EndpointGroup = @import("../../../endpoint.zig").EndpointGroup;
const handleResponse = @import("../../../endpoint.zig").handleResponse;

const Handler = @import("../../../handler.zig");
const httpz = @import("httpz");

const std = @import("std");
