//! Types shared by several widgets.

/// A widget-specific command offered in editors' context menus (the builder's
/// right-click menu): flip one `bool` prop. A widget lists them in a
/// `pub const actions = [_]Action{ ... }` declaration; the registry collects them.
pub const Action = struct {
    /// Menu text (when the prop is off, or always if `label_when_on` is empty).
    label: []const u8,
    /// The bool prop to flip.
    toggle: []const u8,
    /// Menu text while the prop is on ("Make vertical" / "Make horizontal").
    label_when_on: []const u8 = "",
    /// Show a check mark while on (for options, as opposed to a switch).
    checkable: bool = false,
};

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
