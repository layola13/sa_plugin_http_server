const std = @import("std");
const plugin_api = @import("plugin_api");
const plugin_helpers = @import("plugin_helpers.zig");
const http_server_interface = @import("http_server_interface");
const _http_api = @import("http_saasm_api.zig");
// NOTE(Zig 0.17): `usingnamespace` was removed; explicit re-exports preserve plugin.* ABI.
pub const HttpServer = _http_api.HttpServer;
pub const HttpRequest = _http_api.HttpRequest;
pub const HttpResponse = _http_api.HttpResponse;
pub const HttpStreamResponse = _http_api.HttpStreamResponse;
pub const WebSocketHandle = _http_api.WebSocketHandle;
pub const NetworkStatus = _http_api.NetworkStatus;
pub const PollEvent = _http_api.PollEvent;
pub const max_v2_message_bytes = _http_api.max_v2_message_bytes;
pub const SaHttpServerHandle = _http_api.SaHttpServerHandle;
pub const SaHttpRequestHandle = _http_api.SaHttpRequestHandle;
pub const SaHttpResponseHandle = _http_api.SaHttpResponseHandle;
pub const SaHttpStreamResponseHandle = _http_api.SaHttpStreamResponseHandle;
pub const sa_http_server_new = _http_api.sa_http_server_new;
pub const sa_http_server_start = _http_api.sa_http_server_start;
pub const sa_http_server_accept = _http_api.sa_http_server_accept;
pub const sa_http_server_req_get_method = _http_api.sa_http_server_req_get_method;
pub const sa_http_server_req_get_path = _http_api.sa_http_server_req_get_path;
pub const sa_http_server_req_get_header = _http_api.sa_http_server_req_get_header;
pub const sa_http_server_req_get_body = _http_api.sa_http_server_req_get_body;
pub const sa_http_server_req_free = _http_api.sa_http_server_req_free;
pub const sa_http_server_resp_new = _http_api.sa_http_server_resp_new;
pub const sa_http_server_resp_send = _http_api.sa_http_server_resp_send;
pub const sa_http_server_resp_set_content_type = _http_api.sa_http_server_resp_set_content_type;
pub const sa_http_server_resp_free = _http_api.sa_http_server_resp_free;
pub const sa_http_server_resp_stream_new = _http_api.sa_http_server_resp_stream_new;
pub const sa_http_server_resp_stream_write = _http_api.sa_http_server_resp_stream_write;
pub const sa_http_server_resp_stream_flush = _http_api.sa_http_server_resp_stream_flush;
pub const sa_http_server_resp_stream_end = _http_api.sa_http_server_resp_stream_end;
pub const sa_http_server_resp_stream_free = _http_api.sa_http_server_resp_stream_free;
pub const sa_http_server_free = _http_api.sa_http_server_free;
pub const sa_http_server_set_max_body_bytes = _http_api.sa_http_server_set_max_body_bytes;
pub const sa_http_server_serve_threaded = _http_api.sa_http_server_serve_threaded;
pub const sa_http_server_stop_serving = _http_api.sa_http_server_stop_serving;
pub const sa_http_server_websocket_upgrade = _http_api.sa_http_server_websocket_upgrade;
pub const sa_http_server_websocket_read = _http_api.sa_http_server_websocket_read;
pub const sa_http_server_websocket_write = _http_api.sa_http_server_websocket_write;
pub const sa_http_server_websocket_free = _http_api.sa_http_server_websocket_free;
pub const sa_http_server_new_v2 = _http_api.sa_http_server_new_v2;
pub const sa_http_server_start_v2 = _http_api.sa_http_server_start_v2;
pub const sa_http_server_accept_v2 = _http_api.sa_http_server_accept_v2;
pub const sa_http_server_req_free_v2 = _http_api.sa_http_server_req_free_v2;
pub const sa_http_server_resp_new_v2 = _http_api.sa_http_server_resp_new_v2;
pub const sa_http_server_resp_add_header_v2 = _http_api.sa_http_server_resp_add_header_v2;
pub const sa_http_server_resp_send_v2 = _http_api.sa_http_server_resp_send_v2;
pub const sa_http_server_resp_free_v2 = _http_api.sa_http_server_resp_free_v2;
pub const sa_http_server_resp_stream_new_v2 = _http_api.sa_http_server_resp_stream_new_v2;
pub const sa_http_server_resp_stream_add_header_v2 = _http_api.sa_http_server_resp_stream_add_header_v2;
pub const sa_http_server_resp_stream_write_v2 = _http_api.sa_http_server_resp_stream_write_v2;
pub const sa_http_server_resp_stream_flush_v2 = _http_api.sa_http_server_resp_stream_flush_v2;
pub const sa_http_server_resp_stream_end_v2 = _http_api.sa_http_server_resp_stream_end_v2;
pub const sa_http_server_resp_stream_free_v2 = _http_api.sa_http_server_resp_stream_free_v2;
pub const sa_http_server_free_v2 = _http_api.sa_http_server_free_v2;
pub const sa_http_server_websocket_upgrade_v2 = _http_api.sa_http_server_websocket_upgrade_v2;
pub const sa_http_server_websocket_poll_v2 = _http_api.sa_http_server_websocket_poll_v2;
pub const sa_http_server_websocket_read_v2 = _http_api.sa_http_server_websocket_read_v2;
pub const sa_http_server_websocket_write_v2 = _http_api.sa_http_server_websocket_write_v2;
pub const sa_http_server_websocket_close_v2 = _http_api.sa_http_server_websocket_close_v2;
pub const sa_http_server_websocket_free_v2 = _http_api.sa_http_server_websocket_free_v2;

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

const sio = @import("sio");

pub fn ensureDir(path: []const u8) !void {
    if (path.len != 0) try sio.cwd().makePath(path);
}

pub fn writeFile(path: []const u8, bytes: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| try ensureDir(dir);
    var file = try sio.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(bytes);
}

pub fn requestPath(target: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, target, '?')) |idx| return target[0..idx];
    return target;
}

fn writeHttpResponse(writer: *std.Io.Writer, status: u16, reason: []const u8, content_type: []const u8, body: []const u8) !void {
    try writer.print("HTTP/1.1 {d} {s}\r\ncontent-type: {s}\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n", .{ status, reason, content_type, body.len });
    if (body.len > 0) try writer.writeAll(body);
    try writer.flush();
}

fn handleRawRoute(path: []const u8, body: []const u8, content_type: []const u8, writer: *std.Io.Writer, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    if (std.mem.eql(u8, path, "/echo")) {
        const ct = if (content_type.len == 0) "application/octet-stream" else content_type;
        try writeHttpResponse(writer, 200, "OK", ct, body);
        try stdout.print("route=echo path={s} body={d}\n", .{ path, body.len });
        return;
    }
    if (std.mem.eql(u8, path, "/stream")) {
        try writer.print("HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ntransfer-encoding: chunked\r\nconnection: close\r\n\r\n", .{});
        for ([_][]const u8{ "data: first\n\n", "data: second\n\n" }) |chunk| {
            try writer.print("{x}\r\n", .{chunk.len});
            try writer.writeAll(chunk);
            try writer.print("\r\n", .{});
            try writer.flush();
        }
        try writer.writeAll("0\r\n\r\n");
        try writer.flush();
        try stdout.print("route=stream path={s}\n", .{path});
        return;
    }
    const not_found = "not found\n";
    try writeHttpResponse(writer, 404, "Not Found", "text/plain", not_found);
    try stderr.print("error: unknown route {s}\n", .{path});
}

fn readHttpRequest(allocator: std.mem.Allocator, reader: *std.Io.net.Stream.Reader) !struct { target: []u8, content_type: []u8, body: []u8 } {
    var head = std.Io.Writer.Allocating.init(allocator);
    defer head.deinit();
    // Read until end of headers.
    while (true) {
        const chunk = try reader.interface.take(1);
        try head.writer.writeAll(chunk);
        if (head.written().len > 64 * 1024) return error.InvalidPath;
        if (head.written().len >= 4 and std.mem.endsWith(u8, head.written(), "\r\n\r\n")) break;
    }
    const head_bytes = head.written();
    var lines = std.mem.splitSequence(u8, head_bytes, "\r\n");
    const request_line = lines.next() orelse return error.InvalidPath;
    var parts = std.mem.splitScalar(u8, request_line, ' ');
    _ = parts.next() orelse return error.InvalidPath; // method
    const target_raw = parts.next() orelse return error.InvalidPath;
    const target = try allocator.dupe(u8, requestPath(target_raw));
    errdefer allocator.free(target);
    var content_type: []u8 = try allocator.dupe(u8, "");
    errdefer allocator.free(content_type);
    var content_len: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) break;
        if (std.ascii.startsWithIgnoreCase(line, "content-type:")) {
            allocator.free(content_type);
            content_type = try allocator.dupe(u8, std.mem.trim(u8, line["content-type:".len..], " \t"));
        } else if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
            content_len = std.fmt.parseInt(usize, std.mem.trim(u8, line["content-length:".len..], " \t"), 10) catch 0;
        }
    }
    if (content_len > 2 * 1024 * 1024) return error.InvalidPath;
    var body: []u8 = try allocator.alloc(u8, content_len);
    errdefer allocator.free(body);
    var off: usize = 0;
    while (off < content_len) {
        const n = try reader.interface.readSliceShort(body[off..]);
        if (n == 0) return error.InvalidPath;
        off += n;
    }
    return .{ .target = target, .content_type = content_type, .body = body };
}

pub fn runServeCommand(ctx: *const plugin_api.Context, argv: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) anyerror!?u8 {
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
    // NOTE(Zig 0.17): std.net/std.http.Server removed; minimal Io.net HTTP/1.1 server.
    const io = sio.io();
    var address = std.Io.net.IpAddress.parse(host, port) catch return error.InvalidPath;
    var server = address.listen(io, .{ .reuse_address = true }) catch return error.InvalidPath;
    defer server.deinit(io);

    var served: usize = 0;
    while (max_requests == null or served < max_requests.?) {
        const stream = server.accept(io) catch |err| {
            try stderr.print("error: accept failed: {}\n", .{err});
            return 1;
        };
        defer stream.close(io);

        var read_buf: [8192]u8 = undefined;
        var s_reader = stream.reader(io, &read_buf);
        var write_buf: [8192]u8 = undefined;
        var s_writer = stream.writer(io, &write_buf);
        const req = readHttpRequest(ctx.allocator, &s_reader) catch |err| {
            try stderr.print("error: receive head failed: {}\n", .{err});
            return 1;
        };
        defer ctx.allocator.free(req.target);
        defer ctx.allocator.free(req.content_type);
        defer ctx.allocator.free(req.body);

        handleRawRoute(req.target, req.body, req.content_type, &s_writer.interface, stdout, stderr) catch |err| {
            try stderr.print("error: request handling failed: {}\n", .{err});
            return 1;
        };
        served += 1;
    }
    return 0;
}

pub fn runHttpServerCommand(ctx: *const plugin_api.Context, argv: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) anyerror!?u8 {
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

fn writeHttpServerCliError(writer: *std.Io.Writer, argv: []const []const u8, err: anyerror) !void {
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
        stdout_writer.flush() catch return @intFromEnum(plugin_api.AbiStatus.failed);
        stderr_writer.flush() catch return @intFromEnum(plugin_api.AbiStatus.failed);
        out_code.* = 1;
        return @intFromEnum(plugin_api.AbiStatus.ok);
    };
    stdout_writer.flush() catch return @intFromEnum(plugin_api.AbiStatus.failed);
    stderr_writer.flush() catch return @intFromEnum(plugin_api.AbiStatus.failed);
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
