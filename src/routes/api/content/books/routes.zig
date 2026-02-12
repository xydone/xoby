const log = std.log.scoped(.book_route);

const Endpoints = EndpointGroup(.{
    Create,
});

pub const endpoint_data = Endpoints.endpoint_data;
pub const init = Endpoints.init;

const Create = Endpoint(struct {
    const Body = struct {
        title: []const u8,
        release_date: ?[]const u8 = null,
        total_pages: ?i32 = null,
        publisher: ?[]const u8 = null,
        description: ?[]const u8 = null,
    };

    const Response = struct {
        id: []const u8,
        title: []const u8,
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
        .path = "/api/books/",
    };

    pub fn call(ctx: *Handler.RequestContext, req: EndpointRequest(Body, void, void), res: *httpz.Response) anyerror!void {
        const allocator = res.arena;
        const Model = BookModel.Create;

        const request: Model.Request = .{
            .title = req.body.title,
            .user_id = ctx.user_id.?,
            .release_date = req.body.release_date,
            .total_pages = req.body.total_pages,
            .description = req.body.description,
        };

        const response = Model.call(allocator, .{ .database = ctx.database_pool }, request) catch |err| {
            log.err("Create Book Model failed! {}", .{err});
            handleResponse(res, .internal_server_error, null);
            return;
        };
        defer response.deinit(allocator);

        res.status = 200;
        try res.json(Response{
            .id = response.id,
            .title = response.title,
        }, .{});
    }
});

const BookModel = @import("../../../../models/content/content.zig").Books;

const Endpoint = @import("../../../../endpoint.zig").Endpoint;
const EndpointRequest = @import("../../../../endpoint.zig").EndpointRequest;
const EndpointData = @import("../../../../endpoint.zig").EndpointData;
const EndpointGroup = @import("../../../../endpoint.zig").EndpointGroup;
const handleResponse = @import("../../../../endpoint.zig").handleResponse;

const Handler = @import("../../../../handler.zig");
const httpz = @import("httpz");

const std = @import("std");
