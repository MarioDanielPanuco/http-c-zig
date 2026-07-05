//! Minimal HTTP/1.1 wire-format helpers shared by the workload driver
//! (client side: parse a response) and the mock server (server side: parse
//! a request). Deliberately not std.http.Client/Server -- ztest talks raw
//! sockets so malformed/partial requests stay expressible.
const std = @import("std");

/// Returns the index just past the blank line that ends the header block
/// ("\r\n\r\n"), i.e. where the body starts. Null if not seen yet.
pub fn findBodyStart(buf: []const u8) ?usize {
    const idx = std.mem.indexOf(u8, buf, "\r\n\r\n") orelse return null;
    return idx + 4;
}

pub const StatusLine = struct {
    code: u16,
    reason: []const u8,
};

/// Parses a leading "HTTP/1.1 200 OK\r\n" off a response buffer.
pub fn parseStatusLine(buf: []const u8) ?StatusLine {
    if (!std.mem.startsWith(u8, buf, "HTTP/")) return null;
    const line_end = std.mem.indexOf(u8, buf, "\r\n") orelse return null;
    const line = buf[0..line_end];
    var parts = std.mem.splitScalar(u8, line, ' ');
    _ = parts.next() orelse return null; // "HTTP/1.1"
    const code_str = parts.next() orelse return null;
    const code = std.fmt.parseInt(u16, code_str, 10) catch return null;
    const reason = parts.rest();
    return .{ .code = code, .reason = reason };
}

pub const RequestLine = struct {
    method: []const u8,
    uri: []const u8, // with the leading '/' stripped
};

/// Parses a leading "METHOD /uri HTTP/1.1\r\n" off a request buffer.
pub fn parseRequestLine(buf: []const u8) ?RequestLine {
    const line_end = std.mem.indexOf(u8, buf, "\r\n") orelse return null;
    const line = buf[0..line_end];
    var parts = std.mem.splitScalar(u8, line, ' ');
    const method = parts.next() orelse return null;
    const raw_uri = parts.next() orelse return null;
    if (raw_uri.len == 0 or raw_uri[0] != '/') return null;
    return .{ .method = method, .uri = raw_uri[1..] };
}

/// Case-insensitive header lookup within a "Name: value\r\n"-per-line
/// header block (no leading request/status line, no trailing blank line
/// required in `headers`).
pub fn findHeader(headers: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        if (std.ascii.eqlIgnoreCase(key, name)) {
            return std.mem.trim(u8, line[colon + 1 ..], " \t");
        }
    }
    return null;
}

test "parseStatusLine reads code and reason" {
    const sl = parseStatusLine("HTTP/1.1 404 Not Found\r\nContent-Length: 10\r\n\r\nNot Found\n").?;
    try std.testing.expectEqual(@as(u16, 404), sl.code);
    try std.testing.expectEqualStrings("Not Found", sl.reason);
}

test "parseRequestLine strips the leading slash" {
    const rl = parseRequestLine("GET /test1.txt HTTP/1.1\r\n").?;
    try std.testing.expectEqualStrings("GET", rl.method);
    try std.testing.expectEqualStrings("test1.txt", rl.uri);
}

test "findHeader is case-insensitive and trims" {
    const headers = "Request-Id: 42\r\nContent-Length:  7  \r\n";
    try std.testing.expectEqualStrings("42", findHeader(headers, "request-id").?);
    try std.testing.expectEqualStrings("7", findHeader(headers, "Content-Length").?);
    try std.testing.expect(findHeader(headers, "Nope") == null);
}

test "findBodyStart locates the blank line" {
    const msg = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi";
    try std.testing.expectEqualStrings("hi", msg[findBodyStart(msg).?..]);
    try std.testing.expect(findBodyStart("no blank line here") == null);
}
