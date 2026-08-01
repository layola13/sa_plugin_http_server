const std = @import("std");
const plugin_api = @import("plugin_api");
const plugin_helpers = @import("plugin_helpers.zig");
const http_server_interface = @import("http_server_interface");
pub usingnamespace @import("http_saasm_api.zig");

pub const interface_source = http_server_interface.source;

const skills = [_]plugin_api.SkillSection{
    .{
        .name = "http server plugin",
        .summary = "HubProxy and HTTP server scaffolding",
        .items = &.{
            "http-server scaffold <dir>",
            "http-server serve <host> <port>",
            "reads request headers and bodies",
            "streams chunked responses for SSE-style routes",
            "generates a concrete HubProxy starter project",
            "emits a concrete sa_http_server.sai interface",
        },
    },
};

pub fn ensureDir(path: []const u8) !void {
    if (path.len != 0) try std.fs.cwd().makePath(path);
}

pub fn writeFile(path: []const u8, bytes: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| try ensureDir(dir);
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(bytes);
}

pub fn requestPath(target: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, target, '?')) |idx| return target[0..idx];
    return target;
}

pub fn headerValue(request: *std.http.Server.Request, name: []const u8) ?[]const u8 {
    var it = request.iterateHeaders();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    }
    return null;
}

pub fn readRequestBodyAlloc(ctx: *const plugin_api.Context, request: *std.http.Server.Request) ![]u8 {
    var body = std.ArrayList(u8).init(ctx.allocator);
    errdefer body.deinit();
    const reader = try request.reader();
    try reader.readAllArrayList(&body, 2 * 1024 * 1024);
    return body.toOwnedSlice();
}

pub fn respondStreamed(request: *std.http.Server.Request, send_buffer: []u8, chunks: []const []const u8) !void {
    var response = request.respondStreaming(.{
        .send_buffer = send_buffer,
        .respond_options = .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/event-stream" },
            },
            .transfer_encoding = .chunked,
        },
    });
    for (chunks, 0..) |chunk, idx| {
        try response.writeAll(chunk);
        try response.flush();
        if (idx + 1 < chunks.len) std.time.sleep(10 * std.time.ns_per_ms);
    }
    try response.endChunked(.{});
}

pub fn handleRoute(
    ctx: *const plugin_api.Context,
    request: *std.http.Server.Request,
    stdout: std.io.AnyWriter,
    stderr: std.io.AnyWriter,
) !void {
    const path = requestPath(request.head.target);
    const content_type = headerValue(request, "content-type") orelse "";

    if (std.mem.eql(u8, path, "/echo")) {
        const body = try readRequestBodyAlloc(ctx, request);
        defer ctx.allocator.free(body);
        try request.respond(body, .{
            .status = .ok,
            .extra_headers = if (content_type.len == 0) &.{} else &.{.{ .name = "content-type", .value = content_type }},
        });
        try stdout.print("route=echo path={s} body={d}\n", .{ path, body.len });
        return;
    }

    if (std.mem.eql(u8, path, "/stream")) {
        var send_buffer: [2048]u8 = undefined;
        try respondStreamed(request, &send_buffer, &.{
            "data: first\n\n",
            "data: second\n\n",
        });
        try stdout.print("route=stream path={s}\n", .{path});
        return;
    }

    const not_found = "not found\n";
    try request.respond(not_found, .{
        .status = .not_found,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/plain" },
        },
    });
    try stderr.print("error: unknown route {s}\n", .{path});
}

pub fn runServeCommand(ctx: *const plugin_api.Context, argv: []const []const u8, stdout: std.io.AnyWriter, stderr: std.io.AnyWriter) anyerror!?u8 {
    if (argv.len < 2) return null;
    if (!std.mem.eql(u8, argv[1], "http-server")) return null;
    if (argv.len < 5) return error.MissingSourcePath;

    const sub = argv[2];
    if (!std.mem.eql(u8, sub, "serve")) return error.UnknownCommand;

    const host = argv[3];
    const port = std.fmt.parseInt(u16, argv[4], 10) catch return error.InvalidPath;
    var max_requests: ?usize = null;
    if (argv.len >= 6) {
        max_requests = std.fmt.parseInt(usize, argv[5], 10) catch return error.InvalidPath;
    }
    const address = std.net.Address.parseIp(host, port) catch return error.InvalidPath;
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();

    var served: usize = 0;
    while (max_requests == null or served < max_requests.?) {
        var accepted = try server.accept();
        defer accepted.stream.close();

        var request_buffer: [4096]u8 = undefined;
        var http_server = std.http.Server.init(accepted, &request_buffer);
        var request = http_server.receiveHead() catch |err| {
            try stderr.print("error: receive head failed: {}\n", .{err});
            return 1;
        };

        handleRoute(ctx, &request, stdout, stderr) catch |err| {
            try stderr.print("error: request handling failed: {}\n", .{err});
            return 1;
        };
        served += 1;
    }
    return 0;
}

pub fn runHttpServerCommand(ctx: *const plugin_api.Context, argv: []const []const u8, stdout: std.io.AnyWriter, stderr: std.io.AnyWriter) anyerror!?u8 {
    if (argv.len < 2) return null;
    if (!std.mem.eql(u8, argv[1], "http-server")) return null;
    if (argv.len < 3) return error.MissingSourcePath;

    const sub = argv[2];
    if (std.mem.eql(u8, sub, "serve")) {
        if (argv.len < 5) return error.MissingSourcePath;
        return try runServeCommand(ctx, argv, stdout, stderr);
    }
    if (!std.mem.eql(u8, sub, "scaffold")) return error.UnknownCommand;
    if (argv.len < 4) return error.MissingSourcePath;

    const root = argv[3];
    const iface_path = try std.fs.path.join(ctx.allocator, &.{ root, "sa_http_server.sai" });
    defer ctx.allocator.free(iface_path);
    const main_path = try std.fs.path.join(ctx.allocator, &.{ root, "main.sa" });
    defer ctx.allocator.free(main_path);
    const readme_path = try std.fs.path.join(ctx.allocator, &.{ root, "README.md" });
    defer ctx.allocator.free(readme_path);

    try writeFile(iface_path, interface_source);

    try writeFile(main_path,
        \\@export hubproxy_main():
        \\L_ENTRY:
        \\  panic(102)
    );

    try writeFile(readme_path,
        \\# HubProxy scaffold
        \\
        \\Generated by `sa http-server scaffold`.
        \\Fill in the HTTP handlers and wire them to `sa_http_server`.
        \\
        \\The `http-server serve` command is a minimal runtime smoke test for the plugin.
    );

    try stdout.print("{s}\n", .{root});
    return 0;
}

fn isHttpServerCliError(err: anyerror) bool {
    return switch (err) {
        error.MissingSourcePath,
        error.UnknownCommand,
        error.InvalidPath,
        error.FileNotFound,
        error.NotDir,
        error.AccessDenied,
        => true,
        else => false,
    };
}

fn httpServerCliHint(argv: []const []const u8, err: anyerror) []const u8 {
    const sub = if (argv.len >= 3) argv[2] else "";
    return switch (err) {
        error.MissingSourcePath => if (sub.len == 0)
            "usage: sa http-server <scaffold|serve> ..."
        else if (std.mem.eql(u8, sub, "scaffold"))
            "usage: sa http-server scaffold <dir>"
        else if (std.mem.eql(u8, sub, "serve"))
            "usage: sa http-server serve <host> <port> [max-requests]"
        else
            "usage: sa http-server <scaffold|serve> ...",
        error.UnknownCommand => "supported HTTP server subcommands are scaffold and serve",
        error.InvalidPath => "check the scaffold path, host address, port, or max request count",
        error.FileNotFound, error.NotDir => "check that the scaffold parent path exists and is a directory",
        error.AccessDenied => "check filesystem permissions for the scaffold path or listen address",
        else => "check HTTP server command arguments",
    };
}

fn writeHttpServerCliError(writer: std.io.AnyWriter, argv: []const []const u8, err: anyerror) !void {
    const message = switch (err) {
        error.MissingSourcePath => "missing required HTTP server operand",
        error.UnknownCommand => "unknown HTTP server subcommand",
        error.InvalidPath => "invalid HTTP server path or address",
        error.FileNotFound => "HTTP server file or directory not found",
        error.NotDir => "HTTP server path is not a directory",
        error.AccessDenied => "HTTP server path or address access denied",
        else => @errorName(err),
    };
    try writer.print("error[SA-HTTP-SERVER-CLI]: {s}\n", .{message});
    try writer.print("  help: {s}\n", .{httpServerCliHint(argv, err)});
}

pub fn runHttpServerCommandAbi(ctx: *const plugin_api.Context, argv: [*]const [*:0]const u8, argv_len: usize, stdout: plugin_api.HostStream, stderr: plugin_api.HostStream, out_code: *u8) callconv(.c) u32 {
    out_code.* = 0;
    if (argv_len < 2) return @intFromEnum(plugin_api.AbiStatus.unknown_command);
    if (!std.mem.eql(u8, std.mem.span(argv[1]), "http-server")) return @intFromEnum(plugin_api.AbiStatus.unknown_command);

    const args = plugin_helpers.cArgvToSlice(argv, argv_len, ctx.allocator) catch return @intFromEnum(plugin_api.AbiStatus.failed);
    defer ctx.allocator.free(args);
    var stdout_ctx: plugin_helpers.StreamWriterCtx = undefined;
    var stderr_ctx: plugin_helpers.StreamWriterCtx = undefined;
    const stdout_writer = plugin_helpers.makeAnyWriter(stdout, &stdout_ctx) orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const stderr_writer = plugin_helpers.makeAnyWriter(stderr, &stderr_ctx) orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const result = runHttpServerCommand(ctx, args, stdout_writer, stderr_writer) catch |err| {
        if (!isHttpServerCliError(err)) return @intFromEnum(plugin_api.AbiStatus.failed);
        writeHttpServerCliError(stderr_writer, args, err) catch return @intFromEnum(plugin_api.AbiStatus.failed);
        out_code.* = 1;
        return @intFromEnum(plugin_api.AbiStatus.ok);
    };
    if (result) |code| {
        out_code.* = code;
        return @intFromEnum(plugin_api.AbiStatus.ok);
    }
    return @intFromEnum(plugin_api.AbiStatus.unknown_command);
}

pub const plugin = plugin_api.Plugin{
    .name = "http-server",
    .handleCommand = runHttpServerCommand,
    .skills = &skills,
};

const descriptor = plugin_api.PluginDescriptor{
    .abi_version = plugin_api.abi_version,
    .descriptor_size = @as(u32, @intCast(@sizeOf(plugin_api.PluginDescriptor))),
    .name = "http-server",
    .init = null,
    .prebuild = null,
    .postbuild = null,
    .handle_command = runHttpServerCommandAbi,
    .skills_ptr = skills[0..].ptr,
    .skills_len = skills.len,
};

pub export const saasm_plugin_descriptor_v1: plugin_api.PluginDescriptor = descriptor;

pub export fn saasm_plugin_descriptor_v1_fn(out: *plugin_api.PluginDescriptor) callconv(.c) void {
    out.* = descriptor;
}
