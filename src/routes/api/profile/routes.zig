const log = std.log.scoped(.profile_route);

const Endpoints = EndpointGroup(.{
    CreateList,
    ChangeList,
    GetList,
    GetLists,
    GetAllProgress,
    GetRatings,
    ImportLetterboxdWatchlist,
});

pub const endpoint_data = Endpoints.endpoint_data;
pub const init = Endpoints.init;

const CreateList = Endpoint(struct {
    const Body = struct {
        name: []const u8,
        is_public: bool,
    };

    const Response = struct {
        id: []const u8,
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
        .path = "/api/profile/list",
    };

    pub fn call(ctx: *Handler.RequestContext, req: EndpointRequest(Body, void, void), res: *httpz.Response) anyerror!void {
        const allocator = res.arena;
        const Model = ProfileModel.CreateList;

        const request = Model.Request{
            .user_id = ctx.user_id.?,
            .name = req.body.name,
            .is_public = req.body.is_public,
        };

        const response = Model.call(allocator, ctx.database_pool, request) catch |err| {
            log.err("Create List Model failed! {}", .{err});
            handleResponse(res, .internal_server_error, null);
            return;
        };
        defer response.deinit(allocator);

        res.status = 200;
        try res.json(Response{
            .id = response.id,
        }, .{});
    }
});

const GetList = Endpoint(struct {
    const Params = struct {
        id: []const u8,
    };

    const Response = struct {
        id: []const u8,
        user_id: []const u8,
        name: []const u8,
        is_public: bool,
        created_at: i64,
        items: []ProfileModel.GetList.Response.Item,
    };

    pub const endpoint_data: EndpointData = .{
        .Request = .{
            .Params = Params,
        },
        .Response = Response,
        .method = .GET,
        .route_data = .{
            .signed_in = true,
        },
        .path = "/api/profile/list/:id",
    };

    pub fn call(ctx: *Handler.RequestContext, req: EndpointRequest(void, Params, void), res: *httpz.Response) anyerror!void {
        const allocator = res.arena;
        const Model = ProfileModel.GetList;

        const request = Model.Request{
            .user_id = ctx.user_id.?,
            .list_id = req.params.id,
        };

        const response = Model.call(allocator, ctx.database_pool, request) catch |err| {
            log.err("Get List Model failed! {}", .{err});
            handleResponse(res, .internal_server_error, null);
            return;
        };
        defer response.deinit(allocator);

        res.status = 200;
        try res.json(Response{
            .id = response.id,
            .user_id = response.user_id,
            .name = response.name,
            .is_public = response.is_public,
            .created_at = response.created_at,
            .items = response.items,
        }, .{});
    }
});

const GetLists = Endpoint(struct {
    const Response = []struct {
        id: []const u8,
        user_id: []const u8,
        name: []const u8,
        is_public: bool,
        created_at: i64,
    };

    pub const endpoint_data: EndpointData = .{
        .Request = .{},
        .Response = Response,
        .method = .GET,
        .route_data = .{
            .signed_in = true,
        },
        .path = "/api/profile/lists",
    };

    pub fn call(ctx: *Handler.RequestContext, _: EndpointRequest(void, void, void), res: *httpz.Response) anyerror!void {
        const allocator = res.arena;
        const Model = ProfileModel.GetLists;

        const request = Model.Request{
            .user_id = ctx.user_id.?,
        };

        const responses = Model.call(allocator, ctx.database_pool, request) catch |err| {
            log.err("Get List Model failed! {}", .{err});
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

const ChangeList = Endpoint(struct {
    const Body = struct {
        name: []const u8,
        is_public: bool,
    };

    const Response = struct {
        id: []const u8,
    };

    pub const endpoint_data: EndpointData = .{
        .Request = .{
            .Body = Body,
        },
        .Response = Response,
        .method = .PATCH,
        .route_data = .{
            .signed_in = true,
        },
        .path = "/api/profile/list",
    };

    pub fn call(ctx: *Handler.RequestContext, req: EndpointRequest(Body, void, void), res: *httpz.Response) anyerror!void {
        const allocator = res.arena;
        const Model = ProfileModel.CreateList;

        const request = Model.Request{
            .user_id = ctx.user_id.?,
            .name = req.body.name,
            .is_public = req.body.is_public,
        };

        const response = Model.call(allocator, ctx.database_pool, request) catch |err| {
            log.err("Change List Model failed! {}", .{err});
            handleResponse(res, .internal_server_error, null);
            return;
        };
        defer response.deinit(allocator);

        res.status = 200;
        try res.json(Response{
            .id = response.id,
        }, .{});
    }
});

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
        const Model = ProfileModel.GetRatings;

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
        const Model = ProfileModel.GetAllProgress;

        const request = Model.Request{
            .user_id = ctx.user_id.?,
        };

        const responses = Model.call(allocator, ctx.database_pool, request) catch |err| {
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

const ImportLetterboxdWatchlist = Endpoint(struct {
    const Params = struct {
        id: []const u8,
    };
    const Response = struct {
        failed_inserts: []LetterboxdImporter.Watchlist.Response,
    };

    pub const endpoint_data: EndpointData = .{
        .Request = .{
            .Params = Params,
        },
        .Response = Response,
        .method = .POST,
        .route_data = .{
            .signed_in = true,
            .is_multipart = true,
        },
        .path = "/api/profile/list/:id/import/letterboxd",
    };

    pub fn call(ctx: *Handler.RequestContext, req: EndpointRequest(void, Params, void), res: *httpz.Response) anyerror!void {
        const allocator = res.arena;

        const list = blk: {
            const value = req.multipart.?.get("list") orelse {
                handleResponse(res, .bad_request, "Missing \"list\" in multipart list.");
                return;
            };
            break :blk value.value;
        };

        const failed_inserts = try LetterboxdImporter.Watchlist.import(
            allocator,
            ctx.database_pool,
            ctx.user_id.?,
            list,
            req.params.id,
        );

        const response: Response = .{
            .failed_inserts = failed_inserts,
        };

        res.status = 200;
        try res.json(response, .{});
    }
});

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
