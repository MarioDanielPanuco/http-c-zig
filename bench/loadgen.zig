//! Zig-native closed-loop HTTP load generator for the thread-scaling sweep
//! (bench/scaling.sh). It exists because httpserver is strictly
//! one-request-per-connection: oha only *approximates* that with
//! --disable-keepalive, and wrk actively fights it (keep-alive + reconnect,
//! logging socket errors on every close). This generator opens one connection,
//! sends one request, drains the response to EOF, and closes -- the server's
//! exact model, natively, with no reconnect artifacts.
//!
//! It imports ztest's wire.zig read-only (status-line parsing), so it frames
//! responses the same way the driver + server-under-test do, by construction.
//! Framing is trivial here: both httpserver and nginx (keepalive_timeout 0)
//! close the socket after one response, so "read to EOF" *is* the full body --
//! we only parse the status line, off the first chunk.
//!
//! Closed-loop: -c CONN worker threads, each with one outstanding request at a
//! time (connect -> send -> recv -> close, repeat). Throughput = completed
//! responses / wall-clock. Per-request latency (connect through last byte) is
//! sampled per thread and merged for p50/p90/p99 -- no cross-thread contention
//! on the hot path (each thread owns its samples + counters; combined after
//! join).
//!
//! Usage (bench/scaling.sh owns server lifecycle + thread sweep):
//!   bench-loadgen <host:port> GET|PUT <path> [-c CONN] [-d SECS | -n REQS] [-b BODYFILE]
//! Emits ONE line to stdout, space-separated for `read -r`:
//!   <req_per_sec> <p50_ms> <p90_ms> <p99_ms> <requests> <errors> <mb_per_sec>
//! Diagnostics go to stderr.
const std = @import("std");
const wire = @import("wire");

const Config = struct {
    addr: std.net.Address,
    request: []const u8, // full request bytes (line + headers + optional body)
    deadline_ms: i64, // wall-clock stop time; ignored when quota > 0
    quota: u64, // per-thread request count for -n mode; 0 => duration mode
    gpa: std.mem.Allocator,
};

const Worker = struct {
    cfg: *const Config,
    samples: std.ArrayList(u32) = .empty, // per-request latency, microseconds
    requests: u64 = 0, // fully-received responses
    ok2xx: u64 = 0,
    io_errors: u64 = 0, // connect/write/pre-status read failures
    bytes: u64 = 0, // response bytes received
};

fn runWorker(w: *Worker) void {
    const cfg = w.cfg;
    var buf: [65536]u8 = undefined;

    while (true) {
        if (cfg.quota > 0) {
            if (w.requests + w.io_errors >= cfg.quota) break;
        } else if (std.time.milliTimestamp() >= cfg.deadline_ms) {
            break;
        }

        const start = std.time.Instant.now() catch {
            w.io_errors += 1;
            continue;
        };

        const stream = std.net.tcpConnectToAddress(cfg.addr) catch {
            w.io_errors += 1;
            continue;
        };

        stream.writeAll(cfg.request) catch {
            stream.close();
            w.io_errors += 1;
            continue;
        };
        // Half-close so the server sees request EOF (matters for PUT, whose
        // body length the server otherwise reads by Content-Length; harmless
        // for GET). Mirrors the driver + differential oracle.
        std.posix.shutdown(stream.handle, .send) catch {};

        var total: usize = 0;
        var status: u16 = 0;
        var got_status = false;
        while (true) {
            // A close/reset ends the read; the server is close-per-request, so
            // EOF here is the end of the (only) response.
            const n = stream.read(&buf) catch break;
            if (n == 0) break;
            if (!got_status) {
                if (wire.parseStatusLine(buf[0..n])) |sl| status = sl.code;
                got_status = true;
            }
            total += n;
        }
        stream.close();

        const end = std.time.Instant.now() catch start;
        const lat_us: u32 = @intCast(@min(end.since(start) / std.time.ns_per_us, std.math.maxInt(u32)));

        if (!got_status) {
            // Connected but the peer closed before any bytes -- count as an
            // I/O error, not a completed request.
            w.io_errors += 1;
            continue;
        }
        w.requests += 1;
        w.bytes += total;
        if (status >= 200 and status < 300) w.ok2xx += 1;
        w.samples.append(cfg.gpa, lat_us) catch {};
    }
}

fn parseEndpoint(s: []const u8) !std.net.Address {
    const colon = std.mem.lastIndexOfScalar(u8, s, ':') orelse return error.BadEndpoint;
    const host = s[0..colon];
    const port = try std.fmt.parseInt(u16, s[colon + 1 ..], 10);
    return std.net.Address.resolveIp(host, port);
}

fn pct(sorted: []const u32, p: u64) f64 {
    if (sorted.len == 0) return 0;
    const idx = (sorted.len - 1) * p / 100;
    return @as(f64, @floatFromInt(sorted[idx])) / 1000.0; // us -> ms
}

pub fn main() !void {
    const gpa = std.heap.page_allocator;

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);
    if (args.len < 4) {
        std.debug.print(
            "usage: {s} <host:port> GET|PUT <path> [-c CONN] [-d SECS | -n REQS] [-b BODYFILE]\n",
            .{args[0]},
        );
        std.process.exit(2);
    }

    const addr = try parseEndpoint(args[1]);
    const method = args[2];
    const path = args[3];

    var conns: usize = 4;
    var dur_s: u64 = 10;
    var reqs_total: u64 = 0; // 0 => duration mode
    var body_file: ?[]const u8 = null;

    var i: usize = 4;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-c")) {
            i += 1;
            conns = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, a, "-d")) {
            i += 1;
            dur_s = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, a, "-n")) {
            i += 1;
            reqs_total = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, a, "-b")) {
            i += 1;
            body_file = args[i];
        } else {
            std.debug.print("loadgen: unknown arg '{s}'\n", .{a});
            std.process.exit(2);
        }
    }
    if (conns == 0) conns = 1;

    // Build the request bytes once, shared read-only by every worker.
    var body: []const u8 = &.{};
    if (body_file) |bf| body = try std.fs.cwd().readFileAlloc(gpa, bf, 1 << 30);

    var req: std.ArrayList(u8) = .empty;
    try req.print(gpa, "{s} {s} HTTP/1.1\r\nHost: localhost\r\n", .{ method, path });
    if (body.len > 0) try req.print(gpa, "Content-Length: {d}\r\n", .{body.len});
    try req.appendSlice(gpa, "\r\n");
    if (body.len > 0) try req.appendSlice(gpa, body);
    const request = try req.toOwnedSlice(gpa);

    // Per-thread quota in -n mode: split the total evenly (last thread eats the
    // remainder), so N connections issue exactly reqs_total requests combined.
    const quota: u64 = if (reqs_total > 0)
        (reqs_total + conns - 1) / conns
    else
        0;

    var cfg = Config{
        .addr = addr,
        .request = request,
        .deadline_ms = std.time.milliTimestamp() + @as(i64, @intCast(dur_s * 1000)),
        .quota = quota,
        .gpa = gpa,
    };

    const workers = try gpa.alloc(Worker, conns);
    defer gpa.free(workers);
    for (workers) |*w| w.* = .{ .cfg = &cfg };

    const threads = try gpa.alloc(std.Thread, conns);
    defer gpa.free(threads);

    const wall_start = try std.time.Instant.now();
    for (threads, workers) |*t, *w| t.* = try std.Thread.spawn(.{}, runWorker, .{w});
    for (threads) |t| t.join();
    const wall_end = try std.time.Instant.now();
    const elapsed_s = @as(f64, @floatFromInt(wall_end.since(wall_start))) / std.time.ns_per_s;

    // Merge for aggregate stats.
    var all: std.ArrayList(u32) = .empty;
    defer all.deinit(gpa);
    var requests: u64 = 0;
    var ok2xx: u64 = 0;
    var io_errors: u64 = 0;
    var bytes: u64 = 0;
    for (workers) |*w| {
        requests += w.requests;
        ok2xx += w.ok2xx;
        io_errors += w.io_errors;
        bytes += w.bytes;
        try all.appendSlice(gpa, w.samples.items);
        w.samples.deinit(gpa);
    }
    std.mem.sort(u32, all.items, {}, std.sort.asc(u32));

    const rps = if (elapsed_s > 0) @as(f64, @floatFromInt(requests)) / elapsed_s else 0;
    const mbps = if (elapsed_s > 0) @as(f64, @floatFromInt(bytes)) / elapsed_s / 1_000_000.0 else 0;
    // errors = connection/IO failures + non-2xx responses.
    const errors = io_errors + (requests - ok2xx);

    var stdout_buf: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(&stdout_buf, "{d:.0} {d:.3} {d:.3} {d:.3} {d} {d} {d:.1}\n", .{
        rps,
        pct(all.items, 50),
        pct(all.items, 90),
        pct(all.items, 99),
        requests,
        errors,
        mbps,
    });
    _ = try std.fs.File.stdout().writeAll(line);
}
