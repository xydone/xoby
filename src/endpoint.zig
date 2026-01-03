pub const EndpointRequestType = struct {
    Body: type = void,
    Params: type = void,
    Query: type = void,
};

pub fn EndpointRequest(comptime Body: type, comptime Params: type, comptime Query: type) type {
    return struct {
        body: Body,
        params: Params,
        query: Query,
    };
}

pub const EndpointData = struct {
    Request: EndpointRequestType,
    Response: type,
    path: []const u8,
    method: httpz.Method,
    route_data: RouteData,
};

pub fn Endpoint(
    comptime T: type,
) type {
    return struct {
        pub const endpoint_data: EndpointData = T.endpoint_data;
        const callImpl: fn (
            *Handler.RequestContext,
            EndpointRequest(T.endpoint_data.Request.Body, T.endpoint_data.Request.Params, T.endpoint_data.Request.Query),
            *httpz.Response,
        ) anyerror!void = T.call;

        pub fn init(router: *Router) void {
            const path = T.endpoint_data.path;
            const route_data = T.endpoint_data.route_data;
            switch (T.endpoint_data.method) {
                .GET => {
                    router.*.get(path, call, .{ .data = &route_data });
                },
                .POST => {
                    router.*.post(path, call, .{ .data = &route_data });
                },
                .PATCH => {
                    router.*.patch(path, call, .{ .data = &route_data });
                },
                .PUT => {
                    router.*.put(path, call, .{ .data = &route_data });
                },
                .OPTIONS => {
                    router.*.options(path, call, .{ .data = &route_data });
                },
                .CONNECT => {
                    router.*.connect(path, call, .{ .data = &route_data });
                },
                .DELETE => {
                    router.*.delete(path, call, .{ .data = &route_data });
                },
                .HEAD => {
                    router.*.head(path, call, .{ .data = &route_data });
                },
                // NOTE: http.zig supports non-standard http methods. For now, creating routes with a non-standard method is not supported.
                .OTHER => {
                    @compileError("Method OTHER is not supported!");
                },
            }
        }

        pub fn call(ctx: *Handler.RequestContext, req: *httpz.Request, res: *httpz.Response) !void {
            const allocator = res.arena;
            const request: EndpointRequest(T.endpoint_data.Request.Body, T.endpoint_data.Request.Params, T.endpoint_data.Request.Query) = .{
                .body = blk: {
                    switch (@typeInfo(T.endpoint_data.Request.Body)) {
                        .void => break :blk {},
                        else => {
                            const body = req.body() orelse {
                                handleResponse(res, ResponseError.body_missing, null);
                                return;
                            };
                            break :blk std.json.parseFromSliceLeaky(T.endpoint_data.Request.Body, allocator, body, .{}) catch {
                                handleResponse(res, ResponseError.not_found, null);
                                return;
                            };
                        },
                    }
                },

                .params = blk: {
                    switch (@typeInfo(T.endpoint_data.Request.Params)) {
                        .void => {},
                        else => |type_info| {
                            var params: T.endpoint_data.Request.Params = undefined;
                            inline for (type_info.@"struct".fields) |field| {
                                const value = req.param(field.name) orelse {
                                    const msg = try std.fmt.allocPrint(allocator, "{s} not found inside parameters!", .{field.name});
                                    defer allocator.free(msg);
                                    return handleResponse(res, ResponseError.bad_request, msg);
                                };
                                switch (field.type) {
                                    u16, u32, u64, i16, i32, i64 => |t| @field(params, field.name) = try std.fmt.parseInt(t, value, 10),
                                    f16, f32, f64 => |t| @field(params, field.name) = try std.fmt.parseFloat(t, value),
                                    []const u8 => @field(params, field.name) = value,
                                    else => |t| {
                                        switch (@typeInfo(t)) {
                                            .@"enum" => @field(params, field.name) = std.meta.stringToEnum(t, value) orelse {
                                                const enum_name = enum_blk: {
                                                    const name = @typeName(t);
                                                    // filter out the namespace that gets included inside the @typeInfo() response
                                                    // exit early if type does not have a namespace
                                                    const i = std.mem.lastIndexOfScalar(u8, name, '.') orelse break :enum_blk name;
                                                    break :enum_blk name[i + 1 ..];
                                                };
                                                const msg = try std.fmt.allocPrint(allocator, "Incorrect value '{s}' for enum {s}", .{ value, enum_name });
                                                defer allocator.free(msg);
                                                return handleResponse(res, ResponseError.bad_request, msg);
                                            },
                                            else => @compileError(std.fmt.comptimePrint("{} not supported!", .{t})),
                                        }
                                    },
                                }
                            }
                            break :blk params;
                        },
                    }
                },

                .query = blk: {
                    switch (@typeInfo(T.endpoint_data.Request.Query)) {
                        .void => {},
                        else => |type_info| {
                            var query: T.endpoint_data.Request.Query = undefined;
                            inline for (type_info.@"struct".fields) |field| {
                                var q = try req.query();
                                const value = q.get(field.name) orelse {
                                    const msg = try std.fmt.allocPrint(allocator, "{s} not found inside query!", .{field.name});
                                    defer allocator.free(msg);
                                    return handleResponse(res, ResponseError.bad_request, msg);
                                };
                                switch (field.type) {
                                    u16, u32, u64, i16, i32, i64 => |t| @field(query, field.name) = try std.fmt.parseInt(t, value, 10),
                                    f16, f32, f64 => |t| @field(query, field.name) = try std.fmt.parseFloat(t, value),
                                    []const u8, []u8 => @field(query, field.name) = value,
                                    else => |t| {
                                        switch (@typeInfo(t)) {
                                            .@"enum" => @field(query, field.name) = std.meta.stringToEnum(t, value) orelse {
                                                const enum_name = enum_blk: {
                                                    const name = @typeName(t);
                                                    // filter out the namespace that gets included inside the @typeInfo() response
                                                    // exit early if type does not have a namespace
                                                    const i = std.mem.lastIndexOfScalar(u8, name, '.') orelse break :enum_blk name;
                                                    break :enum_blk name[i + 1 ..];
                                                };
                                                const msg = try std.fmt.allocPrint(allocator, "Incorrect value '{s}' for enum {s}", .{ value, enum_name });
                                                defer allocator.free(msg);
                                                return handleResponse(res, ResponseError.bad_request, msg);
                                            },
                                            else => @compileError(std.fmt.comptimePrint("{} not supported!", .{t})),
                                        }
                                    },
                                }
                            }

                            break :blk query;
                        },
                    }
                },
            };

            try callImpl(ctx, request, res);
        }
    };
}

test "Base | Endpoint | Request body" {
    const TestSetup = @import("tests/setup.zig");
    const jsonStringify = @import("util/jsonStringify.zig").jsonStringify;
    const ht = @import("httpz").testing;
    const allocator = std.testing.allocator;

    const ExampleEnum = enum { a, b, c };

    const Body = struct {
        string: []const u8,
        int: i32,
        float: f32,
        @"enum": ExampleEnum,
    };

    const body: Body = .{
        .string = "abcd",
        .int = -3,
        .float = std.math.pi,
        .@"enum" = .a,
    };

    const body_string = try jsonStringify(allocator, body);
    defer allocator.free(body_string);

    const TestEndpoint = Endpoint(struct {
        pub const endpoint_data: EndpointData = .{
            .Request = .{ .Body = Body },
            .Response = undefined,
            .path = undefined,
            .method = undefined,
            .route_data = undefined,
        };
        pub fn call(_: *Handler.RequestContext, req: EndpointRequest(Body, void, void), _: *httpz.Response) !void {
            try std.testing.expectEqualStrings("abcd", req.body.string);
            try std.testing.expectEqual(-3, req.body.int);
            try std.testing.expectEqual(std.math.pi, req.body.float);
            try std.testing.expectEqual(ExampleEnum.a, req.body.@"enum");
        }
    });

    var ctx = try TestSetup.RequestContext.init(undefined, 1);

    {
        var web_test = ht.init(.{});
        defer web_test.deinit();

        web_test.body(body_string);
        try TestEndpoint.call(&ctx, web_test.req, web_test.res);
    }
}

test "Base | Endpoint | Request params" {
    const TestSetup = @import("tests/setup.zig");
    const ht = @import("httpz").testing;
    const allocator = std.testing.allocator;

    const ExampleEnum = enum { a, b, c };

    const Params = struct {
        string: []const u8,
        int: i32,
        float: f32,
        @"enum": ExampleEnum,
    };

    const params: Params = .{
        .string = "abcd",
        .int = -3,
        .float = std.math.pi,
        .@"enum" = .a,
    };

    const TestEndpoint = Endpoint(struct {
        pub const endpoint_data: EndpointData = .{
            .Request = .{ .Params = Params },
            .Response = undefined,
            .path = undefined,
            .method = undefined,
            .route_data = undefined,
        };
        pub fn call(_: *Handler.RequestContext, req: EndpointRequest(void, Params, void), _: *httpz.Response) !void {
            try std.testing.expectEqualStrings("abcd", req.params.string);
            try std.testing.expectEqual(-3, req.params.int);
            try std.testing.expectEqual(std.math.pi, req.params.float);
            try std.testing.expectEqual(ExampleEnum.a, req.params.@"enum");
        }
    });

    var ctx = try TestSetup.RequestContext.init(undefined, 1);

    var value_list = std.ArrayList(struct { name: []const u8, value: []u8 }).empty;
    defer {
        for (value_list.items) |item| {
            allocator.free(item.value);
        }
        value_list.deinit(allocator);
    }
    inline for (@typeInfo(Params).@"struct".fields) |field| {
        const value = try std.fmt.allocPrint(allocator, switch (@typeInfo(field.type)) {
            .pointer => "{s}",
            else => "{}",
        }, .{@field(params, field.name)});
        try value_list.append(allocator, .{ .name = field.name, .value = value });
    }

    {
        var web_test = ht.init(.{});
        defer web_test.deinit();

        for (value_list.items) |entry| {
            web_test.param(entry.name, entry.value);
        }

        try TestEndpoint.call(&ctx, web_test.req, web_test.res);
    }
}

test "Base | Endpoint | Request query" {
    const TestSetup = @import("tests/setup.zig");
    const ht = @import("httpz").testing;
    const allocator = std.testing.allocator;

    const ExampleEnum = enum { a, b, c };

    const Query = struct {
        string: []const u8,
        int: i32,
        float: f32,
        @"enum": ExampleEnum,
    };

    const query: Query = .{
        .string = "abcd",
        .int = -3,
        .float = std.math.pi,
        .@"enum" = .a,
    };

    const TestEndpoint = Endpoint(struct {
        pub const endpoint_data: EndpointData = .{
            .Request = .{ .Query = Query },
            .Response = undefined,
            .path = undefined,
            .method = undefined,
            .route_data = undefined,
        };
        pub fn call(_: *Handler.RequestContext, req: EndpointRequest(void, void, Query), _: *httpz.Response) !void {
            try std.testing.expectEqualStrings("abcd", req.query.string);
            try std.testing.expectEqual(-3, req.query.int);
            try std.testing.expectEqual(std.math.pi, req.query.float);
            try std.testing.expectEqual(ExampleEnum.a, req.query.@"enum");
        }
    });

    var ctx = try TestSetup.RequestContext.init(undefined, 1);

    var value_list = std.ArrayList(struct { name: []const u8, value: []u8 }).empty;
    defer {
        for (value_list.items) |item| {
            allocator.free(item.value);
        }
        value_list.deinit(allocator);
    }
    inline for (@typeInfo(Query).@"struct".fields) |field| {
        const value = try std.fmt.allocPrint(allocator, switch (@typeInfo(field.type)) {
            .pointer => "{s}",
            else => "{}",
        }, .{@field(query, field.name)});
        try value_list.append(allocator, .{ .name = field.name, .value = value });
    }

    {
        var web_test = ht.init(.{});
        defer web_test.deinit();

        for (value_list.items) |entry| {
            web_test.query(entry.name, entry.value);
        }

        try TestEndpoint.call(&ctx, web_test.req, web_test.res);
    }
}

const std = @import("std");

const Handler = @import("handler.zig");
const RouteData = Handler.RouteData;
const Router = Handler.Router;

pub const handleResponse = @import("handler.zig").handleResponse;
const ResponseError = @import("handler.zig").ResponseError;

const httpz = @import("httpz");
