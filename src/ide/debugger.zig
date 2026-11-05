//! The runtime debugger: a debug adapter (`lldb-dap`, or GDB's DAP mode) running
//! as a child process, a `dap/session.zig` Session driving it, and the project's
//! breakpoints kept in `.zigide/debug.zon`. No UI here (`debug_panel.zig` and the
//! editor marks are the UI).
//!
//!     const d = try Debugger.create(gpa, io, &project, environ, .{ .wake = sdl.wake });
//!     defer d.destroy();
//!     d.session.on_change = ChangeHook.bind(&app, App.debugChanged);
//!     _ = try d.session.toggleBreakpoint(abs_path, line);        // gutter click
//!     try d.start(.{ .program = "zig-out/bin/app" });           // spawns the adapter, launches
//!     // each loop iteration:
//!     d.poll();                                                  // adapter output -> session; saves breakpoints
//!
//! The `Session` lives as long as the `Debugger`, so breakpoints survive runs; each
//! `start` spawns a fresh adapter process. Breakpoints are saved (project-relative
//! paths inside the project) a moment after they change.
//!
//! `.zigide/debug.zon`:
//!
//!     .{
//!         .breakpoints = .{ .{ .file = "src/main.zig", .line = 12, .enabled = true, .condition = "" } },
//!         // Optional run configuration (otherwise the program is found in zig-out/bin):
//!         .program = "zig-out/bin/app", .args = .{ "--verbose" }, .cwd = "", .stop_on_entry = false,
//!     }

const std = @import("std");
const process = @import("../platform/process.zig");
const zon = @import("../uidoc/zon.zig");
const project_mod = @import("project.zig");
const adapters = @import("dap/adapters.zig");
const zigct = @import("dap/zigct.zig");
const comptime_scan = @import("comptime_scan.zig");
const comptime_graph = @import("comptime_graph.zig");
const builtin = @import("builtin");
const session_mod = @import("dap/session.zig");
const Session = session_mod.Session;

pub const config_path = ".zigide/debug.zon";

/// The small file that makes the compiler evaluate a comptime block (in the project root, so the
/// whole project is one module; deleted when the session ends).
pub const comptime_root = ".zigct-root.zig";

pub const ComptimeOptions = struct {
    /// Read the project's build for its module graph (a `build.zig` is needed); false evaluates
    /// the file as a standalone one in the project folder.
    read_build: bool = true,
    /// The file with the block (absolute) and the block's 1-based lines.
    file: []const u8,
    start_line: u32,
    end_line: u32,
    /// What the block needs referenced (`comptime_scan.Block.fn_path`).
    fn_path: []const u8 = "",
    /// The Zig installation's `lib` directory (the compiler reads `std` from there).
    zig_lib_dir: []const u8,
    stop_on_entry: bool = true,
};

const Prep = struct {
    runner: *process.Runner,
    text: std.ArrayListUnmanaged(u8) = .empty,
    started_ms: u64,
    last_data_ms: u64,
    opts: ComptimeOptions,
};

pub const Options = struct {
    wake: ?*const fn () void = null,
    /// The `debug.adapter_path` setting ("" = look for one).
    adapter_path: []const u8 = "",
};

pub const StartOptions = struct {
    /// The program to debug: absolute, or relative to the project.
    program: []const u8,
    args: []const []const u8 = &.{},
    cwd: []const u8 = "",
    env: []const []const u8 = &.{},
    stop_on_entry: bool = false,
};

/// The run configuration read from `debug.zon` (strings owned by the debugger).
pub const RunConfig = struct {
    program: []const u8 = "",
    args: []const []const u8 = &.{},
    cwd: []const u8 = "",
    stop_on_entry: bool = false,
};

pub const Debugger = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    project: *const project_mod.Project,
    environ: ?*const std.process.Environ.Map,
    wake: ?*const fn () void,
    adapter_path: []u8,
    session: *Session,
    runner: ?*process.Runner = null,
    found: ?adapters.Found = null,
    /// The adapter was looked for (and is `found`, or missing).
    searched: bool = false,
    config_arena: std.heap.ArenaAllocator,
    config: RunConfig = .{},
    /// A `change` happened since the last save.
    dirty: bool = false,
    dirty_since_ms: u64 = 0,
    now_ms: u64 = 0,
    batch: std.ArrayListUnmanaged(process.Event) = .empty,
    on_change: ?session_mod.ChangeHook = null,
    /// The files written for a comptime session (wrappers in the modules' folders), removed when it ends.
    ct_files: std.ArrayListUnmanaged([]u8) = .empty,
    /// Reading the build for a comptime session.
    prep: ?*Prep = null,

    pub fn create(gpa: std.mem.Allocator, io: std.Io, project: *const project_mod.Project, environ: ?*const std.process.Environ.Map, opts: Options) !*Debugger {
        const self = try gpa.create(Debugger);
        errdefer gpa.destroy(self);
        const ap = try gpa.dupe(u8, opts.adapter_path);
        errdefer gpa.free(ap);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .project = project,
            .environ = environ,
            .wake = opts.wake,
            .adapter_path = ap,
            .session = undefined,
            .config_arena = .init(gpa),
        };
        self.session = try Session.create(gpa, .{ .ctx = self, .call = writeToAdapter });
        errdefer self.session.destroy();
        self.session.on_change = session_mod.ChangeHook.bind(self, sessionChanged);
        self.loadConfig();
        return self;
    }

    pub fn destroy(self: *Debugger) void {
        self.save();
        self.cancelPrep();
        self.removeComptimeFiles();
        self.ct_files.deinit(self.gpa);
        if (self.runner) |r| r.destroy();
        for (self.batch.items) |*e| e.deinit(self.gpa);
        self.batch.deinit(self.gpa);
        self.session.destroy();
        if (self.found) |f| f.deinit(self.gpa);
        self.config_arena.deinit();
        self.gpa.free(self.adapter_path);
        self.gpa.destroy(self);
    }

    fn writeToAdapter(ctx: ?*anyopaque, bytes: []const u8) void {
        const self: *Debugger = @ptrCast(@alignCast(ctx.?));
        const r = self.runner orelse return;
        r.writeStdin(bytes) catch {};
    }

    fn sessionChanged(self: *Debugger) void {
        self.dirty = true;
        self.dirty_since_ms = self.now_ms;
        if (self.on_change) |h| h.call(h.ctx);
    }

    /// The `debug.adapter_path` setting changed.
    pub fn setAdapterPath(self: *Debugger, path: []const u8) void {
        if (std.mem.eql(u8, path, self.adapter_path)) return;
        const copy = self.gpa.dupe(u8, path) catch return;
        self.gpa.free(self.adapter_path);
        self.adapter_path = copy;
        self.searched = false;
    }

    /// The adapter this machine has, looked for once (null when none: see `missingNote`).
    pub fn adapter(self: *Debugger) ?adapters.Found {
        if (!self.searched) {
            self.searched = true;
            if (self.found) |f| f.deinit(self.gpa);
            self.found = adapters.find(self.gpa, self.io, self.environ, self.adapter_path) catch null;
        }
        return self.found;
    }

    pub fn missingNote(self: *Debugger) []u8 {
        return adapters.missingNote(self.gpa, self.adapter_path) catch self.gpa.dupe(u8, "no debug adapter found") catch &.{};
    }

    // ---- starting ----

    /// Spawn the adapter and launch `opts.program` under it. Errors are put in the console and `failure`.
    pub fn start(self: *Debugger, opts: StartOptions) !void {
        if (self.session.active()) return;
        const a = self.adapter() orelse {
            const note = self.missingNote();
            defer self.gpa.free(note);
            self.session.say(note);
            self.session.failure = self.gpa.dupe(u8, note) catch &.{};
            self.session.state = .terminated;
            if (self.on_change) |h| h.call(h.ctx);
            return error.NoAdapter;
        };
        if (self.runner) |r| {
            r.destroy();
            self.runner = null;
        }
        const program = if (std.fs.path.isAbsolute(opts.program)) try self.gpa.dupe(u8, opts.program) else try self.project.absPath(self.gpa, opts.program);
        defer self.gpa.free(program);
        const cwd = if (opts.cwd.len == 0) try self.gpa.dupe(u8, self.project.root) else if (std.fs.path.isAbsolute(opts.cwd)) try self.gpa.dupe(u8, opts.cwd) else try self.project.absPath(self.gpa, opts.cwd);
        defer self.gpa.free(cwd);
        self.runner = process.Runner.start(self.gpa, self.io, .{ .argv = a.argv, .cwd = self.project.root, .stdin = true, .wake = self.wake }) catch |err| {
            var buf: [200]u8 = undefined;
            self.session.say(std.fmt.bufPrint(&buf, "could not start {s}: {s}", .{ a.name, @errorName(err) }) catch "could not start the adapter");
            return err;
        };
        try self.session.start(.{ .program = program, .args = opts.args, .cwd = cwd, .env = opts.env, .stop_on_entry = opts.stop_on_entry, .gdb = a.kind == .gdb });
    }

    /// Debug one `comptime` block with zigct (see `dap/zigct.zig`). When the project has a
    /// `build.zig` the module graph is read from it first (`comptime_graph.zig`; this takes a
    /// moment: `preparing()` is true, `poll` continues), so `@import("dependency")` works.
    /// Problems are put in the console and `failure`, and returned.
    pub fn startComptime(self: *Debugger, opts: ComptimeOptions) !void {
        if (self.session.active() or self.prep != null) return;
        const ct = zigct.find(self.gpa, self.io, self.environ) orelse {
            self.refuse("the comptime debugger (zigct) is not built: use Zig > Build Comptime Debugger, or run tools/zigct/build.sh");
            return error.NoZigct;
        };
        defer self.gpa.free(ct);
        if (self.project.relPath(opts.file) == null) {
            self.refuse("the block is outside the project");
            return error.OutsideProject;
        }
        if (!self.project.hasBuildZig() or builtin.os.tag == .windows or !opts.read_build) return self.launchComptime(ct, opts, null);

        const home = if (self.environ) |e| e.get("HOME") orelse "/tmp" else "/tmp";
        const cache = try std.fmt.allocPrint(self.gpa, "{s}/.cache/zigui-ide/zigct/graph-cache", .{home});
        defer self.gpa.free(cache);
        const lib_env = try std.fmt.allocPrint(self.gpa, "ZIG_LIB_DIR={s}", .{opts.zig_lib_dir});
        defer self.gpa.free(lib_env);
        const runner = process.Runner.start(self.gpa, self.io, .{
            .argv = &.{ "env", "ZCT_DRYRUN=1", lib_env, ct, "build", "--verbose", "--cache-dir", cache },
            .cwd = self.project.root,
            .stdin = true,
            .wake = self.wake,
        }) catch |err| {
            self.refuse("could not start zigct to read the build");
            return err;
        };
        const p = try self.gpa.create(Prep);
        p.* = .{
            .runner = runner,
            .started_ms = self.now_ms,
            .last_data_ms = self.now_ms,
            .opts = .{
                .file = try self.gpa.dupe(u8, opts.file),
                .start_line = opts.start_line,
                .end_line = opts.end_line,
                .fn_path = try self.gpa.dupe(u8, opts.fn_path),
                .zig_lib_dir = try self.gpa.dupe(u8, opts.zig_lib_dir),
                .stop_on_entry = opts.stop_on_entry,
            },
        };
        self.prep = p;
        self.session.say("reading the build to find the module graph...");
        if (self.on_change) |h| h.call(h.ctx);
    }

    /// A comptime session is being prepared (the build is being read).
    pub fn preparing(self: *const Debugger) bool {
        return self.prep != null;
    }

    fn cancelPrep(self: *Debugger) void {
        const p = self.prep orelse return;
        self.prep = null;
        p.runner.destroy();
        p.text.deinit(self.gpa);
        self.gpa.free(p.opts.file);
        self.gpa.free(p.opts.fn_path);
        self.gpa.free(p.opts.zig_lib_dir);
        self.gpa.destroy(p);
    }

    fn pollPrep(self: *Debugger, now_ms: u64) void {
        const p = self.prep orelse return;
        var batch: std.ArrayListUnmanaged(process.Event) = .empty;
        defer batch.deinit(self.gpa);
        p.runner.drain(&batch);
        var exited = false;
        for (batch.items) |*e| {
            switch (e.*) {
                .chunk => |c| {
                    p.text.appendSlice(self.gpa, c.bytes) catch {};
                    p.last_data_ms = now_ms;
                },
                .exited => exited = true,
            }
            e.deinit(self.gpa);
        }
        const quiet = now_ms -% p.last_data_ms > 1500;
        const long = now_ms -% p.started_ms > 300_000;
        if (!exited and !long and !quiet) return;
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        // The parsed commands point into this copy: the build run's buffer is freed below.
        const text = a.dupe(u8, p.text.items) catch return;
        const compiles = comptime_graph.parse(a, text) catch &.{};
        if (compiles.len == 0 and !exited and !long) return; // the build is still configuring
        // Take over the options, then drop the build run.
        const opts: ComptimeOptions = p.opts;
        const file = a.dupe(u8, opts.file) catch return;
        const fn_path = a.dupe(u8, opts.fn_path) catch return;
        const lib = a.dupe(u8, opts.zig_lib_dir) catch return;
        const text_tail = text[text.len -| 1500..];
        var o2 = opts;
        o2.file = file;
        o2.fn_path = fn_path;
        o2.zig_lib_dir = lib;
        self.cancelPrep();

        if (compiles.len == 0) {
            self.session.say(text_tail);
            return self.refuse("the build did not report any compile step: see the messages above");
        }
        const plan = comptime_graph.plan(a, compiles, self.project.root, file, fn_path) catch null;
        if (plan == null) self.session.say("[this file is not in a module of the build: it is evaluated as a standalone file in the project folder]");
        const ct = zigct.find(self.gpa, self.io, self.environ) orelse return self.refuse("zigct is not built");
        defer self.gpa.free(ct);
        self.launchComptime(ct, o2, plan) catch {};
    }

    fn launchComptime(self: *Debugger, ct: []const u8, opts: ComptimeOptions, plan: ?comptime_graph.Plan) !void {
        const gpa = self.gpa;
        var args: std.ArrayListUnmanaged([]const u8) = .empty;
        defer args.deinit(gpa);
        var owned_root: ?[]u8 = null;
        defer if (owned_root) |r| gpa.free(r);
        if (plan) |pl| {
            for (pl.files) |f| {
                std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = f.path, .data = f.content }) catch |err| {
                    self.removeComptimeFiles();
                    self.refuse("could not write the files that make the compiler evaluate the block");
                    return err;
                };
                try self.ct_files.append(gpa, try gpa.dupe(u8, f.path));
            }
            try args.appendSlice(gpa, pl.args);
        } else {
            const rel = self.project.relPath(opts.file).?;
            const root_src = try comptime_scan.rootSource(gpa, rel, opts.fn_path);
            defer gpa.free(root_src);
            try self.project.writeFile(comptime_root, root_src);
            owned_root = try self.project.absPath(gpa, comptime_root);
            try self.ct_files.append(gpa, try gpa.dupe(u8, owned_root.?));
            try args.append(gpa, owned_root.?);
        }
        try args.appendSlice(gpa, &.{ "--zig-lib-dir", opts.zig_lib_dir });

        const home = if (self.environ) |e| e.get("HOME") orelse "/tmp" else "/tmp";
        const cache = try std.fmt.allocPrint(gpa, "{s}/.cache/zigui-ide/zigct/cache", .{home});
        defer gpa.free(cache);
        const launch = try std.json.Stringify.valueAlloc(gpa, .{
            .zigArgs = args.items,
            .sourceRoot = self.project.root,
            .cacheDir = cache,
            .stopOnEntry = opts.stop_on_entry,
            .target = .{ .file = opts.file, .startLine = opts.start_line, .endLine = opts.end_line },
        }, .{});
        defer gpa.free(launch);

        if (self.runner) |r| {
            r.destroy();
            self.runner = null;
        }
        self.runner = process.Runner.start(gpa, self.io, .{ .argv = &.{ ct, "dap-comptime" }, .cwd = self.project.root, .stdin = true, .wake = self.wake }) catch |err| {
            self.removeComptimeFiles();
            self.refuse("could not start zigct");
            return err;
        };
        try self.session.start(.{ .program = "", .raw_launch = launch });
    }

    fn refuse(self: *Debugger, note: []const u8) void {
        self.session.say(note);
        self.session.failure = self.gpa.dupe(u8, note) catch &.{};
        self.session.state = .terminated;
        if (self.on_change) |h| h.call(h.ctx);
    }

    fn removeComptimeFiles(self: *Debugger) void {
        for (self.ct_files.items) |path| {
            std.Io.Dir.cwd().deleteFile(self.io, path) catch {};
            self.gpa.free(path);
        }
        self.ct_files.clearRetainingCapacity();
    }

    /// Start with the run configuration from `debug.zon` (null `program` if there is none).
    pub fn startConfigured(self: *Debugger) !void {
        if (self.config.program.len == 0) return error.NoProgram;
        try self.start(.{ .program = self.config.program, .args = self.config.args, .cwd = self.config.cwd, .stop_on_entry = self.config.stop_on_entry });
    }

    pub fn stop(self: *Debugger) void {
        if (self.prep != null) {
            self.cancelPrep();
            self.session.say("[cancelled]");
            if (self.on_change) |h| h.call(h.ctx);
            return;
        }
        self.session.stop();
    }

    // ---- polling ----

    /// Call every loop iteration with the UI's clock (`ui.now_ms`).
    pub fn poll(self: *Debugger, now_ms: u64) void {
        self.now_ms = now_ms;
        self.pollPrep(now_ms);
        if (self.runner) |r| {
            r.drain(&self.batch);
            var ended = false;
            for (self.batch.items) |*e| {
                switch (e.*) {
                    .chunk => |c| switch (c.stream) {
                        .stdout => self.session.client.receive(c.bytes),
                        .stderr => self.session.say(c.bytes),
                    },
                    .exited => ended = true,
                }
                e.deinit(self.gpa);
            }
            self.batch.clearRetainingCapacity();
            if (ended) {
                // The adapter itself ended: the session cannot go on.
                if (self.session.active()) {
                    self.session.say("[the debug adapter exited]");
                    self.session.state = .terminated;
                    self.sessionChanged();
                }
                r.destroy();
                self.runner = null;
            } else if (self.session.state == .terminated and r.finished()) {
                r.destroy();
                self.runner = null;
            }
        }
        if (self.ct_files.items.len > 0 and self.prep == null and !self.session.active()) self.removeComptimeFiles();
        if (self.dirty and now_ms -% self.dirty_since_ms > 800) self.save();
    }

    // ---- breakpoints file ----

    fn loadConfig(self: *Debugger) void {
        const bytes = self.project.readFile(self.gpa, config_path, 1024 * 1024) catch return;
        defer self.gpa.free(bytes);
        var tmp = std.heap.ArenaAllocator.init(self.gpa);
        defer tmp.deinit();
        const v = zon.parse(tmp.allocator(), bytes, null) catch return;
        if (v.field("breakpoints")) |list| for (list.items() orelse &.{}) |b| {
            const file = strField(b, "file") orelse continue;
            const line = intField(b, "line") orelse continue;
            if (line <= 0) continue;
            const abs = if (std.fs.path.isAbsolute(file)) self.gpa.dupe(u8, file) catch continue else self.project.absPath(self.gpa, file) catch continue;
            defer self.gpa.free(abs);
            var enabled = true;
            if (b.field("enabled")) |e| if (e == .bool) {
                enabled = e.bool;
            };
            self.session.setBreakpoint(abs, @intCast(line), enabled, strField(b, "condition") orelse "") catch {};
        };
        const a = self.config_arena.allocator();
        if (strField(v, "program")) |p| self.config.program = a.dupe(u8, p) catch "";
        if (strField(v, "cwd")) |p| self.config.cwd = a.dupe(u8, p) catch "";
        if (v.field("stop_on_entry")) |e| if (e == .bool) {
            self.config.stop_on_entry = e.bool;
        };
        if (v.field("args")) |args| {
            var list: std.ArrayListUnmanaged([]const u8) = .empty;
            for (args.items() orelse &.{}) |x| {
                if (x == .string) list.append(a, a.dupe(u8, x.string) catch continue) catch {};
            }
            self.config.args = list.items;
        }
        // Loading is not a change worth saving again.
        self.dirty = false;
    }

    fn strField(v: zon.Value, name: []const u8) ?[]const u8 {
        const f = v.field(name) orelse return null;
        return if (f == .string) f.string else null;
    }

    fn intField(v: zon.Value, name: []const u8) ?i64 {
        const f = v.field(name) orelse return null;
        return if (f == .int) f.int else null;
    }

    /// Write `.zigide/debug.zon` (breakpoints, and the run configuration as it was read).
    pub fn save(self: *Debugger) void {
        self.dirty = false;
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(self.gpa);
        out.appendSlice(self.gpa, "// Debugger settings of the zigui IDE: breakpoints (kept by the IDE) and an optional run configuration.\n.{\n    .breakpoints = .{\n") catch return;
        for (self.session.breakpoints.items) |b| {
            const rel = self.project.relPath(b.file) orelse b.file;
            const file = zon.render(self.gpa, .{ .string = rel }) catch return;
            defer self.gpa.free(file);
            const cond = zon.render(self.gpa, .{ .string = b.condition }) catch return;
            defer self.gpa.free(cond);
            out.print(self.gpa, "        .{{ .file = {s}, .line = {d}, .enabled = {s}, .condition = {s} }},\n", .{ file, b.line, if (b.enabled) "true" else "false", cond }) catch return;
        }
        out.appendSlice(self.gpa, "    },\n") catch return;
        if (self.config.program.len > 0) {
            const prog = zon.render(self.gpa, .{ .string = self.config.program }) catch return;
            defer self.gpa.free(prog);
            out.print(self.gpa, "    .program = {s},\n", .{prog}) catch return;
            out.appendSlice(self.gpa, "    .args = .{") catch return;
            for (self.config.args, 0..) |a, i| {
                const q = zon.render(self.gpa, .{ .string = a }) catch return;
                defer self.gpa.free(q);
                out.print(self.gpa, "{s} {s}", .{ if (i > 0) "," else "", q }) catch return;
            }
            out.appendSlice(self.gpa, " },\n") catch return;
            const cwd = zon.render(self.gpa, .{ .string = self.config.cwd }) catch return;
            defer self.gpa.free(cwd);
            out.print(self.gpa, "    .cwd = {s},\n    .stop_on_entry = {s},\n", .{ cwd, if (self.config.stop_on_entry) "true" else "false" }) catch return;
        }
        out.appendSlice(self.gpa, "}\n") catch return;
        // Nothing to save and no file yet: do not create one.
        if (self.session.breakpoints.items.len == 0 and self.config.program.len == 0) {
            self.project.dir.access(self.project.io, config_path, .{}) catch return;
        }
        self.project.dir.createDirPath(self.project.io, ".zigide") catch return;
        self.project.writeFile(config_path, out.items) catch {};
    }

    /// The program to debug when no run configuration names one: the only file in `zig-out/bin`,
    /// or the one named like the project. Null (and `why` says it) when it cannot be decided.
    pub fn findProgram(self: *Debugger, why: *[]const u8) ?[]u8 {
        if (self.config.program.len > 0) return self.gpa.dupe(u8, self.config.program) catch null;
        var dir = self.project.dir.openDir(self.io, "zig-out/bin", .{ .iterate = true }) catch {
            why.* = "no zig-out/bin folder: build the project first";
            return null;
        };
        defer dir.close(self.io);
        var names: std.ArrayListUnmanaged([]u8) = .empty;
        defer {
            for (names.items) |n| self.gpa.free(n);
            names.deinit(self.gpa);
        }
        var it = dir.iterate();
        while (it.next(self.io) catch null) |e| {
            if (e.kind != .file) continue;
            names.append(self.gpa, self.gpa.dupe(u8, e.name) catch continue) catch {};
        }
        if (names.items.len == 0) {
            why.* = "zig-out/bin is empty: the build produced no program";
            return null;
        }
        var pick: usize = names.items.len;
        if (names.items.len == 1) pick = 0 else for (names.items, 0..) |n, i| {
            const base = std.fs.path.stem(n);
            if (std.mem.eql(u8, base, self.project.name)) pick = i;
        }
        if (pick == names.items.len) {
            why.* = "several programs in zig-out/bin: set .program in .zigide/debug.zon";
            return null;
        }
        return std.fs.path.join(self.gpa, &.{ "zig-out", "bin", names.items[pick] }) catch null;
    }
};

// ---- tests -----------------------------------------------------------------

const testing = std.testing;
const pty_common = @import("../platform/pty_common.zig");

fn pumpUntil(d: *Debugger, tries: usize, comptime cond: fn (*Debugger) bool) !void {
    var i: usize = 0;
    while (i < tries and !cond(d)) : (i += 1) {
        d.poll(@intCast(i * 2));
        pty_common.sleepMs(2);
    }
}

fn isStopped(d: *Debugger) bool {
    return d.session.state == .stopped and d.session.variables(if (d.session.scopes.len > 0) d.session.scopes[0].reference else -1) != null;
}

fn isTerminated(d: *Debugger) bool {
    return d.session.state == .terminated;
}

test "breakpoints are saved relative to the project, restored, and the program is found in zig-out/bin" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var p = try project_mod.testProject(&tmp);
    defer p.close();
    {
        const d = try Debugger.create(testing.allocator, testing.io, &p, null, .{});
        defer d.destroy();
        const abs = try p.absPath(testing.allocator, "src/main.zig");
        defer testing.allocator.free(abs);
        try d.session.setBreakpoint(abs, 4, true, "");
        try d.session.setBreakpoint(abs, 9, false, "i == 3");
        d.save();
    }
    const text = try p.readFile(testing.allocator, config_path, 4096);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, ".file = \"src/main.zig\", .line = 4, .enabled = true") != null);
    try testing.expect(std.mem.indexOf(u8, text, ".condition = \"i == 3\"") != null);

    const d2 = try Debugger.create(testing.allocator, testing.io, &p, null, .{});
    defer d2.destroy();
    try testing.expectEqual(@as(usize, 2), d2.session.breakpoints.items.len);
    try testing.expectEqual(@as(u32, 9), d2.session.breakpoints.items[1].line);
    try testing.expect(!d2.session.breakpoints.items[1].enabled);
    try testing.expect(std.fs.path.isAbsolute(d2.session.breakpoints.items[0].file));

    // zig-out/bin: one file is the program; two need a choice.
    var why: []const u8 = "";
    try testing.expect(d2.findProgram(&why) == null);
    try tmp.dir.createDirPath(testing.io, "zig-out/bin");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "zig-out/bin/app", .data = "x" });
    const one = d2.findProgram(&why).?;
    defer testing.allocator.free(one);
    try testing.expect(std.mem.endsWith(u8, one, "bin/app"));
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "zig-out/bin/other", .data = "x" });
    try testing.expect(d2.findProgram(&why) == null);
    try testing.expect(std.mem.indexOf(u8, why, "several programs") != null);
}

test "end to end against a real adapter: break in a Zig program, read the stack and locals, step, continue to the end" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var p = try project_mod.testProject(&tmp);
    defer p.close();
    try p.writeFile("main.zig",
        \\const std = @import("std");
        \\fn add(a: i32, b: i32) i32 {
        \\    const sum = a + b;
        \\    return sum;
        \\}
        \\pub fn main() void {
        \\    const r = add(1, 2);
        \\    std.debug.print("r={d}\n", .{r});
        \\}
        \\
    );
    // The adapter and compiler are found like the IDE finds them.
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("PATH", "/usr/bin:/usr/local/bin:/bin");
    try env.put("HOME", "/tmp");
    const d = try Debugger.create(testing.allocator, testing.io, &p, &env, .{});
    defer d.destroy();
    if (d.adapter() == null) return error.SkipZigTest;
    const build = std.process.run(testing.allocator, testing.io, .{ // -fllvm: LLDB cannot read locals from the self-hosted backend's debug info (see docs/debugging.html).
        .argv = &.{ "zig", "build-exe", "main.zig", "-O", "Debug", "-fllvm" }, .cwd = .{ .path = p.root } }) catch return error.SkipZigTest;
    defer testing.allocator.free(build.stdout);
    defer testing.allocator.free(build.stderr);
    if (build.term != .exited or build.term.exited != 0) return error.SkipZigTest;

    const main_abs = try p.absPath(testing.allocator, "main.zig");
    defer testing.allocator.free(main_abs);
    try d.session.setBreakpoint(main_abs, 3, true, ""); // `const sum = a + b;`
    try d.start(.{ .program = "main" });
    try pumpUntil(d, 5000, isStopped);
    const s = d.session;
    if (s.state != .stopped) {
        for (s.console.items) |l| std.debug.print("console: {s}\n", .{l});
        return error.TestUnexpectedResult;
    }
    try testing.expectEqualStrings("breakpoint", s.stop_reason);
    try testing.expect(std.mem.indexOf(u8, s.frames[0].name, "add") != null);
    try testing.expectEqual(@as(u32, 3), s.frames[0].line);
    try testing.expect(std.mem.endsWith(u8, s.frames[0].path, "main.zig"));
    try testing.expect(s.breakpoints.items[0].verified == .verified);
    // The caller is on the stack too.
    var saw_main = false;
    for (s.frames) |f| {
        if (std.mem.indexOf(u8, f.name, "main") != null) saw_main = true;
    }
    try testing.expect(saw_main);
    // The arguments are locals.
    const locals = s.variables(s.scopes[0].reference).?;
    var saw_a = false;
    for (locals) |v| {
        if (std.mem.eql(u8, v.name, "a")) {
            saw_a = true;
            try testing.expectEqualStrings("1", v.value);
        }
    }
    try testing.expect(saw_a);

    s.stepOver();
    try pumpUntil(d, 5000, isStopped);
    try testing.expectEqual(session_mod.State.stopped, s.state);
    try testing.expectEqual(@as(u32, 4), s.frames[0].line);

    s.continueRun();
    try pumpUntil(d, 5000, isTerminated);
    try testing.expectEqual(session_mod.State.terminated, s.state);
    var saw_output = false;
    for (s.console.items) |l| {
        if (std.mem.indexOf(u8, l, "r=3") != null) saw_output = true;
    }
    try testing.expect(saw_output);
    try testing.expectEqual(@as(?i64, 0), s.exit_code);
}

fn zigLibDir(gpa: std.mem.Allocator, io: std.Io) ?[]u8 {
    const r = std.process.run(gpa, io, .{ .argv = &.{ "zig", "env" } }) catch return null;
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    const key = ".lib_dir = \"";
    const i = std.mem.indexOf(u8, r.stdout, key) orelse return null;
    const rest = r.stdout[i + key.len ..];
    const j = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return gpa.dupe(u8, rest[0..j]) catch null;
}

test "comptime session end to end: a block in a function of an imported file, breakpoint, step, locals, the synthetic root is removed" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var p = try project_mod.testProject(&tmp);
    defer p.close();
    try p.writeFile("src/util.zig",
        \\pub fn two() u32 {
        \\    return 2;
        \\}
        \\
    );
    try p.writeFile("src/lib.zig",
        \\const util = @import("util.zig");
        \\
        \\pub fn run(n: u32) u32 {
        \\    comptime {
        \\        var k: u32 = 5;
        \\        k += util.two();
        \\        _ = &k;
        \\    }
        \\    return n;
        \\}
        \\
    );
    var env = try testing.environ.createMap(testing.allocator);
    defer env.deinit();
    const d = try Debugger.create(testing.allocator, testing.io, &p, &env, .{});
    defer d.destroy();
    const ct = zigct.find(testing.allocator, testing.io, &env) orelse {
        std.debug.print("zigct is not built: skipping (tools/zigct/build.sh)\n", .{});
        return error.SkipZigTest;
    };
    testing.allocator.free(ct);
    const lib = zigLibDir(testing.allocator, testing.io) orelse return error.SkipZigTest;
    defer testing.allocator.free(lib);

    const abs = try p.absPath(testing.allocator, "src/lib.zig");
    defer testing.allocator.free(abs);
    try d.session.setBreakpoint(abs, 6, true, "");
    try d.startComptime(.{ .file = abs, .start_line = 4, .end_line = 8, .fn_path = "run", .zig_lib_dir = lib, .read_build = false });
    try testing.expect(d.session.isComptime());
    try pumpUntil(d, 30000, isStopped);
    const s = d.session;
    if (s.state != .stopped) {
        for (s.console.items) |l| std.debug.print("console: {s}\n", .{l});
        return error.TestUnexpectedResult;
    }
    // Stopped at the entry of the block (line 5), then the breakpoint on line 6.
    try testing.expectEqualStrings("entry", s.stop_reason);
    try testing.expectEqual(@as(u32, 5), s.frames[0].line);
    try testing.expectEqualStrings("run", s.frames[0].name);
    s.continueRun();
    try pumpUntil(d, 30000, isStoppedAgain);
    try testing.expectEqualStrings("breakpoint", s.stop_reason);
    try testing.expectEqual(@as(u32, 6), s.frames[0].line);
    const locals = s.variables(s.scopes[0].reference).?;
    try testing.expectEqualStrings("k", locals[0].name);
    try testing.expectEqualStrings("5", locals[0].value);
    // The synthetic root exists while the session runs, and is gone when it ends.
    try testing.expect(p.exists(comptime_root));
    s.continueRun();
    try pumpUntil(d, 30000, isTerminated);
    try testing.expectEqual(session_mod.State.terminated, s.state);
    d.poll(0);
    try testing.expect(!p.exists(comptime_root));
}

fn isStoppedAgain(d: *Debugger) bool {
    return d.session.state == .stopped and d.session.stop_count >= 2 and isStopped(d);
}

fn stoppedAfter(d: *Debugger, count: u32) bool {
    return d.session.state == .stopped and d.session.stop_count > count and isStopped(d);
}

test "comptime session in a project with a dependency: the build's module graph is used, so the block can import and step into the package" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var p = try project_mod.testProject(&tmp);
    defer p.close();
    try tmp.dir.createDirPath(testing.io, "mylib/src");
    try p.writeFile("build.zig.zon",
        \\.{
        \\    .name = .depproj,
        \\    .version = "0.0.1",
        \\    .fingerprint = 0x30362a229c3f08a1,
        \\    .minimum_zig_version = "0.17.0",
        \\    .dependencies = .{ .mylib = .{ .path = "mylib" } },
        \\    .paths = .{ "build.zig", "build.zig.zon", "src", "mylib" },
        \\}
        \\
    );
    try p.writeFile("mylib/build.zig.zon",
        \\.{
        \\    .name = .mylib,
        \\    .version = "0.0.1",
        \\    .fingerprint = 0xe7f9492974d36f0e,
        \\    .paths = .{ "build.zig", "build.zig.zon", "src" },
        \\}
        \\
    );
    try p.writeFile("mylib/build.zig",
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    _ = b.addModule("mylib", .{ .root_source_file = b.path("src/mylib.zig") });
        \\}
        \\
    );
    try p.writeFile("mylib/src/mylib.zig",
        \\pub fn triple(x: u32) u32 {
        \\    return x * 3;
        \\}
        \\
    );
    try p.writeFile("build.zig",
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    const mylib = b.dependency("mylib", .{}).module("mylib");
        \\    const exe = b.addExecutable(.{
        \\        .name = "depproj",
        \\        .root_module = b.createModule(.{
        \\            .root_source_file = b.path("src/main.zig"),
        \\            .target = b.standardTargetOptions(.{}),
        \\            .optimize = b.standardOptimizeOption(.{}),
        \\            .imports = &.{.{ .name = "mylib", .module = mylib }},
        \\        }),
        \\    });
        \\    b.installArtifact(exe);
        \\}
        \\
    );
    try p.writeFile("src/main.zig",
        \\const std = @import("std");
        \\const mylib = @import("mylib");
        \\
        \\comptime {
        \\    var t: u32 = 1;
        \\    t = mylib.triple(t);
        \\    if (t != 3) @compileError("bad");
        \\}
        \\
        \\pub fn main() void {
        \\    std.debug.print("{d}\n", .{mylib.triple(2)});
        \\}
        \\
    );
    var env = try testing.environ.createMap(testing.allocator);
    defer env.deinit();
    const d = try Debugger.create(testing.allocator, testing.io, &p, &env, .{});
    defer d.destroy();
    const ct = zigct.find(testing.allocator, testing.io, &env) orelse {
        std.debug.print("zigct is not built: skipping (tools/zigct/build.sh)\n", .{});
        return error.SkipZigTest;
    };
    testing.allocator.free(ct);
    const lib = zigLibDir(testing.allocator, testing.io) orelse return error.SkipZigTest;
    defer testing.allocator.free(lib);

    const abs = try p.absPath(testing.allocator, "src/main.zig");
    defer testing.allocator.free(abs);
    try d.startComptime(.{ .file = abs, .start_line = 4, .end_line = 8, .zig_lib_dir = lib });
    try testing.expect(d.preparing());
    try pumpUntil(d, 120000, isStopped); // reading the build can take a while the first time
    const s = d.session;
    if (s.state != .stopped) {
        for (s.console.items) |l| std.debug.print("console: {s}\n", .{l});
        return error.TestUnexpectedResult;
    }
    try testing.expect(!d.preparing());
    try testing.expectEqualStrings("entry", s.stop_reason);
    try testing.expectEqual(@as(u32, 5), s.frames[0].line);
    var count = s.stop_count;
    s.stepOver();
    try pumpUntil(d, 30000, struct {
        fn f(dd: *Debugger) bool {
            return dd.session.state == .stopped and dd.session.frames.len > 0 and dd.session.frames[0].line == 6 and isStopped(dd);
        }
    }.f);
    try testing.expectEqual(@as(u32, 6), s.frames[0].line);
    count = s.stop_count;
    s.stepIn();
    var tries: usize = 0;
    while (tries < 15000 and !stoppedAfter(d, count)) : (tries += 1) {
        d.poll(@intCast(tries * 2));
        pty_common.sleepMs(2);
    }
    try testing.expect(std.mem.indexOf(u8, s.frames[0].name, "triple") != null);
    try testing.expect(std.mem.endsWith(u8, s.frames[0].path, "mylib/src/mylib.zig"));
    const locals = s.variables(s.scopes[0].reference).?;
    try testing.expectEqualStrings("x", locals[0].name);
    try testing.expectEqualStrings("1", locals[0].value);
    // The wrapper files exist during the session and are gone after it.
    try testing.expect(p.exists("src/.zigct-root.zig"));
    try testing.expect(p.exists("src/.zigct-target.zig"));
    s.continueRun();
    try pumpUntil(d, 30000, isTerminated);
    d.poll(0);
    try testing.expect(!p.exists("src/.zigct-root.zig"));
    try testing.expect(!p.exists("src/.zigct-target.zig"));
}
