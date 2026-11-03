//! The Project Settings feature
//! This allows the editor to present settings graphically
//! And then the build.zig or project source code can consume the settings directly
//!
//! Settings (*.proj.zon) file example
//! .{
//!    .properties = .{
//!         // this actually containes the properties that should be present and their default values
//!         .project_name = "Hello App",.{
//!         .default_width = 1280,
//!         .default_height = 720,
//!         .resizable = true,
//!    },
//!    .metadata = .{
//!         .default_width = .{ .min_value = 0 },
//!         .default_height = .{ .min_value = 0, .max_value = 65535 },
//!         .resizable = .{ .ui_type = .select }, // select (true or false) instead of a checkbox
//!    },
//! }
//!
//! The IDE will generate a zig model to match the properties struct 
const std = @import("std");
const zigui = @import("zigui");

/// Generate the project stub 
pub fn generateStub(project: *zigui.ide.Project) !void {
    const DefaultZONType = struct {
        properties: struct{} = .{},
        metadata: struct{} = .{},
    };
    
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const absolute_path = try project.dir.realpath(".", &buf);
    
    const filename = try std.fs.path.join(project.gpa, &.{
        absolute_path,
        project.name,
        ".proj.zon",
    });
    
    const defaultConfig = DefaultZONType{};
    
    _ = defaultConfig;
    _ = filename;
}

