//! A Ui with test fonts for the IDE panels' tests.

const std = @import("std");
const Ui = @import("../core/ui.zig").Ui;
const draw_list = @import("../core/draw_list.zig");
const font = @import("../text/font.zig");

pub const Rig = struct {
    ui: Ui,
    cmds: [8192]draw_list.Command = undefined,
    glyphs: [8192]draw_list.Glyph = undefined,
    list: draw_list.DrawList = undefined,
    prop: font.TestFont = .{},
    mono: font.TestFont = .{ .monospace = true },

    pub fn init() !*Rig {
        const r = try std.testing.allocator.create(Rig);
        r.* = .{ .ui = try Ui.init(std.testing.allocator) };
        _ = try r.ui.addFont(r.prop.backend());
        r.ui.theme.mono_font = try r.ui.addFont(r.mono.backend());
        r.list = draw_list.DrawList.init(&r.cmds, &r.glyphs);
        r.ui.tree.get(r.ui.tree.root).?.style = .{ .direction = .column };
        return r;
    }

    pub fn deinit(self: *Rig) void {
        self.ui.deinit();
        std.testing.allocator.destroy(self);
    }

    pub fn frame(self: *Rig) !void {
        self.ui.update();
        try self.ui.layoutAndPaint(.{ .w = 800, .h = 600 }, &self.list);
        self.ui.endFrame();
    }
};
