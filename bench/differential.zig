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
//! It reuses ztest's toml.zig (workload grammar), events.zig (typed event
//! decode), wire.zig (status/header/body framing), AND oliver.zig's Driver
//! (raw-TCP replay) via the single shared `ztest` module -- so it agrees
//! with the audit suite's driver and the server-under-test by construction.
//! The only differential-specific pieces are the Host header (nginx requires
//! one), the sha256 observation digests, and the divergence allowlist below.
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

/// Replay `evs` against one server via ztest's Driver (the same code path
/// the audit suite uses -- agreement by construction), then hash what was
/// observed per request id into `out`.
///
/// LOAD/UNLOAD apply to `root` (the serve dir both servers share);
/// infile paths resolve against the repo root (cwd), matching the runner.
fn replay(
    gpa: std.mem.Allocator,
    ep: Endpoint,
    root: std.fs.Dir,
    evs: []const ztest.events.Event,
    out: *ObsMap,
) !void {
    var driver = ztest.oliver.Driver.init(gpa, ep.host, ep.port, std.fs.cwd(), root, .{
        // HTTP/1.1 requires a Host header; nginx enforces it (400 without),
        // httpserver ignores it. The runner omits it because it only ever
        // talks to httpserver.
        .extra_headers = "Host: localhost\r\n",
    });
    defer driver.deinit();

    try driver.run(evs);

    var it = driver.responses.iterator();
    while (it.next()) |entry| {
        const rid = entry.key_ptr.*;
        const status = driver.statuses.get(rid) orelse 0; // 0 = unparseable status line
        var digest: Digest = undefined;
        Sha256.hash(entry.value_ptr.*, &digest, .{});
        const is_put = if (ztest.events.findCreate(evs, rid)) |c|
            std.mem.eql(u8, c.method, "PUT")
        else
            false;
        try out.put(rid, .{ .status = status, .body = digest, .is_put = is_put });
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
    const evs = try ztest.events.decode(gpa, w.events.items);
    defer gpa.free(evs);

    var root = try std.fs.cwd().openDir(root_path, .{});
    defer root.close();

    var obsA = ObsMap.init(gpa);
    defer obsA.deinit();
    var obsB = ObsMap.init(gpa);
    defer obsB.deinit();

    // Sequential passes over the shared root; each re-applies LOAD/UNLOAD.
    try replay(gpa, epA, root, evs, &obsA);
    try replay(gpa, epB, root, evs, &obsB);

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
