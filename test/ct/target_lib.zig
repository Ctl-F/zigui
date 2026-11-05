comptime {
    const early = 1;
    _ = early;
}

pub fn inFn(n: u32) u32 {
    comptime {
        var k: u32 = 5;
        k += 1;
        _ = &k;
    }
    return n;
}

comptime {
    const late = 2;
    _ = late;
}
