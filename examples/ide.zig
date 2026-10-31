//! The IDE: a project's files, find in project, tabbed source editors, and the
//! Output panel, all in one dock. This is the workbench's sibling that edits a
//! folder of code instead of one UI document.
//!
//! Run:  zig build ide                     (opens the current folder)
//!       zig-out/bin/ide path/to/project
//!
//! Double-click a file in Files to open it; Ctrl+S saves; Ctrl+F finds in the
//! file, Ctrl+Shift+F finds in the project; F5 runs `zig build run`, Ctrl+B `zig build`, Ctrl+Shift+F6 restarts the IDE (a fresh copy of the executable on the
//! same folder and files), Ctrl+Shift+F5 builds and restarts if the build succeeds, Ctrl+` opens the terminal, and Ctrl+Shift+T
//! `zig build test` (double-click an error in Output to jump to it).
//!
//! Env (headless checks, with SDL_VIDEODRIVER=dummy):
//!   ZIGUI_SCRIPT="open src/main.zig;search needle;sleep 300"   open PATH[:LINE] |
//!       search TEXT | sleep MS | wheel X Y DY | click X Y | type TEXT | key [mods+]NAME
//!   ZIGUI_SCREENSHOT=out.png

const std = @import("std");
const zigui = @import("zigui");
const sdl = @import("zigui_sdl");
const stb = @import("zigui_stb");

const Ui = zigui.Ui;
const ide = zigui.ide; // hello

/// The IDE's key bindings (the `mod` key is Ctrl, or Cmd on macOS); users change them in a keymap file.
const default_bindings = [_][2][]const u8{
    .{ "f5", "ide.run" },
    .{ "mod+b", "ide.build" },
    .{ "ctrl+shift+f6", "ide.restart" },
    .{ "ctrl+shift+f5", "ide.build_restart" },
    .{ "mod+shift+t", "ide.test" },
    .{ "mod+s", "file.save" },
    .{ "mod+shift+s", "file.save_all" },
    .{ "mod+w", "file.close" },
    .{ "mod+z", "edit.undo" },
    .{ "mod+shift+z", "edit.redo" },
    .{ "mod+x", "edit.cut" },
    .{ "mod+c", "edit.copy" },
    .{ "mod+v", "edit.paste" },
    .{ "mod+a", "edit.select_all" },
    .{ "mod+f", "edit.find" },
    .{ "mod+h", "edit.replace" },
    .{ "mod+shift+f", "project.search" },
    .{ "f12", "editor.definition" },
    .{ "f2", "refactor.rename_handler" },
    .{ "mod+`", "view.terminal" },
};

const App = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    ui: *Ui,
    project: *ide.Project,
    dock: *zigui.Dock,
    docs: *ide.Documents = undefined,
    files: *ide.FilesPanel = undefined,
    search: *ide.SearchPanel = undefined,
    output: *ide.OutputPanel = undefined,
    status: *zigui.Label = undefined,
    lsp: *ide.lsp_assist.Assist = undefined,
    terminal: *ide.TerminalPanel = undefined,
    designer: *ide.designer.Designer = undefined,
    environ: ?*const std.process.Environ.Map = null,
    /// Settings and keymaps as last read (the strings live in its arena).
    loaded: ide.settings.Loaded = undefined,
    /// The theme's own text size, to go back to when a setting is removed.
    base_font_size: f32 = 14,
    /// The arrangement the IDE started with (before a saved session changed it), for Reset Panel Layout.
    default_layout: []u8 = &.{},
    prompt: *ide.prompt.Prompt = undefined,
    welcome_panel: *zigui.dock.Panel = undefined,
    output_panel: *zigui.dock.Panel = undefined,
    /// An edit command (Undo, Copy...) is forwarding itself as a key press; the
    /// shortcut for it must not run it again if nothing used the key.
    forwarding: bool = false,
    /// Quit was asked while files had unsaved changes: asking again discards them.
    quit_armed: bool = false,
    /// Renaming a handler: what was found, and the new name once confirmed.
    rename_scan: ?ide.handlers.Scan = null,
    rename_index: usize = 0,
    rename_pending: [96]u8 = undefined,
    rename_pending_len: usize = 0,
    /// Leave the main loop (set when a new instance has been started).
    quit: bool = false,
    /// Scripted (headless) runs only log what a restart would start: the new
    /// instance would inherit the script and restart again.
    dry_restart: bool = false,
    /// Read and write the session (off in scripted runs unless ZIGUI_SESSION=1, so tests leave no trace).
    session_enabled: bool = true,
    /// A build was started to be followed by a restart if it succeeds.
    restart_after_build: bool = false,
    terminal_panel: *zigui.dock.Panel = undefined,
    files_panel: *zigui.dock.Panel = undefined,
    search_panel: *zigui.dock.Panel = undefined,

    fn openFile(self: *App, path: []const u8) void {
        if (ide.designer.isUiDocument(path)) {
            self.designer.open(path) catch |err| self.setStatus("could not open {s} in the designer: {s}", .{ path, @errorName(err) });
            return;
        }
        self.openAt(path, 0, 0);
    }

    fn openAt(self: *App, path: []const u8, line: u32, col: u32) void {
        // Compiler output carries paths relative to where the build ran (the
        // project root) or absolute ones.
                
        const rel = self.project.relPath(path) orelse path;
        _ = self.docs.open(rel, line, col) catch |err| {
            var buf: [200]u8 = undefined;
            self.status.setText(std.fmt.bufPrint(&buf, "could not open {s}: {s}", .{ rel, @errorName(err) }) catch "could not open file") catch {};
        };
    }

    fn runBuild(self: *App, step: []const u8) void {
        if (self.dock.panelNamed("Output")) |p| {
            if (p.state == .hidden) self.dock.showPanel(p) catch {};
        }
        _ = self.docs.saveAll();
        const argv: []const []const u8 = if (step.len == 0) &.{ "zig", "build" } else &.{ "zig", "build", step };
        self.output.run(self.io, argv, self.project.root, sdl.wake) catch |err| {
            std.log.err("could not start zig build: {s}", .{@errorName(err)});
        };
    }

    /// Start a new copy of this program on the same folder and files, then quit.
    fn restartNow(self: *App) void {
        _ = self.docs.saveAll();
        self.saveSession();
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var files: std.ArrayListUnmanaged([]const u8) = .empty;
        for (self.docs.docs.items) |d| files.append(a, d.path) catch {};
        const exe = std.process.executablePathAlloc(self.io, a) catch |err| {
            self.setStatus("cannot restart: no executable path ({s})", .{@errorName(err)});
            return;
        };
        const target = ide.relaunch.resolveExe(a, self.io, exe) catch exe;
        const cmd = ide.relaunch.argv(a, target, self.project.root, files.items) catch return;
        if (self.dry_restart) {
            std.log.info("restart: would start {s} {s} (+{d} more arguments)", .{ cmd[0], cmd[1], cmd.len - 2 });
            self.quit = true;
            return;
        }
        ide.relaunch.spawnDetached(self.io, cmd) catch |err| {
            self.setStatus("cannot restart: could not start {s} ({s})", .{ cmd[0], @errorName(err) });
            return;
        };
        self.quit = true;
    }

    fn setStatus(self: *App, comptime fmt: []const u8, args: anytype) void {
        var buf: [240]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, fmt, args) catch "";
        std.log.warn("{s}", .{text});
        self.status.setText(text) catch {};
    }

    /// Make panel `p` visible and bring it forward.
    fn showPanel(self: *App, p: *zigui.dock.Panel) void {
        self.dock.showPanel(p) catch {};
        self.dock.activatePanel(p);
    }

    /// Edit commands act on whatever has focus by pressing the key it would
    /// have used (so they work in editors, text fields and the designer alike).
    fn forward(self: *App, key: zigui.keys.Key, mods: zigui.keys.Mods) void {
        if (self.forwarding) return;
        self.forwarding = true;
        defer self.forwarding = false;
        self.ui.key(key, mods, true, false);
        self.ui.key(key, mods, false, false);
    }

    fn focusInTerminal(self: *App) bool {
        return self.ui.focused() != null and self.ui.focused().?.eql(self.terminal.term.node);
    }

    fn editCommand(self: *App, name: []const u8) void {
        const K = zigui.keys.Key;
        // A terminal copies and pastes with Ctrl+Shift (Ctrl+C is an interrupt there).
        if (self.focusInTerminal()) {
            if (std.mem.eql(u8, name, "edit.copy")) return self.forward(K.c, .{ .ctrl = true, .shift = true });
            if (std.mem.eql(u8, name, "edit.paste")) return self.forward(K.v, .{ .ctrl = true, .shift = true });
            return;
        }
        if (std.mem.eql(u8, name, "edit.undo")) self.forward(K.z, .{ .ctrl = true }) else if (std.mem.eql(u8, name, "edit.redo")) self.forward(K.z, .{ .ctrl = true, .shift = true }) else if (std.mem.eql(u8, name, "edit.cut")) self.forward(K.x, .{ .ctrl = true }) else if (std.mem.eql(u8, name, "edit.copy")) self.forward(K.c, .{ .ctrl = true }) else if (std.mem.eql(u8, name, "edit.paste")) self.forward(K.v, .{ .ctrl = true }) else if (std.mem.eql(u8, name, "edit.select_all")) self.forward(K.a, .{ .ctrl = true }) else if (std.mem.eql(u8, name, "edit.find")) self.forward(K.f, .{ .ctrl = true }) else if (std.mem.eql(u8, name, "edit.replace")) self.forward(K.h, .{ .ctrl = true });
    }

    // ---- settings, keymap, session ----

    /// Read the settings and keymaps (the global files, then the project's) and apply them.
    fn reloadSettings(self: *App) void {
        const fresh = ide.settings.load(self.gpa, self.io, self.project, self.environ) catch |err| return self.setStatus("could not read settings: {s}", .{@errorName(err)});
        self.loaded.deinit();
        self.loaded = fresh;
        self.applySettings();
    }

    fn applySettings(self: *App) void {
        const s = self.loaded.settings;
        self.ui.theme.font_size = if (s.ui_font_size > 0) s.ui_font_size else self.base_font_size;
        self.docs.defaults = .{ .size = s.editor_font_size, .tab_width = s.tab_width, .line_numbers = s.line_numbers, .folding = s.folding };
        self.docs.applyDefaults();
        self.ui.tree.markDirty(self.ui.tree.root, .{ .layout = true, .paint = true });
        if (s.problems > 0) self.setStatus("settings: {d} entries were not understood and were ignored", .{s.problems});
    }

    fn applyKeymap(self: *App) void {
        if (self.loaded.keymap.len == 0) return;
        const report = self.ui.loadKeymap(self.loaded.keymap);
        if (report.errors > 0) self.setStatus("keybindings: {d} lines were not understood (first: line {d})", .{ report.errors, report.first_error_line });
    }

    /// Open a file under `.zigide/`, creating it from `text` first if it is missing.
    fn openConfig(self: *App, rel: []const u8, text: []const u8) void {
        if (self.project.readFile(self.gpa, rel, 16)) |existing| self.gpa.free(existing) else |_| {
            self.project.dir.createDirPath(self.io, ".zigide") catch {};
            self.project.writeFile(rel, text) catch |err| return self.setStatus("could not create {s}: {s}", .{ rel, @errorName(err) });
        }
        _ = self.docs.open(rel, 0, 0) catch |err| self.setStatus("could not open {s}: {s}", .{ rel, @errorName(err) });
    }

    /// A document was saved: reread the settings or keymap if that is what it was.
    fn savedThunk(ctx: ?*anyopaque, doc: *ide.documents.Doc) void {
        const self: *App = @ptrCast(@alignCast(ctx.?));
        self.onSaved(doc);
    }

    fn onSaved(self: *App, doc: *ide.documents.Doc) void {
        if (std.mem.eql(u8, doc.path, ide.settings.project_settings) or std.mem.eql(u8, doc.path, ide.settings.project_keymap)) {
            self.reloadSettings();
            self.applyKeymap();
        }
    }

    fn saveSession(self: *App) void {
        if (!self.session_enabled) return;
        ide.session.save(self.gpa, self.project, self.docs, self.dock, self.designer) catch |err| std.log.warn("could not save the session: {s}", .{@errorName(err)});
    }

    fn onCommand(self: *App, ev: *zigui.Event) void {
        const name = ev.text;
        const eq = std.mem.eql;
        if (std.mem.startsWith(u8, name, "edit.")) return self.editCommand(name);
        if (!eq(u8, name, "file.quit")) self.quit_armed = false;
        if (eq(u8, name, "ide.restart")) {
            self.restartNow();
        } else if (eq(u8, name, "ide.build_restart")) {
            self.runBuild("");
            self.restart_after_build = self.output.running;
        } else if (eq(u8, name, "ide.build")) {
            self.runBuild("");
        } else if (eq(u8, name, "ide.run")) {
            self.runBuild("run");
        } else if (eq(u8, name, "ide.test")) {
            self.runBuild("test");
        } else if (eq(u8, name, "file.save")) {
            _ = self.docs.saveActive();
        } else if (eq(u8, name, "file.save_all")) {
            _ = self.docs.saveAll();
        } else if (eq(u8, name, "file.close")) {
            if (self.docs.active()) |d| self.dock.requestClose(d.panel);
        } else if (eq(u8, name, "file.new_ui")) {
            self.prompt.ask("New UI document (a path ending in .ui.zon):", "ui/untitled.ui.zon", .bind(self, onNewUiName));
        } else if (eq(u8, name, "file.design")) {
            const d = self.docs.active() orelse return self.setStatus("open a .zon document to design it", .{});
            if (!std.mem.endsWith(u8, d.path, ".zon")) return self.setStatus("{s} is not a .zon document", .{d.path});
            self.designer.attach(d) catch |err| self.setStatus("cannot design {s}: {s}", .{ d.path, @errorName(err) });
        } else if (eq(u8, name, "file.refresh")) {
            self.files.reload() catch {};
        } else if (eq(u8, name, "file.settings")) {
            self.openConfig(ide.settings.project_settings, ide.settings.template);
        } else if (eq(u8, name, "file.keybindings")) {
            var arena = std.heap.ArenaAllocator.init(self.gpa);
            defer arena.deinit();
            const text = ide.settings.keymapTemplate(arena.allocator(), &default_bindings) catch return;
            self.openConfig(ide.settings.project_keymap, text);
        } else if (eq(u8, name, "view.reset_layout")) {
            self.dock.loadLayout(self.default_layout) catch |err| self.setStatus("could not reset the layout: {s}", .{@errorName(err)});
        } else if (eq(u8, name, "file.quit")) {
            if (self.docs.anyDirty() and !self.quit_armed) {
                self.quit_armed = true;
                self.setStatus("unsaved changes: Save All first, or choose Quit again to discard them", .{});
            } else self.quit = true;
        } else if (eq(u8, name, "view.files")) {
            self.showPanel(self.files_panel);
        } else if (eq(u8, name, "view.search")) {
            self.showPanel(self.search_panel);
        } else if (eq(u8, name, "view.output")) {
            self.showPanel(self.output_panel);
        } else if (eq(u8, name, "view.terminal")) {
            self.showPanel(self.terminal_panel);
            self.terminal.focus();
        } else if (eq(u8, name, "view.welcome")) {
            self.showPanel(self.welcome_panel);
        } else if (eq(u8, name, "view.designer")) {
            if (self.designer.builder) |b| b.setPanelsVisible(true) else self.setStatus("open a .ui.zon document first (File > New UI Document)", .{});
        } else if (eq(u8, name, "editor.definition")) {
            if (self.docs.active()) |d| self.lsp.gotoDefinition(d.editor);
        } else if (eq(u8, name, "project.search")) {
            self.showPanel(self.search_panel);
            self.ui.setFocus(self.search.field.node);
        } else if (eq(u8, name, "refactor.rename_handler")) {
            self.beginRename();
        } else if (eq(u8, name, "refactor.regenerate")) {
            self.designer.service.commit() catch |err| return self.setStatus("could not regenerate {s}: {s}", .{ ide.handlers.binding_file, @errorName(err) });
            self.setStatus("regenerated {s}", .{ide.handlers.binding_file});
        }
    }

    // ---- UI documents ----

    fn onNewUiName(self: *App, text: []const u8) void {
        var name = std.mem.trim(u8, text, " \t");
        if (name.len == 0) return;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        if (!std.mem.endsWith(u8, name, ".ui.zon")) name = std.fmt.bufPrint(&buf, "{s}.ui.zon", .{name}) catch return;
        if (self.project.readFile(self.gpa, name, 16)) |existing| {
            self.gpa.free(existing);
            return self.setStatus("{s} already exists", .{name});
        } else |_| {}
        if (std.fs.path.dirname(name)) |dir| self.project.dir.createDirPath(self.io, dir) catch {};
        var doc = zigui.uidoc.Doc.init(self.gpa) catch return;
        defer doc.deinit();
        const zon = doc.toZon(self.gpa) catch return;
        defer self.gpa.free(zon);
        self.project.writeFile(name, zon) catch |err| return self.setStatus("could not create {s}: {s}", .{ name, @errorName(err) });
        // The Zig file that goes with it, where its event handlers will live.
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        if (ide.handlers.companionFor(arena.allocator(), name)) |t| {
            if (self.project.readFile(self.gpa, t.file, 16)) |existing| self.gpa.free(existing) else |_| {
                if (ide.handlers.newFileText(arena.allocator(), t, "")) |body| self.project.writeFile(t.file, body) catch {} else |_| {}
            }
        } else |_| {}
        self.files.reload() catch {};
        self.designer.open(name) catch |err| self.setStatus("could not open {s}: {s}", .{ name, @errorName(err) });
    }

    // ---- renaming a handler ----

    /// The identifier around byte offset `at` of `text`.
    fn wordAt(text: []const u8, at: usize) []const u8 {
        var s = @min(at, text.len);
        var e = s;
        while (s > 0 and (std.ascii.isAlphanumeric(text[s - 1]) or text[s - 1] == '_')) s -= 1;
        while (e < text.len and (std.ascii.isAlphanumeric(text[e]) or text[e] == '_')) e += 1;
        return text[s..e];
    }

    fn beginRename(self: *App) void {
        const d = self.docs.active() orelse return self.setStatus("open the file with the handler and put the caret on its name", .{});
        const core = d.editor.core();
        const head = core.primaryHead();
        const text = d.editor.textAlloc(self.gpa) catch return;
        defer self.gpa.free(text);
        const word = wordAt(text, head);
        if (word.len == 0) return self.setStatus("put the caret on the handler's name", .{});
        if (self.rename_scan) |*old| old.deinit();
        self.rename_scan = ide.handlers.scan(self.gpa, self.project) catch null;
        const sc = &(self.rename_scan orelse return);
        var found: ?usize = null;
        for (sc.handlers, 0..) |h, i| {
            if (std.mem.eql(u8, h.file, d.path) and std.mem.eql(u8, h.name, word)) found = i;
        }
        const i = found orelse return self.setStatus("{s} is not an event handler (a method taking *Event)", .{word});
        self.rename_index = i;
        self.rename_pending_len = 0;
        var buf: [160]u8 = undefined;
        self.prompt.ask(std.fmt.bufPrint(&buf, "Rename handler {s} to:", .{word}) catch "Rename handler to:", word, .bind(self, onRenameAnswer));
    }

    /// First Enter: say what would change. Enter again with the same name: do it.
    fn onRenameAnswer(self: *App, answer: []const u8) void {
        const sc = &(self.rename_scan orelse return);
        const h = sc.handlers[self.rename_index];
        const new_name = std.mem.trim(u8, answer, " \t");
        if (new_name.len == 0 or std.mem.eql(u8, new_name, h.name)) return;
        if (!ide.handlers.isIdentifier(new_name)) return self.setStatus("{s} is not a valid name", .{new_name});
        const confirmed = self.rename_pending_len == new_name.len and std.mem.eql(u8, self.rename_pending[0..new_name.len], new_name);
        if (confirmed) {
            self.rename_pending_len = 0;
            self.designer.service.rename(h, new_name) catch |err| return self.setStatus("rename failed: {s}", .{@errorName(err)});
            self.setStatus("renamed {s} to {s}; references and {s} updated", .{ h.name, new_name, ide.handlers.binding_file });
            return;
        }
        var refs: std.ArrayListUnmanaged(ide.handlers.Reference) = .empty;
        defer {
            for (refs.items) |r| {
                self.gpa.free(r.file);
                self.gpa.free(r.text);
            }
            refs.deinit(self.gpa);
        }
        var plan = ide.handlers.planRename(self.gpa, self.project, h, new_name, &refs) catch |err| return self.setStatus("cannot rename: {s}", .{@errorName(err)});
        plan.deinit();
        var files: usize = 0;
        var last: []const u8 = "";
        for (refs.items) |r| {
            if (!std.mem.eql(u8, r.file, last)) files += 1;
            last = r.file;
        }
        if (new_name.len > self.rename_pending.len) return;
        @memcpy(self.rename_pending[0..new_name.len], new_name);
        self.rename_pending_len = new_name.len;
        var buf: [200]u8 = undefined;
        self.prompt.setTitle(std.fmt.bufPrint(&buf, "{s} -> {s}: {d} places in {d} files. Enter again to apply:", .{ h.name, new_name, refs.items.len, files }) catch "Enter again to apply:");
        self.prompt.keepOpen();
    }

    fn poll(self: *App) void {
        self.output.poll();
        if (self.restart_after_build and !self.output.running) {
            self.restart_after_build = false;
            if (self.output.exit_code == 0) self.restartNow() else self.setStatus("build failed: not restarting", .{});
        }
        self.search.poll();
        self.docs.poll();
        self.lsp.poll();
        self.terminal.poll();
        self.designer.poll();
        const doc_msg = self.docs.statusText();
        const msg = if (doc_msg.len > 0) doc_msg else if (self.designer.problemText().len > 0) self.designer.problemText() else self.lsp.statusText();
        if (!std.mem.eql(u8, msg, self.status.props.text.bytes)) self.status.setText(msg) catch {};
    }
};

fn runCommand(app: *App, ui: *Ui, cmd: []const u8) void {
    if (std.mem.startsWith(u8, cmd, "sleep ")) {
        const ms = std.fmt.parseInt(u64, cmd["sleep ".len..], 10) catch 0;
        var ts: std.os.linux.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * 1_000_000) };
        _ = std.os.linux.nanosleep(&ts, null);
        app.poll();
        return;
    }
    const sp = std.mem.indexOfScalar(u8, cmd, ' ') orelse return;
    const verb = cmd[0..sp];
    const rest = cmd[sp + 1 ..];
    if (std.mem.eql(u8, verb, "open")) {
        // path[:line[:col]]
        var path = rest;
        var line: u32 = 0;
        var col: u32 = 1;
        var nums: [2]u32 = undefined;
        var n: usize = 0;
        while (n < 2) {
            const c = std.mem.lastIndexOfScalar(u8, path, ':') orelse break;
            const v = std.fmt.parseInt(u32, path[c + 1 ..], 10) catch break;
            nums[n] = v;
            n += 1;
            path = path[0..c];
        }
        if (n == 1) line = nums[0];
        if (n == 2) {
            line = nums[1];
            col = nums[0];
        }
        app.openAt(path, line, col);
    } else if (std.mem.eql(u8, verb, "cmd")) {
        _ = ui.invokeCommand(rest);
    } else if (std.mem.eql(u8, verb, "ask")) {
        // Answer the prompt bar: type the text and press Enter.
        ui.textInput(rest);
        ui.key(.enter, .{}, true, false);
        ui.key(.enter, .{}, false, false);
    } else if (std.mem.eql(u8, verb, "search")) {
        app.dock.activatePanel(app.search_panel);
        app.search.setQuery(rest);
        app.search.start();
    } else if (std.mem.eql(u8, verb, "type")) {
        ui.textInput(rest);
    } else if (std.mem.eql(u8, verb, "key")) {
        var mods: zigui.keys.Mods = .{};
        var parts = std.mem.splitScalar(u8, rest, '+');
        var last: []const u8 = "";
        while (parts.next()) |p| {
            if (std.mem.eql(u8, p, "ctrl")) {
                mods.ctrl = true;
            } else if (std.mem.eql(u8, p, "shift")) {
                mods.shift = true;
            } else if (std.mem.eql(u8, p, "alt")) {
                mods.alt = true;
            } else last = p;
        }
        const k = zigui.keys.parseKey(last) orelse .unknown;
        ui.key(k, mods, true, false);
        ui.key(k, mods, false, false);
    } else if (std.mem.eql(u8, verb, "wheel")) {
        var nums = std.mem.tokenizeScalar(u8, rest, ' ');
        const x = std.fmt.parseFloat(f32, nums.next() orelse return) catch return;
        const y = std.fmt.parseFloat(f32, nums.next() orelse return) catch return;
        const dy = std.fmt.parseFloat(f32, nums.next() orelse return) catch return;
        ui.pointerMove(x, y);
        ui.wheel(x, y, 0, dy);
    } else if (std.mem.eql(u8, verb, "click") or std.mem.eql(u8, verb, "move")) {
        var nums = std.mem.tokenizeScalar(u8, rest, ' ');
        const x = std.fmt.parseFloat(f32, nums.next() orelse return) catch return;
        const y = std.fmt.parseFloat(f32, nums.next() orelse return) catch return;
        ui.pointerMove(x, y);
        if (verb[0] == 'c') {
            ui.pointerButtonEx(x, y, 1, true, 1);
            ui.pointerButtonEx(x, y, 1, false, 1);
        }
    }
}

const WindowPresenter = struct {
    window: *sdl.Window,

    fn present(ctx: ?*anyopaque, rgba: []const u8, w: u32, h: u32) zigui.render_backend.Error!void {
        const self: *WindowPresenter = @ptrCast(@alignCast(ctx.?));
        self.window.present(rgba, w, h) catch return error.PresentFailed;
    }

    fn presenter(self: *WindowPresenter) zigui.software_backend.Presenter {
        return .{ .ctx = self, .present = present };
    }
};

fn clipGet(_: ?*anyopaque, gpa: std.mem.Allocator) ?[]u8 {
    return sdl.clipboardGet(gpa);
}

fn clipSet(_: ?*anyopaque, text: []const u8) void {
    sdl.clipboardSet(text);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const dir_arg: []const u8 = if (args.len > 1) args[1] else ".";

    const reopen = try ide.relaunch.openFilesFrom(init.arena.allocator(), if (args.len > 2) args[2..] else &.{});
    var project = ide.Project.open(gpa, io, dir_arg) catch |err| {
        std.log.err("could not open project folder {s}: {s}", .{ dir_arg, @errorName(err) });
        return err;
    };
    defer project.close();

    try sdl.init();
    defer sdl.quit();
    var title_buf: [256]u8 = undefined;
    const title: [:0]const u8 = std.fmt.bufPrintSentinel(&title_buf, "zigui ide - {s}", .{project.name}, 0) catch "zigui ide";
    var window = sdl.Window.create(title, 1500, 860) catch |err| {
        std.log.err("could not create window: {s} ({s})", .{ @errorName(err), sdl.lastError() });
        return err;
    };
    defer window.destroy();

    var ui = try Ui.init(gpa);
    ui.clock = sdl.ticksNs;
    ui.wake = sdl.wake;
    defer ui.deinit();

    const ui_bytes = stb.loadFirst(io, gpa, init.environ_map.get("ZIGUI_FONT"), &stb.ui_font_candidates);
    defer if (ui_bytes) |b| gpa.free(b);
    const mono_bytes = stb.loadFirst(io, gpa, init.environ_map.get("ZIGUI_MONO_FONT"), &stb.mono_font_candidates);
    defer if (mono_bytes) |b| gpa.free(b);
    var ui_font: stb.StbFont = undefined;
    var mono_font: stb.StbFont = undefined;
    if (ui_bytes) |bytes| {
        try ui_font.init(bytes, 0);
        _ = try ui.addFont(ui_font.backend());
        if (mono_bytes) |mb| {
            try mono_font.init(mb, 0);
            ui.theme.mono_font = try ui.addFont(mono_font.backend());
        }
    } else {
        std.log.warn("no UI font found (set ZIGUI_FONT=/path/to/font.ttf); text will not be drawn", .{});
    }
    ui.clipboard = .{ .get = clipGet, .set = clipSet };

    const scripted = init.environ_map.get("ZIGUI_SCREENSHOT") != null;
    var app: App = .{ .dry_restart = scripted, .session_enabled = !scripted or init.environ_map.get("ZIGUI_SESSION") != null, .gpa = gpa, .io = io, .ui = &ui, .project = &project, .dock = undefined };
    defer if (app.rename_scan) |*sc| sc.deinit();
    app.environ = init.environ_map;
    app.base_font_size = ui.theme.font_size;
    app.loaded = try ide.settings.load(gpa, io, &project, init.environ_map);
    defer app.loaded.deinit();
    defer gpa.free(app.default_layout);

    ui.tree.get(ui.tree.root).?.style = .{ .direction = .column };
    ui.tree.get(ui.tree.root).?.visual = .{ .background = zigui.Color.rgb(24, 25, 29) };
    
    
    // Add Menu Bar
    const bar = try zigui.MenuBar.create(&ui, ui.tree.root, .{});
    defer bar.destroy();
    
    const dock = try zigui.Dock.create(&ui, ui.tree.root, .{ .style = .{ .grow = 1 } });
    app.dock = dock;
    app.prompt = try ide.prompt.Prompt.create(&ui, ui.tree.root);
    defer app.prompt.destroy();
    app.status = try ui.add(zigui.Label, ui.tree.root, .{ .style = .{ .padding = zigui.style.Edges.xy(8, 3), .shrink = 0 } });

    // Center: a welcome tab that documents open beside.
    const welcome = try dock.addPanel("Welcome");
    app.welcome_panel = welcome;
    ui.tree.get(welcome.content).?.style = .{ .direction = .column, .grow = 1, .padding = zigui.style.Edges.all(16), .gap = zigui.Length.px(8) };
    _ = try ui.add(zigui.Label, welcome.content, .{ .text = project.name, .size = 20 });
    _ = try ui.add(zigui.Label, welcome.content, .{ .text = "Double-click a file to open it; a .ui.zon file opens in the UI designer (File > New UI Document to start one)." });
    for ([_][]const u8{
        "Ctrl+S save   Ctrl+Shift+S save all   Ctrl+W close   Ctrl+F find   Ctrl+H replace   Ctrl+Shift+F find in project",
        "F5 run   Ctrl+B build   Ctrl+Shift+T test   Ctrl+Shift+F5 build and restart   Ctrl+Shift+F6 restart the IDE",
        "F12 go to definition   Ctrl+Space suggestions   Ctrl+` terminal   F2 rename handler",
    }) |line| _ = try ui.add(zigui.Label, welcome.content, .{ .text = line, .font = .mono });
    try dock.dockTab(welcome, null);

    // Suggestions that work with no language server: words in the file, plus
    // Zig names and the standard library read from source (std.zig.Ast).
    const std_dir = ide.zig_complete.locateStdDir(gpa, io);
    defer if (std_dir) |d| gpa.free(d);
    if (std_dir == null) std.log.warn("could not run `zig env`; standard library completion is off", .{});
    const zig_completer = try ide.zig_complete.ZigCompleter.create(gpa, io, std_dir);
    defer zig_completer.destroy();
    const completion = try zigui.completion.Completion.create(&ui);
    defer completion.destroy();
    try completion.addProvider(zig_completer.provider());
    const hover = try zigui.hover.Hover.create(&ui);
    defer hover.destroy();
    try hover.addProvider(zig_completer.hoverProvider());
    const signature = try zigui.hover.SignatureHelp.create(&ui);
    defer signature.destroy();
    try signature.addProvider(zig_completer.signatureProvider());
    // A language server, if one is installed (ZIGUI_ZLS=/path/to/zls, else `zls` on PATH).
    // It adds diagnostics, completions, hover, parameter hints and go to definition
    // to the offline ones; without it everything above still works.
    const lsp = try ide.lsp_assist.Assist.create(&ui, io, project.root);
    defer lsp.destroy();
    app.lsp = lsp;
    lsp.wake = sdl.wake;
    lsp.completion = completion;
    lsp.hover = hover;
    lsp.signature = signature;
    lsp.on_open = ide.output_panel.OpenHook.bind(&app, App.openAt);
    const zls_command = if (app.loaded.settings.language_server.len > 0) app.loaded.settings.language_server else (init.environ_map.get("ZIGUI_ZLS") orelse "zls");
    try lsp.addServer(&zigui.syntax.zig, "zig", &.{zls_command});
    try completion.addProvider(lsp.completionProvider());
    try hover.addProvider(lsp.hoverProvider());
    try signature.addProvider(lsp.signatureProvider());
    app.docs = try ide.Documents.create(&ui, dock, &project, io, .{ .anchor = welcome });
    defer app.docs.destroy();
    app.docs.enableCompletion(completion, zig_completer);
    app.docs.enableHints(hover, signature);

    app.docs.enableLsp(lsp);
    app.docs.on_saved = .{ .ctx = &app, .call = App.savedThunk };
    app.applySettings();
    app.designer = try ide.designer.Designer.create(&ui, dock, app.docs, &project, io, .{ .center = welcome });
    defer app.designer.destroy();

    const files_panel = try dock.addPanel("Files");
    app.files_panel = files_panel;
    app.files = try ide.FilesPanel.create(&ui, files_panel.content, &project, .{ .on_open = ide.files_panel.OpenFileHook.bind(&app, App.openFile) });
    defer app.files.destroy();
    try dock.dockRoot(files_panel, .left, 280);

    const search_panel = try dock.addPanel("Search");
    app.search_panel = search_panel;
    app.search = try ide.SearchPanel.create(&ui, search_panel.content, &project, .{ .on_open = ide.output_panel.OpenHook.bind(&app, App.openAt), .wake = sdl.wake });
    defer app.search.destroy();
    try dock.dockTab(search_panel, files_panel);
    dock.activatePanel(files_panel);

    const output_panel = try dock.addPanel("Output");
    app.output = try ide.OutputPanel.create(&ui, output_panel.content, .{ .style = .{ .grow = 1 }, .on_open = ide.output_panel.OpenHook.bind(&app, App.openAt) });
    defer app.output.destroy();
    app.output_panel = output_panel;
    try dock.dockRoot(output_panel, .bottom, 220);

    // The terminal shares the bottom group with Output.
    const terminal_panel = try dock.addPanel("Terminal");
    app.terminal_panel = terminal_panel;
    app.terminal = try ide.TerminalPanel.create(&ui, terminal_panel.content, .{
        .cwd = project.root,
        .environ = init.environ_map,
        .wake = sdl.wake,
        .argv = if (app.loaded.settings.shell.len > 0) &.{app.loaded.settings.shell} else &.{},
    });
    defer app.terminal.destroy();
    try dock.dockTab(terminal_panel, output_panel);
    dock.activatePanel(output_panel);

    // Commands (menus and shortcuts refer to them by name).
    inline for (.{
        .{ "file.new_ui", "New UI Document..." },
        .{ "file.design", "Design This Document" },
        .{ "file.save", "Save" },
        .{ "file.save_all", "Save All" },
        .{ "file.close", "Close Document" },
        .{ "file.refresh", "Refresh Files" },
        .{ "file.settings", "Settings" },
        .{ "file.keybindings", "Keyboard Shortcuts File" },
        .{ "file.quit", "Quit" },
        .{ "edit.undo", "Undo" },
        .{ "edit.redo", "Redo" },
        .{ "edit.cut", "Cut" },
        .{ "edit.copy", "Copy" },
        .{ "edit.paste", "Paste" },
        .{ "edit.select_all", "Select All" },
        .{ "edit.find", "Find..." },
        .{ "edit.replace", "Replace..." },
        .{ "project.search", "Find in Project..." },
        .{ "editor.definition", "Go to Definition" },
        .{ "refactor.rename_handler", "Rename Event Handler..." },
        .{ "refactor.regenerate", "Regenerate ui_actions.zig" },
        .{ "view.files", "Files" },
        .{ "view.search", "Search" },
        .{ "view.output", "Output" },
        .{ "view.terminal", "Terminal" },
        .{ "view.designer", "UI Designer Panels" },
        .{ "view.welcome", "Welcome and Shortcuts" },
        .{ "view.reset_layout", "Reset Panel Layout" },
        .{ "ide.build", "Build" },
        .{ "ide.run", "Run" },
        .{ "ide.test", "Run Tests" },
        .{ "ide.build_restart", "Build and Restart the IDE" },
        .{ "ide.restart", "Restart the IDE" },
    }) |c| {
        _ = try ui.registerCommand(c[0], .{
            .title = c[1],
            .run = zigui.event.Callback.bind(&app, App.onCommand),
        });
    }

    for (default_bindings) |b| {
        ui.bindShortcut(b[0], b[1], .app, null) catch |err| std.log.warn("cannot bind {s}: {s}", .{ b[0], @errorName(err) });
    }
    app.applyKeymap();

    // The menu bar.
    try bar.addMenu("File", &.{
        .{ .label = "New UI Document...", .command = "file.new_ui" },
        .{ .label = "Design This Document", .command = "file.design" },
        .{ .separator = true },
        .{ .label = "Save", .command = "file.save" },
        .{ .label = "Save All", .command = "file.save_all" },
        .{ .label = "Close Document", .command = "file.close" },
        .{ .separator = true },
        .{ .label = "Refresh Files", .command = "file.refresh" },
        .{ .separator = true },
        .{ .label = "Settings", .command = "file.settings" },
        .{ .label = "Keyboard Shortcuts File", .command = "file.keybindings" },
        .{ .separator = true },
        .{ .label = "Build and Restart the IDE", .command = "ide.build_restart" },
        .{ .label = "Restart the IDE", .command = "ide.restart" },
        .{ .label = "Quit", .command = "file.quit" },
    }, null);
    try bar.addMenu("Edit", &.{
        .{ .label = "Undo", .command = "edit.undo" },
        .{ .label = "Redo", .command = "edit.redo" },
        .{ .separator = true },
        .{ .label = "Cut", .command = "edit.cut" },
        .{ .label = "Copy", .command = "edit.copy" },
        .{ .label = "Paste", .command = "edit.paste" },
        .{ .label = "Select All", .command = "edit.select_all" },
        .{ .separator = true },
        .{ .label = "Find...", .command = "edit.find" },
        .{ .label = "Replace...", .command = "edit.replace" },
        .{ .label = "Find in Project...", .command = "project.search" },
        .{ .separator = true },
        .{ .label = "Go to Definition", .command = "editor.definition" },
    }, null);
    try bar.addMenu("Refactor", &.{
        .{ .label = "Rename Event Handler...", .command = "refactor.rename_handler" },
        .{ .label = "Regenerate ui_actions.zig", .command = "refactor.regenerate" },
    }, null);
    try bar.addMenu("View", &.{
        .{ .label = "Files", .command = "view.files" },
        .{ .label = "Search", .command = "view.search" },
        .{ .label = "Output", .command = "view.output" },
        .{ .label = "Terminal", .command = "view.terminal" },
        .{ .separator = true },
        .{ .label = "UI Designer Panels", .command = "view.designer" },
        .{ .separator = true },
        .{ .label = "Welcome and Shortcuts", .command = "view.welcome" },
        .{ .separator = true },
        .{ .label = "Reset Panel Layout", .command = "view.reset_layout" },
    }, null);
    try bar.addMenu("Build", &.{
        .{ .label = "Build", .command = "ide.build" },
        .{ .label = "Run", .command = "ide.run" },
        .{ .label = "Run Tests", .command = "ide.test" },
        .{ .separator = true },
        .{ .label = "Build and Restart the IDE", .command = "ide.build_restart" },
    }, null);

    app.default_layout = try dock.saveLayout(gpa);
    var restored = false;
    if (app.session_enabled and app.loaded.settings.restore_session and reopen.len == 0) {
        if (ide.session.load(gpa, &project)) |loaded_session| {
            var sess = loaded_session;
            defer sess.deinit();
            sess.restore(app.docs, dock, app.designer);
            restored = true;
        }
    }
    if (!restored) {
        for (reopen) |rel| _ = app.docs.open(rel, 0, 0) catch {};
    }

    const commands = try gpa.alloc(zigui.draw_list.Command, 32768);
    defer gpa.free(commands);
    const glyphs = try gpa.alloc(zigui.draw_list.Glyph, 65536);
    defer gpa.free(glyphs);
    var list = zigui.DrawList.init(commands, glyphs);
    var prewarmed_scale: f32 = 0;
    var presenter: WindowPresenter = .{ .window = &window };
    var renderer = try zigui.software_backend.SoftwareBackend.init(gpa, presenter.presenter());
    defer renderer.deinit();
    const backend = renderer.backend();

    var force = true;
    var last_frame_ms: u64 = 0;
    const screenshot = init.environ_map.get("ZIGUI_SCREENSHOT");
    var script = std.mem.tokenizeScalar(u8, init.environ_map.get("ZIGUI_SCRIPT") orelse "", ';');
    var text_input_on = false;
    var running = true;
    defer app.saveSession();
    while (running and !app.quit) {
        _ = ui.tick(sdl.ticks());
        app.poll();
        ui.update();
        if (force or ui.isDirty()) {
            const px = window.pixelSize();
            const scale = window.scale();
            if (scale != prewarmed_scale) {
                prewarmed_scale = scale;
                for (0..ui.text.fonts.items.len) |f| {
                    ui.text.prewarmAscii(@intCast(f), ui.theme.font_size * scale);
                    ui.text.prewarmAscii(@intCast(f), 15 * scale);
                }
            }
            try ui.renderFrame(backend, &list, .{ .pixel_w = px.w, .pixel_h = px.h, .scale = scale, .clear = zigui.Color.black });
            force = false;
            last_frame_ms = sdl.ticks();
        }
        ui.endFrame();

        if (screenshot != null) {
            if (script.next()) |cmd| {
                runCommand(&app, &ui, cmd);
                continue;
            }
            const img = try backend.readback(gpa);
            defer img.deinit(gpa);
            const png = try zigui.png.encodeRgba(gpa, img.rgba, img.width, img.height);
            defer gpa.free(png);
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = screenshot.?, .data = png });
            std.log.info("wrote {s}: {d}x{d}", .{ screenshot.?, img.width, img.height });
            return;
        }

        if (ui.textInputRect()) |r| {
            if (!text_input_on) sdl.startTextInput(&window);
            text_input_on = true;
            sdl.setTextInputArea(&window, r.x, r.y, r.w, r.h);
        } else if (text_input_on) {
            sdl.stopTextInput(&window);
            text_input_on = false;
        }

        sdl.setUiCursor(ui.cursor());
        const timeout: i32 = if (ui.nextWakeMs()) |ms| @intCast(ms) else -1;
        var ev = sdl.waitEvent(timeout);
        _ = ui.tick(sdl.ticks());
        while (ev) |e| : (ev = sdl.pollEvent()) {
            switch (e.data) {
                .quit, .close_requested => running = false,
                .resized => force = true,
                .expose => if (sdl.ticks() -% last_frame_ms > 100) {
                    force = true;
                },
                .mouse_move => |m| ui.pointerMove(m.x, m.y),
                .mouse_button => |m| ui.pointerButtonEx(m.x, m.y, @backingInt(m.button), m.down, m.clicks),
                .mouse_wheel => |m| ui.wheel(m.px, m.py, m.x, m.y),
                .pointer_left => ui.pointerLeft(),
                .focus_lost => ui.pointerCancel(),
                .text_input => |t| ui.textInput(t.bytes[0..t.len]),
                .text_editing => |t| ui.textEditing(t.bytes[0..t.len], t.cursor),
                .key => |k| {
                    const used = ui.keyHandled(k.key, k.mods, k.down, k.repeat);
                    if (k.down and k.key == .escape and !used) {
                        if (ui.focused() != null) ui.setFocus(null) else running = false;
                    }
                },
            }
        }
    }
}
