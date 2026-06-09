const std = @import("std");

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
        const listener = &(self.server orelse return error.NotFound);
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
            if (content_length > 2 * 1024 * 1024) return error.BodyTooLarge;
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
    content_type: []const u8 = "text/plain",
    sent: bool = false,

    pub fn init(request: *HttpRequest, status: u16) !*HttpResponse {
        const self = try request.allocator.create(HttpResponse);
        self.* = .{
            .allocator = request.allocator,
            .request = request,
            .status = status,
            .content_type = "text/plain",
        };
        return self;
    }

    pub fn setContentType(self: *HttpResponse, content_type: []const u8) !void {
        if (self.sent) return error.ResponseAlreadySent;
        self.content_type = content_type;
    }

    pub fn send(self: *HttpResponse, body: []const u8) !void {
        if (self.sent) return error.ResponseAlreadySent;
        var header_buf: [256]u8 = undefined;
        const header = try std.fmt.bufPrint(
            &header_buf,
            "HTTP/1.1 {d} {s}\r\ncontent-length: {d}\r\ncontent-type: {s}\r\nconnection: close\r\n\r\n",
            .{ self.status, statusText(self.status), body.len, self.content_type },
        );
        try self.request.connection.stream.writeAll(header);
        try self.request.connection.stream.writeAll(body);
        self.sent = true;
    }

    pub fn deinit(self: *HttpResponse) void {
        self.allocator.destroy(self);
    }
};

pub const HttpStreamResponse = struct {
    allocator: std.mem.Allocator,
    request: *HttpRequest,
    sent_head: bool = false,
    ended: bool = false,

    pub fn init(request: *HttpRequest, status: u16) !*HttpStreamResponse {
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

    pub fn sendHead(self: *HttpStreamResponse, status: u16) !void {
        if (self.sent_head) return;
        var header_buf: [256]u8 = undefined;
        const header = try std.fmt.bufPrint(
            &header_buf,
            "HTTP/1.1 {d} {s}\r\ncontent-type: text/event-stream\r\ntransfer-encoding: chunked\r\nconnection: close\r\n\r\n",
            .{ status, statusText(status) },
        );
        try self.request.connection.stream.writeAll(header);
        self.sent_head = true;
    }

    pub fn writeChunk(self: *HttpStreamResponse, bytes: []const u8) !void {
        if (!self.sent_head) try self.sendHead(200);
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
        try self.request.connection.stream.writeAll("0\r\n\r\n");
        self.ended = true;
    }

    pub fn deinit(self: *HttpStreamResponse) void {
        self.allocator.destroy(self);
    }
};

pub const WebSocketHandle = struct {
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    last_message: ?[]u8 = null,

    pub fn initFromRequest(request: *HttpRequest) !*WebSocketHandle {
        const self = try request.allocator.create(WebSocketHandle);
        self.* = .{
            .allocator = request.allocator,
            .stream = request.connection.stream,
        };
        return self;
    }

    pub fn deinit(self: *WebSocketHandle) void {
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

pub fn computeWebSocketAccept(key: []const u8, out: *[28]u8) []const u8 {
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

pub fn writeFrame(stream: std.net.Stream, opcode: u8, payload: []const u8) bool {
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

pub fn readFrame(handle: *WebSocketHandle, max_len: u64, out_opcode: ?*u8, out_ptr: ?*?[*]const u8, out_len: ?*u64) u32 {
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
