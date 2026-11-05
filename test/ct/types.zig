fn Pair(comptime A: type, comptime B: type) type {
    return struct {
        first: A,
        second: B,
    };
}

const Color = enum { red, green };

comptime {
    const P = Pair(u32, Color);
    var p: P = .{ .first = 1, .second = .green };
    _ = &p;
    const Q = Pair(u8, u8);
    const q: Q = .{ .first = 1, .second = 2 };
    _ = q;
}
