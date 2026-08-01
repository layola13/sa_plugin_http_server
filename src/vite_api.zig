const std = @import("std");
const sa_std_net = @import("sa_std_net.zig");

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

pub fn ensureProcessSignalSafety() void {
    sigpipe_once.call();
}

pub const Header = struct {
    name: []u8,
    value: []u8,
};

pub const max_v2_message_bytes: usize = 16 * 1024 * 1024;

pub const NetworkStatus = enum(u32) {
    ok = 0,
    would_block = 1,
    closed = 2,
    timeout = 3,
    too_large = 4,
    invalid = 5,
    io_error = 6,
};

pub const PollEvent = struct {
    pub const readable: u32 = 1;
    pub const writable: u32 = 2;
    pub const closed: u32 = 4;
};

fn timeoutMillis(timeout_ms: u32) i32 {
    return @intCast(@min(timeout_ms, @as(u32, @intCast(std.math.maxInt(i32)))));
}

pub fn statusFromError(err: anyerror) NetworkStatus {
    return switch (err) {
        error.WouldBlock => .would_block,
        error.EndOfStream,
        error.BrokenPipe,
        error.ConnectionAborted,
        error.ConnectionResetByPeer,
        error.NotOpenForReading,
        error.NotOpenForWriting,
        error.HttpConnectionClosing,
        error.HttpRequestTruncated,
        => .closed,
        error.BodyTooLarge, error.StreamTooLong => .too_large,
        error.InvalidCharacter,
        error.InvalidContentLength,
        error.InvalidWebSocketFrame,
        error.HttpHeadersInvalid,
        error.HttpHeadersOversize,
        error.InvalidArgument,
        => .invalid,
        else => .io_error,
    };
}

pub fn pollStream(stream: std.net.Stream, events: i16, timeout_ms: u32, out_events: ?*u32) NetworkStatus {
    if (out_events) |slot| slot.* = 0;
    var poll_fds = [1]std.posix.pollfd{.{
        .fd = stream.handle,
        .events = events,
        .revents = 0,
    }};
    const ready = std.posix.poll(&poll_fds, timeoutMillis(timeout_ms)) catch return .io_error;
    if (ready == 0) return if (timeout_ms == 0) .would_block else .timeout;

    const revents = poll_fds[0].revents;
    if (revents & (std.posix.POLL.ERR | std.posix.POLL.NVAL) != 0) return .io_error;

    var result: u32 = 0;
    if (revents & std.posix.POLL.IN != 0) result |= PollEvent.readable;
    if (revents & std.posix.POLL.OUT != 0) result |= PollEvent.writable;
    if (revents & std.posix.POLL.HUP != 0) result |= PollEvent.closed;
    if (out_events) |slot| slot.* = result;
    if (result & (PollEvent.readable | PollEvent.writable) != 0) return .ok;
    if (result & PollEvent.closed != 0) return .closed;
    return .would_block;
}

fn setNonBlocking(stream: std.net.Stream) !void {
    const flags = try std.posix.fcntl(stream.handle, std.posix.F.GETFL, 0);
    const nonblocking = flags | (@as(usize, 1) << @bitOffsetOf(std.posix.O, "NONBLOCK"));
    _ = try std.posix.fcntl(stream.handle, std.posix.F.SETFL, nonblocking);
}

fn setReceiveTimeout(stream: std.net.Stream, timeout_ms: u32) !void {
    if (timeout_ms == 0) return setNonBlocking(stream);
    const timeout = std.posix.timeval{
        .sec = @intCast(timeout_ms / 1000),
        .usec = @intCast((timeout_ms % 1000) * 1000),
    };
    try std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout));
}

fn validHeaderName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |ch| {
        const valid = std.ascii.isAlphanumeric(ch) or switch (ch) {
            '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
            else => false,
        };
        if (!valid) return false;
    }
    return true;
}

fn validHeaderValue(value: []const u8) bool {
    for (value) |ch| {
        if ((ch < 0x20 and ch != '\t') or ch == 0x7f) return false;
    }
    return true;
}

const ResponseHeaderBag = struct {
    allocator: std.mem.Allocator,
    content_type: []const u8,
    owns_content_type: bool = false,
    extra: std.ArrayList(Header),
    byte_len: usize = 0,

    fn init(allocator: std.mem.Allocator, content_type: []const u8) ResponseHeaderBag {
        return .{
            .allocator = allocator,
            .content_type = content_type,
            .extra = std.ArrayList(Header).init(allocator),
        };
    }

    fn deinit(self: *ResponseHeaderBag) void {
        if (self.owns_content_type) self.allocator.free(self.content_type);
        for (self.extra.items) |header| {
            self.allocator.free(header.name);
            self.allocator.free(header.value);
        }
        self.extra.deinit();
    }

    fn setContentType(self: *ResponseHeaderBag, value: []const u8) !void {
        if (!validHeaderValue(value)) return error.InvalidArgument;
        const total = std.math.add(usize, value.len, self.byte_len) catch return error.StreamTooLong;
        if (total > max_v2_message_bytes) return error.StreamTooLong;
        const owned = try self.allocator.dupe(u8, value);
        if (self.owns_content_type) self.allocator.free(self.content_type);
        self.content_type = owned;
        self.owns_content_type = true;
    }

    fn add(self: *ResponseHeaderBag, name: []const u8, value: []const u8) !void {
        if (!validHeaderName(name) or !validHeaderValue(value)) return error.InvalidArgument;
        if (std.ascii.eqlIgnoreCase(name, "content-type")) return self.setContentType(value);
        if (std.ascii.eqlIgnoreCase(name, "content-length") or
            std.ascii.eqlIgnoreCase(name, "connection") or
            std.ascii.eqlIgnoreCase(name, "transfer-encoding")) return error.InvalidArgument;

        const new_size = std.math.add(usize, name.len, value.len) catch return error.StreamTooLong;
        const with_content_type = std.math.add(usize, self.content_type.len, self.byte_len) catch return error.StreamTooLong;
        const total = std.math.add(usize, with_content_type, new_size) catch return error.StreamTooLong;
        if (total > max_v2_message_bytes) return error.StreamTooLong;
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned_value);
        try self.extra.append(.{ .name = owned_name, .value = owned_value });
        self.byte_len += new_size;
    }

    fn write(self: *const ResponseHeaderBag, writer: anytype) !void {
        try writer.print("content-type: {s}\r\n", .{self.content_type});
        for (self.extra.items) |header| {
            try writer.print("{s}: {s}\r\n", .{ header.name, header.value });
        }
    }
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

    pub fn init(allocator: std.mem.Allocator) !*HttpServer {
        const self = try allocator.create(HttpServer);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .server = null,
        };
        return self;
    }

    pub fn start(self: *HttpServer, host: []const u8, port: u16) !void {
        try self.startWithOptions(host, port, .{ .reuse_address = true });
    }

    pub fn startWithOptions(self: *HttpServer, host: []const u8, port: u16, options: std.net.Address.ListenOptions) !void {
        if (self.server != null) return;
        const address = try std.net.Address.parseIp(host, port);
        self.server = try address.listen(options);
    }

    pub fn accept(self: *HttpServer) !*HttpRequest {
        return self.acceptConfigured(2 * 1024 * 1024, null);
    }

    pub fn pollAccept(self: *HttpServer, timeout_ms: u32) NetworkStatus {
        const listener = &(self.server orelse return .invalid);
        return pollStream(listener.stream, std.posix.POLL.IN, timeout_ms, null);
    }

    pub fn acceptWithBodyLimit(self: *HttpServer, max_body_len: usize) !*HttpRequest {
        return self.acceptConfigured(max_body_len, null);
    }

    pub fn acceptWithBodyLimitAndTimeout(self: *HttpServer, max_body_len: usize, timeout_ms: u32) !*HttpRequest {
        return self.acceptConfigured(max_body_len, timeout_ms);
    }

    fn acceptConfigured(self: *HttpServer, max_body_len: usize, receive_timeout_ms: ?u32) !*HttpRequest {
        const listener = &(self.server orelse return error.NotFound);
        const accepted = try listener.accept();
        errdefer accepted.stream.close();
        if (receive_timeout_ms) |timeout_ms| try setReceiveTimeout(accepted.stream, timeout_ms);

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
        var content_length: usize = 0;
        var it = std_request.iterateHeaders();
        while (it.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "content-length")) {
                content_length = std.fmt.parseInt(usize, header.value, 10) catch return error.InvalidContentLength;
            }
            try headers.append(.{
                .name = try self.allocator.dupe(u8, header.name),
                .value = try self.allocator.dupe(u8, header.value),
            });
        }

        var body = std.ArrayList(u8).init(self.allocator);
        errdefer body.deinit();
        if (content_length > 0) {
            if (content_length > max_body_len) return error.BodyTooLarge;
            const reader = try std_request.reader();
            try body.ensureTotalCapacity(content_length);
            try reader.readNoEof(body.unusedCapacitySlice()[0..content_length]);
            body.items.len = content_length;
        }

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

    pub fn deinit(self: *HttpServer) void {
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

    pub fn freeResources(self: *HttpRequest) void {
        for (self.headers) |header| {
            self.allocator.free(header.name);
            self.allocator.free(header.value);
        }
        self.allocator.free(self.headers);
        self.allocator.free(self.method);
        self.allocator.free(self.target);
        if (self.body.len != 0) self.allocator.free(self.body);
    }

    pub fn deinit(self: *HttpRequest) void {
        self.connection.stream.close();
        self.freeResources();
        self.allocator.destroy(self);
    }
};

pub const HttpResponse = struct {
    allocator: std.mem.Allocator,
    request: *HttpRequest,
    status: u16,
    headers: ResponseHeaderBag,
    sent: bool = false,

    pub fn init(request: *HttpRequest, status: u16) !*HttpResponse {
        const self = try request.allocator.create(HttpResponse);
        self.* = .{
            .allocator = request.allocator,
            .request = request,
            .status = status,
            .headers = ResponseHeaderBag.init(request.allocator, "text/plain"),
        };
        return self;
    }

    pub fn setContentType(self: *HttpResponse, content_type: []const u8) !void {
        if (self.sent) return error.ResponseAlreadySent;
        try self.headers.setContentType(content_type);
    }

    pub fn setHeader(self: *HttpResponse, name: []const u8, value: []const u8) !void {
        if (self.sent) return error.ResponseAlreadySent;
        try self.headers.add(name, value);
    }

    pub fn send(self: *HttpResponse, body: []const u8) !void {
        if (self.sent) return error.ResponseAlreadySent;
        var head = std.ArrayList(u8).init(self.allocator);
        defer head.deinit();
        const writer = head.writer();
        try writer.print("HTTP/1.1 {d} {s}\r\ncontent-length: {d}\r\n", .{ self.status, statusText(self.status), body.len });
        try self.headers.write(writer);
        try writer.writeAll("connection: close\r\n\r\n");
        try writer.writeAll(body);
        try self.request.connection.stream.writeAll(head.items);
        self.sent = true;
    }

    pub fn deinit(self: *HttpResponse) void {
        self.headers.deinit();
        self.allocator.destroy(self);
    }
};

pub const HttpStreamResponse = struct {
    allocator: std.mem.Allocator,
    request: *HttpRequest,
    status: u16,
    headers: ResponseHeaderBag,
    sent_head: bool = false,
    ended: bool = false,

    pub fn init(request: *HttpRequest, status: u16) !*HttpStreamResponse {
        const self = try initDeferred(request, status);
        errdefer self.deinit();
        try self.sendHead(status);
        return self;
    }

    pub fn initDeferred(request: *HttpRequest, status: u16) !*HttpStreamResponse {
        const self = try request.allocator.create(HttpStreamResponse);
        errdefer request.allocator.destroy(self);
        self.* = .{
            .allocator = request.allocator,
            .request = request,
            .status = status,
            .headers = ResponseHeaderBag.init(request.allocator, "text/event-stream"),
            .sent_head = false,
            .ended = false,
        };
        return self;
    }

    pub fn setHeader(self: *HttpStreamResponse, name: []const u8, value: []const u8) !void {
        if (self.sent_head) return error.ResponseAlreadySent;
        try self.headers.add(name, value);
    }

    pub fn sendHead(self: *HttpStreamResponse, status: u16) !void {
        if (self.sent_head) return;
        var head = std.ArrayList(u8).init(self.allocator);
        defer head.deinit();
        const writer = head.writer();
        try writer.print("HTTP/1.1 {d} {s}\r\n", .{ status, statusText(status) });
        try self.headers.write(writer);
        try writer.writeAll("transfer-encoding: chunked\r\nconnection: close\r\n\r\n");
        try self.request.connection.stream.writeAll(head.items);
        self.sent_head = true;
    }

    pub fn writeChunk(self: *HttpStreamResponse, bytes: []const u8) !void {
        if (!self.sent_head) try self.sendHead(self.status);
        var size_buf: [32]u8 = undefined;
        const size = try std.fmt.bufPrint(&size_buf, "{x}\r\n", .{bytes.len});
        try self.request.connection.stream.writeAll(size);
        try self.request.connection.stream.writeAll(bytes);
        try self.request.connection.stream.writeAll("\r\n");
    }

    pub fn flush(self: *HttpStreamResponse) !void {
        _ = self;
    }

    pub fn endChunked(self: *HttpStreamResponse) !void {
        if (self.ended) return;
        if (!self.sent_head) try self.sendHead(self.status);
        try self.request.connection.stream.writeAll("0\r\n\r\n");
        self.ended = true;
    }

    pub fn deinit(self: *HttpStreamResponse) void {
        self.headers.deinit();
        self.allocator.destroy(self);
    }
};

pub const WebSocketHandle = struct {
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    last_message: ?[]u8 = null,
    incoming: std.ArrayList(u8),
    fragmented: std.ArrayList(u8),
    fragmented_opcode: ?u8 = null,
    pending_write: ?[]u8 = null,
    pending_offset: usize = 0,
    v2_mode: bool = false,
    close_sent: bool = false,
    close_received: bool = false,
    peer_closed: bool = false,

    pub fn initFromRequest(request: *HttpRequest) !*WebSocketHandle {
        const self = try request.allocator.create(WebSocketHandle);
        self.* = .{
            .allocator = request.allocator,
            .stream = request.connection.stream,
            .incoming = std.ArrayList(u8).init(request.allocator),
            .fragmented = std.ArrayList(u8).init(request.allocator),
        };
        return self;
    }

    pub fn enableV2(self: *WebSocketHandle) !void {
        if (self.v2_mode) return;
        try setNonBlocking(self.stream);
        self.v2_mode = true;
    }

    pub fn deinit(self: *WebSocketHandle) void {
        if (self.last_message) |message| self.allocator.free(message);
        if (self.pending_write) |pending| self.allocator.free(pending);
        self.incoming.deinit();
        self.fragmented.deinit();
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

pub fn findHeader(request: *HttpRequest, name: []const u8) ?[]const u8 {
    for (request.headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    }
    return null;
}

pub fn headerContainsToken(value: []const u8, token: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, value, " \t,");
    while (it.next()) |part| {
        if (std.ascii.eqlIgnoreCase(part, token)) return true;
    }
    return false;
}

fn writeExact(stream: std.net.Stream, bytes: []const u8) bool {
    stream.writeAll(bytes) catch return false;
    return true;
}

pub fn writeFrame(stream: std.net.Stream, opcode: u8, payload: []const u8) bool {
    const frame_cap = std.math.add(usize, payload.len, 14) catch return false;
    const frame = std.heap.page_allocator.alloc(u8, frame_cap) catch return false;
    defer std.heap.page_allocator.free(frame);
    const frame_len = sa_std_net.buildWebSocketFrame(frame, opcode, payload, null) catch return false;
    return writeExact(stream, frame[0..frame_len]);
}

pub fn readFrame(handle: *WebSocketHandle, max_len: u64, out_opcode: ?*u8, out_ptr: ?*?[*]const u8, out_len: ?*u64) u32 {
    const opcode_slot = out_opcode orelse return 2;
    const ptr_slot = out_ptr orelse return 2;
    const len_slot = out_len orelse return 2;

    while (true) {
        const frame = sa_std_net.readWebSocketFrameAlloc(handle.allocator, handle.stream, max_len, true) catch return 2;
        const opcode = frame.opcode;
        const payload = frame.payload;
        if (payload.len > 0) {
            if (handle.last_message) |message| handle.allocator.free(message);
            handle.last_message = null;
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

const ParsedV2Frame = struct {
    fin: bool,
    opcode: u8,
    payload: []u8,
};

fn decodeV2Frame(handle: *WebSocketHandle, max_len: usize) !?ParsedV2Frame {
    const bytes = handle.incoming.items;
    if (bytes.len < 2) return null;
    if ((bytes[0] & 0x70) != 0) return error.InvalidWebSocketFrame;

    const fin = bytes[0] & 0x80 != 0;
    const opcode = bytes[0] & 0x0f;
    const masked = bytes[1] & 0x80 != 0;
    if (!masked) return error.InvalidWebSocketFrame;

    var payload_len: u64 = bytes[1] & 0x7f;
    var offset: usize = 2;
    if (payload_len == 126) {
        if (bytes.len < 4) return null;
        payload_len = std.mem.readInt(u16, bytes[2..4], .big);
        if (payload_len < 126) return error.InvalidWebSocketFrame;
        offset = 4;
    } else if (payload_len == 127) {
        if (bytes.len < 10) return null;
        payload_len = std.mem.readInt(u64, bytes[2..10], .big);
        if (payload_len < 65536 or payload_len & (@as(u64, 1) << 63) != 0) return error.InvalidWebSocketFrame;
        offset = 10;
    }
    if (payload_len > max_len or payload_len > max_v2_message_bytes) return error.StreamTooLong;
    if (opcode >= 8 and (!fin or payload_len > 125)) return error.InvalidWebSocketFrame;
    if (opcode != 0 and opcode != 1 and opcode != 2 and opcode != 8 and opcode != 9 and opcode != 10) return error.InvalidWebSocketFrame;

    const payload_len_usize: usize = @intCast(payload_len);
    const frame_len = std.math.add(usize, offset + 4, payload_len_usize) catch return error.StreamTooLong;
    if (bytes.len < frame_len) return null;
    const mask = bytes[offset..][0..4].*;
    offset += 4;

    var payload: []u8 = &.{};
    if (payload_len_usize != 0) {
        payload = try handle.allocator.alloc(u8, payload_len_usize);
        @memcpy(payload, bytes[offset .. offset + payload_len_usize]);
        for (payload, 0..) |*byte, idx| byte.* ^= mask[idx & 3];
    }

    const remaining = bytes.len - frame_len;
    std.mem.copyForwards(u8, handle.incoming.items[0..remaining], handle.incoming.items[frame_len..]);
    handle.incoming.items.len = remaining;
    return .{ .fin = fin, .opcode = opcode, .payload = payload };
}

fn replaceLastMessage(handle: *WebSocketHandle, payload: []u8, out_ptr: *?[*]const u8, out_len: *u64) void {
    if (handle.last_message) |message| handle.allocator.free(message);
    if (payload.len == 0) {
        handle.last_message = null;
        out_ptr.* = null;
        out_len.* = 0;
    } else {
        handle.last_message = payload;
        out_ptr.* = payload.ptr;
        out_len.* = payload.len;
    }
}

fn flushPendingWrite(handle: *WebSocketHandle) NetworkStatus {
    const pending = handle.pending_write orelse return .ok;
    while (handle.pending_offset < pending.len) {
        const written = handle.stream.write(pending[handle.pending_offset..]) catch |err| return statusFromError(err);
        if (written == 0) {
            handle.peer_closed = true;
            return .closed;
        }
        handle.pending_offset += written;
    }
    handle.allocator.free(pending);
    handle.pending_write = null;
    handle.pending_offset = 0;
    return .ok;
}

fn websocketFrameSize(payload_len: usize) !usize {
    const header_len: usize = if (payload_len < 126) 2 else if (payload_len <= std.math.maxInt(u16)) 4 else 10;
    return std.math.add(usize, payload_len, header_len) catch error.StreamTooLong;
}

pub fn writeFrameV2(handle: *WebSocketHandle, opcode: u8, payload: []const u8) NetworkStatus {
    if (handle.peer_closed or handle.close_sent or handle.close_received) return .closed;
    if (payload.len > max_v2_message_bytes) return .too_large;
    if (opcode != 1 and opcode != 2 and opcode != 9 and opcode != 10) return .invalid;
    if ((opcode == @intFromEnum(WebSocketOpcode.ping) or opcode == @intFromEnum(WebSocketOpcode.pong)) and payload.len > 125) return .too_large;
    if (opcode == @intFromEnum(WebSocketOpcode.text) and !std.unicode.utf8ValidateSlice(payload)) return .invalid;
    handle.enableV2() catch return .io_error;

    const pending_status = flushPendingWrite(handle);
    if (pending_status != .ok) return pending_status;

    const frame_cap = websocketFrameSize(payload.len) catch return .too_large;
    const frame = handle.allocator.alloc(u8, frame_cap) catch return .io_error;
    const frame_len = sa_std_net.buildWebSocketFrame(frame, opcode, payload, null) catch {
        handle.allocator.free(frame);
        return .invalid;
    };
    handle.pending_write = frame[0..frame_len];
    handle.pending_offset = 0;
    const status = flushPendingWrite(handle);
    return switch (status) {
        .would_block => .ok,
        else => status,
    };
}

pub fn pollWebSocketV2(handle: *WebSocketHandle, interests: u32, timeout_ms: u32, out_events: *u32) NetworkStatus {
    out_events.* = 0;
    if (handle.peer_closed or handle.close_received) {
        out_events.* = PollEvent.closed;
        return .closed;
    }
    if (interests == 0 or interests & ~(PollEvent.readable | PollEvent.writable) != 0) return .invalid;
    handle.enableV2() catch return .io_error;

    if (interests & PollEvent.writable != 0 and handle.pending_write != null) {
        const flush_status = flushPendingWrite(handle);
        if (flush_status == .closed or flush_status == .io_error) return flush_status;
    }

    var posix_events: i16 = 0;
    if (interests & PollEvent.readable != 0) posix_events |= std.posix.POLL.IN;
    if (interests & PollEvent.writable != 0) posix_events |= std.posix.POLL.OUT;
    const poll_status = pollStream(handle.stream, posix_events, timeout_ms, out_events);
    if (poll_status != .ok) return poll_status;
    if (out_events.* & PollEvent.writable != 0 and handle.pending_write != null) {
        const flush_status = flushPendingWrite(handle);
        if (flush_status != .ok) {
            out_events.* &= ~PollEvent.writable;
            if (out_events.* & PollEvent.readable != 0) return .ok;
            return flush_status;
        }
    }
    return .ok;
}

pub fn readFrameV2(handle: *WebSocketHandle, max_len_u64: u64, out_opcode: *u8, out_ptr: *?[*]const u8, out_len: *u64) NetworkStatus {
    out_opcode.* = 0;
    out_ptr.* = null;
    out_len.* = 0;
    if (handle.peer_closed or handle.close_received) return .closed;
    handle.enableV2() catch return .io_error;
    const max_len: usize = @intCast(@min(max_len_u64, @as(u64, max_v2_message_bytes)));

    while (true) {
        const decoded = decodeV2Frame(handle, max_len) catch |err| {
            const status = statusFromError(err);
            if (status == .too_large or status == .invalid) handle.peer_closed = true;
            return status;
        };
        if (decoded) |frame| {
            switch (frame.opcode) {
                @intFromEnum(WebSocketOpcode.ping) => {
                    const pong_status = writeFrameV2(handle, @intFromEnum(WebSocketOpcode.pong), frame.payload);
                    if (frame.payload.len != 0) handle.allocator.free(frame.payload);
                    if (pong_status != .ok) return pong_status;
                    continue;
                },
                @intFromEnum(WebSocketOpcode.pong) => {
                    if (frame.payload.len != 0) handle.allocator.free(frame.payload);
                    continue;
                },
                @intFromEnum(WebSocketOpcode.connection_close) => {
                    if (frame.payload.len == 1) {
                        handle.allocator.free(frame.payload);
                        handle.peer_closed = true;
                        return .invalid;
                    }
                    if (frame.payload.len >= 2) {
                        const code = std.mem.readInt(u16, frame.payload[0..2], .big);
                        if (!validCloseCode(code) or !std.unicode.utf8ValidateSlice(frame.payload[2..])) {
                            handle.allocator.free(frame.payload);
                            handle.peer_closed = true;
                            return .invalid;
                        }
                    }
                    handle.close_received = true;
                    out_opcode.* = frame.opcode;
                    replaceLastMessage(handle, frame.payload, out_ptr, out_len);
                    return .ok;
                },
                @intFromEnum(WebSocketOpcode.text), @intFromEnum(WebSocketOpcode.binary) => {
                    if (handle.fragmented_opcode != null) {
                        if (frame.payload.len != 0) handle.allocator.free(frame.payload);
                        handle.peer_closed = true;
                        return .invalid;
                    }
                    if (frame.fin) {
                        if (frame.opcode == @intFromEnum(WebSocketOpcode.text) and !std.unicode.utf8ValidateSlice(frame.payload)) {
                            if (frame.payload.len != 0) handle.allocator.free(frame.payload);
                            handle.peer_closed = true;
                            return .invalid;
                        }
                        out_opcode.* = frame.opcode;
                        replaceLastMessage(handle, frame.payload, out_ptr, out_len);
                        return .ok;
                    }
                    handle.fragmented_opcode = frame.opcode;
                    handle.fragmented.appendSlice(frame.payload) catch {
                        if (frame.payload.len != 0) handle.allocator.free(frame.payload);
                        return .io_error;
                    };
                    if (frame.payload.len != 0) handle.allocator.free(frame.payload);
                },
                @intFromEnum(WebSocketOpcode.continuation) => {
                    const opcode = handle.fragmented_opcode orelse {
                        if (frame.payload.len != 0) handle.allocator.free(frame.payload);
                        handle.peer_closed = true;
                        return .invalid;
                    };
                    if (handle.fragmented.items.len + frame.payload.len > max_len or
                        handle.fragmented.items.len + frame.payload.len > max_v2_message_bytes)
                    {
                        if (frame.payload.len != 0) handle.allocator.free(frame.payload);
                        handle.peer_closed = true;
                        return .too_large;
                    }
                    handle.fragmented.appendSlice(frame.payload) catch {
                        if (frame.payload.len != 0) handle.allocator.free(frame.payload);
                        return .io_error;
                    };
                    if (frame.payload.len != 0) handle.allocator.free(frame.payload);
                    if (frame.fin) {
                        const message = handle.fragmented.toOwnedSlice() catch return .io_error;
                        handle.fragmented = std.ArrayList(u8).init(handle.allocator);
                        handle.fragmented_opcode = null;
                        if (opcode == @intFromEnum(WebSocketOpcode.text) and !std.unicode.utf8ValidateSlice(message)) {
                            if (message.len != 0) handle.allocator.free(message);
                            handle.peer_closed = true;
                            return .invalid;
                        }
                        out_opcode.* = opcode;
                        replaceLastMessage(handle, message, out_ptr, out_len);
                        return .ok;
                    }
                },
                else => unreachable,
            }
            continue;
        }

        if (handle.incoming.items.len >= max_v2_message_bytes + 14) {
            handle.peer_closed = true;
            return .too_large;
        }
        var buffer: [4096]u8 = undefined;
        const capacity = max_v2_message_bytes + 14 - handle.incoming.items.len;
        const read_len = @min(buffer.len, capacity);
        const count = handle.stream.read(buffer[0..read_len]) catch |err| return statusFromError(err);
        if (count == 0) {
            handle.peer_closed = true;
            return .closed;
        }
        handle.incoming.appendSlice(buffer[0..count]) catch return .io_error;
    }
}

fn validCloseCode(code: u16) bool {
    if (code < 1000 or code >= 5000) return false;
    return switch (code) {
        1004, 1005, 1006, 1015 => false,
        else => true,
    };
}

pub fn closeWebSocketV2(handle: *WebSocketHandle, code: u16, reason: []const u8) NetworkStatus {
    if (handle.peer_closed or handle.close_sent) return .closed;
    if (!validCloseCode(code) or reason.len > 123 or !std.unicode.utf8ValidateSlice(reason)) return .invalid;
    var payload: [125]u8 = undefined;
    std.mem.writeInt(u16, payload[0..2], code, .big);
    @memcpy(payload[2 .. 2 + reason.len], reason);

    handle.enableV2() catch return .io_error;
    const pending_status = flushPendingWrite(handle);
    if (pending_status != .ok) return pending_status;
    const frame_cap = websocketFrameSize(2 + reason.len) catch return .too_large;
    const frame = handle.allocator.alloc(u8, frame_cap) catch return .io_error;
    const frame_len = sa_std_net.buildWebSocketFrame(frame, @intFromEnum(WebSocketOpcode.connection_close), payload[0 .. 2 + reason.len], null) catch {
        handle.allocator.free(frame);
        return .invalid;
    };
    handle.pending_write = frame[0..frame_len];
    handle.pending_offset = 0;
    handle.close_sent = true;
    const status = flushPendingWrite(handle);
    return switch (status) {
        .would_block => .ok,
        else => status,
    };
}

fn methodStringAlloc(allocator: std.mem.Allocator, method: std.http.Method) ![]u8 {
    var buf: [24]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try method.write(stream.writer());
    return allocator.dupe(u8, stream.getWritten());
}
