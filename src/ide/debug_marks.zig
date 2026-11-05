//! What the debugger draws in the editors: a mark in the gutter for each
//! breakpoint (solid, hollow when the adapter could not place it, dim when
//! disabled, a diamond when it has a condition), an arrow and a tinted line where
//! the program is stopped, and a hidden tracker per breakpoint so a breakpoint
//! stays on its line of code while you edit above it. No session or UI of its
//! own: it reads a `Session` and writes to the open documents' editors.
//!
//!     debug_marks.sync(gpa, docs, &project, session);    // after any debugger change
//!     if (debug_marks.drift(gpa, docs, &project, session)) ...;   // every loop iteration: breakpoints moved by edits
//!
//! Editor slots used: gutter marks 1 (breakpoints) and 2 (the arrow), decorations
//! 4 (trackers) and 5 (the execution line).

const std = @import("std");
const CodeEditor = @import("../widgets/code_editor.zig").CodeEditor;
const Decoration = @import("../widgets/code_editor.zig").Decoration;
const Mark = @import("../widgets/code_editor.zig").Mark;
const documents = @import("documents.zig");
const project_mod = @import("project.zig");
const session_mod = @import("dap/session.zig");

pub const mark_owner_breakpoints = 1;
pub const mark_owner_arrow = 2;
pub const deco_owner_trackers = 4;
pub const deco_owner_exec = 5;

fn absOf(gpa: std.mem.Allocator, project: *const project_mod.Project, path: []const u8) ?[]u8 {
    if (std.fs.path.isAbsolute(path)) return gpa.dupe(u8, path) catch null;
    return project.absPath(gpa, path) catch null;
}

fn lessLine(_: void, a: u32, b: u32) bool {
    return a < b;
}

/// The lines (1-based, ascending) of `session`'s breakpoints in file `abs`.
fn linesOf(gpa: std.mem.Allocator, session: *const session_mod.Session, abs: []const u8) !std.ArrayListUnmanaged(u32) {
    var lines: std.ArrayListUnmanaged(u32) = .empty;
    errdefer lines.deinit(gpa);
    for (session.breakpoints.items) |b| {
        if (std.mem.eql(u8, b.file, abs)) try lines.append(gpa, b.line);
    }
    std.mem.sort(u32, lines.items, {}, lessLine);
    return lines;
}

fn kindOf(b: session_mod.Breakpoint) @import("../widgets/code_editor.zig").MarkKind {
    if (!b.enabled) return .breakpoint_disabled;
    // Only a debugging session can say it could not place one.
    if (b.verified == .unverified) return .breakpoint_unverified;
    if (b.condition.len > 0) return .breakpoint_conditional;
    return .breakpoint;
}

/// Redraw the breakpoint marks, the stop arrow and line, and the trackers of every open document.
pub fn sync(gpa: std.mem.Allocator, docs: *documents.Documents, project: *const project_mod.Project, session: *const session_mod.Session) void {
    // Where the program is stopped, if it is.
    var stop_path: ?[]u8 = null;
    defer if (stop_path) |p| gpa.free(p);
    var stop_line: u32 = 0;
    if (session.state == .stopped and session.selected < session.frames.len) {
        const f = session.frames[session.selected];
        if (f.path.len > 0 and f.line > 0) {
            stop_path = absOf(gpa, project, f.path);
            stop_line = f.line;
        }
    }
    for (docs.docs.items) |doc| {
        const ed = doc.editor;
        const abs = absOf(gpa, project, doc.path) orelse continue;
        defer gpa.free(abs);
        const text = &ed.core().doc;

        var marks: std.ArrayListUnmanaged(Mark) = .empty;
        defer marks.deinit(gpa);
        var trackers: std.ArrayListUnmanaged(Decoration) = .empty;
        defer trackers.deinit(gpa);
        // Trackers must be sorted by position, like the lines.
        var sorted = linesOf(gpa, session, abs) catch continue;
        defer sorted.deinit(gpa);
        for (sorted.items) |line| {
            if (line == 0 or line > text.lineCount()) continue;
            for (session.breakpoints.items) |b| {
                if (b.line == line and std.mem.eql(u8, b.file, abs)) {
                    marks.append(gpa, .{ .line = line - 1, .kind = kindOf(b) }) catch {};
                    break;
                }
            }
            const ls = text.lineStart(line - 1);
            trackers.append(gpa, .{ .start = ls, .end = @min(ls + 1, text.len()), .kind = .tracker }) catch {};
        }
        ed.setGutterMarks(mark_owner_breakpoints, marks.items) catch {};
        if (trackers.items.len == 0) ed.clearDecorations(deco_owner_trackers) else ed.setDecorations(deco_owner_trackers, trackers.items) catch {};

        // The arrow and the tinted line.
        const here = if (stop_path) |sp| std.mem.eql(u8, sp, abs) else false;
        if (here and stop_line >= 1 and stop_line <= text.lineCount()) {
            ed.setGutterMarks(mark_owner_arrow, &.{.{ .line = stop_line - 1, .kind = .arrow }}) catch {};
            const ls = text.lineStart(stop_line - 1);
            ed.setDecorations(deco_owner_exec, &.{.{ .start = ls, .end = @max(text.lineEnd(stop_line - 1), ls + 1), .kind = .exec_line }}) catch {};
        } else {
            ed.clearGutterMarks(mark_owner_arrow);
            ed.clearDecorations(deco_owner_exec);
        }
    }
}

/// Move breakpoints whose tracked line changed because of edits. True if any moved.
pub fn drift(gpa: std.mem.Allocator, docs: *documents.Documents, project: *const project_mod.Project, session: *session_mod.Session) bool {
    var moved = false;
    for (docs.docs.items) |doc| {
        const ed = doc.editor;
        const trackers = ed.decos[deco_owner_trackers].items;
        if (trackers.len == 0) continue;
        const abs = absOf(gpa, project, doc.path) orelse continue;
        defer gpa.free(abs);
        var sorted = linesOf(gpa, session, abs) catch continue;
        defer sorted.deinit(gpa);
        // Only when the lists still describe each other (a debugger change redraws them first).
        if (sorted.items.len != trackers.len) continue;
        const text = &ed.core().doc;
        // Compute every new line first: moving one breakpoint must not confuse the next.
        var targets = gpa.alloc(u32, trackers.len) catch continue;
        defer gpa.free(targets);
        for (trackers, 0..) |t, i| targets[i] = @intCast(text.lineOfOffset(@min(t.start, text.len())) + 1);
        for (sorted.items, targets) |from, to| {
            if (from == to) continue;
            session.moveBreakpoint(abs, from, to);
            moved = true;
        }
    }
    return moved;
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;
const Rig = @import("../core/test_rig.zig").Rig;
const Dock = @import("../widgets/dock.zig").Dock;

fn noSend(_: ?*anyopaque, _: []const u8) void {}

test "breakpoints show as marks with their state, the stop shows an arrow and a tinted line, and edits move breakpoints" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var p = try project_mod.testProject(&tmp);
    defer p.close();
    try p.writeFile("src/main.zig", "line one\nline two\nline three\nline four\n");
    const r = try Rig.init();
    defer r.deinit();
    const dock = try Dock.create(&r.ui, r.ui.tree.root, .{ .style = .{ .grow = 1 } });
    const welcome = try dock.addPanel("Welcome");
    try dock.dockTab(welcome, null);
    const docs = try documents.Documents.create(&r.ui, dock, &p, testing.io, .{ .anchor = welcome });
    defer docs.destroy();
    const doc = try docs.open("src/main.zig", 1, 1);
    try r.frame();

    const s = try session_mod.Session.create(testing.allocator, .{ .call = noSend });
    defer s.destroy();
    const abs = try p.absPath(testing.allocator, "src/main.zig");
    defer testing.allocator.free(abs);
    try s.setBreakpoint(abs, 2, true, "");
    try s.setBreakpoint(abs, 4, true, "n > 1");
    sync(testing.allocator, docs, &p, s);
    try testing.expectEqual(@as(usize, 2), doc.editor.marks[mark_owner_breakpoints].items.len);
    try testing.expect(doc.editor.marks[mark_owner_breakpoints].items[0].kind == .breakpoint);
    try testing.expectEqual(@as(usize, 1), doc.editor.marks[mark_owner_breakpoints].items[0].line);
    try testing.expect(doc.editor.marks[mark_owner_breakpoints].items[1].kind == .breakpoint_conditional);
    try testing.expectEqual(@as(usize, 2), doc.editor.decos[deco_owner_trackers].items.len);

    // A disabled breakpoint is dim; one the adapter could not place is hollow.
    try s.setBreakpoint(abs, 2, false, "");
    sync(testing.allocator, docs, &p, s);
    try testing.expect(doc.editor.marks[mark_owner_breakpoints].items[0].kind == .breakpoint_disabled);
    s.breakpoints.items[1].verified = .unverified;
    sync(testing.allocator, docs, &p, s);
    try testing.expect(doc.editor.marks[mark_owner_breakpoints].items[1].kind == .breakpoint_unverified);

    // Stopped on line 3: an arrow and a tinted line, in the file that is open.
    const a = s.snap.allocator();
    const frames = try a.alloc(session_mod.Frame, 1);
    frames[0] = .{ .id = 1, .name = "main", .path = abs, .line = 3, .column = 1 };
    s.frames = frames;
    s.state = .stopped;
    sync(testing.allocator, docs, &p, s);
    try testing.expectEqual(@as(usize, 2), doc.editor.marks[mark_owner_arrow].items[0].line);
    try testing.expect(doc.editor.decos[deco_owner_exec].items[0].kind == .exec_line);
    s.state = .running;
    s.frames = &.{};
    sync(testing.allocator, docs, &p, s);
    try testing.expectEqual(@as(usize, 0), doc.editor.marks[mark_owner_arrow].items.len);

    // Insert a line above both breakpoints: the tracked lines move, and so do the breakpoints.
    r.ui.setFocus(doc.editor.node);
    doc.editor.core().setCaret(0, false);
    r.ui.key(.enter, .{}, true, false); // a real edit: the editor moves its decorations
    try r.frame();
    try testing.expect(drift(testing.allocator, docs, &p, s));
    try testing.expectEqual(@as(u32, 3), s.breakpoints.items[0].line);
    try testing.expectEqual(@as(u32, 5), s.breakpoints.items[1].line);
    try testing.expect(!drift(testing.allocator, docs, &p, s)); // nothing more to move
}
