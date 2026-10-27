//! The widget interface, checked at compile time.
//!
//! A widget type `W` (such as `Button`) must declare:
//!
//!   Props, Out        app-written and toolkit-written state; `Props` may carry
//!                     a `dirty_map` for the shadow checker
//!   Options           what `Ui.add` accepts; has a `style: Style` field
//!   listened_kinds    event kinds its node listens for
//!   nodeTemplate(style) -> Node   the tree node it lives on
//!   init(ui, node) -> W, deinit(*W), apply(*W, Options) !void
//!   handleEvent(*W, *Event) void
//!   prepare(*W), update(*W), endFrame(*W)   per-frame hooks (see `Ui.update`)
//!   tick(*W, now) bool, msUntilBlink(*W, now) ?u64, caretRect(*W) ?Rect
//!                     only for widgets that have a text caret
//!
//! and have the fields `props: Props`, `out: Out`, `node: Handle`, `ui: *Ui`.
//! The comptime checker below turns a missing piece into a clear compile
//! error at `Ui.add` rather than a confusing one deep inside it. A future
//! runtime schema or widget registry can reflect over exactly this shape.

const std = @import("std");

pub fn check(comptime W: type) void {
    const required = [_][]const u8{
        "Props",         "Out",    "Options",   "listened_kinds", "nodeTemplate",
        "init",          "deinit", "apply",     "handleEvent",    "prepare",
        "update",        "endFrame",
    };
    inline for (required) |name| {
        if (!@hasDecl(W, name)) @compileError("widget " ++ @typeName(W) ++ " is missing `" ++ name ++ "`");
    }
    inline for (.{ "props", "out", "node", "ui" }) |name| {
        if (!@hasField(W, name)) @compileError("widget " ++ @typeName(W) ++ " is missing field `" ++ name ++ "`");
    }
    if (!@hasField(W.Options, "style")) @compileError("widget " ++ @typeName(W) ++ ".Options needs a `style` field");
}
