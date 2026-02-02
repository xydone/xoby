const std = @import("std");

const NAME = "xoby";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .sanitize_c = .full,
        .sanitize_thread = true,
    });

    const openapi_module = b.createModule(.{
        .root_source_file = b.path("src/openapi.zig"),
        .target = target,
        .optimize = optimize,
    });

    const httpz = b.dependency("httpz", .{
        .target = target,
        .optimize = optimize,
    });
    module.addImport("httpz", httpz.module("httpz"));
    openapi_module.addImport("httpz", httpz.module("httpz"));

    const zdt = b.dependency("zdt", .{
        .target = target,
        .optimize = optimize,
    });
    module.addImport("zdt", zdt.module("zdt"));
    openapi_module.addImport("zdt", zdt.module("zdt"));

    const pg = b.dependency("pg", .{
        .target = target,
        .optimize = optimize,
    });
    module.addImport("pg", pg.module("pg"));
    openapi_module.addImport("pg", pg.module("pg"));

    const jwt = b.dependency("jwt", .{
        .target = target,
        .optimize = optimize,
    });
    module.addImport("jwt", jwt.module("jwt"));
    openapi_module.addImport("jwt", jwt.module("jwt"));

    const dep_curl = b.dependency("curl", .{
        .target = target,
        .optimize = optimize,
        .mbedtls_pthreads = true,
    });
    module.addImport("curl", dep_curl.module("curl"));
    openapi_module.addImport("curl", dep_curl.module("curl"));

    const zimdjson = b.dependency("zimdjson", .{});
    module.addImport("zimdjson", zimdjson.module("zimdjson"));
    openapi_module.addImport("zimdjson", zimdjson.module("zimdjson"));

    const bzip_dependency = b.dependency("libzip", .{
        .target = target,
        .optimize = optimize,
    });
    module.linkLibrary(bzip_dependency.artifact("zip"));
    openapi_module.linkLibrary(bzip_dependency.artifact("zip"));

    const exe = b.addExecutable(.{
        .name = NAME,
        .root_module = module,
    });

    const exe_openapi = b.addExecutable(.{
        .name = NAME ++ "_openapi",
        .root_module = openapi_module,
    });

    const run_openapi = b.addRunArtifact(exe_openapi);
    const openapi_run_step = b.step("openapi", "Run OpenAPI generator");
    openapi_run_step.dependOn(&run_openapi.step);

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    const exe_tests = b.addTest(.{
        .root_module = module,
        .test_runner = .{
            .path = b.path("src/tests/test_runner.zig"),
            .mode = .simple,
        },
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    if (b.args) |args| {
        run_cmd.addArgs(args);
        run_exe_tests.addArgs(args);
    }

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);

    const exe_check = b.addExecutable(.{
        .name = NAME,
        .root_module = module,
    });
    const check = b.step("check", "Check if " ++ NAME ++ " compiles");
    check.dependOn(&exe_check.step);
    check.dependOn(&exe_tests.step);
    check.dependOn(&exe_openapi.step);
}
