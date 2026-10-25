const std = @import("std");
const assert = std.debug.assert;
const cli = @import("testing/cli.zig");
const Workspace = @import("testing/workspace.zig");

const camel = "fn helper() {\n    let valueMax = 1;\n}\n";
const guard_tripped = "allocation guard tripped";
const suite = "config";

const nested = "fn helper(a: bool, b: bool, c: bool) {\n    if a {\n        if b {\n" ++
    "            if c {\n                let _ = 1;\n            }\n        }\n    }\n}\n";

fn run(gpa: std.mem.Allocator, io: std.Io, arguments: []const []const u8) !cli.Output {
    var command: cli.Command = try .init(gpa, io);
    defer command.deinit(gpa);

    try command.environment_set("TIGERSTYLE_NO_CACHE", "1");
    try command.arguments_add(gpa, &.{ "lint", "--format", "concise" });
    try command.arguments_add(gpa, arguments);
    command.environment_remove("CLICOLOR_FORCE");
    command.environment_remove("FORCE_COLOR");
    command.environment_remove("NO_COLOR");

    var output = try command.output(gpa, io);

    if (contains(output.stderr, guard_tripped)) {
        std.debug.print("{s}\n", .{output.stderr});
        output.deinit(gpa);

        return error.TestUnexpectedResult;
    }

    return output;
}

fn contains(text: []const u8, part: []const u8) bool {
    assert(part.len > 0);

    return std.mem.find(u8, text, part) != null;
}

fn expect_contains(text: []const u8, part: []const u8) !void {
    if (!contains(text, part)) std.debug.print("{s}\n", .{text});

    try std.testing.expect(contains(text, part));
}

fn expect_lacks(text: []const u8, part: []const u8) !void {
    if (contains(text, part)) std.debug.print("{s}\n", .{text});

    try std.testing.expect(!contains(text, part));
}

fn expect_stdout_contains(
    gpa: std.mem.Allocator,
    io: std.Io,
    arguments: []const []const u8,
    part: []const u8,
) !void {
    var output = try run(gpa, io, arguments);
    defer output.deinit(gpa);

    try expect_contains(output.stdout, part);
}

fn expect_stdout_empty(gpa: std.mem.Allocator, io: std.Io, arguments: []const []const u8) !void {
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
    var output = try run(gpa, io, arguments);
    defer output.deinit(gpa);

    try expect_contains(output.stderr, part);
}

test "a discovered config turns on an opt in rule" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, suite, "discovered");
    defer workspace.deinit();

    const source = try workspace.write("a.rs", camel);

    _ = try workspace.write("tigerstyle.toml", "extend_select = [\"TS032\"]\n");

    try expect_stdout_contains(gpa, io, &.{source}, "TS032");
}

test "an isolated run reads no config" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, suite, "isolated");
    defer workspace.deinit();

    const source = try workspace.write("a.rs", camel);

    _ = try workspace.write("tigerstyle.toml", "extend_select = [\"TS032\"]\n");

    var output = try run(gpa, io, &.{ "--isolated", source });
    defer output.deinit(gpa);

    try std.testing.expectEqualStrings("", output.stdout);
    try std.testing.expectEqual(@as(?u8, 0), output.code);
}

test "a hidden name wins over the plain one" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, suite, "hidden");
    defer workspace.deinit();

    const source = try workspace.write("a.rs", camel);

    _ = try workspace.write("tigerstyle.toml", "extend_select = [\"TS042\"]\n");
    _ = try workspace.write(".tigerstyle.toml", "extend_select = [\"TS032\"]\n");

    try expect_stdout_contains(gpa, io, &.{source}, "TS032");
}

test "a nested config governs its subtree" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, suite, "nested");
    defer workspace.deinit();

    _ = try workspace.write("tigerstyle.toml", "extend_select = [\"TS032\"]\n");

    const outer = try workspace.write("a.rs", camel);
    const inner = try workspace.directory("deep");
    const nested_source = try workspace.write("deep/b.rs", camel);

    assert(std.mem.startsWith(u8, nested_source, inner));

    _ = try workspace.write("deep/tigerstyle.toml", "ignore = [\"TS032\"]\n");

    try expect_stdout_contains(gpa, io, &.{outer}, "TS032");
    try expect_stdout_empty(gpa, io, &.{nested_source});
}

test "an extend chain resolves outermost first" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, suite, "extend");
    defer workspace.deinit();

    _ = try workspace.write("base.toml", "extend_select = [\"TS032\"]\nline_length_max = 40\n");

    const source = try workspace.write("a.rs", camel);

    _ = try workspace.write("tigerstyle.toml", "extend = \"base.toml\"\nline_length_max = 200\n");

    var output = try run(gpa, io, &.{source});
    defer output.deinit(gpa);

    try expect_contains(output.stdout, "TS032");
    try expect_lacks(output.stdout, "TS012");
}

test "an extend cycle falls back to the defaults" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, suite, "cycle");
    defer workspace.deinit();

    const source = try workspace.write("a.rs", camel);

    _ = try workspace.write("tigerstyle.toml", "extend = \"other.toml\"\n");
    _ = try workspace.write("other.toml", "extend = \"tigerstyle.toml\"\n");

    var output = try run(gpa, io, &.{source});
    defer output.deinit(gpa);

    try expect_contains(output.stderr, "extends itself");
    try std.testing.expectEqual(@as(?u8, 0), output.code);
}

test "a broken config names its line" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, suite, "broken");
    defer workspace.deinit();

    const source = try workspace.write("a.rs", camel);

    _ = try workspace.write("tigerstyle.toml", "line_length_max = 40\nnonsense = 1\n");

    var output = try run(gpa, io, &.{source});
    defer output.deinit(gpa);

    try expect_contains(output.stderr, "tigerstyle.toml:2:");
    try expect_contains(output.stderr, "not a tigerstyle-lsp option");
}

test "a zero limit leaves the defaults standing" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, suite, "zero");
    defer workspace.deinit();

    const source = try workspace.write("a.rs", camel);

    _ = try workspace.write("tigerstyle.toml", "line_length_max = 0\n");

    try expect_stderr_contains(gpa, io, &.{source}, "the limit is zero");
}

test "a config selector whose digits overrun a code names no rule" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, suite, "selector-overrun");
    defer workspace.deinit();

    const source = try workspace.write("a.rs", camel);

    _ = try workspace.write("tigerstyle.toml", "extend_select = [\"TS9999999999\"]\n");

    try expect_stderr_contains(gpa, io, &.{source}, "the selector names no rule");
}

test "a command line selector replaces the config selection" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, suite, "selection");
    defer workspace.deinit();

    const source = try workspace.write("a.rs", camel);

    _ = try workspace.write("tigerstyle.toml", "extend_select = [\"TS032\"]\n");

    try expect_stdout_empty(gpa, io, &.{ "--select", "TS042", source });
}

test "a per file ignore covers a matching path" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, suite, "ignores");
    defer workspace.deinit();

    const source = try workspace.write("deep/a.rs", camel);

    _ = try workspace.write(
        "tigerstyle.toml",
        "extend_select = [\"TS032\"]\n\n[per-file-ignores]\n\"deep/*\" = [\"TS032\"]\n",
    );

    try expect_stdout_empty(gpa, io, &.{source});
}

test "a config threshold reaches the rule" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, suite, "threshold-config");
    defer workspace.deinit();

    const source = try workspace.write("a.rs", nested);

    _ = try workspace.write("tigerstyle.toml", "nesting_depth_max = 2\n");

    var output = try run(gpa, io, &.{source});
    defer output.deinit(gpa);

    try expect_contains(output.stdout, "TS008");
    try expect_contains(output.stdout, "over the 2 level limit");
}

test "a language block leaves another language on the global limit" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, suite, "threshold-language");
    defer workspace.deinit();

    const rust = try workspace.write("a.rs", nested);

    _ = try workspace.write(
        "tigerstyle.toml",
        "nesting_depth_max = 2\n\n[language.python]\nnesting_depth_max = 8\n",
    );

    try expect_stdout_contains(gpa, io, &.{rust}, "TS008");
}

test "a language block overrides a limit" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, suite, "language");
    defer workspace.deinit();

    const source = try workspace.write("a.rs", "fn helper() {\n    let value = 1;\n}\n");

    _ = try workspace.write(
        "tigerstyle.toml",
        "line_length_max = 200\n\n[language.rust]\nline_length_max = 10\n",
    );

    try expect_stdout_contains(gpa, io, &.{source}, "TS012");
}

test "a language block replaces the selection for that language only" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, suite, "language-select");
    defer workspace.deinit();

    const rust = try workspace.write("a.rs", "use std::fmt::*;\n");
    const python = try workspace.write("a.py", "from os import *\n\ndef f():\n    maxValue = 1\n");

    _ = try workspace.write("tigerstyle.toml", "[language.python]\nselect = [\"TS032\"]\n");

    var output = try run(gpa, io, &.{ rust, python });
    defer output.deinit(gpa);

    try expect_contains(output.stdout, "a.rs:1:5: warning TS011");
    try expect_contains(output.stdout, "a.py:4:5: warning TS032");

    var lines: cli.Lines = .init(output.stdout);
    var swallowed = false;

    for (0..output.stdout.len + 1) |_| {
        const line = lines.next() orelse break;

        if (contains(line, "a.py")) {
            if (contains(line, "TS011")) swallowed = true;
        }
    }

    if (swallowed) std.debug.print("{s}\n", .{output.stdout});

    try std.testing.expect(!swallowed);
}

test "a language ignore leaves the other languages alone" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, suite, "language-ignore");
    defer workspace.deinit();

    const rust = try workspace.write("a.rs", "use std::fmt::*;\n");
    const python = try workspace.write("a.py", "from os import *\n");

    _ = try workspace.write("tigerstyle.toml", "[language.python]\nignore = [\"TS011\"]\n");

    var output = try run(gpa, io, &.{ rust, python });
    defer output.deinit(gpa);

    try expect_contains(output.stdout, "a.rs");
    try expect_lacks(output.stdout, "a.py");
}

test "preview inside a language block is refused by line" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, suite, "language-preview");
    defer workspace.deinit();

    const source = try workspace.write("a.rs", camel);

    _ = try workspace.write("tigerstyle.toml", "[language.rust]\npreview = true\n");

    var output = try run(gpa, io, &.{source});
    defer output.deinit(gpa);

    try expect_contains(output.stderr, "tigerstyle.toml:2:");
    try expect_contains(output.stderr, "preview is a top-level key");
}

test "respect gitignore on the command line overrides the key" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, suite, "gitignore-flag");
    defer workspace.deinit();

    _ = try workspace.write(".gitignore", "skipped.rs\n");
    _ = try workspace.write("skipped.rs", camel);
    _ = try workspace.write("tigerstyle.toml", "extend_select = [\"TS032\"]\n");

    var honoured = try run(gpa, io, &.{workspace.root});
    defer honoured.deinit(gpa);

    try expect_lacks(honoured.stdout, "skipped.rs");

    var ignored = try run(gpa, io, &.{ "--respect-gitignore", "false", workspace.root });
    defer ignored.deinit(gpa);

    try expect_contains(ignored.stdout, "skipped.rs");
}

test "an unsatisfied required version is reported" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, suite, "version");
    defer workspace.deinit();

    const source = try workspace.write("a.rs", camel);

    _ = try workspace.write("tigerstyle.toml", "required_version = \">=99.0\"\n");

    try expect_stderr_contains(gpa, io, &.{source}, "required_version");
}
