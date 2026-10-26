//! Gap buffer of bytes: cheap inserts and deletes near the cursor, which is
//! how a single-line text field is edited. (The editor core uses a piece
//! table instead; both sit behind the same "storage" idea from the design doc.)

const std = @import("std");

pub const GapBuffer = struct {
    gpa: std.mem.Allocator,
    buf: []u8 = &.{},
    gap_start: usize = 0,
    gap_end: usize = 0,

    pub fn init(gpa: std.mem.Allocator) GapBuffer {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *GapBuffer) void {
        self.gpa.free(self.buf);
        self.* = undefined;
    }

    pub fn len(self: *const GapBuffer) usize {
        return self.buf.len - (self.gap_end - self.gap_start);
    }

    pub fn clear(self: *GapBuffer) void {
        self.gap_start = 0;
        self.gap_end = self.buf.len;
    }

    fn moveGap(self: *GapBuffer, pos: usize) void {
        std.debug.assert(pos <= self.len());
        if (pos == self.gap_start) return;
        const gap = self.gap_end - self.gap_start;
        if (pos < self.gap_start) {
            const n = self.gap_start - pos;
            std.mem.copyBackwards(u8, self.buf[self.gap_end - n .. self.gap_end], self.buf[pos..self.gap_start]);
        } else {
            const n = pos - self.gap_start;
            std.mem.copyForwards(u8, self.buf[self.gap_start .. self.gap_start + n], self.buf[self.gap_end .. self.gap_end + n]);
        }
        self.gap_start = pos;
        self.gap_end = pos + gap;
    }

    fn ensureGap(self: *GapBuffer, need: usize) !void {
        const gap = self.gap_end - self.gap_start;
        if (gap >= need) return;
        const tail = self.buf.len - self.gap_end;
        const new_len = @max(self.buf.len * 2, self.len() + need + 16);
        const new = try self.gpa.alloc(u8, new_len);
        @memcpy(new[0..self.gap_start], self.buf[0..self.gap_start]);
        @memcpy(new[new_len - tail ..], self.buf[self.gap_end..]);
        self.gpa.free(self.buf);
        self.buf = new;
        self.gap_end = new_len - tail;
    }

    pub fn insert(self: *GapBuffer, pos: usize, bytes: []const u8) !void {
        std.debug.assert(pos <= self.len());
        try self.ensureGap(bytes.len);
        self.moveGap(pos);
        @memcpy(self.buf[self.gap_start..][0..bytes.len], bytes);
        self.gap_start += bytes.len;
    }

    pub fn delete(self: *GapBuffer, pos: usize, n: usize) void {
        std.debug.assert(pos + n <= self.len());
        self.moveGap(pos);
        self.gap_end += n;
    }

    /// The whole content as one slice. Moves the gap to the end (O(gap-to-end))
    /// so it is cheap while typing at the end; the slice is valid until the
    /// next mutation.
    pub fn contiguous(self: *GapBuffer) []const u8 {
        self.moveGap(self.len());
        return self.buf[0..self.len()];
    }
};

test "insert, delete, and read back across gap moves" {
    var g = GapBuffer.init(std.testing.allocator);
    defer g.deinit();
    try g.insert(0, "hello");
    try g.insert(5, " world");
    try g.insert(5, ",");
    try std.testing.expectEqualStrings("hello, world", g.contiguous());
    g.delete(5, 1);
    g.delete(0, 1);
    try std.testing.expectEqualStrings("ello world", g.contiguous());
    try g.insert(0, ">>");
    try std.testing.expectEqualStrings(">>ello world", g.contiguous());
    try std.testing.expectEqual(@as(usize, 12), g.len());
}

test "grows past the initial capacity with the gap in the middle" {
    var g = GapBuffer.init(std.testing.allocator);
    defer g.deinit();
    try g.insert(0, "ab");
    for (0..200) |_| try g.insert(1, "x");
    try std.testing.expectEqual(@as(usize, 202), g.len());
    const s = g.contiguous();
    try std.testing.expectEqual(@as(u8, 'a'), s[0]);
    try std.testing.expectEqual(@as(u8, 'b'), s[201]);
    try std.testing.expectEqual(@as(usize, 200), std.mem.count(u8, s, "x"));
}

test "clear and reuse; empty buffer is safe" {
    var g = GapBuffer.init(std.testing.allocator);
    defer g.deinit();
    try std.testing.expectEqualStrings("", g.contiguous());
    try g.insert(0, "abc");
    g.clear();
    try std.testing.expectEqual(@as(usize, 0), g.len());
    try g.insert(0, "z");
    try std.testing.expectEqualStrings("z", g.contiguous());
}
