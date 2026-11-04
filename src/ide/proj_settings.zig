const std = @import("std");
const project_mod = @import("project.zig");
const zon = @import("../uidoc/zon.zig");

const Project = project_mod.Project;

/// `<project name>.proj.zon`
pub fn fileName(a: std.mem.Allocator, project: *const Project) ![]u8 {
    return try std.fmt.allocPrint(a, "{s}.proj.zon", .{ project.name });
}


fn typeText(v: zon.Value, meta: zon.Value) ?[]const u8 {
    _ = meta;
    return switch(v) {
        .none => null,
        .bool => "bool",
        .int => "i64",
        .float => "f64",
        .string => "[]const u8",
        .tag => null, // TODO
        .record => null, // TODO
        .list => null, // TODO
    };
}

fn valueString(arena: std.mem.Allocator, value: zon.Value) !?[]const u8 {
    return switch(value) {
        .none, .tag, .record, .list => null, // TODO
        .bool, .int, .float, .string => try zon.render(arena, value),
    };
}

/// The format string of the generated file. Arguments, in order: the source file's
/// name, the `Settings` fields, the `Metadata` fields (each field line ends in `,\n`).
const SettingZigTypesTemplate = @embedFile("templates/ide_settings/ide_setting.zig.template");

/// The text of the generated settings file for `doc` (`source_name` is only mentioned in its header).
///
/// Every setting whose type can be written gets a `Settings` field with its value as the default.
/// Every setting also gets a `Metadata` entry, even one that is not typed yet, and so does every
/// metadata key that has no setting: an unknown key would make `@import("<name>.proj.zon")` fail.
pub fn generateTypes(gpa: std.mem.Allocator, doc: *const Doc, source_name: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var settings_fields: std.ArrayList(u8) = .empty;
    defer settings_fields.deinit(gpa);
    var metadata_fields: std.ArrayList(u8) = .empty;
    defer metadata_fields.deinit(gpa);

    for (doc.settings.fields() orelse &.{}) |field| {
        const name = try std.fmt.allocPrint(a, "{f}", .{std.zig.fmtId(field.name)});
        try metadata_fields.print(gpa, "    {s}: Meta = .{{}},\n", .{name});

        const type_text = typeText(field.value, doc.metadata.field(field.name) orelse .none) orelse continue; // TODO: enums, records, lists
        try settings_fields.print(gpa, "    {s}: {s}", .{ name, type_text });
        if (try valueString(a, field.value)) |default| try settings_fields.print(gpa, " = {s}", .{default});
        try settings_fields.appendSlice(gpa, ",\n");
    }

    // Metadata for names that are not settings (left behind, or for a setting not typed yet).
    for (doc.metadata.fields() orelse &.{}) |entry| {
        if (doc.settings.field(entry.name) != null) continue;
        try metadata_fields.print(gpa, "    {f}: Meta = .{{}},\n", .{std.zig.fmtId(entry.name)});
    }

    return std.fmt.allocPrint(gpa, SettingZigTypesTemplate, .{ source_name, settings_fields.items, metadata_fields.items });
}


pub const Doc = struct {
    arena: std.heap.ArenaAllocator,
    gpa: std.mem.Allocator,
    
    settings: zon.Value = .{ .record = &.{} },
    metadata: zon.Value = .{ .record = &.{} },
    
    
    pub fn init(gpa: std.mem.Allocator) @This() {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa), .gpa = gpa };
    }
    
    pub fn deinit(this: *@This()) void {
        this.arena.deinit();
    }
    
    
    /// Load project file
    pub fn load(gpa: std.mem.Allocator, project: *const Project) !@This() {
        var doc = @This().init(gpa);
        
        const settings_filename = try fileName(gpa, project);
        defer gpa.free(settings_filename);
        
        const a = doc.arena.allocator();

        const bytes = project.readFile(a, settings_filename, 1024 * 1024 * 2) catch return doc;
        
        const v = zon.parse(a, bytes, null) catch return doc;
        
        if(v.field("settings")) |set| {
            doc.settings = set;
        }
        if(v.field("metadata")) |meta| {
            doc.metadata = meta;
        }
        
        return doc;
    }
};

/// A scratch project holding `<name>.proj.zon` with `text`, loaded.
fn loadSample(gpa: std.mem.Allocator, tmp: *std.testing.TmpDir, p: *Project, text: []const u8) !Doc {
    _ = tmp;
    const file = try fileName(gpa, p);
    defer gpa.free(file);
    try p.writeFile(file, text);
    return Doc.load(gpa, p);
}

test "generateTypes writes typed settings, quoted strings and a Meta per setting" {
    const testing = std.testing;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var p = try project_mod.testProject(&tmp);
    defer p.close();

    // ZON in a multiline string: no escape processing, so this is exactly the file's text.
    var doc = try loadSample(gpa, &tmp, &p,
        \\.{ .settings = .{ .a = 1, .b = true, .c = "say \"hi\"", .d = 2.5, .@"type" = -3 }, .metadata = .{} }
    );
    defer doc.deinit();
    // A document that did not load would give an empty `Settings`: fail here, not in the text comparison.
    try testing.expectEqual(@as(usize, 5), doc.settings.fields().?.len);

    const expected = try std.fmt.allocPrint(gpa, SettingZigTypesTemplate, .{
        "<source_name>",
        \\    a: i64 = 1,
        \\    b: bool = true,
        \\    c: []const u8 = "say \"hi\"",
        \\    d: f64 = 2.5,
        \\    @"type": i64 = -3,
        \\
        ,
        \\    a: Meta = .{},
        \\    b: Meta = .{},
        \\    c: Meta = .{},
        \\    d: Meta = .{},
        \\    @"type": Meta = .{},
        \\
        ,
    });
    defer gpa.free(expected);

    const result = try generateTypes(gpa, &doc, "<source_name>");
    defer gpa.free(result);
    try testing.expectEqualStrings(expected, result);
    try testing.expect(std.mem.endsWith(u8, result, "};\n"));
}

test "generateTypes keeps metadata of settings it cannot type yet and of keys without a setting" {
    const testing = std.testing;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var p = try project_mod.testProject(&tmp);
    defer p.close();

    var doc = try loadSample(gpa, &tmp, &p,
        \\.{
        \\    .settings = .{ .mode = .fast, .level = 3 },
        \\    .metadata = .{ .mode = .{ .label = "Mode" }, .gone = .{ .label = "Removed" } },
        \\}
    );
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 2), doc.settings.fields().?.len);

    const result = try generateTypes(gpa, &doc, "x.proj.zon");
    defer gpa.free(result);
    // `mode` is an enum literal, which is not typed yet: no Settings field, but its Meta stays.
    try testing.expect(std.mem.indexOf(u8, result, "pub const Settings = struct {\n    level: i64 = 3,\n};") != null);
    try testing.expect(std.mem.indexOf(u8, result, "pub const Metadata = struct {\n    mode: Meta = .{},\n    level: Meta = .{},\n    gone: Meta = .{},\n};") != null);
}

test "generateTypes with no project file gives empty Settings and Metadata" {
    const testing = std.testing;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var p = try project_mod.testProject(&tmp);
    defer p.close();
    var doc = try Doc.load(gpa, &p);
    defer doc.deinit();
    const result = try generateTypes(gpa, &doc, "x.proj.zon");
    defer gpa.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "pub const Settings = struct {\n};") != null);
    try testing.expect(std.mem.indexOf(u8, result, "pub const Metadata = struct {\n};") != null);
}

test "typeText returns expected results" {
    const testing = std.testing;
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    
    const testZon = ".{ .a = 1, .b = true, .c = \"Hello World\" }";
    const tree = try zon.parse(arena.allocator(), testZon, null);
    
    try testing.expectEqualStrings("i64", typeText(tree.field("a").?, .none).?);
    try testing.expectEqualStrings("bool", typeText(tree.field("b").?, .none).?);
    try testing.expectEqualStrings("[]const u8", typeText(tree.field("c").?, .none).?);
}

test "a project file loads its settings and metadata; a missing one is empty" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    
    var p = try project_mod.testProject(&tmp);
    defer p.close();
    
    // no file: and empty document, not an error.
    var none = try Doc.load(testing.allocator, &p);
    defer none.deinit();
    try testing.expectEqual(@as(usize, 0), none.settings.fields().?.len);
    
    const name = try fileName(testing.allocator, &p);
    defer testing.allocator.free(name);
    try p.writeFile(name, 
        \\.{
        \\    .settings = .{ .title = "Hello", .max_players = 4 },
        \\    .metadata = .{ .max_players = .{ .label = "Max players", .min = 1, .max = 16 } },
        \\}
    );
    
    var doc = try Doc.load(testing.allocator, &p);
    defer doc.deinit();
    
    try testing.expectEqual(@as(i64, 4), doc.settings.field("max_players").?.int);
    try testing.expectEqualStrings("Max players", doc.metadata.field("max_players").?.field("label").?.string);
}

