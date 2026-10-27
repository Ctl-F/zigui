const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Shadow-copy dirty checker: on in Debug and ReleaseSafe, off in
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

    // Boundary check: no C calling conventions or extern types in the Zig core.
    const boundary = b.addExecutable(.{
        .name = "check_boundary",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/check_boundary.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const run_boundary = b.addRunArtifact(boundary);
    run_boundary.setCwd(b.path("."));
    const boundary_step = b.step("check-boundary", "Fail if C-convention code appears in the Zig core");
    boundary_step.dependOn(&run_boundary.step);
    test_step.dependOn(&run_boundary.step);
    const boundary_tests = b.addTest(.{ .root_module = boundary.root_module });
    test_step.dependOn(&b.addRunArtifact(boundary_tests).step);

    // SDL3 platform shim. Kept out of the core module so core and its tests
    // never need SDL. Requires the SDL3 development files on the system.
    const sdl_c = b.addTranslateC(.{
        .root_source_file = b.path("src/platform/sdl_c.h"),
        .target = target,
        .optimize = optimize,
    });
    sdl_c.linkSystemLibrary("sdl3", .{});
    const sdl_c_mod = sdl_c.createModule();
    sdl_c_mod.linkSystemLibrary("sdl3", .{});

    const sdl_mod = b.addModule("zigui_sdl", .{
        .root_source_file = b.path("src/platform/sdl.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    sdl_mod.addImport("sdl_c", sdl_c_mod);
    sdl_mod.addImport("zigui", mod);

    // stb_truetype font backend. Separate module so core never needs C.
    const stb_c = b.addTranslateC(.{
        .root_source_file = b.path("src/text/stb_c.h"),
        .target = target,
        .optimize = optimize,
    });
    stb_c.addIncludePath(b.path("third_party/stb"));
    const stb_mod = b.addModule("zigui_stb", .{
        .root_source_file = b.path("src/text/stb.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    stb_mod.addImport("zigui", mod);
    stb_mod.addImport("stb_c", stb_c.createModule());
    stb_mod.addIncludePath(b.path("third_party/stb"));
    stb_mod.addCSourceFile(.{ .file = b.path("src/text/stb_impl.c"), .flags = &.{} });

    const stb_tests = b.addTest(.{ .root_module = stb_mod });
    test_step.dependOn(&b.addRunArtifact(stb_tests).step);

    const demo = b.addExecutable(.{
        .name = "demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/demo.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "zigui", .module = mod },
                .{ .name = "zigui_sdl", .module = sdl_mod },
                .{ .name = "zigui_stb", .module = stb_mod },
            },
        }),
    });
    b.installArtifact(demo);

    const dedit = b.addExecutable(.{
        .name = "dedit",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/dedit.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "zigui", .module = mod },
                .{ .name = "zigui_sdl", .module = sdl_mod },
                .{ .name = "zigui_stb", .module = stb_mod },
            },
        }),
    });

    const builder_exe = b.addExecutable(.{
        .name = "builder",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/builder.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "zigui", .module = mod },
                .{ .name = "zigui_sdl", .module = sdl_mod },
                .{ .name = "zigui_stb", .module = stb_mod },
            },
        }),
    });
    b.installArtifact(builder_exe);

    const paint_exe = b.addExecutable(.{
        .name = "paint",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/paint.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "zigui", .module = mod },
                .{ .name = "zigui_sdl", .module = sdl_mod },
                .{ .name = "zigui_stb", .module = stb_mod },
            },
        }),
    });
    b.installArtifact(paint_exe);

    const run_demo = b.addRunArtifact(demo);
    const demo_step = b.step("demo", "Build and run the demo window (needs SDL3)");
    demo_step.dependOn(&run_demo.step);

    const run_builder = b.addRunArtifact(builder_exe);
    const builder_step = b.step("builder", "Build and run the UI builder (edits ui.zon; or run zig-out/bin/builder FILE)");
    builder_step.dependOn(&run_builder.step);

    const run_paint = b.addRunArtifact(paint_exe);
    const paint_step = b.step("paint", "Build and run the paint example (canvas with an offscreen surface)");
    paint_step.dependOn(&run_paint.step);

    const run_dedit = b.addRunArtifact(dedit);
    const dedit_step = b.step("dedit", "Build and run the demo editor");
    dedit_step.dependOn(&run_dedit.step);
}
