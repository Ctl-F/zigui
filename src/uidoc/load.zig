//! Turn a UI document into live widgets (design doc section 13).
//!
//! `instantiate` walks the document and, for each node, creates a plain container
//! (`"box"`) or the registered widget of that name, applies its `style` and
//! `props` through the runtime schema, binds `on` events to named actions, and
//! records `id`s. Everything the document says is checked against the schema: an
//! unknown prop, a wrong value type, or an enum name that does not exist is a
//! `Problem` (with the node and a path like `props.colors.text`), not a crash.
//!
//! Actions are the app's named callbacks:
//!
//!     var actions: load.Actions = .{};
//!     try actions.put(gpa, "confirm", Callback.bind(&app, App.onConfirm));
//!     var inst = try load.instantiate(&ui, ui.tree.root, &doc, .{ .actions = &actions });
//!
//! With `strict` (the default) a missing action is a problem; the builder turns
//! it off so unfinished documents still preview.

const std = @import("std");
const Allocator = std.mem.Allocator;
const schema = @import("../core/schema.zig");
const ui_mod = @import("../core/ui.zig");
const Ui = ui_mod.Ui;
const event = @import("../core/event.zig");
const Handle = @import("../core/handle.zig").Handle;
const DirtyFlags = @import("../core/dirty.zig").DirtyFlags;
const registry = @import("../widgets/registry.zig");
const form = @import("../forms/form.zig");
const doc_mod = @import("doc.zig");
const zon = @import("zon.zig");

/// Named callbacks that documents bind events to. Names are borrowed.
pub const Actions = struct {
    map: std.StringHashMapUnmanaged(event.Callback) = .empty,

    pub fn put(self: *Actions, gpa: Allocator, name: []const u8, cb: event.Callback) !void {
        try self.map.put(gpa, name, cb);
    }

    pub fn deinit(self: *Actions, gpa: Allocator) void {
        self.map.deinit(gpa);
    }
};

pub const Options = struct {
    actions: ?*const Actions = null,
    /// Unknown actions are problems (otherwise they are ignored).
    strict: bool = true,
};

pub const Problem = struct {
    /// The document node it concerns.
    uid: u32,
    /// Includes the path, for example `props.variant: unknown value 'huge'`.
    message: []const u8,
};

pub const Instance = struct {
    ui: *Ui,
    gpa: Allocator,
    root: Handle,
    arena: std.heap.ArenaAllocator,
    ids: std.StringHashMapUnmanaged(Handle) = .empty,
    by_uid: std.AutoHashMapUnmanaged(u32, Handle) = .empty,
    problems: std.ArrayListUnmanaged(Problem) = .empty,

    pub fn deinit(self: *Instance) void {
        self.ids.deinit(self.gpa);
        self.by_uid.deinit(self.gpa);
        self.problems.deinit(self.gpa);
        self.arena.deinit();
    }

    /// Remove the widgets this instance created, then free it.
    pub fn destroy(self: *Instance) void {
        _ = self.ui.tree.destroySubtree(self.root);
        self.deinit();
    }

    /// The node with document `id`.
    pub fn find(self: *const Instance, id: []const u8) ?Handle {
        return self.ids.get(id);
    }

    /// The widget of type `W` with document `id`, if it is one.
    pub fn widget(self: *const Instance, comptime W: type, id: []const u8) ?*W {
        const h = self.find(id) orelse return null;
        const n = self.ui.tree.get(h) orelse return null;
        if (n.widget_type != ui_mod.typeTag(W)) return null;
        return @ptrCast(@alignCast(n.widget.?));
    }

    /// The live node made from document node `uid`.
    pub fn handleOf(self: *const Instance, uid: u32) ?Handle {
        return self.by_uid.get(uid);
    }
};

const Ctx = struct {
    inst: *Instance,
    opts: Options,
    uid: u32 = 0,

    fn arena(self: *Ctx) Allocator {
        return self.inst.arena.allocator();
    }

    fn problem(self: *Ctx, comptime fmt: []const u8, args: anytype) !void {
        const msg = try std.fmt.allocPrint(self.arena(), fmt, args);
        try self.inst.problems.append(self.inst.gpa, .{ .uid = self.uid, .message = msg });
    }
};

fn replaceText(ctx: ?*anyopaque, t: *anyopaque, bytes: []const u8) error{OutOfMemory}!void {
    const ui: *Ui = @ptrCast(@alignCast(ctx.?));
    try ui.replaceText(@ptrCast(@alignCast(t)), bytes);
}

/// Create the widgets for `doc` under `parent`. The result's `problems` lists
/// anything in the document that could not be honored; the rest is built.
pub fn instantiate(ui: *Ui, parent: Handle, doc: *const doc_mod.Doc, opts: Options) !Instance {
    var inst: Instance = .{
        .ui = ui,
        .gpa = ui.gpa,
        .root = Handle.invalid,
        .arena = std.heap.ArenaAllocator.init(ui.gpa),
    };
    errdefer inst.deinit();
    var ctx: Ctx = .{ .inst = &inst, .opts = opts };
    inst.root = try buildNode(&ctx, parent, doc.root);
    return inst;
}

/// Parse ZON text into a document and instantiate it. In strict mode a document
/// with problems is torn down again and reported as `error.InvalidDocument`.
pub fn instantiateStrict(ui: *Ui, parent: Handle, doc: *const doc_mod.Doc, opts: Options) !Instance {
    var inst = try instantiate(ui, parent, doc, opts);
    if (inst.problems.items.len > 0) {
        inst.destroy();
        return error.InvalidDocument;
    }
    return inst;
}

fn buildNode(c: *Ctx, parent: Handle, n: *const doc_mod.Node) anyerror!Handle {
    const ui = c.inst.ui;
    c.uid = n.uid;
    var info: ?*const registry.Info = null;
    const h: Handle = blk: {
        if (std.mem.eql(u8, n.type_name, doc_mod.box_type)) {
            const created = try ui.tree.create(.{});
            errdefer _ = ui.tree.destroySubtree(created);
            try ui.tree.appendChild(parent, created);
            break :blk created;
        }
        info = registry.find(n.type_name);
        if (info) |i| break :blk try i.create(ui, parent);
        try c.problem("unknown widget type '{s}'", .{n.type_name});
        // Keep the tree's shape: an unknown widget becomes an empty container.
        const created = try ui.tree.create(.{});
        errdefer _ = ui.tree.destroySubtree(created);
        try ui.tree.appendChild(parent, created);
        break :blk created;
    };
    errdefer _ = ui.tree.destroySubtree(h);
    const node = ui.tree.get(h).?;
    try c.inst.by_uid.put(c.inst.gpa, n.uid, h);

    const env: schema.Env = .{ .ctx = ui, .replace_text = replaceText };
    try applyValue(c, &env, registry.styleSchema(), &node.style, n.style, "style");
    if (info) |i| {
        const w = node.widget.?;
        var props = n.props;
        if (i.set_text) |set_text| {
            if (n.props.field("text")) |t| {
                if (t == .string) {
                    try set_text(w, t.string);
                } else try c.problem("props.text: expected a string", .{});
                props = try zon.withoutField(c.arena(), n.props, "text");
            }
        }
        try applyValue(c, &env, i.props, i.propsPtr(w), props, "props");
        for (n.on) |b| try bindEvent(c, i, w, b);
    } else {
        if (!isEmptyRecord(n.props) and std.mem.eql(u8, n.type_name, doc_mod.box_type)) {
            try c.problem("props: a box has no props", .{});
        }
        if (n.on.len > 0 and std.mem.eql(u8, n.type_name, doc_mod.box_type)) {
            try c.problem("on: a box has no events", .{});
        }
    }
    ui.tree.markDirty(h, DirtyFlags.layout_and_paint);

    if (n.id.len > 0) {
        if (c.inst.ids.contains(n.id)) {
            try c.problem("id '{s}' is used more than once", .{n.id});
        } else {
            try c.inst.ids.put(c.inst.gpa, try c.arena().dupe(u8, n.id), h);
        }
    }
    var child_parent = h;
    if (info) |i| {
        if (i.content) |content| child_parent = content(node.widget.?);
    }
    for (n.children.items) |child| _ = try buildNode(c, child_parent, child);
    return h;
}

fn isEmptyRecord(v: zon.Value) bool {
    const fs = v.fields() orelse return true;
    return fs.len == 0;
}

fn bindEvent(c: *Ctx, info: *const registry.Info, w: *anyopaque, b: doc_mod.EventBinding) !void {
    c.uid = c.uid; // the node's uid is still current
    var known = false;
    for (info.events) |e| known = known or std.mem.eql(u8, e, b.event);
    if (!known) {
        try c.problem("on.{s}: {s} has no such event", .{ b.event, info.name });
        return;
    }
    const cb = if (c.opts.actions) |a| a.map.get(b.action) else null;
    if (cb) |callback| {
        _ = info.setEvent(w, b.event, callback);
    } else if (c.opts.strict) {
        try c.problem("on.{s}: unknown action '{s}'", .{ b.event, b.action });
    }
}

// ---- applying ZON values through the schema ---------------------------------

fn applyValue(c: *Ctx, env: *const schema.Env, ty: *const schema.Type, ptr: *anyopaque, v: zon.Value, path: []const u8) anyerror!void {
    switch (ty.kind) {
        .@"struct" => {
            const fs = v.fields() orelse {
                try c.problem("{s}: expected a record", .{path});
                return;
            };
            for (fs) |f| {
                const field = ty.field(f.name) orelse {
                    try c.problem("{s}: unknown field '{s}'", .{ path, f.name });
                    continue;
                };
                const sub = try std.fmt.allocPrint(c.arena(), "{s}.{s}", .{ path, f.name });
                if (field.type.kind == .callback) {
                    try c.problem("{s}: events are bound under .on", .{sub});
                    continue;
                }
                if (!field.type.isEditable() or field.meta.readonly) {
                    try c.problem("{s}: cannot be set from a document", .{sub});
                    continue;
                }
                try applyValue(c, env, field.type, @ptrFromInt(@intFromPtr(ptr) + field.offset), f.value, sub);
            }
        },
        .array => {
            const items = v.items() orelse {
                try c.problem("{s}: expected a list of {d}", .{ path, ty.len });
                return;
            };
            if (items.len != ty.len) {
                try c.problem("{s}: expected {d} items, found {d}", .{ path, ty.len, items.len });
                return;
            }
            for (items, 0..) |item, i| {
                const sub = try std.fmt.allocPrint(c.arena(), "{s}[{d}]", .{ path, i });
                try applyValue(c, env, ty.child.?, @ptrFromInt(@intFromPtr(ptr) + i * ty.elem_size), item, sub);
            }
        },
        .optional => {
            if (v == .none) {
                ty.set_absent.?(ptr);
                return;
            }
            if (ty.payload.?(ptr) == null) ty.set_present_from.?(ptr, ty.payload_default.?);
            try applyValue(c, env, ty.child.?, ty.payload.?(ptr).?, v, path);
        },
        .callback, .unsupported => try c.problem("{s}: cannot be set from a document", .{path}),
        else => {
            var why: []const u8 = "";
            const value = try convert(c, ty, v, &why) orelse {
                try c.problem("{s}: {s}", .{ path, why });
                return;
            };
            ty.set.?(ptr, value, env) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.OutOfRange => try c.problem("{s}: out of range", .{path}),
                else => try c.problem("{s}: cannot set ({s})", .{ path, @errorName(err) }),
            };
        },
    }
}

fn kindName(v: zon.Value) []const u8 {
    return switch (v) {
        .none => "null",
        .bool => "a boolean",
        .int => "an integer",
        .float => "a number",
        .string => "a string",
        .tag => "an enum value",
        .record => "a record",
        .list => "a list",
    };
}

/// ZON value to schema value for a leaf type, or null with `why` set.
fn convert(c: *Ctx, ty: *const schema.Type, v: zon.Value, why: *[]const u8) !?schema.Value {
    switch (ty.kind) {
        .bool => if (v == .bool) return .{ .bool = v.bool },
        .int => if (v == .int) return .{ .int = v.int },
        .float => switch (v) {
            .float => |f| return .{ .float = f },
            .int => |i| return .{ .float = @floatFromInt(i) },
            else => {},
        },
        .string, .text => if (v == .string) return .{ .text = v.string },
        .choice => {
            const name = switch (v) {
                .tag => |t| t,
                .string => |s| s,
                else => {
                    why.* = try std.fmt.allocPrint(c.arena(), "expected one of {s}", .{try joinNames(c, ty)});
                    return null;
                },
            };
            for (ty.enum_names, 0..) |n, i| {
                if (std.mem.eql(u8, n, name)) return .{ .choice = @intCast(i) };
            }
            why.* = try std.fmt.allocPrint(c.arena(), "unknown value '{s}' (expected {s})", .{ name, try joinNames(c, ty) });
            return null;
        },
        .color => return try convertColor(c, v, why),
        .length => return try convertLength(c, v, why),
        else => {},
    }
    why.* = try std.fmt.allocPrint(c.arena(), "expected a {s} value, found {s}", .{ @tagName(ty.kind), kindName(v) });
    return null;
}

fn joinNames(c: *Ctx, ty: *const schema.Type) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (ty.enum_names, 0..) |n, i| {
        if (i > 0) try out.appendSlice(c.arena(), ", ");
        try out.appendSlice(c.arena(), n);
    }
    return out.items;
}

fn byte(v: zon.Value) ?u8 {
    return if (v == .int) std.math.cast(u8, v.int) else null;
}

fn convertColor(c: *Ctx, v: zon.Value, why: *[]const u8) !?schema.Value {
    const geometry = @import("../core/geometry.zig");
    switch (v) {
        .string => |s| {
            const parsed = form.parseValue(schema.typeOf(geometry.Color), .{}, s) catch |e| {
                why.* = form.parseMessage(e);
                return null;
            };
            return parsed;
        },
        .list => |items| if (items.len == 3 or items.len == 4) {
            const r = byte(items[0]);
            const g = byte(items[1]);
            const b = byte(items[2]);
            const a = if (items.len == 4) byte(items[3]) else 255;
            if (r != null and g != null and b != null and a != null) return .{ .color = .{ .r = r.?, .g = g.?, .b = b.?, .a = a.? } };
        },
        .record => {
            const r = if (v.field("r")) |x| byte(x) else null;
            const g = if (v.field("g")) |x| byte(x) else null;
            const b = if (v.field("b")) |x| byte(x) else null;
            const a = if (v.field("a")) |x| byte(x) else 255;
            if (r != null and g != null and b != null and a != null) return .{ .color = .{ .r = r.?, .g = g.?, .b = b.?, .a = a.? } };
        },
        else => {},
    }
    _ = c;
    if (why.*.len == 0) why.* = "expected \"#rrggbb\", \"#rrggbbaa\", .{ r, g, b } or .{ .r = , .g = , .b = }";
    return null;
}

fn convertLength(c: *Ctx, v: zon.Value, why: *[]const u8) !?schema.Value {
    const Length = @import("../core/length.zig").Length;
    switch (v) {
        .int => |i| return .{ .length = Length.px(@floatFromInt(i)) },
        .float => |f| return .{ .length = Length.px(@floatCast(f)) },
        .tag => |t| {
            if (std.mem.eql(u8, t, "auto")) return .{ .length = .auto };
            if (std.mem.eql(u8, t, "fill")) return .{ .length = .fill };
            if (std.mem.eql(u8, t, "fit")) return .{ .length = .fit };
        },
        .string => |s| {
            const ty = schema.typeOf(Length);
            return form.parseValue(ty, .{}, s) catch |e| {
                why.* = form.parseMessage(e);
                return null;
            };
        },
        .record => {
            if (v.field("pixels")) |p| switch (p) {
                .int => |i| return .{ .length = Length.px(@floatFromInt(i)) },
                .float => |f| return .{ .length = Length.px(@floatCast(f)) },
                else => {},
            };
            if (v.field("percent")) |p| switch (p) {
                .int => |i| return .{ .length = Length.pct(@floatFromInt(i)) },
                .float => |f| return .{ .length = Length.pct(@floatCast(f)) },
                else => {},
            };
        },
        else => {},
    }
    _ = c;
    why.* = "expected a number (pixels), .auto, .fill, .fit, or \"50%\"";
    return null;
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;
const Button = @import("../widgets/button.zig").Button;
const Label = @import("../widgets/label.zig").Label;
const TextField = @import("../widgets/text_field.zig").TextField;
const Color = @import("../core/geometry.zig").Color;

const sample =
    \\.{
    \\    .root = .{
    \\        .type = "box",
    \\        .style = .{ .direction = .column, .gap = 6, .padding = .{ .left = 12, .top = "5%" }, .align_self = .center },
    \\        .children = .{
    \\            .{ .type = "label", .id = "title", .props = .{ .text = "Hello", .size = 20, .color = "#ff8000" } },
    \\            .{
    \\                .type = "button",
    \\                .id = "ok",
    \\                .style = .{ .width = 90, .grow = 1 },
    \\                .props = .{ .text = "OK", .variant = .primary, .colors = null },
    \\                .on = .{ .click = "confirm" },
    \\            },
    \\            .{ .type = "text_field", .id = "name", .props = .{ .text = "abc" } },
    \\        },
    \\    },
    \\}
;

var confirmed: u32 = 0;
fn onConfirm(_: *event.Event) void {
    confirmed += 1;
}

fn loadSample(ui: *Ui, src: []const u8, opts: Options) !struct { doc: doc_mod.Doc, inst: Instance } {
    var doc = try doc_mod.parseDoc(testing.allocator, src, null, null);
    errdefer doc.deinit();
    const inst = try instantiate(ui, ui.tree.root, &doc, opts);
    return .{ .doc = doc, .inst = inst };
}

test "a document becomes widgets with styles, props, ids, and bound actions" {
    var ui = try Ui.init(testing.allocator);
    defer ui.deinit();
    var actions: Actions = .{};
    defer actions.deinit(testing.allocator);
    try actions.put(testing.allocator, "confirm", event.Callback.fromFn(onConfirm));
    var r = try loadSample(&ui, sample, .{ .actions = &actions });
    defer r.doc.deinit();
    defer r.inst.destroy();
    try testing.expectEqual(@as(usize, 0), r.inst.problems.items.len);

    const root = ui.tree.get(r.inst.root).?;
    try testing.expect(root.style.direction == .column);
    try testing.expectEqual(@as(f32, 6), root.style.gap.pixels);
    try testing.expectEqual(@as(f32, 12), root.style.padding.left.pixels);
    try testing.expectEqual(@as(f32, 5), root.style.padding.top.percent);
    try testing.expect(root.style.align_self.? == .center);

    const title = r.inst.widget(Label, "title").?;
    try testing.expectEqualStrings("Hello", title.props.text.bytes);
    try testing.expectEqual(@as(f32, 20), title.props.size);
    try testing.expectEqual(Color.rgb(255, 128, 0), title.props.color);

    const ok = r.inst.widget(Button, "ok").?;
    try testing.expect(ok.props.variant == .primary);
    try testing.expectEqual(@as(f32, 90), ui.tree.get(ok.node).?.style.width.pixels);
    try testing.expectEqualStrings("abc", r.inst.widget(TextField, "name").?.text());
    try testing.expect(r.inst.widget(Button, "title") == null); // wrong type
    try testing.expect(r.inst.find("nope") == null);

    confirmed = 0;
    var ev: event.Event = .{ .kind = .pointer_up };
    ok.props.on_click.?.invoke(&ev);
    try testing.expectEqual(@as(u32, 1), confirmed);
    try testing.expect(r.inst.handleOf(r.doc.root.children.items[1].uid).?.eql(ok.node));
}

test "problems name the node and the path, and the rest still builds" {
    var ui = try Ui.init(testing.allocator);
    defer ui.deinit();
    var r = try loadSample(&ui,
        \\.{ .root = .{ .type = "box", .children = .{
        \\    .{ .type = "button", .props = .{ .text = "x", .variant = .huge, .bogus = 1, .enabled = 3, .on_click = 1 } },
        \\    .{ .type = "slider" },
        \\    .{ .type = "box", .props = .{ .text = "x" }, .on = .{ .click = "go" } },
        \\    .{ .type = "label", .id = "a" },
        \\    .{ .type = "label", .id = "a", .style = .{ .width = "wide", .grow = "x", .nope = 1 } },
        \\    .{ .type = "button", .on = .{ .hover = "x", .click = "missing" } },
        \\    .{ .type = "label", .props = .{ .color = "#12", .size = .big } },
        \\} } }
    , .{});
    defer r.doc.deinit();
    defer r.inst.destroy();
    const want = [_][]const u8{
        "props.variant: unknown value 'huge' (expected normal, primary, danger, flat)",
        "props: unknown field 'bogus'",
        "props.enabled: expected a bool value, found an integer",
        "props.on_click: events are bound under .on",
        "unknown widget type 'slider'",
        "props: a box has no props",
        "on: a box has no events",
        "id 'a' is used more than once",
        "style.width: Use auto, fill, fit, 12 or 50%",
        "style.grow: expected a float value, found a string",
        "style: unknown field 'nope'",
        "on.hover: button has no such event",
        "on.click: unknown action 'missing'",
        "props.color: Use #rgb, #rrggbb or #rrggbbaa",
        "props.size: expected a float value, found an enum value",
    };
    for (want) |w| {
        var found = false;
        for (r.inst.problems.items) |p| found = found or std.mem.indexOf(u8, p.message, w) != null;
        if (!found) {
            std.debug.print("missing problem: {s}\n", .{w});
            for (r.inst.problems.items) |p| std.debug.print("  have: {s}\n", .{p.message});
        }
        try testing.expect(found);
    }
    try testing.expectEqual(@as(usize, 7), ui.tree.childCount(r.inst.root));
}

test "lenient mode ignores unknown actions; strict reports and tears down" {
    var ui = try Ui.init(testing.allocator);
    defer ui.deinit();
    var r = try loadSample(&ui, sample, .{ .strict = false });
    try testing.expectEqual(@as(usize, 0), r.inst.problems.items.len);
    try testing.expect(r.inst.widget(Button, "ok").?.props.on_click == null);
    r.inst.destroy();

    const before = ui.tree.childCount(ui.tree.root);
    try testing.expectError(error.InvalidDocument, instantiateStrict(&ui, ui.tree.root, &r.doc, .{}));
    ui.update(); // deferred destroys settle
    try testing.expectEqual(before, ui.tree.childCount(ui.tree.root));
    r.doc.deinit();
}

test "optional props: null clears, a value makes present then edits" {
    var ui = try Ui.init(testing.allocator);
    defer ui.deinit();
    var r = try loadSample(&ui,
        \\.{ .root = .{ .type = "button", .id = "b", .props = .{ .colors = .{ .text = "#010203" } }, .style = .{ .align_self = null } } }
    , .{});
    defer r.doc.deinit();
    defer r.inst.destroy();
    try testing.expectEqual(@as(usize, 0), r.inst.problems.items.len);
    const b = r.inst.widget(Button, "b").?;
    try testing.expect(b.props.colors != null);
    try testing.expectEqual(Color.rgb(1, 2, 3), b.props.colors.?.text);
}

test "loaded widgets lay out and draw with their text" {
    const draw_list = @import("../core/draw_list.zig");
    const font = @import("../text/font.zig");
    var ui = try Ui.init(testing.allocator);
    defer ui.deinit();
    var prop: font.TestFont = .{};
    _ = try ui.addFont(prop.backend());
    ui.theme.font_size = 20;
    var r = try loadSample(&ui, sample, .{ .strict = false });
    defer r.doc.deinit();
    defer r.inst.destroy();

    var cmds: [256]draw_list.Command = undefined;
    var glyphs: [1024]draw_list.Glyph = undefined;
    var list = draw_list.DrawList.init(&cmds, &glyphs);
    ui.update();
    try ui.layoutAndPaint(.{ .w = 300, .h = 200 }, &list);
    ui.endFrame();
    var runs: usize = 0;
    for (list.items()) |cmd| switch (cmd) {
        .glyph_run => runs += 1,
        else => {},
    };
    try testing.expect(runs >= 3); // Hello, OK, abc
    try testing.expect(r.inst.widget(Label, "title").?.out.text_width > 0);
}

test "instantiating allocates cleanly even when allocations fail" {
    var i: usize = 0;
    while (i < 120) : (i += 1) {
        var fa = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = i });
        var ui = Ui.init(fa.allocator()) catch continue;
        defer ui.deinit();
        var doc = try doc_mod.parseDoc(testing.allocator, sample, null, null);
        defer doc.deinit();
        var inst = instantiate(&ui, ui.tree.root, &doc, .{ .strict = false }) catch continue;
        inst.destroy();
    }
}

test "children of a scroll view go into its content node" {
    var ui = try Ui.init(testing.allocator);
    defer ui.deinit();
    var r = try loadSample(&ui,
        \\.{ .root = .{ .type = "scroll_view", .id = "sv", .style = .{ .height = 100 }, .children = .{
        \\    .{ .type = "label", .id = "a", .props = .{ .text = "one" } },
        \\    .{ .type = "label", .id = "b", .props = .{ .text = "two" } },
        \\} } }
    , .{});
    defer r.doc.deinit();
    defer r.inst.destroy();
    try testing.expectEqual(@as(usize, 0), r.inst.problems.items.len);
    const sv = r.inst.widget(zigui_scroll.ScrollView, "sv").?;
    try testing.expectEqual(@as(u32, 1), ui.tree.childCount(sv.node)); // just the content node
    try testing.expectEqual(@as(u32, 2), ui.tree.childCount(sv.contentNode()));
    const a = r.inst.find("a").?;
    try testing.expect(ui.tree.get(a).?.parent.eql(sv.contentNode()));
}

const zigui_scroll = struct {
    const ScrollView = @import("../widgets/scroll_view.zig").ScrollView;
};
