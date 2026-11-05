fn square(x: u32) u32 {
    const y = x * x;
    return y + 1;
}

comptime {
    var total: u32 = 0;
    var i: u32 = 0;
    while (i < 3) : (i += 1) {
        const s = square(i);
        total += s;
    }
    if (total != 8) @compileError("bad");
}
