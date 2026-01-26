// TODO: rethink the way the terms collectors and fetchers are used interchangeably.
const log = std.log.scoped(.collectors_route);

const Endpoints = EndpointGroup(.{
    Index,
    Fetch,
    Active,
    Cancel,
});

pub const endpoint_data = Endpoints.endpoint_data;
pub const init = Endpoints.init;

const Index = Endpoint(struct {
    const Response = struct {};

    pub const endpoint_data: EndpointData = .{
        .Request = .{},
        .Response = Response,
        .method = .POST,
        .route_data = .{
            .admin = true,
        },
        .path = "/api/system/collectors/index",
    };

    pub fn call(ctx: *Handler.RequestContext, _: EndpointRequest(void, void, void), res: *httpz.Response) anyerror!void {
        const allocator = ctx.allocator;
        Collectors.Indexers.fetch(allocator, ctx.database_pool, ctx.config) catch |err| {
            log.err("Refetching indexers failed! {}", .{err});
            handleResponse(res, .internal_server_error, null);
            return;
        };
        res.status = 200;
    }
});

const Fetch = Endpoint(struct {
    const Body = struct {
        collectors: []Collectors.Collector,
    };
    const Response = struct {
        tmdb: ?Collectors.Fetchers.TMDB.Response = null,
    };

    pub const endpoint_data: EndpointData = .{
        .Request = .{
            .Body = Body,
        },
        .Response = Response,
        .method = .POST,
        .route_data = .{
            .admin = true,
        },
        .path = "/api/system/collectors/fetch",
    };

    pub fn call(ctx: *Handler.RequestContext, req: EndpointRequest(Body, void, void), res: *httpz.Response) anyerror!void {
        const allocator = ctx.allocator;
        const fetch_response = Collectors.Fetchers.fetch(
            allocator,
            ctx.collectors_fetchers,
            ctx.database_pool,
            ctx.config,
            ctx.user_id.?,
            req.body.collectors,
        ) catch |err| {
            log.err("Fetching failed! {}", .{err});
            handleResponse(res, .internal_server_error, null);
            return;
        };

        const response: Response = .{
            .tmdb = fetch_response.tmdb,
        };

        res.status = 200;
        try res.json(response, .{});
    }
});

const Active = Endpoint(struct {
    const Response = struct {
        tmdb: bool,
    };

    pub const endpoint_data: EndpointData = .{
        .Request = .{},
        .Response = Response,
        .method = .GET,
        .route_data = .{
            .admin = true,
        },
        .path = "/api/system/collectors",
    };

    pub fn call(ctx: *Handler.RequestContext, _: EndpointRequest(void, void, void), res: *httpz.Response) anyerror!void {
        const response: Response = .{
            .tmdb = if (ctx.collectors_fetchers.active_tmdb) |_| true else false,
        };

        res.status = 200;
        try res.json(response, .{});
    }
});

const Cancel = Endpoint(struct {
    const Body = struct {
        fetchers: []Collectors.Fetchers.Fetcher,
    };
    const Response = struct {
        tmdb: bool,
    };

    pub const endpoint_data: EndpointData = .{
        .Request = .{
            .Body = Body,
        },
        .Response = Response,
        .method = .POST,
        .route_data = .{
            .admin = true,
        },
        .path = "/api/system/collectors",
    };

    pub fn call(ctx: *Handler.RequestContext, req: EndpointRequest(Body, void, void), res: *httpz.Response) anyerror!void {
        for (req.body.fetchers) |fetcher| {
            ctx.collectors_fetchers.cancel(fetcher);
        }

        const response: Response = .{
            .tmdb = if (ctx.collectors_fetchers.active_tmdb) |_| true else false,
        };

        res.status = 200;
        try res.json(response, .{});
    }
});

const Collectors = @import("../../../../collectors/collectors.zig");

const Endpoint = @import("../../../../endpoint.zig").Endpoint;
const EndpointRequest = @import("../../../../endpoint.zig").EndpointRequest;
const EndpointData = @import("../../../../endpoint.zig").EndpointData;
const EndpointGroup = @import("../../../../endpoint.zig").EndpointGroup;
const handleResponse = @import("../../../../endpoint.zig").handleResponse;

const Handler = @import("../../../../handler.zig");
const httpz = @import("httpz");

const std = @import("std");
