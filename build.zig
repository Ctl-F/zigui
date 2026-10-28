const std = @import("std");

/// The library modules (core, SDL shim, GPU backend, stb font backend) built for
/// one optimization mode.
const Libs = struct {
    core: *std.Build.Module,
    sdl: *std.Build.Module,
    gpu: *std.Build.Module,
    stb: *std.Build.Module,
    sdl_c: *std.Build.Module,
};

const Checks = struct { ui_checks: ?bool, ui_strict: bool };

fn makeLibs(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, exported: bool, checks: Checks) Libs {
    // Shadow-copy dirty checker: on in Debug and ReleaseSafe, off in
    // ReleaseFast/ReleaseSmall (unless overridden with -Dui_checks).
    const ui_checks = checks.ui_checks orelse (optimize == .debug or optimize == .safe);
    const ui_strict = checks.ui_strict;

    const options = b.addOptions();
    options.addOption(bool, "ui_checks", ui_checks);
    options.addOption(bool, "ui_strict", ui_strict);

    const core_opts: std.Build.Module.CreateOptions = .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    };
    const core = if (exported) b.addModule("zigui", core_opts) else b.createModule(core_opts);
    core.addOptions("build_options", options);

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

    const sdl_opts: std.Build.Module.CreateOptions = .{
        .root_source_file = b.path("src/platform/sdl.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    };
    const sdl_mod = if (exported) b.addModule("zigui_sdl", sdl_opts) else b.createModule(sdl_opts);
    sdl_mod.addImport("sdl_c", sdl_c_mod);
    sdl_mod.addImport("zigui", core);

    // SDL3 GPU renderer backend (Vulkan today). Shaders are SPIR-V committed
    // under src/platform/shaders; `zig build shaders` regenerates them (needs glslc).
    const gpu_opts: std.Build.Module.CreateOptions = .{
        .root_source_file = b.path("src/platform/sdl_gpu.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    };
    const gpu_mod = if (exported) b.addModule("zigui_gpu", gpu_opts) else b.createModule(gpu_opts);
    gpu_mod.addImport("sdl_c", sdl_c_mod);
    gpu_mod.addImport("zigui", core);

    // stb_truetype font backend. Separate module so core never needs C.
    const stb_c = b.addTranslateC(.{
        .root_source_file = b.path("src/text/stb_c.h"),
        .target = target,
        .optimize = optimize,
    });
    stb_c.addIncludePath(b.path("third_party/stb"));
    const stb_opts: std.Build.Module.CreateOptions = .{
        .root_source_file = b.path("src/text/stb.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    };
    const stb_mod = if (exported) b.addModule("zigui_stb", stb_opts) else b.createModule(stb_opts);
    stb_mod.addImport("zigui", core);
    stb_mod.addImport("stb_c", stb_c.createModule());
    stb_mod.addIncludePath(b.path("third_party/stb"));
    stb_mod.addCSourceFile(.{ .file = b.path("src/text/stb_impl.c"), .flags = &.{} });

    return .{ .core = core, .sdl = sdl_mod, .gpu = gpu_mod, .stb = stb_mod, .sdl_c = sdl_c_mod };
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The example programs are interactive and software rendering in a Debug
    // build is far too slow to judge them by, so they default to ReleaseSafe
    // (still checked, but optimized). `-Dexample_optimize=Debug` to debug them.
    const example_optimize = b.option(
        std.builtin.OptimizeMode,
        "example_optimize",
        "Optimization mode for the example programs (default ReleaseSafe when building Debug)",
    ) orelse (if (optimize == .debug) .safe else optimize);

    // -Dui_checks=true|false forces the debug checks on or off; -Dui_strict makes
    // the dirty checker panic instead of logging.
    const checks: Checks = .{
        .ui_checks = b.option(bool, "ui_checks", "Enable debug checks such as the shadow-copy dirty checker"),
        .ui_strict = b.option(bool, "ui_strict", "Make debug checks panic instead of logging warnings") orelse false,
    };
    const libs = makeLibs(b, target, optimize, true, checks);
    const ex = if (example_optimize == optimize) libs else makeLibs(b, target, example_optimize, false, checks);

    const tests = b.addTest(.{ .root_module = libs.core });
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

    const gpu_tests = b.addTest(.{ .root_module = libs.gpu });
    test_step.dependOn(&b.addRunArtifact(gpu_tests).step);
    const stb_tests = b.addTest(.{ .root_module = libs.stb });
    test_step.dependOn(&b.addRunArtifact(stb_tests).step);

    const shaders_step = b.step("shaders", "Recompile the GLSL shaders to SPIR-V (needs glslc)");
    for ([_][2][]const u8{ .{ "vertex", "ui.vert" }, .{ "fragment", "ui.frag" } }) |sh| {
        const run = b.addSystemCommand(&.{
            "glslc",
            b.fmt("-fshader-stage={s}", .{sh[0]}),
            b.fmt("src/platform/shaders/{s}", .{sh[1]}),
            "-o",
            b.fmt("src/platform/shaders/{s}.spv", .{sh[1]}),
        });
        run.setCwd(b.path("."));
        shaders_step.dependOn(&run.step);
    }

    const demo = addExample(b, ex, target, example_optimize, "demo", "examples/demo.zig", true);
    b.installArtifact(demo);
    const dedit = addExample(b, ex, target, example_optimize, "dedit", "examples/dedit.zig", false);
    const builder_exe = addExample(b, ex, target, example_optimize, "builder", "examples/builder.zig", false);
    b.installArtifact(builder_exe);
    const paint_exe = addExample(b, ex, target, example_optimize, "paint", "examples/paint.zig", false);
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

fn addExample(
    b: *std.Build,
    libs: Libs,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    path: []const u8,
    with_gpu: bool,
) *std.Build.Step.Compile {
    const m = b.createModule(.{
        .root_source_file = b.path(path),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    m.addImport("zigui", libs.core);
    m.addImport("zigui_sdl", libs.sdl);
    m.addImport("zigui_stb", libs.stb);
    if (with_gpu) m.addImport("zigui_gpu", libs.gpu);
    return b.addExecutable(.{ .name = name, .root_module = m });
}
