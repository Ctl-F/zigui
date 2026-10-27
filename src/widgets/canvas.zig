//! Canvas: a node the app draws into and reads raw input from (design doc
//! section 9). Meant for paint programs, viewports, games, and custom widgets.
//!
//! Surface modes:
//!   1. Draw-list mode: set `props.on_draw`; it runs each time the canvas is
//!      painted and emits commands (through the `PaintCtx`) clipped to the node.
//!   2. Offscreen texture mode: `createSurface(w, h)` gives the canvas a
//!      backend-owned texture that is drawn stretched over the node (`props.filter`
//!      picks nearest or linear). The app writes pixels with `updateSurface` and
//!      the canvas repaints; nothing else is rebuilt. Call `releaseSurface` before
//!      destroying a canvas (a backend also frees leftovers when it is destroyed).
//!   3. Native-pass mode needs a GPU backend and is not available yet.
//! Both modes can be combined: the surface is drawn first, then `on_draw`.
//!
//! Redraw policy: `on_demand` repaints only on `invalidate()` or input-driven
//! changes; `continuous` repaints every frame (pace the loop with vsync);
//! `fixed_hz` repaints `props.hz` times a second. `Ui.nextWakeMs` reports when
//! the next frame is due so the event loop sleeps correctly.
//!
//! Input: `on_pointer` receives pointer enter/leave/down/move/up and wheel with
//! `local_x`/`local_y` relative to the canvas; a press captures the pointer until
//! release. `on_key` receives key down/up and committed text. With `raw_keys`
//! a focused canvas gets every key (Tab and all shortcuts included) and only
//! Escape leaves it. `grab_input` sends all pointer input to the canvas wherever
//! the pointer is. Pointer lock (hiding and confining the cursor) is a platform
//! feature and not implemented.

const std = @import("std");
const Handle = @import("../core/handle.zig").Handle;
const shadow = @import("../core/shadow.zig");
const DirtyFlags = @import("../core/dirty.zig").DirtyFlags;
const Rect = @import("../core/geometry.zig").Rect;
const Ui = @import("../core/ui.zig").Ui;
const event = @import("../core/event.zig");
const paint_ctx = @import("../core/paint_ctx.zig");
const PaintCtx = paint_ctx.PaintCtx;
const draw_list = @import("../core/draw_list.zig");
const Style = @import("../core/style.zig").Style;
const Node = @import("../core/tree.zig").Node;
const backend_mod = @import("../render/backend.zig");

pub const RedrawPolicy = enum { on_demand, continuous, fixed_hz };

/// Draws into the canvas. `pc.rect` is the canvas' rectangle in window
/// coordinates; commands are clipped to it.
pub const DrawHook = struct {
    ctx: ?*anyopaque = null,
    run: *const fn (ctx: ?*anyopaque, canvas: *Canvas, pc: *PaintCtx) paint_ctx.Error!void,

    pub const is_callback = true;

    /// `DrawHook.bind(&app, App.draw)` where `draw` is `fn (*App, *Canvas, *PaintCtx) Error!void`.
    pub fn bind(ctx: anytype, comptime f: anytype) DrawHook {
        const Ptr = @TypeOf(ctx);
        return .{
            .ctx = @ptrCast(ctx),
            .run = &struct {
                fn thunk(c: ?*anyopaque, canvas: *Canvas, pc: *PaintCtx) paint_ctx.Error!void {
                    try f(@as(Ptr, @ptrCast(@alignCast(c.?))), canvas, pc);
                }
            }.thunk,
        };
    }
};

pub const Surface = struct {
    texture: backend_mod.TextureId,
    width: u32,
    height: u32,
};

pub const Canvas = struct {
    props: Props = .{},
    out: Out = .{},
    node: Handle,
    ui: *Ui,
    checker: shadow.Checker(Props),
    surface: ?Surface = null,
    last_frame_ms: u64 = 0,
    holds_grab: bool = false,
    /// Logical-pixel region (canvas-local) invalidated since the last paint,
    /// for damage tracking; null means "all" or "nothing" per `needs_paint`.
    dirty_rect: ?Rect = null,

    pub const Props = struct {
        redraw_policy: RedrawPolicy = .on_demand,
        /// Frames per second for `fixed_hz`.
        hz: f32 = 30,
        enabled: bool = true,
        /// Every key goes to this canvas while it has focus (Escape excepted).
        raw_keys: bool = false,
        /// All pointer input goes to this canvas, wherever the pointer is.
        grab_input: bool = false,
        /// How an offscreen surface is scaled onto the node.
        filter: draw_list.ImageFilter = .linear,
        on_pointer: ?event.Callback = null,
        on_key: ?event.Callback = null,
        on_draw: ?DrawHook = null,

        pub const dirty_map = .{
            .redraw_policy = shadow.Category.paint,
            .hz = shadow.Category.paint,
            .enabled = shadow.Category.paint,
            .raw_keys = shadow.Category.none,
            .grab_input = shadow.Category.none,
            .filter = shadow.Category.paint,
        };
    };

    pub const Out = struct {
        hovered: bool = false,
        focused: bool = false,
        /// A button is held down on the canvas.
        pressed: bool = false,
        /// Last pointer position, canvas-local, in logical pixels.
        pointer_x: f32 = 0,
        pointer_y: f32 = 0,
        /// Times the canvas has been painted.
        frames: u64 = 0,
    };

    pub const Options = struct {
        style: Style = .{},
        /// Accessible name (for screen readers).
        label: []const u8 = "Canvas",
        redraw_policy: RedrawPolicy = .on_demand,
        hz: f32 = 30,
        enabled: bool = true,
        raw_keys: bool = false,
        grab_input: bool = false,
        filter: draw_list.ImageFilter = .linear,
        on_pointer: ?event.Callback = null,
        on_key: ?event.Callback = null,
        on_draw: ?DrawHook = null,
    };

    pub const listened_kinds = [_]event.EventKind{
        .pointer_enter, .pointer_leave, .pointer_down, .pointer_move, .pointer_up,
        .wheel,         .key_down,      .key_up,        .text_input,  .focus_in,
        .focus_out,
    };

    pub fn nodeTemplate(style: Style) Node {
        return .{
            .role = .canvas,
            .style = style,
            .flags = .{ .focusable = true, .clip_children = true, .repaint_boundary = true },
        };
    }

    pub fn init(ui: *Ui, node: Handle) Canvas {
        const props: Props = .{};
        return .{ .node = node, .ui = ui, .checker = shadow.Checker(Props).init(&props) };
    }

    pub fn deinit(self: *Canvas) void {
        if (self.holds_grab and Handle.eql(self.ui.input.grab, self.node)) self.ui.input.grab = Handle.invalid;
        // The surface belongs to the backend, which frees it with itself; see
        // `releaseSurface` for freeing it earlier.
    }

    pub fn apply(self: *Canvas, o: Options) !void {
        try self.ui.tree.setLabel(self.node, o.label);
        self.props.redraw_policy = o.redraw_policy;
        self.props.hz = o.hz;
        self.props.enabled = o.enabled;
        self.props.raw_keys = o.raw_keys;
        self.props.grab_input = o.grab_input;
        self.props.filter = o.filter;
        self.props.on_pointer = o.on_pointer;
        self.props.on_key = o.on_key;
        self.props.on_draw = o.on_draw;
        self.checker.sync(&self.props);
    }

    // ---- drawing ----

    /// Ask for a repaint (all of it, or just `rect`, canvas-local).
    pub fn invalidate(self: *Canvas, rect: ?Rect) void {
        if (rect) |r| {
            self.dirty_rect = if (self.dirty_rect) |d| unionRect(d, r) else r;
        } else {
            self.dirty_rect = null;
        }
        self.ui.tree.markDirty(self.node, DirtyFlags.paint_only);
    }

    fn unionRect(a: Rect, b: Rect) Rect {
        const x0 = @min(a.x, b.x);
        const y0 = @min(a.y, b.y);
        return .{ .x = x0, .y = y0, .w = @max(a.right(), b.right()) - x0, .h = @max(a.bottom(), b.bottom()) - y0 };
    }

    pub fn paintHook(self: *Canvas, pc: *PaintCtx) paint_ctx.Error!void {
        self.out.frames += 1;
        self.dirty_rect = null;
        if (self.surface) |s| {
            try pc.list.image(.{ .rect = pc.rect, .texture = s.texture, .filter = self.props.filter });
        }
        if (self.props.on_draw) |hook| try hook.run(hook.ctx, self, pc);
    }

    // ---- offscreen surface ----

    /// Give the canvas a `w` by `h` RGBA surface (cleared to transparent),
    /// replacing any earlier one. Needs a backend: draw one frame with
    /// `Ui.renderFrame` first, or call `Ui.setBackend`.
    pub fn createSurface(self: *Canvas, w: u32, h: u32) !void {
        const be = self.ui.backend orelse return error.NoBackend;
        const texture = try be.createTexture(.{ .width = w, .height = h });
        self.releaseSurface();
        self.surface = .{ .texture = texture, .width = w, .height = h };
        self.invalidate(null);
    }

    /// Write `rect` (surface pixels) of the surface from tightly or loosely
    /// packed RGBA8 `pixels` (rows `stride` bytes apart) and repaint.
    pub fn updateSurface(self: *Canvas, rect: backend_mod.URect, pixels: []const u8, stride: usize) !void {
        const s = self.surface orelse return error.NoSurface;
        const be = self.ui.backend orelse return error.NoBackend;
        try be.updateTexture(s.texture, rect, pixels, stride);
        // The dirty region in canvas-local logical pixels (surface stretches over the node).
        const node = self.ui.tree.get(self.node).?;
        const sx = node.rect.w / @as(f32, @floatFromInt(s.width));
        const sy = node.rect.h / @as(f32, @floatFromInt(s.height));
        self.invalidate(.{
            .x = @as(f32, @floatFromInt(rect.x)) * sx,
            .y = @as(f32, @floatFromInt(rect.y)) * sy,
            .w = @as(f32, @floatFromInt(rect.w)) * sx,
            .h = @as(f32, @floatFromInt(rect.h)) * sy,
        });
    }

    pub fn releaseSurface(self: *Canvas) void {
        if (self.surface) |s| {
            if (self.ui.backend) |be| be.destroyTexture(s.texture);
            self.surface = null;
        }
    }

    /// Convert a canvas-local logical point to surface pixels.
    pub fn toSurface(self: *Canvas, x: f32, y: f32) ?struct { x: f32, y: f32 } {
        const s = self.surface orelse return null;
        const node = self.ui.tree.get(self.node) orelse return null;
        if (node.rect.w <= 0 or node.rect.h <= 0) return null;
        return .{
            .x = x / node.rect.w * @as(f32, @floatFromInt(s.width)),
            .y = y / node.rect.h * @as(f32, @floatFromInt(s.height)),
        };
    }

    // ---- redraw policy ----

    fn frameIntervalMs(self: *const Canvas) u64 {
        const hz = if (self.props.hz > 0) self.props.hz else 1;
        return @max(@as(u64, @intFromFloat(@round(1000.0 / hz))), 1);
    }

    /// Repaint if the policy says a frame is due. True if it did.
    pub fn tick(self: *Canvas, now_ms: u64) bool {
        switch (self.props.redraw_policy) {
            .on_demand => return false,
            .continuous => {
                self.last_frame_ms = now_ms;
                self.ui.tree.markDirty(self.node, DirtyFlags.paint_only);
                return true;
            },
            .fixed_hz => {
                if (now_ms < self.last_frame_ms + self.frameIntervalMs() and self.last_frame_ms != 0) return false;
                self.last_frame_ms = now_ms;
                self.ui.tree.markDirty(self.node, DirtyFlags.paint_only);
                return true;
            },
        }
    }

    /// Milliseconds until the canvas wants its next frame; null for `on_demand`.
    pub fn msUntilFrame(self: *const Canvas, now_ms: u64) ?u64 {
        return switch (self.props.redraw_policy) {
            .on_demand => null,
            .continuous => 0,
            .fixed_hz => blk: {
                const due = self.last_frame_ms + self.frameIntervalMs();
                break :blk if (now_ms >= due) 0 else due - now_ms;
            },
        };
    }

    // ---- events ----

    pub fn handleEvent(self: *Canvas, ev: *event.Event) void {
        if (!self.props.enabled) return;
        switch (ev.kind) {
            .pointer_enter => self.out.hovered = true,
            .pointer_leave => self.out.hovered = false,
            .pointer_down => self.out.pressed = true,
            .pointer_up => self.out.pressed = false,
            .focus_in => self.out.focused = true,
            .focus_out => self.out.focused = false,
            else => {},
        }
        switch (ev.kind) {
            .pointer_enter, .pointer_leave, .pointer_down, .pointer_move, .pointer_up, .wheel => {
                self.out.pointer_x = ev.local_x;
                self.out.pointer_y = ev.local_y;
                if (self.props.on_pointer) |cb| cb.invoke(ev);
            },
            .key_down, .key_up, .text_input => {
                if (self.props.on_key) |cb| cb.invoke(ev);
            },
            else => {},
        }
    }

    pub fn prepare(self: *Canvas) void {
        const node = self.ui.tree.get(self.node).?;
        node.flags.focusable = self.props.enabled;
        node.flags.raw_keys = self.props.raw_keys and self.props.enabled;
        const want = self.props.grab_input and self.props.enabled;
        if (want and !self.holds_grab) {
            self.ui.input.grab = self.node;
            self.holds_grab = true;
        } else if (!want and self.holds_grab) {
            if (Handle.eql(self.ui.input.grab, self.node)) self.ui.input.grab = Handle.invalid;
            self.holds_grab = false;
        }
    }

    pub fn update(self: *Canvas) void {
        self.ui.verifyProps(self.node, &self.checker, &self.props, "canvas");
    }

    pub fn endFrame(self: *Canvas) void {
        _ = self;
    }
};

// ---- tests -----------------------------------------------------------------

const testing = std.testing;
const Color = @import("../core/geometry.zig").Color;
const Length = @import("../core/length.zig").Length;
const keys = @import("../core/keys.zig");
const software_backend = @import("../render/software_backend.zig");

const Rig = struct {
    ui: Ui,
    cmds: [256]draw_list.Command = undefined,
    glyphs: [64]draw_list.Glyph = undefined,
    list: draw_list.DrawList = undefined,

    fn init() !*Rig {
        const r = try testing.allocator.create(Rig);
        r.ui = try Ui.init(testing.allocator);
        r.list = draw_list.DrawList.init(&r.cmds, &r.glyphs);
        r.ui.tree.get(r.ui.tree.root).?.style = .{ .align_items = .start };
        return r;
    }

    fn deinit(self: *Rig) void {
        self.ui.deinit();
        testing.allocator.destroy(self);
    }

    fn frame(self: *Rig) !void {
        self.ui.update();
        if (self.ui.isDirty()) try self.ui.layoutAndPaint(.{ .w = 300, .h = 200 }, &self.list);
        self.ui.endFrame();
    }

    fn canvas(self: *Rig, o: Canvas.Options) !*Canvas {
        var opts = o;
        opts.style = .{ .width = Length.px(100), .height = Length.px(80), .shrink = 0 };
        return self.ui.add(Canvas, self.ui.tree.root, opts);
    }
};

const Hits = struct {
    var pointer: u32 = 0;
    var key: u32 = 0;
    var last_x: f32 = 0;
    var last_y: f32 = 0;
    var last_key: keys.Key = .unknown;
    var text: [16]u8 = undefined;
    var text_len: usize = 0;

    fn onPointer(ev: *event.Event) void {
        pointer += 1;
        last_x = ev.local_x;
        last_y = ev.local_y;
    }

    fn onKey(ev: *event.Event) void {
        key += 1;
        last_key = ev.key;
        if (ev.kind == .text_input) {
            @memcpy(text[0..ev.text.len], ev.text);
            text_len = ev.text.len;
        }
    }

    fn reset() void {
        pointer = 0;
        key = 0;
        text_len = 0;
    }
};

const DrawProbe = struct {
    calls: u32 = 0,
    fn draw(self: *DrawProbe, c: *Canvas, pc: *PaintCtx) paint_ctx.Error!void {
        self.calls += 1;
        _ = c;
        try pc.list.fillRect(.{ .x = pc.rect.x + 2, .y = pc.rect.y + 2, .w = 10, .h = 10 }, .{ .color = Color.rgb(1, 2, 3) });
    }
};

test "the draw hook runs on paint, inside the canvas clip, and counts frames" {
    const r = try Rig.init();
    defer r.deinit();
    var probe: DrawProbe = .{};
    const c = try r.canvas(.{ .on_draw = DrawHook.bind(&probe, DrawProbe.draw) });
    try r.frame();
    try testing.expectEqual(@as(u32, 1), probe.calls);
    try testing.expectEqual(@as(u64, 1), c.out.frames);
    var saw = false;
    var clip_open = false;
    for (r.list.items()) |cmd| switch (cmd) {
        .push_clip => clip_open = true,
        .fill_rect => |f| if (clip_open and f.paint == .color and std.meta.eql(f.paint.color, Color.rgb(1, 2, 3))) {
            saw = true;
        },
        else => {},
    };
    try testing.expect(saw);
    try testing.expect(r.list.isBalanced());

    // Nothing invalidated: no repaint. Invalidating repaints (and records the region).
    try r.frame();
    try testing.expectEqual(@as(u32, 1), probe.calls);
    c.invalidate(.{ .x = 5, .y = 5, .w = 10, .h = 10 });
    try testing.expect(c.dirty_rect != null);
    try r.frame();
    try testing.expectEqual(@as(u32, 2), probe.calls);
    try testing.expect(c.dirty_rect == null);
}

test "pointer events arrive in local coordinates; a press captures the drag" {
    const r = try Rig.init();
    defer r.deinit();
    Hits.reset();
    const c = try r.canvas(.{ .on_pointer = event.Callback.fromFn(Hits.onPointer) });
    try r.frame();
    const ui = &r.ui;
    ui.pointerMove(30, 20);
    try testing.expect(c.out.hovered);
    try testing.expectEqual(@as(f32, 30), Hits.last_x);
    ui.pointerButtonEx(30, 20, 1, true, 1);
    try testing.expect(c.out.pressed and c.out.focused);
    ui.pointerMove(250, 190); // far outside: still the canvas, now outside its rect
    try testing.expectEqual(@as(f32, 250), Hits.last_x);
    try testing.expectEqual(@as(f32, 190), Hits.last_y);
    ui.pointerButtonEx(250, 190, 1, false, 1);
    try testing.expect(!c.out.pressed);
    const before = Hits.pointer;
    ui.wheel(20, 20, 0, 1);
    try testing.expectEqual(before + 1, Hits.pointer);
}

test "raw keys: a focused canvas gets every key; shortcuts and Tab stay out; Escape leaves" {
    const r = try Rig.init();
    defer r.deinit();
    Hits.reset();
    const ui = &r.ui;
    const Fired = struct {
        var n: u32 = 0;
        fn run(_: *event.Event) void {
            n += 1;
        }
    };
    Fired.n = 0;
    _ = try ui.registerCommand("test.undo", .{ .run = event.Callback.fromFn(Fired.run) });
    try ui.bindShortcut("ctrl+z", "test.undo", .app, null);
    const c = try r.canvas(.{ .raw_keys = true, .on_key = event.Callback.fromFn(Hits.onKey) });
    const other = try ui.add(Canvas, ui.tree.root, .{});
    try r.frame();
    ui.setFocus(c.node);

    ui.key(.z, .{ .ctrl = true }, true, false);
    try testing.expectEqual(@as(u32, 0), Fired.n); // the shortcut never ran
    try testing.expectEqual(@as(u32, 1), Hits.key);
    try testing.expectEqual(keys.Key.z, Hits.last_key);
    ui.key(.tab, .{}, true, false);
    try testing.expect(Handle.eql(ui.focused().?, c.node)); // Tab went to the canvas
    try testing.expectEqual(@as(u32, 2), Hits.key);
    ui.textInput("é");
    try testing.expectEqualStrings("é", Hits.text[0..Hits.text_len]);

    // Escape is never swallowed.
    try testing.expect(!ui.keyHandled(.escape, .{}, true, false));

    // Without raw mode the same keys behave normally.
    c.props.raw_keys = false;
    ui.tree.markDirty(c.node, .{});
    try r.frame();
    ui.key(.z, .{ .ctrl = true }, true, false);
    try testing.expectEqual(@as(u32, 1), Fired.n);
    ui.key(.tab, .{}, true, false);
    try testing.expect(Handle.eql(ui.focused().?, other.node));
}

test "grab_input sends all pointer events to the canvas, until released" {
    const r = try Rig.init();
    defer r.deinit();
    Hits.reset();
    const ui = &r.ui;
    const btn = try ui.add(@import("button.zig").Button, ui.tree.root, .{ .style = .{ .width = Length.px(50), .height = Length.px(30), .shrink = 0 } });
    const c = try r.canvas(.{ .grab_input = true, .on_pointer = event.Callback.fromFn(Hits.onPointer) });
    try r.frame();
    const bn = ui.tree.get(btn.node).?;
    const over_button_x = bn.rect.x + 5;
    const over_button_y = bn.rect.y + 5;
    ui.pointerMove(over_button_x, over_button_y);
    try testing.expect(Hits.pointer > 0);
    try testing.expect(!btn.out.hovered); // the button never saw the pointer
    ui.pointerButtonEx(over_button_x, over_button_y, 1, true, 1);
    ui.pointerButtonEx(over_button_x, over_button_y, 1, false, 1);
    try testing.expect(!btn.out.clicked);

    c.props.grab_input = false;
    try r.frame();
    ui.pointerMove(over_button_x + 1, over_button_y + 1);
    try testing.expect(btn.out.hovered);
}

test "redraw policy: continuous and fixed_hz mark paint and report when the next frame is due" {
    const r = try Rig.init();
    defer r.deinit();
    const ui = &r.ui;
    const c = try r.canvas(.{});
    try r.frame();
    try testing.expect(ui.nextWakeMs() == null); // on demand: nothing scheduled
    try testing.expect(!ui.tick(100));
    try testing.expect(!ui.isDirty());

    c.props.redraw_policy = .continuous;
    ui.tree.markDirty(c.node, .{});
    try r.frame();
    try testing.expectEqual(@as(?u32, 0), ui.nextWakeMs());
    try testing.expect(ui.tick(200));
    try testing.expect(ui.isDirty());
    try r.frame();

    c.props.redraw_policy = .fixed_hz;
    c.props.hz = 20; // every 50 ms
    ui.tree.markDirty(c.node, .{});
    try r.frame();
    try testing.expect(ui.tick(1000)); // first frame is due immediately
    try r.frame();
    try testing.expectEqual(@as(?u32, 50), ui.nextWakeMs());
    try testing.expect(!ui.tick(1020));
    try testing.expect(!ui.isDirty());
    ui.now_ms = 1030;
    try testing.expectEqual(@as(?u32, 20), ui.nextWakeMs());
    try testing.expect(ui.tick(1050));
    try testing.expect(ui.isDirty());
}

test "offscreen surface: needs a backend, draws stretched over the node, repaints on update" {
    const r = try Rig.init();
    defer r.deinit();
    const ui = &r.ui;
    const c = try r.canvas(.{ .filter = .nearest });
    try testing.expectError(error.NoBackend, c.createSurface(2, 2));
    try testing.expectError(error.NoSurface, c.updateSurface(.{ .x = 0, .y = 0, .w = 1, .h = 1 }, &.{ 0, 0, 0, 0 }, 4));

    var sb = try software_backend.SoftwareBackend.init(testing.allocator, null);
    defer sb.deinit();
    ui.setBackend(sb.backend());
    try c.createSurface(2, 2);
    const px = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255 };
    try c.updateSurface(.{ .x = 0, .y = 0, .w = 2, .h = 2 }, &px, 8);
    try testing.expect(c.dirty_rect != null);

    ui.update();
    try ui.renderFrame(sb.backend(), &r.list, .{ .pixel_w = 300, .pixel_h = 200, .clear = Color.black });
    const img = try sb.backend().readback(testing.allocator);
    defer img.deinit(testing.allocator);
    // The 100x80 node at the origin shows a 2x2 image: quadrants red, green / blue, white.
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, img.rgba[(10 * 300 + 10) * 4 ..][0..4]);
    try testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, img.rgba[(10 * 300 + 90) * 4 ..][0..4]);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, img.rgba[(70 * 300 + 10) * 4 ..][0..4]);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 255 }, img.rgba[(10 * 300 + 150) * 4 ..][0..4]); // outside the node

    // A partial update dirties only the matching region, in canvas coordinates.
    try c.updateSurface(.{ .x = 1, .y = 1, .w = 1, .h = 1 }, &.{ 9, 9, 9, 255 }, 4);
    try testing.expectEqual(@as(f32, 50), c.dirty_rect.?.x);
    try testing.expectEqual(@as(f32, 40), c.dirty_rect.?.y);
    const p = c.toSurface(75, 20).?;
    try testing.expectEqual(@as(f32, 1.5), p.x);
    try testing.expectEqual(@as(f32, 0.5), p.y);
    c.releaseSurface();
    try testing.expect(c.surface == null);
}

test "a disabled canvas is inert and leaves the tab order" {
    const r = try Rig.init();
    defer r.deinit();
    Hits.reset();
    const c = try r.canvas(.{ .enabled = false, .on_pointer = event.Callback.fromFn(Hits.onPointer) });
    try r.frame();
    r.ui.pointerMove(10, 10);
    r.ui.pointerButtonEx(10, 10, 1, true, 1);
    try testing.expectEqual(@as(u32, 0), Hits.pointer);
    try testing.expect(r.ui.focused() == null);
    try testing.expect(!r.ui.tree.get(c.node).?.flags.focusable);
}
