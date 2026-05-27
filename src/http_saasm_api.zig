const std = @import("std");
const plugin_api = @import("plugin_api");

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
    target: []u8,
    headers: []Header,
    body: []u8,

    fn deinit(self: *HttpRequest) void {
        self.connection.stream.close();
        for (self.headers) |header| {
            self.allocator.free(header.name);
            self.allocator.free(header.value);
        }
        self.allocator.free(self.headers);
        self.allocator.free(self.target);
        if (self.body.len != 0) self.allocator.free(self.body);
        self.allocator.destroy(self);
    }
};

pub const HttpResponse = struct {
    allocator: std.mem.Allocator,
    request: *HttpRequest,
    status: u16,
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

pub export fn sa_http_server_new(out_server: ?*?*anyopaque) u32 {
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
        "HTTP/1.1 {d} {s}\r\ncontent-length: {d}\r\ncontent-type: text/plain\r\nconnection: close\r\n\r\n",
        .{ response.status, statusText(response.status), payload.len },
    ) catch return @intFromEnum(plugin_api.AbiStatus.failed);
    conn.stream.writeAll(header) catch return @intFromEnum(plugin_api.AbiStatus.failed);
    conn.stream.writeAll(payload) catch return @intFromEnum(plugin_api.AbiStatus.failed);
    response.sent = true;
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
