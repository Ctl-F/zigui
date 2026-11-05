comptime {
    var t: u32 = 0;
    var i: u32 = 0;
    while (i < 3) : (i += 1) t += i;
    const done = t;
    _ = done;
}
