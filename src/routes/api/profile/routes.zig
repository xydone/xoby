const log = std.log.scoped(.profile_route);

const Endpoints = EndpointGroup(.{
    List.Endpoints,
    Ratings.Endpoints,
    Progress.Endpoints,
    ImportLetterboxdWatchlist,
});

pub const endpoint_data = Endpoints.endpoint_data;
pub const init = Endpoints.init;

const ImportLetterboxdWatchlist = Endpoint(struct {
    const Response = LetterboxdImporter.Import.Response;
    pub const endpoint_data: EndpointData = .{
        .Request = .{},
        .Response = Response,
        .method = .POST,
        .route_data = .{
            .signed_in = true,
            .is_multipart = true,
        },
        .path = "/api/profile/import/letterboxd",
    };

    pub fn call(ctx: *Handler.RequestContext, req: EndpointRequest(void, void, void), res: *httpz.Response) anyerror!void {
        const allocator = res.arena;

        const file = blk: {
            const value = req.multipart.?.get("zip") orelse {
                handleResponse(res, .bad_request, "Missing \"zip\" in multipart list.");
                return;
            };
            break :blk value.value;
        };

        // NOTE: not deinitializing due to scope
        const response = try LetterboxdImporter.Import.call(
            allocator,
            ctx.database_pool,
            ctx.user_id.?,
            file,
        );

        res.status = 200;
        try res.json(response, .{});
    }
});

const List = @import("list/routes.zig");
const Progress = @import("progress/routes.zig");
const Ratings = @import("ratings/routes.zig");

const LetterboxdImporter = @import("../../../importers/importer.zig").Letterboxd;

const ProgressStatus = @import("../../../models/content/content.zig").Media.ProgressStatus;
const ProfileModel = @import("../../../models/profiles/profiles.zig");

const Endpoint = @import("../../../endpoint.zig").Endpoint;
const EndpointRequest = @import("../../../endpoint.zig").EndpointRequest;
const EndpointData = @import("../../../endpoint.zig").EndpointData;
const EndpointGroup = @import("../../../endpoint.zig").EndpointGroup;
const handleResponse = @import("../../../endpoint.zig").handleResponse;

const Handler = @import("../../../handler.zig");
const httpz = @import("httpz");

const std = @import("std");
