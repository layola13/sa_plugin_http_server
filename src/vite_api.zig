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

/// Restore fully blocking I/O and clear any receive timeout.
fn setBlocking(stream: std.net.Stream) !void {
    const flags = try std.posix.fcntl(stream.handle, std.posix.F.GETFL, 0);
    const blocking = flags & ~(@as(usize, 1) << @bitOffsetOf(std.posix.O, "NONBLOCK"));
    _ = try std.posix.fcntl(stream.handle, std.posix.F.SETFL, blocking);
    const zero = std.posix.timeval{ .sec = 0, .usec = 0 };
    std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&zero)) catch {};
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

/// Per-connection state for HTTP keep-alive. Owns the std.http.Server parser
/// (which buffers pipelined bytes across requests) and its heap read buffer.
/// Always heap-allocated and never moved while pooled.
const ConnState = struct {
    http: std.http.Server,
    read_buffer: []u8,
};

/// Cap on idle keep-alive connections held in the pool (each pins an 8KB
/// read buffer plus a socket). Overflow connections are closed on recycle.
/// Kept small on purpose: every accept scans the pool, so the cap bounds
/// the per-accept cost under connection-churn workloads.
const max_recycled_conns: usize = 64;
const conn_read_buffer_len: usize = 8192;
/// Buffered stream output is pushed to the socket once it reaches this size,
/// or on flush()/endChunked().
const stream_flush_threshold: usize = 8192;
/// Bound on one non-blocking keep-alive probe parse (covers normal TCP
/// segment gaps without stalling the accept loop).
const probe_parse_timeout_ms: u32 = 50;

/// Result of the internal poll over listener + idle pool + wake pipe.
const PollOutcome = struct {
    status: NetworkStatus,
    /// A recycled connection may have a request (or died): sweep the pool.
    recycled_ready: bool,
    /// The listener has a pending connection.
    listener_ready: bool,
};

/// Request handler for sa_http_server_serve_threaded:
/// `fn (req: ?*anyopaque, ctx: ?*anyopaque) callconv(.c) void`.
/// Runs on plugin pool threads. The handler owns the request: it must send a
/// response (or upgrade) and then call sa_http_server_req_free, which
/// recycles keep-alive connections back into the pool.
pub const HttpServeHandlerFn = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) void;

pub const ThreadPool = struct {
    server: *HttpServer,
    threads: []std.Thread,
    handler: HttpServeHandlerFn,
    handler_ctx: ?*anyopaque,
    max_requests: u64,
    served: std.atomic.Value(u64),
    stopping: std.atomic.Value(bool),
};

fn workerMain(pool: *ThreadPool) void {
    const srv = pool.server;
    while (!pool.stopping.load(.acquire)) {
        if (pool.max_requests != 0 and pool.served.load(.acquire) >= pool.max_requests) break;
        const req = srv.acceptWorker(&pool.stopping) catch continue;
        _ = pool.served.fetchAdd(1, .acq_rel);
        pool.handler(@ptrCast(req), pool.handler_ctx);
    }
}

/// Bound on the request-head parse for connections accepted by the plugin
/// thread pool (slowloris guard for serve_threaded).
const worker_head_parse_timeout_ms: u32 = 5000;

pub const HttpServer = struct {
    allocator: std.mem.Allocator,
    server: ?std.net.Server = null,
    /// v1 request body limit. Default 2MB (historic); configurable via
    /// sa_http_server_set_max_body_bytes. v2 always uses 16MB.
    max_body_len: usize = 2 * 1024 * 1024,
    /// Idle keep-alive connections waiting for their next request.
    recycled: std.ArrayList(*ConnState),
    recycled_mutex: std.Thread.Mutex = .{},
    /// Self-pipe: pushRecycled writes a byte so an accept loop blocked in
    /// poll() wakes up immediately. Recycling is asynchronous (handler
    /// threads recycle after the accept loop snapshotted the pool), so
    /// without this the next request on a reused connection could sleep
    /// until the poll timeout.
    wake_pipe: [2]std.posix.fd_t,
    /// Active plugin-internal thread pool (serve_threaded), if any.
    pool: ?*ThreadPool = null,

    pub fn init(allocator: std.mem.Allocator) !*HttpServer {
        const self = try allocator.create(HttpServer);
        errdefer allocator.destroy(self);
        const pipe = try std.posix.pipe();
        errdefer {
            std.posix.close(pipe[0]);
            std.posix.close(pipe[1]);
        }
        for (pipe) |fd| {
            const flags = try std.posix.fcntl(fd, std.posix.F.GETFL, 0);
            const nonblocking = flags | (@as(usize, 1) << @bitOffsetOf(std.posix.O, "NONBLOCK"));
            _ = try std.posix.fcntl(fd, std.posix.F.SETFL, nonblocking);
        }
        self.* = .{
            .allocator = allocator,
            .server = null,
            .recycled = std.ArrayList(*ConnState).init(allocator),
            .wake_pipe = pipe,
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
        // The accept loop must never block inside accept(): a poll-reported
        // readable listener can still yield an empty accept queue if the
        // pending connection reset between poll and accept. Non-blocking
        // accept returns WouldBlock instead of wedging the whole server.
        setNonBlocking(self.server.?.stream) catch |err| {
            self.server.?.deinit();
            self.server = null;
            return err;
        };
    }

    pub fn setMaxBodyLen(self: *HttpServer, max_bytes: usize) !void {
        if (max_bytes == 0 or max_bytes > (1 << 30)) return error.InvalidArgument;
        self.max_body_len = max_bytes;
    }

    pub fn accept(self: *HttpServer) !*HttpRequest {
        return self.acceptConfigured(self.max_body_len, null);
    }

    /// Worker accept for serve_threaded: poll-driven like acceptConfigured
    /// but with a 1s poll slice so stopServing() is noticed promptly, and a
    /// bounded head parse (slowloris guard). Returns error.WouldBlock on
    /// timeout or when stopping so the worker loop can re-check.
    fn acceptWorker(self: *HttpServer, stopping: *const std.atomic.Value(bool)) !*HttpRequest {
        while (true) {
            if (stopping.load(.acquire)) return error.WouldBlock;
            const pr = self.pollAcceptEx(1000);
            switch (pr.status) {
                .ok => {
                    if (pr.recycled_ready) {
                        if (self.drainRecycled(self.max_body_len, null)) |req| return req;
                    }
                    if (pr.listener_ready) {
                        if (try self.acceptFresh(self.max_body_len, worker_head_parse_timeout_ms, null, true)) |req| return req;
                    }
                },
                .timeout => return error.WouldBlock,
                else => return error.ConnectionAborted,
            }
        }
    }

    pub fn serveThreaded(
        self: *HttpServer,
        num_threads: u32,
        handler: HttpServeHandlerFn,
        handler_ctx: ?*anyopaque,
        max_requests: u64,
    ) !void {
        if (self.server == null) return error.NotStarted;
        if (self.pool != null) return error.AlreadyServing;
        var n: usize = num_threads;
        if (n == 0) n = std.Thread.getCpuCount() catch 4;
        n = @min(@max(n, 1), 256);

        const pool = try self.allocator.create(ThreadPool);
        errdefer self.allocator.destroy(pool);
        const threads = try self.allocator.alloc(std.Thread, n);
        errdefer self.allocator.free(threads);
        pool.* = .{
            .server = self,
            .threads = threads,
            .handler = handler,
            .handler_ctx = handler_ctx,
            .max_requests = max_requests,
            .served = std.atomic.Value(u64).init(0),
            .stopping = std.atomic.Value(bool).init(false),
        };
        self.pool = pool;

        var started: usize = 0;
        while (started < n) : (started += 1) {
            threads[started] = std.Thread.spawn(.{}, workerMain, .{pool}) catch |err| {
                pool.stopping.store(true, .release);
                for (threads[0..started]) |t| t.join();
                self.pool = null;
                self.allocator.free(threads);
                self.allocator.destroy(pool);
                return err;
            };
        }
        for (threads) |t| t.join();
        self.pool = null;
        self.allocator.free(threads);
        self.allocator.destroy(pool);
    }

    /// Ask a running serveThreaded loop to stop. Wakes workers blocked in
    /// poll() via listener shutdown; in-flight handlers run to completion.
    /// NOTE: the shutdown also closes the listening socket, so the server
    /// handle cannot accept new connections afterwards — free it with
    /// sa_http_server_free once the loop has returned.
    pub fn stopServing(self: *HttpServer) void {
        if (self.pool) |pool| pool.stopping.store(true, .release);
        if (self.server) |*s| std.posix.shutdown(s.stream.handle, .both) catch {};
    }

    /// Public pollable status (v2 ABI). See pollAcceptEx for the internals.
    pub fn pollAccept(self: *HttpServer, timeout_ms: u32) NetworkStatus {
        return self.pollAcceptEx(timeout_ms).status;
    }

    /// Like poll(2) over the listener plus all idle keep-alive connections
    /// plus the recycle wake pipe: tells the accept loop which class of fd
    /// is actionable so it can skip sweeping the idle pool when only the
    /// listener has traffic.
    fn pollAcceptEx(self: *HttpServer, timeout_ms: u32) PollOutcome {
        const bad = PollOutcome{ .status = .invalid, .recycled_ready = false, .listener_ready = false };
        var fds: [max_recycled_conns + 2]std.posix.pollfd = undefined;        var nfds: usize = 0;
        var nrec: usize = 0;
        {
            self.recycled_mutex.lock();
            defer self.recycled_mutex.unlock();
            for (self.recycled.items) |conn| {
                // Pipelined bytes already buffered: no need to poll.
                if (conn.http.read_buffer_len > conn.http.next_request_start) {
                    return .{ .status = .ok, .recycled_ready = true, .listener_ready = false };
                }
                fds[nfds] = .{
                    .fd = conn.http.connection.stream.handle,
                    .events = std.posix.POLL.IN,
                    .revents = 0,
                };
                nfds += 1;
            }
            nrec = nfds;
            fds[nfds] = .{ .fd = self.wake_pipe[0], .events = std.posix.POLL.IN, .revents = 0 };
            nfds += 1;
            if (self.server) |*s| {
                fds[nfds] = .{
                    .fd = s.stream.handle,
                    .events = std.posix.POLL.IN,
                    .revents = 0,
                };
                nfds += 1;
            } else {
                return bad;
            }
        }
        const ready = std.posix.poll(fds[0..nfds], timeoutMillis(timeout_ms)) catch
            return .{ .status = .io_error, .recycled_ready = false, .listener_ready = false };
        if (ready == 0) return .{
            .status = if (timeout_ms == 0) .would_block else .timeout,
            .recycled_ready = false,
            .listener_ready = false,
        };
        // Drain the wake pipe (a recycle happened); it counts as pool activity.
        // A dead pooled fd (POLLERR/POLLNVAL, e.g. a keep-alive connection
        // whose TCP state fully died while pooled) must NEVER poison the
        // poll: mark the pool for sweeping and let drainRecycled reap the
        // dead connection. Returning .io_error here used to wedge the accept
        // loop permanently (host spins on the failed accept). Only the
        // listener's health is fatal.
        var recycled_ready = false;
        if (fds[nrec].revents & std.posix.POLL.IN != 0) {
            recycled_ready = true;
            var tmp: [64]u8 = undefined;
            while (std.posix.read(self.wake_pipe[0], &tmp)) |n| {
                if (n == 0) break;
            } else |_| {}
        }
        for (fds[0..nrec]) |pfd| {
            if (pfd.revents != 0) recycled_ready = true;
        }
        const levents = fds[nfds - 1].revents;
        if (levents & (std.posix.POLL.ERR | std.posix.POLL.NVAL) != 0)
            return .{ .status = .io_error, .recycled_ready = false, .listener_ready = false };
        return .{
            .status = .ok,
            .recycled_ready = recycled_ready,
            .listener_ready = levents & std.posix.POLL.IN != 0,
        };
    }

    pub fn acceptWithBodyLimit(self: *HttpServer, max_body_len: usize) !*HttpRequest {
        return self.acceptConfigured(max_body_len, null);
    }

    pub fn acceptWithBodyLimitAndTimeout(self: *HttpServer, max_body_len: usize, timeout_ms: u32) !*HttpRequest {
        return self.acceptConfigured(max_body_len, timeout_ms);
    }

    fn acceptConfigured(self: *HttpServer, max_body_len: usize, receive_timeout_ms: ?u32) !*HttpRequest {
        if (self.server == null) return error.NotFound;
        if (receive_timeout_ms) |timeout_ms| {
            return self.acceptBounded(max_body_len, timeout_ms);
        }
        // v1: block until the next request arrives on any connection.
        // Poll-driven so one idle keep-alive connection can never wedge the
        // accept loop while other connections have traffic. The idle pool is
        // only swept when poll saw pool activity (wake pipe or recycled fd),
        // keeping the per-accept cost O(1) in the common listener-traffic case.
        while (true) {
            const pr = self.pollAcceptEx(60_000);
            switch (pr.status) {
                .ok => {
                    if (pr.recycled_ready) {
                        if (self.drainRecycled(max_body_len, null)) |req| return req;
                    }
                    if (pr.listener_ready) {
                        if (try self.acceptFresh(max_body_len, null, null, true)) |req| return req;
                    }
                    // Spurious wakeup (e.g. a recycled fd died and was
                    // reaped): re-poll.
                },
                .timeout => continue,
                else => return error.ConnectionAborted,
            }
        }
    }

    fn acceptBounded(self: *HttpServer, max_body_len: usize, timeout_ms: u32) !*HttpRequest {
        if (self.server == null) return error.NotFound;
        const start_ms = std.time.milliTimestamp();
        while (true) {
            const elapsed_ms: u64 = blk: {
                const e = std.time.milliTimestamp() - start_ms;
                break :blk if (e <= 0) 0 else @intCast(e);
            };
            if (elapsed_ms >= timeout_ms) return if (timeout_ms == 0) error.WouldBlock else error.HttpHeadersUnreadable;
            const remaining: u32 = @intCast(@min(timeout_ms - elapsed_ms, std.math.maxInt(u32)));
            const pr = self.pollAcceptEx(remaining);
            switch (pr.status) {
                .ok => {
                    if (pr.recycled_ready) {
                        if (self.drainRecycled(max_body_len, timeout_ms)) |req| return req;
                    }
                    if (pr.listener_ready) {
                        if (try self.acceptFresh(max_body_len, remaining, timeout_ms, true)) |req| return req;
                    }
                },
                .timeout => return error.HttpHeadersUnreadable,
                .would_block => return error.WouldBlock,
                else => return error.ConnectionAborted,
            }
        }
    }

    /// Non-blocking sweep over idle keep-alive connections. Returns the first
    /// connection that yields a complete request; unready connections are
    /// pushed back, dead ones closed. Never blocks. Takes the pool lock only
    /// twice (swap-out, push-back) and uses a single poll(2) over the whole
    /// batch, so the cost stays flat no matter how many idle connections sit
    /// in the pool.
    fn drainRecycled(self: *HttpServer, max_body_len: usize, post_parse_timeout: ?u32) ?*HttpRequest {
        var conns = std.ArrayList(*ConnState).init(self.allocator);
        {
            self.recycled_mutex.lock();
            defer self.recycled_mutex.unlock();
            std.mem.swap(std.ArrayList(*ConnState), &self.recycled, &conns);
        }
        var keep = std.ArrayList(*ConnState).init(self.allocator);
        defer keep.deinit();
        var result: ?*HttpRequest = null;

        // One poll over the whole batch instead of one syscall per conn.
        var pfds: [max_recycled_conns]std.posix.pollfd = undefined;
        for (conns.items, 0..) |conn, i| {
            pfds[i] = .{
                .fd = conn.http.connection.stream.handle,
                .events = std.posix.POLL.IN,
                .revents = 0,
            };
        }
        const npoll = conns.items.len;
        if (npoll > 0) {
            _ = std.posix.poll(pfds[0..npoll], 0) catch {};
        }

        for (conns.items, 0..) |conn, i| {
            if (result != null) {
                keep.append(conn) catch self.destroyConn(conn, true);
                continue;
            }
            const stream = conn.http.connection.stream;
            const has_buffered = conn.http.read_buffer_len > conn.http.next_request_start;
            const rev: i16 = if (npoll > 0) pfds[i].revents else 0;
            const dead = rev & (std.posix.POLL.ERR | std.posix.POLL.NVAL) != 0;
            // HUP without IN (or with nothing readable) also means the peer
            // is gone; IN means either data or EOF, decided by the parse.
            const readable = !dead and (has_buffered or (rev & std.posix.POLL.IN) != 0);
            if (!readable) {
                if (dead or (rev & std.posix.POLL.HUP) != 0) {
                    self.destroyConn(conn, true);
                } else {
                    keep.append(conn) catch self.destroyConn(conn, true);
                }
                continue;
            }
            if (!has_buffered) {
                // Readable: give the head parse a short bounded wait so a
                // head+body split across TCP segments still completes.
                setBlocking(stream) catch {
                    self.destroyConn(conn, true);
                    continue;
                };
                setReceiveTimeout(stream, probe_parse_timeout_ms) catch {
                    self.destroyConn(conn, true);
                    continue;
                };
            }
            const req = self.parseHead(conn, max_body_len) catch {
                // A reused connection that stalls mid-head (or speaks garbage)
                // is dropped outright: retrying a partial head is unsafe
                // because std.http keeps a stale next_request_start across
                // attempts, which would discard already-read bytes and
                // mis-parse the remainder. The client simply reconnects.
                self.destroyConn(conn, true);
                continue;
            };
            // Normalize the socket mode for the handler.
            if (post_parse_timeout) |ms| {
                setReceiveTimeout(stream, ms) catch {
                    req.deinit();
                    continue;
                };
            } else {
                setBlocking(stream) catch {
                    req.deinit();
                    continue;
                };
            }
            result = req;
        }
        conns.deinit();

        // Push the survivors back under a single lock hold. No wake-pipe
        // byte: these were already in the pool before this sweep.
        self.recycled_mutex.lock();
        defer self.recycled_mutex.unlock();
        for (keep.items) |conn| {
            if (self.recycled.items.len >= max_recycled_conns) {
                self.destroyConn(conn, true);
            } else {
                self.recycled.append(conn) catch self.destroyConn(conn, true);
            }
        }
        return result;
    }

    /// Accept one NEW tcp connection (never a recycled one). With
    /// require_readable, returns null instead of blocking when the listener
    /// has nothing pending. The listener is non-blocking, so accept() can
    /// only return WouldBlock (no pending connection) rather than wedge.
    /// The head parse is always time-bounded: a client that connects but
    /// never sends a head must not wedge the single accept loop.
    fn acceptFresh(
        self: *HttpServer,
        max_body_len: usize,
        parse_timeout: ?u32,
        post_parse: ?u32,
        require_readable: bool,
    ) !?*HttpRequest {
        const listener = &(self.server orelse return error.NotFound);
        if (require_readable and pollStream(listener.stream, std.posix.POLL.IN, 0, null) != .ok) return null;
        const accepted = listener.accept() catch |err| {
            if (err == error.WouldBlock) return null;
            return err;
        };
        // fd ownership transfers into conn below; the block-scoped errdefer
        // only closes if newConn itself fails (double-close would SIGABRT).
        const conn: *ConnState = blk: {
            errdefer accepted.stream.close();
            break :blk try self.newConn(accepted);
        };
        errdefer self.destroyConn(conn, true);
        const stream = conn.http.connection.stream;
        // Bound the head parse: v1 (parse_timeout == null) gets a generous
        // 30s rather than blocking forever on a silent client.
        const head_timeout_ms = parse_timeout orelse 30_000;
        try setReceiveTimeout(stream, head_timeout_ms);
        const req = try self.parseHead(conn, max_body_len);
        errdefer req.deinit();
        if (post_parse) |ms| {
            try setReceiveTimeout(stream, ms);
        } else {
            try setBlocking(stream);
        }
        return req;
    }

    fn parseHead(self: *HttpServer, conn: *ConnState, max_body_len: usize) !*HttpRequest {
        var std_request = try conn.http.receiveHead();

        const content_length: usize = blk: {
            const cl = std_request.head.content_length orelse 0;
            break :blk @intCast(cl);
        };
        // We only consume Content-Length bodies. Chunked request bodies are
        // left unread, which forces the connection closed after the response.
        const supports_reuse = std_request.head.transfer_encoding == .none;
        const keep_alive = std_request.head.keep_alive and supports_reuse;

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
        if (content_length > 0) {
            if (content_length > max_body_len) return error.BodyTooLarge;
            const reader = try std_request.reader();
            try body.ensureTotalCapacity(content_length);
            try reader.readNoEof(body.unusedCapacitySlice()[0..content_length]);
            body.items.len = content_length;
        } else if (supports_reuse) {
            // No body: drive the parser back to .ready so the connection can
            // serve the next request. (remaining==0 completes immediately.)
            var reader = try std_request.reader();
            var tmp: [1]u8 = undefined;
            _ = try reader.read(&tmp);
        }

        request.* = .{
            .allocator = self.allocator,
            .conn = conn,
            .server = self,
            .keep_alive = keep_alive,
            .response_done = false,
            .method = method,
            .target = target,
            .headers = try headers.toOwnedSlice(),
            .body = try body.toOwnedSlice(),
        };
        return request;
    }

    fn newConn(self: *HttpServer, accepted: std.net.Server.Connection) !*ConnState {
        const read_buffer = try self.allocator.alloc(u8, conn_read_buffer_len);
        errdefer self.allocator.free(read_buffer);
        const conn = try self.allocator.create(ConnState);
        errdefer self.allocator.destroy(conn);
        conn.* = .{
            .http = std.http.Server.init(accepted, read_buffer),
            .read_buffer = read_buffer,
        };
        return conn;
    }

    fn destroyConn(self: *HttpServer, conn: *ConnState, close_stream: bool) void {
        if (close_stream) conn.http.connection.stream.close();
        self.allocator.free(conn.read_buffer);
        self.allocator.destroy(conn);
    }

    fn popRecycled(self: *HttpServer) ?*ConnState {
        self.recycled_mutex.lock();
        defer self.recycled_mutex.unlock();
        if (self.recycled.items.len == 0) return null;
        return self.recycled.pop();
    }

    /// True when the peer already went away (EOF/RST pending). Called at
    /// recycle time so a connection the client already closed never wastes
    /// a pool slot, a wake-pipe byte, and a future O(pool) sweep. A readable
    /// socket is peeked: real bytes (pipelined next request) mean "keep",
    /// EOF means "drop".
    pub fn isPeerClosed(stream: std.net.Stream) bool {
        var pfd = [1]std.posix.pollfd{.{
            .fd = stream.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ready = std.posix.poll(&pfd, 0) catch return true;
        if (ready == 0) return false; // idle: genuine keep-alive candidate
        const rev = pfd[0].revents;
        if (rev & (std.posix.POLL.ERR | std.posix.POLL.NVAL | std.posix.POLL.HUP) != 0) return true;
        if (rev & std.posix.POLL.IN == 0) return false;
        var b: [1]u8 = undefined;
        const n = std.posix.recv(stream.handle, &b, std.os.linux.MSG.PEEK | std.os.linux.MSG.DONTWAIT) catch return true;
        return n == 0;
    }

    /// Return a connection to the idle pool (or close it when the pool is
    /// full). Wakes an accept loop blocked in poll() via the self-pipe, so
    /// the next request on this connection is picked up immediately even
    /// though recycling happens on a handler thread.
    pub fn pushRecycled(self: *HttpServer, conn: *ConnState) void {
        {
            self.recycled_mutex.lock();
            defer self.recycled_mutex.unlock();
            if (self.recycled.items.len >= max_recycled_conns) {
                self.destroyConn(conn, true);
                return;
            }
            self.recycled.append(conn) catch {
                self.destroyConn(conn, true);
                return;
            };
        }
        var b: [1]u8 = .{0};
        _ = std.posix.write(self.wake_pipe[1], &b) catch {};
    }

    pub fn deinit(self: *HttpServer) void {
        if (self.server) |*server| server.deinit();
        while (self.popRecycled()) |conn| self.destroyConn(conn, true);
        self.recycled.deinit();
        std.posix.close(self.wake_pipe[0]);
        std.posix.close(self.wake_pipe[1]);
        self.allocator.destroy(self);
    }
};

pub const HttpRequest = struct {
    allocator: std.mem.Allocator,
    conn: *ConnState,
    server: *HttpServer,
    /// Negotiated at accept: HTTP/1.1 default (unless `Connection: close`),
    /// HTTP/1.0 only with `Connection: keep-alive`. Chunked request bodies
    /// force false (we don't consume them).
    keep_alive: bool,
    /// Set once a fully-framed response hit the wire (content-length body or
    /// terminated chunked stream). req_free recycles the connection only when
    /// this is true; otherwise the connection is closed.
    response_done: bool = false,
    method: []u8,
    target: []u8,
    headers: []Header,
    body: []u8,

    pub fn stream(self: *HttpRequest) std.net.Stream {
        return self.conn.http.connection.stream;
    }

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

    /// Release parser state without closing the stream; ownership of the
    /// returned stream transfers to the caller (WebSocket upgrade).
    pub fn releaseStream(self: *HttpRequest) std.net.Stream {
        const s = self.conn.http.connection.stream;
        self.server.destroyConn(self.conn, false);
        return s;
    }

    pub fn deinit(self: *HttpRequest) void {
        self.server.destroyConn(self.conn, true);
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
        // Framing is explicit (content-length), so the connection may be
        // reused when the client negotiated keep-alive.
        if (self.request.keep_alive) {
            try writer.writeAll("connection: keep-alive\r\n\r\n");
        } else {
            try writer.writeAll("connection: close\r\n\r\n");
        }
        try writer.writeAll(body);
        try self.request.stream().writeAll(head.items);
        self.sent = true;
        self.request.response_done = true;
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
    /// Explicit write buffer. writeChunk frames chunk bytes into it instead
    /// of hitting the socket directly. flush() — or the 8KB auto-flush, or
    /// endChunked() — pushes it to the socket. This is what makes flush() a
    /// real operation: without it, bytes may sit in this buffer.
    /// Semantics: writeChunk alone does NOT guarantee delivery; call flush()
    /// (or end the stream) to push.
    out_buffer: std.ArrayList(u8),

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
            .out_buffer = std.ArrayList(u8).init(request.allocator),
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
        try writer.writeAll("transfer-encoding: chunked\r\n");
        // Chunked framing is self-delimiting, so the connection may be
        // reused once the terminal chunk is sent.
        if (self.request.keep_alive) {
            try writer.writeAll("connection: keep-alive\r\n\r\n");
        } else {
            try writer.writeAll("connection: close\r\n\r\n");
        }
        try self.request.stream().writeAll(head.items);
        self.sent_head = true;
    }

    pub fn writeChunk(self: *HttpStreamResponse, bytes: []const u8) !void {
        if (!self.sent_head) try self.sendHead(self.status);
        var size_buf: [32]u8 = undefined;
        const size = try std.fmt.bufPrint(&size_buf, "{x}\r\n", .{bytes.len});
        try self.out_buffer.appendSlice(size);
        try self.out_buffer.appendSlice(bytes);
        try self.out_buffer.appendSlice("\r\n");
        if (self.out_buffer.items.len >= stream_flush_threshold) try self.flush();
    }

    /// Push everything buffered (sending the head first if needed) to the
    /// socket. This is a real flush: after it returns, all previously
    /// written chunks have been handed to the OS.
    pub fn flush(self: *HttpStreamResponse) !void {
        if (!self.sent_head) try self.sendHead(self.status);
        if (self.out_buffer.items.len != 0) {
            try self.request.stream().writeAll(self.out_buffer.items);
            self.out_buffer.clearRetainingCapacity();
        }
    }

    pub fn endChunked(self: *HttpStreamResponse) !void {
        if (self.ended) return;
        if (!self.sent_head) try self.sendHead(self.status);
        try self.flush();
        try self.request.stream().writeAll("0\r\n\r\n");
        self.ended = true;
        self.request.response_done = true;
    }

    pub fn deinit(self: *HttpStreamResponse) void {
        self.out_buffer.deinit();
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
            // Takes over the TCP stream; the HTTP connection is consumed and
            // never recycled for keep-alive.
            .stream = request.releaseStream(),
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
