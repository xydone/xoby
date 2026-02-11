const log = std.log.scoped(.progress_route);

pub const Endpoints = EndpointGroup(.{
    GetAllProgress,
    GetInProgress,
});

pub const endpoint_data = Endpoints.endpoint_data;
pub const init = Endpoints.init;

/// only returns the last 50
const GetAllProgress = Endpoint(struct {
    const Response = []struct {
        id: []const u8,
        user_id: []const u8,
        media_id: []const u8,
        status: ProgressStatus,
        created_at: i64,
    };

    pub const endpoint_data: EndpointData = .{
        .Request = .{},
        .Response = Response,
        .method = .GET,
        .route_data = .{
            .signed_in = true,
        },
        .path = "/api/profile/progress",
    };

    pub fn call(ctx: *Handler.RequestContext, _: EndpointRequest(void, void, void), res: *httpz.Response) anyerror!void {
        const allocator = res.arena;
        const Model = ProfileModel.Progress.GetAll;

        const request = Model.Request{
            .user_id = ctx.user_id.?,
            .limit = 50,
        };

        const responses = Model.call(
            allocator,
            .{ .database = ctx.database_pool },
            request,
        ) catch |err| {
            log.err("Get All Progress Model failed! {}", .{err});
            handleResponse(res, .internal_server_error, null);
            return;
        };

        defer {
            defer allocator.free(responses);
            for (responses) |response| response.deinit(allocator);
        }

        res.status = 200;
        try res.json(responses, .{});
    }
});

const GetInProgress = Endpoint(struct {
    const Response = []Model.Response;

    pub const endpoint_data: EndpointData = .{
        .Request = .{},
        .Response = Response,
        .method = .GET,
        .route_data = .{
            .signed_in = true,
        },
        .path = "/api/profile/progress/in-progress",
    };

    const Model = ProfileModel.Progress.GetAllStatus;
    pub fn call(ctx: *Handler.RequestContext, _: EndpointRequest(void, void, void), res: *httpz.Response) anyerror!void {
        const allocator = res.arena;

        const request = Model.Request{
            .user_id = ctx.user_id.?,
            .status = .in_progress,
        };

        const responses = Model.call(
            allocator,
            .{ .database = ctx.database_pool },
            request,
        ) catch |err| {
            log.err("Get In Progress Progress Model failed! {}", .{err});
            handleResponse(res, .internal_server_error, null);
            return;
        };

        defer {
            defer allocator.free(responses);
            for (responses) |response| response.deinit(allocator);
        }

        res.status = 200;
        try res.json(responses, .{});
    }
});

const ProgressStatus = @import("../../../../models/content/content.zig").Media.ProgressStatus;
const ProfileModel = @import("../../../../models/profiles/profiles.zig");

const Endpoint = @import("../../../../endpoint.zig").Endpoint;
const EndpointRequest = @import("../../../../endpoint.zig").EndpointRequest;
const EndpointData = @import("../../../../endpoint.zig").EndpointData;
const EndpointGroup = @import("../../../../endpoint.zig").EndpointGroup;
const handleResponse = @import("../../../../endpoint.zig").handleResponse;

const Handler = @import("../../../../handler.zig");
const httpz = @import("httpz");

const std = @import("std");
