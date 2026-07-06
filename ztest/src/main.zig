//! ztest-runner: the Zig-native replacement for
//! test_scripts/{olivertwist,sherlock,watson}.py + test_repo.sh.
//!
//! Usage: ztest-runner <path-to-server-binary>
//!   (or set HTTPSERVER_BIN instead of passing an argument)
//!
//! Must be run from the repo root (same requirement the bash harness has:
//! it reads workloads/*.toml and test_files/*).
//!
//! Phase 1 (smoke): a hand-written tiny workload exercising GET 200/404
//! and PUT 200/201 over raw TCP, independent of the workloads/ fixtures.
//! Phase 2: every workload in workloads/ that test_scripts/*.sh actually
//! exercises (see WORKLOADS below), replaying sherlock+watson's checks.
const std = @import("std");
const ztest = @import("ztest");
const toml = ztest.toml;
const audit = ztest.audit;
const oliver = ztest.oliver;

const WorkloadSpec = struct {
    file: []const u8,
    threads: u32,
};

// Mirrors test_scripts/*.sh's (workload, thread-count) pairs -- the same
// set test_repo.sh runs, plus nconflict_pause_puts.toml which has no .sh
// wrapper but belongs to the same family. See docs/PLAN.md M2/M3 accept
// criteria.
const WORKLOADS = [_]WorkloadSpec{
    .{ .file = "workloads/audit_get.toml", .threads = 1 },
    .{ .file = "workloads/audit_put.toml", .threads = 1 },
    .{ .file = "workloads/audit_mix.toml", .threads = 1 },
    .{ .file = "workloads/conflict_pause_gets.toml", .threads = 4 },
    .{ .file = "workloads/conflict_pause_puts.toml", .threads = 4 },
    .{ .file = "workloads/conflict_stress_mix.toml", .threads = 4 },
    .{ .file = "workloads/conflict_stress_put.toml", .threads = 4 },
    .{ .file = "workloads/nconflict_pause.toml", .threads = 4 },
    .{ .file = "workloads/nconflict_pause_puts.toml", .threads = 4 },
    .{ .file = "workloads/nconflict_stress.toml", .threads = 4 },
};

const SMOKE_TOML =
    \\[[events]]
    \\type = "CREATE"
    \\method = "PUT"
    \\uri = "ztest-smoke.txt"
    \\infile = "ztest/src/main.zig"
    \\id = 0
    \\
    \\[[events]]
    \\type = "SEND_ALL"
    \\id = 0
    \\
    \\[[events]]
    \\type = "WAIT"
    \\id = 0
    \\
    \\[[events]]
    \\type = "CREATE"
    \\method = "PUT"
    \\uri = "ztest-smoke.txt"
    \\infile = "ztest/src/main.zig"
    \\id = 1
    \\
    \\[[events]]
    \\type = "SEND_ALL"
    \\id = 1
    \\
    \\[[events]]
    \\type = "WAIT"
    \\id = 1
    \\
    \\[[events]]
    \\type = "CREATE"
    \\method = "GET"
    \\uri = "ztest-smoke.txt"
    \\id = 2
    \\
    \\[[events]]
    \\type = "SEND_ALL"
    \\id = 2
    \\
    \\[[events]]
    \\type = "WAIT"
    \\id = 2
    \\
    \\[[events]]
    \\type = "CREATE"
    \\method = "GET"
    \\uri = "ztest-smoke-missing.txt"
    \\id = 3
    \\
    \\[[events]]
    \\type = "SEND_ALL"
    \\id = 3
    \\
    \\[[events]]
    \\type = "WAIT"
    \\id = 3
;

pub fn main() !u8 {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    const bin_path_arg = if (args.len > 1)
        args[1]
    else
        std.process.getEnvVarOwned(gpa, "HTTPSERVER_BIN") catch {
            std.debug.print("usage: ztest-runner <path-to-server-binary>  (or set HTTPSERVER_BIN)\n", .{});
            return 2;
        };
    // Each workload spawns the server with its cwd set to a fresh scratch
    // directory (so it serves files from there, not the repo). A relative
    // bin_path_arg would then resolve against *that* directory instead of
    // wherever ztest-runner was launched from, so resolve to an absolute
    // path up front.
    const bin_path = std.fs.cwd().realpathAlloc(gpa, bin_path_arg) catch |err| {
        std.debug.print("error: couldn't resolve server binary path {s}: {t}\n", .{ bin_path_arg, err });
        return 2;
    };
    defer gpa.free(bin_path);

    const repo_root = std.fs.cwd();
    // Sanity check we're being run from the repo root, the same
    // precondition the bash harness has.
    repo_root.access("workloads", .{}) catch {
        std.debug.print("error: run ztest-runner from the repo root (workloads/ not found in cwd)\n", .{});
        return 2;
    };

    var overall_ok = true;

    std.debug.print("== phase 1: smoke ({s}) ==\n", .{bin_path});
    var w = try toml.parse(gpa, SMOKE_TOML);
    defer w.deinit();
    const smoke_ok = runOne(gpa, bin_path, "smoke", w.events.items, 2, repo_root) catch |err| blk: {
        std.debug.print("smoke: runner error: {t}\n", .{err});
        break :blk false;
    };
    printResult("smoke", smoke_ok);
    overall_ok = overall_ok and smoke_ok;

    std.debug.print("\n== phase 2: workload suite ==\n", .{});
    for (WORKLOADS) |spec| {
        const text = repo_root.readFileAlloc(gpa, spec.file, 16 << 20) catch |err| {
            std.debug.print("{s}: couldn't read workload: {t}\n", .{ spec.file, err });
            overall_ok = false;
            continue;
        };
        defer gpa.free(text);
        var wl = toml.parse(gpa, text) catch |err| {
            std.debug.print("{s}: TOML parse error: {t}\n", .{ spec.file, err });
            overall_ok = false;
            continue;
        };
        defer wl.deinit();

        const ok = runOne(gpa, bin_path, spec.file, wl.events.items, spec.threads, repo_root) catch |err| blk: {
            std.debug.print("{s}: runner error: {t}\n", .{ spec.file, err });
            break :blk false;
        };
        printResult(spec.file, ok);
        overall_ok = overall_ok and ok;
    }

    return if (overall_ok) 0 else 1;
}

fn printResult(name: []const u8, ok: bool) void {
    std.debug.print("  {s}: {s}\n", .{ name, if (ok) "PASS" else "FAIL" });
}

/// Owns one spawned server process: fresh scratch cwd, free port, stderr
/// (= audit log) drained on a background thread, readiness-probed via TCP.
const ServerUnderTest = struct {
    child: std.process.Child,
    scratch: Scratch,
    drain: *Drain,
    drain_thread: std.Thread,
    port: u16,
    stopped: bool = false,

    const Drain = struct {
        file: std.fs.File,
        gpa: std.mem.Allocator,
        // gpa-owned (NOT the arena): audit.parseAuditLog stores slices
        // *into* buf rather than copies, so it must outlive every use of
        // the parsed ops -- freed only in deinit(), after all checks ran.
        buf: std.ArrayList(u8) = .empty,

        fn run(d: *Drain) void {
            var chunk: [4096]u8 = undefined;
            while (true) {
                const n = d.file.read(&chunk) catch return;
                if (n == 0) return;
                d.buf.appendSlice(d.gpa, chunk[0..n]) catch return;
            }
        }
    };

    /// Spawns `bin_path -t threads <port>` with cwd set to a fresh scratch
    /// directory and waits (up to 5s) for the port to accept connections.
    /// `arena` owns the scratch path and the Drain struct itself.
    fn start(
        arena: std.mem.Allocator,
        gpa: std.mem.Allocator,
        bin_path: []const u8,
        name: []const u8,
        threads: u32,
    ) !ServerUnderTest {
        var scratch = try makeScratchDir(arena, name);
        errdefer scratch.dir.close();

        const port = try pickFreePort();

        var threads_buf: [16]u8 = undefined;
        const threads_str = try std.fmt.bufPrint(&threads_buf, "{d}", .{threads});
        var port_buf: [16]u8 = undefined;
        const port_str = try std.fmt.bufPrint(&port_buf, "{d}", .{port});

        var child = std.process.Child.init(&.{ bin_path, "-t", threads_str, port_str }, gpa);
        child.cwd = scratch.path;
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Pipe;
        try child.spawn();
        errdefer _ = child.kill() catch {};

        const drain = try arena.create(Drain);
        drain.* = .{ .file = child.stderr.?, .gpa = gpa };
        const drain_thread = try std.Thread.spawn(.{}, Drain.run, .{drain});

        if (!waitForListen("127.0.0.1", port, 5000)) {
            std.debug.print("{s}: server never started listening on {d}\n", .{ name, port });
            _ = child.kill() catch {};
            drain_thread.join();
            drain.buf.deinit(gpa);
            return error.ServerNeverListened;
        }

        return .{
            .child = child,
            .scratch = scratch,
            .drain = drain,
            .drain_thread = drain_thread,
            .port = port,
        };
    }

    /// Kills the server (idempotent) and returns the complete audit-log
    /// bytes. The slice is owned by this struct; valid until deinit().
    fn stop(self: *ServerUnderTest) []const u8 {
        if (!self.stopped) {
            self.stopped = true;
            _ = self.child.kill() catch {};
            self.drain_thread.join();
        }
        return self.drain.buf.items;
    }

    fn deinit(self: *ServerUnderTest) void {
        _ = self.stop();
        self.drain.buf.deinit(self.drain.gpa);
        self.scratch.dir.close();
        // Best-effort: leaving a scratch dir behind is useful for debugging
        // a failure, so cleanup errors are not fatal.
        std.fs.deleteTreeAbsolute(self.scratch.path) catch {};
    }
};

/// Spawns the server in a fresh scratch dir, drives `tables` against it,
/// tears it down, and checks the resulting audit log for well-formedness +
/// ordering (sherlock) + replay consistency (watson).
fn runOne(
    gpa: std.mem.Allocator,
    bin_path: []const u8,
    name: []const u8,
    tables: []const toml.Table,
    threads: u32,
    repo_root: std.fs.Dir,
) !bool {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const evs = try ztest.events.decode(a, tables);

    var sut = try ServerUnderTest.start(a, gpa, bin_path, name, threads);
    defer sut.deinit();

    var driver = oliver.Driver.init(gpa, "127.0.0.1", sut.port, repo_root, sut.scratch.dir);
    defer driver.deinit();

    var ok = true;
    driver.run(evs) catch |err| {
        std.debug.print("{s}: driver error: {t}\n", .{ name, err });
        ok = false;
    };

    const audit_text = sut.stop();
    const parsed = try audit.parseAuditLog(a, audit_text);
    report(&ok, parsed.result);

    const ops = try filterDrivenOps(a, parsed.ops.items);

    const order_result = try audit.checkOrdering(a, evs, ops);
    report(&ok, order_result);

    const replay_result = try audit.checkReplay(a, evs, ops, repo_root, driver.responses);
    report(&ok, replay_result);

    return ok;
}

/// Folds one check's outcome into the overall verdict and prints its
/// diagnostics.
fn report(ok: *bool, result: audit.Result) void {
    if (!result.ok) ok.* = false;
    for (result.messages.items) |m| std.debug.print("    - {s}\n", .{m});
}

/// waitForListen() probes readiness by opening a TCP connection and
/// immediately closing it without sending a request. A spec-correct server
/// (verified against the authoritative olivertwist/sherlock/watson harness)
/// treats that as a malformed request and emits one `UNSUPPORTED,,400,0`
/// audit line per spawn. That phantom is not a workload request -- worse,
/// left in it corrupts replay filesystem state (its rid collides with the
/// workload's rid 0). Drop non-GET/PUT ops before the sherlock/watson
/// checks; no suite workload issues any other method, so this only ever
/// removes probe noise. Well-formedness still runs over every line.
fn filterDrivenOps(a: std.mem.Allocator, ops: []const audit.Op) ![]const audit.Op {
    var driven: std.ArrayList(audit.Op) = .empty;
    for (ops) |op| {
        if (std.mem.eql(u8, op.oper, "GET") or std.mem.eql(u8, op.oper, "PUT")) {
            try driven.append(a, op);
        }
    }
    return driven.toOwnedSlice(a);
}

const Scratch = struct {
    path: []const u8,
    dir: std.fs.Dir,
};

var scratch_counter: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

fn makeScratchDir(a: std.mem.Allocator, name: []const u8) !Scratch {
    const base = std.process.getEnvVarOwned(a, "TMPDIR") catch try a.dupe(u8, "/tmp");
    const n = scratch_counter.fetchAdd(1, .monotonic);
    const sanitized_name = try a.dupe(u8, name);
    for (sanitized_name) |*c| {
        if (c.* == '/' or c.* == '.') c.* = '_';
    }
    const path = try std.fmt.allocPrint(a, "{s}/ztest-{s}-{d}-{d}", .{ base, sanitized_name, std.time.milliTimestamp(), n });
    try std.fs.makeDirAbsolute(path);
    const dir = try std.fs.openDirAbsolute(path, .{});
    return .{ .path = path, .dir = dir };
}

fn pickFreePort() !u16 {
    const address = try std.net.Address.parseIp("127.0.0.1", 0);
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();
    return server.listen_address.getPort();
}

fn waitForListen(host: []const u8, port: u16, timeout_ms: u64) bool {
    var waited: u64 = 0;
    const step_ms = 20;
    while (waited < timeout_ms) : (waited += step_ms) {
        const stream = std.net.tcpConnectToHost(std.heap.page_allocator, host, port) catch {
            std.Thread.sleep(step_ms * std.time.ns_per_ms);
            continue;
        };
        stream.close();
        return true;
    }
    return false;
}
