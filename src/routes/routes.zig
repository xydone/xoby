pub inline fn init(router: *Handler.Router) void {
    API.init(router);
}

const API = @import("api/routes.zig");

const Handler = @import("../handler.zig");
const httpz = @import("httpz");
