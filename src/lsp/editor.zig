const std = @import("std");
const assert = std.debug.assert;
const json = @import("json");
const scylla = @import("scylla");
const Registry = scylla.rule.Registry;
const Selection = scylla.rule.Selection;
const StaticAllocator = scylla.StaticAllocator;
const log = scylla.log;
const Draft = @import("../config/draft.zig");
const Limits = @import("../limits.zig");
const Rules = @import("../rules.zig");

fix_on_save: bool,
preference: Preference,
preview: ?bool,
selection: Selection,
thresholds: [threshold_count]?u32,

const Editor = @This();

const Fault = enum {
    selector,
    value,

    pub fn reason(fault: Fault) []const u8 {
        const text: []const u8 = switch (fault) {
            .selector => "the selector names no rule",
            .value => "the value is not of the setting's kind",
        };

        assert(text.len > 0);
        assert(std.mem.startsWith(u8, text, "the "));

        return text;
    }
};

const Faulted = struct {
    fault: Fault,
    field: []const u8,
};

pub const Faults = scylla.ArrayType(Faulted);

const Preference = enum {
    editor_first,
    editor_only,
    filesystem_first,
};

const SelectionKey = struct {
    name: []const u8,
    target: Target,
};

const Target = enum {
    extend_select,
    ignore,
    select,

    fn list(target: Target) Selection.List {
        const result: Selection.List = switch (target) {
            .extend_select => .extend_select,
            .ignore => .ignore,
            .select => .select,
        };

        assert(std.mem.eql(u8, @tagName(result), @tagName(target)));

        return result;
    }
};

const ThresholdKey = struct {
    camel: []const u8,
    snake: []const u8,
};

pub const editor_count: u32 = folder_count_max + 1;
pub const folder_count_max: u32 = 8;
const threshold_count: u32 = 7;
const scalar_keys = [_][]const u8{ "configurationPreference", "fixOnSave", "preview" };
const settings_field = "settings";

const selection_keys = [_]SelectionKey{
    .{ .name = "select", .target = .select },
    .{ .name = "extendSelect", .target = .extend_select },
    .{ .name = "ignore", .target = .ignore },
    .{ .name = "enabledRules", .target = .extend_select },
    .{ .name = "disabledRules", .target = .ignore },
};

const threshold_keys = [threshold_count]ThresholdKey{
    .{ .camel = "assertionsPerFunctionMin", .snake = "assertions_per_function_min" },
    .{ .camel = "declarationDistanceMax", .snake = "declaration_distance_max" },
    .{ .camel = "elseIfChainMax", .snake = "else_if_chain_max" },
    .{ .camel = "functionLinesMax", .snake = "function_lines_max" },
    .{ .camel = "lineLengthMax", .snake = "line_length_max" },
    .{ .camel = "nestingDepthMax", .snake = "nesting_depth_max" },
    .{ .camel = "parametersMax", .snake = "parameters_max" },
};

comptime {
    assert(editor_count == folder_count_max + 1);
    assert(threshold_keys.len == threshold_count);
    assert(selection_keys.len == 5);
}

pub fn init(gpa: std.mem.Allocator) std.mem.Allocator.Error!Editor {
    assert(Limits.selector_count_max > 0);

    const selection: Selection = try .init(gpa, Limits.selector_count_max);

    assert(selection.select.capacity() == Limits.selector_count_max);
    assert(!selection.selected);

    return .{
        .fix_on_save = false,
        .preference = .filesystem_first,
        .preview = null,
        .selection = selection,
        .thresholds = @splat(null),
    };
}

pub fn deinit(editor: *Editor, gpa: std.mem.Allocator) void {
    assert(editor.selection.select.capacity() == Limits.selector_count_max);

    editor.selection.deinit(gpa);
    editor.* = undefined;
}

pub fn clear(editor: *Editor) void {
    editor.fix_on_save = false;
    editor.preference = .filesystem_first;
    editor.preview = null;

    editor.selection.clear();
    editor.thresholds = @splat(null);

    assert(!editor.selection.selected);
    assert(editor.selection.select.empty());
}

pub fn apply(editor: *const Editor, draft: *Draft) void {
    assert(draft.thresholds.validate());

    var dropped: u32 = 0;

    for (threshold_keys, editor.thresholds) |key, threshold| {
        const value = threshold orelse continue;

        assert(value > 0);

        draft.threshold_set(key.snake, value) catch |err| switch (err) {
            error.KeyUnknown, error.ValueZero => dropped += 1,
        };
    }

    if (editor.preview) |preview| draft.selection.preview.enabled = preview;

    dropped += draft.selection.overlay(&editor.selection);

    if (dropped > 0) log.line("{d} editor settings did not fit and are ignored", .{dropped});

    assert(draft.thresholds.validate());
}

pub fn read(
    editor: *Editor,
    message: *const json.Document,
    settings: json.Node,
    registry: *const Registry,
    faults: *Faults,
) void {
    assert(registry.count() > 0);

    editor.clear();

    if (message.kind_of(settings) != .object) {
        fault_push(faults, settings_field, .value);

        return;
    }

    var entries = message.entries(settings);

    for (0..entries.remaining + 1) |_| {
        const entry = entries.next() orelse break;

        editor.member_read(message, entry, registry, faults);
    } else unreachable;

    assert(faults.count() <= faults.capacity());
}

fn member_read(
    editor: *Editor,
    message: *const json.Document,
    entry: json.Entries.Entry,
    registry: *const Registry,
    faults: *Faults,
) void {
    const field = entry.key;
    const value = entry.value;

    assert(message.kind_of(field) == .string);

    if (editor.threshold_read(message, entry, faults)) return;
    if (editor.selection_read(message, entry, registry, faults)) return;

    if (message.text_is(field, "preview")) {
        editor.preview = message.boolean_of(value);

        if (editor.preview == null) fault_push(faults, "preview", .value);

        return;
    }

    if (message.text_is(field, "fixOnSave")) {
        if (message.boolean_of(value)) |flag| {
            editor.fix_on_save = flag;
        } else {
            fault_push(faults, "fixOnSave", .value);
        }

        return;
    }

    if (message.text_is(field, "configurationPreference")) {
        editor.preference_read(message, value, faults);
    }
}

fn preference_read(
    editor: *Editor,
    message: *const json.Document,
    named: json.Node,
    faults: *Faults,
) void {
    const preferences = [_]struct { []const u8, Preference }{
        .{ "editorFirst", .editor_first },
        .{ "editorOnly", .editor_only },
        .{ "filesystemFirst", .filesystem_first },
    };

    for (preferences) |preference| {
        if (!message.text_is(named, preference[0])) continue;

        editor.preference = preference[1];

        assert(editor.preference == preference[1]);

        return;
    }

    fault_push(faults, "configurationPreference", .value);
}

fn threshold_read(
    editor: *Editor,
    message: *const json.Document,
    entry: json.Entries.Entry,
    faults: *Faults,
) bool {
    assert(message.kind_of(entry.key) == .string);

    for (threshold_keys, 0..) |key, index| {
        if (!message.text_is(entry.key, key.camel)) continue;

        if (threshold_of(message, entry.value)) |threshold| {
            editor.thresholds[index] = threshold;
        } else {
            fault_push(faults, key.camel, .value);
        }

        return true;
    }

    return false;
}

fn threshold_of(message: *const json.Document, value: json.Node) ?u32 {
    const held = message.integer_of(value) orelse return null;
    if (held <= 0) return null;

    const threshold = std.math.cast(u32, held) orelse return null;

    assert(threshold > 0);

    return threshold;
}

fn selection_read(
    editor: *Editor,
    message: *const json.Document,
    entry: json.Entries.Entry,
    registry: *const Registry,
    faults: *Faults,
) bool {
    assert(message.kind_of(entry.key) == .string);

    for (selection_keys) |key| {
        if (!message.text_is(entry.key, key.name)) continue;

        if (key.target == .select) editor.selection.replace(.select);

        const found = editor.selection.selectors_read(
            registry,
            message,
            entry.value,
            key.target.list(),
        );

        for (0..found.selector_count) |_| fault_push(faults, key.name, .selector);
        for (0..found.value_count) |_| fault_push(faults, key.name, .value);

        return true;
    }

    return false;
}

fn fault_push(faults: *Faults, field: []const u8, kind: Fault) void {
    assert(field.len > 0);

    if (faults.full()) return;

    faults.push(.{ .fault = kind, .field = field });

    assert(!faults.empty());
}

const editor_only = [_][]const u8{
    "arguments",
    "configPath",
    "enable",
    "isolated",
    "languages",
    "logFile",
    "logLevel",
    "path",
    "showNotifications",
    "trace.server",
};

const manifest_bytes_max: u32 = 1 << 20;
const manifest_node_count_max: u32 = 1 << 16;
const Names = std.ArrayList([]const u8);

const Fingerprint = struct {
    extend_select: u32,
    fix_on_save: bool,
    ignore: u32,
    preference: Preference,
    preview: ?bool,
    select: u32,
    selected: bool,
    thresholds: [threshold_count]?u32,
};

fn fingerprint(editor: *const Editor) Fingerprint {
    return .{
        .extend_select = editor.selection.extend_select.count(),
        .fix_on_save = editor.fix_on_save,
        .ignore = editor.selection.ignore.count(),
        .preference = editor.preference,
        .preview = editor.preview,
        .select = editor.selection.select.count(),
        .selected = editor.selection.selected,
        .thresholds = editor.thresholds,
    };
}

fn names_read(gpa: std.mem.Allocator) !Names {
    var names: Names = .empty;
    errdefer names.deinit(gpa);

    for (threshold_keys) |key| try names.append(gpa, key.camel);
    for (selection_keys) |key| try names.append(gpa, key.name);
    for (scalar_keys) |name| try names.append(gpa, name);

    std.mem.sort([]const u8, names.items, {}, name_less);

    return names;
}

fn names_contributed(arena: std.mem.Allocator, manifest: []const u8) !Names {
    var storage: json.Storage = try .init(arena, .{
        .node_count_max = manifest_node_count_max,
        .text_bytes_max = manifest_bytes_max,
    });

    defer storage.deinit(arena);

    var document: json.Document = undefined;

    try document.parse(storage, manifest);

    const root = document.root();

    const contributes = document.member(root, "contributes") orelse {
        return error.TestUnexpectedResult;
    };

    const configuration = document.member(contributes, "configuration") orelse {
        return error.TestUnexpectedResult;
    };

    var names: Names = .empty;

    try properties_collect(arena, &document, configuration, &names);

    var sections = document.items(configuration);

    for (0..sections.remaining + 1) |_| {
        const section = sections.next() orelse break;

        try properties_collect(arena, &document, section, &names);
    } else unreachable;

    std.mem.sort([]const u8, names.items, {}, name_less);

    try std.testing.expect(names.items.len > 0);

    return names;
}

fn properties_collect(
    arena: std.mem.Allocator,
    document: *const json.Document,
    section: json.Node,
    names: *Names,
) !void {
    const properties = document.member(section, "properties") orelse return;
    var entries = document.entries(properties);

    for (0..entries.remaining + 1) |_| {
        const entry = entries.next() orelse break;
        const text = document.text_of(entry.key) orelse return error.TestUnexpectedResult;

        if (std.mem.startsWith(u8, text, "tigerstyle.")) {
            try names.append(arena, try arena.dupe(u8, text["tigerstyle.".len..]));
        }
    } else unreachable;
}

fn name_less(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}

fn names_contain(names: []const []const u8, name: []const u8) bool {
    for (names) |held| {
        if (std.mem.eql(u8, held, name)) return true;
    }

    return false;
}

fn value_of(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "configurationPreference")) return "\"editorOnly\"";
    if (std.mem.eql(u8, name, "fixOnSave")) return "true";
    if (std.mem.eql(u8, name, "preview")) return "true";

    for (selection_keys) |key| {
        if (std.mem.eql(u8, name, key.name)) return "[\"TS001\"]";
    }

    return "3";
}

fn key_read(gpa: std.mem.Allocator, registry: *const Registry, name: []const u8) !void {
    const body = try gpa.print("{{\"{s}\": {s}}}", .{ name, value_of(name) });
    defer gpa.free(body);

    var static_allocator: StaticAllocator = .init(gpa);
    defer static_allocator.deinit();

    const frozen_gpa = static_allocator.allocator();

    var storage: json.Storage = try .init(frozen_gpa, .{
        .node_count_max = 16,
        .text_bytes_max = 256,
    });

    defer storage.deinit(frozen_gpa);

    var document: json.Document = undefined;
    var untouched: Editor = try .init(frozen_gpa);
    defer untouched.deinit(frozen_gpa);

    var editor: Editor = try .init(frozen_gpa);
    defer editor.deinit(frozen_gpa);

    var faults: Faults = try .init(frozen_gpa, Limits.selector_count_max);
    defer faults.deinit(frozen_gpa);

    {
        var scope = static_allocator.freeze_scope();
        defer scope.leave();

        try document.parse(storage, body);
        editor.read(&document, document.root(), registry, &faults);
    }

    if (faults.count() > 0) std.debug.print("tigerstyle.{s} was refused\n", .{name});

    try std.testing.expectEqual(@as(u32, 0), faults.count());

    if (std.meta.eql(fingerprint(&editor), fingerprint(&untouched))) {
        std.debug.print("tigerstyle.{s} is named by a table and read by nothing\n", .{name});

        return error.TestUnexpectedResult;
    }
}

test "the extension and the server name the same settings" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const manifest = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "editors/vscode/package.json",
        gpa,
        .limited(manifest_bytes_max),
    );

    defer gpa.free(manifest);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    const contributed = try names_contributed(arena.allocator(), manifest);

    var read_names = try names_read(gpa);
    defer read_names.deinit(gpa);

    for (read_names.items) |name| {
        if (!names_contain(contributed.items, name)) {
            std.debug.print(
                "the server reads tigerstyle.{s} and the extension does not contribute it\n",
                .{name},
            );

            return error.TestUnexpectedResult;
        }
    }

    for (contributed.items) |name| {
        if (names_contain(read_names.items, name)) continue;
        if (names_contain(&editor_only, name)) continue;

        std.debug.print("the extension contributes tigerstyle.{s} and nothing reads it\n", .{name});

        return error.TestUnexpectedResult;
    }

    for (editor_only) |name| {
        try std.testing.expect(names_contain(contributed.items, name));
        try std.testing.expect(!names_contain(read_names.items, name));
    }

    try std.testing.expectEqual(contributed.items.len, read_names.items.len + editor_only.len);
}

test "every key the tables name is a key the reader consumes" {
    const gpa = std.testing.allocator;

    var rules: Rules = try .init(gpa);
    defer rules.deinit(gpa);

    var names = try names_read(gpa);
    defer names.deinit(gpa);

    for (names.items) |name| try key_read(gpa, &rules.registry, name);
}
