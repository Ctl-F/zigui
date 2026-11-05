fn bad(v: u32) u32 {
    if (v > 1) @compileError("too big");
    return v;
}

comptime {
    const a = bad(1);
    const b = bad(a + 1);
    _ = b;
}
