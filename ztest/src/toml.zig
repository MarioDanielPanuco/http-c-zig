//! A parser for the tiny subset of TOML actually used by workloads/*.toml:
//! a flat list of `[[events]]` tables, each holding `key = value` pairs
//! where value is either a quoted string or a bare integer. No nested
//! tables, no arrays-of-values, no floats, no multi-line strings — none of
//! that vocabulary appears in the workload files.
const std = @import("std");

pub const Value = union(enum) {
    str: []const u8,
    int: i64,
};

pub const Table = struct {
    keys: std.ArrayList([]const u8) = .empty,
    vals: std.ArrayList(Value) = .empty,

    fn put(self: *Table, a: std.mem.Allocator, key: []const u8, value: Value) !void {
        try self.keys.append(a, key);
        try self.vals.append(a, value);
    }

    pub fn get(self: Table, key: []const u8) ?Value {
        for (self.keys.items, 0..) |k, i| {
            if (std.mem.eql(u8, k, key)) return self.vals.items[i];
        }
        return null;
    }

    pub fn getStr(self: Table, key: []const u8) ?[]const u8 {
        const v = self.get(key) orelse return null;
        return switch (v) {
            .str => |s| s,
            .int => null,
        };
    }

    pub fn getInt(self: Table, key: []const u8) ?i64 {
        const v = self.get(key) orelse return null;
        return switch (v) {
            .int => |n| n,
            .str => null,
        };
    }

    /// Convenience: many events key their request off "id" as an integer,
    /// but TOML doesn't distinguish -- fetch as int.
    pub fn getId(self: Table) ?i64 {
        return self.getInt("id");
    }
};

pub const Workload = struct {
    arena: std.heap.ArenaAllocator,
    events: std.ArrayList(Table) = .empty,

    pub fn deinit(self: *Workload) void {
        self.arena.deinit();
    }
};

pub const ParseError = error{
    KeyValueOutsideTable,
    MissingEquals,
    UnterminatedString,
    InvalidInteger,
    EmptyKey,
} || std.mem.Allocator.Error;

fn parseValue(a: std.mem.Allocator, raw: []const u8) ParseError!Value {
    if (raw.len == 0) return ParseError.InvalidInteger;
    if (raw[0] == '"') {
        // Find the matching close quote (skipping escaped `\"`), so a
        // trailing `# comment` after a quoted value doesn't confuse us.
        var end: usize = 1;
        var escaped = false;
        while (end < raw.len and (raw[end] != '"' or escaped)) : (end += 1) {
            escaped = (raw[end] == '\\' and !escaped);
        }
        if (end >= raw.len) return ParseError.UnterminatedString;
        const inner = raw[1..end];
        // Unescape the two sequences that could plausibly appear; the
        // workload files don't use anything fancier than plain paths.
        if (std.mem.indexOfScalar(u8, inner, '\\') == null) {
            return Value{ .str = try a.dupe(u8, inner) };
        }
        var out = std.ArrayList(u8).empty;
        var i: usize = 0;
        while (i < inner.len) {
            if (inner[i] == '\\' and i + 1 < inner.len) {
                switch (inner[i + 1]) {
                    '"' => try out.append(a, '"'),
                    '\\' => try out.append(a, '\\'),
                    'n' => try out.append(a, '\n'),
                    't' => try out.append(a, '\t'),
                    else => |c| try out.append(a, c),
                }
                i += 2;
            } else {
                try out.append(a, inner[i]);
                i += 1;
            }
        }
        return Value{ .str = try out.toOwnedSlice(a) };
    }
    const n = std.fmt.parseInt(i64, raw, 10) catch return ParseError.InvalidInteger;
    return Value{ .int = n };
}

/// Parses `text` (the full contents of a workloads/*.toml file) into a flat
/// list of event tables, in file order. Order matters: it's the total order
/// the rest of ztest treats as "what actually happened," matching how a
/// strictly single-threaded reader of the same file would replay it.
pub fn parse(gpa: std.mem.Allocator, text: []const u8) ParseError!Workload {
    var workload = Workload{ .arena = std.heap.ArenaAllocator.init(gpa) };
    errdefer workload.arena.deinit();
    const a = workload.arena.allocator();

    var current: ?usize = null;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        var line = std.mem.trim(u8, raw_line, " \t\r");
        // Strip trailing "# comment" only when it's a whole-line comment;
        // the workload files never put '#' inside a quoted value, so a
        // simple whole-line check is enough.
        if (line.len == 0) continue;
        if (line[0] == '#') continue;

        if (std.mem.eql(u8, line, "[[events]]")) {
            try workload.events.append(a, .{});
            current = workload.events.items.len - 1;
            continue;
        }

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return ParseError.MissingEquals;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        if (key.len == 0) return ParseError.EmptyKey;
        var val_raw = std.mem.trim(u8, line[eq + 1 ..], " \t");
        // drop an inline trailing comment after a bare (unquoted) value
        if (val_raw.len > 0 and val_raw[0] != '"') {
            if (std.mem.indexOfScalar(u8, val_raw, '#')) |hash| {
                val_raw = std.mem.trim(u8, val_raw[0..hash], " \t");
            }
        }
        const value = try parseValue(a, val_raw);
        const idx = current orelse return ParseError.KeyValueOutsideTable;
        try workload.events.items[idx].put(a, try a.dupe(u8, key), value);
    }

    return workload;
}

test "parses a minimal workload" {
    const text =
        \\[[events]]
        \\type = "CREATE"
        \\method = "GET"
        \\uri = "test1.txt"
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
    var w = try parse(std.testing.allocator, text);
    defer w.deinit();

    try std.testing.expectEqual(@as(usize, 3), w.events.items.len);
    try std.testing.expectEqualStrings("CREATE", w.events.items[0].getStr("type").?);
    try std.testing.expectEqualStrings("GET", w.events.items[0].getStr("method").?);
    try std.testing.expectEqualStrings("test1.txt", w.events.items[0].getStr("uri").?);
    try std.testing.expectEqual(@as(i64, 0), w.events.items[0].getId().?);
    try std.testing.expectEqualStrings("WAIT", w.events.items[2].getStr("type").?);
}

test "ignores comments and blank lines" {
    const text =
        \\# a leading comment
        \\
        \\[[events]]
        \\type = "SLEEP"   # inline comment
        \\seconds = 4
        \\
    ;
    var w = try parse(std.testing.allocator, text);
    defer w.deinit();
    try std.testing.expectEqual(@as(usize, 1), w.events.items.len);
    try std.testing.expectEqualStrings("SLEEP", w.events.items[0].getStr("type").?);
    try std.testing.expectEqual(@as(i64, 4), w.events.items[0].getInt("seconds").?);
}

test "rejects a key=value pair outside any table" {
    const text = "type = \"CREATE\"\n";
    try std.testing.expectError(ParseError.KeyValueOutsideTable, parse(std.testing.allocator, text));
}

test "loads real workload files" {
    // Sanity-check the parser against the actual fixtures it exists to read.
    var dir = std.fs.cwd().openDir("workloads", .{ .iterate = true }) catch return error.SkipZigTest;
    defer dir.close();
    var it = dir.iterate();
    var checked: usize = 0;
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".toml")) continue;
        const text = try dir.readFileAlloc(std.testing.allocator, entry.name, 16 * 1024 * 1024);
        defer std.testing.allocator.free(text);
        var w = try parse(std.testing.allocator, text);
        defer w.deinit();
        try std.testing.expect(w.events.items.len > 0);
        checked += 1;
    }
    try std.testing.expect(checked > 0);
}
