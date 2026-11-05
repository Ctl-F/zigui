const Inner = struct { a: u8, b: ?u8 };
const U = union(enum) { i: i32, f: f32 };
const Outer = struct { name: []const u8, inner: Inner, list: [2]Inner };

comptime {
    const none: ?u32 = null;
    const some: ?u32 = 7;
    const u: U = .{ .f = 1.5 };
    var o: Outer = .{ .name = "hi", .inner = .{ .a = 1, .b = null }, .list = .{ .{ .a = 2, .b = 3 }, .{ .a = 4, .b = null } } };
    const p = &o;
    const T = Outer;
    o.inner.a = 9;
    _ = .{ none, some, u, p, T };
}
