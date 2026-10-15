const std = @import("std");

fn readInterfaceSource(b: *std.Build, filename: []const u8) []u8 {
    // NOTE(Zig 0.17): `std.fs.cwd().readFileAlloc` + `b.pathFromRoot` were
    // removed. Resolve against the build root and read via `std.Io.Dir`.
    const io = b.graph.io;
    const root_path = b.root.root_dir.path orelse ".";
    const abs_path = std.fs.path.join(b.allocator, &.{ root_path, filename }) catch @panic("OOM");
    var file = std.Io.Dir.openFileAbsolute(io, abs_path, .{}) catch @panic("unable to read sa_http_server.sai");
    defer file.close(io);
    var buf: [128]u8 = undefined;
    var reader = file.reader(io, &buf);
    return reader.interface.allocRemaining(b.allocator, .limited(1024 * 1024)) catch @panic("unable to read sa_http_server.sai");
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sci_root = b.option([]const u8, "sci-root", "Path to the sci checkout") orelse "../sci";
    const interface_source = readInterfaceSource(b, "sa_http_server.sai");
    const interface_options = b.addOptions();
    interface_options.addOption([]const u8, "source", interface_source);
    const sa_net_primitives = b.createModule(.{
        .root_source_file = b.path(b.pathJoin(&.{ sci_root, "src", "runtime", "sa_net_primitives.zig" })),
        .target = target,
        .optimize = optimize,
    });
    const sio_module = b.createModule(.{
        .root_source_file = b.path(b.pathJoin(&.{ sci_root, "src", "sa_io.zig" })),
        .target = target,
        .optimize = optimize,
    });
    const plugin_api = b.createModule(.{
        .root_source_file = b.path("src/plugin_api.zig"),
        .target = target,
        .optimize = optimize,
    });
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/plugin.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    root_module.addImport("plugin_api", plugin_api);
    root_module.addImport("sa_net_primitives", sa_net_primitives);
    root_module.addImport("sio", sio_module);
    root_module.addOptions("http_server_interface", interface_options);
    const lib = b.addLibrary(.{
        .name = "http-server",
        .root_module = root_module,
        .linkage = .dynamic,
    });
    b.installArtifact(lib);

    const test_module = b.createModule(.{
        .root_source_file = b.path("tests/plugin_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_module.addImport("plugin", root_module);
    test_module.addImport("plugin_api", plugin_api);
    test_module.addImport("sio", sio_module);
    const tests = b.addTest(.{
        .root_module = test_module,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run plugin tests");
    test_step.dependOn(&run_tests.step);
}
