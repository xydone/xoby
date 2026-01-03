pub inline fn init(router: *Handler.Router) void {
    Books.init(router);
    Movies.init(router);
    Media.init(router);
}

const Media = @import("media/routes.zig");
const Books = @import("books/routes.zig");
const Movies = @import("movies/routes.zig");

const Endpoint = @import("../../../endpoint.zig").Endpoint;
const EndpointRequest = @import("../../../endpoint.zig").EndpointRequest;
const EndpointData = @import("../../../endpoint.zig").EndpointData;
const handleResponse = @import("../../../endpoint.zig").handleResponse;

const Handler = @import("../../../handler.zig");
const httpz = @import("httpz");
