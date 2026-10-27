//! Glyph atlas: rasterized glyph bitmaps packed into fixed-size 8-bit pages.
//!
//! - Pages are 1024x1024 coverage bitmaps, shelf-packed, allocated lazily up
//!   to `max_pages`.
//! - Entries are keyed by font, glyph, size (quantized) and subpixel bucket.
//! - When every page is full, the least-recently-used page is cleared and its
//!   entries dropped. A page used during the current frame is never evicted,
//!   so a glyph handed out this frame stays valid until `beginFrame`; if all
//!   pages were used this frame the glyph is skipped (`null`) instead.
//! - Glyphs are separated by a 1px gutter so bilinear sampling on a GPU
//!   backend does not bleed neighbors in.

const std = @import("std");
const font = @import("font.zig");

pub const page_size: u32 = 1024;
pub const max_pages = 4;
pub const subpixel_steps: u32 = 4;
const gutter: u32 = 1;

pub const Key = struct {
    font: u32,
    glyph: u32,
    /// Device pixel size in 1/16 px.
    size_q: u32,
    subpixel: u8,
};

pub fn quantizeSize(size: f32) u32 {
    return @intFromFloat(@round(@max(size, 0) * 16));
}

pub const Entry = struct {
    page: u8,
    x: u16,
    y: u16,
    w: u16,
    h: u16,
    left: i16,
    top: i16,
};

const Shelf = struct { y: u32, h: u32, x: u32 };

const Page = struct {
    pixels: []u8,
    shelves: std.ArrayListUnmanaged(Shelf) = .empty,
    next_y: u32 = 0,
    last_used: u64 = 0,
    /// Set when contents changed since the last upload (GPU backends).
    dirty: bool = false,
};

pub const Atlas = struct {
    gpa: std.mem.Allocator,
    pages: [max_pages]?Page = @splat(null),
    map: std.AutoHashMapUnmanaged(Key, Entry) = .empty,
    frame: u64 = 1,
    /// Scratch for rasterizing one glyph before it is copied in.
    scratch: std.ArrayListUnmanaged(u8) = .empty,
    /// Count of glyphs that could not be stored this frame.
    skipped: u32 = 0,
    evictions: u32 = 0,

    pub fn init(gpa: std.mem.Allocator) Atlas {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Atlas) void {
        for (&self.pages) |*p| if (p.*) |*page| {
            self.gpa.free(page.pixels);
            page.shelves.deinit(self.gpa);
        };
        self.map.deinit(self.gpa);
        self.scratch.deinit(self.gpa);
        self.* = undefined;
    }

    /// Mark the start of a frame. Pages used since the previous call become
    /// evictable again.
    pub fn beginFrame(self: *Atlas) void {
        self.frame += 1;
        self.skipped = 0;
    }

    pub fn count(self: *const Atlas) usize {
        return self.map.count();
    }

    pub fn pageCount(self: *const Atlas) usize {
        var n: usize = 0;
        for (self.pages) |p| n += @intFromBool(p != null);
        return n;
    }

    /// The next page whose contents changed since it was last taken (clearing its
    /// flag), for a GPU backend to upload. Call until null.
    pub fn takeDirtyPage(self: *Atlas) ?u8 {
        for (&self.pages, 0..) |*p, i| if (p.*) |*page| {
            if (page.dirty) {
                page.dirty = false;
                return @intCast(i);
            }
        };
        return null;
    }

    pub fn pagePixels(self: *const Atlas, page: u8) []const u8 {
        return self.pages[page].?.pixels;
    }

    pub fn lookup(self: *Atlas, key: Key) ?Entry {
        const e = self.map.get(key) orelse return null;
        self.pages[e.page].?.last_used = self.frame;
        return e;
    }

    /// Look up a glyph, rasterizing it through `backend` on a miss.
    /// Returns null if it cannot be stored this frame (atlas full of live pages)
    /// or on allocation failure.
    pub fn getOrAdd(self: *Atlas, key: Key, backend: font.Backend, size: f32) ?Entry {
        if (self.lookup(key)) |e| return e;

        const sub = @as(f32, @floatFromInt(key.subpixel)) / @as(f32, subpixel_steps);
        const box = backend.glyphBox(key.glyph, size, sub);
        if (box.w + gutter > page_size or box.h + gutter > page_size) return null;

        var entry: Entry = .{
            .page = 0,
            .x = 0,
            .y = 0,
            .w = @intCast(box.w),
            .h = @intCast(box.h),
            .left = @intCast(box.left),
            .top = @intCast(box.top),
        };
        if (box.w == 0 or box.h == 0) {
            // No ink (space): cache it so lookups are cheap, but it needs no space.
            self.ensurePage(0) catch return null;
            self.map.put(self.gpa, key, entry) catch return null;
            return entry;
        }

        const slot = self.allocate(box.w, box.h) orelse return null;
        entry.page = slot.page;
        entry.x = @intCast(slot.x);
        entry.y = @intCast(slot.y);

        self.scratch.resize(self.gpa, @as(usize, box.w) * box.h) catch return null;
        @memset(self.scratch.items, 0);
        backend.rasterize(key.glyph, size, sub, self.scratch.items, box.w);

        const page = &self.pages[slot.page].?;
        for (0..box.h) |row| {
            const dst = page.pixels[(slot.y + row) * page_size + slot.x ..][0..box.w];
            @memcpy(dst, self.scratch.items[row * box.w ..][0..box.w]);
        }
        page.dirty = true;
        page.last_used = self.frame;
        self.map.put(self.gpa, key, entry) catch return null;
        return entry;
    }

    fn ensurePage(self: *Atlas, i: usize) !void {
        if (self.pages[i] != null) return;
        const pixels = try self.gpa.alloc(u8, @as(usize, page_size) * page_size);
        @memset(pixels, 0);
        self.pages[i] = .{ .pixels = pixels, .last_used = self.frame };
    }

    const Slot = struct { page: u8, x: u32, y: u32 };

    fn allocate(self: *Atlas, w: u32, h: u32) ?Slot {
        // Try existing pages, then a fresh page, then evict.
        for (&self.pages, 0..) |*p, i| {
            if (p.*) |*page| if (fit(page, self.gpa, w, h)) |s| return .{ .page = @intCast(i), .x = s.x, .y = s.y };
        }
        for (0..max_pages) |i| {
            if (self.pages[i] != null) continue;
            self.ensurePage(i) catch return null;
            const page = &self.pages[i].?;
            if (fit(page, self.gpa, w, h)) |s| return .{ .page = @intCast(i), .x = s.x, .y = s.y };
            return null;
        }
        // Evict the least recently used page not used this frame.
        var victim: ?usize = null;
        for (self.pages, 0..) |p, i| {
            const page = p orelse continue;
            if (page.last_used >= self.frame) continue;
            if (victim == null or page.last_used < self.pages[victim.?].?.last_used) victim = i;
        }
        const v = victim orelse {
            self.skipped += 1;
            return null;
        };
        self.clearPage(v);
        const page = &self.pages[v].?;
        if (fit(page, self.gpa, w, h)) |s| return .{ .page = @intCast(v), .x = s.x, .y = s.y };
        return null;
    }

    fn clearPage(self: *Atlas, i: usize) void {
        const page = &self.pages[i].?;
        @memset(page.pixels, 0);
        page.shelves.clearRetainingCapacity();
        page.next_y = 0;
        page.dirty = true;
        self.evictions += 1;
        var it = self.map.iterator();
        // Entries cannot be removed while iterating; collect by rebuilding.
        var keep: std.AutoHashMapUnmanaged(Key, Entry) = .empty;
        while (it.next()) |kv| {
            if (kv.value_ptr.page != i) keep.put(self.gpa, kv.key_ptr.*, kv.value_ptr.*) catch {};
        }
        self.map.deinit(self.gpa);
        self.map = keep;
    }
};

const Pos = struct { x: u32, y: u32 };

/// Shelf packing: reuse a shelf of similar height, else open a new one.
fn fit(page: *Page, gpa: std.mem.Allocator, w: u32, h: u32) ?Pos {
    const pw = w + gutter;
    const ph = h + gutter;
    for (page.shelves.items) |*s| {
        // Shelf must be tall enough, but not wastefully so.
        if (s.h >= ph and s.h <= ph + ph / 4 + 2 and s.x + pw <= page_size) {
            const pos: Pos = .{ .x = s.x, .y = s.y };
            s.x += pw;
            return pos;
        }
    }
    if (page.next_y + ph > page_size) return null;
    page.shelves.append(gpa, .{ .y = page.next_y, .h = ph, .x = pw }) catch return null;
    const pos: Pos = .{ .x = 0, .y = page.next_y };
    page.next_y += ph;
    return pos;
}

// ---- tests -----------------------------------------------------------------

test "glyphs are rasterized once and cached" {
    var atlas = Atlas.init(std.testing.allocator);
    defer atlas.deinit();
    var tf: font.TestFont = .{};
    const b = tf.backend();
    const key: Key = .{ .font = 0, .glyph = 'A', .size_q = quantizeSize(20), .subpixel = 0 };
    const e1 = atlas.getOrAdd(key, b, 20).?;
    const e2 = atlas.getOrAdd(key, b, 20).?;
    try std.testing.expectEqual(e1, e2);
    try std.testing.expectEqual(@as(usize, 1), atlas.count());
    try std.testing.expect(e1.w > 0 and e1.h > 0);
    // The stored bitmap has ink where the glyph was placed.
    const px = atlas.pagePixels(e1.page);
    try std.testing.expectEqual(@as(u8, 255), px[@as(usize, e1.y) * page_size + e1.x]);
}

test "whitespace glyphs are cached without using space" {
    var atlas = Atlas.init(std.testing.allocator);
    defer atlas.deinit();
    var tf: font.TestFont = .{};
    const e = atlas.getOrAdd(.{ .font = 0, .glyph = 1, .size_q = quantizeSize(12), .subpixel = 0 }, tf.backend(), 12).?;
    try std.testing.expectEqual(@as(u16, 0), e.w);
}

test "different sizes and subpixel buckets get separate entries" {
    var atlas = Atlas.init(std.testing.allocator);
    defer atlas.deinit();
    var tf: font.TestFont = .{};
    const b = tf.backend();
    _ = atlas.getOrAdd(.{ .font = 0, .glyph = 'x', .size_q = quantizeSize(12), .subpixel = 0 }, b, 12).?;
    _ = atlas.getOrAdd(.{ .font = 0, .glyph = 'x', .size_q = quantizeSize(16), .subpixel = 0 }, b, 16).?;
    _ = atlas.getOrAdd(.{ .font = 0, .glyph = 'x', .size_q = quantizeSize(12), .subpixel = 2 }, b, 12).?;
    try std.testing.expectEqual(@as(usize, 3), atlas.count());
}

test "packed glyphs never overlap" {
    var atlas = Atlas.init(std.testing.allocator);
    defer atlas.deinit();
    var tf: font.TestFont = .{};
    const b = tf.backend();
    var entries: [90]Entry = undefined;
    for (0..90) |i| {
        const g: u32 = 0x21 + @as(u32, @intCast(i));
        entries[i] = atlas.getOrAdd(.{ .font = 0, .glyph = g, .size_q = quantizeSize(30), .subpixel = 0 }, b, 30).?;
    }
    for (entries, 0..) |a, i| {
        for (entries[i + 1 ..]) |c| {
            if (a.page != c.page) continue;
            const sep = a.x + a.w <= c.x or c.x + c.w <= a.x or a.y + a.h <= c.y or c.y + c.h <= a.y;
            try std.testing.expect(sep);
        }
    }
}

test "a full atlas evicts the least recently used page, never one used this frame" {
    var atlas = Atlas.init(std.testing.allocator);
    defer atlas.deinit();
    var tf: font.TestFont = .{};
    const b = tf.backend();
    // Large glyphs: ~ 1000 px tall each (one per shelf, so about one per page).
    const size: f32 = 1400;
    var key: Key = .{ .font = 0, .glyph = 'A', .size_q = quantizeSize(size), .subpixel = 0 };

    var added: u32 = 0;
    // Fill every page within a single frame.
    while (added < max_pages) : (added += 1) {
        key.glyph = 'A' + added;
        try std.testing.expect(atlas.getOrAdd(key, b, size) != null);
    }
    try std.testing.expectEqual(@as(usize, max_pages), atlas.pageCount());
    // Everything is live this frame, so another glyph is skipped, not evicted.
    key.glyph = 'Z';
    try std.testing.expect(atlas.getOrAdd(key, b, size) == null);
    try std.testing.expect(atlas.skipped > 0);
    try std.testing.expectEqual(@as(u32, 0), atlas.evictions);

    // Next frame the oldest page can be reclaimed.
    atlas.beginFrame();
    try std.testing.expect(atlas.getOrAdd(key, b, size) != null);
    try std.testing.expectEqual(@as(u32, 1), atlas.evictions);
}

test "takeDirtyPage reports each changed page once" {
    var a = Atlas.init(std.testing.allocator);
    defer a.deinit();
    try std.testing.expect(a.takeDirtyPage() == null);
    try a.ensurePage(0);
    a.pages[0].?.dirty = true;
    try std.testing.expectEqual(@as(?u8, 0), a.takeDirtyPage());
    try std.testing.expect(a.takeDirtyPage() == null);
}
