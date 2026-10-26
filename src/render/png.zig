//! Minimal PNG encoder (RGBA8, uncompressed deflate). For screenshots and
//! golden-image debugging; not meant to be small.

const std = @import("std");

fn chunk(out: *std.ArrayListUnmanaged(u8), gpa: std.mem.Allocator, kind: *const [4]u8, data: []const u8) !void {
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(data.len), .big);
    try out.appendSlice(gpa, &len);
    try out.appendSlice(gpa, kind);
    try out.appendSlice(gpa, data);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    var c: [4]u8 = undefined;
    std.mem.writeInt(u32, &c, crc.final(), .big);
    try out.appendSlice(gpa, &c);
}

/// Encode tightly packed RGBA8 pixels. Caller frees the result.
pub fn encodeRgba(gpa: std.mem.Allocator, rgba: []const u8, width: u32, height: u32) ![]u8 {
    std.debug.assert(rgba.len == @as(usize, width) * height * 4);

    // Raw scanlines, each prefixed by filter type 0.
    const row_bytes = @as(usize, width) * 4;
    const raw = try gpa.alloc(u8, (row_bytes + 1) * height);
    defer gpa.free(raw);
    for (0..height) |y| {
        raw[y * (row_bytes + 1)] = 0;
        @memcpy(raw[y * (row_bytes + 1) + 1 ..][0..row_bytes], rgba[y * row_bytes ..][0..row_bytes]);
    }

    // zlib stream of stored blocks.
    var z: std.ArrayListUnmanaged(u8) = .empty;
    defer z.deinit(gpa);
    try z.appendSlice(gpa, &.{ 0x78, 0x01 });
    var off: usize = 0;
    while (off < raw.len or off == 0) {
        const n = @min(raw.len - off, 65535);
        const final: u8 = if (off + n >= raw.len) 1 else 0;
        var hdr: [5]u8 = undefined;
        hdr[0] = final;
        std.mem.writeInt(u16, hdr[1..3], @intCast(n), .little);
        std.mem.writeInt(u16, hdr[3..5], ~@as(u16, @intCast(n)), .little);
        try z.appendSlice(gpa, &hdr);
        try z.appendSlice(gpa, raw[off..][0..n]);
        off += n;
        if (final == 1) break;
    }
    var adler: [4]u8 = undefined;
    std.mem.writeInt(u32, &adler, std.hash.Adler32.hash(raw), .big);
    try z.appendSlice(gpa, &adler);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, &.{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A });
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 6; // RGBA
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try chunk(&out, gpa, "IHDR", &ihdr);
    try chunk(&out, gpa, "IDAT", z.items);
    try chunk(&out, gpa, "IEND", &.{});
    return out.toOwnedSlice(gpa);
}

test "encodes a valid-looking PNG" {
    const px = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 255 };
    const png = try encodeRgba(std.testing.allocator, &px, 2, 1);
    defer std.testing.allocator.free(png);
    try std.testing.expectEqualSlices(u8, &.{ 0x89, 'P', 'N', 'G' }, png[0..4]);
    try std.testing.expectEqualSlices(u8, "IEND", png[png.len - 8 ..][0..4]);
}
