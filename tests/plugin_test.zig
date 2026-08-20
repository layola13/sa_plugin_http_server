const std = @import("std");
const plugin = @import("plugin");
const plugin_api = @import("plugin_api");

const CaptureStream = struct {
    buffer: *std.ArrayList(u8),
};

fn captureWriteAll(ctx: ?*anyopaque, bytes: [*]const u8, len: usize) callconv(.c) u32 {
    const stream_ctx: *CaptureStream = @ptrCast(@alignCast(ctx orelse return @intFromEnum(plugin_api.AbiStatus.failed)));
    stream_ctx.buffer.appendSlice(bytes[0..len]) catch return @intFromEnum(plugin_api.AbiStatus.failed);
    return @intFromEnum(plugin_api.AbiStatus.ok);
}

fn captureHostStream(ctx: *CaptureStream) plugin_api.HostStream {
    return .{ .ctx = ctx, .write_all = captureWriteAll };
}

fn dupeZArgs(allocator: std.mem.Allocator, argv: []const []const u8) ![][*:0]const u8 {
    var out = try allocator.alloc([*:0]const u8, argv.len);
    errdefer allocator.free(out);
    var copied: usize = 0;
    errdefer {
        for (out[0..copied]) |arg| allocator.free(std.mem.sliceTo(arg, 0));
    }
    for (argv, 0..) |arg, idx| {
        out[idx] = try allocator.dupeZ(u8, arg);
        copied += 1;
    }
    return out;
}

fn setTestReceiveTimeout(stream: std.net.Stream, timeout_ms: u32) !void {
    const timeout = std.posix.timeval{
        .sec = @intCast(timeout_ms / 1000),
        .usec = @intCast((timeout_ms % 1000) * 1000),
    };
    try std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout));
}
fn readResponseUntil(stream: std.net.Stream, buffer: []u8, needle: []const u8, timeout_ms: u32) !usize {
    const start_ms = std.time.milliTimestamp();
    var length: usize = 0;
    while (length < buffer.len) {
        const elapsed_ms: u64 = @intCast(@max(0, std.time.milliTimestamp() - start_ms));
        if (elapsed_ms >= timeout_ms) return error.TestTimeout;
        var poll_fds = [_]std.posix.pollfd{.{
            .fd = stream.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const remaining_ms: i32 = @intCast(timeout_ms - elapsed_ms);
        if (try std.posix.poll(&poll_fds, remaining_ms) == 0) return error.TestTimeout;
        const count = stream.read(buffer[length..]) catch |err| switch (err) {
            error.ConnectionResetByPeer, error.WouldBlock, error.ConnectionTimedOut => return error.TestTimeout,
            else => return err,
        };
        if (count == 0) return error.TestTimeout;
        length += count;
        if (std.mem.indexOf(u8, buffer[0..length], needle) != null) return length;
    }
    return error.TestTimeout;
}
fn freeZArgs(allocator: std.mem.Allocator, argv: [][*:0]const u8) void {
    for (argv) |arg| allocator.free(std.mem.sliceTo(arg, 0));
    allocator.free(argv);
}

test "http server plugin abi maps missing serve port to cli diagnostic" {
    var ctx = plugin_api.Context{ .allocator = std.testing.allocator };
    var stdout_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();
    var stdout_ctx = CaptureStream{ .buffer = &stdout_buf };
    var stderr_ctx = CaptureStream{ .buffer = &stderr_buf };

    const argv = try dupeZArgs(std.testing.allocator, &.{ "sa", "http-server", "serve", "127.0.0.1" });
    defer freeZArgs(std.testing.allocator, argv);

    var out_code: u8 = 255;
    const status = plugin.runHttpServerCommandAbi(
        &ctx,
        argv.ptr,
        argv.len,
        captureHostStream(&stdout_ctx),
        captureHostStream(&stderr_ctx),
        &out_code,
    );

    try std.testing.expectEqual(@intFromEnum(plugin_api.AbiStatus.ok), status);
    try std.testing.expectEqual(@as(u8, 1), out_code);
    try std.testing.expectEqual(@as(usize, 0), stdout_buf.items.len);
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buf.items, 1, "error[SA-HTTP-SERVER-CLI]: missing required HTTP server operand"));
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buf.items, 1, "usage: sa http-server serve <host> <port>"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, stderr_buf.items, 1, "PluginFailed"));
}

test "http server plugin exports runtime descriptor and scaffold entry" {
    const exported = &plugin.saasm_plugin_descriptor_v1;
    try std.testing.expectEqual(plugin_api.abi_version, exported.abi_version);
    try std.testing.expectEqual(@as(u32, @sizeOf(plugin_api.PluginDescriptor)), exported.descriptor_size);
    try std.testing.expectEqualStrings("http-server", std.mem.span(exported.name));
    try std.testing.expectEqual(@as(usize, 1), exported.skills_len);
    try std.testing.expectEqualStrings("http server plugin", exported.skills_ptr[0].name);
    try std.testing.expect(exported.handle_command != null);

    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var stdout_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const argv = [_][]const u8{ "sa", "http-server", "scaffold", "scaffold-out" };
    var ctx = plugin_api.Context{ .allocator = std.testing.allocator };
    const code = try plugin.runHttpServerCommand(
        &ctx,
        argv[0..],
        stdout_buf.writer().any(),
        stderr_buf.writer().any(),
    );

    try std.testing.expectEqual(@as(?u8, 0), code);
    try std.testing.expectEqualStrings("scaffold-out\n", stdout_buf.items);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
    const iface = try std.fs.cwd().readFileAlloc(std.testing.allocator, "scaffold-out/sa_http_server.sai", 1024 * 1024);
    defer std.testing.allocator.free(iface);
    try std.testing.expectEqualStrings(plugin.interface_source, iface);
}

test "http server runtime installs SIGPIPE handler for broken SSE sockets" {
    if (!@hasDecl(std.posix.SIG, "PIPE")) return error.SkipZigTest;

    const default_act: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.PIPE, &default_act, null);

    var server: ?*anyopaque = null;
    try std.testing.expectEqual(@as(u32, 0), plugin.sa_http_server_new(&server));
    defer _ = plugin.sa_http_server_free(server);

    var installed: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.PIPE, null, &installed);
    try std.testing.expect(installed.handler.handler != std.posix.SIG.DFL);
}

test "http server saasm api exposes request method" {
    const port: u16 = 18082;
    var server: ?*anyopaque = null;
    try std.testing.expectEqual(@as(u32, 0), plugin.sa_http_server_new(&server));
    defer _ = plugin.sa_http_server_free(server);

    const host = "127.0.0.1";
    try std.testing.expectEqual(@as(u32, 0), plugin.sa_http_server_start(server, host.ptr, host.len, port));

    const client_thread = try std.Thread.spawn(.{}, struct {
        fn run() !void {
            var stream = blk: {
                var attempt: usize = 0;
                while (attempt < 50) : (attempt += 1) {
                    const connected = std.net.tcpConnectToHost(std.testing.allocator, "127.0.0.1", 18082) catch |err| switch (err) {
                        error.ConnectionRefused => {
                            std.time.sleep(20 * std.time.ns_per_ms);
                            continue;
                        },
                        else => return err,
                    };
                    break :blk connected;
                }
                return error.ConnectionRefused;
            };
            defer stream.close();
            try stream.writeAll("POST /method HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
            var response_buf: [128]u8 = undefined;
            _ = try stream.read(&response_buf);
        }
    }.run, .{});

    var req: ?*anyopaque = null;
    try std.testing.expectEqual(@as(u32, 0), plugin.sa_http_server_accept(server, &req));
    defer _ = plugin.sa_http_server_req_free(req);

    var method_ptr: ?[*]const u8 = null;
    var method_len: u64 = 0;
    try std.testing.expectEqual(@as(u32, 0), plugin.sa_http_server_req_get_method(req, &method_ptr, &method_len));
    try std.testing.expectEqualStrings("POST", (method_ptr orelse return error.NullMethod)[0..@intCast(method_len)]);

    var resp: ?*anyopaque = null;
    const body = "ok";
    try std.testing.expectEqual(@as(u32, 0), plugin.sa_http_server_resp_new(req, 200, &resp));
    try std.testing.expectEqual(@as(u32, 0), plugin.sa_http_server_resp_send(resp, body.ptr, body.len));
    _ = plugin.sa_http_server_resp_free(resp);

    client_thread.join();
}

test "http server saasm api can send typed plain response" {
    const port: u16 = 18083;
    var server: ?*anyopaque = null;
    try std.testing.expectEqual(@as(u32, 0), plugin.sa_http_server_new(&server));
    defer _ = plugin.sa_http_server_free(server);

    const host = "127.0.0.1";
    try std.testing.expectEqual(@as(u32, 0), plugin.sa_http_server_start(server, host.ptr, host.len, port));

    const client_thread = try std.Thread.spawn(.{}, struct {
        fn run() !void {
            var stream = blk: {
                var attempt: usize = 0;
                while (attempt < 50) : (attempt += 1) {
                    const connected = std.net.tcpConnectToHost(std.testing.allocator, "127.0.0.1", 18083) catch |err| switch (err) {
                        error.ConnectionRefused => {
                            std.time.sleep(20 * std.time.ns_per_ms);
                            continue;
                        },
                        else => return err,
                    };
                    break :blk connected;
                }
                return error.ConnectionRefused;
            };
            defer stream.close();
            try stream.writeAll("GET /typed HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n");
            var response_buf: [512]u8 = undefined;
            const n = try stream.read(&response_buf);
            const response = response_buf[0..n];
            try std.testing.expect(std.mem.indexOf(u8, response, "HTTP/1.1 418") != null);
            try std.testing.expect(std.mem.indexOf(u8, response, "content-type: application/json") != null);
            try std.testing.expect(std.mem.endsWith(u8, response, "{}"));
        }
    }.run, .{});

    var req: ?*anyopaque = null;
    try std.testing.expectEqual(@as(u32, 0), plugin.sa_http_server_accept(server, &req));
    defer _ = plugin.sa_http_server_req_free(req);

    var resp: ?*anyopaque = null;
    const body = "{}";
    const content_type = "application/json";
    try std.testing.expectEqual(@as(u32, 0), plugin.sa_http_server_resp_new(req, 418, &resp));
    try std.testing.expectEqual(@as(u32, 0), plugin.sa_http_server_resp_set_content_type(resp, content_type.ptr, content_type.len));
    try std.testing.expectEqual(@as(u32, 0), plugin.sa_http_server_resp_send(resp, body.ptr, body.len));
    _ = plugin.sa_http_server_resp_free(resp);

    client_thread.join();
}

test "http server saasm api accepts null pointer for zero-length body" {
    const port: u16 = 18084;
    var server: ?*anyopaque = null;
    try std.testing.expectEqual(@as(u32, 0), plugin.sa_http_server_new(&server));
    defer _ = plugin.sa_http_server_free(server);

    const host = "127.0.0.1";
    try std.testing.expectEqual(@as(u32, 0), plugin.sa_http_server_start(server, host.ptr, host.len, port));

    const client_thread = try std.Thread.spawn(.{}, struct {
        fn run() !void {
            var stream = blk: {
                var attempt: usize = 0;
                while (attempt < 50) : (attempt += 1) {
                    const connected = std.net.tcpConnectToHost(std.testing.allocator, "127.0.0.1", 18084) catch |err| switch (err) {
                        error.ConnectionRefused => {
                            std.time.sleep(20 * std.time.ns_per_ms);
                            continue;
                        },
                        else => return err,
                    };
                    break :blk connected;
                }
                return error.ConnectionRefused;
            };
            defer stream.close();
            try stream.writeAll("GET /empty HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n");
            var response_buf: [512]u8 = undefined;
            const n = try stream.read(&response_buf);
            const response = response_buf[0..n];
            try std.testing.expect(std.mem.indexOf(u8, response, "HTTP/1.1 204") != null);
            try std.testing.expect(std.mem.indexOf(u8, response, "content-length: 0") != null);
        }
    }.run, .{});

    var req: ?*anyopaque = null;
    try std.testing.expectEqual(@as(u32, 0), plugin.sa_http_server_accept(server, &req));
    defer _ = plugin.sa_http_server_req_free(req);

    var resp: ?*anyopaque = null;
    try std.testing.expectEqual(@as(u32, 0), plugin.sa_http_server_resp_new(req, 204, &resp));
    try std.testing.expectEqual(@as(u32, 0), plugin.sa_http_server_resp_send(resp, null, 0));
    _ = plugin.sa_http_server_resp_free(resp);

    client_thread.join();
}

test "http server plugin serve responds on a local loopback socket" {
    var stdout_buf = std.ArrayList(u8).init(std.heap.page_allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.heap.page_allocator);
    defer stderr_buf.deinit();
    var stdout_writer = stdout_buf.writer();
    var stderr_writer = stderr_buf.writer();

    const port: u16 = 18080;
    const argv = [_][]const u8{ "sa", "http-server", "serve", "127.0.0.1", "18080", "1" };
    var ctx = plugin_api.Context{ .allocator = std.heap.page_allocator };
    const serve_thread = try std.Thread.spawn(.{}, struct {
        fn run(context: *plugin_api.Context, args: []const []const u8, stdout: std.io.AnyWriter, stderr: std.io.AnyWriter) void {
            _ = plugin.runHttpServerCommand(context, args, stdout, stderr) catch {};
        }
    }.run, .{ &ctx, argv[0..], stdout_writer.any(), stderr_writer.any() });
    var serve_joined = false;
    defer if (!serve_joined) serve_thread.join();

    var client = blk: {
        var attempt: usize = 0;
        while (attempt < 50) : (attempt += 1) {
            const stream = std.net.tcpConnectToHost(std.heap.page_allocator, "127.0.0.1", port) catch |err| switch (err) {
                error.ConnectionRefused => {
                    std.time.sleep(20 * std.time.ns_per_ms);
                    continue;
                },
                else => {
                    serve_thread.join();
                    serve_joined = true;
                    return err;
                },
            };
            break :blk stream;
        }
        serve_thread.join();
        serve_joined = true;
        return error.ConnectionRefused;
    };
    defer client.close();
    try client.writeAll("GET /echo HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: text/plain\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello");

    var response_buf: [256]u8 = undefined;
    const read_result = readResponseUntil(client, &response_buf, "hello", 2000);
    const response_len = try read_result;
    try std.testing.expect(std.mem.indexOf(u8, response_buf[0..response_len], "hello") != null);
    serve_thread.join();
    serve_joined = true;
    try std.testing.expectEqualStrings("route=echo path=/echo body=5\n", stdout_buf.items);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}
test "http server plugin stream route returns chunked SSE body" {
    var stdout_buf = std.ArrayList(u8).init(std.heap.page_allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.heap.page_allocator);
    defer stderr_buf.deinit();
    var stdout_writer = stdout_buf.writer();
    var stderr_writer = stderr_buf.writer();

    const port: u16 = 18081;
    const argv = [_][]const u8{ "sa", "http-server", "serve", "127.0.0.1", "18081", "1" };
    var ctx = plugin_api.Context{ .allocator = std.heap.page_allocator };
    const serve_thread = try std.Thread.spawn(.{}, struct {
        fn run(context: *plugin_api.Context, args: []const []const u8, stdout: std.io.AnyWriter, stderr: std.io.AnyWriter) void {
            _ = plugin.runHttpServerCommand(context, args, stdout, stderr) catch {};
        }
    }.run, .{ &ctx, argv[0..], stdout_writer.any(), stderr_writer.any() });
    var serve_joined = false;
    defer if (!serve_joined) serve_thread.join();

    var client = blk: {
        var attempt: usize = 0;
        while (attempt < 50) : (attempt += 1) {
            const stream = std.net.tcpConnectToHost(std.heap.page_allocator, "127.0.0.1", port) catch |err| switch (err) {
                error.ConnectionRefused => {
                    std.time.sleep(20 * std.time.ns_per_ms);
                    continue;
                },
                else => {
                    serve_thread.join();
                    serve_joined = true;
                    return err;
                },
            };
            break :blk stream;
        }
        serve_thread.join();
        serve_joined = true;
        return error.ConnectionRefused;
    };
    defer client.close();
    try client.writeAll("GET /stream HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n");

    var response_buf: [512]u8 = undefined;
    const read_result = readResponseUntil(client, &response_buf, "data: second", 2000);
    std.time.sleep(100 * std.time.ns_per_ms);
    const response_len = try read_result;
    try std.testing.expect(std.mem.indexOf(u8, response_buf[0..response_len], "data: first") != null);
    serve_thread.join();
    serve_joined = true;
    try std.testing.expectEqualStrings("route=stream path=/stream\n", stdout_buf.items);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}
fn connectEventually(port: u16) !std.net.Stream {
    var attempt: usize = 0;
    while (attempt < 50) : (attempt += 1) {
        return std.net.tcpConnectToHost(std.heap.page_allocator, "127.0.0.1", port) catch |err| switch (err) {
            error.ConnectionRefused => {
                std.time.sleep(20 * std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
    }
    return error.ConnectionRefused;
}

const ClientCapture = struct {
    bytes: [4096]u8 = undefined,
    len: usize = 0,
    failed: bool = false,
};

fn captureHttpResponse(port: u16, request: []const u8, capture: *ClientCapture) void {
    var stream = connectEventually(port) catch {
        capture.failed = true;
        return;
    };
    defer stream.close();
    stream.writeAll(request) catch {
        capture.failed = true;
        return;
    };
    capture.len = stream.read(&capture.bytes) catch {
        capture.failed = true;
        return;
    };
}

fn sendPartialHttpRequest(port: u16) void {
    var stream = connectEventually(port) catch return;
    defer stream.close();
    stream.writeAll("GET /slow HTTP/1.1\r\n") catch return;
    std.time.sleep(100 * std.time.ns_per_ms);
}

test "http server v2 status codes and pollable accept are stable" {
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(plugin.NetworkStatus.ok));
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(plugin.NetworkStatus.would_block));
    try std.testing.expectEqual(@as(u32, 2), @intFromEnum(plugin.NetworkStatus.closed));
    try std.testing.expectEqual(@as(u32, 3), @intFromEnum(plugin.NetworkStatus.timeout));
    try std.testing.expectEqual(@as(u32, 4), @intFromEnum(plugin.NetworkStatus.too_large));
    try std.testing.expectEqual(@as(u32, 5), @intFromEnum(plugin.NetworkStatus.invalid));
    try std.testing.expectEqual(@as(u32, 6), @intFromEnum(plugin.NetworkStatus.io_error));

    var server: ?*anyopaque = null;
    try std.testing.expectEqual(@as(u32, 0), plugin.sa_http_server_new_v2(&server));
    defer _ = plugin.sa_http_server_free_v2(server);
    const host = "127.0.0.1";
    try std.testing.expectEqual(@as(u32, 0), plugin.sa_http_server_start_v2(server, host.ptr, host.len, 18085));

    var req: ?*anyopaque = @ptrFromInt(1);
    try std.testing.expectEqual(@as(u32, 1), plugin.sa_http_server_accept_v2(server, 0, &req));
    try std.testing.expectEqual(@as(?*anyopaque, null), req);
    req = @ptrFromInt(1);
    try std.testing.expectEqual(@as(u32, 3), plugin.sa_http_server_accept_v2(server, 10, &req));
    try std.testing.expectEqual(@as(?*anyopaque, null), req);

    const partial_thread = try std.Thread.spawn(.{}, sendPartialHttpRequest, .{@as(u16, 18085)});
    var partial_joined = false;
    defer if (!partial_joined) partial_thread.join();
    try std.testing.expectEqual(@as(u32, 3), plugin.sa_http_server_accept_v2(server, 25, &req));
    try std.testing.expectEqual(@as(?*anyopaque, null), req);
    partial_thread.join();
    partial_joined = true;

    var capture = ClientCapture{};
    const client_thread = try std.Thread.spawn(.{}, captureHttpResponse, .{
        @as(u16, 18085),
        @as([]const u8, "GET /after-timeout HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"),
        &capture,
    });
    var client_joined = false;
    defer if (!client_joined) client_thread.join();
    try std.testing.expectEqual(@as(u32, 0), plugin.sa_http_server_accept_v2(server, 1000, &req));
    defer _ = plugin.sa_http_server_req_free_v2(req);
    var resp: ?*anyopaque = null;
    try std.testing.expectEqual(@as(u32, 0), plugin.sa_http_server_resp_new_v2(req, 204, &resp));
    defer _ = plugin.sa_http_server_resp_free_v2(resp);
    try std.testing.expectEqual(@as(u32, 0), plugin.sa_http_server_resp_send_v2(resp, null, 0, 1000));
    client_thread.join();
    client_joined = true;
    try std.testing.expect(!capture.failed);
    try std.testing.expect(std.mem.indexOf(u8, capture.bytes[0..capture.len], "HTTP/1.1 204") != null);
}

test "http server v2 owns arbitrary response headers and enforces the message cap" {
    var server: ?*anyopaque = null;
    try std.testing.expectEqual(@as(u32, 0), plugin.sa_http_server_new_v2(&server));
    defer _ = plugin.sa_http_server_free_v2(server);
    const host = "127.0.0.1";
    try std.testing.expectEqual(@as(u32, 0), plugin.sa_http_server_start_v2(server, host.ptr, host.len, 18086));

    var capture = ClientCapture{};
    const client_thread = try std.Thread.spawn(.{}, captureHttpResponse, .{
        @as(u16, 18086),
        @as([]const u8, "GET /headers HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"),
        &capture,
    });
    var client_joined = false;
    defer if (!client_joined) client_thread.join();

    var req: ?*anyopaque = null;
    try std.testing.expectEqual(@as(u32, 0), plugin.sa_http_server_accept_v2(server, 1000, &req));
    defer _ = plugin.sa_http_server_req_free_v2(req);
    var resp: ?*anyopaque = null;
    try std.testing.expectEqual(@as(u32, 0), plugin.sa_http_server_resp_new_v2(req, 200, &resp));
    defer _ = plugin.sa_http_server_resp_free_v2(resp);

    const header_name = "x-codex-max";
    var header_value = [_]u8{ 'r', 'e', 'a', 'd', 'y' };
    try std.testing.expectEqual(@as(u32, 0), plugin.sa_http_server_resp_add_header_v2(resp, header_name.ptr, header_name.len, header_value[0..].ptr, header_value.len));
    header_value[0] = 'X';
    const cookie_name = "set-cookie";
    const cookie_a = "a=1";
    const cookie_b = "b=2";
    try std.testing.expectEqual(@as(u32, 0), plugin.sa_http_server_resp_add_header_v2(resp, cookie_name.ptr, cookie_name.len, cookie_a.ptr, cookie_a.len));
    try std.testing.expectEqual(@as(u32, 0), plugin.sa_http_server_resp_add_header_v2(resp, cookie_name.ptr, cookie_name.len, cookie_b.ptr, cookie_b.len));
    const injected = "ok\r\nx-injected: yes";
    try std.testing.expectEqual(@as(u32, 5), plugin.sa_http_server_resp_add_header_v2(resp, header_name.ptr, header_name.len, injected.ptr, injected.len));

    const oversized = try std.testing.allocator.alloc(u8, plugin.max_v2_message_bytes + 1);
    defer std.testing.allocator.free(oversized);
    try std.testing.expectEqual(@as(u32, 4), plugin.sa_http_server_resp_send_v2(resp, oversized.ptr, oversized.len, 0));
    const body = "ok";
    try std.testing.expectEqual(@as(u32, 0), plugin.sa_http_server_resp_send_v2(resp, body.ptr, body.len, 1000));

    client_thread.join();
    client_joined = true;
    try std.testing.expect(!capture.failed);
    const response = capture.bytes[0..capture.len];
    try std.testing.expect(std.mem.indexOf(u8, response, "x-codex-max: ready\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "set-cookie: a=1\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "set-cookie: b=2\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, response, "ok"));
}

const WsClientState = struct {
    handshake_ok: bool = false,
    saw_close: bool = false,
    failed: bool = false,
};

fn websocketV2Client(port: u16, state: *WsClientState) void {
    var stream = connectEventually(port) catch {
        state.failed = true;
        return;
    };
    defer stream.close();
    stream.writeAll(
        "GET /ws HTTP/1.1\r\n" ++
            "Host: 127.0.0.1\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Version: 13\r\n" ++
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n",
    ) catch {
        state.failed = true;
        return;
    };
    var handshake: [512]u8 = undefined;
    const handshake_len = stream.read(&handshake) catch {
        state.failed = true;
        return;
    };
    state.handshake_ok = std.mem.indexOf(u8, handshake[0..handshake_len], "101 Switching Protocols") != null and
        std.mem.indexOf(u8, handshake[0..handshake_len], "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=") != null;
    std.time.sleep(50 * std.time.ns_per_ms);

    const frames = [_]u8{
        0x01, 0x82, 1, 2, 3, 4,       'h' ^ 1, 'e' ^ 2,
        0x89, 0x81, 9, 8, 7, 6,       '!' ^ 9, 0x80,
        0x83, 5,    6, 7, 8, 'l' ^ 5, 'l' ^ 6, 'o' ^ 7,
    };
    stream.writeAll(&frames) catch {
        state.failed = true;
        return;
    };

    var received: [1024]u8 = undefined;
    var used: usize = 0;
    while (used < received.len) {
        const count = stream.read(received[used..]) catch {
            state.failed = true;
            return;
        };
        if (count == 0) break;
        used += count;
        if (std.mem.indexOfScalar(u8, received[0..used], 0x88) != null) {
            state.saw_close = true;
            return;
        }
    }
}

test "http server v2 websocket polls fragmented messages and performs protocol close" {
    var server: ?*anyopaque = null;
    try std.testing.expectEqual(@as(u32, 0), plugin.sa_http_server_new_v2(&server));
    defer _ = plugin.sa_http_server_free_v2(server);
    const host = "127.0.0.1";
    try std.testing.expectEqual(@as(u32, 0), plugin.sa_http_server_start_v2(server, host.ptr, host.len, 18087));

    var client_state = WsClientState{};
    const client_thread = try std.Thread.spawn(.{}, websocketV2Client, .{ @as(u16, 18087), &client_state });
    var client_joined = false;
    defer if (!client_joined) client_thread.join();

    var req: ?*anyopaque = null;
    try std.testing.expectEqual(@as(u32, 0), plugin.sa_http_server_accept_v2(server, 1000, &req));
    var ws: ?*anyopaque = null;
    try std.testing.expectEqual(@as(u32, 0), plugin.sa_http_server_websocket_upgrade_v2(req, &ws));
    defer _ = plugin.sa_http_server_websocket_free_v2(ws);

    var events: u32 = 99;
    try std.testing.expectEqual(@as(u32, 1), plugin.sa_http_server_websocket_poll_v2(ws, plugin.PollEvent.readable, 0, &events));
    try std.testing.expectEqual(@as(u32, 0), events);
    try std.testing.expectEqual(@as(u32, 0), plugin.sa_http_server_websocket_poll_v2(ws, plugin.PollEvent.readable, 1000, &events));
    try std.testing.expect(events & plugin.PollEvent.readable != 0);

    var opcode: u8 = 0;
    var message_ptr: ?[*]const u8 = null;
    var message_len: u64 = 0;
    try std.testing.expectEqual(@as(u32, 0), plugin.sa_http_server_websocket_read_v2(ws, plugin.max_v2_message_bytes, &opcode, &message_ptr, &message_len));
    try std.testing.expectEqual(@as(u8, 1), opcode);
    try std.testing.expectEqualStrings("hello", (message_ptr orelse return error.NullMessage)[0..@intCast(message_len)]);

    const oversized = try std.testing.allocator.alloc(u8, plugin.max_v2_message_bytes + 1);
    defer std.testing.allocator.free(oversized);
    var written: u64 = 99;
    try std.testing.expectEqual(@as(u32, 4), plugin.sa_http_server_websocket_write_v2(ws, 1, oversized.ptr, oversized.len, &written));
    try std.testing.expectEqual(@as(u64, 0), written);
    const reply = "ok";
    try std.testing.expectEqual(@as(u32, 0), plugin.sa_http_server_websocket_write_v2(ws, 1, reply.ptr, reply.len, &written));
    try std.testing.expectEqual(@as(u64, reply.len), written);
    const reason = "done";
    try std.testing.expectEqual(@as(u32, 0), plugin.sa_http_server_websocket_close_v2(ws, 1000, reason.ptr, reason.len));
    try std.testing.expectEqual(@as(u32, 2), plugin.sa_http_server_websocket_write_v2(ws, 1, reply.ptr, reply.len, &written));
    try std.testing.expectEqual(@as(u64, 0), written);

    client_thread.join();
    client_joined = true;
    try std.testing.expect(!client_state.failed);
    try std.testing.expect(client_state.handshake_ok);
    try std.testing.expect(client_state.saw_close);
}

const BackpressureClientState = struct {
    handshake_ok: bool = false,
    bytes_read: usize = 0,
    failed: bool = false,
    allow_read: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn websocketBackpressureClient(port: u16, state: *BackpressureClientState) void {
    var stream = connectEventually(port) catch {
        state.failed = true;
        return;
    };
    defer stream.close();
    stream.writeAll(
        "GET /backpressure HTTP/1.1\r\n" ++
            "Host: 127.0.0.1\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Version: 13\r\n" ++
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n",
    ) catch {
        state.failed = true;
        return;
    };
    var handshake: [512]u8 = undefined;
    const handshake_len = stream.read(&handshake) catch {
        state.failed = true;
        return;
    };
    state.handshake_ok = std.mem.indexOf(u8, handshake[0..handshake_len], "101 Switching Protocols") != null;

    var wait_attempt: usize = 0;
    while (!state.allow_read.load(.acquire) and wait_attempt < 5000) : (wait_attempt += 1) {
        std.time.sleep(std.time.ns_per_ms);
    }
    if (!state.allow_read.load(.acquire)) return;
    var buffer: [8192]u8 = undefined;
    while (true) {
        var poll_fds = [_]std.posix.pollfd{.{
            .fd = stream.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ready = std.posix.poll(&poll_fds, 5000) catch {
            state.failed = true;
            return;
        };
        if (ready == 0) {
            state.failed = true;
            return;
        }
        const count = stream.read(&buffer) catch |err| switch (err) {
            error.ConnectionResetByPeer => return,
            else => {
                state.failed = true;
                return;
            },
        };
        if (count == 0) return;
        state.bytes_read += count;
    }
}

test "http server v2 websocket reports and recovers from bounded backpressure" {
    var server: ?*anyopaque = null;
    try std.testing.expectEqual(@as(u32, 0), plugin.sa_http_server_new_v2(&server));
    defer _ = plugin.sa_http_server_free_v2(server);
    const host = "127.0.0.1";
    try std.testing.expectEqual(@as(u32, 0), plugin.sa_http_server_start_v2(server, host.ptr, host.len, 18088));

    var client_state = BackpressureClientState{};
    const client_thread = try std.Thread.spawn(.{}, websocketBackpressureClient, .{ @as(u16, 18088), &client_state });
    var client_joined = false;
    defer client_state.allow_read.store(true, .release);
    defer if (!client_joined) client_thread.join();

    var req: ?*anyopaque = null;
    try std.testing.expectEqual(@as(u32, 0), plugin.sa_http_server_accept_v2(server, 1000, &req));
    var ws: ?*anyopaque = null;
    try std.testing.expectEqual(@as(u32, 0), plugin.sa_http_server_websocket_upgrade_v2(req, &ws));
    var ws_live = true;
    defer {
        if (ws_live) _ = plugin.sa_http_server_websocket_free_v2(ws);
    }

    const handle = @as(*plugin.WebSocketHandle, @ptrCast(@alignCast(ws orelse return error.NullWebSocket)));
    const send_buffer_size: c_int = 4096;
    try std.posix.setsockopt(handle.stream.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDBUF, std.mem.asBytes(&send_buffer_size));

    const backpressure_payload_bytes = 64 * 1024;
    const payload = try std.testing.allocator.alloc(u8, backpressure_payload_bytes);
    defer std.testing.allocator.free(payload);
    @memset(payload, 'x');
    var written: u64 = 0;
    try std.testing.expectEqual(@as(u32, 0), plugin.sa_http_server_websocket_write_v2(ws, 2, payload.ptr, payload.len, &written));
    try std.testing.expectEqual(@as(u64, payload.len), written);
    var saw_backpressure = false;
    var attempt: usize = 0;
    while (attempt < 256) : (attempt += 1) {
        const status = plugin.sa_http_server_websocket_write_v2(ws, 2, payload.ptr, payload.len, &written);
        if (status == 1) {
            try std.testing.expectEqual(@as(u64, 0), written);
            saw_backpressure = true;
            break;
        }
        try std.testing.expectEqual(@as(u32, 0), status);
        try std.testing.expectEqual(@as(u64, payload.len), written);
    }
    try std.testing.expect(saw_backpressure);
    client_state.allow_read.store(true, .release);

    var events: u32 = 0;
    try std.testing.expectEqual(@as(u32, 1), plugin.sa_http_server_websocket_poll_v2(ws, plugin.PollEvent.writable, 0, &events));
    try std.testing.expectEqual(@as(u32, 0), events);

    var recovered = false;
    attempt = 0;
    while (attempt < 20) : (attempt += 1) {
        const status = plugin.sa_http_server_websocket_poll_v2(ws, plugin.PollEvent.writable, 250, &events);
        if (status == 0 and events & plugin.PollEvent.writable != 0) {
            recovered = true;
            break;
        }
        try std.testing.expect(status == 1 or status == 3);
    }
    try std.testing.expect(recovered);

    try std.testing.expectEqual(@as(u32, 0), plugin.sa_http_server_websocket_free_v2(ws));
    ws_live = false;
    client_thread.join();
    client_joined = true;
    try std.testing.expect(!client_state.failed);
    try std.testing.expect(client_state.handshake_ok);
    try std.testing.expect(client_state.bytes_read >= backpressure_payload_bytes);
}
