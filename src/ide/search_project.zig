//! Find in project: search every text file under a project for a string, on a
//! worker thread, streaming the hits to the UI thread. No UI here.
//!
//!     const s = try Searcher.start(gpa, &project, "needle", .{}, sdl.wake);
//!     defer s.destroy();
//!     // each loop iteration:
//!     var batch: std.ArrayListUnmanaged(Event) = .empty;
//!     s.drain(&batch);
//!     for (batch.items) |*e| { ... e.deinit(gpa); }
//!     batch.clearRetainingCapacity();
//!
//! Skips the folders `project.excluded` lists, binary files (a NUL byte in the
//! first 8 KiB) and files over 4 MiB. Matching is `editor/search.zig`'s, line by
//! line. `cancel` (or starting a new search and destroying this one) stops it.

const std = @import("std");
const worker = @import("../core/worker.zig");
const search = @import("../editor/search.zig");
const project_mod = @import("project.zig");
const Project = project_mod.Project;

pub const Hit = struct {
    /// Project-relative path ('/' separators). Owned by the event.
    path: []u8,
    /// 1-based line, 1-based column (in bytes) of the match.
    line: u32,
    col: u32,
    /// The line's text (trimmed of leading whitespace, cut to 200 bytes). Owned.
    text: []u8,
};

pub const Summary = struct {
    files: u32,
    hits: u32,
    /// Stopped at `max_hits`.
    truncated: bool,
    cancelled: bool,
};

pub const Event = union(enum) {
    hit: Hit,
    done: Summary,

    pub fn deinit(self: *Event, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .hit => |h| {
                gpa.free(h.path);
                gpa.free(h.text);
            },
            .done => {},
        }
    }
};

pub const max_hits = 5000;
const max_file = 4 * 1024 * 1024;

pub const Searcher = struct {
    gpa: std.mem.Allocator,
    project: *const Project,
    query: []u8,
    opts: search.Options,
    queue: worker.Queue(Event),
    thread: ?std.Thread = null,
    cancelled: std.atomic.Value(bool) = .init(false),
    finished_flag: std.atomic.Value(bool) = .init(false),

    pub fn start(gpa: std.mem.Allocator, project: *const Project, query: []const u8, opts: search.Options, wake: ?*const fn () void) !*Searcher {
        const self = try gpa.create(Searcher);
        errdefer gpa.destroy(self);
        const q = try gpa.dupe(u8, query);
        errdefer gpa.free(q);
        self.* = .{ .gpa = gpa, .project = project, .query = q, .opts = opts, .queue = .{ .gpa = gpa, .wake = wake } };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    pub fn cancel(self: *Searcher) void {
        self.cancelled.store(true, .release);
    }

    pub fn drain(self: *Searcher, out: *std.ArrayListUnmanaged(Event)) void {
        self.queue.drain(out);
    }

    pub fn finished(self: *const Searcher) bool {
        return self.finished_flag.load(.acquire);
    }

    pub fn destroy(self: *Searcher) void {
        self.cancel();
        if (self.thread) |t| t.join();
        var left: std.ArrayListUnmanaged(Event) = .empty;
        self.queue.drain(&left);
        for (left.items) |*e| e.deinit(self.gpa);
        left.deinit(self.gpa);
        self.queue.deinit();
        self.gpa.free(self.query);
        self.gpa.destroy(self);
    }

    fn run(self: *Searcher) void {
        var summary: Summary = .{ .files = 0, .hits = 0, .truncated = false, .cancelled = false };
        self.walk(&summary) catch {};
        summary.cancelled = self.cancelled.load(.acquire);
        self.queue.push(.{ .done = summary }) catch {};
        self.finished_flag.store(true, .release);
    }

    fn walk(self: *Searcher, summary: *Summary) !void {
        if (self.query.len == 0) return;
        const io = self.project.io;
        var walker = try self.project.dir.walkSelectively(self.gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (self.cancelled.load(.acquire) or summary.truncated) return;
            switch (entry.kind) {
                .directory => if (!project_mod.isExcludedName(entry.basename)) walker.enter(io, entry) catch {},
                .file => self.searchFile(entry.path, summary),
                else => {},
            }
        }
    }

    fn searchFile(self: *Searcher, rel: []const u8, summary: *Summary) void {
        const bytes = self.project.readFile(self.gpa, rel, max_file) catch return;
        defer self.gpa.free(bytes);
        if (std.mem.indexOfScalar(u8, bytes[0..@min(bytes.len, 8192)], 0) != null) return;
        summary.files += 1;
        var line_no: u32 = 0;
        var it = std.mem.splitScalar(u8, bytes, '\n');
        while (it.next()) |line_raw| {
            line_no += 1;
            const line = std.mem.trimEnd(u8, line_raw, "\r");
            var at: usize = 0;
            while (search.indexIn(line, self.query, at, self.opts)) |s| {
                if (summary.hits >= max_hits) {
                    summary.truncated = true;
                    return;
                }
                self.post(rel, line_no, @intCast(s + 1), line);
                summary.hits += 1;
                at = s + self.query.len;
            }
            if (self.cancelled.load(.acquire)) return;
        }
    }

    fn post(self: *Searcher, rel: []const u8, line: u32, col: u32, text: []const u8) void {
        const trimmed = std.mem.trimStart(u8, text, " \t");
        const shown = trimmed[0..@min(trimmed.len, 200)];
        const path = self.gpa.dupe(u8, rel) catch return;
        const t = self.gpa.dupe(u8, shown) catch {
            self.gpa.free(path);
            return;
        };
        for (path) |*c| {
            if (c.* == '\\') c.* = '/';
        }
        self.queue.push(.{ .hit = .{ .path = path, .line = line, .col = col, .text = t } }) catch {
            self.gpa.free(path);
            self.gpa.free(t);
        };
    }
};

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

fn collect(s: *Searcher, out: *std.ArrayListUnmanaged(Event)) !void {
    var tries: usize = 0;
    while (!s.finished() and tries < 3000) : (tries += 1) {
        s.drain(out);
        var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 1_000_000 };
        _ = std.os.linux.nanosleep(&ts, null);
    }
    s.drain(out);
    try testing.expect(s.finished());
}

fn freeEvents(list: *std.ArrayListUnmanaged(Event)) void {
    for (list.items) |*e| e.deinit(testing.allocator);
    list.deinit(testing.allocator);
}

test "search finds matches in text files, skips excluded folders and binaries, and reports positions" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var p = try project_mod.testProject(&tmp);
    defer p.close();
    const s = try Searcher.start(testing.allocator, &p, "std", .{}, null);
    defer s.destroy();
    var events: std.ArrayListUnmanaged(Event) = .empty;
    defer freeEvents(&events);
    try collect(s, &events);

    var hits: usize = 0;
    var saw_main = false;
    var saw_readme = false;
    var summary: ?Summary = null;
    for (events.items) |e| switch (e) {
        .hit => |h| {
            hits += 1;
            try testing.expect(std.mem.indexOf(u8, h.path, ".git") == null);
            try testing.expect(std.mem.indexOf(u8, h.path, "zig-out") == null);
            try testing.expect(!std.mem.eql(u8, h.path, "blob.bin"));
            if (std.mem.eql(u8, h.path, "src/main.zig")) {
                saw_main = true;
                try testing.expectEqual(@as(u32, 1), h.line);
                try testing.expect(h.col == 7 or h.col == 22); // `const std` and `@import("std")`
                try testing.expectEqualStrings("const std = @import(\"std\");", h.text);
            }
            if (std.mem.eql(u8, h.path, "README.md")) saw_readme = true; // "STD": case-insensitive
        },
        .done => |d| summary = d,
    };
    // main.zig has two on line 1, a.zig one, README one.
    try testing.expectEqual(@as(usize, 4), hits);
    try testing.expect(saw_main and saw_readme);
    try testing.expect(summary != null and !summary.?.cancelled and !summary.?.truncated);
    try testing.expectEqual(@as(u32, 4), summary.?.hits);

    // Case-sensitive and whole-word narrow it.
    const s2 = try Searcher.start(testing.allocator, &p, "std", .{ .case_sensitive = true, .whole_word = true }, null);
    defer s2.destroy();
    var ev2: std.ArrayListUnmanaged(Event) = .empty;
    defer freeEvents(&ev2);
    try collect(s2, &ev2);
    var n2: usize = 0;
    for (ev2.items) |e| if (e == .hit) {
        n2 += 1;
    };
    try testing.expectEqual(@as(usize, 3), n2);
}

test "an empty query finds nothing and cancel stops early" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var p = try project_mod.testProject(&tmp);
    defer p.close();
    const s = try Searcher.start(testing.allocator, &p, "", .{}, null);
    defer s.destroy();
    var events: std.ArrayListUnmanaged(Event) = .empty;
    defer freeEvents(&events);
    try collect(s, &events);
    try testing.expectEqual(@as(usize, 1), events.items.len);
    try testing.expect(events.items[0] == .done and events.items[0].done.hits == 0);

    const s2 = try Searcher.start(testing.allocator, &p, "e", .{}, null);
    s2.cancel();
    s2.destroy(); // joins; must not hang or leak
}
