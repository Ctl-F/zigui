//! The IDE side of ZVM: a status-bar button showing the Zig version in use, a
//! picker to switch it, a picker to install more, and the questions the IDE asks
//! ("ZVM is not installed: install it?", "this project wants Zig 0.16.0, which is
//! not installed"). The work is done by ZVM itself, run in the Output panel so
//! its progress is visible; `zvm.zig` is the UI-free part.
//!
//!     const zv = try Versions.create(&ui, ui.tree.root, io, environ, .{
//!         .output = output_panel, .on_restart = .bind(&app, App.restart), .wake = sdl.wake,
//!         .command = "zig.switch_version", .global_dir = settings_dir });
//!     defer zv.destroy();
//!     const button = zv.button;            // put it in the status bar
//!     zv.startup(auto.wanted, auto.missing);   // once, after the window exists
//!     zv.poll();                           // each loop iteration
//!     zv.showSwitcher();                   // the commands
//!     zv.showInstaller();
//!
//! Switching runs `zvm use`, which changes `zig` for everything on the machine
//! (that is what ZVM does); the IDE then restarts on the same project so its
//! completion, language server and builds all use the new version.

const std = @import("std");
const Handle = @import("../core/handle.zig").Handle;
const Ui = @import("../core/ui.zig").Ui;
const Edges = @import("../core/style.zig").Edges;
const Button = @import("../widgets/button.zig").Button;
const quick_pick = @import("../widgets/quick_pick.zig");
const message_box = @import("../widgets/message_box.zig");
const output_panel = @import("output_panel.zig");
const zvm = @import("zvm.zig");

pub const VoidHook = struct {
    ctx: ?*anyopaque = null,
    call: *const fn (ctx: ?*anyopaque) void,

    pub fn bind(ctx: anytype, comptime f: anytype) VoidHook {
        const Ptr = @TypeOf(ctx);
        return .{
            .ctx = @ptrCast(ctx),
            .call = &struct {
                fn thunk(c: ?*anyopaque) void {
                    f(@as(Ptr, @ptrCast(@alignCast(c.?))));
                }
            }.thunk,
        };
    }
};

pub const Options = struct {
    output: *output_panel.OutputPanel,
    /// Restart the IDE on the same project (after `zvm use`).
    on_restart: ?VoidHook = null,
    /// Make the Output panel visible (ZVM's progress goes there).
    show_output: ?VoidHook = null,
    wake: ?*const fn () void = null,
    /// Where the button goes (default: the parent given to `create`, which also holds the overlays).
    button_parent: ?Handle = null,
    /// The command the status-bar button runs.
    command: []const u8 = "",
    /// The IDE's global settings folder (to remember "don't ask again").
    global_dir: ?[]const u8 = null,
    /// Replaces ZVM's install script (for tests).
    install_argv: ?[]const []const u8 = null,
};

const Question = enum { install_zvm, install_wanted, switch_after_install };
const Mode = enum { switch_version, install_version, new_project };
const Pending = enum { none, install_zvm, install_version, use_version, install_zls };

pub const Versions = struct {
    gpa: std.mem.Allocator,
    ui: *Ui,
    io: std.Io,
    environ: ?*const std.process.Environ.Map,
    opts: Options,
    button: *Button,
    picker: *quick_pick.QuickPick,
    box: *message_box.MessageBox,
    install: ?zvm.Install = null,
    fetcher: ?*zvm.Fetcher = null,
    installed: [][]u8 = &.{},
    current: ?[]u8 = null,
    /// What the open project asks for.
    wanted: ?[]u8 = null,
    wanted_missing: bool = false,
    /// What a running ZVM command is for, and the version it is about.
    pending: Pending = .none,
    pending_version: ?[]u8 = null,
    question: Question = .install_zvm,
    mode: Mode = .switch_version,
    /// Strings of the picker's rows.
    arena: std.heap.ArenaAllocator,
    rows: std.ArrayListUnmanaged(quick_pick.Item) = .empty,
    row_versions: std.ArrayListUnmanaged([]const u8) = .empty,
    new_project_hook: ?*const fn (ctx: ?*anyopaque, version: []const u8) void = null,
    new_project_ctx: ?*anyopaque = null,
    label_buf: [96]u8 = undefined,
    /// After installing, switch to the version at once (else ask).
    switch_after: bool = false,

    pub fn create(ui: *Ui, parent: Handle, io: std.Io, environ: ?*const std.process.Environ.Map, opts: Options) !*Versions {
        const self = try ui.gpa.create(Versions);
        errdefer ui.gpa.destroy(self);
        const picker = try quick_pick.QuickPick.create(ui, parent);
        errdefer picker.destroy();
        const box = try message_box.MessageBox.create(ui, parent);
        errdefer box.destroy();
        // The button goes where the caller puts it (the status bar).
        const button = try ui.add(Button, opts.button_parent orelse parent, .{ .text = "Zig", .variant = .flat, .style = .{ .padding = Edges.xy(8, 2), .shrink = 0 }, .command = if (opts.command.len > 0) opts.command else null });
        self.* = .{ .gpa = ui.gpa, .ui = ui, .io = io, .environ = environ, .opts = opts, .button = button, .picker = picker, .box = box, .arena = .init(ui.gpa) };
        self.refresh();
        return self;
    }

    pub fn destroy(self: *Versions) void {
        self.picker.destroy();
        self.box.destroy();
        if (self.fetcher) |f| f.destroy();
        if (self.install) |i| i.deinit(self.gpa);
        zvm.freeVersions(self.gpa, self.installed);
        if (self.current) |c| self.gpa.free(c);
        if (self.wanted) |w| self.gpa.free(w);
        if (self.pending_version) |p| self.gpa.free(p);
        self.rows.deinit(self.gpa);
        self.row_versions.deinit(self.gpa);
        self.arena.deinit();
        self.gpa.destroy(self);
    }

    /// Where ZVM's version is available: the `Install` found, if any.
    pub fn zvmInstall(self: *const Versions) ?zvm.Install {
        return self.install;
    }

    /// Installed versions, newest first.
    pub fn installedVersions(self: *const Versions) []const []u8 {
        return self.installed;
    }

    pub fn currentVersion(self: *const Versions) ?[]const u8 {
        return self.current;
    }

    /// Path of the `zig` program of an installed version (caller frees), or null without ZVM.
    pub fn zigPathFor(self: *const Versions, version: []const u8) ?[]u8 {
        const i = self.install orelse return null;
        return zvm.zigExe(self.gpa, i.home, version) catch null;
    }

    /// Read ZVM's state from disk again (and start the version list request when ZVM exists).
    pub fn refresh(self: *Versions) void {
        if (self.install) |i| i.deinit(self.gpa);
        self.install = zvm.locate(self.gpa, self.io, self.environ) catch null;
        zvm.freeVersions(self.gpa, self.installed);
        self.installed = &.{};
        if (self.current) |c| self.gpa.free(c);
        self.current = null;
        if (self.install) |i| {
            self.installed = zvm.installed(self.gpa, self.io, i.home) catch &.{};
            self.current = zvm.current(self.gpa, self.io, i.home);
            if (self.fetcher == null) {
                self.fetcher = zvm.Fetcher.start(self.gpa, self.io, i.exe, self.opts.wake) catch null;
            } else if (self.fetcher) |f| f.refresh() catch {};
        }
        self.updateButton();
    }

    fn updateButton(self: *Versions) void {
        const text = if (self.install == null)
            "Zig: no ZVM"
        else if (self.current) |c|
            std.fmt.bufPrint(&self.label_buf, "Zig {s}", .{c}) catch "Zig"
        else
            "Zig: none selected";
        self.button.setText(text) catch {};
    }

    // ---- startup ----

    /// Once the window exists: offer ZVM if it is missing (unless declined before),
    /// or offer to install the version the project asks for if ZVM lacks it.
    pub fn startup(self: *Versions, wanted: ?[]const u8, wanted_missing: bool) void {
        if (wanted) |w| self.wanted = self.gpa.dupe(u8, w) catch null;
        self.wanted_missing = wanted_missing;
        if (self.install == null) {
            if (!self.declined()) self.offerZvm();
            return;
        }
        if (wanted_missing) self.askInstallWanted();
    }

    fn markerPath(self: *Versions) ?[]u8 {
        const dir = self.opts.global_dir orelse return null;
        return std.fs.path.join(self.gpa, &.{ dir, zvm.declined_marker }) catch null;
    }

    fn declined(self: *Versions) bool {
        const p = self.markerPath() orelse return false;
        defer self.gpa.free(p);
        std.Io.Dir.cwd().access(self.io, p, .{}) catch return false;
        return true;
    }

    fn markDeclined(self: *Versions) void {
        const dir = self.opts.global_dir orelse return;
        const p = self.markerPath() orelse return;
        defer self.gpa.free(p);
        std.Io.Dir.cwd().createDirPath(self.io, dir) catch return;
        std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = p, .data = "The IDE does not offer to install ZVM again. Delete this file to be asked again.\n" }) catch {};
    }

    /// Ask whether to install ZVM (the `zig.install_zvm` command, and the first-start question).
    pub fn offerZvm(self: *Versions) void {
        if (self.install != null) return;
        var buf: [400]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "ZVM (the Zig version manager) was not found on this machine.\nWith it the IDE can switch Zig versions, install new ones, and\nuse the version each project asks for.\n\nInstall it now? This runs ZVM's official installer:\n    {s}", .{zvm.install_script_text}) catch "Install ZVM?";
        self.question = .install_zvm;
        self.box.show(.{ .title = "Install ZVM?", .message = msg, .buttons = &.{ "Install ZVM", "Not now", "Don't ask again" }, .cancel = 1, .on_choice = .bind(self, onChoice) });
    }

    fn askInstallWanted(self: *Versions) void {
        const w = self.wanted orelse return;
        var buf: [300]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "This project asks for Zig {s}, which ZVM has not installed.\n\nInstall it and switch to it? The IDE restarts afterwards.", .{w}) catch "Install the project's Zig version?";
        self.question = .install_wanted;
        self.box.show(.{ .title = "Zig version missing", .message = msg, .buttons = &.{ "Install and switch", "Not now" }, .on_choice = .bind(self, onChoice) });
    }

    fn onChoice(self: *Versions, index: usize) void {
        switch (self.question) {
            .install_zvm => switch (index) {
                0 => self.runInstallZvm(),
                2 => self.markDeclined(),
                else => {},
            },
            .install_wanted => if (index == 0) {
                if (self.wanted) |w| self.runInstallVersion(w, true);
            },
            .switch_after_install => if (index == 0) {
                if (self.pending_version) |v| self.runUse(v);
            },
        }
    }

    // ---- running ZVM ----

    fn showOutput(self: *Versions) void {
        if (self.opts.show_output) |h| h.call(h.ctx);
    }

    fn runInstallZvm(self: *Versions) void {
        const argv = self.opts.install_argv orelse zvm.install_script_argv;
        self.showOutput();
        self.opts.output.run(self.io, argv, null, self.opts.wake) catch return;
        self.pending = .install_zvm;
    }

    fn remoteHasZls(self: *const Versions, version: []const u8) bool {
        const f = self.fetcher orelse return false;
        for (f.versions()) |r| {
            if (std.mem.eql(u8, r.version, version)) return r.zls;
        }
        return false;
    }

    fn runInstallVersion(self: *Versions, version: []const u8, then_use: bool) void {
        const i = self.install orelse return;
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const argv = zvm.installArgv(arena.allocator(), i.exe, version, self.remoteHasZls(version)) catch return;
        self.showOutput();
        self.opts.output.run(self.io, argv, null, self.opts.wake) catch return;
        self.setPendingVersion(version);
        self.pending = .install_version;
        self.switch_after = then_use;
    }
    fn setPendingVersion(self: *Versions, version: []const u8) void {
        const copy = self.gpa.dupe(u8, version) catch return;
        if (self.pending_version) |p| self.gpa.free(p);
        self.pending_version = copy;
    }

    fn runUse(self: *Versions, version: []const u8) void {
        const i = self.install orelse return;
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const argv = zvm.useArgv(arena.allocator(), i.exe, version) catch return;
        self.showOutput();
        self.opts.output.run(self.io, argv, null, self.opts.wake) catch return;
        self.setPendingVersion(version);
        self.pending = .use_version;
    }

    /// `zvm install <current> --zls`: add the language server for the Zig version in use
    /// (it leaves Zig itself alone), then restart so the IDE starts it.
    pub fn installZls(self: *Versions) void {
        const i = self.install orelse return self.offerZvm();
        const cur = self.current orelse return;
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const argv = zvm.installArgv(arena.allocator(), i.exe, cur, true) catch return;
        self.showOutput();
        self.opts.output.run(self.io, argv, null, self.opts.wake) catch return;
        self.pending = .install_zls;
    }

    /// Call every loop iteration: version list answers and finished ZVM commands.
    pub fn poll(self: *Versions) void {
        if (self.fetcher) |f| {
            if (f.poll() and self.picker.isOpen() and self.mode == .install_version) self.fillInstaller();
        }
        if (self.pending == .none) return;
        const out = self.opts.output;
        if (out.running) return;
        const code = out.exit_code orelse return;
        const what = self.pending;
        self.pending = .none;
        if (code != 0) return; // the Output panel already shows what went wrong
        switch (what) {
            .none => {},
            .install_zvm => {
                self.refresh();
                if (self.install != null) {
                    if (self.wanted_missing) self.askInstallWanted();
                }
            },
            .install_version => {
                self.refresh();
                const v = self.pending_version orelse return;
                if (self.switch_after) {
                    self.runUse(v);
                } else {
                    var buf: [200]u8 = undefined;
                    const msg = std.fmt.bufPrint(&buf, "Zig {s} is installed.\n\nSwitch to it now? The IDE restarts afterwards.", .{v}) catch "Switch now?";
                    self.question = .switch_after_install;
                    self.box.show(.{ .title = "Installed", .message = msg, .buttons = &.{ "Switch", "Not now" }, .on_choice = .bind(self, onChoice) });
                }
            },
            .use_version, .install_zls => if (self.opts.on_restart) |h| h.call(h.ctx),
        }
    }

    // ---- pickers ----

    fn resetRows(self: *Versions) void {
        _ = self.arena.reset(.retain_capacity);
        self.rows.clearRetainingCapacity();
        self.row_versions.clearRetainingCapacity();
    }

    fn addRow(self: *Versions, label: []const u8, detail: []const u8, version: []const u8) void {
        const a = self.arena.allocator();
        const l = a.dupe(u8, label) catch return;
        const d = a.dupe(u8, detail) catch return;
        const v = a.dupe(u8, version) catch return;
        self.rows.append(self.gpa, .{ .label = l, .detail = d }) catch return;
        self.row_versions.append(self.gpa, v) catch {
            _ = self.rows.pop();
        };
    }

    fn isCurrent(self: *const Versions, v: []const u8) bool {
        const c = self.current orelse return false;
        return std.mem.eql(u8, c, v);
    }

    /// The Zig version picker: installed versions, and a way to install another.
    pub fn showSwitcher(self: *Versions) void {
        if (self.install == null) return self.offerZvm();
        self.refresh();
        self.resetRows();
        for (self.installed) |v| {
            var detail: []const u8 = "";
            if (self.isCurrent(v)) detail = "in use";
            if (self.wanted) |w| {
                if (std.mem.eql(u8, w, v)) detail = if (self.isCurrent(v)) "in use, what this project asks for" else "what this project asks for";
            }
            self.addRow(v, detail, v);
        }
        self.addRow("Install another version...", "", "");
        self.mode = .switch_version;
        self.picker.show(.{ .placeholder = "Switch Zig version", .items = self.rows.items, .on_pick = .bind(self, onPick) });
        self.picker.setStatus(if (self.installed.len == 0) "no Zig versions installed yet" else "switching restarts the IDE");
    }

    /// The installable versions (the list comes from ZVM and needs the network).
    pub fn showInstaller(self: *Versions) void {
        if (self.install == null) return self.offerZvm();
        self.refresh();
        self.mode = .install_version;
        self.fillInstaller();
        self.picker.show(.{ .placeholder = "Install a Zig version", .items = self.rows.items, .on_pick = .bind(self, onPick) });
        self.installerStatus();
    }

    fn fillInstaller(self: *Versions) void {
        self.resetRows();
        if (self.fetcher) |f| {
            for (f.versions()) |r| {
                if (r.installed and !std.mem.eql(u8, r.version, "master")) continue;
                const detail: []const u8 = if (std.mem.eql(u8, r.version, "master")) (if (r.installed) "development build (update)" else "development build") else if (r.zls) "with ZLS" else "";
                self.addRow(r.version, detail, r.version);
            }
        }
        if (self.picker.isOpen()) {
            self.picker.setItems(self.rows.items);
            self.installerStatus();
        }
    }

    fn installerStatus(self: *Versions) void {
        const f = self.fetcher orelse return;
        if (f.running()) return self.picker.setStatus("asking ZVM for the available versions...");
        if (f.failed) return self.picker.setStatus("ZVM could not list versions (offline?)");
        if (self.rows.items.len == 0) return self.picker.setStatus("every released version is installed");
        self.picker.setStatus("installing runs ZVM in the Output panel");
    }

    /// A picker of installed versions for a new project; `hook` gets the chosen one.
    pub fn showProjectVersions(self: *Versions, ctx: *anyopaque, hook: *const fn (ctx: ?*anyopaque, version: []const u8) void) bool {
        if (self.install == null or self.installed.len == 0) return false;
        self.refresh();
        self.resetRows();
        // The version in use first: it is what most people want.
        if (self.current) |c| self.addRow(c, "in use", c);
        for (self.installed) |v| {
            if (self.isCurrent(v)) continue;
            self.addRow(v, "", v);
        }
        self.mode = .new_project;
        self.new_project_hook = hook;
        self.new_project_ctx = ctx;
        self.picker.show(.{ .placeholder = "Zig version for the new project", .items = self.rows.items, .on_pick = .bind(self, onPick) });
        self.picker.setStatus("the project records it in .zigversion");
        return true;
    }

    fn onPick(self: *Versions, index: usize) void {
        if (index >= self.row_versions.items.len) return;
        const v = self.row_versions.items[index];
        switch (self.mode) {
            .switch_version => {
                if (v.len == 0) return self.showInstaller();
                if (self.isCurrent(v)) return;
                self.runUse(v);
            },
            .install_version => self.runInstallVersion(v, false),
            .new_project => if (self.new_project_hook) |h| h(self.new_project_ctx, v),
        }
    }
};

// ---- tests -----------------------------------------------------------------

const testing = std.testing;
const builtin = @import("builtin");
const Rig = @import("../core/test_rig.zig").Rig;

fn pump(r: *Rig, zv: *Versions, cond: *const fn (*Versions) bool) !void {
    var tries: usize = 0;
    while (tries < 4000 and !cond(zv)) : (tries += 1) {
        zv.opts.output.poll();
        zv.poll();
        try r.frame();
        @import("../platform/pty_common.zig").sleepMs(2);
    }
}

test "without ZVM the button says so, and the first start offers the installer once" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const a = testing.allocator;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    const root = try a.dupe(u8, buf[0..n]);
    defer a.free(root);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", root);
    try env.put("PATH", "/nonexistent-dir");

    const r = try Rig.init();
    defer r.deinit();
    const out = try output_panel.OutputPanel.create(&r.ui, r.ui.tree.root, .{});
    defer out.destroy();
    const settings_dir = try std.fs.path.join(a, &.{ root, "cfg" });
    defer a.free(settings_dir);
    const zv = try Versions.create(&r.ui, r.ui.tree.root, testing.io, &env, .{ .output = out, .global_dir = settings_dir });
    defer zv.destroy();
    try r.frame();
    try testing.expect(zv.install == null);
    zv.startup(null, false);
    try testing.expect(zv.box.isOpen());
    zv.box.choose(2); // Don't ask again
    try testing.expect(!zv.box.isOpen());
    // A second start stays quiet.
    zv.startup(null, false);
    try testing.expect(!zv.box.isOpen());
}

test "accepting runs the installer, and ZVM is found once it has run" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const a = testing.allocator;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    const root = try a.dupe(u8, buf[0..n]);
    defer a.free(root);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", root);
    try env.put("PATH", "/nonexistent-dir");

    // The "installer" creates ~/.zvm/self/zvm.
    const script = try std.fmt.allocPrint(a, "mkdir -p {s}/.zvm/self && printf '#!/bin/sh\\n' > {s}/.zvm/self/zvm && chmod +x {s}/.zvm/self/zvm && echo installed", .{ root, root, root });
    defer a.free(script);
    const r = try Rig.init();
    defer r.deinit();
    const out = try output_panel.OutputPanel.create(&r.ui, r.ui.tree.root, .{});
    defer out.destroy();
    const zv = try Versions.create(&r.ui, r.ui.tree.root, testing.io, &env, .{ .output = out, .install_argv = &.{ "sh", "-c", script } });
    defer zv.destroy();
    try r.frame();
    zv.offerZvm();
    try testing.expect(zv.box.isOpen());
    zv.box.choose(0);
    try pump(r, zv, struct {
        fn done(z: *Versions) bool {
            return z.install != null;
        }
    }.done);
    try testing.expect(zv.install != null);
    try testing.expectEqual(Pending.none, zv.pending);
}

test "with ZVM, the switcher lists installed versions and picking one runs `zvm use` then restarts" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const a = testing.allocator;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    const root = try a.dupe(u8, buf[0..n]);
    defer a.free(root);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", root);
    try env.put("PATH", "/nonexistent-dir");
    try tmp.dir.createDirPath(testing.io, ".zvm/self");
    try tmp.dir.createDirPath(testing.io, ".zvm/0.16.0");
    try tmp.dir.createDirPath(testing.io, ".zvm/0.17.0");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".zvm/0.16.0/zig", .data = "x" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".zvm/0.17.0/zig", .data = "x" });
    try tmp.dir.symLink(testing.io, "0.17.0", ".zvm/bin", .{ .is_directory = true });
    // A fake ZVM: `use` succeeds and says what it was asked; the list request fails (offline).
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".zvm/self/zvm", .data = "#!/bin/sh\n[ \"$3\" = use ] && echo \"using $4\" && exit 0\nexit 1\n" });
    try tmp.dir.setFilePermissions(testing.io, ".zvm/self/zvm", .executable_file, .{});

    const r = try Rig.init();
    defer r.deinit();
    const out = try output_panel.OutputPanel.create(&r.ui, r.ui.tree.root, .{});
    defer out.destroy();
    const Restarted = struct {
        n: u32 = 0,
        fn go(self: *@This()) void {
            self.n += 1;
        }
    };
    var restarted: Restarted = .{};
    const zv = try Versions.create(&r.ui, r.ui.tree.root, testing.io, &env, .{ .output = out, .on_restart = .bind(&restarted, Restarted.go) });
    defer zv.destroy();
    try r.frame();
    try testing.expectEqual(@as(usize, 2), zv.installed.len);
    try testing.expectEqualStrings("0.17.0", zv.current.?);
    try testing.expectEqualStrings("Zig 0.17.0", zv.button.props.text.bytes);

    zv.showSwitcher();
    try r.frame();
    // Rows: 0.17.0 (in use), 0.16.0, "Install another version...".
    try testing.expectEqual(@as(usize, 3), zv.rows.items.len);
    try testing.expectEqualStrings("0.17.0", zv.rows.items[0].label);
    try testing.expectEqualStrings("in use", zv.rows.items[0].detail);
    zv.onPick(1); // 0.16.0
    try testing.expectEqual(Pending.use_version, zv.pending);
    try pump(r, zv, struct {
        fn done(z: *Versions) bool {
            return z.pending == .none;
        }
    }.done);
    try testing.expectEqual(@as(u32, 1), restarted.n);
    try testing.expect(std.mem.indexOf(u8, out.editor.editor.doc.range(0, out.editor.editor.doc.len()) catch "", "using 0.16.0") != null);
}
