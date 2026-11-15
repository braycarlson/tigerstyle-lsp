const std = @import("std");
const assert = std.debug.assert;
const cli = @import("cli.zig");
const Workspace = @import("workspace.zig");
const camel = "fn helper() {\n    let valueMax = 1;\n}\n";
const guard_tripped = "allocation guard tripped";
const suite = "config";

const nested = "fn helper(a: bool, b: bool, c: bool) {\n    if a {\n        if b {\n" ++
    "            if c {\n                let _ = 1;\n            }\n        }\n    }\n}\n";

fn run(gpa: std.mem.Allocator, io: std.Io, arguments: []const []const u8) !cli.Output {
    assert(arguments.len > 0);

    var command: cli.Command = try .init(gpa, io);
    defer command.deinit(gpa);

    try command.environment_set(.{ .key = "TIGERSTYLE_NO_CACHE", .value = "1" });
    try command.arguments_add(gpa, &.{ "lint", "--format", "concise" });
    try command.arguments_add(gpa, arguments);
    command.environment_remove("CLICOLOR_FORCE");
    command.environment_remove("FORCE_COLOR");
    command.environment_remove("NO_COLOR");

    var output = try command.output(gpa, io);

    if (contains(.{ .part = guard_tripped, .text = output.stderr })) {
        std.debug.print("{s}\n", .{output.stderr});
        output.deinit(gpa);

        return error.TestUnexpectedResult;
    }

    return output;
}

fn contains(options: struct { part: []const u8, text: []const u8 }) bool {
    assert(options.part.len > 0);

    return std.mem.find(u8, options.text, options.part) != null;
}

fn expect_contains(options: struct { part: []const u8, text: []const u8 }) !void {
    assert(options.part.len > 0);

    if (!contains(.{
        .part = options.part,
        .text = options.text,
    })) std.debug.print("{s}\n", .{options.text});

    try std.testing.expect(contains(.{ .part = options.part, .text = options.text }));
}

fn expect_lacks(options: struct { part: []const u8, text: []const u8 }) !void {
    assert(options.part.len > 0);

    if (contains(.{
        .part = options.part,
        .text = options.text,
    })) std.debug.print("{s}\n", .{options.text});

    try std.testing.expect(!contains(.{ .part = options.part, .text = options.text }));
}

fn expect_stdout_contains(
    gpa: std.mem.Allocator,
    io: std.Io,
    arguments: []const []const u8,
    part: []const u8,
) !void {
    assert(arguments.len > 0);
    assert(part.len > 0);

    var output = try run(gpa, io, arguments);
    defer output.deinit(gpa);

    try expect_contains(.{ .part = part, .text = output.stdout });
}

fn expect_stdout_empty(gpa: std.mem.Allocator, io: std.Io, arguments: []const []const u8) !void {
    assert(arguments.len > 0);

    var output = try run(gpa, io, arguments);
    defer output.deinit(gpa);

    try std.testing.expectEqualStrings("", output.stdout);
}

fn expect_stderr_contains(
    gpa: std.mem.Allocator,
    io: std.Io,
    arguments: []const []const u8,
    part: []const u8,
) !void {
    assert(arguments.len > 0);
    assert(part.len > 0);

    var output = try run(gpa, io, arguments);
    defer output.deinit(gpa);

    try expect_contains(.{ .part = part, .text = output.stderr });
}

test "a discovered config turns on an opt in rule" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var workspace: Workspace = try .init(gpa, io, .{ .name = "discovered", .suite = suite });
    defer workspace.deinit();

    const source = try workspace.write(.{ .body = camel, .name = "a.rs" });

    _ = try workspace.write(.{
        .body = "extend_select = [\"TS032\"]\n",
        .name = "tigerstyle.toml",
    });

    try expect_stdout_contains(gpa, io, &.{source}, "TS032");
}

test "an isolated run reads no config" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var workspace: Workspace = try .init(gpa, io, .{ .name = "isolated", .suite = suite });
    defer workspace.deinit();

    const source = try workspace.write(.{ .body = camel, .name = "a.rs" });

    _ = try workspace.write(.{
        .body = "extend_select = [\"TS032\"]\n",
        .name = "tigerstyle.toml",
    });

    var output = try run(gpa, io, &.{ "--isolated", source });
    defer output.deinit(gpa);

    try std.testing.expectEqualStrings("", output.stdout);
    try std.testing.expectEqual(@as(?u8, 0), output.code);
}

test "a hidden name wins over the plain one" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var workspace: Workspace = try .init(gpa, io, .{ .name = "hidden", .suite = suite });
    defer workspace.deinit();

    const source = try workspace.write(.{ .body = camel, .name = "a.rs" });

    _ = try workspace.write(.{
        .body = "extend_select = [\"TS042\"]\n",
        .name = "tigerstyle.toml",
    });

    _ = try workspace.write(.{
        .body = "extend_select = [\"TS032\"]\n",
        .name = ".tigerstyle.toml",
    });

    try expect_stdout_contains(gpa, io, &.{source}, "TS032");
}

test "a nested config governs its subtree" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var workspace: Workspace = try .init(gpa, io, .{ .name = "nested", .suite = suite });
    defer workspace.deinit();

    _ = try workspace.write(.{
        .body = "extend_select = [\"TS032\"]\n",
        .name = "tigerstyle.toml",
    });

    const outer = try workspace.write(.{ .body = camel, .name = "a.rs" });
    const inner = try workspace.directory("deep");
    const nested_source = try workspace.write(.{ .body = camel, .name = "deep/b.rs" });

    assert(std.mem.startsWith(u8, nested_source, inner));

    _ = try workspace.write(.{ .body = "ignore = [\"TS032\"]\n", .name = "deep/tigerstyle.toml" });

    try expect_stdout_contains(gpa, io, &.{outer}, "TS032");
    try expect_stdout_empty(gpa, io, &.{nested_source});
}

test "an extend chain resolves outermost first" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var workspace: Workspace = try .init(gpa, io, .{ .name = "extend", .suite = suite });
    defer workspace.deinit();

    _ = try workspace.write(.{
        .body = "extend_select = [\"TS032\"]\nline_length_max = 40\n",
        .name = "base.toml",
    });

    const source = try workspace.write(.{ .body = camel, .name = "a.rs" });

    _ = try workspace.write(.{
        .body = "extend = \"base.toml\"\nline_length_max = 200\n",
        .name = "tigerstyle.toml",
    });

    var output = try run(gpa, io, &.{source});
    defer output.deinit(gpa);

    try expect_contains(.{ .part = "TS032", .text = output.stdout });
    try expect_lacks(.{ .part = "TS012", .text = output.stdout });
}

test "an extend cycle falls back to the defaults" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var workspace: Workspace = try .init(gpa, io, .{ .name = "cycle", .suite = suite });
    defer workspace.deinit();

    const source = try workspace.write(.{ .body = camel, .name = "a.rs" });

    _ = try workspace.write(.{ .body = "extend = \"other.toml\"\n", .name = "tigerstyle.toml" });
    _ = try workspace.write(.{ .body = "extend = \"tigerstyle.toml\"\n", .name = "other.toml" });

    var output = try run(gpa, io, &.{source});
    defer output.deinit(gpa);

    try expect_contains(.{ .part = "extends itself", .text = output.stderr });
    try std.testing.expectEqual(@as(?u8, 0), output.code);
}

test "a broken config names its line" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var workspace: Workspace = try .init(gpa, io, .{ .name = "broken", .suite = suite });
    defer workspace.deinit();

    const source = try workspace.write(.{ .body = camel, .name = "a.rs" });

    _ = try workspace.write(.{
        .body = "line_length_max = 40\nnonsense = 1\n",
        .name = "tigerstyle.toml",
    });

    var output = try run(gpa, io, &.{source});
    defer output.deinit(gpa);

    try expect_contains(.{ .part = "tigerstyle.toml:2:", .text = output.stderr });
    try expect_contains(.{ .part = "not a tigerstyle-lsp option", .text = output.stderr });
}

test "a zero limit leaves the defaults standing" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var workspace: Workspace = try .init(gpa, io, .{ .name = "zero", .suite = suite });
    defer workspace.deinit();

    const source = try workspace.write(.{ .body = camel, .name = "a.rs" });

    _ = try workspace.write(.{ .body = "line_length_max = 0\n", .name = "tigerstyle.toml" });

    try expect_stderr_contains(gpa, io, &.{source}, "the limit is zero");
}

test "a config selector whose digits overrun a code names no rule" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var workspace: Workspace = try .init(gpa, io, .{ .name = "selector-overrun", .suite = suite });
    defer workspace.deinit();

    const source = try workspace.write(.{ .body = camel, .name = "a.rs" });

    _ = try workspace.write(.{
        .body = "extend_select = [\"TS9999999999\"]\n",
        .name = "tigerstyle.toml",
    });

    try expect_stderr_contains(gpa, io, &.{source}, "the selector names no rule");
}

test "a command line selector replaces the config selection" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var workspace: Workspace = try .init(gpa, io, .{ .name = "selection", .suite = suite });
    defer workspace.deinit();

    const source = try workspace.write(.{ .body = camel, .name = "a.rs" });

    _ = try workspace.write(.{
        .body = "extend_select = [\"TS032\"]\n",
        .name = "tigerstyle.toml",
    });

    try expect_stdout_empty(gpa, io, &.{ "--select", "TS042", source });
}

test "a per file ignore covers a matching path" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var workspace: Workspace = try .init(gpa, io, .{ .name = "ignores", .suite = suite });
    defer workspace.deinit();

    const source = try workspace.write(.{ .body = camel, .name = "deep/a.rs" });

    _ = try workspace.write(.{
        .body = "extend_select = [\"TS032\"]\n\n[per-file-ignores]\n\"deep/*\" = [\"TS032\"]\n",
        .name = "tigerstyle.toml",
    });

    try expect_stdout_empty(gpa, io, &.{source});
}

test "a config threshold reaches the rule" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var workspace: Workspace = try .init(gpa, io, .{ .name = "threshold-config", .suite = suite });
    defer workspace.deinit();

    const source = try workspace.write(.{ .body = nested, .name = "a.rs" });

    _ = try workspace.write(.{ .body = "nesting_depth_max = 2\n", .name = "tigerstyle.toml" });

    var output = try run(gpa, io, &.{source});
    defer output.deinit(gpa);

    try expect_contains(.{ .part = "TS008", .text = output.stdout });
    try expect_contains(.{ .part = "over the 2 level limit", .text = output.stdout });
}

test "a language block leaves another language on the global limit" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, .{
        .name = "threshold-language",
        .suite = suite,
    });

    defer workspace.deinit();

    const rust = try workspace.write(.{ .body = nested, .name = "a.rs" });

    _ = try workspace.write(.{
        .body = "nesting_depth_max = 2\n\n[language.python]\nnesting_depth_max = 8\n",
        .name = "tigerstyle.toml",
    });

    try expect_stdout_contains(gpa, io, &.{rust}, "TS008");
}

test "a language block overrides a limit" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var workspace: Workspace = try .init(gpa, io, .{ .name = "language", .suite = suite });
    defer workspace.deinit();

    const source = try workspace.write(.{
        .body = "fn helper() {\n    let value = 1;\n}\n",
        .name = "a.rs",
    });

    _ = try workspace.write(.{
        .body = "line_length_max = 200\n\n[language.rust]\nline_length_max = 10\n",
        .name = "tigerstyle.toml",
    });

    try expect_stdout_contains(gpa, io, &.{source}, "TS012");
}

test "a language block replaces the selection for that language only" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var workspace: Workspace = try .init(gpa, io, .{ .name = "language-select", .suite = suite });
    defer workspace.deinit();

    const rust = try workspace.write(.{ .body = "use std::fmt::*;\n", .name = "a.rs" });

    const python = try workspace.write(.{
        .body = "from os import *\n\ndef f():\n    maxValue = 1\n",
        .name = "a.py",
    });

    _ = try workspace.write(.{
        .body = "[language.python]\nselect = [\"TS032\"]\n",
        .name = "tigerstyle.toml",
    });

    var output = try run(gpa, io, &.{ rust, python });
    defer output.deinit(gpa);

    try expect_contains(.{ .part = "a.rs:1:5: warning TS011", .text = output.stdout });
    try expect_contains(.{ .part = "a.py:4:5: warning TS032", .text = output.stdout });

    var lines: cli.Lines = .init(output.stdout);
    var swallowed = false;

    for (0..output.stdout.len + 1) |_| {
        const line = lines.next() orelse break;

        if (contains(.{ .part = "a.py", .text = line })) {
            if (contains(.{ .part = "TS011", .text = line })) swallowed = true;
        }
    }

    if (swallowed) std.debug.print("{s}\n", .{output.stdout});

    try std.testing.expect(!swallowed);
}

test "a language ignore leaves the other languages alone" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var workspace: Workspace = try .init(gpa, io, .{ .name = "language-ignore", .suite = suite });
    defer workspace.deinit();

    const rust = try workspace.write(.{ .body = "use std::fmt::*;\n", .name = "a.rs" });
    const python = try workspace.write(.{ .body = "from os import *\n", .name = "a.py" });

    _ = try workspace.write(.{
        .body = "[language.python]\nignore = [\"TS011\"]\n",
        .name = "tigerstyle.toml",
    });

    var output = try run(gpa, io, &.{ rust, python });
    defer output.deinit(gpa);

    try expect_contains(.{ .part = "a.rs", .text = output.stdout });
    try expect_lacks(.{ .part = "a.py", .text = output.stdout });
}

test "preview inside a language block is refused by line" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var workspace: Workspace = try .init(gpa, io, .{ .name = "language-preview", .suite = suite });
    defer workspace.deinit();

    const source = try workspace.write(.{ .body = camel, .name = "a.rs" });

    _ = try workspace.write(.{
        .body = "[language.rust]\npreview = true\n",
        .name = "tigerstyle.toml",
    });

    var output = try run(gpa, io, &.{source});
    defer output.deinit(gpa);

    try expect_contains(.{ .part = "tigerstyle.toml:2:", .text = output.stderr });
    try expect_contains(.{ .part = "preview is a top-level key", .text = output.stderr });
}

test "respect gitignore on the command line overrides the key" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var workspace: Workspace = try .init(gpa, io, .{ .name = "gitignore-flag", .suite = suite });
    defer workspace.deinit();

    _ = try workspace.write(.{ .body = "skipped.rs\n", .name = ".gitignore" });
    _ = try workspace.write(.{ .body = camel, .name = "skipped.rs" });

    _ = try workspace.write(.{
        .body = "extend_select = [\"TS032\"]\n",
        .name = "tigerstyle.toml",
    });

    var honoured = try run(gpa, io, &.{workspace.root});
    defer honoured.deinit(gpa);

    try expect_lacks(.{ .part = "skipped.rs", .text = honoured.stdout });

    var ignored = try run(gpa, io, &.{ "--respect-gitignore", "false", workspace.root });
    defer ignored.deinit(gpa);

    try expect_contains(.{ .part = "skipped.rs", .text = ignored.stdout });
}

test "an unsatisfied required version is reported" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var workspace: Workspace = try .init(gpa, io, .{ .name = "version", .suite = suite });
    defer workspace.deinit();

    const source = try workspace.write(.{ .body = camel, .name = "a.rs" });

    _ = try workspace.write(.{
        .body = "required_version = \">=99.0\"\n",
        .name = "tigerstyle.toml",
    });

    try expect_stderr_contains(gpa, io, &.{source}, "required_version");
}
