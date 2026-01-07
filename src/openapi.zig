pub fn main() !void {
    // WARNING: this needs to be manually changed if new routes are added
    const endpoint_data = .{
        Auth.endpoint_data,
        Books.endpoint_data,
        Movies.endpoint_data,
        // Media.endpoint_data,
        Profiles.endpoint_data,
    };

    const allocator = std.heap.smp_allocator;
    var path_map = std.StringHashMap(Path).init(allocator);

    inline for (endpoint_data) |endpoints| {
        inline for (endpoints) |endpoint| {
            const formatted_path = try transformPath(allocator, endpoint.path);

            var parameters = std.ArrayList(Path.Operation.Parameter).empty;
            defer parameters.deinit(allocator);

            var schema_map = std.StringHashMap(Schema).init(allocator);

            var request_body: ?Path.Operation.RequestBody = null;

            var required = std.ArrayList([]const u8).empty;
            defer required.deinit(allocator);

            if (@typeInfo(endpoint.Request.Body) == .@"struct") {
                const @"struct" = @typeInfo(endpoint.Request.Body).@"struct";
                inline for (@"struct".fields) |field| {
                    if (@typeInfo(field.type) != .optional) try required.append(allocator, field.name);
                    try schema_map.put(field.name, Schema.init(field.type, allocator));
                }
            }
            if (schema_map.count() != 0) {
                request_body = .{
                    .required = true,
                    .content = .{
                        .@"application/json" = .{
                            .schema = .{
                                .type = .object,
                                .required = if (required.items.len != 0) try required.toOwnedSlice(allocator) else null,
                                .properties = schema_map,
                            },
                        },
                    },
                };
            }

            if (@typeInfo(endpoint.Request.Params) == .@"struct") {
                const @"struct" = @typeInfo(endpoint.Request.Params).@"struct";

                inline for (@"struct".fields) |field| {
                    try parameters.append(allocator, .{
                        .name = field.name,
                        .in = .path,
                        .required = true,
                        .schema = Schema.init(field.type, allocator),
                    });
                }
            }
            if (@typeInfo(endpoint.Request.Query) == .@"struct") {
                const @"struct" = @typeInfo(endpoint.Request.Query).@"struct";

                inline for (@"struct".fields) |field| {
                    try parameters.append(allocator, .{
                        .name = field.name,
                        .in = .query,
                        .required = true,
                        .schema = Schema.init(field.type, allocator),
                    });
                }
            }
            try insertParameter(.{
                .path = formatted_path,
                .method = endpoint.method,
                .params = try parameters.toOwnedSlice(allocator),
                .request_body = request_body,
            }, endpoint.Response, allocator, &path_map);
        }
    }
    const file = try std.fs.cwd().createFile("docs/openapi.json", .{});
    defer file.close();

    const document: OpenAPI = .{
        .openapi = "3.1.0",
        .info = .{
            .title = "Gainz",
            .version = "0.0.0",
        },
        .paths = path_map,
    };
    var writer = std.Io.Writer.Allocating.init(allocator);

    const fmt = std.json.fmt(document, .{});

    try fmt.format(&writer.writer);

    try file.writeAll(writer.written());
}

fn transformPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var new_path_builder = std.ArrayList(u8).empty;

    var it = std.mem.splitScalar(u8, path, '/');

    var is_first_segment = true;

    while (it.next()) |segment| {
        if (!is_first_segment) {
            try new_path_builder.append(allocator, '/');
        }
        is_first_segment = false;

        if (segment.len > 1 and segment[0] == ':') {
            try new_path_builder.print(allocator, "{{{s}}}", .{segment[1..]});
        } else {
            try new_path_builder.appendSlice(allocator, segment);
        }
    }

    return new_path_builder.toOwnedSlice(allocator);
}

fn insertParameter(route_info: struct {
    path: []const u8,
    method: Method,
    params: ?[]Path.Operation.Parameter = null,
    request_body: ?Path.Operation.RequestBody = null,
}, ResponseT: type, allocator: std.mem.Allocator, map: *std.StringHashMap(Path)) !void {
    var responses = std.StringHashMap(Response).init(allocator);

    var schema_map = std.StringHashMap(Schema).init(allocator);

    switch (@typeInfo(ResponseT)) {
        .@"struct" => |@"struct"| {
            inline for (@"struct".fields) |field| {
                try schema_map.put(field.name, Schema.init(field.type, allocator));
            }
        },
        .pointer => |ptr| blk: {
            if (ptr.size != .slice) break :blk;
            inline for (@typeInfo(ptr.child).@"struct".fields) |field| {
                try schema_map.put(field.name, Schema.init(field.type, allocator));
            }
        },
        else => {},
    }

    const schema: Schema = switch (@typeInfo(ResponseT)) {
        .@"struct" => Schema{ .properties = schema_map },
        .pointer => blk: {
            const items = try allocator.create(Schema);
            items.* = Schema{
                .type = .object,
                .properties = schema_map,
            };

            break :blk Schema{ .type = .array, .items = items };
        },
        else => {},
    };

    try responses.put("200", Response{
        .description = "Success",
        .content = .{
            .@"application/json" = .{
                .schema = schema,
            },
        },
    });
    var name_it = std.mem.tokenizeScalar(u8, route_info.path, '/');
    // skip `api/`
    _ = name_it.next();
    const route_name = name_it.next().?;
    const some_path = try allocator.dupe(u8, route_name);

    const tags = try allocator.alloc([]u8, 1);
    tags[0] = some_path;
    const operation = Path.Operation{
        .parameters = if (route_info.params) |p| p else null,
        .requestBody = if (route_info.request_body) |rb| rb else null,
        .responses = responses,
        .tags = tags,
    };
    const gop = try map.getOrPut(route_info.path);
    if (gop.found_existing == true) {
        // setOperation(route_info.method, gop.value_ptr, operation);
        var op = getOperation(route_info.method, gop.value_ptr) orelse Path.Operation{
            .responses = responses,
        };

        op.parameters = if (route_info.params) |p| p else null;
        op.requestBody = if (route_info.request_body) |rb| rb else null;

        setOperation(route_info.method, gop.value_ptr, operation);
    } else {
        gop.value_ptr.* = Path{};

        setOperation(route_info.method, gop.value_ptr, operation);
    }
}

fn getOperation(method: Method, value_ptr: *Path) ?Path.Operation {
    return switch (method) {
        .GET => value_ptr.*.get,
        .HEAD => value_ptr.*.head,
        .POST => value_ptr.*.post,
        .PUT => value_ptr.*.put,
        .PATCH => value_ptr.*.patch,
        .DELETE => value_ptr.*.delete,
        .OPTIONS => value_ptr.*.options,
        .CONNECT => value_ptr.*.connect,
        .OTHER => unreachable,
    };
}

fn setOperation(method: Method, value_ptr: *Path, operation: Path.Operation) void {
    switch (method) {
        .GET => value_ptr.*.get = operation,
        .HEAD => value_ptr.*.head = operation,
        .POST => value_ptr.*.post = operation,
        .PUT => value_ptr.*.put = operation,
        .PATCH => value_ptr.*.patch = operation,
        .DELETE => value_ptr.*.delete = operation,
        .OPTIONS => value_ptr.*.options = operation,
        .CONNECT => value_ptr.*.connect = operation,
        .OTHER => unreachable,
    }
}

const Auth = @import("routes/api/auth/routes.zig");
const Books = @import("routes/api/content/books/routes.zig");
const Movies = @import("routes/api/content/movies/routes.zig");
const Media = @import("routes/api/content/media/routes.zig");
const Profiles = @import("routes/api/profile/routes.zig");

const Method = @import("httpz").Method;

const Path = @import("openapi/path.zig");
const Schema = @import("openapi/schema.zig");
const Response = @import("openapi/response.zig");
const OpenAPI = @import("openapi/openapi.zig");

const std = @import("std");
