//! IDE-level code: services and panels that know about projects, Zig, and
//! build tools. It builds on the framework (widgets, the editor, process
//! plumbing) and nothing in the framework imports it. See `NOTES/ide-plan.md`.

pub const buildout = @import("ide/buildout.zig");
pub const project = @import("ide/project.zig");
pub const Project = project.Project;
pub const search_project = @import("ide/search_project.zig");
pub const output_panel = @import("ide/output_panel.zig");
pub const OutputPanel = output_panel.OutputPanel;

test {
    @import("std").testing.refAllDecls(@This());
    _ = buildout;
    _ = project;
    _ = search_project;
    _ = output_panel;
}
