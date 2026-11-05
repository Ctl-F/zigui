const std = @import("std");

fn twice(x: u32) u32 {
    return x * 2;
}

test "doubles at comptime" {
    comptime {
        var k: u32 = 3;
        k = twice(k);
        if (k != 6) @compileError("bad");
    }
    try std.testing.expect(twice(2) == 4);
}

test "another test" {
    comptime {
        const z = 1;
        _ = z;
    }
}
