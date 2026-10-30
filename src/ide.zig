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
pub const zig_index = @import("ide/zig_index.zig");
pub const zig_complete = @import("ide/zig_complete.zig");
pub const jsonrpc = @import("ide/lsp/jsonrpc.zig");
pub const lsp_assist = @import("ide/lsp_assist.zig");
pub const lsp_client = @import("ide/lsp/client.zig");
pub const lsp_results = @import("ide/lsp/results.zig");
pub const terminal_panel = @import("ide/terminal_panel.zig");
pub const TerminalPanel = terminal_panel.TerminalPanel;
pub const relaunch = @import("ide/relaunch.zig");
pub const handlers = @import("ide/handlers.zig");
pub const designer = @import("ide/designer.zig");
pub const prompt = @import("ide/prompt.zig");
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
    _ = prompt;
    _ = designer;
    _ = handlers;
    _ = relaunch;
    _ = terminal_panel;
    _ = jsonrpc;
    _ = lsp_client;
    _ = lsp_assist;
    _ = lsp_results;
    _ = zig_index;
    _ = zig_complete;
    _ = search_panel;
    _ = output_panel;
}
