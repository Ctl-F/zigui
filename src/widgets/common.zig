//! Types shared by several widgets.

/// Toolkit-owned widget text. Do not construct one yourself: set text through
/// the widget's setter (`button.setText(...)`), which copies the bytes into
/// storage the toolkit owns and frees. A literal assigned here directly would
/// be freed later by the toolkit, which is why this is a wrapper and not a bare
/// `[]const u8`.
pub const Text = struct {
    /// Marks this as toolkit-owned text for the runtime schema.
    pub const is_text = true;

    bytes: []const u8 = "",

    pub fn slice(self: Text) []const u8 {
        return self.bytes;
    }
};
