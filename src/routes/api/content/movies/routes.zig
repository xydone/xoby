pub inline fn init(router: *Handler.Router) void {
    Create.init(router);
}

const Create = Endpoint(struct {
    pub const endpoint_data: EndpointData = .{
        .Request = .{},
        .Response = struct {},
        .method = .POST,
        .route_data = .{},
        .path = "/api/movies/",
    };

    pub fn call(ctx: *Handler.RequestContext, req: EndpointRequest(void, void, void), res: *httpz.Response) anyerror!void {
        _ = ctx;
        _ = req;
        _ = res;
    }
});

const Endpoint = @import("../../../../endpoint.zig").Endpoint;
const EndpointRequest = @import("../../../../endpoint.zig").EndpointRequest;
const EndpointData = @import("../../../../endpoint.zig").EndpointData;
const handleResponse = @import("../../../../endpoint.zig").handleResponse;

const Handler = @import("../../../../handler.zig");
const httpz = @import("httpz");
