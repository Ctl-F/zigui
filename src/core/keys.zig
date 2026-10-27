//! Platform-independent key identifiers, modifier bits, and key chords.
//!
//! `Key` names the keys the toolkit reacts to (navigation, editing, letters,
//! digits, common punctuation, function keys). Platform shims translate their
//! native codes into it; anything unmapped is `.unknown`, and the raw platform
//! codes still travel in the event.
//!
//! A `Chord` is one key plus modifiers ("ctrl+shift+p"). Shortcuts bind
//! sequences of chords. Text form: tokens joined by `+`, modifiers first
//! (`ctrl`, `shift`, `alt`, `gui`/`cmd`/`super`, and `mod`, which means Cmd on
//! macOS and Ctrl elsewhere), then a key name (`a`..`z`, `0`..`9`, `enter`,
//! `esc`, `f5`, `,`, `/`, ...). Sequences separate chords with spaces.

const std = @import("std");
const builtin = @import("builtin");

pub const Key = enum(u32) {
    unknown = 0,
    a, b, c, d, e, f, g, h, i, j, k, l, m,
    n, o, p, q, r, s, t, u, v, w, x, y, z,
    enter,
    escape,
    backspace,
    tab,
    space,
    delete,
    insert,
    left,
    right,
    up,
    down,
    home,
    end,
    page_up,
    page_down,
    f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12,
    d0, d1, d2, d3, d4, d5, d6, d7, d8, d9,
    minus,
    equals,
    left_bracket,
    right_bracket,
    backslash,
    semicolon,
    quote,
    grave,
    comma,
    period,
    slash,
    _,

    /// A key that produces text when typed (letters, digits, punctuation, space).
    /// These arrive as `text_input` too, so unmodified bindings on them must not
    /// fire while the user is typing.
    pub fn isPrintable(self: Key) bool {
        const v = @intFromEnum(self);
        return (v >= @intFromEnum(Key.a) and v <= @intFromEnum(Key.z)) or
            self == .space or
            (v >= @intFromEnum(Key.d0) and v <= @intFromEnum(Key.slash));
    }
};

/// Modifier keys held during an event.
pub const Mods = packed struct(u4) {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    /// Windows/Command/Super key.
    gui: bool = false,

    pub const none: Mods = .{};

    /// The "primary shortcut" modifier: Cmd on macOS, Ctrl elsewhere.
    pub const primary: Mods = if (builtin.os.tag == .macos) .{ .gui = true } else .{ .ctrl = true };

    pub fn bits(self: Mods) u4 {
        return @bitCast(self);
    }

    pub fn eql(a: Mods, b: Mods) bool {
        return a.bits() == b.bits();
    }

    pub fn isEmpty(self: Mods) bool {
        return self.bits() == 0;
    }

    /// True if any modifier set in `other` is also set here.
    pub fn any(self: Mods, other: Mods) bool {
        return self.bits() & other.bits() != 0;
    }

    pub fn merge(a: Mods, b: Mods) Mods {
        return @bitCast(a.bits() | b.bits());
    }

    /// Command-style shortcuts: Ctrl, or Cmd on macOS.
    pub fn command(self: Mods) bool {
        return self.ctrl or self.gui;
    }

    /// Modifiers other than Shift (what distinguishes a shortcut from typing).
    pub fn withoutShift(self: Mods) Mods {
        var m = self;
        m.shift = false;
        return m;
    }
};

pub const Chord = struct {
    key: Key,
    mods: Mods = .{},

    pub fn eql(a: Chord, b: Chord) bool {
        return a.key == b.key and a.mods.eql(b.mods);
    }

    /// True for a chord that is just typing: a printable key with no modifier
    /// other than Shift.
    pub fn isTyping(self: Chord) bool {
        return self.key.isPrintable() and self.mods.withoutShift().isEmpty();
    }
};

/// Longest chord sequence a binding may have.
pub const max_sequence = 4;

const key_names = [_]struct { name: []const u8, key: Key }{
    .{ .name = "enter", .key = .enter },
    .{ .name = "return", .key = .enter },
    .{ .name = "esc", .key = .escape },
    .{ .name = "escape", .key = .escape },
    .{ .name = "backspace", .key = .backspace },
    .{ .name = "tab", .key = .tab },
    .{ .name = "space", .key = .space },
    .{ .name = "delete", .key = .delete },
    .{ .name = "del", .key = .delete },
    .{ .name = "insert", .key = .insert },
    .{ .name = "left", .key = .left },
    .{ .name = "right", .key = .right },
    .{ .name = "up", .key = .up },
    .{ .name = "down", .key = .down },
    .{ .name = "home", .key = .home },
    .{ .name = "end", .key = .end },
    .{ .name = "pageup", .key = .page_up },
    .{ .name = "pagedown", .key = .page_down },
    .{ .name = "minus", .key = .minus },
    .{ .name = "equals", .key = .equals },
    .{ .name = "comma", .key = .comma },
    .{ .name = "period", .key = .period },
    .{ .name = "slash", .key = .slash },
    .{ .name = "-", .key = .minus },
    .{ .name = "=", .key = .equals },
    .{ .name = "[", .key = .left_bracket },
    .{ .name = "]", .key = .right_bracket },
    .{ .name = "\\", .key = .backslash },
    .{ .name = ";", .key = .semicolon },
    .{ .name = "'", .key = .quote },
    .{ .name = "`", .key = .grave },
    .{ .name = ",", .key = .comma },
    .{ .name = ".", .key = .period },
    .{ .name = "/", .key = .slash },
};

/// Parse a key name ("a", "5", "f3", "enter", "/") case-insensitively.
pub fn parseKey(name: []const u8) ?Key {
    if (name.len == 1) {
        const c = std.ascii.toLower(name[0]);
        if (c >= 'a' and c <= 'z') return @enumFromInt(@intFromEnum(Key.a) + (c - 'a'));
        if (c >= '0' and c <= '9') return @enumFromInt(@intFromEnum(Key.d0) + (c - '0'));
    }
    if (name.len >= 2 and name.len <= 3 and (name[0] == 'f' or name[0] == 'F')) {
        const n = std.fmt.parseInt(u8, name[1..], 10) catch return lookupName(name);
        if (n >= 1 and n <= 12) return @enumFromInt(@intFromEnum(Key.f1) + (n - 1));
    }
    return lookupName(name);
}

fn lookupName(name: []const u8) ?Key {
    for (key_names) |e| if (std.ascii.eqlIgnoreCase(e.name, name)) return e.key;
    return null;
}

/// Parse "ctrl+shift+p". Null if a token is unknown or the key is missing.
pub fn parseChord(text: []const u8) ?Chord {
    if (text.len == 0) return null;
    var mods: Mods = .{};
    var key: ?Key = null;
    // A trailing "+" is the plus key written as "ctrl++"; treat "+" alone as unsupported.
    var it = std.mem.splitScalar(u8, text, '+');
    while (it.next()) |tok| {
        if (key != null) return null; // nothing may follow the key
        if (std.ascii.eqlIgnoreCase(tok, "ctrl") or std.ascii.eqlIgnoreCase(tok, "control")) {
            mods.ctrl = true;
        } else if (std.ascii.eqlIgnoreCase(tok, "shift")) {
            mods.shift = true;
        } else if (std.ascii.eqlIgnoreCase(tok, "alt") or std.ascii.eqlIgnoreCase(tok, "option")) {
            mods.alt = true;
        } else if (std.ascii.eqlIgnoreCase(tok, "gui") or std.ascii.eqlIgnoreCase(tok, "cmd") or std.ascii.eqlIgnoreCase(tok, "super")) {
            mods.gui = true;
        } else if (std.ascii.eqlIgnoreCase(tok, "mod")) {
            mods = mods.merge(Mods.primary);
        } else {
            key = parseKey(tok) orelse return null;
        }
    }
    return .{ .key = key orelse return null, .mods = mods };
}

/// Parse a space-separated chord sequence into `out`; returns the count, or
/// null if empty, too long, or any chord is invalid.
pub fn parseSequence(text: []const u8, out: *[max_sequence]Chord) ?usize {
    var n: usize = 0;
    var it = std.mem.tokenizeScalar(u8, text, ' ');
    while (it.next()) |tok| {
        if (n == max_sequence) return null;
        out[n] = parseChord(tok) orelse return null;
        n += 1;
    }
    return if (n == 0) null else n;
}

fn keyLabel(k: Key) []const u8 {
    for (key_names) |e| {
        if (e.key == k and e.name.len > 1) {
            return switch (k) {
                .enter => "Enter",
                .escape => "Esc",
                .backspace => "Backspace",
                .tab => "Tab",
                .space => "Space",
                .delete => "Delete",
                .insert => "Insert",
                .left => "Left",
                .right => "Right",
                .up => "Up",
                .down => "Down",
                .home => "Home",
                .end => "End",
                .page_up => "PageUp",
                .page_down => "PageDown",
                else => e.name,
            };
        }
    }
    return "?";
}

/// Human-readable form for menus and tooltips ("Ctrl+Shift+P"). Writes into
/// `buf` and returns the used slice (truncated if `buf` is too small).
pub fn formatChord(c: Chord, buf: []u8) []const u8 {
    var w: usize = 0;
    const put = struct {
        fn f(b: []u8, at: *usize, s: []const u8) void {
            const n = @min(s.len, b.len - at.*);
            @memcpy(b[at.*..][0..n], s[0..n]);
            at.* += n;
        }
    }.f;
    if (c.mods.ctrl) put(buf, &w, "Ctrl+");
    if (c.mods.alt) put(buf, &w, "Alt+");
    if (c.mods.shift) put(buf, &w, "Shift+");
    if (c.mods.gui) put(buf, &w, if (builtin.os.tag == .macos) "Cmd+" else "Super+");

    const v = @intFromEnum(c.key);
    var one: [2]u8 = undefined;
    if (v >= @intFromEnum(Key.a) and v <= @intFromEnum(Key.z)) {
        one[0] = 'A' + @as(u8, @intCast(v - @intFromEnum(Key.a)));
        put(buf, &w, one[0..1]);
    } else if (v >= @intFromEnum(Key.d0) and v <= @intFromEnum(Key.d9)) {
        one[0] = '0' + @as(u8, @intCast(v - @intFromEnum(Key.d0)));
        put(buf, &w, one[0..1]);
    } else if (v >= @intFromEnum(Key.f1) and v <= @intFromEnum(Key.f12)) {
        var tmp: [4]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "F{d}", .{v - @intFromEnum(Key.f1) + 1}) catch "F?";
        put(buf, &w, s);
    } else {
        // Punctuation: show the symbol (its single-character name).
        var shown: []const u8 = keyLabel(c.key);
        for (key_names) |e| {
            if (e.key == c.key and e.name.len == 1) {
                shown = e.name;
                break;
            }
        }
        put(buf, &w, shown);
    }
    return buf[0..w];
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

test "parse keys: letters, digits, function keys, names, punctuation" {
    try testing.expectEqual(Key.a, parseKey("a").?);
    try testing.expectEqual(Key.z, parseKey("Z").?);
    try testing.expectEqual(Key.d0, parseKey("0").?);
    try testing.expectEqual(Key.d9, parseKey("9").?);
    try testing.expectEqual(Key.f1, parseKey("f1").?);
    try testing.expectEqual(Key.f12, parseKey("F12").?);
    try testing.expect(parseKey("f13") == null);
    try testing.expectEqual(Key.escape, parseKey("ESC").?);
    try testing.expectEqual(Key.enter, parseKey("return").?);
    try testing.expectEqual(Key.slash, parseKey("/").?);
    try testing.expectEqual(Key.comma, parseKey(",").?);
    try testing.expectEqual(Key.page_down, parseKey("PageDown").?);
    try testing.expect(parseKey("nonsense") == null);
    try testing.expect(parseKey("") == null);
}

test "parse chords with modifiers in any order and case" {
    const c = parseChord("Ctrl+Shift+P").?;
    try testing.expectEqual(Key.p, c.key);
    try testing.expect(c.mods.eql(.{ .ctrl = true, .shift = true }));
    try testing.expect(Chord.eql(parseChord("shift+ctrl+p").?, c));
    try testing.expect(Chord.eql(parseChord("alt+left").?, .{ .key = .left, .mods = .{ .alt = true } }));
    try testing.expect(Chord.eql(parseChord("cmd+s").?, .{ .key = .s, .mods = .{ .gui = true } }));
    try testing.expect(Chord.eql(parseChord("mod+s").?, .{ .key = .s, .mods = Mods.primary }));
    try testing.expect(Chord.eql(parseChord("f5").?, .{ .key = .f5 }));
    try testing.expect(parseChord("ctrl+") == null); // no key
    try testing.expect(parseChord("ctrl") == null);
    try testing.expect(parseChord("p+ctrl") == null); // nothing after the key
    try testing.expect(parseChord("ctrl+bogus") == null);
    try testing.expect(parseChord("") == null);
}

test "parse sequences" {
    var seq: [max_sequence]Chord = undefined;
    try testing.expectEqual(@as(usize, 2), parseSequence("ctrl+k ctrl+c", &seq).?);
    try testing.expect(Chord.eql(seq[0], .{ .key = .k, .mods = .{ .ctrl = true } }));
    try testing.expect(Chord.eql(seq[1], .{ .key = .c, .mods = .{ .ctrl = true } }));
    try testing.expectEqual(@as(usize, 1), parseSequence("  f2  ", &seq).?);
    try testing.expect(parseSequence("", &seq) == null);
    try testing.expect(parseSequence("a b c d e", &seq) == null); // too long
    try testing.expect(parseSequence("a bogus", &seq) == null);
}

test "format chords for display" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("Ctrl+Shift+P", formatChord(.{ .key = .p, .mods = .{ .ctrl = true, .shift = true } }, &buf));
    try testing.expectEqualStrings("Alt+Left", formatChord(.{ .key = .left, .mods = .{ .alt = true } }, &buf));
    try testing.expectEqualStrings("F5", formatChord(.{ .key = .f5 }, &buf));
    try testing.expectEqualStrings("Ctrl+7", formatChord(.{ .key = .d7, .mods = .{ .ctrl = true } }, &buf));
    try testing.expectEqualStrings("Ctrl+/", formatChord(.{ .key = .slash, .mods = .{ .ctrl = true } }, &buf));
    try testing.expectEqualStrings("Enter", formatChord(.{ .key = .enter }, &buf));
    var tiny: [4]u8 = undefined;
    try testing.expectEqualStrings("Ctrl", formatChord(.{ .key = .p, .mods = .{ .ctrl = true } }, &tiny)); // truncates safely
}

test "format and parse agree" {
    var buf: [32]u8 = undefined;
    const chords = [_]Chord{
        .{ .key = .a, .mods = .{ .ctrl = true } },
        .{ .key = .d3, .mods = .{ .alt = true, .shift = true } },
        .{ .key = .f12 },
        .{ .key = .tab, .mods = .{ .shift = true } },
        .{ .key = .period, .mods = .{ .ctrl = true } },
        .{ .key = .page_up },
    };
    for (chords) |c| {
        const text = formatChord(c, &buf);
        try testing.expect(Chord.eql(parseChord(text).?, c));
    }
}

test "typing chords and printable keys" {
    try testing.expect((Chord{ .key = .a }).isTyping());
    try testing.expect((Chord{ .key = .a, .mods = .{ .shift = true } }).isTyping());
    try testing.expect((Chord{ .key = .space }).isTyping());
    try testing.expect(!(Chord{ .key = .a, .mods = .{ .ctrl = true } }).isTyping());
    try testing.expect(!(Chord{ .key = .enter }).isTyping());
    try testing.expect(!(Chord{ .key = .left }).isTyping());
    try testing.expect(Key.slash.isPrintable() and Key.d5.isPrintable());
    try testing.expect(!Key.f5.isPrintable());
}
