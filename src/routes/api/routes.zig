pub inline fn init(router: *Handler.Router) void {
    Auth.init(router);
    Content.init(router);
    Profile.init(router);
    System.init(router);
}

const Auth = @import("auth/routes.zig");
const Content = @import("content/routes.zig");
const Profile = @import("profile/routes.zig");
const System = @import("system/routes.zig");

const Handler = @import("../../handler.zig");
const httpz = @import("httpz");
