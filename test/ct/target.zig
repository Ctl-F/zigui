const lib = @import("target_lib.zig");
comptime {
    _ = lib;
    _ = &lib.inFn;
}
