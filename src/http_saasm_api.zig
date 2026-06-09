const std = @import("std");
const plugin_api = @import("plugin_api");
const core = @import("vite_api.zig");

const ensureProcessSignalSafety = core.ensureProcessSignalSafety;
pub const HttpServer = core.HttpServer;
pub const HttpRequest = core.HttpRequest;
pub const HttpResponse = core.HttpResponse;
pub const HttpStreamResponse = core.HttpStreamResponse;
pub const WebSocketHandle = core.WebSocketHandle;
const findHeader = core.findHeader;
const headerContainsToken = core.headerContainsToken;
const computeWebSocketAccept = core.computeWebSocketAccept;
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
    const body = body_ptr orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const response = @as(*HttpResponse, @ptrCast(@alignCast(resp_ptr)));
    response.send(body[0..@intCast(body_len)]) catch return @intFromEnum(plugin_api.AbiStatus.failed);
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
    const body = body_ptr orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const response = @as(*HttpStreamResponse, @ptrCast(@alignCast(resp_ptr)));
    if (response.ended) return @intFromEnum(plugin_api.AbiStatus.failed);
    response.writeChunk(body[0..@intCast(body_len)]) catch return @intFromEnum(plugin_api.AbiStatus.failed);
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
    const accept = computeWebSocketAccept(key, &accept_buf);

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
