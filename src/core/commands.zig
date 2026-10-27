//! Command registry: named actions shared by shortcuts, buttons, menus, and
//! the builder (design doc sections 14 and 16).
//!
//! A command has a unique name ("file.save"), a human title, an enabled flag,
//! and an optional handler. Running it calls the handler with an `Event` of
//! kind `command` whose `text` is the command name, so one handler can serve
//! several commands. Handlers are ordinary `event.Callback`s.
//!
//! Commands are addressed by generational `Handle`, so a stale handle from an
//! unregistered command is detected instead of aliasing a new one.

const std = @import("std");
const Handle = @import("handle.zig").Handle;
const Pool = @import("pool.zig").Pool;
const event = @import("event.zig");

pub const Command = struct {
    /// Owned.
    name: []u8,
    /// Owned. Shown in menus and palettes.
    title: []u8,
    run: ?event.Callback,
    enabled: bool = true,
    /// Whether holding the shortcut key re-runs it (arrow navigation yes, save no).
    repeat: bool = false,
};

pub const Error = error{ DuplicateCommand, OutOfMemory };

/// What `register` accepts.
pub const Options = struct {
    /// Shown in menus and palettes; the name is used if empty.
    title: []const u8 = "",
    run: ?event.Callback = null,
    enabled: bool = true,
    /// Whether holding the shortcut key re-runs it (arrow navigation yes, save no).
    repeat: bool = false,
};

pub const Commands = struct {
    gpa: std.mem.Allocator,
    pool: Pool(Command, 64),
    by_name: std.StringHashMapUnmanaged(Handle) = .empty,

    pub fn init(gpa: std.mem.Allocator) Commands {
        return .{ .gpa = gpa, .pool = Pool(Command, 64).init(gpa) };
    }

    pub fn deinit(self: *Commands) void {
        var it = self.pool.iterator();
        while (it.next()) |e| self.freeCommand(e.ptr);
        self.pool.deinit();
        self.by_name.deinit(self.gpa);
        self.* = undefined;
    }

    fn freeCommand(self: *Commands, c: *Command) void {
        self.gpa.free(c.name);
        self.gpa.free(c.title);
    }

    pub fn count(self: *const Commands) u32 {
        return self.pool.count();
    }

    pub fn register(self: *Commands, name: []const u8, opts: Options) Error!Handle {
        if (self.by_name.contains(name)) return error.DuplicateCommand;
        const owned_name = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(owned_name);
        const owned_title = try self.gpa.dupe(u8, if (opts.title.len > 0) opts.title else name);
        errdefer self.gpa.free(owned_title);
        const h = try self.pool.create(.{
            .name = owned_name,
            .title = owned_title,
            .run = opts.run,
            .enabled = opts.enabled,
            .repeat = opts.repeat,
        });
        errdefer _ = self.pool.destroy(h);
        try self.by_name.put(self.gpa, owned_name, h);
        return h;
    }

    /// Remove a command. Returns false if the handle was already stale.
    /// Bindings to it become inert (their handle no longer resolves).
    pub fn unregister(self: *Commands, h: Handle) bool {
        const c = self.pool.get(h) orelse return false;
        _ = self.by_name.remove(c.name);
        self.freeCommand(c);
        return self.pool.destroy(h);
    }

    pub fn find(self: *const Commands, name: []const u8) ?Handle {
        return self.by_name.get(name);
    }

    pub fn get(self: *Commands, h: Handle) ?*Command {
        return self.pool.get(h);
    }

    pub fn isEnabled(self: *Commands, h: Handle) bool {
        const c = self.pool.get(h) orelse return false;
        return c.enabled;
    }

    pub fn setEnabled(self: *Commands, h: Handle, enabled: bool) void {
        if (self.pool.get(h)) |c| c.enabled = enabled;
    }

    /// Run the command. Returns true if a handler ran: false if the command is
    /// unknown, disabled, or has no handler. `target` is who the event is
    /// aimed at (usually the focused node). The handler may register or
    /// unregister commands, including this one.
    pub fn invoke(self: *Commands, h: Handle, target: Handle) bool {
        const c = self.pool.get(h) orelse return false;
        if (!c.enabled) return false;
        const run = c.run orelse return false;
        // The name slice dies if the handler unregisters the command, so the
        // event's text is only valid during the call, as documented.
        var ev: event.Event = .{
            .kind = .command,
            .target = target,
            .text = c.name,
        };
        run.invoke(&ev);
        return true;
    }

    pub fn invokeByName(self: *Commands, name: []const u8, target: Handle) bool {
        const h = self.find(name) orelse return false;
        return self.invoke(h, target);
    }
};

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

const Probe = struct {
    var calls: u32 = 0;
    var last_name: [32]u8 = undefined;
    var last_len: usize = 0;
    var last_user: ?*anyopaque = null;

    fn reset() void {
        calls = 0;
        last_len = 0;
        last_user = null;
    }

    fn handler(user: ?*anyopaque, ev: *event.Event) void {
        calls += 1;
        const got = ev.text;
        @memcpy(last_name[0..got.len], got);
        last_len = got.len;
        last_user = user;
        std.debug.assert(ev.kind == .command);
    }

    fn name() []const u8 {
        return last_name[0..last_len];
    }
};

test "register, find, and invoke by handle or name" {
    var cmds = Commands.init(testing.allocator);
    defer cmds.deinit();
    Probe.reset();
    var token: u32 = 7;
    const h = try cmds.register("file.save", .{ .title = "Save", .run = .{ .ctx = &token, .call = Probe.handler } });
    try testing.expect(cmds.find("file.save").?.eql(h));
    try testing.expect(cmds.find("file.open") == null);

    try testing.expect(cmds.invoke(h, Handle.invalid));
    try testing.expectEqualStrings("file.save", Probe.name());
    try testing.expectEqual(@as(?*anyopaque, &token), Probe.last_user);
    try testing.expect(cmds.invokeByName("file.save", Handle.invalid));
    try testing.expectEqual(@as(u32, 2), Probe.calls);
    try testing.expect(!cmds.invokeByName("nope", Handle.invalid));
}

test "duplicate names are rejected; titles and names are copied" {
    var cmds = Commands.init(testing.allocator);
    defer cmds.deinit(); // leak-checked
    var buf = [_]u8{ 'a', 'b' };
    _ = try cmds.register(&buf, .{ .title = &buf });
    buf[0] = 'z'; // the registry made its own copy
    try testing.expect(cmds.find("ab") != null);
    try testing.expectError(error.DuplicateCommand, cmds.register("ab", .{ .title = "Other" }));
    try testing.expectEqualStrings("ab", cmds.get(cmds.find("ab").?).?.title);
}

test "disabled commands and commands without handlers do not run" {
    var cmds = Commands.init(testing.allocator);
    defer cmds.deinit();
    Probe.reset();
    const h = try cmds.register("a", .{ .title = "A", .run = .{ .call = Probe.handler } });
    const bare = try cmds.register("b", .{ .title = "B" });
    cmds.setEnabled(h, false);
    try testing.expect(!cmds.isEnabled(h));
    try testing.expect(!cmds.invoke(h, Handle.invalid));
    cmds.setEnabled(h, true);
    try testing.expect(cmds.invoke(h, Handle.invalid));
    try testing.expect(!cmds.invoke(bare, Handle.invalid));
    try testing.expectEqual(@as(u32, 1), Probe.calls);
}

test "unregistering frees the name for reuse and stales the old handle" {
    var cmds = Commands.init(testing.allocator);
    defer cmds.deinit();
    Probe.reset();
    const h = try cmds.register("x", .{ .title = "X", .run = .{ .call = Probe.handler } });
    try testing.expect(cmds.unregister(h));
    try testing.expect(!cmds.unregister(h));
    try testing.expect(cmds.find("x") == null);
    try testing.expect(!cmds.invoke(h, Handle.invalid));
    const h2 = try cmds.register("x", .{ .title = "X again", .run = .{ .call = Probe.handler } });
    try testing.expect(!h2.eql(h));
    try testing.expect(!cmds.invoke(h, Handle.invalid)); // still stale
    try testing.expect(cmds.invoke(h2, Handle.invalid));
}

test "a handler can unregister its own command" {
    var cmds = Commands.init(testing.allocator);
    defer cmds.deinit();
    const Self = struct {
        var registry: *Commands = undefined;
        var me: Handle = undefined;
        fn run(_: ?*anyopaque, _: *event.Event) void {
            _ = registry.unregister(me);
        }
    };
    Self.registry = &cmds;
    Self.me = try cmds.register("once", .{ .title = "Once", .run = .{ .call = Self.run } });
    try testing.expect(cmds.invoke(Self.me, Handle.invalid));
    try testing.expectEqual(@as(u32, 0), cmds.count());
}
