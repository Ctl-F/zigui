const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Shadow-copy dirty checker: on in Debug and ReleaseSafe by default, off in
    // ReleaseFast/ReleaseSmall. Override with -Dui_checks=true|false.
    const ui_checks = b.option(
        bool,
        "ui_checks",
        "Enable debug checks such as the shadow-copy dirty checker",
    ) orelse (optimize == .debug or optimize == .safe);

    // When true, the dirty checker panics instead of logging a warning.
    const ui_strict = b.option(
        bool,
        "ui_strict",
        "Make debug checks panic instead of logging warnings",
    ) orelse false;

    const options = b.addOptions();
    options.addOption(bool, "ui_checks", ui_checks);
    options.addOption(bool, "ui_strict", ui_strict);

    const mod = b.addModule("zigui", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addOptions("build_options", options);

    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
