//! JSON-RPC framing as language servers use it over stdio: each message is
//! `Content-Length: N\r\n\r\n` followed by N bytes of JSON (other header lines,
//! such as Content-Type, are allowed and ignored).
//!
//!     const framed = try jsonrpc.frame(gpa, "{\"jsonrpc\":\"2.0\",...}");   // send these bytes
//!
//!     var reader: jsonrpc.Reader = .{ .gpa = gpa };      // feed it whatever the server wrote
//!     try reader.push(chunk);
//!     while (reader.next()) |body| handle(body);          // bodies valid until the next push/next

const std = @import("std");

/// `body` with its header, ready to write to the server.
pub fn frame(gpa: std.mem.Allocator, body: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "Content-Length: {d}\r\n\r\n{s}", .{ body.len, body });
}

pub const Reader = struct {
    gpa: std.mem.Allocator,
    buf: std.ArrayListUnmanaged(u8) = .empty,
    /// Start of the unread part of `buf`.
    pos: usize = 0,

    pub fn deinit(self: *Reader) void {
        self.buf.deinit(self.gpa);
    }

    /// Add bytes the server wrote (any split: messages may arrive in pieces or several at once).
    pub fn push(self: *Reader, bytes: []const u8) !void {
        if (self.pos > 0 and self.pos == self.buf.items.len) {
            self.buf.clearRetainingCapacity();
            self.pos = 0;
        } else if (self.pos > 64 * 1024) {
            // Drop what has been consumed.
            const rest = self.buf.items[self.pos..];
            std.mem.copyForwards(u8, self.buf.items[0..rest.len], rest);
            self.buf.shrinkRetainingCapacity(rest.len);
            self.pos = 0;
        }
        try self.buf.appendSlice(self.gpa, bytes);
    }

    /// The next complete message body, or null if more bytes are needed.
    pub fn next(self: *Reader) ?[]const u8 {
        while (true) {
            const data = self.buf.items[self.pos..];
            const end = std.mem.indexOf(u8, data, "\r\n\r\n") orelse return null;
            const headers = data[0..end];
            var length: ?usize = null;
            var lines = std.mem.splitSequence(u8, headers, "\r\n");
            while (lines.next()) |line| {
                const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
                if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), "content-length")) {
                    length = std.fmt.parseInt(usize, std.mem.trim(u8, line[colon + 1 ..], " \t"), 10) catch null;
                }
            }
            const body_start = end + 4;
            const len = length orelse {
                // A header block without a length is garbage: skip it and look again.
                self.pos += body_start;
                continue;
            };
            if (data.len < body_start + len) return null;
            const body = data[body_start .. body_start + len];
            self.pos += body_start + len;
            return body;
        }
    }
};

const testing = std.testing;

test "frames round-trip, in pieces and several at once" {
    const a = try frame(testing.allocator, "{\"a\":1}");
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("Content-Length: 7\r\n\r\n{\"a\":1}", a);
    const b = try frame(testing.allocator, "{\"bb\":22}");
    defer testing.allocator.free(b);

    var r: Reader = .{ .gpa = testing.allocator };
    defer r.deinit();
    // The first message split mid-header and mid-body.
    try r.push(a[0..10]);
    try testing.expect(r.next() == null);
    try r.push(a[10 .. a.len - 3]);
    try testing.expect(r.next() == null);
    try r.push(a[a.len - 3 ..]);
    try testing.expectEqualStrings("{\"a\":1}", r.next().?);
    try testing.expect(r.next() == null);
    // Two in one push.
    const both = try std.mem.concat(testing.allocator, u8, &.{ a, b });
    defer testing.allocator.free(both);
    try r.push(both);
    try testing.expectEqualStrings("{\"a\":1}", r.next().?);
    try testing.expectEqualStrings("{\"bb\":22}", r.next().?);
    try testing.expect(r.next() == null);
}

test "extra headers, odd case, and headers without a length are tolerated" {
    var r: Reader = .{ .gpa = testing.allocator };
    defer r.deinit();
    try r.push("content-length: 2\r\nContent-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\n{}");
    try testing.expectEqualStrings("{}", r.next().?);
    try r.push("X-Junk: 1\r\n\r\nContent-Length: 4\r\n\r\ntrue");
    try testing.expectEqualStrings("true", r.next().?);
}
