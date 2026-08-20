const std = @import("std");
const plugin_api = @import("plugin_api");
const core = @import("vite_api.zig");
const sa_std_net = @import("sa_std_net.zig");

const ensureProcessSignalSafety = core.ensureProcessSignalSafety;
pub const HttpServer = core.HttpServer;
pub const HttpRequest = core.HttpRequest;
pub const HttpResponse = core.HttpResponse;
pub const HttpStreamResponse = core.HttpStreamResponse;
pub const WebSocketHandle = core.WebSocketHandle;
pub const NetworkStatus = core.NetworkStatus;
pub const PollEvent = core.PollEvent;
pub const max_v2_message_bytes = core.max_v2_message_bytes;
const findHeader = core.findHeader;
const headerContainsToken = core.headerContainsToken;
const readFrame = core.readFrame;
const writeFrame = core.writeFrame;

pub const SaHttpServerHandle = extern struct {
    impl: ?*anyopaque,
};

pub const SaHttpRequestHandle = extern struct {
    impl: ?*anyopaque,
};

pub const SaHttpResponseHandle = extern struct {
    impl: ?*anyopaque,
};

pub const SaHttpStreamResponseHandle = extern struct {
    impl: ?*anyopaque,
};

pub export fn sa_http_server_new(out_server: ?*?*anyopaque) u32 {
    ensureProcessSignalSafety();
    const slot = out_server orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const server = HttpServer.init(std.heap.page_allocator) catch return @intFromEnum(plugin_api.AbiStatus.failed);
    slot.* = @ptrCast(server);
    return @intFromEnum(plugin_api.AbiStatus.ok);
}

pub export fn sa_http_server_start(server: ?*anyopaque, host_ptr: ?[*]const u8, host_len: u64, port: u16) u32 {
    const server_ptr = server orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const host = host_ptr orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const srv = @as(*HttpServer, @ptrCast(@alignCast(server_ptr)));
    srv.start(host[0..@intCast(host_len)], port) catch return @intFromEnum(plugin_api.AbiStatus.failed);
    return @intFromEnum(plugin_api.AbiStatus.ok);
}

pub export fn sa_http_server_accept(server: ?*anyopaque, out_req: ?*?*anyopaque) u32 {
    const server_ptr = server orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const slot = out_req orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const srv = @as(*HttpServer, @ptrCast(@alignCast(server_ptr)));
    const request = srv.accept() catch return @intFromEnum(plugin_api.AbiStatus.failed);
    slot.* = @ptrCast(request);
    return @intFromEnum(plugin_api.AbiStatus.ok);
}

pub export fn sa_http_server_req_get_method(req: ?*anyopaque, out_method_ptr: ?*?[*]const u8, out_len: ?*u64) u32 {
    const req_ptr = req orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const method_slot = out_method_ptr orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const len_slot = out_len orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const request = @as(*HttpRequest, @ptrCast(@alignCast(req_ptr)));
    method_slot.* = request.method.ptr;
    len_slot.* = request.method.len;
    return @intFromEnum(plugin_api.AbiStatus.ok);
}

pub export fn sa_http_server_req_get_path(req: ?*anyopaque, out_path_ptr: ?*?[*]const u8, out_len: ?*u64) u32 {
    const req_ptr = req orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const path_slot = out_path_ptr orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const len_slot = out_len orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const request = @as(*HttpRequest, @ptrCast(@alignCast(req_ptr)));
    const target = request.target;
    const path = if (std.mem.indexOfScalar(u8, target, '?')) |idx| target[0..idx] else target;
    path_slot.* = path.ptr;
    len_slot.* = path.len;
    return @intFromEnum(plugin_api.AbiStatus.ok);
}

pub export fn sa_http_server_req_get_header(req: ?*anyopaque, key_ptr: ?[*]const u8, key_len: u64, out_val_ptr: ?*?[*]const u8, out_val_len: ?*u64) u32 {
    const req_ptr = req orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const key = key_ptr orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const path_slot = out_val_ptr orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const len_slot = out_val_len orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const request = @as(*HttpRequest, @ptrCast(@alignCast(req_ptr)));
    const wanted = key[0..@intCast(key_len)];
    for (request.headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, wanted)) {
            path_slot.* = header.value.ptr;
            len_slot.* = header.value.len;
            return @intFromEnum(plugin_api.AbiStatus.ok);
        }
    }
    return @intFromEnum(plugin_api.AbiStatus.failed);
}

pub export fn sa_http_server_req_get_body(req: ?*anyopaque, out_body_ptr: ?*?[*]const u8, out_body_len: ?*u64) u32 {
    const req_ptr = req orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const body_slot = out_body_ptr orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const len_slot = out_body_len orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const request = @as(*HttpRequest, @ptrCast(@alignCast(req_ptr)));
    body_slot.* = request.body.ptr;
    len_slot.* = request.body.len;
    return @intFromEnum(plugin_api.AbiStatus.ok);
}

pub export fn sa_http_server_req_free(req: ?*anyopaque) u32 {
    const req_ptr = req orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const request = @as(*HttpRequest, @ptrCast(@alignCast(req_ptr)));
    request.deinit();
    return @intFromEnum(plugin_api.AbiStatus.ok);
}

pub export fn sa_http_server_resp_new(req: ?*anyopaque, status: u16, out_resp: ?*?*anyopaque) u32 {
    const req_ptr = req orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const slot = out_resp orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const request = @as(*HttpRequest, @ptrCast(@alignCast(req_ptr)));
    const response = HttpResponse.init(request, status) catch return @intFromEnum(plugin_api.AbiStatus.failed);
    slot.* = @ptrCast(response);
    return @intFromEnum(plugin_api.AbiStatus.ok);
}

pub export fn sa_http_server_resp_send(resp: ?*anyopaque, body_ptr: ?[*]const u8, body_len: u64) u32 {
    const resp_ptr = resp orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const body = if (body_ptr) |body| body[0..@intCast(body_len)] else blk: {
        if (body_len != 0) return @intFromEnum(plugin_api.AbiStatus.failed);
        break :blk "";
    };
    const response = @as(*HttpResponse, @ptrCast(@alignCast(resp_ptr)));
    response.send(body) catch return @intFromEnum(plugin_api.AbiStatus.failed);
    return @intFromEnum(plugin_api.AbiStatus.ok);
}

pub export fn sa_http_server_resp_set_content_type(resp: ?*anyopaque, content_type_ptr: ?[*]const u8, content_type_len: u64) u32 {
    const resp_ptr = resp orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const content_type = content_type_ptr orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const response = @as(*HttpResponse, @ptrCast(@alignCast(resp_ptr)));
    response.setContentType(content_type[0..@intCast(content_type_len)]) catch return @intFromEnum(plugin_api.AbiStatus.failed);
    return @intFromEnum(plugin_api.AbiStatus.ok);
}

pub export fn sa_http_server_resp_free(resp: ?*anyopaque) u32 {
    const resp_ptr = resp orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const response = @as(*HttpResponse, @ptrCast(@alignCast(resp_ptr)));
    response.deinit();
    return @intFromEnum(plugin_api.AbiStatus.ok);
}

pub export fn sa_http_server_resp_stream_new(req: ?*anyopaque, status: u16, out_resp: ?*?*anyopaque) u32 {
    const req_ptr = req orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const slot = out_resp orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const request = @as(*HttpRequest, @ptrCast(@alignCast(req_ptr)));
    const response = HttpStreamResponse.init(request, status) catch return @intFromEnum(plugin_api.AbiStatus.failed);
    slot.* = @ptrCast(response);
    return @intFromEnum(plugin_api.AbiStatus.ok);
}

pub export fn sa_http_server_resp_stream_write(resp: ?*anyopaque, body_ptr: ?[*]const u8, body_len: u64) u32 {
    const resp_ptr = resp orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const body = if (body_ptr) |body| body[0..@intCast(body_len)] else blk: {
        if (body_len != 0) return @intFromEnum(plugin_api.AbiStatus.failed);
        break :blk "";
    };
    const response = @as(*HttpStreamResponse, @ptrCast(@alignCast(resp_ptr)));
    if (response.ended) return @intFromEnum(plugin_api.AbiStatus.failed);
    response.writeChunk(body) catch return @intFromEnum(plugin_api.AbiStatus.failed);
    return @intFromEnum(plugin_api.AbiStatus.ok);
}

pub export fn sa_http_server_resp_stream_flush(resp: ?*anyopaque) u32 {
    const resp_ptr = resp orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const response = @as(*HttpStreamResponse, @ptrCast(@alignCast(resp_ptr)));
    if (response.ended) return @intFromEnum(plugin_api.AbiStatus.failed);
    response.flush() catch return @intFromEnum(plugin_api.AbiStatus.failed);
    return @intFromEnum(plugin_api.AbiStatus.ok);
}

pub export fn sa_http_server_resp_stream_end(resp: ?*anyopaque) u32 {
    const resp_ptr = resp orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const response = @as(*HttpStreamResponse, @ptrCast(@alignCast(resp_ptr)));
    if (response.ended) return @intFromEnum(plugin_api.AbiStatus.failed);
    response.endChunked() catch return @intFromEnum(plugin_api.AbiStatus.failed);
    response.ended = true;
    return @intFromEnum(plugin_api.AbiStatus.ok);
}

pub export fn sa_http_server_resp_stream_free(resp: ?*anyopaque) u32 {
    const resp_ptr = resp orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const response = @as(*HttpStreamResponse, @ptrCast(@alignCast(resp_ptr)));
    response.deinit();
    return @intFromEnum(plugin_api.AbiStatus.ok);
}

pub export fn sa_http_server_free(server: ?*anyopaque) u32 {
    const server_ptr = server orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const srv = @as(*HttpServer, @ptrCast(@alignCast(server_ptr)));
    srv.deinit();
    return @intFromEnum(plugin_api.AbiStatus.ok);
}

pub export fn sa_http_server_websocket_upgrade(req: ?*anyopaque, out_ws: ?*?*anyopaque) u32 {
    const req_ptr = req orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const slot = out_ws orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const request = @as(*HttpRequest, @ptrCast(@alignCast(req_ptr)));

    const upgrade = findHeader(request, "upgrade") orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    if (!std.ascii.eqlIgnoreCase(upgrade, "websocket")) return @intFromEnum(plugin_api.AbiStatus.failed);
    const connection = findHeader(request, "connection") orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    if (!headerContainsToken(connection, "upgrade")) return @intFromEnum(plugin_api.AbiStatus.failed);
    const key = findHeader(request, "sec-websocket-key") orelse return @intFromEnum(plugin_api.AbiStatus.failed);

    var accept_buf: [28]u8 = undefined;
    const accept = sa_std_net.websocketAccept(key, &accept_buf) catch return @intFromEnum(plugin_api.AbiStatus.failed);

    var header_buf: [256]u8 = undefined;
    const response = std.fmt.bufPrint(
        &header_buf,
        "HTTP/1.1 101 Switching Protocols\r\nupgrade: websocket\r\nconnection: Upgrade\r\nsec-websocket-accept: {s}\r\n\r\n",
        .{accept},
    ) catch return @intFromEnum(plugin_api.AbiStatus.failed);
    request.connection.stream.writeAll(response) catch return @intFromEnum(plugin_api.AbiStatus.failed);

    const handle = WebSocketHandle.initFromRequest(request) catch return @intFromEnum(plugin_api.AbiStatus.failed);
    slot.* = @ptrCast(handle);
    request.freeResources();
    request.allocator.destroy(request);
    return @intFromEnum(plugin_api.AbiStatus.ok);
}

pub export fn sa_http_server_websocket_read(ws: ?*anyopaque, max_len: u64, out_opcode: ?*u8, out_ptr: ?*?[*]const u8, out_len: ?*u64) u32 {
    const ws_ptr = ws orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const handle = @as(*WebSocketHandle, @ptrCast(@alignCast(ws_ptr)));
    return readFrame(handle, max_len, out_opcode, out_ptr, out_len);
}

pub export fn sa_http_server_websocket_write(ws: ?*anyopaque, opcode: u8, data_ptr: ?[*]const u8, data_len: u64) u32 {
    const ws_ptr = ws orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const handle = @as(*WebSocketHandle, @ptrCast(@alignCast(ws_ptr)));
    const payload = if (data_ptr) |ptr| ptr[0..@intCast(data_len)] else &[_]u8{};
    if (!writeFrame(handle.stream, opcode, payload)) return @intFromEnum(plugin_api.AbiStatus.failed);
    return @intFromEnum(plugin_api.AbiStatus.ok);
}

pub export fn sa_http_server_websocket_free(ws: ?*anyopaque) u32 {
    const ws_ptr = ws orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const handle = @as(*WebSocketHandle, @ptrCast(@alignCast(ws_ptr)));
    handle.deinit();
    return @intFromEnum(plugin_api.AbiStatus.ok);
}

fn networkStatus(status: NetworkStatus) u32 {
    return @intFromEnum(status);
}

fn validWebSocketKey(key: []const u8) bool {
    if (key.len != 24) return false;
    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(key) catch return false;
    if (decoded_len != 16) return false;
    var decoded: [16]u8 = undefined;
    std.base64.standard.Decoder.decode(&decoded, key) catch return false;
    return true;
}

pub export fn sa_http_server_new_v2(out_server: ?*?*anyopaque) u32 {
    ensureProcessSignalSafety();
    const slot = out_server orelse return networkStatus(.invalid);
    slot.* = null;
    const server = HttpServer.init(std.heap.page_allocator) catch return networkStatus(.io_error);
    slot.* = @ptrCast(server);
    return networkStatus(.ok);
}

pub export fn sa_http_server_start_v2(server: ?*anyopaque, host_ptr: ?[*]const u8, host_len: u64, port: u16) u32 {
    const server_ptr = server orelse return networkStatus(.invalid);
    if (host_len == 0 or host_len > std.math.maxInt(usize)) return networkStatus(.invalid);
    const host = host_ptr orelse return networkStatus(.invalid);
    const srv = @as(*HttpServer, @ptrCast(@alignCast(server_ptr)));
    srv.start(host[0..@intCast(host_len)], port) catch |err| return networkStatus(core.statusFromError(err));
    return networkStatus(.ok);
}

pub export fn sa_http_server_accept_v2(server: ?*anyopaque, timeout_ms: u32, out_req: ?*?*anyopaque) u32 {
    const slot = out_req orelse return networkStatus(.invalid);
    slot.* = null;
    const server_ptr = server orelse return networkStatus(.invalid);
    const srv = @as(*HttpServer, @ptrCast(@alignCast(server_ptr)));
    const started_ms = std.time.milliTimestamp();
    const poll_status = srv.pollAccept(timeout_ms);
    if (poll_status != .ok) return networkStatus(poll_status);
    const receive_timeout_ms: u32 = if (timeout_ms == 0) 0 else blk: {
        const elapsed_signed = std.time.milliTimestamp() - started_ms;
        const elapsed_ms: u64 = if (elapsed_signed <= 0) 0 else @intCast(elapsed_signed);
        if (elapsed_ms >= timeout_ms) return networkStatus(.timeout);
        break :blk @intCast(@as(u64, timeout_ms) - elapsed_ms);
    };
    const request = srv.acceptWithBodyLimitAndTimeout(max_v2_message_bytes, receive_timeout_ms) catch |err| {
        if (err == error.WouldBlock or err == error.HttpHeadersUnreadable or err == error.HttpRequestTruncated or err == error.HttpConnectionClosing) return networkStatus(if (timeout_ms == 0) .would_block else .timeout);
        return networkStatus(core.statusFromError(err));
    };
    slot.* = @ptrCast(request);
    return networkStatus(.ok);
}

pub export fn sa_http_server_req_free_v2(req: ?*anyopaque) u32 {
    const req_ptr = req orelse return networkStatus(.invalid);
    const request = @as(*HttpRequest, @ptrCast(@alignCast(req_ptr)));
    request.deinit();
    return networkStatus(.ok);
}

pub export fn sa_http_server_resp_new_v2(req: ?*anyopaque, status: u16, out_resp: ?*?*anyopaque) u32 {
    const slot = out_resp orelse return networkStatus(.invalid);
    slot.* = null;
    const req_ptr = req orelse return networkStatus(.invalid);
    if (status < 100 or status > 599) return networkStatus(.invalid);
    const request = @as(*HttpRequest, @ptrCast(@alignCast(req_ptr)));
    const response = HttpResponse.init(request, status) catch return networkStatus(.io_error);
    slot.* = @ptrCast(response);
    return networkStatus(.ok);
}

pub export fn sa_http_server_resp_add_header_v2(resp: ?*anyopaque, name_ptr: ?[*]const u8, name_len: u64, value_ptr: ?[*]const u8, value_len: u64) u32 {
    const resp_ptr = resp orelse return networkStatus(.invalid);
    if (name_len == 0 or name_len > std.math.maxInt(usize) or value_len > std.math.maxInt(usize)) return networkStatus(.invalid);
    const name = name_ptr orelse return networkStatus(.invalid);
    const value = if (value_ptr) |ptr| ptr[0..@intCast(value_len)] else blk: {
        if (value_len != 0) return networkStatus(.invalid);
        break :blk "";
    };
    const response = @as(*HttpResponse, @ptrCast(@alignCast(resp_ptr)));
    response.setHeader(name[0..@intCast(name_len)], value) catch |err| return networkStatus(core.statusFromError(err));
    return networkStatus(.ok);
}

pub export fn sa_http_server_resp_send_v2(resp: ?*anyopaque, body_ptr: ?[*]const u8, body_len: u64, timeout_ms: u32) u32 {
    const resp_ptr = resp orelse return networkStatus(.invalid);
    if (body_len > max_v2_message_bytes) return networkStatus(.too_large);
    const body = if (body_ptr) |ptr| ptr[0..@intCast(body_len)] else blk: {
        if (body_len != 0) return networkStatus(.invalid);
        break :blk "";
    };
    const response = @as(*HttpResponse, @ptrCast(@alignCast(resp_ptr)));
    const poll_status = core.pollStream(response.request.connection.stream, std.posix.POLL.OUT, timeout_ms, null);
    if (poll_status != .ok) return networkStatus(poll_status);
    response.send(body) catch |err| return networkStatus(core.statusFromError(err));
    return networkStatus(.ok);
}

pub export fn sa_http_server_resp_free_v2(resp: ?*anyopaque) u32 {
    const resp_ptr = resp orelse return networkStatus(.invalid);
    const response = @as(*HttpResponse, @ptrCast(@alignCast(resp_ptr)));
    response.deinit();
    return networkStatus(.ok);
}

pub export fn sa_http_server_resp_stream_new_v2(req: ?*anyopaque, status: u16, out_resp: ?*?*anyopaque) u32 {
    const slot = out_resp orelse return networkStatus(.invalid);
    slot.* = null;
    const req_ptr = req orelse return networkStatus(.invalid);
    if (status < 100 or status > 599) return networkStatus(.invalid);
    const request = @as(*HttpRequest, @ptrCast(@alignCast(req_ptr)));
    const response = HttpStreamResponse.initDeferred(request, status) catch return networkStatus(.io_error);
    slot.* = @ptrCast(response);
    return networkStatus(.ok);
}

pub export fn sa_http_server_resp_stream_add_header_v2(resp: ?*anyopaque, name_ptr: ?[*]const u8, name_len: u64, value_ptr: ?[*]const u8, value_len: u64) u32 {
    const resp_ptr = resp orelse return networkStatus(.invalid);
    if (name_len == 0 or name_len > std.math.maxInt(usize) or value_len > std.math.maxInt(usize)) return networkStatus(.invalid);
    const name = name_ptr orelse return networkStatus(.invalid);
    const value = if (value_ptr) |ptr| ptr[0..@intCast(value_len)] else blk: {
        if (value_len != 0) return networkStatus(.invalid);
        break :blk "";
    };
    const response = @as(*HttpStreamResponse, @ptrCast(@alignCast(resp_ptr)));
    response.setHeader(name[0..@intCast(name_len)], value) catch |err| return networkStatus(core.statusFromError(err));
    return networkStatus(.ok);
}

pub export fn sa_http_server_resp_stream_write_v2(resp: ?*anyopaque, body_ptr: ?[*]const u8, body_len: u64, timeout_ms: u32) u32 {
    const resp_ptr = resp orelse return networkStatus(.invalid);
    if (body_len > max_v2_message_bytes) return networkStatus(.too_large);
    const body = if (body_ptr) |ptr| ptr[0..@intCast(body_len)] else blk: {
        if (body_len != 0) return networkStatus(.invalid);
        break :blk "";
    };
    const response = @as(*HttpStreamResponse, @ptrCast(@alignCast(resp_ptr)));
    if (response.ended) return networkStatus(.closed);
    const poll_status = core.pollStream(response.request.connection.stream, std.posix.POLL.OUT, timeout_ms, null);
    if (poll_status != .ok) return networkStatus(poll_status);
    response.writeChunk(body) catch |err| return networkStatus(core.statusFromError(err));
    return networkStatus(.ok);
}

pub export fn sa_http_server_resp_stream_flush_v2(resp: ?*anyopaque) u32 {
    const resp_ptr = resp orelse return networkStatus(.invalid);
    const response = @as(*HttpStreamResponse, @ptrCast(@alignCast(resp_ptr)));
    if (response.ended) return networkStatus(.closed);
    response.flush() catch |err| return networkStatus(core.statusFromError(err));
    return networkStatus(.ok);
}

pub export fn sa_http_server_resp_stream_end_v2(resp: ?*anyopaque, timeout_ms: u32) u32 {
    const resp_ptr = resp orelse return networkStatus(.invalid);
    const response = @as(*HttpStreamResponse, @ptrCast(@alignCast(resp_ptr)));
    if (response.ended) return networkStatus(.closed);
    const poll_status = core.pollStream(response.request.connection.stream, std.posix.POLL.OUT, timeout_ms, null);
    if (poll_status != .ok) return networkStatus(poll_status);
    response.endChunked() catch |err| return networkStatus(core.statusFromError(err));
    return networkStatus(.ok);
}

pub export fn sa_http_server_resp_stream_free_v2(resp: ?*anyopaque) u32 {
    const resp_ptr = resp orelse return networkStatus(.invalid);
    const response = @as(*HttpStreamResponse, @ptrCast(@alignCast(resp_ptr)));
    response.deinit();
    return networkStatus(.ok);
}

pub export fn sa_http_server_free_v2(server: ?*anyopaque) u32 {
    const server_ptr = server orelse return networkStatus(.invalid);
    const srv = @as(*HttpServer, @ptrCast(@alignCast(server_ptr)));
    srv.deinit();
    return networkStatus(.ok);
}

pub export fn sa_http_server_websocket_upgrade_v2(req: ?*anyopaque, out_ws: ?*?*anyopaque) u32 {
    const slot = out_ws orelse return networkStatus(.invalid);
    slot.* = null;
    const req_ptr = req orelse return networkStatus(.invalid);
    const request = @as(*HttpRequest, @ptrCast(@alignCast(req_ptr)));
    const version = findHeader(request, "sec-websocket-version") orelse return networkStatus(.invalid);
    const key = findHeader(request, "sec-websocket-key") orelse return networkStatus(.invalid);
    if (!std.mem.eql(u8, version, "13") or !validWebSocketKey(key)) return networkStatus(.invalid);

    var raw_ws: ?*anyopaque = null;
    if (sa_http_server_websocket_upgrade(req, &raw_ws) != @intFromEnum(plugin_api.AbiStatus.ok)) return networkStatus(.invalid);
    const handle = @as(*WebSocketHandle, @ptrCast(@alignCast(raw_ws orelse return networkStatus(.io_error))));
    handle.enableV2() catch {
        handle.deinit();
        return networkStatus(.io_error);
    };
    slot.* = raw_ws;
    return networkStatus(.ok);
}

pub export fn sa_http_server_websocket_poll_v2(ws: ?*anyopaque, interests: u32, timeout_ms: u32, out_events: ?*u32) u32 {
    const events_slot = out_events orelse return networkStatus(.invalid);
    events_slot.* = 0;
    const ws_ptr = ws orelse return networkStatus(.invalid);
    const handle = @as(*WebSocketHandle, @ptrCast(@alignCast(ws_ptr)));
    return networkStatus(core.pollWebSocketV2(handle, interests, timeout_ms, events_slot));
}

pub export fn sa_http_server_websocket_read_v2(ws: ?*anyopaque, max_len: u64, out_opcode: ?*u8, out_ptr: ?*?[*]const u8, out_len: ?*u64) u32 {
    const opcode_slot = out_opcode orelse return networkStatus(.invalid);
    const ptr_slot = out_ptr orelse return networkStatus(.invalid);
    const len_slot = out_len orelse return networkStatus(.invalid);
    opcode_slot.* = 0;
    ptr_slot.* = null;
    len_slot.* = 0;
    const ws_ptr = ws orelse return networkStatus(.invalid);
    const handle = @as(*WebSocketHandle, @ptrCast(@alignCast(ws_ptr)));
    return networkStatus(core.readFrameV2(handle, max_len, opcode_slot, ptr_slot, len_slot));
}

pub export fn sa_http_server_websocket_write_v2(ws: ?*anyopaque, opcode: u8, data_ptr: ?[*]const u8, data_len: u64, out_written: ?*u64) u32 {
    const written_slot = out_written orelse return networkStatus(.invalid);
    written_slot.* = 0;
    const ws_ptr = ws orelse return networkStatus(.invalid);
    if (data_len > max_v2_message_bytes) return networkStatus(.too_large);
    const payload = if (data_ptr) |ptr| ptr[0..@intCast(data_len)] else blk: {
        if (data_len != 0) return networkStatus(.invalid);
        break :blk "";
    };
    const handle = @as(*WebSocketHandle, @ptrCast(@alignCast(ws_ptr)));
    const status = core.writeFrameV2(handle, opcode, payload);
    if (status == .ok) written_slot.* = data_len;
    return networkStatus(status);
}

pub export fn sa_http_server_websocket_close_v2(ws: ?*anyopaque, code: u16, reason_ptr: ?[*]const u8, reason_len: u64) u32 {
    const ws_ptr = ws orelse return networkStatus(.invalid);
    if (reason_len > 123) return networkStatus(.too_large);
    const reason = if (reason_ptr) |ptr| ptr[0..@intCast(reason_len)] else blk: {
        if (reason_len != 0) return networkStatus(.invalid);
        break :blk "";
    };
    const handle = @as(*WebSocketHandle, @ptrCast(@alignCast(ws_ptr)));
    return networkStatus(core.closeWebSocketV2(handle, code, reason));
}

pub export fn sa_http_server_websocket_free_v2(ws: ?*anyopaque) u32 {
    const ws_ptr = ws orelse return networkStatus(.invalid);
    const handle = @as(*WebSocketHandle, @ptrCast(@alignCast(ws_ptr)));
    handle.deinit();
    return networkStatus(.ok);
}
