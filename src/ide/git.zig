//! Git through the `git` program: read a repository's status and diffs, stage and
//! unstage files, commit, stash and push, with the slow part on a worker thread.
//! No UI here (`git_panel.zig` is the panel).
//!
//!     const g = try Git.init(gpa, io, project.root, environ, sdl.wake);
//!     defer g.deinit();
//!     _ = g.submit(.status);                       // one job at a time
//!     // each loop iteration:
//!     if (g.poll()) |*done| { defer done.deinit(gpa); ... }
//!
//! Every command runs `git -C <project root> ...` with prompts for credentials
//! switched off (`GIT_TERMINAL_PROMPT=0`), so a push that needs a password fails
//! with a message instead of hanging a hidden terminal prompt. Credential helpers
//! and ssh agents work as in a terminal. `parseStatus` and `diffLines` are pure.

const std = @import("std");
const builtin = @import("builtin");
const worker = @import("../core/worker.zig");

// ---- status ----------------------------------------------------------------

/// One line of `git status --porcelain=v1`: index state `x`, work tree state `y`.
pub const Entry = struct {
    x: u8,
    y: u8,
    /// Relative to the repository's top folder, '/' separators.
    path: []const u8,
    /// The old name of a rename or copy.
    orig: ?[]const u8 = null,

    pub fn untracked(self: Entry) bool {
        return self.x == '?' and self.y == '?';
    }

    pub fn conflicted(self: Entry) bool {
        if (self.x == 'U' or self.y == 'U') return true;
        return (self.x == 'A' and self.y == 'A') or (self.x == 'D' and self.y == 'D');
    }

    /// Has a change in the index (staged).
    pub fn staged(self: Entry) bool {
        return !self.untracked() and !self.conflicted() and self.x != ' ' and self.x != '!';
    }

    /// Has a change in the work tree (not staged yet), untracked files excluded.
    pub fn changed(self: Entry) bool {
        return !self.untracked() and !self.conflicted() and self.y != ' ' and self.y != '!';
    }
};

pub const Status = struct {
    arena: std.heap.ArenaAllocator,
    /// The current branch ("(detached)" when none).
    branch: []const u8 = "",
    upstream: ?[]const u8 = null,
    ahead: u32 = 0,
    behind: u32 = 0,
    entries: []Entry = &.{},
    stashes: u32 = 0,
    /// No commit exists yet (unstaging then needs `git rm --cached`).
    initial: bool = false,
    /// The repository's top folder (absolute).
    top: []const u8 = "",

    pub fn deinit(self: *Status) void {
        self.arena.deinit();
    }

    pub fn count(self: *const Status, comptime pick: enum { staged, changed, untracked, conflicted }) usize {
        var n: usize = 0;
        for (self.entries) |e| {
            const hit = switch (pick) {
                .staged => e.staged(),
                .changed => e.changed(),
                .untracked => e.untracked(),
                .conflicted => e.conflicted(),
            };
            if (hit) n += 1;
        }
        return n;
    }
};

/// Parse `git status --porcelain=v1 -z --branch` output into `st` (strings in its arena).
pub fn parseStatus(st: *Status, bytes: []const u8) !void {
    const a = st.arena.allocator();
    var list: std.ArrayListUnmanaged(Entry) = .empty;
    var it = std.mem.splitScalar(u8, bytes, 0);
    while (it.next()) |rec| {
        if (rec.len == 0) continue;
        if (std.mem.startsWith(u8, rec, "## ")) {
            try parseBranch(st, rec[3..]);
            continue;
        }
        if (rec.len < 4 or rec[2] != ' ') continue;
        var e: Entry = .{ .x = rec[0], .y = rec[1], .path = try a.dupe(u8, rec[3..]) };
        // A rename or copy is followed by the old name as its own record.
        if (e.x == 'R' or e.x == 'C' or e.y == 'R' or e.y == 'C') {
            if (it.next()) |old| e.orig = try a.dupe(u8, old);
        }
        try list.append(a, e);
    }
    st.entries = list.items;
}

/// `main...origin/main [ahead 1, behind 2]`, `No commits yet on main`, `HEAD (no branch)`.
fn parseBranch(st: *Status, text: []const u8) !void {
    const a = st.arena.allocator();
    if (std.mem.startsWith(u8, text, "No commits yet on ")) {
        st.branch = try a.dupe(u8, text["No commits yet on ".len..]);
        st.initial = true;
        return;
    }
    if (std.mem.startsWith(u8, text, "HEAD (no branch)")) {
        st.branch = "(detached)";
        return;
    }
    var name = text;
    var rest: []const u8 = "";
    if (std.mem.indexOf(u8, text, " [")) |i| {
        name = text[0..i];
        rest = text[i + 2 ..];
    }
    if (std.mem.indexOf(u8, name, "...")) |i| {
        st.branch = try a.dupe(u8, name[0..i]);
        st.upstream = try a.dupe(u8, name[i + 3 ..]);
    } else st.branch = try a.dupe(u8, name);
    if (std.mem.indexOf(u8, rest, "ahead ")) |i| st.ahead = leadingNumber(rest[i + 6 ..]);
    if (std.mem.indexOf(u8, rest, "behind ")) |i| st.behind = leadingNumber(rest[i + 7 ..]);
}

fn leadingNumber(s: []const u8) u32 {
    var n: u32 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') break;
        n = n * 10 + (c - '0');
    }
    return n;
}

// ---- diffs -----------------------------------------------------------------

pub const LineKind = enum { added, removed, hunk, header, context };

/// How a line of unified diff text should look.
pub fn diffLineKind(line: []const u8) LineKind {
    if (std.mem.startsWith(u8, line, "@@")) return .hunk;
    if (std.mem.startsWith(u8, line, "+++") or std.mem.startsWith(u8, line, "---") or std.mem.startsWith(u8, line, "diff ") or std.mem.startsWith(u8, line, "index ") or std.mem.startsWith(u8, line, "new file") or std.mem.startsWith(u8, line, "deleted file") or std.mem.startsWith(u8, line, "similarity") or std.mem.startsWith(u8, line, "rename ")) return .header;
    if (line.len > 0 and line[0] == '+') return .added;
    if (line.len > 0 and line[0] == '-') return .removed;
    return .context;
}

// ---- running git -----------------------------------------------------------

pub const Output = struct {
    ok: bool,
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(self: Output, gpa: std.mem.Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
    }
};

pub const Kind = enum { status, diff, action };

pub const Job = struct {
    kind: Kind,
    /// What to run (after `git -C <root>`), for `.action`; `.diff` builds its own.
    args: []const []const u8 = &.{},
    /// For `.diff`: the file and which side.
    path: []const u8 = "",
    staged: bool = false,
    untracked: bool = false,
    /// For `.action`: what to call it in messages.
    label: []const u8 = "",
};

pub const Done = struct {
    kind: Kind,
    ok: bool,
    /// `.diff`: the diff text. `.action`: git's message (first lines of stdout or stderr). Owned.
    text: []u8,
    /// `.diff`: which file (owned) and side.
    path: []u8,
    staged: bool,
    label: []u8,
    /// `.status`: the parsed status (null if this is not a repository or git failed).
    status: ?*Status,
    /// `.status`: git could not be run or the folder is not a repository: why.
    problem: []u8,

    pub fn deinit(self: *Done, gpa: std.mem.Allocator) void {
        gpa.free(self.text);
        gpa.free(self.path);
        gpa.free(self.label);
        gpa.free(self.problem);
        if (self.status) |s| {
            s.deinit();
            gpa.destroy(s);
        }
    }
};

pub const Git = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    root: []u8,
    env: std.process.Environ.Map,
    queue: worker.Queue(Done),
    thread: ?std.Thread = null,
    busy_flag: std.atomic.Value(bool) = .init(false),
    /// The job in flight (owned copies, valid until it finishes).
    job_args: std.ArrayListUnmanaged([]u8) = .empty,
    job_path: ?[]u8 = null,
    job_label: ?[]u8 = null,
    job: Job = .{ .kind = .status },
    top: ?[]u8 = null,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, root: []const u8, environ: ?*const std.process.Environ.Map, wake: ?*const fn () void) !*Git {
        const self = try gpa.create(Git);
        errdefer gpa.destroy(self);
        const r = try gpa.dupe(u8, root);
        errdefer gpa.free(r);
        var env = std.process.Environ.Map.init(gpa);
        errdefer env.deinit();
        if (environ) |m| {
            var it = m.iterator();
            while (it.next()) |kv| try env.put(kv.key_ptr.*, kv.value_ptr.*);
        }
        try env.put("GIT_TERMINAL_PROMPT", "0");
        try env.put("LC_ALL", "C");
        self.* = .{ .gpa = gpa, .io = io, .root = r, .env = env, .queue = .{ .gpa = gpa, .wake = wake } };
        return self;
    }

    pub fn deinit(self: *Git) void {
        if (self.thread) |t| t.join();
        var left: std.ArrayListUnmanaged(Done) = .empty;
        self.queue.drain(&left);
        for (left.items) |*d| d.deinit(self.gpa);
        left.deinit(self.gpa);
        self.queue.deinit();
        self.freeJob();
        self.job_args.deinit(self.gpa);
        self.env.deinit();
        if (self.top) |t| self.gpa.free(t);
        self.gpa.free(self.root);
        self.gpa.destroy(self);
    }

    fn freeJob(self: *Git) void {
        for (self.job_args.items) |a| self.gpa.free(a);
        self.job_args.clearRetainingCapacity();
        if (self.job_path) |p| self.gpa.free(p);
        self.job_path = null;
        if (self.job_label) |p| self.gpa.free(p);
        self.job_label = null;
    }

    /// Run `git -C <root> args...` and wait. Any thread (the UI uses `submit`).
    pub fn run(self: *Git, args: []const []const u8) !Output {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        defer argv.deinit(self.gpa);
        try argv.appendSlice(self.gpa, &.{ "git", "-C", self.root });
        try argv.appendSlice(self.gpa, args);
        const res = try std.process.run(self.gpa, self.io, .{
            .argv = argv.items,
            .environ_map = &self.env,
            .stdout_limit = .limited(16 << 20),
            .stderr_limit = .limited(1 << 20),
            .timeout = .{ .duration = .{ .raw = .fromSeconds(120), .clock = .awake } },
        });
        const ok = switch (res.term) {
            .exited => |c| c == 0,
            else => false,
        };
        return .{ .ok = ok, .stdout = res.stdout, .stderr = res.stderr };
    }

    pub fn busy(self: *const Git) bool {
        return self.busy_flag.load(.acquire);
    }

    /// Start a job on the worker thread. False (nothing started) while another is running.
    pub fn submit(self: *Git, job: Job) bool {
        if (self.busy()) return false;
        if (self.thread) |t| t.join();
        self.thread = null;
        self.freeJob();
        // Copies: the caller's strings may not outlive this call.
        for (job.args) |a| {
            const c = self.gpa.dupe(u8, a) catch return false;
            self.job_args.append(self.gpa, c) catch {
                self.gpa.free(c);
                return false;
            };
        }
        self.job_path = self.gpa.dupe(u8, job.path) catch return false;
        self.job_label = self.gpa.dupe(u8, job.label) catch return false;
        self.job = job;
        self.busy_flag.store(true, .release);
        self.thread = std.Thread.spawn(.{}, work, .{self}) catch {
            self.busy_flag.store(false, .release);
            return false;
        };
        return true;
    }

    /// A finished job, if one arrived (UI thread). Call `deinit` on it.
    pub fn poll(self: *Git) ?Done {
        var out: std.ArrayListUnmanaged(Done) = .empty;
        defer out.deinit(self.gpa);
        self.queue.drain(&out);
        if (out.items.len == 0) return null;
        // One job at a time: at most one result.
        for (out.items[1..]) |*d| d.deinit(self.gpa);
        return out.items[0];
    }

    fn work(self: *Git) void {
        defer self.busy_flag.store(false, .release);
        const done = self.execute() catch |err| blk: {
            const msg = std.fmt.allocPrint(self.gpa, "could not run git: {s}", .{@errorName(err)}) catch return;
            break :blk Done{
                .kind = self.job.kind,
                .ok = false,
                .text = msg,
                .path = self.gpa.dupe(u8, "") catch return,
                .staged = false,
                .label = self.gpa.dupe(u8, "") catch return,
                .status = null,
                .problem = self.gpa.dupe(u8, "could not run git") catch return,
            };
        };
        self.queue.push(done) catch {
            var d = done;
            d.deinit(self.gpa);
        };
    }

    fn firstLines(text: []const u8) []const u8 {
        const t = std.mem.trim(u8, text, " \r\n");
        // A few lines are plenty for a message.
        var end: usize = 0;
        var lines: usize = 0;
        while (end < t.len and lines < 4) : (end += 1) {
            if (t[end] == '\n') lines += 1;
        }
        return std.mem.trimEnd(u8, t[0..end], "\n");
    }

    fn execute(self: *Git) !Done {
        const gpa = self.gpa;
        const empty = try gpa.dupe(u8, "");
        errdefer gpa.free(empty);
        var done: Done = .{
            .kind = self.job.kind,
            .ok = false,
            .text = empty,
            .path = try gpa.dupe(u8, self.job_path orelse ""),
            .staged = self.job.staged,
            .label = try gpa.dupe(u8, self.job_label orelse ""),
            .status = null,
            .problem = try gpa.dupe(u8, ""),
        };
        errdefer done.deinit(gpa);
        switch (self.job.kind) {
            .status => try self.doStatus(&done),
            .diff => try self.doDiff(&done),
            .action => {
                const out = try self.run(self.job_args.items);
                defer out.deinit(gpa);
                done.ok = out.ok;
                gpa.free(done.text);
                done.text = try gpa.dupe(u8, firstLines(if (out.stderr.len > 0 and !out.ok) out.stderr else if (out.stdout.len > 0) out.stdout else out.stderr));
            },
        }
        return done;
    }

    fn setProblem(self: *Git, done: *Done, text: []const u8) !void {
        self.gpa.free(done.problem);
        done.problem = try self.gpa.dupe(u8, text);
    }

    fn doStatus(self: *Git, done: *Done) !void {
        const gpa = self.gpa;
        const top_out = self.run(&.{ "rev-parse", "--show-toplevel" }) catch |err| {
            return self.setProblem(done, if (err == error.FileNotFound) "git is not installed" else "could not run git");
        };
        defer top_out.deinit(gpa);
        if (!top_out.ok) return self.setProblem(done, "not a git repository");
        const top = std.mem.trim(u8, top_out.stdout, " \r\n");

        const st_out = try self.run(&.{ "status", "--porcelain=v1", "-z", "--branch", "--untracked-files=all" });
        defer st_out.deinit(gpa);
        if (!st_out.ok) return self.setProblem(done, firstLines(st_out.stderr));
        const st = try gpa.create(Status);
        st.* = .{ .arena = .init(gpa) };
        errdefer {
            st.deinit();
            gpa.destroy(st);
        }
        st.top = try st.arena.allocator().dupe(u8, top);
        try parseStatus(st, st_out.stdout);
        if (self.run(&.{ "stash", "list" })) |sl| {
            defer sl.deinit(gpa);
            for (sl.stdout) |c| {
                if (c == '\n') st.stashes += 1;
            }
        } else |_| {}
        done.status = st;
        done.ok = true;
    }

    fn doDiff(self: *Git, done: *Done) !void {
        const gpa = self.gpa;
        const path = self.job_path orelse "";
        const out = if (self.job.untracked)
            try self.run(&.{ "diff", "--no-index", "--no-color", "--", if (builtin.os.tag == .windows) "NUL" else "/dev/null", path })
        else if (self.job.staged)
            try self.run(&.{ "diff", "--no-color", "--cached", "--", path })
        else
            try self.run(&.{ "diff", "--no-color", "--", path });
        defer out.deinit(gpa);
        // `--no-index` exits 1 when the files differ; that is the normal case.
        done.ok = out.ok or (self.job.untracked and out.stdout.len > 0);
        gpa.free(done.text);
        done.text = try gpa.dupe(u8, if (out.stdout.len > 0) out.stdout else out.stderr);
    }
};

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

test "status output is parsed into branch, counts and entries (renames, untracked, conflicts)" {
    var st: Status = .{ .arena = .init(testing.allocator) };
    defer st.deinit();
    try parseStatus(&st, "## main...origin/main [ahead 2, behind 1]\x00 M src/a.zig\x00M  b.zig\x00MM both.zig\x00R  new.zig\x00old.zig\x00?? c.txt\x00UU merge.zig\x00");
    try testing.expectEqualStrings("main", st.branch);
    try testing.expectEqualStrings("origin/main", st.upstream.?);
    try testing.expectEqual(@as(u32, 2), st.ahead);
    try testing.expectEqual(@as(u32, 1), st.behind);
    try testing.expectEqual(@as(usize, 6), st.entries.len);
    try testing.expectEqual(@as(usize, 3), st.count(.staged)); // b, both, renamed
    try testing.expectEqual(@as(usize, 2), st.count(.changed)); // a, both
    try testing.expectEqual(@as(usize, 1), st.count(.untracked));
    try testing.expectEqual(@as(usize, 1), st.count(.conflicted));
    try testing.expectEqualStrings("old.zig", st.entries[3].orig.?);
    try testing.expectEqualStrings("new.zig", st.entries[3].path);
}

test "branch lines without an upstream, with no commits, or detached" {
    var a: Status = .{ .arena = .init(testing.allocator) };
    defer a.deinit();
    try parseStatus(&a, "## feature\x00");
    try testing.expectEqualStrings("feature", a.branch);
    try testing.expect(a.upstream == null);
    var b: Status = .{ .arena = .init(testing.allocator) };
    defer b.deinit();
    try parseStatus(&b, "## No commits yet on master\x00?? f\x00");
    try testing.expectEqualStrings("master", b.branch);
    var c: Status = .{ .arena = .init(testing.allocator) };
    defer c.deinit();
    try parseStatus(&c, "## HEAD (no branch)\x00");
    try testing.expectEqualStrings("(detached)", c.branch);
}

test "diff lines are classified" {
    try testing.expect(diffLineKind("+added") == .added);
    try testing.expect(diffLineKind("-removed") == .removed);
    try testing.expect(diffLineKind("+++ b/f") == .header);
    try testing.expect(diffLineKind("--- a/f") == .header);
    try testing.expect(diffLineKind("@@ -1 +1 @@") == .hunk);
    try testing.expect(diffLineKind(" context") == .context);
    try testing.expect(diffLineKind("") == .context);
}

fn waitDone(g: *Git) !Done {
    var tries: usize = 0;
    while (tries < 20000) : (tries += 1) {
        if (g.poll()) |d| return d;
        @import("../platform/pty_common.zig").sleepMs(2);
    }
    return error.Timeout;
}

/// A scratch repository with one commit, or null when `git` is not installed.
fn scratchRepo(tmp: *testing.TmpDir, root: []const u8) !?*Git {
    const g = try Git.init(testing.allocator, testing.io, root, null, null);
    errdefer g.deinit();
    const init_out = g.run(&.{ "init", "-q" }) catch return null;
    init_out.deinit(testing.allocator);
    for ([_][]const []const u8{ &.{ "config", "user.email", "t@example.com" }, &.{ "config", "user.name", "T" }, &.{ "config", "commit.gpgsign", "false" } }) |args| {
        const o = try g.run(args);
        o.deinit(testing.allocator);
    }
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "f.txt", .data = "one\n" });
    const add = try g.run(&.{ "add", "f.txt" });
    add.deinit(testing.allocator);
    const commit = try g.run(&.{ "commit", "-q", "-m", "first" });
    commit.deinit(testing.allocator);
    return g;
}

test "status, diff, stage, unstage, commit and stash against a real repository" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    const g = (try scratchRepo(&tmp, buf[0..n])) orelse return error.SkipZigTest;
    defer g.deinit();

    // A modified file and an untracked one.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "f.txt", .data = "one\ntwo\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "new.txt", .data = "hello\n" });
    try testing.expect(g.submit(.{ .kind = .status }));
    var d = try waitDone(g);
    {
        defer d.deinit(testing.allocator);
        try testing.expect(d.ok and d.status != null);
        const st = d.status.?;
        try testing.expectEqual(@as(usize, 1), st.count(.changed));
        try testing.expectEqual(@as(usize, 1), st.count(.untracked));
        try testing.expectEqual(@as(usize, 0), st.count(.staged));
        try testing.expect(st.branch.len > 0);
    }

    // Diffs: the work tree change, and an untracked file shown as all-added.
    try testing.expect(g.submit(.{ .kind = .diff, .path = "f.txt" }));
    d = try waitDone(g);
    try testing.expect(std.mem.indexOf(u8, d.text, "+two") != null);
    d.deinit(testing.allocator);
    try testing.expect(g.submit(.{ .kind = .diff, .path = "new.txt", .untracked = true }));
    d = try waitDone(g);
    try testing.expect(d.ok and std.mem.indexOf(u8, d.text, "+hello") != null);
    d.deinit(testing.allocator);

    // Stage both, check, unstage one.
    try testing.expect(g.submit(.{ .kind = .action, .args = &.{ "add", "--", "f.txt", "new.txt" }, .label = "stage" }));
    d = try waitDone(g);
    try testing.expect(d.ok);
    d.deinit(testing.allocator);
    try testing.expect(g.submit(.{ .kind = .diff, .path = "f.txt", .staged = true }));
    d = try waitDone(g);
    try testing.expect(std.mem.indexOf(u8, d.text, "+two") != null);
    d.deinit(testing.allocator);
    try testing.expect(g.submit(.{ .kind = .action, .args = &.{ "restore", "--staged", "--", "new.txt" } }));
    d = try waitDone(g);
    try testing.expect(d.ok);
    d.deinit(testing.allocator);

    // Commit what is staged, then stash the leftover untracked file with the commit message check.
    try testing.expect(g.submit(.{ .kind = .action, .args = &.{ "commit", "-m", "second" } }));
    d = try waitDone(g);
    try testing.expect(d.ok);
    d.deinit(testing.allocator);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "f.txt", .data = "one\ntwo\nthree\n" });
    try testing.expect(g.submit(.{ .kind = .action, .args = &.{ "stash", "push", "-m", "wip" } }));
    d = try waitDone(g);
    try testing.expect(d.ok);
    d.deinit(testing.allocator);
    try testing.expect(g.submit(.{ .kind = .status }));
    d = try waitDone(g);
    defer d.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 1), d.status.?.stashes);
    try testing.expectEqual(@as(usize, 0), d.status.?.count(.changed));
}

test "a folder that is not a repository is reported, not an error" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    // A temporary folder is normally outside any repository; make sure git does not climb out of it.
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("PATH", "/usr/bin:/bin:/usr/local/bin");
    try env.put("GIT_CEILING_DIRECTORIES", std.fs.path.dirname(buf[0..n]) orelse "/");
    const g = try Git.init(testing.allocator, testing.io, buf[0..n], &env, null);
    defer g.deinit();
    try testing.expect(g.submit(.{ .kind = .status }));
    var d = try waitDone(g);
    defer d.deinit(testing.allocator);
    try testing.expect(!d.ok and d.status == null);
    try testing.expect(d.problem.len > 0);
}
