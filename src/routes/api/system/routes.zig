pub inline fn init(router: *Handler.Router) void {
    Collectors.init(router);
}

const Collectors = @import("collectors/routes.zig");

const Handler = @import("../../../handler.zig");
const httpz = @import("httpz");
