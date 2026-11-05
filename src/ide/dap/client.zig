//! A Debug Adapter Protocol client: requests with callbacks, and events to a hook.
//! DAP frames messages like the language server protocol (`Content-Length`), so
//! this reuses `lsp/jsonrpc.zig`; the messages differ:
//!
//!     {"seq":1,"type":"request","command":"initialize","arguments":{...}}
//!     {"seq":1,"type":"response","request_seq":1,"success":true,"command":"initialize","body":{...}}
//!     {"seq":2,"type":"event","event":"stopped","body":{...}}
//!
//! Single-threaded like `lsp/client.zig`: the UI thread calls `receive` with the
//! bytes the adapter wrote and the client writes through the `Send` it was given.
//! Callbacks get parsed JSON that is valid only during the call. No process here
//! (`../debug_session.zig` and `../debugger.zig` own the adapter process).
//!
//!     const c = try Client.create(gpa, .{ .ctx = &adapter, .call = Adapter.write });
//!     defer c.destroy();
//!     c.on_event = EventHook.bind(&session, Session.event);
//!     _ = try c.request("initialize", .{ .adapterID = "x" }, ResponseHook.bind(&session, Session.initialized));
//!     c.receive(bytes_from_adapter);

const std = @import("std");
const jsonrpc = @import("../lsp/jsonrpc.zig");

/// Writes one framed message (header included) to the adapter.
pub const Send = struct {
    ctx: ?*anyopaque = null,
    call: *const fn (ctx: ?*anyopaque, bytes: []const u8) void,
};

pub const Response = struct {
    /// False when the adapter answered `success: false` (see `message`).
    ok: bool,
    /// `body` (`.null` for none).
    body: std.json.Value,
    message: []const u8 = "",
    /// For building lists while reading `body` (freed after the callback).
    arena: std.mem.Allocator,
};

pub const ResponseHook = struct {
    ctx: ?*anyopaque = null,
    call: *const fn (ctx: ?*anyopaque, res: *const Response) void,

    pub fn bind(ctx: anytype, comptime f: anytype) ResponseHook {
        const Ptr = @TypeOf(ctx);
        return .{
            .ctx = @ptrCast(ctx),
            .call = &struct {
                fn thunk(c: ?*anyopaque, res: *const Response) void {
                    f(@as(Ptr, @ptrCast(@alignCast(c.?))), res);
                }
            }.thunk,
        };
    }
};

pub const EventHook = struct {
    ctx: ?*anyopaque = null,
    call: *const fn (ctx: ?*anyopaque, name: []const u8, body: std.json.Value) void,

    pub fn bind(ctx: anytype, comptime f: anytype) EventHook {
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

const Pending = struct { seq: u32, hook: ?ResponseHook };

pub const Client = struct {
    gpa: std.mem.Allocator,
    send: Send,
    reader: jsonrpc.Reader,
    seq: u32 = 1,
    pending: std.ArrayListUnmanaged(Pending) = .empty,
    on_event: ?EventHook = null,

    pub fn create(gpa: std.mem.Allocator, send: Send) !*Client {
        const self = try gpa.create(Client);
        self.* = .{ .gpa = gpa, .send = send, .reader = .{ .gpa = gpa } };
        return self;
    }

    pub fn destroy(self: *Client) void {
        self.pending.deinit(self.gpa);
        self.reader.deinit();
        self.gpa.destroy(self);
    }

    /// Forget everything in flight (a new adapter process is about to be used).
    pub fn reset(self: *Client) void {
        self.pending.clearRetainingCapacity();
        self.reader.buf.clearRetainingCapacity();
        self.reader.pos = 0;
    }

    fn write(self: *Client, body: []const u8) void {
        const framed = jsonrpc.frame(self.gpa, body) catch return;
        defer self.gpa.free(framed);
        self.send.call(self.send.ctx, framed);
    }

    /// Send a request; `hook` (optional) gets the answer. Returns its `seq`.
    pub fn request(self: *Client, command: []const u8, args: anytype, hook: ?ResponseHook) !u32 {
        const seq = self.seq;
        self.seq += 1;
        const a = try std.json.Stringify.valueAlloc(self.gpa, args, .{ .emit_null_optional_fields = false });
        defer self.gpa.free(a);
        const body = try std.fmt.allocPrint(self.gpa, "{{\"seq\":{d},\"type\":\"request\",\"command\":\"{s}\",\"arguments\":{s}}}", .{ seq, command, a });
        defer self.gpa.free(body);
        // Registered before writing: an adapter (or a test fake) may answer from inside `write`.
        try self.pending.append(self.gpa, .{ .seq = seq, .hook = hook });
        errdefer _ = self.pending.pop();
        self.write(body);
        return seq;
    }

    /// Forget a request's callback (the answer is ignored when it arrives).
    pub fn cancel(self: *Client, seq: u32) void {
        for (self.pending.items) |*p| {
            if (p.seq == seq) p.hook = null;
        }
    }

    /// Bytes the adapter wrote.
    pub fn receive(self: *Client, bytes: []const u8) void {
        self.reader.push(bytes) catch return;
        while (self.reader.next()) |body| self.handle(body);
    }

    fn handle(self: *Client, body: []const u8) void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const msg = std.json.parseFromSliceLeaky(std.json.Value, a, body, .{}) catch return;
        if (msg != .object) return;
        const obj = msg.object;
        const kind = strOf(obj.get("type")) orelse return;
        if (std.mem.eql(u8, kind, "response")) {
            self.response(a, obj);
        } else if (std.mem.eql(u8, kind, "event")) {
            const name = strOf(obj.get("event")) orelse return;
            const h = self.on_event orelse return;
            h.call(h.ctx, name, obj.get("body") orelse .null);
        } else if (std.mem.eql(u8, kind, "request")) {
            // Requests from the adapter (`runInTerminal`, `startDebugging`): not supported.
            const seq = intOf(obj.get("seq")) orelse return;
            const command = strOf(obj.get("command")) orelse "";
            const out = std.fmt.allocPrint(a, "{{\"seq\":{d},\"type\":\"response\",\"request_seq\":{d},\"success\":false,\"command\":\"{s}\",\"message\":\"not supported by this client\"}}", .{ self.seq, seq, command }) catch return;
            self.seq += 1;
            self.write(out);
        }
    }

    fn response(self: *Client, a: std.mem.Allocator, obj: std.json.ObjectMap) void {
        const rs = intOf(obj.get("request_seq")) orelse return;
        var found: ?Pending = null;
        for (self.pending.items, 0..) |p, i| {
            if (p.seq == rs) {
                found = p;
                _ = self.pending.orderedRemove(i);
                break;
            }
        }
        const p = found orelse return;
        const h = p.hook orelse return;
        const ok = if (obj.get("success")) |s| (s == .bool and s.bool) else false;
        h.call(h.ctx, &.{ .ok = ok, .body = obj.get("body") orelse .null, .message = strOf(obj.get("message")) orelse "", .arena = a });
    }
};

// ---- reading JSON ----------------------------------------------------------

pub fn strOf(v: ?std.json.Value) ?[]const u8 {
    const x = v orelse return null;
    return if (x == .string) x.string else null;
}

pub fn intOf(v: ?std.json.Value) ?i64 {
    const x = v orelse return null;
    return switch (x) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => null,
    };
}

pub fn boolOf(v: ?std.json.Value, default: bool) bool {
    const x = v orelse return default;
    return if (x == .bool) x.bool else default;
}

pub fn arrayOf(v: ?std.json.Value) []const std.json.Value {
    const x = v orelse return &.{};
    return if (x == .array) x.array.items else &.{};
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

const Wire = struct {
    gpa: std.mem.Allocator,
    sent: std.ArrayListUnmanaged([]u8) = .empty,
    fn write(ctx: ?*anyopaque, bytes: []const u8) void {
        const self: *Wire = @ptrCast(@alignCast(ctx.?));
        var r: jsonrpc.Reader = .{ .gpa = self.gpa };
        defer r.deinit();
        r.push(bytes) catch return;
        while (r.next()) |body| self.sent.append(self.gpa, self.gpa.dupe(u8, body) catch return) catch {};
    }
    fn deinit(self: *Wire) void {
        for (self.sent.items) |m| self.gpa.free(m);
        self.sent.deinit(self.gpa);
    }
};

const Got = struct {
    ok: ?bool = null,
    name: [32]u8 = undefined,
    name_len: usize = 0,
    thread: i64 = -1,
    fn response(self: *Got, res: *const Response) void {
        self.ok = res.ok;
        if (intOf(res.body.object.get("n"))) |n| self.thread = n;
    }
    fn event(self: *Got, name: []const u8, body: std.json.Value) void {
        @memcpy(self.name[0..name.len], name);
        self.name_len = name.len;
        if (body == .object) self.thread = intOf(body.object.get("threadId")) orelse -1;
    }
};

fn serve(c: *Client, comptime fmt: []const u8, args: anytype) !void {
    const body = try std.fmt.allocPrint(testing.allocator, fmt, args);
    defer testing.allocator.free(body);
    const framed = try jsonrpc.frame(testing.allocator, body);
    defer testing.allocator.free(framed);
    c.receive(framed);
}

test "a request goes out as a DAP envelope and its response reaches the hook; events reach the event hook" {
    var wire: Wire = .{ .gpa = testing.allocator };
    defer wire.deinit();
    const c = try Client.create(testing.allocator, .{ .ctx = &wire, .call = Wire.write });
    defer c.destroy();
    var got: Got = .{};
    c.on_event = EventHook.bind(&got, Got.event);
    const seq = try c.request("initialize", .{ .adapterID = "zigui", .linesStartAt1 = true }, ResponseHook.bind(&got, Got.response));
    try testing.expectEqual(@as(u32, 1), seq);
    try testing.expectEqualStrings("{\"seq\":1,\"type\":\"request\",\"command\":\"initialize\",\"arguments\":{\"adapterID\":\"zigui\",\"linesStartAt1\":true}}", wire.sent.items[0]);

    try serve(c, "{{\"seq\":1,\"type\":\"response\",\"request_seq\":1,\"success\":true,\"command\":\"initialize\",\"body\":{{\"n\":7}}}}", .{});
    try testing.expectEqual(@as(?bool, true), got.ok);
    try testing.expectEqual(@as(i64, 7), got.thread);
    try serve(c, "{{\"seq\":2,\"type\":\"event\",\"event\":\"stopped\",\"body\":{{\"threadId\":3}}}}", .{});
    try testing.expectEqualStrings("stopped", got.name[0..got.name_len]);
    try testing.expectEqual(@as(i64, 3), got.thread);
}

test "a failed response, a cancelled request, and a request from the adapter" {
    var wire: Wire = .{ .gpa = testing.allocator };
    defer wire.deinit();
    const c = try Client.create(testing.allocator, .{ .ctx = &wire, .call = Wire.write });
    defer c.destroy();
    var got: Got = .{};
    const a = try c.request("launch", .{}, ResponseHook.bind(&got, Got.response));
    try serve(c, "{{\"seq\":5,\"type\":\"response\",\"request_seq\":{d},\"success\":false,\"command\":\"launch\",\"message\":\"no such file\",\"body\":{{\"n\":1}}}}", .{a});
    try testing.expectEqual(@as(?bool, false), got.ok);

    got.ok = null;
    const b = try c.request("next", .{ .threadId = 1 }, ResponseHook.bind(&got, Got.response));
    c.cancel(b);
    try serve(c, "{{\"seq\":6,\"type\":\"response\",\"request_seq\":{d},\"success\":true,\"command\":\"next\"}}", .{b});
    try testing.expect(got.ok == null);

    // `runInTerminal` is answered with a failure so the adapter does not wait.
    try serve(c, "{{\"seq\":9,\"type\":\"request\",\"command\":\"runInTerminal\",\"arguments\":{{}}}}", .{});
    const last = wire.sent.items[wire.sent.items.len - 1];
    try testing.expect(std.mem.indexOf(u8, last, "\"request_seq\":9") != null and std.mem.indexOf(u8, last, "\"success\":false") != null);
}
