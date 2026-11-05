//! A debug session: the state machine the debugger UI reads, built on `client.zig`.
//!
//!     idle -> starting -> running <-> stopped -> terminated
//!
//!     var s = try Session.create(gpa, send);          // `send` writes to the adapter
//!     defer s.destroy();
//!     s.on_change = ChangeHook.bind(&ui_state, State.redraw);
//!     try s.setBreakpoint("/proj/src/main.zig", 12, true, "");   // before or during a session
//!     try s.start(.{ .program = "/proj/zig-out/bin/app", .cwd = "/proj" });
//!     // feed the adapter's output:    s.client.receive(bytes);
//!     // the user:                     s.stepOver(); s.stepIn(); s.resume(); s.pause(); s.stop();
//!     // when `state == .stopped`:     s.frames, s.scopes, s.variables(ref), s.expand(ref)
//!
//! Startup follows the protocol: `initialize`, then `launch`, then the adapter's
//! `initialized` event is the cue to send the breakpoints and `configurationDone`.
//! On every stop it asks for the stack, the top frame's scopes and the first
//! scope's variables; children of a variable load when `expand` asks. Everything it
//! shows is a copy that stays valid until the next resume or frame change.
//! No process, no UI here: tests drive it with a scripted fake adapter.

const std = @import("std");
const client_mod = @import("client.zig");
const Client = client_mod.Client;
const strOf = client_mod.strOf;
const intOf = client_mod.intOf;
const boolOf = client_mod.boolOf;
const arrayOf = client_mod.arrayOf;

pub const State = enum { idle, starting, running, stopped, terminated };

pub const Frame = struct {
    id: i64,
    name: []const u8,
    /// "" when the frame has no source (runtime internals).
    path: []const u8,
    line: u32,
    column: u32,
};

pub const Scope = struct {
    name: []const u8,
    reference: i64,
    expensive: bool,
};

pub const Variable = struct {
    name: []const u8,
    value: []const u8,
    type_name: []const u8,
    /// Non-zero: it has children (`expand`).
    reference: i64,
};

pub const Verified = enum { unknown, verified, unverified };

pub const Breakpoint = struct {
    /// Absolute path.
    file: []u8,
    /// 1-based.
    line: u32,
    enabled: bool = true,
    /// Stop only when this expression is true ("" for always).
    condition: []u8,
    verified: Verified = .unknown,
    /// The adapter's note when it could not set it.
    message: []u8,
};

pub const Launch = struct {
    program: []const u8,
    args: []const []const u8 = &.{},
    cwd: []const u8 = "",
    /// `KEY=VALUE` entries added to the environment.
    env: []const []const u8 = &.{},
    stop_on_entry: bool = false,
    /// Which adapter: they spell a few launch arguments differently.
    gdb: bool = false,
    /// A comptime session (`zigct`): the JSON object sent as `launch` arguments, as is (see
    /// `zigct.zig`); `program` and the fields above are not used.
    raw_launch: []const u8 = "",
};

pub const ChangeHook = struct {
    ctx: ?*anyopaque = null,
    call: *const fn (ctx: ?*anyopaque) void,

    pub fn bind(ctx: anytype, comptime f: anytype) ChangeHook {
        const Ptr = @TypeOf(ctx);
        return .{
            .ctx = @ptrCast(ctx),
            .call = &struct {
                fn thunk(c: ?*anyopaque) void {
                    f(@as(Ptr, @ptrCast(@alignCast(c.?))));
                }
            }.thunk,
        };
    }
};

/// Events and requests that are not standard DAP (zigct's `zigct/typeEvent`, ...).
pub const CustomHook = struct {
    ctx: ?*anyopaque = null,
    call: *const fn (ctx: ?*anyopaque, name: []const u8, body: std.json.Value) void,

    pub fn bind(ctx: anytype, comptime f: anytype) CustomHook {
        const Ptr = @TypeOf(ctx);
        return .{
            .ctx = @ptrCast(ctx),
            .call = &struct {
                fn thunk(c: ?*anyopaque, name: []const u8, body: std.json.Value) void {
                    f(@as(Ptr, @ptrCast(@alignCast(c.?))), name, body);
                }
            }.thunk,
        };
    }
};

const max_console_lines = 2000;
const max_frames = 60;

const VarCache = struct { reference: i64, items: []Variable, loaded: bool = false };

pub const Session = struct {
    gpa: std.mem.Allocator,
    client: *Client,
    state: State = .idle,
    on_change: ?ChangeHook = null,
    /// A comptime session stops where a compile error is raised (before the stack unwinds), and
    /// optionally at every `@compileLog`.
    break_compile_error: bool = true,
    break_compile_log: bool = false,
    /// Gets the adapter's non-standard events (names with a `/`).
    on_custom: ?CustomHook = null,
    /// Breakpoints, in the order they were added.
    breakpoints: std.ArrayListUnmanaged(Breakpoint) = .empty,
    /// Adapter output and our own notes, one line each (capped).
    console: std.ArrayListUnmanaged([]u8) = .empty,
    /// Why the program stopped ("breakpoint", "step", "exception", ...), and the adapter's description.
    stop_reason: []u8 = &.{},
    stop_text: []u8 = &.{},
    thread_id: i64 = 0,
    /// Counts up at every stop (the UI opens the stop's file when it changes).
    stop_count: u32 = 0,
    /// The stack of the stopped thread, innermost first; `selected` is the frame the panels show.
    frames: []Frame = &.{},
    selected: usize = 0,
    scopes: []Scope = &.{},
    /// Where the program ended and with what (valid once `state == .terminated`).
    exit_code: ?i64 = null,
    /// A reason startup failed (the adapter's message).
    failure: []u8 = &.{},
    launch: ?OwnedLaunch = null,
    /// Everything the panels show for the current stop.
    snap: std.heap.ArenaAllocator,
    var_cache: std.ArrayListUnmanaged(VarCache) = .empty,
    /// Breakpoints (and `configurationDone`) are sent once `initialized` arrived.
    adapter_ready: bool = false,
    /// `setBreakpoints` requests in flight, oldest first (answers come back in order).
    bp_requests: std.ArrayListUnmanaged(BpRequest) = .empty,

    const BpRequest = struct { seq: u32, file: []u8 };
    const OwnedLaunch = struct {
        program: []u8,
        args: [][]u8,
        cwd: []u8,
        env: [][]u8,
        stop_on_entry: bool,
        gdb: bool,
        raw: []u8,
    };

    pub fn create(gpa: std.mem.Allocator, send: client_mod.Send) !*Session {
        const self = try gpa.create(Session);
        errdefer gpa.destroy(self);
        const c = try Client.create(gpa, send);
        self.* = .{ .gpa = gpa, .client = c, .snap = .init(gpa) };
        c.on_event = client_mod.EventHook.bind(self, onEvent);
        return self;
    }

    pub fn destroy(self: *Session) void {
        self.client.destroy();
        for (self.breakpoints.items) |b| {
            self.gpa.free(b.file);
            self.gpa.free(b.condition);
            self.gpa.free(b.message);
        }
        self.breakpoints.deinit(self.gpa);
        for (self.console.items) |l| self.gpa.free(l);
        self.console.deinit(self.gpa);
        self.gpa.free(self.stop_reason);
        self.gpa.free(self.stop_text);
        self.gpa.free(self.failure);
        self.freeLaunch();
        self.var_cache.deinit(self.gpa);
        for (self.bp_requests.items) |r| self.gpa.free(r.file);
        self.bp_requests.deinit(self.gpa);
        self.snap.deinit();
        self.gpa.destroy(self);
    }

    fn freeLaunch(self: *Session) void {
        const l = self.launch orelse return;
        self.gpa.free(l.program);
        for (l.args) |a| self.gpa.free(a);
        self.gpa.free(l.args);
        self.gpa.free(l.cwd);
        self.gpa.free(l.raw);
        for (l.env) |a| self.gpa.free(a);
        self.gpa.free(l.env);
        self.launch = null;
    }

    fn changed(self: *Session) void {
        if (self.on_change) |h| h.call(h.ctx);
    }

    /// A comptime session (zigct) rather than a runtime one.
    pub fn isComptime(self: *const Session) bool {
        const l = self.launch orelse return false;
        return l.raw.len > 0;
    }

    pub fn active(self: *const Session) bool {
        return self.state == .starting or self.state == .running or self.state == .stopped;
    }

    /// A line for the console (adapter output, or a note from us).
    pub fn say(self: *Session, text: []const u8) void {
        var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\r\n"), '\n');
        while (it.next()) |line| {
            const copy = self.gpa.dupe(u8, std.mem.trimEnd(u8, line, "\r")) catch return;
            self.console.append(self.gpa, copy) catch {
                self.gpa.free(copy);
                return;
            };
            if (self.console.items.len > max_console_lines) self.gpa.free(self.console.orderedRemove(0));
        }
    }

    fn replace(self: *Session, slot: *[]u8, text: []const u8) void {
        const copy = self.gpa.dupe(u8, text) catch return;
        self.gpa.free(slot.*);
        slot.* = copy;
    }

    // ---- starting and stopping ----

    pub fn start(self: *Session, l: Launch) !void {
        if (self.active()) return;
        self.freeLaunch();
        const args = try self.gpa.alloc([]u8, l.args.len);
        var na: usize = 0;
        errdefer {
            for (args[0..na]) |a| self.gpa.free(a);
            self.gpa.free(args);
        }
        for (l.args) |a| {
            args[na] = try self.gpa.dupe(u8, a);
            na += 1;
        }
        const env = try self.gpa.alloc([]u8, l.env.len);
        var ne: usize = 0;
        errdefer {
            for (env[0..ne]) |a| self.gpa.free(a);
            self.gpa.free(env);
        }
        for (l.env) |a| {
            env[ne] = try self.gpa.dupe(u8, a);
            ne += 1;
        }
        self.launch = .{
            .program = try self.gpa.dupe(u8, l.program),
            .args = args,
            .cwd = try self.gpa.dupe(u8, l.cwd),
            .env = env,
            .stop_on_entry = l.stop_on_entry,
            .gdb = l.gdb,
            .raw = try self.gpa.dupe(u8, l.raw_launch),
        };
        self.client.reset();
        for (self.bp_requests.items) |r| self.gpa.free(r.file);
        self.bp_requests.clearRetainingCapacity();
        self.state = .starting;
        self.adapter_ready = false;
        self.exit_code = null;
        self.replace(&self.failure, "");
        self.dropSnapshot();
        _ = try self.client.request("initialize", .{
            .clientID = "zigui",
            .clientName = "zigui IDE",
            .adapterID = "zigui",
            .linesStartAt1 = true,
            .columnsStartAt1 = true,
            .pathFormat = "path",
            .supportsVariableType = true,
            .supportsRunInTerminalRequest = false,
        }, client_mod.ResponseHook.bind(self, onInitialize));
        self.changed();
    }

    fn fail(self: *Session, why: []const u8) void {
        self.replace(&self.failure, why);
        var buf: [300]u8 = undefined;
        self.say(std.fmt.bufPrint(&buf, "debugger: {s}", .{why}) catch why);
        self.state = .terminated;
        self.changed();
    }

    fn onInitialize(self: *Session, res: *const client_mod.Response) void {
        if (!res.ok) return self.fail(if (res.message.len > 0) res.message else "the adapter refused to initialize");
        const l = self.launch orelse return;
        const cwd: ?[]const u8 = if (l.cwd.len > 0) l.cwd else null;
        const hook = client_mod.ResponseHook.bind(self, onLaunch);
        if (l.raw.len > 0) {
            var parsed = std.json.parseFromSlice(std.json.Value, self.gpa, l.raw, .{}) catch return self.fail("the comptime launch arguments are not valid JSON");
            defer parsed.deinit();
            _ = self.client.request("launch", parsed.value, hook) catch self.fail("could not send launch");
            return;
        }
        const sent = if (l.gdb)
            // GDB's DAP: no `env` array, and the entry stop is spelled differently.
            self.client.request("launch", .{ .program = l.program, .args = l.args, .cwd = cwd, .stopAtBeginningOfMainSubprogram = l.stop_on_entry }, hook)
        else
            self.client.request("launch", .{ .program = l.program, .args = l.args, .cwd = cwd, .env = l.env, .stopOnEntry = l.stop_on_entry }, hook);
        _ = sent catch self.fail("could not send launch");
    }

    fn onLaunch(self: *Session, res: *const client_mod.Response) void {
        if (!res.ok) self.fail(if (res.message.len > 0) res.message else "the adapter could not launch the program");
    }

    /// The adapter is ready for breakpoints: send them all, then say we are done configuring.
    fn onAdapterReady(self: *Session) void {
        self.adapter_ready = true;
        // One request per file.
        var done: std.ArrayListUnmanaged([]const u8) = .empty;
        defer done.deinit(self.gpa);
        for (self.breakpoints.items) |b| {
            var seen = false;
            for (done.items) |f| {
                if (std.mem.eql(u8, f, b.file)) seen = true;
            }
            if (seen) continue;
            done.append(self.gpa, b.file) catch {};
            self.sendFile(b.file);
        }
        self.sendExceptionFilters();
        _ = self.client.request("configurationDone", struct {}{}, client_mod.ResponseHook.bind(self, onConfigured)) catch {};
    }

    fn onConfigured(self: *Session, res: *const client_mod.Response) void {
        if (!res.ok) return self.fail("configurationDone failed");
        // A stop may already have arrived (stopOnEntry).
        if (self.state == .starting) self.state = .running;
        self.changed();
    }

    /// End the debuggee and the session.
    pub fn stop(self: *Session) void {
        if (!self.active()) return;
        _ = self.client.request("disconnect", .{ .terminateDebuggee = true }, client_mod.ResponseHook.bind(self, onDisconnect)) catch {
            self.state = .terminated;
            self.changed();
        };
    }

    fn onDisconnect(self: *Session, _: *const client_mod.Response) void {
        if (self.state != .terminated) {
            self.state = .terminated;
            self.dropSnapshot();
            self.changed();
        }
    }

    // ---- running ----

    fn resumeWith(self: *Session, command: []const u8) void {
        if (self.state != .stopped) return;
        // Running before the request goes out: an adapter may answer with the next stop at once.
        self.state = .running;
        self.dropSnapshot();
        _ = self.client.request(command, .{ .threadId = self.thread_id }, null) catch {
            self.state = .stopped;
            return;
        };
        self.changed();
    }

    pub fn continueRun(self: *Session) void {
        self.resumeWith("continue");
    }

    pub fn stepOver(self: *Session) void {
        self.resumeWith("next");
    }

    pub fn stepIn(self: *Session) void {
        self.resumeWith("stepIn");
    }

    pub fn stepOut(self: *Session) void {
        self.resumeWith("stepOut");
    }

    pub fn pause(self: *Session) void {
        if (self.state != .running) return;
        _ = self.client.request("pause", .{ .threadId = self.thread_id }, null) catch {};
    }

    // ---- events ----

    fn onEvent(self: *Session, name: []const u8, body: std.json.Value) void {
        if (std.mem.eql(u8, name, "initialized")) {
            self.onAdapterReady();
        } else if (std.mem.eql(u8, name, "stopped")) {
            self.onStopped(body);
        } else if (std.mem.eql(u8, name, "continued")) {
            if (self.state == .stopped) {
                self.state = .running;
                self.dropSnapshot();
                self.changed();
            }
        } else if (std.mem.eql(u8, name, "output")) {
            if (body == .object) {
                const cat = strOf(body.object.get("category")) orelse "console";
                if (std.mem.eql(u8, cat, "telemetry")) return;
                if (strOf(body.object.get("output"))) |text| {
                    self.say(text);
                    self.changed();
                }
            }
        } else if (std.mem.eql(u8, name, "exited")) {
            if (body == .object) self.exit_code = intOf(body.object.get("exitCode"));
        } else if (std.mem.eql(u8, name, "terminated")) {
            self.state = .terminated;
            self.dropSnapshot();
            var buf: [96]u8 = undefined;
            if (self.isComptime()) {
                self.say(if ((self.exit_code orelse 0) == 0) "[the comptime run finished]" else "[the compilation failed: the compiler's messages are above]");
            } else if (self.exit_code) |c| self.say(std.fmt.bufPrint(&buf, "[the program exited with code {d}]", .{c}) catch "[the program ended]") else self.say("[the program ended]");
            self.changed();
        } else if (std.mem.eql(u8, name, "breakpoint")) {
            self.onBreakpointEvent(body);
        } else if (std.mem.indexOfScalar(u8, name, '/') != null) {
            if (self.on_custom) |h| h.call(h.ctx, name, body);
        }
    }

    /// Tell a comptime adapter which exceptions stop it (also callable while the session runs).
    pub fn sendExceptionFilters(self: *Session) void {
        if (!self.isComptime() or !self.adapter_ready) return;
        var filters: [2][]const u8 = undefined;
        var n: usize = 0;
        if (self.break_compile_error) {
            filters[n] = "compile_error";
            n += 1;
        }
        if (self.break_compile_log) {
            filters[n] = "compile_log";
            n += 1;
        }
        _ = self.client.request("setExceptionBreakpoints", .{ .filters = filters[0..n] }, null) catch {};
    }

    /// A non-standard request (`zigct/typeInfo`); the answer goes to `hook`.
    pub fn customRequest(self: *Session, command: []const u8, args: anytype, hook: ?client_mod.ResponseHook) !u32 {
        return self.client.request(command, args, hook);
    }

    fn onStopped(self: *Session, body: std.json.Value) void {
        if (body != .object) return;
        self.dropSnapshot();
        self.state = .stopped;
        self.stop_count +%= 1;
        self.thread_id = intOf(body.object.get("threadId")) orelse self.thread_id;
        self.replace(&self.stop_reason, strOf(body.object.get("reason")) orelse "");
        self.replace(&self.stop_text, strOf(body.object.get("description")) orelse strOf(body.object.get("text")) orelse "");
        _ = self.client.request("stackTrace", .{ .threadId = self.thread_id, .startFrame = 0, .levels = max_frames }, client_mod.ResponseHook.bind(self, onStack)) catch {};
        self.changed();
    }

    fn onStack(self: *Session, res: *const client_mod.Response) void {
        if (!res.ok or self.state != .stopped or res.body != .object) return;
        const a = self.snap.allocator();
        const list = arrayOf(res.body.object.get("stackFrames"));
        const frames = a.alloc(Frame, list.len) catch return;
        var n: usize = 0;
        for (list) |f| {
            if (f != .object) continue;
            var path: []const u8 = "";
            if (f.object.get("source")) |src| if (src == .object) {
                path = strOf(src.object.get("path")) orelse "";
            };
            frames[n] = .{
                .id = intOf(f.object.get("id")) orelse 0,
                .name = a.dupe(u8, strOf(f.object.get("name")) orelse "") catch "",
                .path = a.dupe(u8, path) catch "",
                .line = @intCast(@max(intOf(f.object.get("line")) orelse 0, 0)),
                .column = @intCast(@max(intOf(f.object.get("column")) orelse 0, 0)),
            };
            n += 1;
        }
        self.frames = frames[0..n];
        self.selected = 0;
        self.requestScopes();
        self.changed();
    }

    /// Show another frame of the stack.
    pub fn selectFrame(self: *Session, index: usize) void {
        if (self.state != .stopped or index >= self.frames.len or index == self.selected) return;
        self.selected = index;
        self.scopes = &.{};
        self.var_cache.clearRetainingCapacity();
        self.requestScopes();
        self.changed();
    }

    fn requestScopes(self: *Session) void {
        if (self.selected >= self.frames.len) return;
        _ = self.client.request("scopes", .{ .frameId = self.frames[self.selected].id }, client_mod.ResponseHook.bind(self, onScopes)) catch {};
    }

    fn onScopes(self: *Session, res: *const client_mod.Response) void {
        if (!res.ok or self.state != .stopped or res.body != .object) return;
        const a = self.snap.allocator();
        const list = arrayOf(res.body.object.get("scopes"));
        const scopes = a.alloc(Scope, list.len) catch return;
        var n: usize = 0;
        for (list) |s| {
            if (s != .object) continue;
            scopes[n] = .{
                .name = a.dupe(u8, strOf(s.object.get("name")) orelse "") catch "",
                .reference = intOf(s.object.get("variablesReference")) orelse 0,
                .expensive = boolOf(s.object.get("expensive"), false),
            };
            n += 1;
        }
        self.scopes = scopes[0..n];
        // The first scope (locals) is always wanted; the rest load on request.
        if (n > 0 and !self.scopes[0].expensive) self.expand(self.scopes[0].reference);
        self.changed();
    }

    /// The children of `reference`, once they have been loaded (null while loading or never asked).
    pub fn variables(self: *const Session, reference: i64) ?[]const Variable {
        for (self.var_cache.items) |c| {
            if (c.reference == reference and c.loaded) return c.items;
        }
        return null;
    }

    fn asked(self: *const Session, reference: i64) bool {
        for (self.var_cache.items) |c| {
            if (c.reference == reference) return true;
        }
        return false;
    }

    /// Are the children of `reference` being fetched?
    pub fn loading(self: *const Session, reference: i64) bool {
        return self.asked(reference) and self.variables(reference) == null;
    }

    /// Load the children of `reference` (a scope or a variable) if needed.
    pub fn expand(self: *Session, reference: i64) void {
        if (reference <= 0 or self.state != .stopped or self.asked(reference)) return;
        // Mark it as loading so a second click does not ask again.
        self.var_cache.append(self.gpa, .{ .reference = reference, .items = &.{} }) catch return;
        _ = self.client.request("variables", .{ .variablesReference = reference }, client_mod.ResponseHook.bind(self, onVariables)) catch {};
    }

    fn onVariables(self: *Session, res: *const client_mod.Response) void {
        if (self.state != .stopped or res.body != .object) return;
        // Responses arrive in the order requested; the oldest loading entry is the one answered.
        var slot: ?*VarCache = null;
        for (self.var_cache.items) |*c| {
            if (c.items.len == 0 and !c.loaded) {
                slot = c;
                break;
            }
        }
        const target = slot orelse return;
        target.loaded = true;
        if (!res.ok) return;
        const a = self.snap.allocator();
        const list = arrayOf(res.body.object.get("variables"));
        const items = a.alloc(Variable, list.len) catch return;
        var n: usize = 0;
        for (list) |v| {
            if (v != .object) continue;
            items[n] = .{
                .name = a.dupe(u8, strOf(v.object.get("name")) orelse "") catch "",
                .value = a.dupe(u8, strOf(v.object.get("value")) orelse "") catch "",
                .type_name = a.dupe(u8, strOf(v.object.get("type")) orelse "") catch "",
                .reference = intOf(v.object.get("variablesReference")) orelse 0,
            };
            n += 1;
        }
        target.items = items[0..n];
        self.changed();
    }

    /// Forget what a stop showed (the program is running again, or ended).
    fn dropSnapshot(self: *Session) void {
        self.frames = &.{};
        self.scopes = &.{};
        self.selected = 0;
        self.var_cache.clearRetainingCapacity();
        _ = self.snap.reset(.retain_capacity);
    }

    // ---- breakpoints ----

    fn findBreakpoint(self: *const Session, file: []const u8, line: u32) ?usize {
        for (self.breakpoints.items, 0..) |b, i| {
            if (b.line == line and std.mem.eql(u8, b.file, file)) return i;
        }
        return null;
    }

    /// Add a breakpoint, or update the one on that line.
    pub fn setBreakpoint(self: *Session, file: []const u8, line: u32, enabled: bool, condition: []const u8) !void {
        if (self.findBreakpoint(file, line)) |i| {
            const b = &self.breakpoints.items[i];
            b.enabled = enabled;
            self.gpa.free(b.condition);
            b.condition = try self.gpa.dupe(u8, condition);
            b.verified = .unknown;
        } else {
            const f = try self.gpa.dupe(u8, file);
            errdefer self.gpa.free(f);
            const c = try self.gpa.dupe(u8, condition);
            errdefer self.gpa.free(c);
            const m = try self.gpa.dupe(u8, "");
            errdefer self.gpa.free(m);
            try self.breakpoints.append(self.gpa, .{ .file = f, .line = line, .enabled = enabled, .condition = c, .message = m });
        }
        self.sendFile(file);
        self.changed();
    }

    /// Toggle a breakpoint on `file:line` (added, or removed if it was there). True when it is now set.
    pub fn toggleBreakpoint(self: *Session, file: []const u8, line: u32) !bool {
        if (self.findBreakpoint(file, line)) |_| {
            self.removeBreakpoint(file, line);
            return false;
        }
        try self.setBreakpoint(file, line, true, "");
        return true;
    }

    pub fn removeBreakpoint(self: *Session, file: []const u8, line: u32) void {
        const i = self.findBreakpoint(file, line) orelse return;
        const b = self.breakpoints.orderedRemove(i);
        self.gpa.free(b.file);
        self.gpa.free(b.condition);
        self.gpa.free(b.message);
        self.sendFile(file);
        self.changed();
    }

    /// Move a breakpoint to another line (the text changed above it).
    pub fn moveBreakpoint(self: *Session, file: []const u8, from: u32, to: u32) void {
        const i = self.findBreakpoint(file, from) orelse return;
        if (from == to) return;
        // Two breakpoints may not share a line.
        if (self.findBreakpoint(file, to)) |_| return self.removeBreakpoint(file, from);
        self.breakpoints.items[i].line = to;
        self.breakpoints.items[i].verified = .unknown;
        self.sendFile(file);
        self.changed();
    }

    /// Tell the adapter all enabled breakpoints of `file` (it replaces what it had).
    fn sendFile(self: *Session, file: []const u8) void {
        if (!self.adapter_ready or !self.active()) return;
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const Spec = struct { line: u32, condition: ?[]const u8 = null };
        var specs: std.ArrayListUnmanaged(Spec) = .empty;
        for (self.breakpoints.items) |*b| {
            if (!std.mem.eql(u8, b.file, file)) continue;
            b.verified = .unknown;
            if (!b.enabled) continue;
            specs.append(a, .{ .line = b.line, .condition = if (b.condition.len > 0) b.condition else null }) catch return;
        }
        // Queued before sending: the answer may arrive from inside the call.
        self.bp_requests.append(self.gpa, .{ .seq = 0, .file = self.gpa.dupe(u8, file) catch return }) catch return;
        _ = self.client.request("setBreakpoints", .{ .source = .{ .path = file }, .breakpoints = specs.items }, client_mod.ResponseHook.bind(self, onBreakpoints)) catch {
            self.gpa.free(self.bp_requests.pop().?.file);
        };
    }

    fn onBreakpoints(self: *Session, res: *const client_mod.Response) void {
        // Answers come back in the order they were asked.
        if (self.bp_requests.items.len == 0) return;
        const req = self.bp_requests.orderedRemove(0);
        defer self.gpa.free(req.file);
        if (res.body != .object) return;
        const results = arrayOf(res.body.object.get("breakpoints"));
        // The adapter answers for the enabled breakpoints of that file, in the order sent.
        var k: usize = 0;
        for (self.breakpoints.items) |*b| {
            if (!std.mem.eql(u8, b.file, req.file) or !b.enabled) continue;
            if (k >= results.len) break;
            const r = results[k];
            k += 1;
            if (r != .object) continue;
            b.verified = if (boolOf(r.object.get("verified"), false)) .verified else .unverified;
            if (intOf(r.object.get("line"))) |l| {
                // The adapter may place it on the nearest line with code.
                if (l > 0 and @as(u32, @intCast(l)) != b.line and b.verified == .verified) {
                    // Keep the user's line: the mark shows where they put it; only note the difference.
                    var buf: [64]u8 = undefined;
                    self.replace(&b.message, std.fmt.bufPrint(&buf, "bound to line {d}", .{l}) catch "");
                }
            }
            if (strOf(r.object.get("message"))) |m| self.replace(&b.message, m);
        }
        self.changed();
    }

    fn onBreakpointEvent(self: *Session, body: std.json.Value) void {
        if (body != .object) return;
        const bp = body.object.get("breakpoint") orelse return;
        if (bp != .object) return;
        const line = intOf(bp.object.get("line")) orelse return;
        const path = if (bp.object.get("source")) |s| (if (s == .object) strOf(s.object.get("path")) else null) else null;
        const verified = boolOf(bp.object.get("verified"), false);
        for (self.breakpoints.items) |*b| {
            if (b.line == @as(u32, @intCast(@max(line, 0))) and (path == null or std.mem.eql(u8, b.file, path.?))) {
                b.verified = if (verified) .verified else .unverified;
            }
        }
        self.changed();
    }

    // ---- evaluating ----

    /// Evaluate `expression` in the selected frame; the result (or the error) goes to the console.
    pub fn evaluate(self: *Session, expression: []const u8) void {
        if (self.state != .stopped and self.state != .running) return;
        var buf: [300]u8 = undefined;
        self.say(std.fmt.bufPrint(&buf, "> {s}", .{expression}) catch expression);
        const frame: ?i64 = if (self.state == .stopped and self.selected < self.frames.len) self.frames[self.selected].id else null;
        _ = self.client.request("evaluate", .{ .expression = expression, .frameId = frame, .context = "repl" }, client_mod.ResponseHook.bind(self, onEvaluate)) catch {};
        self.changed();
    }

    fn onEvaluate(self: *Session, res: *const client_mod.Response) void {
        if (!res.ok) {
            self.say(if (res.message.len > 0) res.message else "evaluation failed");
        } else if (res.body == .object) {
            self.say(strOf(res.body.object.get("result")) orelse "");
        }
        self.changed();
    }
};

// ---- tests -----------------------------------------------------------------

const testing = std.testing;
const jsonrpc = @import("../lsp/jsonrpc.zig");

/// A scripted adapter: answers requests like a small debuggee would.
const Fake = struct {
    gpa: std.mem.Allocator,
    session: *Session = undefined,
    requests: std.ArrayListUnmanaged([]u8) = .empty,
    /// Stop (event) right after `configurationDone`, and after continue/next with this reason.
    stop_after_configure: bool = true,
    refuse_launch: bool = false,

    fn deinit(self: *Fake) void {
        for (self.requests.items) |r| self.gpa.free(r);
        self.requests.deinit(self.gpa);
    }

    fn feed(self: *Fake, comptime fmt: []const u8, args: anytype) void {
        const body = std.fmt.allocPrint(self.gpa, fmt, args) catch return;
        defer self.gpa.free(body);
        const framed = jsonrpc.frame(self.gpa, body) catch return;
        defer self.gpa.free(framed);
        self.session.client.receive(framed);
    }

    fn write(ctx: ?*anyopaque, bytes: []const u8) void {
        const self: *Fake = @ptrCast(@alignCast(ctx.?));
        var r: jsonrpc.Reader = .{ .gpa = self.gpa };
        defer r.deinit();
        r.push(bytes) catch return;
        while (r.next()) |body| {
            self.requests.append(self.gpa, self.gpa.dupe(u8, body) catch return) catch {};
            self.answer(body);
        }
    }

    fn answer(self: *Fake, body: []const u8) void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const msg = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), body, .{}) catch return;
        const seq = intOf(msg.object.get("seq")) orelse return;
        const cmd = strOf(msg.object.get("command")) orelse return;
        const ok = "{{\"seq\":0,\"type\":\"response\",\"request_seq\":{d},\"success\":true,\"command\":\"{s}\"";
        if (std.mem.eql(u8, cmd, "initialize")) {
            self.feed(ok ++ ",\"body\":{{}}}}", .{ seq, cmd });
        } else if (std.mem.eql(u8, cmd, "launch")) {
            if (self.refuse_launch) return self.feed("{{\"seq\":0,\"type\":\"response\",\"request_seq\":{d},\"success\":false,\"command\":\"launch\",\"message\":\"no such program\"}}", .{seq});
            self.feed(ok ++ "}}", .{ seq, cmd });
            self.feed("{{\"seq\":0,\"type\":\"event\",\"event\":\"initialized\"}}", .{});
        } else if (std.mem.eql(u8, cmd, "setBreakpoints")) {
            // Verify every requested line, except line 99 which has no code.
            const bps = arrayOf(msg.object.get("arguments").?.object.get("breakpoints"));
            var out: std.ArrayListUnmanaged(u8) = .empty;
            defer out.deinit(self.gpa);
            for (bps, 0..) |b, i| {
                const line = intOf(b.object.get("line")) orelse 0;
                if (i > 0) out.append(self.gpa, ',') catch {};
                out.print(self.gpa, "{{\"verified\":{s},\"line\":{d}}}", .{ if (line == 99) "false" else "true", line }) catch {};
            }
            self.feed(ok ++ ",\"body\":{{\"breakpoints\":[{s}]}}}}", .{ seq, cmd, out.items });
        } else if (std.mem.eql(u8, cmd, "configurationDone")) {
            self.feed(ok ++ "}}", .{ seq, cmd });
            if (self.stop_after_configure) self.feed("{{\"seq\":0,\"type\":\"event\",\"event\":\"stopped\",\"body\":{{\"reason\":\"breakpoint\",\"threadId\":1}}}}", .{});
        } else if (std.mem.eql(u8, cmd, "stackTrace")) {
            self.feed(ok ++ ",\"body\":{{\"stackFrames\":[{{\"id\":10,\"name\":\"inner\",\"source\":{{\"path\":\"/p/a.zig\"}},\"line\":5,\"column\":3}},{{\"id\":11,\"name\":\"main\",\"source\":{{\"path\":\"/p/a.zig\"}},\"line\":12,\"column\":1}}],\"totalFrames\":2}}}}", .{ seq, cmd });
        } else if (std.mem.eql(u8, cmd, "scopes")) {
            const frame = intOf(msg.object.get("arguments").?.object.get("frameId")) orelse 0;
            self.feed(ok ++ ",\"body\":{{\"scopes\":[{{\"name\":\"Locals\",\"variablesReference\":{d},\"expensive\":false}},{{\"name\":\"Registers\",\"variablesReference\":900,\"expensive\":true}}]}}}}", .{ seq, cmd, frame * 100 });
        } else if (std.mem.eql(u8, cmd, "variables")) {
            const ref = intOf(msg.object.get("arguments").?.object.get("variablesReference")) orelse 0;
            if (ref == 1000) {
                self.feed(ok ++ ",\"body\":{{\"variables\":[{{\"name\":\"x\",\"value\":\"42\",\"type\":\"i32\",\"variablesReference\":0}},{{\"name\":\"pt\",\"value\":\"{{...}}\",\"type\":\"Point\",\"variablesReference\":2000}}]}}}}", .{ seq, cmd });
            } else if (ref == 2000) {
                self.feed(ok ++ ",\"body\":{{\"variables\":[{{\"name\":\"px\",\"value\":\"1\",\"type\":\"i32\",\"variablesReference\":0}}]}}}}", .{ seq, cmd });
            } else {
                self.feed(ok ++ ",\"body\":{{\"variables\":[{{\"name\":\"y\",\"value\":\"7\",\"type\":\"i32\",\"variablesReference\":0}}]}}}}", .{ seq, cmd });
            }
        } else if (std.mem.eql(u8, cmd, "next") or std.mem.eql(u8, cmd, "stepIn") or std.mem.eql(u8, cmd, "stepOut")) {
            self.feed(ok ++ "}}", .{ seq, cmd });
            self.feed("{{\"seq\":0,\"type\":\"event\",\"event\":\"stopped\",\"body\":{{\"reason\":\"step\",\"threadId\":1}}}}", .{});
        } else if (std.mem.eql(u8, cmd, "continue")) {
            self.feed(ok ++ ",\"body\":{{\"allThreadsContinued\":true}}}}", .{ seq, cmd });
            self.feed("{{\"seq\":0,\"type\":\"event\",\"event\":\"output\",\"body\":{{\"category\":\"stdout\",\"output\":\"hello\\n\"}}}}", .{});
            self.feed("{{\"seq\":0,\"type\":\"event\",\"event\":\"exited\",\"body\":{{\"exitCode\":3}}}}", .{});
            self.feed("{{\"seq\":0,\"type\":\"event\",\"event\":\"terminated\"}}", .{});
        } else if (std.mem.eql(u8, cmd, "evaluate")) {
            self.feed(ok ++ ",\"body\":{{\"result\":\"43\",\"variablesReference\":0}}}}", .{ seq, cmd });
        } else if (std.mem.eql(u8, cmd, "disconnect")) {
            self.feed(ok ++ "}}", .{ seq, cmd });
        }
    }

    fn count(self: *const Fake, command: []const u8) usize {
        var n: usize = 0;
        var buf: [64]u8 = undefined;
        const needle = std.fmt.bufPrint(&buf, "\"command\":\"{s}\"", .{command}) catch return 0;
        for (self.requests.items) |r| {
            if (std.mem.indexOf(u8, r, needle) != null) n += 1;
        }
        return n;
    }
};

fn makeSession(fake: *Fake) !*Session {
    const s = try Session.create(testing.allocator, .{ .ctx = fake, .call = Fake.write });
    fake.session = s;
    return s;
}

test "starting: initialize, launch, breakpoints on `initialized`, configurationDone, then the first stop fills stack, scopes and locals" {
    var fake: Fake = .{ .gpa = testing.allocator };
    defer fake.deinit();
    const s = try makeSession(&fake);
    defer s.destroy();
    // Breakpoints set before the session starts are sent once the adapter is ready.
    try s.setBreakpoint("/p/a.zig", 5, true, "");
    try s.setBreakpoint("/p/a.zig", 99, true, "x > 1");
    try testing.expectEqual(@as(usize, 0), fake.count("setBreakpoints"));
    try s.start(.{ .program = "/p/app", .cwd = "/p", .args = &.{"-v"} });

    try testing.expectEqual(State.stopped, s.state);
    try testing.expectEqualStrings("breakpoint", s.stop_reason);
    try testing.expectEqual(@as(usize, 1), fake.count("setBreakpoints")); // one request for the file
    try testing.expect(std.mem.indexOf(u8, fake.requests.items[1], "\"program\":\"/p/app\"") != null);
    try testing.expect(std.mem.indexOf(u8, fake.requests.items[1], "\"args\":[\"-v\"]") != null);
    // Verified by the adapter, except the line without code.
    try testing.expect(s.breakpoints.items[0].verified == .verified);
    try testing.expect(s.breakpoints.items[1].verified == .unverified);
    try testing.expectEqual(@as(usize, 2), s.frames.len);
    try testing.expectEqualStrings("inner", s.frames[0].name);
    try testing.expectEqual(@as(u32, 5), s.frames[0].line);
    try testing.expectEqualStrings("/p/a.zig", s.frames[0].path);
    try testing.expectEqual(@as(usize, 2), s.scopes.len);
    try testing.expectEqualStrings("Locals", s.scopes[0].name);
    // The locals scope loaded by itself; the expensive one did not.
    const locals = s.variables(s.scopes[0].reference).?;
    try testing.expectEqual(@as(usize, 2), locals.len);
    try testing.expectEqualStrings("42", locals[0].value);
    try testing.expect(s.variables(s.scopes[1].reference) == null);
}

test "expanding a variable loads its children once; selecting another frame reloads scopes" {
    var fake: Fake = .{ .gpa = testing.allocator };
    defer fake.deinit();
    const s = try makeSession(&fake);
    defer s.destroy();
    try s.start(.{ .program = "/p/app" });
    const locals = s.variables(s.scopes[0].reference).?;
    try testing.expectEqual(@as(i64, 2000), locals[1].reference);
    s.expand(2000);
    s.expand(2000); // already loaded: no second request
    try testing.expectEqualStrings("px", s.variables(2000).?[0].name);
    try testing.expectEqual(@as(usize, 2), fake.count("variables")); // locals + pt

    s.selectFrame(1);
    try testing.expectEqual(@as(usize, 1), s.selected);
    try testing.expectEqual(@as(i64, 1100), s.scopes[0].reference);
    try testing.expectEqualStrings("y", s.variables(1100).?[0].name);
}

test "stepping resumes and stops again; continuing to the end terminates with the exit code and output" {
    var fake: Fake = .{ .gpa = testing.allocator };
    defer fake.deinit();
    const s = try makeSession(&fake);
    defer s.destroy();
    try s.start(.{ .program = "/p/app" });
    s.stepOver();
    try testing.expectEqual(State.stopped, s.state);
    try testing.expectEqualStrings("step", s.stop_reason);
    try testing.expectEqual(@as(usize, 1), fake.count("next"));
    s.stepIn();
    s.stepOut();
    try testing.expectEqual(@as(usize, 1), fake.count("stepIn") + fake.count("stepOut") - 1);

    s.continueRun();
    try testing.expectEqual(State.terminated, s.state);
    try testing.expectEqual(@as(?i64, 3), s.exit_code);
    try testing.expectEqual(@as(usize, 0), s.frames.len); // the stop's data is gone
    var saw_output = false;
    var saw_exit = false;
    for (s.console.items) |l| {
        if (std.mem.eql(u8, l, "hello")) saw_output = true;
        if (std.mem.indexOf(u8, l, "exited with code 3") != null) saw_exit = true;
    }
    try testing.expect(saw_output and saw_exit);
}

test "breakpoints added, moved and removed during a stop are sent again; evaluate answers into the console" {
    var fake: Fake = .{ .gpa = testing.allocator };
    defer fake.deinit();
    const s = try makeSession(&fake);
    defer s.destroy();
    try s.start(.{ .program = "/p/app" });
    try testing.expectEqual(@as(usize, 0), fake.count("setBreakpoints"));
    try testing.expect(try s.toggleBreakpoint("/p/a.zig", 8));
    try testing.expectEqual(@as(usize, 1), fake.count("setBreakpoints"));
    try testing.expect(s.breakpoints.items[0].verified == .verified);
    s.moveBreakpoint("/p/a.zig", 8, 9);
    try testing.expectEqual(@as(u32, 9), s.breakpoints.items[0].line);
    try testing.expect(!try s.toggleBreakpoint("/p/a.zig", 9)); // toggled off
    try testing.expectEqual(@as(usize, 0), s.breakpoints.items.len);
    try testing.expectEqual(@as(usize, 3), fake.count("setBreakpoints"));

    s.evaluate("x + 1");
    try testing.expectEqualStrings("> x + 1", s.console.items[s.console.items.len - 2]);
    try testing.expectEqualStrings("43", s.console.items[s.console.items.len - 1]);
}

test "a refused launch ends the session with the adapter's message; stop disconnects" {
    var fake: Fake = .{ .gpa = testing.allocator, .refuse_launch = true };
    defer fake.deinit();
    const s = try makeSession(&fake);
    defer s.destroy();
    try s.start(.{ .program = "/nope" });
    try testing.expectEqual(State.terminated, s.state);
    try testing.expectEqualStrings("no such program", s.failure);

    var fake2: Fake = .{ .gpa = testing.allocator };
    defer fake2.deinit();
    const s2 = try makeSession(&fake2);
    defer s2.destroy();
    try s2.start(.{ .program = "/p/app" });
    s2.stop();
    try testing.expectEqual(State.terminated, s2.state);
    try testing.expectEqual(@as(usize, 1), fake2.count("disconnect"));
}
