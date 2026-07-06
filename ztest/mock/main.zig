//! A minimal spec-following HTTP server, used ONLY to validate ztest's
//! runner/checker logic while the real C httpserver (src/*.c) doesn't
//! build yet (see docs/PLAN.md). Implements just enough of
//! httpserver-spec to be a faithful stand-in:
//!   - `./mock-httpserver [-t threads] [-l logfile] <port>`
//!   - GET/PUT on flat URIs relative to its cwd (403/404/500 mapped the
//!     same way the spec describes)
//!   - one audit line per request: "Oper,URI,Status,RequestID\n"
//!   - response body convention lifted from old_proj_states/asgn2/response.c
//!     (still the base this repo's asgn4 code descends from): the reason
//!     phrase + "\n" for anything that isn't a successful GET, and the
//!     literal file bytes for a successful GET. That convention is also
//!     what test_scripts/watson.py's replay literally compares against
//!     ("OK", "Created", "Not Found").
//!   - per-URI locking (so different URIs proceed in parallel, same-URI
//!     requests serialize, and the audit-log write happens inside the
//!     same critical section as the file op, which is what keeps log
//!     order and observed effects consistent).
//!
//! Known simplification vs. the graded spec: this uses one OS thread per
//! connection rather than a fixed `-t N`-sized worker pool (so `-t` is
//! accepted but doesn't bound concurrency). That's fine for validating
//! ztest's own ordering/replay checks, which don't depend on worker-pool
//! sizing -- but it means this mock can't stand in for the "N workers
//! plus a dispatcher" thread-count grading check. See ztest/README.md.
const std = @import("std");
const wire = @import("ztest").wire;

var log_mutex: std.Thread.Mutex = .{};
var log_file: std.fs.File = undefined;

var table_mutex: std.Thread.Mutex = .{};
var uri_locks: std.StringHashMap(*std.Thread.Mutex) = undefined;
var uri_locks_gpa: std.mem.Allocator = undefined;

fn lockFor(uri: []const u8) *std.Thread.Mutex {
    table_mutex.lock();
    defer table_mutex.unlock();
    if (uri_locks.get(uri)) |m| return m;
    const key = uri_locks_gpa.dupe(u8, uri) catch @panic("OOM");
    const m = uri_locks_gpa.create(std.Thread.Mutex) catch @panic("OOM");
    m.* = .{};
    uri_locks.put(key, m) catch @panic("OOM");
    return m;
}

fn writeAudit(oper: []const u8, uri: []const u8, status: u16, rid: []const u8) void {
    log_mutex.lock();
    defer log_mutex.unlock();
    var buf: [1024]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "{s},{s},{d},{s}\n", .{ oper, uri, status, rid }) catch return;
    log_file.writeAll(line) catch {};
}

fn statusReason(code: u16) []const u8 {
    return switch (code) {
        200 => "OK",
        201 => "Created",
        400 => "Bad Request",
        403 => "Forbidden",
        404 => "Not Found",
        500 => "Internal Server Error",
        501 => "Not Implemented",
        505 => "Version Not Supported",
        else => "Unknown",
    };
}

fn sendResponse(a: std.mem.Allocator, stream: std.net.Stream, code: u16, body: []const u8) !void {
    const reason = statusReason(code);
    const head = try std.fmt.allocPrint(a, "HTTP/1.1 {d} {s}\r\nContent-Length: {d}\r\n\r\n", .{ code, reason, body.len });
    defer a.free(head);
    try stream.writeAll(head);
    if (body.len > 0) try stream.writeAll(body);
}

/// Reason-phrase-plus-newline response body (the asgn2 convention watson's
/// replay compares against literally: "Not Found\n", "Created\n", ...).
fn errorBody(a: std.mem.Allocator, code: u16) []const u8 {
    return std.fmt.allocPrint(a, "{s}\n", .{statusReason(code)}) catch "";
}

/// The one ordering invariant this mock exists to model: the audit line is
/// written while the per-URI lock is still held (so audit order matches the
/// order of filesystem effects), and the response goes out after unlock.
/// `lock` is null for requests that never took a URI lock (e.g. 501s).
fn auditAndRespond(
    a: std.mem.Allocator,
    stream: std.net.Stream,
    lock: ?*std.Thread.Mutex,
    oper: []const u8,
    uri: []const u8,
    code: u16,
    rid: []const u8,
    body: []const u8,
) void {
    writeAudit(oper, uri, code, rid);
    if (lock) |l| l.unlock();
    sendResponse(a, stream, code, body) catch {};
}

/// Reads off `stream` until the header block (request line + headers) is
/// fully buffered, returning the whole buffer read so far (which may
/// include some leftover body bytes already in the same TCP segment).
fn readHeaders(a: std.mem.Allocator, stream: std.net.Stream) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    var chunk: [4096]u8 = undefined;
    while (wire.findBodyStart(buf.items) == null) {
        const n = try stream.read(&chunk);
        if (n == 0) break;
        try buf.appendSlice(a, chunk[0..n]);
        if (buf.items.len > 1 << 20) break; // defensive cap
    }
    return buf.toOwnedSlice(a);
}

fn handleConnection(gpa: std.mem.Allocator, stream: std.net.Stream) void {
    defer stream.close();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const head = readHeaders(a, stream) catch return;
    const body_start = wire.findBodyStart(head) orelse return;
    const rl = wire.parseRequestLine(head) orelse return;
    const headers = head[std.mem.indexOf(u8, head, "\r\n").? + 2 .. body_start];
    const rid = wire.findHeader(headers, "Request-Id") orelse "0";

    var leftover_body = head[body_start..];

    if (std.mem.eql(u8, rl.method, "GET")) {
        const lock = lockFor(rl.uri);
        lock.lock();
        var code: u16 = 200;
        var body: []const u8 = &.{};
        if (std.fs.cwd().openFile(rl.uri, .{})) |file| {
            defer file.close();
            const stat = file.stat() catch null;
            if (stat) |st| {
                if (st.kind == .directory) code = 403;
            }
            if (code == 200) {
                body = file.readToEndAlloc(a, 1 << 30) catch blk: {
                    code = 500;
                    break :blk errorBody(a, 500);
                };
            } else {
                body = errorBody(a, code);
            }
        } else |err| {
            code = switch (err) {
                error.FileNotFound => 404,
                error.AccessDenied, error.IsDir => 403,
                else => 500,
            };
            body = errorBody(a, code);
        }
        auditAndRespond(a, stream, lock, "GET", rl.uri, code, rid, body);
        return;
    }

    if (std.mem.eql(u8, rl.method, "PUT")) {
        const content_length: usize = blk: {
            const cl = wire.findHeader(headers, "Content-Length") orelse break :blk 0;
            break :blk std.fmt.parseInt(usize, cl, 10) catch 0;
        };

        const lock = lockFor(rl.uri);
        lock.lock();

        const existed = blk: {
            std.fs.cwd().access(rl.uri, .{}) catch break :blk false;
            break :blk true;
        };

        const file = std.fs.cwd().createFile(rl.uri, .{ .truncate = true }) catch |err| {
            const code: u16 = switch (err) {
                error.AccessDenied, error.IsDir => 403,
                else => 500,
            };
            auditAndRespond(a, stream, lock, "PUT", rl.uri, code, rid, errorBody(a, code));
            return;
        };
        defer file.close();

        // Write whatever body bytes arrived alongside the headers, then
        // keep reading (this blocks -- by design -- until the rest of the
        // body arrives, exactly matching a real single-worker-per-connection
        // server's behavior for a slow/paused client).
        var written: usize = 0;
        if (leftover_body.len > content_length) leftover_body = leftover_body[0..content_length];
        if (leftover_body.len > 0) {
            file.writeAll(leftover_body) catch {};
            written = leftover_body.len;
        }
        var chunk: [8192]u8 = undefined;
        while (written < content_length) {
            const want = @min(chunk.len, content_length - written);
            const n = stream.read(chunk[0..want]) catch break;
            if (n == 0) break;
            file.writeAll(chunk[0..n]) catch {};
            written += n;
        }

        const code: u16 = if (existed) 200 else 201;
        auditAndRespond(a, stream, lock, "PUT", rl.uri, code, rid, errorBody(a, code));
        return;
    }

    // Anything else -> 501, per spec. No URI lock: nothing filesystem-visible
    // happens, so there is no effect/log ordering to protect.
    auditAndRespond(a, stream, null, rl.method, rl.uri, 501, rid, errorBody(a, 501));
}

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    uri_locks_gpa = gpa;
    uri_locks = std.StringHashMap(*std.Thread.Mutex).init(gpa);

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    var threads: u32 = 4;
    var log_path: ?[]const u8 = null;
    var port_str: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-t") and i + 1 < args.len) {
            i += 1;
            threads = std.fmt.parseInt(u32, args[i], 10) catch 4;
        } else if (std.mem.eql(u8, arg, "-l") and i + 1 < args.len) {
            i += 1;
            log_path = args[i];
        } else {
            port_str = arg;
        }
    }
    // -t is accepted for CLI compatibility (see module doc comment: this
    // mock uses one thread per connection, not a fixed-size pool). Not
    // logged anywhere: stderr is the audit log channel by default (when
    // -l isn't given) and must contain nothing but audit lines.
    std.mem.doNotOptimizeAway(&threads);

    const port_arg = port_str orelse {
        std.debug.print("usage: mock-httpserver [-t threads] [-l logfile] <port>\n", .{});
        return error.MissingPort;
    };
    const port = try std.fmt.parseInt(u16, port_arg, 10);

    log_file = if (log_path) |p|
        try std.fs.cwd().createFile(p, .{ .truncate = true })
    else
        std.fs.File.stderr();

    const address = try std.net.Address.parseIp("0.0.0.0", port);
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();

    // Signal readiness the same way the bash harness's `wait_for_listen`
    // expects: by the time listen() returns above, the socket is already
    // bound and listening.
    while (true) {
        const conn = server.accept() catch continue;
        const t = std.Thread.spawn(.{}, handleConnection, .{ gpa, conn.stream }) catch {
            conn.stream.close();
            continue;
        };
        t.detach();
    }
}
