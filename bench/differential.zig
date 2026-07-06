//! Semantic differential oracle: replay a workload against TWO HTTP servers
//! (./httpserver and nginx) and check that they agree on the *observable HTTP
//! semantics* -- status code, and for GETs the response body bytes.
//!
//! This is the "test suite vs an open-source server" piece: there is no
//! off-the-shelf black-box conformance suite for a GET/PUT static server, so we
//! turn the existing workloads/audit_*.toml fixtures into a cross-implementation
//! oracle. The audit-log *linearizability* guarantee is unique to ./httpserver
//! (no stock server emits that log), so it stays checked by ztest alone; here we
//! only compare what any HTTP client can observe.
//!
//! It shares ztest's wire.zig (status/header/body framing) and toml.zig
//! (workload grammar) as read-only imports, so it agrees with the driver +
//! server-under-test by construction. Driver reuse becomes possible now that
//! all tools share one ztest module instance; Task 6 of the 2026-07-05
//! refactor does exactly that.
//!
//! Usage (see bench/differential.sh, which owns process lifecycle):
//!   bench-differential <workload.toml> <hostA:portA> <hostB:portB> <serve_root>
//! Both servers serve the same <serve_root>; the two passes run sequentially
//! (A fully, then B), each re-applying the workload's LOAD/UNLOAD steps, so the
//! filesystem state each server sees is identical and there is no concurrent
//! access to the shared root.
const std = @import("std");
const ztest = @import("ztest");
const toml = ztest.toml;
const wire = ztest.wire;

const Sha256 = std.crypto.hash.sha2.Sha256;
const Digest = [Sha256.digest_length]u8;

/// What one request looked like from the client's side.
const Observed = struct {
    status: u16,
    body: Digest, // sha256 of the response body bytes
    is_put: bool, // method was PUT (drives the write-status allowlist)
};

const ObsMap = std.AutoHashMap(i64, Observed);

const Endpoint = struct { host: []const u8, port: u16 };

fn parseEndpoint(s: []const u8) !Endpoint {
    const colon = std.mem.lastIndexOfScalar(u8, s, ':') orelse return error.BadEndpoint;
    return .{
        .host = s[0..colon],
        .port = try std.fmt.parseInt(u16, s[colon + 1 ..], 10),
    };
}

const Conn = struct {
    stream: std.net.Stream,
    is_put: bool,
    request_line: []const u8,
    headers: []const u8,
    body: []const u8,
};

/// Replay `events` against one server, recording per-rid observations in `out`.
/// LOAD/UNLOAD are applied to `root` inline (matching olivertwist/oliver.zig),
/// so the server sees the expected files at each step.
fn replay(
    gpa: std.mem.Allocator,
    ep: Endpoint,
    root: std.fs.Dir,
    events: []const toml.Table,
    out: *ObsMap,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var conns = std.AutoHashMap(i64, Conn).init(gpa);
    defer {
        var it = conns.valueIterator();
        while (it.next()) |c| c.stream.close();
        conns.deinit();
    }

    for (events) |ev| {
        const t = ev.getStr("type") orelse continue;

        if (std.mem.eql(u8, t, "LOAD")) {
            const infile = ev.getStr("infile") orelse return error.MissingField;
            const outfile = ev.getStr("outfile") orelse return error.MissingField;
            const bytes = try std.fs.cwd().readFileAlloc(a, infile, 1 << 30);
            try root.writeFile(.{ .sub_path = outfile, .data = bytes });
        } else if (std.mem.eql(u8, t, "UNLOAD")) {
            const file = ev.getStr("file") orelse return error.MissingField;
            root.deleteFile(file) catch {};
        } else if (std.mem.eql(u8, t, "SLEEP")) {
            const secs = ev.getInt("seconds") orelse 0;
            if (secs > 0) std.Thread.sleep(@as(u64, @intCast(secs)) * std.time.ns_per_s);
        } else if (std.mem.eql(u8, t, "CREATE")) {
            const id = ev.getId() orelse return error.MissingField;
            const uri = ev.getStr("uri") orelse return error.MissingField;
            const method = ev.getStr("method") orelse "GET";

            var body: []const u8 = &.{};
            if (ev.getStr("infile")) |infile| {
                body = try std.fs.cwd().readFileAlloc(a, infile, 1 << 30);
            }

            const request_line = try std.fmt.allocPrint(a, "{s} /{s} HTTP/1.1\r\n", .{ method, uri });
            var headers: std.ArrayList(u8) = .empty;
            // HTTP/1.1 requires a Host header; nginx enforces it (400 without),
            // httpserver ignores it. Send it so the request is well-formed for
            // both. oliver.zig omits it because it only ever talks to httpserver.
            try headers.appendSlice(a, "Host: localhost\r\n");
            try headers.print(a, "Request-Id: {d}\r\n", .{id});
            if (body.len > 0) try headers.print(a, "Content-Length: {d}\r\n", .{body.len});
            try headers.appendSlice(a, "\r\n");

            const stream = try std.net.tcpConnectToHost(a, ep.host, ep.port);
            try conns.put(id, .{
                .stream = stream,
                .is_put = std.mem.eql(u8, method, "PUT"),
                .request_line = request_line,
                .headers = try headers.toOwnedSlice(a),
                .body = body,
            });
        } else if (std.mem.eql(u8, t, "SEND_ALL")) {
            const id = ev.getId() orelse return error.MissingField;
            const c = conns.getPtr(id) orelse return error.UnknownRequestId;
            try c.stream.writeAll(c.request_line);
            try c.stream.writeAll(c.headers);
            if (c.body.len > 0) try c.stream.writeAll(c.body);
            // half-close so the server sees EOF on the request body (mirrors
            // oliver.zig's shutdown(SHUT_WR) after the whole body is sent).
            std.posix.shutdown(c.stream.handle, .send) catch {};
        } else if (std.mem.eql(u8, t, "WAIT")) {
            const id = ev.getId() orelse return error.MissingField;
            const c = conns.getPtr(id) orelse return error.UnknownRequestId;

            var recv: std.ArrayList(u8) = .empty;
            var buf: [8192]u8 = undefined;
            while (true) {
                // A peer reset ends the response read gracefully rather than
                // aborting the whole run; we score whatever was received.
                const n = c.stream.read(&buf) catch |err| switch (err) {
                    error.ConnectionResetByPeer => break,
                    else => return err,
                };
                if (n == 0) break;
                try recv.appendSlice(a, buf[0..n]);
            }

            const status: u16 = if (wire.parseStatusLine(recv.items)) |sl| sl.code else 0;
            const body_start = wire.findBodyStart(recv.items) orelse recv.items.len;
            var digest: Digest = undefined;
            Sha256.hash(recv.items[body_start..], &digest, .{});

            try out.put(id, .{ .status = status, .body = digest, .is_put = c.is_put });
            c.stream.close();
            _ = conns.remove(id);
        } else {
            std.debug.print(
                "differential: unsupported event type '{s}' -- only the audit_* fixtures " ++
                    "(CREATE/SEND_ALL/WAIT/LOAD/UNLOAD/SLEEP) are supported\n",
                .{t},
            );
            return error.UnsupportedEvent;
        }
    }
}

fn is2xx(s: u16) bool {
    return s >= 200 and s < 300;
}

/// A PUT that wrote a file: httpserver answers 201 (new) / 200 (overwrite),
/// nginx dav answers 201 (new) / 204 (overwrite). All three mean "stored".
fn inWriteClass(s: u16) bool {
    return s == 200 or s == 201 or s == 204;
}

/// True when A and B's observations are considered equivalent -- either an
/// exact match, or a known, legitimate divergence between httpserver and nginx.
fn allowed(x: Observed, y: Observed) bool {
    // Exact agreement (the common GET-2xx case: identical status + body bytes).
    if (x.status == y.status and std.mem.eql(u8, &x.body, &y.body)) return true;

    // PUT write-success: statuses in {200,201,204}. The response *body* differs
    // by design (httpserver sends "Created\n"/"OK\n", nginx sends its own), so
    // for a successful PUT we compare only the status class, not the body.
    if (x.is_put and inWriteClass(x.status) and inWriteClass(y.status)) return true;

    // Non-2xx (404/403/505/...): httpserver sends a reason-phrase body, nginx an
    // HTML error page -- compare status only.
    if (!is2xx(x.status) and !is2xx(y.status) and x.status == y.status) return true;

    // Directory GET: httpserver returns 403 (no autoindex); nginx may 200
    // (autoindex) or 301 (redirect to trailing slash). Excluded by design.
    if ((x.status == 403 and (y.status == 200 or y.status == 301)) or
        (y.status == 403 and (x.status == 200 or x.status == 301))) return true;

    return false;
}

fn bodyNote(x: Observed, y: Observed) []const u8 {
    return if (std.mem.eql(u8, &x.body, &y.body)) "body=match" else "body=differ";
}

pub fn main() !void {
    const gpa = std.heap.page_allocator;

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);
    if (args.len != 5) {
        std.debug.print(
            "usage: {s} <workload.toml> <hostA:portA> <hostB:portB> <serve_root>\n",
            .{args[0]},
        );
        std.process.exit(2);
    }
    const workload_path = args[1];
    const epA = try parseEndpoint(args[2]);
    const epB = try parseEndpoint(args[3]);
    const root_path = args[4];

    const text = try std.fs.cwd().readFileAlloc(gpa, workload_path, 16 * 1024 * 1024);
    defer gpa.free(text);
    var w = try toml.parse(gpa, text);
    defer w.deinit();

    var root = try std.fs.cwd().openDir(root_path, .{});
    defer root.close();

    var obsA = ObsMap.init(gpa);
    defer obsA.deinit();
    var obsB = ObsMap.init(gpa);
    defer obsB.deinit();

    // Sequential passes over the shared root; each re-applies LOAD/UNLOAD.
    try replay(gpa, epA, root, w.events.items, &obsA);
    try replay(gpa, epB, root, w.events.items, &obsB);

    var mismatches: usize = 0;

    var it = obsA.iterator();
    while (it.next()) |entry| {
        const rid = entry.key_ptr.*;
        const x = entry.value_ptr.*;
        const y = obsB.get(rid) orelse {
            std.debug.print("MISMATCH rid={d}: A status={d}, but B has no response\n", .{ rid, x.status });
            mismatches += 1;
            continue;
        };
        if (!allowed(x, y)) {
            std.debug.print(
                "MISMATCH rid={d}: A(status={d}) vs B(status={d}) {s}\n",
                .{ rid, x.status, y.status, bodyNote(x, y) },
            );
            mismatches += 1;
        }
    }

    var itb = obsB.iterator();
    while (itb.next()) |entry| {
        if (obsA.get(entry.key_ptr.*) == null) {
            std.debug.print(
                "MISMATCH rid={d}: B status={d}, but A has no response\n",
                .{ entry.key_ptr.*, entry.value_ptr.*.status },
            );
            mismatches += 1;
        }
    }

    if (mismatches == 0) {
        std.debug.print(
            "differential OK: {d} requests, A and B agree (allowlisted divergences ignored)\n",
            .{obsA.count()},
        );
        std.process.exit(0);
    }
    std.debug.print("differential FAILED: {d} unallowlisted mismatch(es)\n", .{mismatches});
    std.process.exit(1);
}
