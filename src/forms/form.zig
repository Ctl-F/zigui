//! Struct-to-form generation (design doc section 11).
//!
//! `Form(T)` builds a dialog body from the runtime schema of `T`: a bool becomes
//! an On/Off toggle, an enum a button that cycles through its names, numbers,
//! colors, lengths, and strings text fields, an optional a "Set" toggle plus the
//! control, and a nested struct or array an indented group. Field defaults are
//! the initial values (or pass `initial`). A `pub const ui` block on `T` supplies
//! labels, tooltips-to-be, min and max, and `hidden`/`readonly`.
//!
//! The form is non-blocking: create it, then poll `state` each frame. A
//! blocking `prompt` needs the platform's event loop and lives with the
//! platform shim, not here.
//!
//!     var form = try Form(NewProject).create(&ui, parent, .{ .title = "New project" });
//!     defer form.destroy();
//!     ... each frame: if (form.state == .submitted) { const v = try form.take(alloc); ... }
//!
//! An optional `pub fn validate(value: *const T, report: *form.Report) void` on
//! `T` adds cross-field checks. Messages must be string literals (or otherwise
//! outlive the call). Parse errors (a bad number, an out-of-range value) and
//! validation errors show under the field and disable Submit.
//!
//! Strings: text the user types is copied into storage the form owns; it stays
//! valid until the form is destroyed. `take` copies the whole value with an
//! allocator you choose (free with `freeOwned`, or pass an arena).

const std = @import("std");
const schema = @import("../core/schema.zig");
const ui_mod = @import("../core/ui.zig");
const Ui = ui_mod.Ui;
const event = @import("../core/event.zig");
const Handle = @import("../core/handle.zig").Handle;
const Length = @import("../core/length.zig").Length;
const Style = @import("../core/style.zig").Style;
const Color = @import("../core/geometry.zig").Color;
const Button = @import("../widgets/button.zig").Button;
const Text = @import("../widgets/common.zig").Text;
const Label = @import("../widgets/label.zig").Label;
const TextField = @import("../widgets/text_field.zig").TextField;

/// Collects validation messages. See `Form`.
pub const Report = struct {
    pub const max_items = 32;
    pub const Item = struct { path: []const u8, message: []const u8 };

    items: [max_items]Item = undefined,
    len: usize = 0,

    /// Attach `message` to the field at `path` (`""` for the form as a whole).
    pub fn add(self: *Report, path: []const u8, message: []const u8) void {
        if (self.len == max_items) return;
        self.items[self.len] = .{ .path = path, .message = message };
        self.len += 1;
    }

    pub fn forPath(self: *const Report, path: []const u8) ?[]const u8 {
        for (self.items[0..self.len]) |it| if (std.mem.eql(u8, it.path, path)) return it.message;
        return null;
    }
};

// ---- value text -----------------------------------------------------------------

pub const ParseError = error{ NotANumber, OutOfRange, BadColor, BadLength };

pub fn parseMessage(err: ParseError) []const u8 {
    return switch (err) {
        error.NotANumber => "Enter a number",
        error.OutOfRange => "Out of range",
        error.BadColor => "Use #rgb, #rrggbb or #rrggbbaa",
        error.BadLength => "Use auto, fill, fit, 12 or 50%",
    };
}

/// Text shown in a field for `v`. `buf` backs numeric formats.
pub fn formatValue(ty: *const schema.Type, v: schema.Value, buf: []u8) []const u8 {
    return switch (v) {
        .none => "",
        .text => |t| t,
        .int => |i| std.fmt.bufPrint(buf, "{d}", .{i}) catch "",
        .float => |f| std.fmt.bufPrint(buf, "{d}", .{f}) catch "",
        .color => |c| std.fmt.bufPrint(buf, "#{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ c.r, c.g, c.b, c.a }) catch "",
        .length => |l| switch (l) {
            .pixels => |p| std.fmt.bufPrint(buf, "{d}", .{p}) catch "",
            .percent => |p| std.fmt.bufPrint(buf, "{d}%", .{p}) catch "",
            .auto => "auto",
            .fill => "fill",
            .fit => "fit",
        },
        .bool => |b| if (b) "true" else "false",
        .choice => |i| if (i < ty.enum_names.len) ty.enum_names[i] else "",
    };
}

fn hexDigit(c: u8) ?u8 {
    return std.fmt.charToDigit(c, 16) catch null;
}

fn parseColor(text: []const u8) ParseError!Color {
    var t = text;
    if (t.len > 0 and t[0] == '#') t = t[1..];
    var out: [4]u8 = .{ 0, 0, 0, 255 };
    switch (t.len) {
        3, 4 => for (t, 0..) |c, i| {
            const d = hexDigit(c) orelse return error.BadColor;
            out[i] = d * 17;
        },
        6, 8 => {
            var i: usize = 0;
            while (i < t.len) : (i += 2) {
                const hi = hexDigit(t[i]) orelse return error.BadColor;
                const lo = hexDigit(t[i + 1]) orelse return error.BadColor;
                out[i / 2] = hi * 16 + lo;
            }
        },
        else => return error.BadColor,
    }
    return .{ .r = out[0], .g = out[1], .b = out[2], .a = out[3] };
}

fn parseLength(text: []const u8) ParseError!Length {
    if (std.mem.eql(u8, text, "auto")) return .auto;
    if (std.mem.eql(u8, text, "fill")) return .fill;
    if (std.mem.eql(u8, text, "fit")) return .fit;
    if (std.mem.endsWith(u8, text, "%")) {
        const n = std.fmt.parseFloat(f32, std.mem.trim(u8, text[0 .. text.len - 1], " ")) catch return error.BadLength;
        if (!std.math.isFinite(n)) return error.BadLength;
        return Length.pct(n);
    }
    const body = if (std.mem.endsWith(u8, text, "px")) text[0 .. text.len - 2] else text;
    const n = std.fmt.parseFloat(f32, std.mem.trim(u8, body, " ")) catch return error.BadLength;
    if (!std.math.isFinite(n)) return error.BadLength;
    return Length.px(n);
}

fn inMetaRange(meta: schema.Meta, x: f64) bool {
    if (meta.min) |lo| if (x < lo) return false;
    if (meta.max) |hi| if (x > hi) return false;
    return true;
}

/// Parse what the user typed into a value for a field of type `ty`.
pub fn parseValue(ty: *const schema.Type, meta: schema.Meta, raw: []const u8) ParseError!schema.Value {
    const text = std.mem.trim(u8, raw, " \t");
    switch (ty.kind) {
        .int => {
            const n = std.fmt.parseInt(i64, text, 10) catch |e| return switch (e) {
                error.Overflow => error.OutOfRange,
                else => error.NotANumber,
            };
            if (!inMetaRange(meta, @floatFromInt(n))) return error.OutOfRange;
            return .{ .int = n };
        },
        .float => {
            const n = std.fmt.parseFloat(f64, text) catch return error.NotANumber;
            if (!std.math.isFinite(n)) return error.NotANumber;
            if (!inMetaRange(meta, n)) return error.OutOfRange;
            return .{ .float = n };
        },
        .color => return .{ .color = try parseColor(text) },
        .length => return .{ .length = try parseLength(text) },
        else => return .{ .text = raw },
    }
}

// ---- owned copies of a value ----------------------------------------------------

fn hasStrings(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.size == .slice and p.child == u8,
        .optional => |o| hasStrings(o.child),
        .array => |a| hasStrings(a.child),
        .@"struct" => |s| blk: {
            if (T == Color) break :blk false;
            inline for (s.field_types) |FT| if (hasStrings(FT)) break :blk true;
            break :blk false;
        },
        else => false,
    };
}

/// Copy `src`, duplicating every `[]const u8` in it with `a`. Free the result
/// with `freeOwned` (or use an arena).
pub fn cloneOwned(comptime T: type, src: T, a: std.mem.Allocator) std.mem.Allocator.Error!T {
    if (comptime !hasStrings(T)) return src;
    switch (@typeInfo(T)) {
        .pointer => return try a.dupe(u8, src),
        .optional => |o| return if (src) |inner| try cloneOwned(o.child, inner, a) else null,
        .array => |arr| {
            var out: T = undefined;
            for (src, 0..) |item, i| {
                out[i] = cloneOwned(arr.child, item, a) catch |e| {
                    for (out[0..i]) |done| freeOwned(arr.child, done, a);
                    return e;
                };
            }
            return out;
        },
        .@"struct" => |s| {
            var out: T = src;
            inline for (s.field_names, s.field_types, 0..) |n, FT, i| {
                if (comptime hasStrings(FT)) {
                    @field(out, n) = cloneOwned(FT, @field(src, n), a) catch |e| {
                        inline for (s.field_names[0..i], s.field_types[0..i]) |pn, PT| {
                            if (comptime hasStrings(PT)) freeOwned(PT, @field(out, pn), a);
                        }
                        return e;
                    };
                }
            }
            return out;
        },
        else => unreachable,
    }
}

/// Free a value made by `cloneOwned`.
pub fn freeOwned(comptime T: type, v: T, a: std.mem.Allocator) void {
    if (comptime !hasStrings(T)) return;
    switch (@typeInfo(T)) {
        .pointer => a.free(v),
        .optional => |o| if (v) |inner| freeOwned(o.child, inner, a),
        .array => |arr| for (v) |item| freeOwned(arr.child, item, a),
        .@"struct" => |s| inline for (s.field_names, s.field_types) |n, FT| freeOwned(FT, @field(v, n), a),
        else => unreachable,
    }
}

// ---- the form -------------------------------------------------------------------

pub const State = enum { open, submitted, cancelled };

/// The `T` of a form over a value known only by its schema (`createDynamic`).
pub const Dynamic = struct {};

pub const Options = struct {
    title: []const u8 = "",
    submit_label: []const u8 = "OK",
    cancel_label: []const u8 = "Cancel",
    /// Layout of the form's root column.
    style: Style = .{},
    /// Width of the label column.
    label_width: f32 = 140,
    /// Show only these top-level fields, in the order of the struct.
    only: ?[]const []const u8 = null,
    /// Show only top-level fields whose `ui` metadata names this group (`""`
    /// matches fields with no group). Ignored when `only` is set.
    group: ?[]const u8 = null,
    /// Include the Submit and Cancel buttons (wizards supply their own).
    footer: bool = true,
};

pub fn Form(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Out = struct {
            /// Something was edited this frame; cleared by `endFrame`.
            changed: bool = false,
            /// No parse errors and `validate` is happy: Submit is enabled.
            valid: bool = true,
            /// An allocation failed while handling an edit.
            failed: bool = false,
        };

        const Kind = enum { toggle, cycle, field, presence };

        const Binding = struct {
            form: *Self,
            kind: Kind,
            path: []const u8,
            ty: *const schema.Type,
            meta: schema.Meta,
            button: ?*Button = null,
            field: ?*TextField = null,
            err: ?*Label = null,
            parse_error: ?[]const u8 = null,
        };

        ui: *Ui,
        gpa: std.mem.Allocator,
        opts: Options,
        /// What is being edited: its schema and where it lives. For `Form(T)`
        /// that is `value`; for `Form(Dynamic)` it is whatever was passed to
        /// `createDynamic` (which must outlive the form).
        root_type: *const schema.Type,
        base: *anyopaque,
        /// The value being edited. Read it any time; `take` gives an owned copy.
        value: T,
        state: State = .open,
        out: Out = .{},
        root: Handle = Handle.invalid,
        body: Handle = Handle.invalid,
        submit: ?*Button = null,
        form_error: ?*Label = null,
        /// True for `createDynamic`: `Text` fields (toolkit-owned widget text) are
        /// editable too.
        dynamic: bool = false,
        /// Called after every revalidation (edit, rebuild).
        notify: ?event.Callback = null,
        /// Wizard pages: whether form-level (`""`) validation messages apply to
        /// the page being shown.
        page_final: bool = true,

        /// Two build arenas: a rebuild can run inside a callback whose binding
        /// lives in the previous arena, so that one is only reset a rebuild later.
        arenas: [2]std.heap.ArenaAllocator,
        cur: u1 = 0,
        bindings: std.ArrayListUnmanaged(*Binding) = .empty,
        /// Strings the user typed, owned by the form.
        owned: std.ArrayListUnmanaged([]u8) = .empty,


        pub fn create(ui: *Ui, parent: Handle, opts: Options) !*Self {
            const self = try ui.gpa.create(Self);
            errdefer ui.gpa.destroy(self);
            self.* = .{
                .ui = ui,
                .gpa = ui.gpa,
                .opts = opts,
                .root_type = schema.typeOf(T),
                .base = undefined,
                .value = schema.defaultOf(T),
                .arenas = .{ std.heap.ArenaAllocator.init(ui.gpa), std.heap.ArenaAllocator.init(ui.gpa) },
            };
            self.base = &self.value;
            errdefer self.release();
            try self.buildChrome(parent);
            try self.rebuild();
            return self;
        }

        /// A form over a value described only by its schema (the builder's
        /// inspector). `T` must be `Dynamic`. Edits are written straight to
        /// `base`; use `notify` to react (for example to mark dirty).
        pub fn createDynamic(ui: *Ui, parent: Handle, root_type: *const schema.Type, base: *anyopaque, opts: Options) !*Self {
            comptime std.debug.assert(T == Dynamic);
            const self = try ui.gpa.create(Self);
            errdefer ui.gpa.destroy(self);
            self.* = .{
                .ui = ui,
                .gpa = ui.gpa,
                .opts = opts,
                .root_type = root_type,
                .base = base,
                .value = .{},
                .dynamic = true,
                .arenas = .{ std.heap.ArenaAllocator.init(ui.gpa), std.heap.ArenaAllocator.init(ui.gpa) },
            };
            errdefer self.release();
            try self.buildChrome(parent);
            try self.rebuild();
            return self;
        }

        /// Create with a starting value. Strings in `initial` are borrowed and
        /// must outlive the form.
        pub fn createWith(ui: *Ui, parent: Handle, initial: T, opts: Options) !*Self {
            const self = try create(ui, parent, opts);
            self.value = initial;
            try self.rebuild();
            return self;
        }

        pub fn destroy(self: *Self) void {
            _ = self.ui.tree.destroySubtree(self.root);
            self.release();
            self.gpa.destroy(self);
        }

        fn release(self: *Self) void {
            for (self.owned.items) |s| self.gpa.free(s);
            self.owned.deinit(self.gpa);
            self.arenas[0].deinit();
            self.arenas[1].deinit();
        }

        /// Copy of the current value that you own: free with `freeOwned`.
        pub fn take(self: *const Self, a: std.mem.Allocator) !T {
            return cloneOwned(T, self.value, a);
        }

        pub fn endFrame(self: *Self) void {
            self.out.changed = false;
        }

        // ---- building ----

        fn arena(self: *Self) std.mem.Allocator {
            return self.arenas[self.cur].allocator();
        }

        fn node(self: *Self, parent: Handle, style: Style) !Handle {
            const h = try self.ui.tree.create(.{ .style = style });
            errdefer _ = self.ui.tree.destroySubtree(h);
            try self.ui.tree.appendChild(parent, h);
            return h;
        }

        fn buildChrome(self: *Self, parent: Handle) !void {
            var root_style = self.opts.style;
            if (root_style.direction != .column) root_style.direction = .column;
            root_style.gap = Length.px(8);
            self.root = try self.node(parent, root_style);
            if (self.opts.title.len > 0) {
                _ = try self.ui.add(Label, self.root, .{ .text = self.opts.title, .size = 18 });
            }
            self.body = try self.node(self.root, .{ .direction = .column, .gap = Length.px(6) });
            self.form_error = try self.ui.add(Label, self.root, .{ .color = error_color });
            if (!self.opts.footer) return;
            const footer = try self.node(self.root, .{ .direction = .row, .gap = Length.px(8), .justify = .end });
            const cancel = try self.ui.add(Button, footer, .{ .text = self.opts.cancel_label });
            cancel.props.on_click = event.Callback.bind(self, onCancel);
            self.submit = try self.ui.add(Button, footer, .{ .text = self.opts.submit_label, .variant = .primary });
            self.submit.?.props.on_click = event.Callback.bind(self, onSubmit);
        }

        /// Rebuild every control from `value` (after `value` was assigned
        /// directly, or when an optional appears or disappears).
        pub fn rebuild(self: *Self) !void {
            var child = self.ui.tree.get(self.body).?.first_child;
            while (self.ui.tree.get(child)) |n| {
                const next = n.next;
                _ = self.ui.tree.destroySubtree(child);
                child = next;
            }
            self.cur ^= 1;
            _ = self.arenas[self.cur].reset(.retain_capacity);
            self.bindings = .empty;
            try self.buildFields(self.body, self.root_type, "", 0);
            self.revalidate();
        }

        fn buildFields(self: *Self, parent: Handle, ty: *const schema.Type, prefix: []const u8, depth: u32) anyerror!void {
            for (ty.fields) |*f| {
                if (f.meta.hidden or !f.type.isEditable()) continue;
                if (f.type.kind == .text and !self.dynamic) continue; // toolkit-owned widget text
                if (depth == 0 and !self.selected(f)) continue;
                const path = if (prefix.len == 0)
                    try self.arena().dupe(u8, f.name)
                else
                    try std.fmt.allocPrint(self.arena(), "{s}.{s}", .{ prefix, f.name });
                var buf: [64]u8 = undefined;
                const label = try self.arena().dupe(u8, f.displayName(&buf));
                try self.buildValue(parent, label, path, f.type, f.meta, depth);
            }
        }

        /// Whether a top-level field belongs on the page being shown.
        fn selected(self: *const Self, f: *const schema.Field) bool {
            if (self.opts.only) |names| {
                for (names) |n| if (std.mem.eql(u8, n, f.name)) return true;
                return false;
            }
            if (self.opts.group) |g| return std.mem.eql(u8, f.meta.group orelse "", g);
            return true;
        }

        fn pathInPage(self: *const Self, path: []const u8) bool {
            if (self.opts.only == null and self.opts.group == null) return true;
            if (path.len == 0) return self.page_final;
            const end = std.mem.indexOfAny(u8, path, ".[") orelse path.len;
            const f = self.root_type.field(path[0..end]) orelse return false;
            return self.selected(f);
        }

        fn labelCell(self: *Self, row: Handle, text: []const u8) !void {
            _ = try self.ui.add(Label, row, .{
                .text = text,
                .style = .{ .width = Length.px(self.opts.label_width), .shrink = 0 },
            });
        }

        fn group(self: *Self, parent: Handle, title: []const u8, depth: u32) !Handle {
            if (title.len > 0) _ = try self.ui.add(Label, parent, .{ .text = title, .size = 15 });
            _ = depth;
            return self.node(parent, .{
                .direction = .column,
                .gap = Length.px(6),
                .padding = .{ .left = Length.px(16) },
            });
        }

        fn bind(self: *Self, kind: Kind, path: []const u8, ty: *const schema.Type, meta: schema.Meta) !*Binding {
            const b = try self.arena().create(Binding);
            b.* = .{ .form = self, .kind = kind, .path = path, .ty = ty, .meta = meta };
            try self.bindings.append(self.arena(), b);
            return b;
        }

        fn buildValue(self: *Self, parent: Handle, label: []const u8, path: []const u8, ty: *const schema.Type, meta: schema.Meta, depth: u32) anyerror!void {
            switch (ty.kind) {
                .@"struct" => {
                    const g = try self.group(parent, label, depth);
                    try self.buildFields(g, ty, path, depth + 1);
                },
                .array => {
                    const g = try self.group(parent, label, depth);
                    var i: usize = 0;
                    while (i < ty.len) : (i += 1) {
                        const p = try std.fmt.allocPrint(self.arena(), "{s}[{d}]", .{ path, i });
                        const l = try std.fmt.allocPrint(self.arena(), "[{d}]", .{i});
                        try self.buildValue(g, l, p, ty.child.?, meta, depth + 1);
                    }
                },
                .optional => {
                    const col = try self.node(parent, .{ .direction = .column, .gap = Length.px(2) });
                    const row = try self.node(col, .{ .direction = .row, .gap = Length.px(8), .align_items = .center });
                    try self.labelCell(row, label);
                    const present = schema.isPresent(self.root_type, self.base, path) catch false;
                    const pb = try self.bind(.presence, path, ty, meta);
                    pb.button = try self.ui.add(Button, row, .{
                        .text = if (present) "Set" else "Unset",
                        .variant = if (present) .primary else .normal,
                        .enabled = !meta.readonly,
                    });
                    pb.button.?.props.on_click = event.Callback.bind(pb, onClick);
                    if (!present) return;
                    const inner = ty.child.?;
                    if (inner.isLeaf()) {
                        try self.leafControl(col, row, path, inner, meta);
                    } else {
                        const g = try self.group(col, "", depth);
                        switch (inner.kind) {
                            .@"struct" => try self.buildFields(g, inner, path, depth + 1),
                            else => try self.buildValue(g, label, path, inner, meta, depth + 1),
                        }
                    }
                },
                else => {
                    if (!ty.isLeaf()) return;
                    const col = try self.node(parent, .{ .direction = .column, .gap = Length.px(2) });
                    const row = try self.node(col, .{ .direction = .row, .gap = Length.px(8), .align_items = .center });
                    try self.labelCell(row, label);
                    try self.leafControl(col, row, path, ty, meta);
                },
            }
        }

        /// The control for a leaf in `row`, and its error line after the row
        /// inside `col`.
        fn leafControl(self: *Self, col: Handle, row: Handle, path: []const u8, ty: *const schema.Type, meta: schema.Meta) !void {
            var vbuf: [64]u8 = undefined;
            const current = schema.get(self.root_type, self.base, path) catch schema.Value.none;
            switch (ty.kind) {
                .bool => {
                    const b = try self.bind(.toggle, path, ty, meta);
                    const on = current == .bool and current.bool;
                    b.button = try self.ui.add(Button, row, .{ .text = if (on) "On" else "Off", .variant = if (on) .primary else .normal, .enabled = !meta.readonly });
                    b.button.?.props.on_click = event.Callback.bind(b, onClick);
                },
                .choice => {
                    const b = try self.bind(.cycle, path, ty, meta);
                    b.button = try self.ui.add(Button, row, .{ .text = formatValue(ty, current, &vbuf), .enabled = !meta.readonly });
                    b.button.?.props.on_click = event.Callback.bind(b, onClick);
                },
                else => {
                    const b = try self.bind(.field, path, ty, meta);
                    b.field = try self.ui.add(TextField, row, .{
                        .text = formatValue(ty, current, &vbuf),
                        .read_only = meta.readonly,
                        .style = .{ .grow = 1, .min_width = Length.px(120) },
                        .on_change = event.Callback.bind(b, onChange),
                        .on_submit = event.Callback.bind(b, onChange),
                    });
                },
            }
            // Every control gets an error line (parse and `validate` messages).
            const bb = self.bindings.items[self.bindings.items.len - 1];
            bb.err = try self.ui.add(Label, col, .{
                .color = error_color,
                .style = .{ .padding = .{ .left = Length.px(self.opts.label_width + 8) } },
            });
        }

        // ---- editing ----

        const error_color = Color.rgb(224, 96, 96);

        fn replaceString(ctx: ?*anyopaque, slot: *[]const u8, bytes: []const u8) error{OutOfMemory}!void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            const copy = try self.gpa.dupe(u8, bytes);
            errdefer self.gpa.free(copy);
            try self.owned.append(self.gpa, copy);
            // Release the previous string if the form made it.
            for (self.owned.items[0 .. self.owned.items.len - 1], 0..) |s, i| {
                if (s.ptr == slot.ptr and s.len == slot.len and s.len > 0) {
                    self.gpa.free(s);
                    _ = self.owned.swapRemove(i);
                    break;
                }
            }
            slot.* = copy;
        }

        fn replaceWidgetText(ctx: ?*anyopaque, t: *anyopaque, bytes: []const u8) error{OutOfMemory}!void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            try self.ui.replaceText(@ptrCast(@alignCast(t)), bytes);
        }

        fn env(self: *Self) schema.Env {
            return .{ .ctx = self, .replace_string = replaceString, .replace_text = if (self.dynamic) replaceWidgetText else null };
        }

        fn write(self: *Self, b: *Binding, v: schema.Value) bool {
            const e = self.env();
            schema.set(self.root_type, self.base, b.path, v, &e) catch |err| {
                b.parse_error = switch (err) {
                    error.OutOfRange => "Out of range",
                    error.OutOfMemory => blk: {
                        self.out.failed = true;
                        break :blk "Out of memory";
                    },
                    else => "Cannot set",
                };
                return false;
            };
            return true;
        }

        fn afterChange(self: *Self) void {
            self.out.changed = true;
            self.revalidate();
        }

        fn onChange(b: *Binding, _: *event.Event) void {
            const self = b.form;
            const text = b.field.?.text();
            b.parse_error = null;
            if (parseValue(b.ty, b.meta, text)) |v| {
                _ = self.write(b, v);
            } else |err| {
                b.parse_error = parseMessage(err);
            }
            self.afterChange();
        }

        fn onClick(b: *Binding, _: *event.Event) void {
            const self = b.form;
            switch (b.kind) {
                .toggle => {
                    const cur = schema.get(self.root_type, self.base, b.path) catch return;
                    const next = !(cur == .bool and cur.bool);
                    if (!self.write(b, .{ .bool = next })) return;
                    const btn = b.button.?;
                    btn.setText(if (next) "On" else "Off") catch {};
                    btn.props.variant = if (next) .primary else .normal;
                    self.ui.tree.markDirty(btn.node, .{ .paint = true });
                },
                .cycle => {
                    const cur = schema.get(self.root_type, self.base, b.path) catch return;
                    const n = b.ty.enum_names.len;
                    if (n == 0 or cur != .choice) return;
                    const next: u32 = @intCast((cur.choice + 1) % n);
                    if (!self.write(b, .{ .choice = next })) return;
                    b.button.?.setText(b.ty.enum_names[next]) catch {};
                },
                .presence => {
                    const present = schema.isPresent(self.root_type, self.base, b.path) catch return;
                    if (present) {
                        schema.setAbsent(self.root_type, self.base, b.path) catch return;
                    } else {
                        schema.setPresentDefault(self.root_type, self.base, b.path) catch return;
                    }
                    self.rebuild() catch {
                        self.out.failed = true;
                    };
                },
                .field => return,
            }
            self.afterChange();
        }

        fn onSubmit(self: *Self, _: *event.Event) void {
            if (self.out.valid and self.state == .open) self.state = .submitted;
        }

        fn onCancel(self: *Self, _: *event.Event) void {
            if (self.state == .open) self.state = .cancelled;
        }

        // ---- validation ----

        fn setLabel(l: *Label, text: []const u8) void {
            if (std.mem.eql(u8, l.props.text.bytes, text)) return;
            l.setText(text) catch {};
        }

        pub fn revalidate(self: *Self) void {
            var report: Report = .{};
            if (comptime @hasDecl(T, "validate")) {
                var all: Report = .{};
                T.validate(&self.value, &all);
                for (all.items[0..all.len]) |it| if (self.pathInPage(it.path)) report.add(it.path, it.message);
            }

            var valid = report.len == 0;
            for (self.bindings.items) |b| {
                const msg = b.parse_error orelse report.forPath(b.path);
                if (msg != null) valid = false;
                if (b.err) |l| setLabel(l, msg orelse "");
            }
            // Messages for paths with no control (or "" for the whole form).
            var general: []const u8 = "";
            for (report.items[0..report.len]) |it| {
                var shown = false;
                for (self.bindings.items) |b| shown = shown or std.mem.eql(u8, b.path, it.path);
                if (!shown) {
                    general = it.message;
                    break;
                }
            }
            if (self.form_error) |l| setLabel(l, general);
            self.out.valid = valid;
            if (self.submit) |sb| sb.setEnabled(valid);
            if (self.notify) |cb| {
                var ev: event.Event = .{ .kind = .command };
                cb.invoke(&ev);
            }
        }
    };
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

const Level = enum { low, medium, high };

const Margins = struct {
    top: u8 = 1,
    bottom: u8 = 2,
};

const Project = struct {
    name: []const u8 = "untitled",
    count: u8 = 3,
    scale: f32 = 1.5,
    shared: bool = false,
    level: Level = .medium,
    accent: Color = Color.rgb(10, 20, 30),
    width: Length = .auto,
    margins: Margins = .{},
    limit: ?u32 = null,
    extra: ?Margins = null,
    sizes: [2]u16 = .{ 8, 9 },
    secret: u32 = 7,
    on_done: ?*const fn () void = null,

    pub const ui = .{
        .count = .{ .label = "How many", .min = 1, .max = 9 },
        .secret = .{ .hidden = true },
    };

    pub fn validate(self: *const Project, report: *Report) void {
        if (self.name.len == 0) report.add("name", "Name is required");
        if (self.shared and self.level == .low) report.add("", "Shared projects need a higher level");
    }
};

fn clickBinding(b: anytype) void {
    var ev: event.Event = .{ .kind = .pointer_up };
    b.button.?.props.on_click.?.invoke(&ev);
}

/// The control for `path` (not the "Set" toggle of an optional).
fn findBinding(f: anytype, path: []const u8) @TypeOf(f.bindings.items[0]) {
    for (f.bindings.items) |b| if (b.kind != .presence and std.mem.eql(u8, b.path, path)) return b;
    @panic("no binding for path");
}

fn findPresence(f: anytype, path: []const u8) @TypeOf(f.bindings.items[0]) {
    for (f.bindings.items) |b| if (b.kind == .presence and std.mem.eql(u8, b.path, path)) return b;
    @panic("no presence toggle for path");
}

fn typeInto(ui: *Ui, fld: *TextField, text: []const u8) void {
    ui.setFocus(fld.node);
    // Replace the whole content.
    ui.key(.a, .{ .ctrl = true }, true, false);
    if (text.len == 0) ui.key(.backspace, .{}, true, false) else ui.textInput(text);
}

test "a form shows one control per supported field and skips hidden and callback ones" {
    var ui = try Ui.init(testing.allocator);
    defer ui.deinit();
    const f = try Form(Project).create(&ui, ui.tree.root, .{ .title = "Project" });
    defer f.destroy();
    const have = [_][]const u8{ "name", "count", "scale", "shared", "level", "accent", "width", "margins.top", "margins.bottom", "sizes[0]", "sizes[1]" };
    for (have) |p| _ = findBinding(f, p);
    _ = findPresence(f, "limit");
    _ = findPresence(f, "extra");
    for (f.bindings.items) |b| {
        try testing.expect(!std.mem.eql(u8, b.path, "secret"));
        try testing.expect(!std.mem.eql(u8, b.path, "on_done"));
        try testing.expect(!std.mem.eql(u8, b.path, "extra.top")); // absent optional: no controls yet
    }
}

test "initial text comes from the field defaults, formatted per kind" {
    var ui = try Ui.init(testing.allocator);
    defer ui.deinit();
    const f = try Form(Project).create(&ui, ui.tree.root, .{});
    defer f.destroy();
    try testing.expectEqualStrings("untitled", findBinding(f, "name").field.?.text());
    try testing.expectEqualStrings("3", findBinding(f, "count").field.?.text());
    try testing.expectEqualStrings("1.5", findBinding(f, "scale").field.?.text());
    try testing.expectEqualStrings("#0a141eff", findBinding(f, "accent").field.?.text());
    try testing.expectEqualStrings("auto", findBinding(f, "width").field.?.text());
    try testing.expectEqualStrings("Off", findBinding(f, "shared").button.?.props.text.bytes);
    try testing.expectEqualStrings("medium", findBinding(f, "level").button.?.props.text.bytes);
}

test "typing parses into the value; bad input blocks submit and shows a message" {
    var ui = try Ui.init(testing.allocator);
    defer ui.deinit();
    const f = try Form(Project).create(&ui, ui.tree.root, .{});
    defer f.destroy();

    typeInto(&ui, findBinding(f, "count").field.?, "7");
    try testing.expectEqual(@as(u8, 7), f.value.count);
    try testing.expect(f.out.valid and f.out.changed);

    typeInto(&ui, findBinding(f, "count").field.?, "12"); // above the ui max of 9
    try testing.expectEqual(@as(u8, 7), f.value.count);
    try testing.expect(!f.out.valid);
    try testing.expectEqualStrings("Out of range", findBinding(f, "count").err.?.props.text.bytes);
    try testing.expect(!f.submit.?.props.enabled);

    typeInto(&ui, findBinding(f, "count").field.?, "abc");
    try testing.expectEqualStrings("Enter a number", findBinding(f, "count").err.?.props.text.bytes);

    typeInto(&ui, findBinding(f, "count").field.?, "4");
    try testing.expect(f.out.valid);
    try testing.expectEqualStrings("", findBinding(f, "count").err.?.props.text.bytes);
    try testing.expect(f.submit.?.props.enabled);

    typeInto(&ui, findBinding(f, "accent").field.?, "#ff8000");
    try testing.expectEqual(Color.rgb(255, 128, 0), f.value.accent);
    typeInto(&ui, findBinding(f, "width").field.?, "40%");
    try testing.expectEqual(@as(f32, 40), f.value.width.percent);
    typeInto(&ui, findBinding(f, "scale").field.?, "2.25");
    try testing.expectEqual(@as(f32, 2.25), f.value.scale);
    typeInto(&ui, findBinding(f, "sizes[1]").field.?, "70000"); // overflows u16
    try testing.expectEqual(@as(u16, 9), f.value.sizes[1]);
    try testing.expect(!f.out.valid);
}

test "toggles and enum buttons write through and update their labels" {
    var ui = try Ui.init(testing.allocator);
    defer ui.deinit();
    const f = try Form(Project).create(&ui, ui.tree.root, .{});
    defer f.destroy();
    const shared = findBinding(f, "shared");
    clickBinding(shared);
    try testing.expect(f.value.shared);
    try testing.expectEqualStrings("On", shared.button.?.props.text.bytes);
    clickBinding(shared);
    try testing.expect(!f.value.shared);

    const level = findBinding(f, "level");
    clickBinding(level);
    try testing.expectEqual(Level.high, f.value.level);
    clickBinding(level); // wraps
    try testing.expectEqual(Level.low, f.value.level);
    try testing.expectEqualStrings("low", level.button.?.props.text.bytes);
}

test "optional fields rebuild with controls when set and drop them when unset" {
    var ui = try Ui.init(testing.allocator);
    defer ui.deinit();
    const f = try Form(Project).create(&ui, ui.tree.root, .{});
    defer f.destroy();
    clickBinding(findPresence(f, "limit"));
    try testing.expectEqual(@as(?u32, 0), f.value.limit);
    typeInto(&ui, findBinding(f, "limit").field.?, "25");
    try testing.expectEqual(@as(?u32, 25), f.value.limit);

    clickBinding(findPresence(f, "extra"));
    try testing.expect(f.value.extra != null);
    typeInto(&ui, findBinding(f, "extra.bottom").field.?, "5");
    try testing.expectEqual(@as(u8, 5), f.value.extra.?.bottom);

    clickBinding(findPresence(f, "extra"));
    try testing.expect(f.value.extra == null);
    for (f.bindings.items) |b| try testing.expect(!std.mem.startsWith(u8, b.path, "extra."));
}

test "validate gates submit with per-field and form-level messages" {
    var ui = try Ui.init(testing.allocator);
    defer ui.deinit();
    const f = try Form(Project).create(&ui, ui.tree.root, .{});
    defer f.destroy();
    typeInto(&ui, findBinding(f, "name").field.?, "");
    try testing.expect(!f.out.valid);
    try testing.expectEqualStrings("Name is required", findBinding(f, "name").err.?.props.text.bytes);

    typeInto(&ui, findBinding(f, "name").field.?, "demo");
    try testing.expect(f.out.valid);

    clickBinding(findBinding(f, "shared"));
    clickBinding(findBinding(f, "level")); // medium -> high
    clickBinding(findBinding(f, "level")); // -> low
    try testing.expect(!f.out.valid);
    try testing.expectEqualStrings("Shared projects need a higher level", f.form_error.?.props.text.bytes);
}

test "submit only works while valid; cancel always works" {
    var ui = try Ui.init(testing.allocator);
    defer ui.deinit();
    const f = try Form(Project).create(&ui, ui.tree.root, .{});
    defer f.destroy();
    var ev: event.Event = .{ .kind = .pointer_up };
    typeInto(&ui, findBinding(f, "name").field.?, "");
    f.submit.?.props.on_click.?.invoke(&ev);
    try testing.expect(f.state == .open);
    typeInto(&ui, findBinding(f, "name").field.?, "ok");
    f.submit.?.props.on_click.?.invoke(&ev);
    try testing.expect(f.state == .submitted);
}

test "take returns an owned copy; typed strings are form-owned and freed" {
    var ui = try Ui.init(testing.allocator);
    defer ui.deinit();
    const f = try Form(Project).create(&ui, ui.tree.root, .{});
    defer f.destroy();
    typeInto(&ui, findBinding(f, "name").field.?, "first");
    typeInto(&ui, findBinding(f, "name").field.?, "second name");
    try testing.expectEqualStrings("second name", f.value.name);
    try testing.expectEqual(@as(usize, 1), f.owned.items.len); // the earlier copy was released

    const copy = try f.take(testing.allocator);
    defer freeOwned(Project, copy, testing.allocator);
    try testing.expectEqualStrings("second name", copy.name);
    try testing.expect(copy.name.ptr != f.value.name.ptr);
}

test "createWith starts from the given value and the `only` list filters top-level fields" {
    var ui = try Ui.init(testing.allocator);
    defer ui.deinit();
    var start: Project = .{};
    start.count = 5;
    const f = try Form(Project).createWith(&ui, ui.tree.root, start, .{ .only = &.{ "count", "name" } });
    defer f.destroy();
    try testing.expectEqualStrings("5", findBinding(f, "count").field.?.text());
    try testing.expectEqual(@as(usize, 2), f.bindings.items.len);
}

test "a dynamic form edits a value in place through its schema" {
    const Live = struct {
        title: Text = .{},
        size: f32 = 0,
        on: bool = true,
    };
    var ui = try Ui.init(testing.allocator);
    defer ui.deinit();
    var live: Live = .{};
    defer ui.freeText(&live.title);
    const f = try Form(Dynamic).createDynamic(&ui, ui.tree.root, schema.typeOf(Live), &live, .{ .footer = false });
    defer f.destroy();
    const Hits = struct {
        var n: u32 = 0;
        fn hit(_: *event.Event) void {
            n += 1;
        }
    };
    Hits.n = 0;
    f.notify = event.Callback.fromFn(Hits.hit);
    typeInto(&ui, findBinding(f, "title").field.?, "Hello");
    try testing.expectEqualStrings("Hello", live.title.bytes);
    typeInto(&ui, findBinding(f, "size").field.?, "12.5");
    try testing.expectEqual(@as(f32, 12.5), live.size);
    clickBinding(findBinding(f, "on"));
    try testing.expect(!live.on);
    try testing.expect(Hits.n >= 3);
}

test "cloneOwned and freeOwned handle nesting, optionals, and arrays without leaks" {
    const Inner = struct { s: []const u8 = "", n: ?[]const u8 = null };
    const Outer = struct { a: Inner = .{}, list: [2]Inner = .{ .{}, .{} }, k: u32 = 0 };
    var o: Outer = .{ .k = 4 };
    o.a.s = "alpha";
    o.list[1].n = "beta";
    const c = try cloneOwned(Outer, o, testing.allocator);
    defer freeOwned(Outer, c, testing.allocator);
    try testing.expectEqualStrings("alpha", c.a.s);
    try testing.expectEqualStrings("beta", c.list[1].n.?);
    try testing.expect(c.a.s.ptr != o.a.s.ptr);
    try testing.expectEqual(@as(u32, 4), c.k);
}

test "cloneOwned does not leak when an allocation fails" {
    const Pair = struct { a: []const u8, b: []const u8 };
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        var fa = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = i });
        if (cloneOwned(Pair, .{ .a = "x", .b = "y" }, fa.allocator())) |ok| {
            freeOwned(Pair, ok, fa.allocator());
        } else |_| {}
    }
}

test "value text round-trips: format then parse" {
    var buf: [64]u8 = undefined;
    const c = schema.typeOf(Color);
    const text = formatValue(c, .{ .color = Color.rgba(1, 2, 3, 4) }, &buf);
    try testing.expectEqual(Color.rgba(1, 2, 3, 4), (try parseValue(c, .{}, text)).color);
    try testing.expectEqual(Color.rgb(0x11, 0x22, 0x33), (try parseValue(c, .{}, "#123")).color);
    try testing.expectError(error.BadColor, parseValue(c, .{}, "#12"));
    try testing.expectError(error.BadColor, parseValue(c, .{}, "#gggggg"));
    const l = schema.typeOf(Length);
    for ([_][]const u8{ "auto", "fill", "fit", "12", "50%" }) |s| {
        const v = try parseValue(l, .{}, s);
        try testing.expectEqualStrings(s, formatValue(l, v, &buf));
    }
    try testing.expectEqual(@as(f32, 8), (try parseValue(l, .{}, "8px")).length.pixels);
    try testing.expectError(error.BadLength, parseValue(l, .{}, "wide"));
    const n = schema.typeOf(f32);
    try testing.expectError(error.NotANumber, parseValue(n, .{}, "nan"));
    try testing.expectError(error.OutOfRange, parseValue(n, .{ .max = 1 }, "2"));
}
