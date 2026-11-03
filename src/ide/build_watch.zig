//! Continuous error checking from the compiler itself: run `zig build --watch`
//! (with `-fincremental`, so a rebuild after an edit recompiles only what the
//! edit touched) in the background and turn each rebuild's errors into a list
//! of located diagnostics the IDE can show as squiggles and in a Problems panel.
//! No UI here.
//!
//!     const w = try Watcher.start(gpa, io, project.root, .{ .incremental = true, .wake = sdl.wake });
//!     defer w.destroy();
//!     // each loop iteration:
//!     if (w.poll()) {
//!         const r = w.latest().?;         // the newest finished rebuild
//!         for (r.diags) |d| { d.path; d.line; d.col; d.len; d.severity; d.message; }
//!     }
//!
//! Where this beats the language server: zls reports syntax and `ast-check`
//! errors; the compiler also reports type errors, missing arguments and the rest
//! of semantic analysis, for the build graph as it is actually configured. What it
//! costs: it builds (and installs) your project each time you save, and only
//! files the build reaches are checked.
//!
//! A rebuild's output ends with a `Build Summary:` line (also when nothing
//! failed), so the diagnostics printed since the previous summary are one result,
//! and a result with none means "everything compiles". Compile errors look like
//!
//!     src/main.zig:2:20: error: expected type 'u32', found '*const [2:0]u8'
//!         const x: u32 = "no";
//!                        ^~~~
//!
//! and the `^~~~` line gives the length of the underline.

const std = @import("std");
const process = @import("../platform/process.zig");
const buildout = @import("buildout.zig");

pub const Severity = enum { err, warning };

pub const Diag = struct {
    /// Project-relative, '/' separators.
    path: []const u8,
    /// 1-based line and byte column of the start.
    line: u32,
    col: u32,
    /// Bytes to underline (at least 1).
    len: u32,
    severity: Severity,
    message: []const u8,
};

/// One finished rebuild.
pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    diags: []Diag,
    /// 1 for the first result, counting up.
    seq: u32,

    pub fn errors(self: *const Result) usize {
        var n: usize = 0;
        for (self.diags) |d| {
            if (d.severity == .err) n += 1;
        }
        return n;
    }

    pub fn warnings(self: *const Result) usize {
        return self.diags.len - self.errors();
    }

    pub fn deinit(self: *Result) void {
        self.arena.deinit();
    }
};

/// Splits build output into rebuilds. Feed it bytes as they arrive.
pub const Collector = struct {
    gpa: std.mem.Allocator,
    /// Absolute project folder, to make paths project-relative.
    root: []const u8,
    partial: [2]std.ArrayListUnmanaged(u8) = .{ .empty, .empty },
    pending: std.ArrayListUnmanaged(Diag) = .empty,
    arena: std.heap.ArenaAllocator,
    /// Lines still to read after a diagnostic: its source line, then the `^~~` line.
    expect: u8 = 0,
    /// Index into `pending` the caret line belongs to (null for notes).
    caret_for: ?usize = null,
    seq: u32 = 0,
    /// Finished results waiting to be taken.
    done: std.ArrayListUnmanaged(*Result) = .empty,

    pub fn init(gpa: std.mem.Allocator, root: []const u8) Collector {
        return .{ .gpa = gpa, .root = root, .arena = .init(gpa) };
    }

    pub fn deinit(self: *Collector) void {
        for (&self.partial) |*p| p.deinit(self.gpa);
        self.pending.deinit(self.gpa);
        self.arena.deinit();
        for (self.done.items) |r| {
            r.deinit();
            self.gpa.destroy(r);
        }
        self.done.deinit(self.gpa);
    }

    /// Bytes from stream `which` (0 stdout, 1 stderr).
    pub fn feed(self: *Collector, which: usize, bytes: []const u8) !void {
        const buf = &self.partial[which];
        try buf.appendSlice(self.gpa, bytes);
        while (std.mem.indexOfScalar(u8, buf.items, '\n')) |nl| {
            try self.line(buf.items[0..nl]);
            const rest = buf.items[nl + 1 ..];
            std.mem.copyForwards(u8, buf.items[0..rest.len], rest);
            buf.shrinkRetainingCapacity(rest.len);
        }
    }

    fn line(self: *Collector, raw: []const u8) !void {
        var clean: std.ArrayListUnmanaged(u8) = .empty;
        defer clean.deinit(self.gpa);
        try buildout.stripAnsi(self.gpa, &clean, raw);
        const text = std.mem.trimEnd(u8, clean.items, "\r");

        if (std.mem.startsWith(u8, text, "Build Summary:")) return self.publish();

        if (self.expect > 0) {
            self.expect -= 1;
            if (self.expect == 1) return; // the source line
            // The caret line.
            if (self.caret_for) |i| {
                const t = std.mem.trimStart(u8, text, " ");
                if (t.len > 0 and t[0] == '^') {
                    var n: u32 = 1;
                    while (n < t.len and t[n] == '~') n += 1;
                    self.pending.items[i].len = n;
                }
            }
            self.caret_for = null;
            return;
        }

        const d = buildout.parseLine(text) orelse return;
        self.expect = 2;
        self.caret_for = null;
        if (d.severity == .note) return;
        const path = self.relative(d.path) orelse return;
        const a = self.arena.allocator();
        const msg = try a.dupe(u8, d.message);
        const p = try a.dupe(u8, path);
        for (p) |*c| {
            if (c.* == '\\') c.* = '/';
        }
        // The same diagnostic twice (several steps compile the same file) counts once.
        for (self.pending.items) |o| {
            if (o.line == d.line and o.col == d.col and std.mem.eql(u8, o.path, p) and std.mem.eql(u8, o.message, msg)) return;
        }
        try self.pending.append(self.gpa, .{
            .path = p,
            .line = d.line,
            .col = d.col,
            .len = 1,
            .severity = if (d.severity == .err) .err else .warning,
            .message = msg,
        });
        self.caret_for = self.pending.items.len - 1;
    }

    /// The project-relative form of `path` (as the compiler printed it), or null
    /// for files outside the project (the standard library, dependencies, the cache).
    fn relative(self: *Collector, path: []const u8) ?[]const u8 {
        var p = path;
        if (std.fs.path.isAbsolute(p)) {
            if (!std.mem.startsWith(u8, p, self.root)) return null;
            p = p[self.root.len..];
            p = std.mem.trimStart(u8, p, "/\\");
        }
        if (std.mem.startsWith(u8, p, "..")) return null;
        if (std.mem.startsWith(u8, p, ".zig-cache") or std.mem.startsWith(u8, p, "zig-out")) return null;
        return p;
    }

    fn publish(self: *Collector) !void {
        self.seq += 1;
        const r = try self.gpa.create(Result);
        errdefer self.gpa.destroy(r);
        r.* = .{ .arena = self.arena, .diags = try self.gpa.dupe(Diag, self.pending.items), .seq = self.seq };
        // `diags` lives with the strings; hand the arena over and start a fresh one.
        // (The slice itself came from `gpa`, so move it into the arena too.)
        const moved = try r.arena.allocator().dupe(Diag, r.diags);
        self.gpa.free(r.diags);
        r.diags = moved;
        self.arena = .init(self.gpa);
        self.pending.clearRetainingCapacity();
        self.expect = 0;
        self.caret_for = null;
        try self.done.append(self.gpa, r);
    }
};

pub const Options = struct {
    /// A build step to run (default: the default step).
    step: []const u8 = "",
    /// `-fincremental`: recompile only what an edit changed.
    incremental: bool = true,
    wake: ?*const fn () void = null,
    /// The `zig` program (default: `zig` from PATH).
    zig: []const u8 = "zig",
};

pub const Watcher = struct {
    gpa: std.mem.Allocator,
    runner: *process.Runner,
    collector: Collector,
    root: []u8,
    batch: std.ArrayListUnmanaged(process.Event) = .empty,
    current: ?*Result = null,
    /// The process ended (with this exit code, 255 if it was killed).
    exit_code: ?u8 = null,
    results: u32 = 0,

    pub fn start(gpa: std.mem.Allocator, io: std.Io, root: []const u8, opts: Options) !*Watcher {
        const self = try gpa.create(Watcher);
        errdefer gpa.destroy(self);
        const r = try gpa.dupe(u8, root);
        errdefer gpa.free(r);
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.appendSlice(gpa, &.{ opts.zig, "build", "--watch", "--color", "off" });
        if (opts.incremental) try argv.append(gpa, "-fincremental");
        if (opts.step.len > 0) try argv.append(gpa, opts.step);
        const runner = try process.Runner.start(gpa, io, .{ .argv = argv.items, .cwd = root, .wake = opts.wake });
        self.* = .{ .gpa = gpa, .runner = runner, .collector = Collector.init(gpa, r), .root = r };
        return self;
    }

    pub fn destroy(self: *Watcher) void {
        self.runner.destroy();
        for (self.batch.items) |*e| e.deinit(self.gpa);
        self.batch.deinit(self.gpa);
        self.collector.deinit();
        if (self.current) |c| {
            c.deinit();
            self.gpa.destroy(c);
        }
        self.gpa.free(self.root);
        self.gpa.destroy(self);
    }

    pub fn running(self: *const Watcher) bool {
        return self.exit_code == null;
    }

    /// The newest finished rebuild.
    pub fn latest(self: *const Watcher) ?*const Result {
        return self.current;
    }

    /// Take in output. True when a new result arrived or the process ended.
    pub fn poll(self: *Watcher) bool {
        var changed = false;
        self.runner.drain(&self.batch);
        for (self.batch.items) |*e| {
            switch (e.*) {
                .chunk => |c| self.collector.feed(if (c.stream == .stdout) 0 else 1, c.bytes) catch {},
                .exited => |t| {
                    self.exit_code = switch (t) {
                        .exited => |code| code,
                        else => 255,
                    };
                    changed = true;
                },
            }
            e.deinit(self.gpa);
        }
        self.batch.clearRetainingCapacity();
        for (self.collector.done.items) |r| {
            if (self.current) |old| {
                old.deinit();
                self.gpa.destroy(old);
            }
            self.current = r;
            self.results += 1;
            changed = true;
        }
        self.collector.done.clearRetainingCapacity();
        return changed;
    }
};

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

const sample_failed =
    "install\n+- install w\n   +- compile exe w debug native 1 errors\n" ++
    "src/main.zig:2:20: error: expected type 'u32', found '*const [2:0]u8'\n" ++
    "    const x: u32 = \"no\";\n" ++
    "                   ^~~~\n" ++
    "referenced by:\n" ++
    "    callMain [inlined]: /home/u/.zvm/0.17.0/lib/std/start.zig:788:64\n" ++
    "/home/u/.zvm/0.17.0/lib/std/start.zig:1:1: error: should be ignored (outside the project)\n" ++
    "error: 1 compilation errors\n" ++
    "failed command: /home/u/.zvm/0.17.0/zig build-exe -Mroot=src/main.zig\n" ++
    "\nBuild Summary: 0/3 steps succeeded (1 failed)\n" ++
    "install transitive failure\n";

test "a failed rebuild gives located diagnostics with underline lengths; the next one replaces it" {
    var c = Collector.init(testing.allocator, "/proj");
    defer c.deinit();
    try c.feed(1, sample_failed);
    try testing.expectEqual(@as(usize, 1), c.done.items.len);
    const r = c.done.items[0];
    try testing.expectEqual(@as(usize, 1), r.diags.len);
    try testing.expectEqualStrings("src/main.zig", r.diags[0].path);
    try testing.expectEqual(@as(u32, 2), r.diags[0].line);
    try testing.expectEqual(@as(u32, 20), r.diags[0].col);
    try testing.expectEqual(@as(u32, 4), r.diags[0].len);
    try testing.expect(r.diags[0].severity == .err);
    try testing.expect(std.mem.startsWith(u8, r.diags[0].message, "expected type 'u32'"));
    try testing.expectEqual(@as(usize, 1), r.errors());

    // A clean rebuild: only the summary.
    try c.feed(1, "Build Summary: 3/3 steps succeeded\ninstall success\n");
    try testing.expectEqual(@as(usize, 2), c.done.items.len);
    try testing.expectEqual(@as(usize, 0), c.done.items[1].diags.len);
    try testing.expectEqual(@as(u32, 2), c.done.items[1].seq);
}

test "output may arrive in pieces, in color, with absolute paths, warnings and repeats" {
    var c = Collector.init(testing.allocator, "/proj");
    defer c.deinit();
    const text = "\x1b[1m/proj/src/a.zig:3:9\x1b[0m: \x1b[31merror:\x1b[0m use of undeclared identifier 'y'\n" ++
        "    _ = y;\n        ^\n" ++
        "/proj/src/a.zig:3:9: error: use of undeclared identifier 'y'\n    _ = y;\n        ^\n" ++
        "src/b.zig:1:1: warning: unused thing\nx\n^~\n" ++
        "src/b.zig:1:1: note: declared here\nx\n^\n" ++
        "Build Summary: 0/1 steps succeeded (1 failed)\n";
    var i: usize = 0;
    while (i < text.len) : (i += 7) try c.feed(1, text[i..@min(i + 7, text.len)]);
    try testing.expectEqual(@as(usize, 1), c.done.items.len);
    const r = c.done.items[0];
    try testing.expectEqual(@as(usize, 2), r.diags.len); // the repeat counted once, the note not at all
    try testing.expectEqualStrings("src/a.zig", r.diags[0].path);
    try testing.expectEqual(@as(u32, 1), r.diags[0].len);
    try testing.expect(r.diags[1].severity == .warning);
    try testing.expectEqual(@as(u32, 2), r.diags[1].len);
    try testing.expectEqual(@as(usize, 1), r.warnings());
}

fn sleepMs(ms: u64) void {
    @import("../platform/pty_common.zig").sleepMs(ms);
}

test "the watcher runs a program and reports its rebuild results" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    // A fake zig that prints one failing rebuild, then stays alive like `--watch`.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "fake_zig", .data = "#!/bin/sh\nprintf 'src/m.zig:4:2: error: bad\\n  x\\n  ^~~\\nBuild Summary: 0/1 steps succeeded (1 failed)\\n' >&2\nsleep 30\n" });
    try tmp.dir.setFilePermissions(testing.io, "fake_zig", .executable_file, .{});
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    const root = try testing.allocator.dupe(u8, buf[0..n]);
    defer testing.allocator.free(root);
    const fake = try std.fs.path.join(testing.allocator, &.{ root, "fake_zig" });
    defer testing.allocator.free(fake);
    const w = try Watcher.start(testing.allocator, testing.io, root, .{ .zig = fake });
    defer w.destroy();
    var tries: usize = 0;
    while (!w.poll() and tries < 3000) : (tries += 1) sleepMs(2);
    const r = w.latest().?;
    try testing.expectEqual(@as(usize, 1), r.diags.len);
    try testing.expectEqualStrings("src/m.zig", r.diags[0].path);
    try testing.expectEqual(@as(u32, 3), r.diags[0].len);
    try testing.expect(w.running());
}
