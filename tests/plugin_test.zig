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
    try std.testing.expectEqualStrings(
        \\@extern sa_http_server_new(&out_server: ptr) -> i32!
        \\@extern sa_http_server_route(server: ptr, &path: ptr, path_len: u64, ^handler: ptr) -> i32!
        \\@extern sa_http_server_start(server: ptr, &host: ptr, host_len: u64, port: u16) -> i32!
        \\@extern sa_http_server_resp_new(req: ptr, status: u16, &out_resp: ptr) -> i32!
        \\@extern sa_http_server_resp_send(resp: ptr, &body_ptr: ptr, body_len: u64) -> i32!
    , iface);
}

test "http server plugin serve responds on a local loopback socket" {
    var stdout_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const port: u16 = 18080;
    const argv = [_][]const u8{ "sa", "http-server", "serve", "127.0.0.1", "18080", "1" };
    var ctx = plugin_api.Context{ .allocator = std.testing.allocator };
    const serve_thread = try std.Thread.spawn(.{}, struct {
        fn run(context: *plugin_api.Context, args: []const []const u8, stdout: std.io.AnyWriter, stderr: std.io.AnyWriter) void {
            _ = plugin.runHttpServerCommand(context, args, stdout, stderr) catch {};
        }
    }.run, .{ &ctx, argv[0..], stdout_buf.writer().any(), stderr_buf.writer().any() });

    var client = blk: {
        var attempt: usize = 0;
        while (attempt < 50) : (attempt += 1) {
            const stream = std.net.tcpConnectToHost(std.testing.allocator, "127.0.0.1", port) catch |err| switch (err) {
                error.ConnectionRefused => {
                    std.time.sleep(20 * std.time.ns_per_ms);
                    continue;
                },
                else => return err,
            };
            break :blk stream;
        }
        return error.ConnectionRefused;
    };
    defer client.close();
    try client.writeAll("GET /echo HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: text/plain\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello");

    var response_buf: [256]u8 = undefined;
    const n = try client.read(&response_buf);
    try std.testing.expect(n > 0);
    try std.testing.expect(std.mem.indexOf(u8, response_buf[0..n], "hello") != null);

    serve_thread.join();
    try std.testing.expectEqualStrings("route=echo path=/echo body=5\n", stdout_buf.items);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "http server plugin stream route returns chunked SSE body" {
    var stdout_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const port: u16 = 18081;
    const argv = [_][]const u8{ "sa", "http-server", "serve", "127.0.0.1", "18081", "1" };
    var ctx = plugin_api.Context{ .allocator = std.testing.allocator };
    const serve_thread = try std.Thread.spawn(.{}, struct {
        fn run(context: *plugin_api.Context, args: []const []const u8, stdout: std.io.AnyWriter, stderr: std.io.AnyWriter) void {
            _ = plugin.runHttpServerCommand(context, args, stdout, stderr) catch {};
        }
    }.run, .{ &ctx, argv[0..], stdout_buf.writer().any(), stderr_buf.writer().any() });

    var client = blk: {
        var attempt: usize = 0;
        while (attempt < 50) : (attempt += 1) {
            const stream = std.net.tcpConnectToHost(std.testing.allocator, "127.0.0.1", port) catch |err| switch (err) {
                error.ConnectionRefused => {
                    std.time.sleep(20 * std.time.ns_per_ms);
                    continue;
                },
                else => return err,
            };
            break :blk stream;
        }
        return error.ConnectionRefused;
    };
    defer client.close();
    try client.writeAll("GET /stream HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n");

    var response_buf: [512]u8 = undefined;
    const n = try client.read(&response_buf);
    try std.testing.expect(n > 0);
    try std.testing.expect(std.mem.indexOf(u8, response_buf[0..n], "data: first") != null);

    serve_thread.join();
    try std.testing.expectEqualStrings("route=stream path=/stream\n", stdout_buf.items);
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}
