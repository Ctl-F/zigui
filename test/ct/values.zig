pub const Color = enum { red, green };
pub const P = struct { x: i32, y: i32, c: Color };

comptime {
    const p: P = .{ .x = 1, .y = 2, .c = .green };
    const arr = [_]u8{ 1, 2, 3 };
    const sl: []const u8 = &arr;
    var q = p;
    q.x += 10;
    _ = sl;
}
