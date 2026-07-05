//! The workload driver: a Zig replacement for test_scripts/olivertwist.py.
//! Talks raw TCP (std.net.Stream read/write, not std.http.Client) so
//! malformed/partial requests stay expressible, exactly like the Python
//! original.
//!
//! Simplification vs. olivertwist.py: this driver executes workload events
//! strictly serially, in file order, with plain blocking socket calls.
//! olivertwist.py is *also* serial except for one thing: an opportunistic
//! epoll-based background drain (`readem`) that (a) caps the number of
//! concurrently-open sockets under `-m/--maxreqs`, and (b) lets a response
//! get read before its explicit WAIT if the OS happens to deliver it
//! early. Neither changes what's observable to sherlock/watson: the
//! ordering check only cares about explicit CONNECT/WAIT events (which
//! stay in file order here by construction), and the replay check only
//! cares about the final bytes each WAIT captured, not when they arrived.
//! The workload files ztest targets are small enough (dozens of
//! connections) that the fd-capping concern doesn't apply either. See
//! ztest/README.md for the full list of known deviations.
const std = @import("std");
const toml = @import("toml.zig");
const wire = @import("wire.zig");

pub const Conn = struct {
    stream: std.net.Stream,
    method: []const u8,
    request_line: []const u8,
    headers: []const u8,
    body: []const u8,
    sent: usize = 0,
    received: std.ArrayList(u8) = .empty,
    got_response: bool = false,
};

pub const DriverError = error{
    UnknownRequestId,
    MissingField,
    UnknownEventType,
} || std.mem.Allocator.Error || std.net.TcpConnectToHostError || std.net.Stream.ReadError || std.net.Stream.WriteError || std.fs.File.OpenError || std.fs.Dir.WriteFileError || std.posix.ShutdownError;

pub const Driver = struct {
    arena: std.heap.ArenaAllocator,
    host: []const u8,
    port: u16,
    repo_root: std.fs.Dir,
    serve_dir: std.fs.Dir,
    conns: std.AutoHashMap(i64, Conn),
    /// rid -> the response body bytes actually observed on the wire
    /// (arena-owned), filled in as WAIT events complete.
    responses: std.AutoHashMap(i64, []const u8),
    /// rid -> HTTP status code actually observed.
    statuses: std.AutoHashMap(i64, u16),

    pub fn init(gpa: std.mem.Allocator, host: []const u8, port: u16, repo_root: std.fs.Dir, serve_dir: std.fs.Dir) Driver {
        return .{
            .arena = std.heap.ArenaAllocator.init(gpa),
            .host = host,
            .port = port,
            .repo_root = repo_root,
            .serve_dir = serve_dir,
            .conns = std.AutoHashMap(i64, Conn).init(gpa),
            .responses = std.AutoHashMap(i64, []const u8).init(gpa),
            .statuses = std.AutoHashMap(i64, u16).init(gpa),
        };
    }

    pub fn deinit(self: *Driver) void {
        var it = self.conns.valueIterator();
        while (it.next()) |c| c.stream.close();
        self.conns.deinit();
        self.responses.deinit();
        self.statuses.deinit();
        self.arena.deinit();
    }

    fn a(self: *Driver) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn run(self: *Driver, events: []const toml.Table) !void {
        for (events) |ev| {
            const t = ev.getStr("type") orelse continue;
            if (std.mem.eql(u8, t, "LOAD")) {
                try self.doLoad(ev);
            } else if (std.mem.eql(u8, t, "UNLOAD")) {
                self.doUnload(ev);
            } else if (std.mem.eql(u8, t, "SLEEP")) {
                const secs = ev.getInt("seconds") orelse 4;
                std.Thread.sleep(@as(u64, @intCast(secs)) * std.time.ns_per_s);
            } else if (std.mem.eql(u8, t, "CREATE")) {
                try self.doCreate(ev);
            } else if (std.mem.eql(u8, t, "SEND_LINE")) {
                const c = try self.get(ev);
                try c.stream.writeAll(c.request_line);
            } else if (std.mem.eql(u8, t, "SEND_HEADERS")) {
                const c = try self.get(ev);
                try c.stream.writeAll(c.headers);
            } else if (std.mem.eql(u8, t, "SEND_BODY")) {
                const c = try self.get(ev);
                try self.sendBody(c, ev.getInt("size"));
            } else if (std.mem.eql(u8, t, "SEND_ALL")) {
                const c = try self.get(ev);
                try c.stream.writeAll(c.request_line);
                try c.stream.writeAll(c.headers);
                try self.sendBody(c, null);
            } else if (std.mem.eql(u8, t, "RECV_PARTIAL")) {
                const c = try self.get(ev);
                const size = ev.getInt("size") orelse 4096;
                try self.recvPartial(c, @intCast(size));
            } else if (std.mem.eql(u8, t, "WAIT")) {
                try self.doWait(ev);
            } else {
                return DriverError.UnknownEventType;
            }
        }
    }

    fn doLoad(self: *Driver, ev: toml.Table) !void {
        const infile = ev.getStr("infile") orelse return DriverError.MissingField;
        const outfile = ev.getStr("outfile") orelse return DriverError.MissingField;
        const bytes = try self.repo_root.readFileAlloc(self.a(), infile, 1 << 30);
        try self.serve_dir.writeFile(.{ .sub_path = outfile, .data = bytes });
    }

    fn doUnload(self: *Driver, ev: toml.Table) void {
        const file = ev.getStr("file") orelse return;
        self.serve_dir.deleteFile(file) catch {};
    }

    fn doCreate(self: *Driver, ev: toml.Table) !void {
        const id = ev.getId() orelse return DriverError.MissingField;
        const uri = ev.getStr("uri") orelse return DriverError.MissingField;
        const method = ev.getStr("method") orelse "GET";

        var body: []const u8 = &.{};
        if (ev.getStr("infile")) |infile| {
            body = try self.repo_root.readFileAlloc(self.a(), infile, 1 << 30);
        }

        const request_line = try std.fmt.allocPrint(self.a(), "{s} /{s} HTTP/1.1\r\n", .{ method, uri });

        var headers: std.ArrayList(u8) = .empty;
        try headers.print(self.a(), "Request-Id: {d}\r\n", .{id});
        if (body.len > 0) {
            try headers.print(self.a(), "Content-Length: {d}\r\n", .{body.len});
        }
        try headers.appendSlice(self.a(), "\r\n");

        const stream = try std.net.tcpConnectToHost(self.a(), self.host, self.port);

        try self.conns.put(id, .{
            .stream = stream,
            .method = method,
            .request_line = request_line,
            .headers = try headers.toOwnedSlice(self.a()),
            .body = body,
        });
    }

    fn get(self: *Driver, ev: toml.Table) !*Conn {
        const id = ev.getId() orelse return DriverError.MissingField;
        return self.conns.getPtr(id) orelse DriverError.UnknownRequestId;
    }

    fn sendBody(self: *Driver, c: *Conn, size: ?i64) !void {
        const total = c.body.len;
        var end = total;
        if (size) |sz| {
            if (sz >= 0) {
                const s: usize = @intCast(sz);
                if (c.sent + s < total) end = c.sent + s;
            }
        }
        if (end > c.sent) {
            try c.stream.writeAll(c.body[c.sent..end]);
        }
        c.sent = end;
        if (c.sent == total) {
            // Mirrors olivertwist.py's `sock.shutdown(SHUT_WR)` once the
            // whole body (possibly zero bytes, for GET) has been sent.
            std.posix.shutdown(c.stream.handle, .send) catch |err| switch (err) {
                error.SocketNotConnected => {},
                else => return err,
            };
        }
        _ = self;
    }

    fn recvPartial(self: *Driver, c: *Conn, size: usize) !void {
        const buf = try self.a().alloc(u8, size);
        const n = try c.stream.read(buf);
        if (n == 0) {
            c.got_response = true;
        } else {
            try c.received.appendSlice(self.a(), buf[0..n]);
        }
    }

    fn recvUntilClosed(self: *Driver, c: *Conn) !void {
        var buf: [8192]u8 = undefined;
        while (true) {
            const n = try c.stream.read(&buf);
            if (n == 0) break;
            try c.received.appendSlice(self.a(), buf[0..n]);
        }
        c.got_response = true;
    }

    fn doWait(self: *Driver, ev: toml.Table) !void {
        const id = ev.getId() orelse return DriverError.MissingField;
        var c = self.conns.get(id) orelse return DriverError.UnknownRequestId;

        if (!c.got_response) {
            try self.recvUntilClosed(&c);
        }

        if (wire.parseStatusLine(c.received.items)) |sl| {
            try self.statuses.put(id, sl.code);
        }
        const body_start = wire.findBodyStart(c.received.items) orelse c.received.items.len;
        const body = try self.a().dupe(u8, c.received.items[body_start..]);
        try self.responses.put(id, body);

        c.stream.close();
        _ = self.conns.remove(id);
    }
};

test "GET workload round-trips against a loopback echo-ish stub" {
    // A tiny in-process TCP server that just proves the driver's send/recv
    // choreography works end-to-end: it reads a request line, ignores
    // headers, and replies with a canned 200 body. Full spec compliance
    // is exercised via ztest/mock, this test only exercises Driver's own
    // socket handling in isolation from any real HTTP semantics.
    const gpa = std.testing.allocator;

    var server = try std.net.Address.parseIp("127.0.0.1", 0);
    var listener = try server.listen(.{ .reuse_address = true });
    defer listener.deinit();
    const port = listener.listen_address.getPort();

    const T = struct {
        fn serveOnce(l: *std.net.Server) !void {
            const conn = try l.accept();
            defer conn.stream.close();
            var buf: [4096]u8 = undefined;
            var total: usize = 0;
            // Read until we see the end of headers (or the peer closes).
            while (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n") == null) {
                const n = try conn.stream.read(buf[total..]);
                if (n == 0) break;
                total += n;
            }
            const body = "OK\n";
            var resp_buf: [128]u8 = undefined;
            const resp = try std.fmt.bufPrint(&resp_buf, "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}", .{ body.len, body });
            try conn.stream.writeAll(resp);
        }
    };
    const thread = try std.Thread.spawn(.{}, T.serveOnce, .{&listener});
    defer thread.join();

    var repo_tmp = std.testing.tmpDir(.{});
    defer repo_tmp.cleanup();
    var serve_tmp = std.testing.tmpDir(.{});
    defer serve_tmp.cleanup();

    var driver = Driver.init(gpa, "127.0.0.1", port, repo_tmp.dir, serve_tmp.dir);
    defer driver.deinit();

    const text =
        \\[[events]]
        \\type = "CREATE"
        \\method = "GET"
        \\uri = "whatever.txt"
        \\id = 0
        \\
        \\[[events]]
        \\type = "SEND_ALL"
        \\id = 0
        \\
        \\[[events]]
        \\type = "WAIT"
        \\id = 0
    ;
    var w = try toml.parse(gpa, text);
    defer w.deinit();

    try driver.run(w.events.items);

    try std.testing.expectEqual(@as(u16, 200), driver.statuses.get(0).?);
    try std.testing.expectEqualStrings("OK\n", driver.responses.get(0).?);
}
