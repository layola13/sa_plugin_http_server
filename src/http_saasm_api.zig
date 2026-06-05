const std = @import("std");
const plugin_api = @import("plugin_api");

var sigpipe_once = std.once(installSigpipeHandler);

fn noopSigpipe(_: i32) callconv(.c) void {}

fn installSigpipeHandler() void {
    if (comptime @hasDecl(std.posix.SIG, "PIPE")) {
        const act: std.posix.Sigaction = .{
            .handler = .{ .handler = noopSigpipe },
            .mask = std.posix.empty_sigset,
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.PIPE, &act, null);
    }
}

fn ensureProcessSignalSafety() void {
    sigpipe_once.call();
}

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

const Header = struct {
    name: []u8,
    value: []u8,
};

const WebSocketOpcode = enum(u8) {
    continuation = 0,
    text = 1,
    binary = 2,
    connection_close = 8,
    ping = 9,
    pong = 10,
};

pub const HttpServer = struct {
    allocator: std.mem.Allocator,
    server: ?std.net.Server = null,

    fn init(allocator: std.mem.Allocator) !*HttpServer {
        const self = try allocator.create(HttpServer);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .server = null,
        };
        return self;
    }

    fn start(self: *HttpServer, host: []const u8, port: u16) !void {
        if (self.server != null) return;
        const address = try std.net.Address.parseIp(host, port);
        self.server = try address.listen(.{ .reuse_address = true });
    }

    fn accept(self: *HttpServer) !*HttpRequest {
        var listener = self.server orelse return error.NotFound;
        const accepted = try listener.accept();

        var request_buffer: [4096]u8 = undefined;
        var http_server = std.http.Server.init(accepted, &request_buffer);
        var std_request = try http_server.receiveHead();

        const request = try self.allocator.create(HttpRequest);
        errdefer self.allocator.destroy(request);

        const method = try methodStringAlloc(self.allocator, std_request.head.method);
        errdefer self.allocator.free(method);

        const target = try self.allocator.dupe(u8, std_request.head.target);
        errdefer self.allocator.free(target);

        var headers = std.ArrayList(Header).init(self.allocator);
        errdefer headers.deinit();
        var it = std_request.iterateHeaders();
        while (it.next()) |header| {
            try headers.append(.{
                .name = try self.allocator.dupe(u8, header.name),
                .value = try self.allocator.dupe(u8, header.value),
            });
        }

        var body = std.ArrayList(u8).init(self.allocator);
        errdefer body.deinit();
        const reader = try std_request.reader();
        try reader.readAllArrayList(&body, 2 * 1024 * 1024);

        request.* = .{
            .allocator = self.allocator,
            .connection = accepted,
            .method = method,
            .target = target,
            .headers = try headers.toOwnedSlice(),
            .body = try body.toOwnedSlice(),
        };
        return request;
    }

    fn deinit(self: *HttpServer) void {
        if (self.server) |*server| server.deinit();
        self.allocator.destroy(self);
    }
};

pub const HttpRequest = struct {
    allocator: std.mem.Allocator,
    connection: std.net.Server.Connection,
    method: []u8,
    target: []u8,
    headers: []Header,
    body: []u8,

    fn freeResources(self: *HttpRequest) void {
        for (self.headers) |header| {
            self.allocator.free(header.name);
            self.allocator.free(header.value);
        }
        self.allocator.free(self.headers);
        self.allocator.free(self.method);
        self.allocator.free(self.target);
        if (self.body.len != 0) self.allocator.free(self.body);
    }

    fn deinit(self: *HttpRequest) void {
        self.connection.stream.close();
        self.freeResources();
        self.allocator.destroy(self);
    }
};

pub const HttpResponse = struct {
    allocator: std.mem.Allocator,
    request: *HttpRequest,
    status: u16,
    content_type: []const u8 = "text/plain",
    sent: bool = false,

    fn deinit(self: *HttpResponse) void {
        self.allocator.destroy(self);
    }
};

pub const HttpStreamResponse = struct {
    allocator: std.mem.Allocator,
    request: *HttpRequest,
    sent_head: bool = false,
    ended: bool = false,

    fn init(request: *HttpRequest, status: u16) !*HttpStreamResponse {
        const self = try request.allocator.create(HttpStreamResponse);
        errdefer request.allocator.destroy(self);
        self.* = .{
            .allocator = request.allocator,
            .request = request,
            .sent_head = false,
            .ended = false,
        };
        try self.sendHead(status);
        return self;
    }

    fn sendHead(self: *HttpStreamResponse, status: u16) !void {
        if (self.sent_head) return;
        var header_buf: [256]u8 = undefined;
        const header = try std.fmt.bufPrint(&header_buf,
            "HTTP/1.1 {d} {s}\r\ncontent-type: text/event-stream\r\ntransfer-encoding: chunked\r\nconnection: close\r\n\r\n",
            .{ status, statusText(status) },
        );
        try self.request.connection.stream.writeAll(header);
        self.sent_head = true;
    }

    fn writeChunk(self: *HttpStreamResponse, bytes: []const u8) !void {
        if (!self.sent_head) try self.sendHead(200);
        var size_buf: [32]u8 = undefined;
        const size = try std.fmt.bufPrint(&size_buf, "{x}\r\n", .{bytes.len});
        try self.request.connection.stream.writeAll(size);
        try self.request.connection.stream.writeAll(bytes);
        try self.request.connection.stream.writeAll("\r\n");
    }

    fn flush(self: *HttpStreamResponse) !void {
        _ = self;
    }

    fn endChunked(self: *HttpStreamResponse) !void {
        if (self.ended) return;
        try self.request.connection.stream.writeAll("0\r\n\r\n");
        self.ended = true;
    }

    fn deinit(self: *HttpStreamResponse) void {
        self.allocator.destroy(self);
    }
};

pub const WebSocketHandle = struct {
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    last_message: ?[]u8 = null,

    fn initFromRequest(request: *HttpRequest) !*WebSocketHandle {
        const self = try request.allocator.create(WebSocketHandle);
        self.* = .{
            .allocator = request.allocator,
            .stream = request.connection.stream,
        };
        return self;
    }

    fn deinit(self: *WebSocketHandle) void {
        if (self.last_message) |message| self.allocator.free(message);
        self.stream.close();
        self.allocator.destroy(self);
    }
};

fn statusText(status: u16) []const u8 {
    return switch (status) {
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        400 => "Bad Request",
        401 => "Unauthorized",
        404 => "Not Found",
        500 => "Internal Server Error",
        else => "OK",
    };
}

fn findHeader(request: *HttpRequest, name: []const u8) ?[]const u8 {
    for (request.headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    }
    return null;
}

fn headerContainsToken(value: []const u8, token: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, value, " \t,");
    while (it.next()) |part| {
        if (std.ascii.eqlIgnoreCase(part, token)) return true;
    }
    return false;
}

fn computeWebSocketAccept(key: []const u8, out: *[28]u8) []const u8 {
    var sha1 = std.crypto.hash.Sha1.init(.{});
    sha1.update(key);
    sha1.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
    var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    sha1.final(&digest);
    return std.base64.standard.Encoder.encode(out, &digest);
}

fn maskInPlace(bytes: []u8, mask: [4]u8) void {
    for (bytes, 0..) |*byte, index| {
        byte.* ^= mask[index & 3];
    }
}

fn readExact(stream: std.net.Stream, buffer: []u8) bool {
    var index: usize = 0;
    while (index < buffer.len) {
        const read_n = stream.read(buffer[index..]) catch return false;
        if (read_n == 0) return false;
        index += read_n;
    }
    return true;
}

fn writeExact(stream: std.net.Stream, bytes: []const u8) bool {
    stream.writeAll(bytes) catch return false;
    return true;
}

fn writeFrame(stream: std.net.Stream, opcode: u8, payload: []const u8) bool {
    var header: [10]u8 = undefined;
    header[0] = 0x80 | (opcode & 0x0f);
    var header_len: usize = 2;
    if (payload.len <= 125) {
        header[1] = @intCast(payload.len);
    } else if (payload.len <= 0xffff) {
        header[1] = 126;
        std.mem.writeInt(u16, header[2..4], @as(u16, @intCast(payload.len)), .big);
        header_len = 4;
    } else {
        header[1] = 127;
        std.mem.writeInt(u64, header[2..10], @as(u64, payload.len), .big);
        header_len = 10;
    }
    if (!writeExact(stream, header[0..header_len])) return false;
    if (payload.len > 0) return writeExact(stream, payload);
    return true;
}

fn readFrame(handle: *WebSocketHandle, max_len: u64, out_opcode: ?*u8, out_ptr: ?*?[*]const u8, out_len: ?*u64) u32 {
    const opcode_slot = out_opcode orelse return 2;
    const ptr_slot = out_ptr orelse return 2;
    const len_slot = out_len orelse return 2;

    while (true) {
        var header: [2]u8 = undefined;
        if (!readExact(handle.stream, &header)) return 2;
        const fin = (header[0] & 0x80) != 0;
        const opcode = header[0] & 0x0f;
        const masked = (header[1] & 0x80) != 0;
        if (!fin or !masked) return 2;

        var payload_len: u64 = header[1] & 0x7f;
        if (payload_len == 126) {
            var extended: [2]u8 = undefined;
            if (!readExact(handle.stream, &extended)) return 2;
            payload_len = std.mem.readInt(u16, &extended, .big);
        } else if (payload_len == 127) {
            var extended: [8]u8 = undefined;
            if (!readExact(handle.stream, &extended)) return 2;
            payload_len = std.mem.readInt(u64, &extended, .big);
        }
        if (payload_len > max_len or payload_len > std.math.maxInt(usize)) return 2;

        var mask_key: [4]u8 = undefined;
        if (!readExact(handle.stream, &mask_key)) return 2;

        var payload: []u8 = &.{};
        if (payload_len > 0) {
            if (handle.last_message) |message| handle.allocator.free(message);
            handle.last_message = null;
            payload = handle.allocator.alloc(u8, @intCast(payload_len)) catch return 2;
            errdefer handle.allocator.free(payload);
            if (!readExact(handle.stream, payload)) return 2;
            maskInPlace(payload, mask_key);
        }

        switch (opcode) {
            @intFromEnum(WebSocketOpcode.ping) => {
                if (!writeFrame(handle.stream, @intFromEnum(WebSocketOpcode.pong), payload)) {
                    if (payload.len > 0) handle.allocator.free(payload);
                    return 2;
                }
                if (payload.len > 0) handle.allocator.free(payload);
                continue;
            },
            @intFromEnum(WebSocketOpcode.pong) => {
                if (payload.len > 0) handle.allocator.free(payload);
                continue;
            },
            @intFromEnum(WebSocketOpcode.connection_close), @intFromEnum(WebSocketOpcode.text), @intFromEnum(WebSocketOpcode.binary) => {
                opcode_slot.* = opcode;
                if (payload.len == 0) {
                    if (handle.last_message) |message| handle.allocator.free(message);
                    handle.last_message = null;
                    ptr_slot.* = null;
                    len_slot.* = 0;
                } else {
                    if (handle.last_message) |message| handle.allocator.free(message);
                    handle.last_message = payload;
                    ptr_slot.* = payload.ptr;
                    len_slot.* = payload.len;
                }
                return 0;
            },
            else => {
                if (payload.len > 0) handle.allocator.free(payload);
                return 2;
            },
        }
    }
}

fn methodStringAlloc(allocator: std.mem.Allocator, method: std.http.Method) ![]u8 {
    var buf: [24]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try method.write(stream.writer());
    return allocator.dupe(u8, stream.getWritten());
}

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
    const response = request.allocator.create(HttpResponse) catch return @intFromEnum(plugin_api.AbiStatus.failed);
        response.* = .{
            .allocator = request.allocator,
            .request = request,
            .status = status,
            .content_type = "text/plain",
        };
    slot.* = @ptrCast(response);
    return @intFromEnum(plugin_api.AbiStatus.ok);
}

pub export fn sa_http_server_resp_send(resp: ?*anyopaque, body_ptr: ?[*]const u8, body_len: u64) u32 {
    const resp_ptr = resp orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const body = body_ptr orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const response = @as(*HttpResponse, @ptrCast(@alignCast(resp_ptr)));
    if (response.sent) return @intFromEnum(plugin_api.AbiStatus.failed);

    const payload = body[0..@intCast(body_len)];
    const conn = &response.request.connection;
    var header_buf: [256]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf,
        "HTTP/1.1 {d} {s}\r\ncontent-length: {d}\r\ncontent-type: {s}\r\nconnection: close\r\n\r\n",
        .{ response.status, statusText(response.status), payload.len, response.content_type },
    ) catch return @intFromEnum(plugin_api.AbiStatus.failed);
    conn.stream.writeAll(header) catch return @intFromEnum(plugin_api.AbiStatus.failed);
    conn.stream.writeAll(payload) catch return @intFromEnum(plugin_api.AbiStatus.failed);
    response.sent = true;
    return @intFromEnum(plugin_api.AbiStatus.ok);
}

pub export fn sa_http_server_resp_set_content_type(resp: ?*anyopaque, content_type_ptr: ?[*]const u8, content_type_len: u64) u32 {
    const resp_ptr = resp orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const content_type = content_type_ptr orelse return @intFromEnum(plugin_api.AbiStatus.failed);
    const response = @as(*HttpResponse, @ptrCast(@alignCast(resp_ptr)));
    if (response.sent) return @intFromEnum(plugin_api.AbiStatus.failed);
    response.content_type = content_type[0..@intCast(content_type_len)];
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
