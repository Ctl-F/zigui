//! Types shared by several widgets.

/// Toolkit-owned string: set it through the `Ui` setters, which copy.
pub const Text = extern struct {
    ptr: ?[*]const u8 = null,
    len: usize = 0,

    pub fn slice(self: Text) []const u8 {
        const p = self.ptr orelse return "";
        return p[0..self.len];
    }
};
