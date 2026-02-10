const log = std.log.scoped(.ratings_route);

pub const Endpoints = EndpointGroup(.{
    GetRatings,
});

pub const endpoint_data = Endpoints.endpoint_data;
pub const init = Endpoints.init;

const GetRatings = Endpoint(struct {
    const Response = []struct {
        id: []const u8,
        user_id: []const u8,
        media_id: []const u8,
        rating_score: u8,
        created_at: i64,
    };

    pub const endpoint_data: EndpointData = .{
        .Request = .{},
        .Response = Response,
        .method = .GET,
        .route_data = .{
            .signed_in = true,
        },
        .path = "/api/profile/ratings/",
    };

    pub fn call(ctx: *Handler.RequestContext, _: EndpointRequest(void, void, void), res: *httpz.Response) anyerror!void {
        const allocator = res.arena;
        const Model = ProfileModel.Ratings.Get;

        const request = Model.Request{
            .user_id = ctx.user_id.?,
        };

        const responses = Model.call(allocator, ctx.database_pool, request) catch |err| {
            log.err("Get Ratings Model failed! {}", .{err});
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

const ProfileModel = @import("../../../../models/profiles/profiles.zig");

const Endpoint = @import("../../../../endpoint.zig").Endpoint;
const EndpointRequest = @import("../../../../endpoint.zig").EndpointRequest;
const EndpointData = @import("../../../../endpoint.zig").EndpointData;
const EndpointGroup = @import("../../../../endpoint.zig").EndpointGroup;
const handleResponse = @import("../../../../endpoint.zig").handleResponse;

const Handler = @import("../../../../handler.zig");
const httpz = @import("httpz");

const std = @import("std");
