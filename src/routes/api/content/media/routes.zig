const log = std.log.scoped(.media_route);

const Endpoints = EndpointGroup(.{
    Rate,
    EditRating,
    GetRating,
    CreateProgress,
    GetProgress,
});

pub const endpoint_data = Endpoints.endpoint_data;
pub const init = Endpoints.init;

const Rate = Endpoint(struct {
    const Body = struct {
        /// [0,10]
        rating_score: u8,
    };

    const Params = struct {
        id: []const u8,
    };

    const Response = struct {
        id: []const u8,
    };

    pub const endpoint_data: EndpointData = .{
        .Request = .{
            .Body = Body,
            .Params = Params,
        },
        .Response = Response,
        .method = .POST,
        .route_data = .{
            .restricted = true,
        },
        .path = "/api/media/:id/rating",
    };

    pub fn call(ctx: *Handler.RequestContext, req: EndpointRequest(Body, Params, void), res: *httpz.Response) anyerror!void {
        const allocator = res.arena;
        const Model = MediaModel.CreateRating;

        const request = Model.Request{
            .user_id = ctx.user_id.?,
            .media_id = req.params.id,
            .rating_score = if (req.body.rating_score <= 10) req.body.rating_score else {
                handleResponse(res, .bad_request, "Rating score must be in the range [0,10]");
                return;
            },
        };

        const response = Model.call(allocator, ctx.database_pool, request) catch |err| {
            log.err("Create Rating Model failed! {}", .{err});
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

const GetRating = Endpoint(struct {
    const Params = struct {
        id: []const u8,
    };

    const Response = struct {
        id: []const u8,
        rating_score: u8,
        created_at: i64,
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
        .path = "/api/media/:id/rating",
    };

    pub fn call(ctx: *Handler.RequestContext, req: EndpointRequest(void, Params, void), res: *httpz.Response) anyerror!void {
        const allocator = res.arena;
        const Model = MediaModel.GetRating;

        const request = Model.Request{
            .user_id = ctx.user_id.?,
            .media_id = req.params.id,
        };

        const response = Model.call(allocator, ctx.database_pool, request) catch |err| {
            log.err("Get Rating Model failed! {}", .{err});
            handleResponse(res, .internal_server_error, null);
            return;
        };
        defer response.deinit(allocator);

        res.status = 200;
        try res.json(Response{
            .id = response.id,
            .rating_score = response.rating_score,
            .created_at = response.created_at,
        }, .{});
    }
});

const EditRating = Endpoint(struct {
    const Body = struct {
        /// [0,10]
        rating_score: u8,
    };
    const Params = struct {
        rating_id: []const u8,
    };

    const Response = struct {
        id: []const u8,
        rating_score: u8,
        created_at: i64,
    };

    pub const endpoint_data: EndpointData = .{
        .Request = .{
            .Body = Body,
            .Params = Params,
        },
        .Response = Response,
        .method = .PATCH,
        .route_data = .{
            .restricted = true,
        },
        .path = "/api/media/rating/:rating_id",
    };

    pub fn call(ctx: *Handler.RequestContext, req: EndpointRequest(Body, Params, void), res: *httpz.Response) anyerror!void {
        const allocator = res.arena;
        const Model = MediaModel.EditRating;

        const request = Model.Request{
            .user_id = ctx.user_id.?,
            .rating_id = req.params.rating_id,
            .rating_score = req.body.rating_score,
        };

        const response = Model.call(allocator, ctx.database_pool, request) catch |err| {
            log.err("Edit Rating Model failed! {}", .{err});
            handleResponse(res, .internal_server_error, null);
            return;
        };
        defer response.deinit(allocator);

        res.status = 200;
        try res.json(Response{
            .id = response.id,
            .rating_score = response.rating_score,
            .created_at = response.created_at,
        }, .{});
    }
});

const CreateProgress = Endpoint(struct {
    const Body = struct {
        status: MediaModel.ProgressStatus,
        progress_value: i32,
    };

    const Params = struct {
        media_id: []const u8,
    };

    const Response = struct {
        id: []const u8,
        user_id: []const u8,
        media_id: []const u8,
        status: MediaModel.ProgressStatus,
        progress_value: i32,
        updated_at: i64,
    };

    pub const endpoint_data: EndpointData = .{
        .Request = .{
            .Body = Body,
            .Params = Params,
        },
        .Response = Response,
        .method = .POST,
        .route_data = .{
            .restricted = true,
        },
        .path = "/api/media/:media_id/progress",
    };

    pub fn call(ctx: *Handler.RequestContext, req: EndpointRequest(Body, Params, void), res: *httpz.Response) anyerror!void {
        const allocator = res.arena;
        const Model = MediaModel.CreateProgress;

        const request = Model.Request{
            .user_id = ctx.user_id.?,
            .media_id = req.params.media_id,
            .status = req.body.status,
            .progress_value = req.body.progress_value,
        };

        const response = Model.call(allocator, ctx.database_pool, request) catch |err| {
            log.err("Create Progress Model failed! {}", .{err});
            handleResponse(res, .internal_server_error, null);
            return;
        };

        res.status = 200;
        try res.json(Response{
            .id = response.id,
            .user_id = response.user_id,
            .media_id = response.media_id,
            .status = response.status,
            .progress_value = response.progress_value,
            .updated_at = response.created_at,
        }, .{});
    }
});

const GetProgress = Endpoint(struct {
    const Params = struct {
        id: []const u8,
    };

    const Response = struct {
        user_id: []const u8,
        media_id: []const u8,
        status: []const u8,
        progress_value: i32,
        updated_at: i64,
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
        .path = "/api/media/:id/progress",
    };

    pub fn call(ctx: *Handler.RequestContext, req: EndpointRequest(void, Params, void), res: *httpz.Response) anyerror!void {
        const allocator = res.arena;
        const Model = MediaModel.GetProgress;

        const request = Model.Request{
            .user_id = ctx.user_id.?,
            .media_id = req.params.id,
        };

        const response = Model.call(allocator, ctx.database_pool, request) catch |err| {
            log.err("Get Progress Model failed! {}", .{err});
            handleResponse(res, .internal_server_error, null);
            return;
        };
        defer response.deinit(allocator);

        res.status = 200;
        try res.json(Response{
            .user_id = response.user_id,
            .media_id = response.media_id,
            .status = response.status,
            .progress_value = response.progress_value,
            .updated_at = response.updated_at,
        }, .{});
    }
});

const MediaModel = @import("../../../../models/content/content.zig").Media;

const Endpoint = @import("../../../../endpoint.zig").Endpoint;
const EndpointRequest = @import("../../../../endpoint.zig").EndpointRequest;
const EndpointData = @import("../../../../endpoint.zig").EndpointData;
const EndpointGroup = @import("../../../../endpoint.zig").EndpointGroup;
const handleResponse = @import("../../../../endpoint.zig").handleResponse;

const Handler = @import("../../../../handler.zig");
const httpz = @import("httpz");

const std = @import("std");
