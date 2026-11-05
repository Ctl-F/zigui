comptime {
    var i: u32 = 0;
    while (i < 3) : (i += 1) {
        if (i == 1) @compileLog("at", i);
    }
}
