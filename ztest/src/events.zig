//! Typed workload events: decodes the stringly toml.Table list into a
//! validated Event union ONCE, so every consumer (the driver, the audit
//! checks, the bench differential) switches on typed payloads instead of
//! re-matching type strings and re-validating fields at each use site.
//!
//! Lifetime: Event string fields are borrowed slices into the parsed
//! toml.Workload's arena — keep the Workload alive as long as the events.
//!
//! Defaults applied here (single source of truth):
//!   - create.method: "GET"
//!   - sleep.seconds: 4   (the driver/reference semantic; the bench
//!     differential previously defaulted to 0 — unified per the 2026-07-05
//!     refactor spec, no fixture relies on the difference)
//!   - recv_partial.size: 4096
const std = @import("std");
const toml = @import("toml.zig");

pub const Create = struct {
    id: i64,
    method: []const u8,
    uri: []const u8,
    /// Request body source path (repo-root-relative); PUT only in practice.
    infile: ?[]const u8,
};

pub const Event = union(enum) {
    load: struct { infile: []const u8, outfile: []const u8 },
    unload: struct { file: []const u8 },
    sleep: struct { seconds: u64 },
    create: Create,
    send_line: struct { id: i64 },
    send_headers: struct { id: i64 },
    send_body: struct { id: i64, size: ?i64 },
    send_all: struct { id: i64 },
    recv_partial: struct { id: i64, size: usize },
    wait: struct { id: i64 },
};

pub const DecodeError = error{ MissingField, UnknownEventType } || std.mem.Allocator.Error;

fn reqStr(t: toml.Table, idx: usize, type_name: []const u8, key: []const u8) DecodeError![]const u8 {
    return t.getStr(key) orelse {
        std.debug.print("event {d} ({s}): missing field '{s}'\n", .{ idx, type_name, key });
        return DecodeError.MissingField;
    };
}

fn reqId(t: toml.Table, idx: usize, type_name: []const u8) DecodeError!i64 {
    return t.getId() orelse {
        std.debug.print("event {d} ({s}): missing field 'id'\n", .{ idx, type_name });
        return DecodeError.MissingField;
    };
}

/// Validates and decodes every table up front; the first problem prints a
/// diagnostic naming the event index and field, then errors. Caller owns
/// the returned slice (free with the same allocator).
pub fn decode(a: std.mem.Allocator, tables: []const toml.Table) DecodeError![]Event {
    var events = try std.ArrayList(Event).initCapacity(a, tables.len);
    errdefer events.deinit(a);

    for (tables, 0..) |t, idx| {
        const type_name = t.getStr("type") orelse {
            std.debug.print("event {d}: missing field 'type'\n", .{idx});
            return DecodeError.MissingField;
        };
        const ev: Event = if (std.mem.eql(u8, type_name, "LOAD")) .{ .load = .{
            .infile = try reqStr(t, idx, type_name, "infile"),
            .outfile = try reqStr(t, idx, type_name, "outfile"),
        } } else if (std.mem.eql(u8, type_name, "UNLOAD")) .{ .unload = .{
            .file = try reqStr(t, idx, type_name, "file"),
        } } else if (std.mem.eql(u8, type_name, "SLEEP")) .{ .sleep = .{
            .seconds = @intCast(t.getInt("seconds") orelse 4),
        } } else if (std.mem.eql(u8, type_name, "CREATE")) .{ .create = .{
            .id = try reqId(t, idx, type_name),
            .method = t.getStr("method") orelse "GET",
            .uri = try reqStr(t, idx, type_name, "uri"),
            .infile = t.getStr("infile"),
        } } else if (std.mem.eql(u8, type_name, "SEND_LINE")) .{ .send_line = .{
            .id = try reqId(t, idx, type_name),
        } } else if (std.mem.eql(u8, type_name, "SEND_HEADERS")) .{ .send_headers = .{
            .id = try reqId(t, idx, type_name),
        } } else if (std.mem.eql(u8, type_name, "SEND_BODY")) .{ .send_body = .{
            .id = try reqId(t, idx, type_name),
            .size = t.getInt("size"),
        } } else if (std.mem.eql(u8, type_name, "SEND_ALL")) .{ .send_all = .{
            .id = try reqId(t, idx, type_name),
        } } else if (std.mem.eql(u8, type_name, "RECV_PARTIAL")) .{ .recv_partial = .{
            .id = try reqId(t, idx, type_name),
            .size = @intCast(t.getInt("size") orelse 4096),
        } } else if (std.mem.eql(u8, type_name, "WAIT")) .{ .wait = .{
            .id = try reqId(t, idx, type_name),
        } } else {
            std.debug.print("event {d}: unknown event type '{s}'\n", .{ idx, type_name });
            return DecodeError.UnknownEventType;
        };
        events.appendAssumeCapacity(ev);
    }

    return events.toOwnedSlice(a);
}

/// Finds the CREATE payload for a request id (the event carrying
/// method/uri/infile); null if the workload never created that id.
pub fn findCreate(events: []const Event, rid: i64) ?Create {
    for (events) |ev| switch (ev) {
        .create => |c| if (c.id == rid) return c,
        else => {},
    };
    return null;
}

test "decode maps every event type and applies defaults" {
    const a = std.testing.allocator;
    const text =
        \\[[events]]
        \\type = "LOAD"
        \\infile = "test_files/a.txt"
        \\outfile = "a.txt"
        \\
        \\[[events]]
        \\type = "CREATE"
        \\uri = "a.txt"
        \\id = 0
        \\
        \\[[events]]
        \\type = "SLEEP"
        \\
        \\[[events]]
        \\type = "SEND_ALL"
        \\id = 0
        \\
        \\[[events]]
        \\type = "WAIT"
        \\id = 0
    ;
    var w = try toml.parse(a, text);
    defer w.deinit();
    const evs = try decode(a, w.events.items);
    defer a.free(evs);

    try std.testing.expectEqual(@as(usize, 5), evs.len);
    try std.testing.expectEqualStrings("a.txt", evs[0].load.outfile);
    // CREATE without an explicit method defaults to GET.
    try std.testing.expectEqualStrings("GET", evs[1].create.method);
    try std.testing.expect(evs[1].create.infile == null);
    // SLEEP without seconds defaults to 4.
    try std.testing.expectEqual(@as(u64, 4), evs[2].sleep.seconds);
    try std.testing.expectEqual(@as(i64, 0), evs[4].wait.id);
}

test "decode rejects a CREATE missing its uri" {
    const a = std.testing.allocator;
    const text =
        \\[[events]]
        \\type = "CREATE"
        \\id = 0
    ;
    var w = try toml.parse(a, text);
    defer w.deinit();
    try std.testing.expectError(DecodeError.MissingField, decode(a, w.events.items));
}

test "decode rejects an unknown event type" {
    const a = std.testing.allocator;
    const text =
        \\[[events]]
        \\type = "TELEPORT"
        \\id = 0
    ;
    var w = try toml.parse(a, text);
    defer w.deinit();
    try std.testing.expectError(DecodeError.UnknownEventType, decode(a, w.events.items));
}

test "findCreate locates the payload by rid" {
    const a = std.testing.allocator;
    const text =
        \\[[events]]
        \\type = "CREATE"
        \\method = "PUT"
        \\uri = "x.txt"
        \\infile = "test_files/x.txt"
        \\id = 7
        \\
        \\[[events]]
        \\type = "WAIT"
        \\id = 7
    ;
    var w = try toml.parse(a, text);
    defer w.deinit();
    const evs = try decode(a, w.events.items);
    defer a.free(evs);

    const c = findCreate(evs, 7).?;
    try std.testing.expectEqualStrings("PUT", c.method);
    try std.testing.expectEqualStrings("x.txt", c.uri);
    try std.testing.expect(findCreate(evs, 8) == null);
}

test "decode handles every real workload file" {
    var dir = std.fs.cwd().openDir("workloads", .{ .iterate = true }) catch return error.SkipZigTest;
    defer dir.close();
    var it = dir.iterate();
    var checked: usize = 0;
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".toml")) continue;
        const text = try dir.readFileAlloc(std.testing.allocator, entry.name, 16 * 1024 * 1024);
        defer std.testing.allocator.free(text);
        var w = try toml.parse(std.testing.allocator, text);
        defer w.deinit();
        const evs = try decode(std.testing.allocator, w.events.items);
        defer std.testing.allocator.free(evs);
        try std.testing.expect(evs.len > 0);
        checked += 1;
    }
    try std.testing.expect(checked > 0);
}
