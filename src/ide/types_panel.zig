//! The Types panel: the struct, union, enum and opaque types the compiler creates while it
//! evaluates your comptime code, as they appear ("watch types be built"). It is fed by zigct's
//! `zigct/typeEvent` events (`Session.on_custom`) and asks `zigct/typeInfo` for the fields of the
//! type you select (the compiler answers while it is stopped).
//!
//!     const tp = try TypesPanel.create(&ui, parent, debugger, .{ .on_open = OpenHook.bind(&app, App.openAt) });
//!     defer tp.destroy();
//!     debugger.session.on_custom = CustomHook.bind(tp, TypesPanel.onCustom);
//!     tp.clear();                                  // before a new comptime session
//!
//! Each type shows how far it is: *declared* (the type exists), *layout resolved* (fields and
//! size are known: now its fields can be listed) and *fully resolved* (default values too).
//! Newest first; the filter matches the name or the kind. Double-click opens the declaration.

const std = @import("std");
const Handle = @import("../core/handle.zig").Handle;
const Ui = @import("../core/ui.zig").Ui;
const event = @import("../core/event.zig");
const Style = @import("../core/style.zig").Style;
const Edges = @import("../core/style.zig").Edges;
const Length = @import("../core/length.zig").Length;
const tree_view = @import("../widgets/tree_view.zig");
const TreeView = tree_view.TreeView;
const Label = @import("../widgets/label.zig").Label;
const TextField = @import("../widgets/text_field.zig").TextField;
const output_panel = @import("output_panel.zig");
const debugger_mod = @import("debugger.zig");
const client_mod = @import("dap/client.zig");
const session_mod = @import("dap/session.zig");

pub const OpenHook = output_panel.OpenHook;

pub const Options = struct {
    style: Style = .{},
    on_open: ?OpenHook = null,
};

pub const Phase = enum {
    declared,
    layout,
    defaults,

    fn text(self: Phase) []const u8 {
        return switch (self) {
            .declared => "declared",
            .layout => "layout resolved",
            .defaults => "fully resolved",
        };
    }
};

pub const Entry = struct {
    id: i64,
    name: []u8,
    kind: []u8,
    phase: Phase,
    /// -1 until the layout is resolved.
    fields: i64,
    file: []u8,
    line: u32,
    requested_by: []u8,
};

pub const TypesPanel = struct {
    gpa: std.mem.Allocator,
    ui: *Ui,
    node: Handle,
    debugger: *debugger_mod.Debugger,
    on_open: ?OpenHook,
    filter: *TextField,
    list: *TreeView,
    detail: *TreeView,
    status: *Label,
    /// In order of first appearance (shown newest first).
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    /// The type whose fields `detail` shows (or is waiting for), by id; -1 for none.
    asked: i64 = -1,

    pub fn create(ui: *Ui, parent: Handle, debugger: *debugger_mod.Debugger, opts: Options) !*TypesPanel {
        const self = try ui.gpa.create(TypesPanel);
        errdefer ui.gpa.destroy(self);
        var style = opts.style;
        style.direction = .column;
        if (std.meta.eql(style.padding, .{})) style.padding = Edges.all(6);
        style.gap = Length.px(4);
        if (style.grow == 0) style.grow = 1;
        const node = try ui.tree.create(.{ .style = style, .role = .panel });
        errdefer _ = ui.tree.destroySubtree(node);
        try ui.tree.appendChild(parent, node);
        try ui.tree.setLabel(node, "Types");
        const top = try ui.tree.create(.{ .style = .{ .direction = .row, .gap = Length.px(6), .align_items = .center, .shrink = 0 } });
        try ui.tree.appendChild(node, top);
        const filter = try ui.add(TextField, top, .{ .placeholder = "Filter by name or kind", .label = "Filter types", .style = .{ .grow = 1 }, .on_change = .bind(self, onFilter) });
        const status = try ui.add(Label, top, .{ .text = "Types appear here while a comptime session runs.", .style = .{ .shrink = 0 } });
        const split = try ui.tree.create(.{ .style = .{ .direction = .row, .gap = Length.px(6), .grow = 1 } });
        try ui.tree.appendChild(node, split);
        const left = try ui.tree.create(.{ .style = .{ .direction = .column, .gap = Length.px(2), .grow = 3, .min_width = Length.px(240) } });
        try ui.tree.appendChild(split, left);
        const list = try ui.add(TreeView, left, .{ .style = .{ .grow = 1 }, .label = "Types", .activate_toggles = false, .on_select = .bind(self, onSelect), .on_activate = .bind(self, onOpen) });
        const right = try ui.tree.create(.{ .style = .{ .direction = .column, .gap = Length.px(2), .grow = 2, .min_width = Length.px(200) } });
        try ui.tree.appendChild(split, right);
        _ = try ui.add(Label, right, .{ .text = "Fields", .style = .{ .shrink = 0 } });
        const detail = try ui.add(TreeView, right, .{ .style = .{ .grow = 1 }, .label = "Type fields", .activate_toggles = false });
        self.* = .{ .gpa = ui.gpa, .ui = ui, .node = node, .debugger = debugger, .on_open = opts.on_open, .filter = filter, .list = list, .detail = detail, .status = status };
        return self;
    }

    pub fn destroy(self: *TypesPanel) void {
        self.freeEntries();
        self.entries.deinit(self.gpa);
        _ = self.ui.tree.destroySubtree(self.node);
        self.gpa.destroy(self);
    }

    fn freeEntry(self: *TypesPanel, e: Entry) void {
        self.gpa.free(e.name);
        self.gpa.free(e.kind);
        self.gpa.free(e.file);
        self.gpa.free(e.requested_by);
    }

    fn freeEntries(self: *TypesPanel) void {
        for (self.entries.items) |e| self.freeEntry(e);
        self.entries.clearRetainingCapacity();
    }

    /// Forget everything (a new session starts).
    pub fn clear(self: *TypesPanel) void {
        self.freeEntries();
        self.asked = -1;
        self.detail.clear();
        self.rebuild();
    }

    /// `Session.on_custom`: zigct's `zigct/typeEvent`.
    pub fn onCustom(self: *TypesPanel, name: []const u8, body: std.json.Value) void {
        if (!std.mem.eql(u8, name, "zigct/typeEvent") or body != .object) return;
        const o = body.object;
        const id = client_mod.intOf(o.get("id")) orelse return;
        const phase_name = client_mod.strOf(o.get("phase")) orelse "declared";
        const phase = std.meta.stringToEnum(Phase, phase_name) orelse .declared;
        const fields = client_mod.intOf(o.get("fieldCount")) orelse -1;
        for (self.entries.items) |*e| {
            if (e.id != id) continue;
            if (@intFromEnum(phase) > @intFromEnum(e.phase)) e.phase = phase;
            if (fields >= 0) e.fields = fields;
            self.rebuild();
            return;
        }
        const entry: Entry = .{
            .id = id,
            .name = self.gpa.dupe(u8, client_mod.strOf(o.get("name")) orelse "?") catch return,
            .kind = self.gpa.dupe(u8, client_mod.strOf(o.get("kind")) orelse "") catch return,
            .phase = phase,
            .fields = fields,
            .file = self.gpa.dupe(u8, client_mod.strOf(o.get("file")) orelse "") catch return,
            .line = @intCast(@max(client_mod.intOf(o.get("line")) orelse 0, 0)),
            .requested_by = self.gpa.dupe(u8, client_mod.strOf(o.get("requestedBy")) orelse "") catch return,
        };
        self.entries.append(self.gpa, entry) catch {
            self.freeEntry(entry);
            return;
        };
        self.rebuild();
    }

    fn matches(e: Entry, needle: []const u8) bool {
        if (needle.len == 0) return true;
        return std.ascii.findIgnoreCase(e.name, needle) != null or std.ascii.findIgnoreCase(e.kind, needle) != null;
    }

    fn rebuild(self: *TypesPanel) void {
        const needle = self.filter.text();
        const keep = self.asked;
        self.list.clear();
        var shown: usize = 0;
        var i = self.entries.items.len;
        while (i > 0) {
            i -= 1;
            const e = self.entries.items[i];
            if (!matches(e, needle)) continue;
            var buf: [600]u8 = undefined;
            var fbuf: [24]u8 = undefined;
            const fields: []const u8 = if (e.fields >= 0) (std.fmt.bufPrint(&fbuf, ", {d} fields", .{e.fields}) catch "") else "";
            const text = std.fmt.bufPrint(&buf, "{s}   {s} - {s}{s}", .{ e.name, e.kind, e.phase.text(), fields }) catch e.name;
            const id = self.list.addItem(tree_view.no_item, text) catch return;
            self.list.setUserData(id, i);
            if (e.id == keep) self.list.select(id);
            shown += 1;
        }
        var sb: [80]u8 = undefined;
        self.status.setText(std.fmt.bufPrint(&sb, "{d} of {d} types", .{ shown, self.entries.items.len }) catch "") catch {};
    }

    fn onFilter(self: *TypesPanel, _: *event.Event) void {
        self.rebuild();
    }

    fn selectedEntry(self: *TypesPanel) ?Entry {
        const id = self.list.selected();
        if (id == tree_view.no_item or !self.list.exists(id)) return null;
        const i: usize = @intCast(self.list.userData(id));
        if (i >= self.entries.items.len) return null;
        return self.entries.items[i];
    }

    fn onSelect(self: *TypesPanel, _: *event.Event) void {
        const e = self.selectedEntry() orelse return;
        if (e.id == self.asked) return;
        self.asked = e.id;
        self.detail.clear();
        const s = self.debugger.session;
        if (s.state != .stopped) {
            _ = self.detail.addItem(tree_view.no_item, "(stop the session to look at the fields)") catch {};
            return;
        }
        if (e.phase == .declared) {
            _ = self.detail.addItem(tree_view.no_item, "(the fields are known once the layout is resolved)") catch {};
            return;
        }
        _ = s.customRequest("zigct/typeInfo", .{ .id = e.id }, client_mod.ResponseHook.bind(self, onTypeInfo)) catch {};
    }

    fn onTypeInfo(self: *TypesPanel, res: *const client_mod.Response) void {
        self.detail.clear();
        if (!res.ok or res.body != .object) {
            _ = self.detail.addItem(tree_view.no_item, if (res.message.len > 0) res.message else "(no information)") catch {};
            return;
        }
        const o = res.body.object;
        if (client_mod.intOf(o.get("id")) != self.asked) return;
        var buf: [300]u8 = undefined;
        const size = client_mod.intOf(o.get("size")) orelse -1;
        const al = client_mod.intOf(o.get("alignment")) orelse -1;
        if (size >= 0) {
            const t = std.fmt.bufPrint(&buf, "size {d}, alignment {d}", .{ size, al }) catch "";
            _ = self.detail.addItem(tree_view.no_item, t) catch {};
        }
        for (client_mod.arrayOf(o.get("fields"))) |f| {
            const name = client_mod.strOf(if (f == .object) f.object.get("name") else null) orelse "?";
            const ty = client_mod.strOf(if (f == .object) f.object.get("type") else null) orelse "";
            const t = if (ty.len > 0) (std.fmt.bufPrint(&buf, "{s}: {s}", .{ name, ty }) catch name) else name;
            _ = self.detail.addItem(tree_view.no_item, t) catch {};
        }
    }

    fn onOpen(self: *TypesPanel, _: *event.Event) void {
        const id = self.list.out.activated_item;
        if (id == tree_view.no_item or !self.list.exists(id)) return;
        const i: usize = @intCast(self.list.userData(id));
        if (i >= self.entries.items.len) return;
        const e = self.entries.items[i];
        if (e.file.len == 0 or e.line == 0) return;
        if (self.on_open) |h| h.call(h.ctx, e.file, e.line, 1);
    }

    /// After the session moved on: a selected type's fields may be askable now.
    pub fn refresh(self: *TypesPanel) void {
        self.asked = -1;
        self.onSelect(undefined);
    }
};

const testing = std.testing;
const Rig = @import("../core/test_rig.zig").Rig;

test "type events fill the table newest first; a later phase updates the row; the filter narrows it" {
    const r = try Rig.init();
    defer r.deinit();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var p = try @import("project.zig").testProject(&tmp);
    defer p.close();
    const d = try debugger_mod.Debugger.create(testing.allocator, testing.io, &p, null, .{});
    defer d.destroy();
    const tp = try TypesPanel.create(&r.ui, r.ui.tree.root, d, .{});
    defer tp.destroy();

    const ev = struct {
        fn send(panel: *TypesPanel, id: i64, name: []const u8, kind: []const u8, phase: []const u8, fields: i64) !void {
            const text = try std.fmt.allocPrint(testing.allocator, "{{\"id\":{d},\"name\":\"{s}\",\"kind\":\"{s}\",\"phase\":\"{s}\",\"fieldCount\":{d},\"file\":\"\",\"line\":0,\"requestedBy\":\"\"}}", .{ id, name, kind, phase, fields });
            defer testing.allocator.free(text);
            var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, text, .{});
            defer parsed.deinit();
            panel.onCustom("zigct/typeEvent", parsed.value);
        }
    };
    try ev.send(tp, 10, "gen.Color", "enum", "declared", -1);
    try ev.send(tp, 11, "gen.Pair(u32,gen.Color)", "struct", "declared", -1);
    try testing.expectEqual(@as(usize, 2), tp.list.childCount(tree_view.no_item));
    // Newest first.
    try testing.expect(std.mem.startsWith(u8, tp.list.itemText(tp.list.childAt(tree_view.no_item, 0)), "gen.Pair"));
    try ev.send(tp, 11, "gen.Pair(u32,gen.Color)", "struct", "layout", 2);
    try testing.expect(std.mem.indexOf(u8, tp.list.itemText(tp.list.childAt(tree_view.no_item, 0)), "layout resolved, 2 fields") != null);
    try testing.expectEqual(@as(usize, 2), tp.entries.items.len);
    try tp.filter.setText("enum");
    tp.rebuild();
    try testing.expectEqual(@as(usize, 1), tp.list.childCount(tree_view.no_item));
}
