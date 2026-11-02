//! Go to anything (Ctrl+,): a quick-pick box over every file and declaration in
//! the project and in the Zig standard library. Typing ranks the matches; Enter
//! opens the file (or the declaration's line). Standard library results open
//! read-only.
//!
//!     const qo = try QuickOpen.create(&ui, ui.tree.root, &project, std_dir, .{ .on_open = OpenHook.bind(&app, App.openAt), .wake = sdl.wake });
//!     defer qo.destroy();
//!     qo.show();                // the command
//!     qo.poll();                // each loop iteration: take finished scans
//!
//! The project is scanned again each time the box opens (so new and saved files
//! show up); the library once, in the background, when `QuickOpen` is created.
//! IDE-level code: it builds on `SymbolIndex` and `widgets.quick_pick`.

const std = @import("std");
const Handle = @import("../core/handle.zig").Handle;
const Ui = @import("../core/ui.zig").Ui;
const quick_pick = @import("../widgets/quick_pick.zig");
const output_panel = @import("output_panel.zig");
const project_mod = @import("project.zig");
const symbol_index = @import("symbol_index.zig");

pub const OpenHook = output_panel.OpenHook;

pub const Options = struct {
    on_open: ?OpenHook = null,
    wake: ?*const fn () void = null,
};

pub const QuickOpen = struct {
    gpa: std.mem.Allocator,
    pick: *quick_pick.QuickPick,
    project_index: *symbol_index.SymbolIndex,
    lib_index: ?*symbol_index.SymbolIndex,
    on_open: ?OpenHook,
    /// The rows shown: project symbols, then library ones; strings live in `arena`.
    items: std.ArrayListUnmanaged(quick_pick.Item) = .empty,
    syms: std.ArrayListUnmanaged(symbol_index.Symbol) = .empty,
    arena: std.heap.ArenaAllocator,

    pub fn create(ui: *Ui, parent: Handle, project: *const project_mod.Project, std_dir: ?[]const u8, opts: Options) !*QuickOpen {
        const self = try ui.gpa.create(QuickOpen);
        errdefer ui.gpa.destroy(self);
        const pick = try quick_pick.QuickPick.create(ui, parent);
        errdefer pick.destroy();
        const pidx = try symbol_index.SymbolIndex.start(ui.gpa, project, null, opts.wake);
        errdefer pidx.destroy();
        const lidx: ?*symbol_index.SymbolIndex = if (std_dir) |d| try symbol_index.SymbolIndex.startLibrary(ui.gpa, project, d, opts.wake) else null;
        self.* = .{ .gpa = ui.gpa, .pick = pick, .project_index = pidx, .lib_index = lidx, .on_open = opts.on_open, .arena = .init(ui.gpa) };
        return self;
    }

    pub fn destroy(self: *QuickOpen) void {
        self.pick.destroy();
        self.project_index.destroy();
        if (self.lib_index) |l| l.destroy();
        self.items.deinit(self.gpa);
        self.syms.deinit(self.gpa);
        self.arena.deinit();
        self.gpa.destroy(self);
    }

    pub fn isOpen(self: *const QuickOpen) bool {
        return self.pick.isOpen();
    }

    pub fn show(self: *QuickOpen) void {
        self.project_index.rescan();
        self.rebuild();
        self.pick.show(.{
            .placeholder = "Go to file, function or type",
            .items = self.items.items,
            .on_pick = .bind(self, onPick),
        });
        self.updateStatus();
    }

    /// Call every loop iteration: take finished scans and refresh the open box.
    pub fn poll(self: *QuickOpen) void {
        var changed = self.project_index.poll();
        if (self.lib_index) |l| {
            if (l.poll()) changed = true;
        }
        if (!changed) return;
        self.rebuild();
        if (self.pick.isOpen()) {
            self.pick.setItems(self.items.items);
            self.updateStatus();
        }
    }

    fn updateStatus(self: *QuickOpen) void {
        const lib_busy = if (self.lib_index) |l| l.running() else false;
        if (lib_busy) {
            self.pick.setStatus("indexing the standard library...");
        } else if (self.project_index.running()) {
            self.pick.setStatus("scanning the project...");
        } else {
            var buf: [64]u8 = undefined;
            self.pick.setStatus(std.fmt.bufPrint(&buf, "{d} names", .{self.items.items.len}) catch "");
        }
    }

    fn kindText(k: symbol_index.Kind) []const u8 {
        return switch (k) {
            .file => "file",
            .function => "fn",
            .type => "type",
            .constant => "const",
            .variable => "var",
        };
    }

    fn rebuild(self: *QuickOpen) void {
        _ = self.arena.reset(.retain_capacity);
        self.items.clearRetainingCapacity();
        self.syms.clearRetainingCapacity();
        const a = self.arena.allocator();
        const lists = [2][]const symbol_index.Symbol{
            self.project_index.symbols(),
            if (self.lib_index) |l| l.symbols() else &.{},
        };
        for (lists) |list| {
            for (list) |s| {
                const detail = if (s.kind == .file)
                    s.shown
                else
                    std.fmt.allocPrint(a, "{s}  {s}:{d}", .{ kindText(s.kind), s.shown, s.line }) catch continue;
                self.items.append(self.gpa, .{ .label = s.name, .detail = detail, .group = if (s.in_std) 1 else 0 }) catch return;
                self.syms.append(self.gpa, s) catch {
                    _ = self.items.pop();
                    return;
                };
            }
        }
    }

    fn onPick(self: *QuickOpen, index: usize) void {
        if (index >= self.syms.items.len) return;
        const s = self.syms.items[index];
        const hook = self.on_open orelse return;
        hook.call(hook.ctx, s.path, s.line, s.col);
    }
};

