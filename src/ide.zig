//! IDE-level code: services and panels that know about projects, Zig, and
//! build tools. It builds on the framework (widgets, the editor, process
//! plumbing) and nothing in the framework imports it. See `NOTES/ide-plan.md`.

pub const buildout = @import("ide/buildout.zig");
pub const project = @import("ide/project.zig");
pub const Project = project.Project;
pub const search_project = @import("ide/search_project.zig");
pub const files_panel = @import("ide/files_panel.zig");
pub const FilesPanel = files_panel.FilesPanel;
pub const search_panel = @import("ide/search_panel.zig");
pub const SearchPanel = search_panel.SearchPanel;
pub const documents = @import("ide/documents.zig");
pub const Documents = documents.Documents;
pub const output_panel = @import("ide/output_panel.zig");
pub const OutputPanel = output_panel.OutputPanel;

test {
    @import("std").testing.refAllDecls(@This());
    _ = buildout;
    _ = project;
    _ = search_project;
    _ = files_panel;
    _ = documents;
    _ = search_panel;
    _ = output_panel;
}
