//! Audit-log checking: the Zig-native replacement for sherlock.py +
//! watson.py, operating directly on a parsed workload (toml.Workload)
//! instead of a separately-recorded oliver send-log. That's a valid
//! simplification here: ztest's driver (oliver.zig) executes workload
//! events strictly in file order (no background/eager draining like the
//! Python reference), so "the order events were issued in" is always
//! exactly "the order they appear in the TOML file" -- there is no need to
//! separately record a timestamped send-log to reconstruct that order.
//!
//! Two checks, matching the two detectives:
//!   - `checkOrdering` (sherlock): is the audit log a linear extension of
//!     the partial order implied by the workload (if R2 connects only
//!     after R1's WAIT completed, R1 must be logged first)?
//!   - `checkReplay` (watson): replayed against a *fresh* scratch
//!     filesystem, in audit-log order, do GET/PUT results match what the
//!     driver actually observed on the wire?
const std = @import("std");
const toml = @import("toml.zig");

pub const Result = struct {
    ok: bool = true,
    messages: std.ArrayList([]const u8) = .empty,

    fn fail(self: *Result, a: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
        self.ok = false;
        try self.messages.append(a, try std.fmt.allocPrint(a, fmt, args));
    }
};

pub const Op = struct {
    oper: []const u8,
    uri: []const u8,
    status: u16,
    rid: i64,
};

pub const AuditParseError = error{MalformedLine} || std.mem.Allocator.Error;

/// Parses raw audit-log text ("GET,/uri,200,0\n" per line, one per
/// request) into a list of Ops. Malformed lines (not exactly 4
/// comma-separated fields, or a non-numeric status/rid) are reported as
/// well-formedness violations rather than making the whole parse fail, so
/// a single garbled/interleaved line (the classic "log write isn't atomic"
/// bug) shows up as a specific, actionable diagnostic.
pub fn parseAuditLog(a: std.mem.Allocator, text: []const u8) !struct { ops: std.ArrayList(Op), result: Result } {
    var ops: std.ArrayList(Op) = .empty;
    var result = Result{};

    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        line_no += 1;
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;

        var fields: [4][]const u8 = undefined;
        var count: usize = 0;
        var it = std.mem.splitScalar(u8, line, ',');
        while (it.next()) |f| {
            if (count < 4) fields[count] = f;
            count += 1;
        }
        if (count != 4) {
            try result.fail(a, "audit log line {d}: expected 4 comma-separated fields (Oper,URI,Status,RequestID), got {d}: {s}", .{ line_no, count, line });
            continue;
        }
        const status = std.fmt.parseInt(u16, fields[2], 10) catch {
            try result.fail(a, "audit log line {d}: status {s} is not an integer", .{ line_no, fields[2] });
            continue;
        };
        const rid = std.fmt.parseInt(i64, fields[3], 10) catch {
            try result.fail(a, "audit log line {d}: request id {s} is not an integer", .{ line_no, fields[3] });
            continue;
        };
        try ops.append(a, .{ .oper = fields[0], .uri = fields[1], .status = status, .rid = rid });
    }

    return .{ .ops = ops, .result = result };
}

/// Finds the CREATE event for a given request id (the one carrying
/// method/uri/infile); returns null if the workload never created that id.
fn findCreate(events: []const toml.Table, rid: i64) ?toml.Table {
    for (events) |ev| {
        const t = ev.getStr("type") orelse continue;
        if (!std.mem.eql(u8, t, "CREATE")) continue;
        if (ev.getId()) |id| {
            if (id == rid) return ev;
        }
    }
    return null;
}

/// sherlock: does the audit log present a valid total ordering of the
/// partial order implied by the workload's CONNECT/WAIT events?
pub fn checkOrdering(a: std.mem.Allocator, events: []const toml.Table, ops: []const Op) !Result {
    var result = Result{};

    // happened[rid] = snapshot of `finished` at the moment rid was first
    // created (CREATE is always first per id in these workloads, matching
    // olivertwist's CONNECT).
    var happened = std.AutoHashMap(i64, std.AutoHashMap(i64, void)).init(a);
    defer {
        var vit = happened.valueIterator();
        while (vit.next()) |snap| snap.deinit();
        happened.deinit();
    }
    var finished = std.AutoHashMap(i64, void).init(a);
    defer finished.deinit();
    var seen_ids = std.AutoHashMap(i64, void).init(a);
    defer seen_ids.deinit();

    for (events) |ev| {
        const t = ev.getStr("type") orelse continue;
        const rid = ev.getId() orelse continue;
        if (std.mem.eql(u8, t, "CREATE")) {
            if (!seen_ids.contains(rid)) {
                try seen_ids.put(rid, {});
                var snapshot = std.AutoHashMap(i64, void).init(a);
                var it = finished.keyIterator();
                while (it.next()) |k| try snapshot.put(k.*, {});
                try happened.put(rid, snapshot);
            }
        } else if (std.mem.eql(u8, t, "WAIT")) {
            try finished.put(rid, {});
        }
    }

    var logged = std.AutoHashMap(i64, void).init(a);
    defer logged.deinit();
    for (ops, 0..) |op, i| {
        const snap = happened.get(op.rid) orelse {
            try result.fail(a, "audit log line {d}: request id {d} was never CREATEd by this workload", .{ i + 1, op.rid });
            continue;
        };
        var it = snap.keyIterator();
        while (it.next()) |k| {
            if (!logged.contains(k.*)) {
                try result.fail(a, "audit log line {d} (rid {d}): request {d} must have been logged first (it finished before rid {d} even connected), but wasn't yet", .{ i + 1, op.rid, k.*, op.rid });
            }
        }
        try logged.put(op.rid, {});
    }

    return result;
}

/// watson: replay LOAD + (GET/PUT per audit-log order) into a fresh
/// scratch directory, and check the resulting bodies match what the
/// driver actually captured on the wire for each request id.
///
/// `repo_root` resolves the infile/outfile paths the same way the
/// workload TOML does (e.g. "test_files/antihero.txt"). `responses` maps
/// request id -> the response body bytes the driver actually received.
pub fn checkReplay(
    a: std.mem.Allocator,
    events: []const toml.Table,
    ops: []const Op,
    repo_root: std.fs.Dir,
    responses: std.AutoHashMap(i64, []const u8),
) !Result {
    var result = Result{};

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const replay_dir = tmp.dir;

    // Seed with every LOAD in the workload (they always precede requests
    // in these workloads; matching watson.py's `loads + ... `).
    for (events) |ev| {
        const t = ev.getStr("type") orelse continue;
        if (!std.mem.eql(u8, t, "LOAD")) continue;
        const infile = ev.getStr("infile") orelse continue;
        const outfile = ev.getStr("outfile") orelse continue;
        const bytes = repo_root.readFileAlloc(a, infile, 1 << 30) catch |err| {
            try result.fail(a, "LOAD {s}: couldn't read from repo: {t}", .{ infile, err });
            continue;
        };
        defer a.free(bytes);
        try replay_dir.writeFile(.{ .sub_path = outfile, .data = bytes });
    }

    for (ops, 0..) |op, i| {
        const create = findCreate(events, op.rid) orelse continue; // already reported by checkOrdering
        const method = create.getStr("method") orelse "GET";
        const uri = create.getStr("uri") orelse op.uri;

        // Spec requires Oper to be the literal request method (GET/PUT),
        // not e.g. the response's reason phrase -- a real bug this catches:
        // an audit_send_response that logs response_get_message() instead
        // of the method.
        if (!std.mem.eql(u8, op.oper, method)) {
            try result.fail(a, "audit line {d} (rid {d}): Oper field is {s}, expected the request method {s}", .{ i + 1, op.rid, op.oper, method });
        }

        var expected: []const u8 = &.{};
        if (std.mem.eql(u8, method, "GET")) {
            expected = replay_dir.readFileAlloc(a, uri, 1 << 30) catch |err| switch (err) {
                error.FileNotFound => try a.dupe(u8, "Not Found\n"),
                else => {
                    try result.fail(a, "audit line {d} (rid {d}): replay GET {s} failed: {t}", .{ i + 1, op.rid, uri, err });
                    continue;
                },
            };
        } else if (std.mem.eql(u8, method, "PUT")) {
            const infile = create.getStr("infile") orelse "";
            const existed = blk: {
                replay_dir.access(uri, .{}) catch break :blk false;
                break :blk true;
            };
            expected = try a.dupe(u8, if (existed) "OK\n" else "Created\n");
            const bytes = repo_root.readFileAlloc(a, infile, 1 << 30) catch |err| {
                try result.fail(a, "audit line {d} (rid {d}): PUT infile {s} couldn't be read: {t}", .{ i + 1, op.rid, infile, err });
                continue;
            };
            defer a.free(bytes);
            try replay_dir.writeFile(.{ .sub_path = uri, .data = bytes });
        } else {
            // Anything else (RESPONSE_NOT_IMPLEMENTED etc.) has no
            // filesystem effect to replay.
            continue;
        }
        defer a.free(expected);

        const actual = responses.get(op.rid) orelse {
            try result.fail(a, "audit line {d} (rid {d}): no recorded response body to compare against (WAIT never ran?)", .{ i + 1, op.rid });
            continue;
        };
        if (!std.mem.eql(u8, expected, actual)) {
            try result.fail(a, "audit line {d} (rid {d}): replay of {s} {s} expected body {any} (len {d}) but driver observed {any} (len {d})", .{
                i + 1,
                op.rid,
                method,
                uri,
                std.zig.fmtString(if (expected.len > 64) expected[0..64] else expected),
                expected.len,
                std.zig.fmtString(if (actual.len > 64) actual[0..64] else actual),
                actual.len,
            });
        }
    }

    return result;
}

test "checkOrdering accepts a correctly-ordered sequential log" {
    const a = std.testing.allocator;
    const text =
        \\[[events]]
        \\type = "CREATE"
        \\method = "GET"
        \\uri = "a.txt"
        \\id = 0
        \\
        \\[[events]]
        \\type = "WAIT"
        \\id = 0
        \\
        \\[[events]]
        \\type = "CREATE"
        \\method = "GET"
        \\uri = "b.txt"
        \\id = 1
        \\
        \\[[events]]
        \\type = "WAIT"
        \\id = 1
    ;
    var w = try toml.parse(a, text);
    defer w.deinit();

    const audit_text = "GET,a.txt,200,0\nGET,b.txt,200,1\n";
    var parsed = try parseAuditLog(a, audit_text);
    defer parsed.ops.deinit(a);
    try std.testing.expect(parsed.result.ok);

    var result = try checkOrdering(a, w.events.items, parsed.ops.items);
    defer result.messages.deinit(a);
    try std.testing.expect(result.ok);
}

test "checkOrdering rejects a log that reorders sequential requests" {
    const a = std.testing.allocator;
    const text =
        \\[[events]]
        \\type = "CREATE"
        \\method = "GET"
        \\uri = "a.txt"
        \\id = 0
        \\
        \\[[events]]
        \\type = "WAIT"
        \\id = 0
        \\
        \\[[events]]
        \\type = "CREATE"
        \\method = "GET"
        \\uri = "b.txt"
        \\id = 1
        \\
        \\[[events]]
        \\type = "WAIT"
        \\id = 1
    ;
    var w = try toml.parse(a, text);
    defer w.deinit();

    // b.txt (id 1) connected only after a.txt (id 0) fully finished, so
    // the audit log MUST show id 0 before id 1. This log has it backwards.
    const audit_text = "GET,b.txt,200,1\nGET,a.txt,200,0\n";
    var parsed = try parseAuditLog(a, audit_text);
    defer parsed.ops.deinit(a);

    var result = try checkOrdering(a, w.events.items, parsed.ops.items);
    defer {
        for (result.messages.items) |m| a.free(m);
        result.messages.deinit(a);
    }
    try std.testing.expect(!result.ok);
}

test "parseAuditLog flags malformed lines instead of crashing" {
    const a = std.testing.allocator;
    var parsed = try parseAuditLog(a, "GET,a.txt,200,0\nnot,enough,fields\nPUT,b.txt,abc,1\n");
    defer {
        parsed.ops.deinit(a);
        for (parsed.result.messages.items) |m| a.free(m);
        parsed.result.messages.deinit(a);
    }
    try std.testing.expect(!parsed.result.ok);
    try std.testing.expectEqual(@as(usize, 1), parsed.ops.items.len); // only the first line was well-formed
    try std.testing.expectEqual(@as(usize, 2), parsed.result.messages.items.len);
}

test "checkReplay matches a GET-then-PUT-then-GET sequence" {
    const a = std.testing.allocator;

    var repo_tmp = std.testing.tmpDir(.{});
    defer repo_tmp.cleanup();
    try repo_tmp.dir.makePath("test_files");
    try repo_tmp.dir.writeFile(.{ .sub_path = "test_files/seed.txt", .data = "hello\n" });

    const text =
        \\[[events]]
        \\type = "LOAD"
        \\infile = "test_files/seed.txt"
        \\outfile = "seeded.txt"
        \\
        \\[[events]]
        \\type = "CREATE"
        \\method = "GET"
        \\uri = "missing.txt"
        \\id = 0
        \\
        \\[[events]]
        \\type = "CREATE"
        \\method = "PUT"
        \\uri = "missing.txt"
        \\infile = "test_files/seed.txt"
        \\id = 1
        \\
        \\[[events]]
        \\type = "CREATE"
        \\method = "GET"
        \\uri = "missing.txt"
        \\id = 2
    ;
    var w = try toml.parse(a, text);
    defer w.deinit();

    // Order: 0 (404, not yet created) -> 1 (PUT creates it, 201) -> 2 (GET sees the new content)
    const audit_text = "GET,missing.txt,404,0\nPUT,missing.txt,201,1\nGET,missing.txt,200,2\n";
    var parsed = try parseAuditLog(a, audit_text);
    defer parsed.ops.deinit(a);

    var responses = std.AutoHashMap(i64, []const u8).init(a);
    defer responses.deinit();
    try responses.put(0, "Not Found\n");
    try responses.put(1, "Created\n");
    try responses.put(2, "hello\n");

    var result = try checkReplay(a, w.events.items, parsed.ops.items, repo_tmp.dir, responses);
    defer {
        for (result.messages.items) |m| a.free(m);
        result.messages.deinit(a);
    }
    try std.testing.expect(result.ok);
}

test "checkReplay flags a response body that disagrees with the claimed order" {
    const a = std.testing.allocator;

    var repo_tmp = std.testing.tmpDir(.{});
    defer repo_tmp.cleanup();
    try repo_tmp.dir.makePath("test_files");
    try repo_tmp.dir.writeFile(.{ .sub_path = "test_files/seed.txt", .data = "hello\n" });

    const text =
        \\[[events]]
        \\type = "CREATE"
        \\method = "PUT"
        \\uri = "f.txt"
        \\infile = "test_files/seed.txt"
        \\id = 0
        \\
        \\[[events]]
        \\type = "CREATE"
        \\method = "GET"
        \\uri = "f.txt"
        \\id = 1
    ;
    var w = try toml.parse(a, text);
    defer w.deinit();

    const audit_text = "PUT,f.txt,201,0\nGET,f.txt,200,1\n";
    var parsed = try parseAuditLog(a, audit_text);
    defer parsed.ops.deinit(a);

    var responses = std.AutoHashMap(i64, []const u8).init(a);
    defer responses.deinit();
    try responses.put(0, "Created\n");
    // Bug: the GET response the driver actually saw doesn't match the
    // file the PUT should have written, even though the log claims PUT
    // happened first.
    try responses.put(1, "SOMETHING ELSE ENTIRELY\n");

    var result = try checkReplay(a, w.events.items, parsed.ops.items, repo_tmp.dir, responses);
    defer {
        for (result.messages.items) |m| a.free(m);
        result.messages.deinit(a);
    }
    try std.testing.expect(!result.ok);
}
