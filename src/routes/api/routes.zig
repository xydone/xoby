pub inline fn init(router: *Handler.Router) void {
    _ = router;
}

const Handler = @import("../../handler.zig");
const httpz = @import("httpz");
