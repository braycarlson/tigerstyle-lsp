const std = @import("std");
const assert = std.debug.assert;
const cli = @import("cli.zig");
const Workspace = @import("workspace.zig");
const camel = "fn helper() {\n    let valueMax = 1;\n}\n";
const guard_tripped = "allocation guard tripped";
const huge_bytes_min = 1 << 20;
const huge_unit = "fn helper() {\n    let value = 1;\n}\n";
const listing_bytes_min = 1 << 18;
const listing_file_count = 1_400;
const listing_stem_bytes = 192;
const note = "// this is a note\nfn main() {\n}\n";
const note_fixed = "// This is a note.\nfn main() {\n}\n";
const suite = "cli";

const nested = "fn helper(a: bool, b: bool, c: bool) {\n    if a {\n        if b {\n" ++
    "            if c {\n                let _ = 1;\n            }\n        }\n    }\n}\n";

fn binary(gpa: std.mem.Allocator, io: std.Io) !cli.Command {
    var command: cli.Command = try .init(gpa, io);
    errdefer command.deinit(gpa);

    try command.environment_set(.{ .key = "TIGERSTYLE_NO_CACHE", .value = "1" });

    assert(command.arguments.items.len == 1);

    return command;
}

fn finished(gpa: std.mem.Allocator, output: cli.Output) !cli.Output {
    var held = output;

    if (contains(.{ .part = guard_tripped, .text = held.stderr })) {
        std.debug.print("{s}\n", .{held.stderr});
        held.deinit(gpa);

        return error.TestUnexpectedResult;
    }

    return held;
}

fn tigerstyle_lsp(gpa: std.mem.Allocator, io: std.Io, arguments: []const []const u8) !cli.Output {
    assert(arguments.len > 0);

    var command = try binary(gpa, io);
    defer command.deinit(gpa);

    try command.arguments_add(gpa, arguments);

    return finished(gpa, try command.output(gpa, io));
}

fn check(gpa: std.mem.Allocator, io: std.Io, arguments: []const []const u8) !cli.Output {
    assert(arguments.len > 0);

    var command = try binary(gpa, io);
    defer command.deinit(gpa);

    try command.arguments_add(gpa, &.{ "check", "--isolated" });
    try command.arguments_add(gpa, arguments);

    return finished(gpa, try command.output(gpa, io));
}

fn piped(
    gpa: std.mem.Allocator,
    io: std.Io,
    arguments: []const []const u8,
    source: []const u8,
) !cli.Output {
    assert(arguments.len > 0);
    assert(source.len > 0);

    var command = try binary(gpa, io);
    defer command.deinit(gpa);

    try command.arguments_add(gpa, arguments);

    return finished(gpa, try command.output_piped(gpa, io, source));
}

fn contains(options: struct { part: []const u8, text: []const u8 }) bool {
    assert(options.part.len > 0);

    return std.mem.find(u8, options.text, options.part) != null;
}

fn line_count(text: []const u8) u32 {
    var lines: cli.Lines = .init(text);
    var count: u32 = 0;

    for (0..text.len + 1) |_| {
        _ = lines.next() orelse break;

        count += 1;
    }

    assert(count <= text.len);

    return count;
}

fn expect_code(output: *const cli.Output, code: u8) !void {
    if (output.code != code) std.debug.print("{s}\n", .{output.stderr});

    try std.testing.expectEqual(@as(?u8, code), output.code);
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

fn expect_run_code(
    gpa: std.mem.Allocator,
    io: std.Io,
    arguments: []const []const u8,
    code: u8,
) !void {
    assert(arguments.len > 0);

    var output = try tigerstyle_lsp(gpa, io, arguments);
    defer output.deinit(gpa);

    try expect_code(&output, code);
}

test "the tokens mode demands one path of a known language" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var workspace: Workspace = try .init(gpa, io, .{ .name = "tokens", .suite = suite });
    defer workspace.deinit();

    const source = try workspace.write(.{ .body = camel, .name = "sample.rs" });
    const other = try workspace.write(.{ .body = camel, .name = "other.rs" });
    const text = try workspace.write(.{ .body = "plain\n", .name = "notes.txt" });

    try expect_run_code(gpa, io, &.{"tokens"}, 2);
    try expect_run_code(gpa, io, &.{ "tokens", source, other }, 2);
    try expect_run_code(gpa, io, &.{ "tokens", text }, 2);
    try expect_run_code(gpa, io, &.{ "tokens", source }, 0);
}

test "the tokens mode refuses a file past the limit" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var workspace: Workspace = try .init(gpa, io, .{ .name = "tokens-oversized", .suite = suite });
    defer workspace.deinit();

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);

    for (0..huge_bytes_min + 1) |_| {
        if (body.items.len > huge_bytes_min) break;

        try body.appendSlice(gpa, huge_unit);
    } else unreachable;

    const source = try workspace.write(.{ .body = body.items, .name = "huge.rs" });
    var output = try tigerstyle_lsp(gpa, io, &.{ "tokens", source });
    defer output.deinit(gpa);

    try expect_code(&output, 1);
    try expect_contains(.{ .part = "rejected", .text = output.stderr });
}

test "check and lint name the same mode" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var workspace: Workspace = try .init(gpa, io, .{ .name = "names", .suite = suite });
    defer workspace.deinit();

    const path = try workspace.write(.{ .body = camel, .name = "a.rs" });
    var checked = try tigerstyle_lsp(gpa, io, &.{ "check", "--isolated", path });
    defer checked.deinit(gpa);

    var linted = try tigerstyle_lsp(gpa, io, &.{ "lint", "--isolated", path });
    defer linted.deinit(gpa);

    try std.testing.expectEqualStrings(checked.stdout, linted.stdout);
}

test "version prints the crate version" {
    const gpa = std.testing.allocator;
    var output = try tigerstyle_lsp(gpa, std.testing.io, &.{"version"});
    defer output.deinit(gpa);

    try std.testing.expect(std.mem.startsWith(u8, output.stdout, "tigerstyle-lsp "));
}

test "rule explains one rule" {
    const gpa = std.testing.allocator;
    var output = try tigerstyle_lsp(gpa, std.testing.io, &.{ "rule", "TS001" });
    defer output.deinit(gpa);

    try expect_contains(.{ .part = "no-recursion", .text = output.stdout });
    try expect_contains(.{ .part = "severity: error", .text = output.stdout });
}

test "rule lists every rule without an argument" {
    const gpa = std.testing.allocator;
    var output = try tigerstyle_lsp(gpa, std.testing.io, &.{"rule"});
    defer output.deinit(gpa);

    try std.testing.expectEqual(@as(u32, 57), line_count(output.stdout));
}

test "config prints the resolved settings" {
    const gpa = std.testing.allocator;
    var output = try tigerstyle_lsp(gpa, std.testing.io, &.{ "config", "--isolated" });
    defer output.deinit(gpa);

    try expect_contains(.{ .part = "line_length_max = 100", .text = output.stdout });
    try expect_contains(.{ .part = "parameters_max = 7", .text = output.stdout });
}

test "show settings matches the config subcommand" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var one = try tigerstyle_lsp(gpa, io, &.{ "config", "--isolated", "--show-settings" });
    defer one.deinit(gpa);

    var two = try tigerstyle_lsp(gpa, io, &.{ "check", "--isolated", "--show-settings", "." });
    defer two.deinit(gpa);

    try std.testing.expectEqualStrings(one.stdout, two.stdout);
}

test "config explains one option" {
    const gpa = std.testing.allocator;
    var output = try tigerstyle_lsp(gpa, std.testing.io, &.{ "config", "line_length_max" });
    defer output.deinit(gpa);

    try std.testing.expect(std.mem.startsWith(u8, output.stdout, "line_length_max"));
    try expect_contains(.{ .part = "Default: 100", .text = output.stdout });
    try expect_contains(.{ .part = "line_length_max = 100", .text = output.stdout });
}

test "config refuses an unknown option" {
    const gpa = std.testing.allocator;
    var output = try tigerstyle_lsp(gpa, std.testing.io, &.{ "config", "not_a_real_key" });
    defer output.deinit(gpa);

    try expect_code(&output, 2);
    try expect_contains(.{ .part = "names no option", .text = output.stderr });
}

test "rule refuses an unknown name" {
    const gpa = std.testing.allocator;
    var output = try tigerstyle_lsp(gpa, std.testing.io, &.{ "rule", "not_a_real_rule" });
    defer output.deinit(gpa);

    try expect_code(&output, 2);
    try expect_contains(.{ .part = "no rule named", .text = output.stderr });
}

test "config lists every option under all" {
    const gpa = std.testing.allocator;
    var output = try tigerstyle_lsp(gpa, std.testing.io, &.{ "config", "--all" });
    defer output.deinit(gpa);

    try expect_contains(.{ .part = "assertions_per_function_min", .text = output.stdout });
    try expect_contains(.{ .part = "line_length_max", .text = output.stdout });
}

test "rule names the languages it reaches" {
    const gpa = std.testing.allocator;
    var output = try tigerstyle_lsp(gpa, std.testing.io, &.{ "rule", "TS001" });
    defer output.deinit(gpa);

    try expect_contains(.{
        .part = "languages: go javascript odin python rust typescript zig",
        .text = output.stdout,
    });
}

test "a clean run writes nothing to standard error" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var workspace: Workspace = try .init(gpa, io, .{ .name = "quiet-run", .suite = suite });
    defer workspace.deinit();

    const source = try workspace.write(.{
        .body = "fn helper(value: u32) -> u32 {\n    assert!(value > 0);\n\n    value\n}\n",
        .name = "a.rs",
    });

    var output = try check(gpa, io, &.{source});
    defer output.deinit(gpa);

    try std.testing.expectEqualStrings("", output.stderr);
}

test "the verbose flag prints the freeze report" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var workspace: Workspace = try .init(gpa, io, .{ .name = "verbose", .suite = suite });
    defer workspace.deinit();

    const source = try workspace.write(.{ .body = camel, .name = "a.rs" });
    var output = try check(gpa, io, &.{ "--verbose", source });
    defer output.deinit(gpa);

    try expect_contains(.{ .part = "limit path_bytes_max", .text = output.stderr });
    try expect_contains(.{ .part = "frozen:", .text = output.stderr });
}

test "the silent flag prints nothing" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var workspace: Workspace = try .init(gpa, io, .{ .name = "silent", .suite = suite });
    defer workspace.deinit();

    const source = try workspace.write(.{ .body = camel, .name = "a.rs" });
    var output = try check(gpa, io, &.{ "--silent", source });
    defer output.deinit(gpa);

    try std.testing.expectEqualStrings("", output.stdout);
    try std.testing.expectEqualStrings("", output.stderr);
}

test "a refused required version exits two" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var workspace: Workspace = try .init(gpa, io, .{ .name = "required-version", .suite = suite });
    defer workspace.deinit();

    _ = try workspace.write(.{
        .body = "required_version = \">=99.0.0\"\n",
        .name = "tigerstyle.toml",
    });

    const source = try workspace.write(.{ .body = camel, .name = "a.rs" });
    var command = try binary(gpa, io);
    defer command.deinit(gpa);

    try command.arguments_add(gpa, &.{ "check", "--no-cache", source });
    command.directory_set(workspace.root);

    var output = try finished(gpa, try command.output(gpa, io));
    defer output.deinit(gpa);

    try expect_code(&output, 2);
}

test "show files lists the walk" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var workspace: Workspace = try .init(gpa, io, .{ .name = "files", .suite = suite });
    defer workspace.deinit();

    _ = try workspace.write(.{ .body = camel, .name = "a.rs" });
    _ = try workspace.write(.{ .body = "value = 1\n", .name = "b.py" });

    var output = try tigerstyle_lsp(gpa, io, &.{ "check", "--show-files", workspace.root });
    defer output.deinit(gpa);

    try std.testing.expectEqual(@as(u32, 2), line_count(output.stdout));
}

test "show files lists a walk longer than the artifact buffer" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var workspace: Workspace = try .init(gpa, io, .{ .name = "files_long", .suite = suite });
    defer workspace.deinit();

    const stem: [listing_stem_bytes]u8 = @splat('a');
    var name_buffer: [listing_stem_bytes + 16]u8 = undefined;

    for (0..listing_file_count) |index| {
        const name = try std.mem.print(&name_buffer, "{s}_{d}.py", .{ &stem, index });

        _ = try workspace.write(.{ .body = "value = 1\n", .name = name });
    }

    var output = try tigerstyle_lsp(gpa, io, &.{ "check", "--show-files", workspace.root });
    defer output.deinit(gpa);

    try expect_code(&output, 0);
    try std.testing.expect(output.stdout.len > listing_bytes_min);
    try std.testing.expectEqual(@as(u32, listing_file_count), line_count(output.stdout));
}

test "statistics counts a rule once per finding" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var workspace: Workspace = try .init(gpa, io, .{ .name = "statistics", .suite = suite });
    defer workspace.deinit();

    const source = try workspace.write(.{
        .body = "fn helper() {\n    let maxValue = 1;\n    let minValue = 2;\n}\n",
        .name = "a.rs",
    });

    var output = try check(gpa, io, &.{ "--extend-select", "TS032", "--statistics", source });
    defer output.deinit(gpa);

    try expect_contains(.{ .part = "2  TS032", .text = output.stdout });
}

test "statistics in json are one object a rule" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var workspace: Workspace = try .init(gpa, io, .{ .name = "statistics-json", .suite = suite });
    defer workspace.deinit();

    const source = try workspace.write(.{
        .body = "fn helper() {\n    let maxValue = 1;\n    let minValue = 2;\n}\n",
        .name = "a.rs",
    });

    const clean = try workspace.write(.{ .body = "fn helper() {\n}\n", .name = "b.rs" });

    var output = try check(gpa, io, &.{
        "--select",
        "TS032",
        "--format",
        "json",
        "--statistics",
        source,
    });

    defer output.deinit(gpa);

    try std.testing.expectEqualStrings(
        \\[
        \\  {
        \\    "code": "TS032",
        \\    "count": 2,
        \\    "fixable": false,
        \\    "fixable_count": 0,
        \\    "name": "snake-case-names",
        \\    "url": "https://github.com/braycarlson/tigerstyle-lsp/blob/main/docs/rules/TS032.md"
        \\  }
        \\]
        \\
    ,
        output.stdout,
    );

    var empty = try check(gpa, io, &.{
        "--select",
        "TS032",
        "--format",
        "json",
        "--statistics",
        clean,
    });

    defer empty.deinit(gpa);

    try std.testing.expectEqualStrings("[]\n", empty.stdout);
}

test "statistics leave the wrapper of a machine format out" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, .{
        .name = "statistics-wrapper",
        .suite = suite,
    });

    defer workspace.deinit();

    const source = try workspace.write(.{ .body = camel, .name = "a.rs" });

    var output = try check(gpa, io, &.{
        "--select",
        "TS032",
        "--format",
        "sarif",
        "--statistics",
        source,
    });

    defer output.deinit(gpa);

    try expect_contains(.{ .part = "1  TS032 snake-case-names", .text = output.stdout });
    try expect_lacks(.{ .part = "$schema", .text = output.stdout });
}

test "a selector whose digits overrun a code names no rule" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var workspace: Workspace = try .init(gpa, io, .{ .name = "selector-overrun", .suite = suite });
    defer workspace.deinit();

    const source = try workspace.write(.{ .body = camel, .name = "a.rs" });
    var output = try check(gpa, io, &.{ "--select", "TS9999999999", source });
    defer output.deinit(gpa);

    try expect_contains(.{
        .part = "a selector on the command line names no rule",
        .text = output.stderr,
    });

    try expect_code(&output, 0);
}

test "a report that cannot be written fails the run" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var workspace: Workspace = try .init(gpa, io, .{ .name = "output-file-full", .suite = suite });
    defer workspace.deinit();

    const source = try workspace.write(.{
        .body = "fn helper() {\n    let value = 1;\n}\n",
        .name = "a.rs",
    });

    const device_full = "/dev/full";

    const device_held = if (std.Io.Dir.cwd().access(io, device_full, .{ .write = true })) |_|
        true
    else |_|
        false;

    const target = if (device_held) device_full else try workspace.write(.{
        .body = "",
        .name = "report.json",
    });

    var locked: ?std.Io.File = null;
    defer if (locked) |file| file.close(io);

    if (!device_held) {
        locked = try std.Io.Dir.cwd().openFile(io, target, .{
            .lock = .exclusive,
            .mode = .read_write,
        });
    }

    var output = try check(gpa, io, &.{
        "--format",
        "json",
        "--output-file",
        target,
        source,
    });

    defer output.deinit(gpa);

    try expect_contains(.{
        .part = "the report could not be written in full",
        .text = output.stderr,
    });

    try expect_code(&output, 1);
}

test "a gitignored directory is skipped" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var workspace: Workspace = try .init(gpa, io, .{ .name = "gitignore", .suite = suite });
    defer workspace.deinit();

    _ = try workspace.write(.{ .body = camel, .name = "a.rs" });
    _ = try workspace.write(.{ .body = camel, .name = "vendor/b.rs" });
    _ = try workspace.write(.{ .body = "vendor/\n", .name = ".gitignore" });

    var output = try check(gpa, io, &.{ "--extend-select", "TS032", workspace.root });
    defer output.deinit(gpa);

    try expect_contains(.{ .part = "a.rs", .text = output.stdout });
    try expect_lacks(.{ .part = "b.rs", .text = output.stdout });
}

test "stdin reads under its given name" {
    const gpa = std.testing.allocator;

    var output = try piped(
        gpa,
        std.testing.io,
        &.{ "check", "--isolated", "--extend-select", "TS032", "--stdin-filename", "a.rs", "-" },
        camel,
    );

    defer output.deinit(gpa);

    const named = std.mem.startsWith(u8, output.stdout, "a.rs:2:9:");

    if (!named) std.debug.print("{s}\n", .{output.stdout});

    try std.testing.expect(named);
    try expect_code(&output, 1);
}

test "a fixed standard input is written to standard output" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var workspace: Workspace = try .init(gpa, io, .{ .name = "stdin-fix", .suite = suite });
    defer workspace.deinit();

    var output = try piped(
        gpa,
        io,
        &.{
            "check",
            "--isolated",
            "--extend-select",
            "TS031",
            "--stdin-filename",
            "a.rs",
            "--fix-only",
            "-",
        },
        note,
    );

    defer output.deinit(gpa);

    try std.testing.expectEqualStrings(note_fixed, output.stdout);
    try expect_code(&output, 0);
    try std.testing.expect(!try workspace.exists("-"));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, "-", .{}));
}

test "a suppressed standard input is written to standard output" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var output = try piped(
        gpa,
        io,
        &.{
            "check",
            "--isolated",
            "--extend-select",
            "TS031",
            "--stdin-filename",
            "a.rs",
            "--add-suppressions",
            "-",
        },
        note,
    );

    defer output.deinit(gpa);

    try expect_contains(.{ .part = "tigerstyle-ignore: TS031", .text = output.stdout });
    try expect_code(&output, 0);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, "-", .{}));
}

test "an include glob narrows the scan" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var workspace: Workspace = try .init(gpa, io, .{ .name = "include", .suite = suite });
    defer workspace.deinit();

    _ = try workspace.write(.{ .body = camel, .name = "a.rs" });
    _ = try workspace.write(.{ .body = "def f():\n    maxValue = 1\n", .name = "b.py" });

    var every = try check(gpa, io, &.{ "--extend-select", "TS032", workspace.root });
    defer every.deinit(gpa);

    try expect_contains(.{ .part = "a.rs", .text = every.stdout });
    try expect_contains(.{ .part = "b.py", .text = every.stdout });

    var narrowed = try check(gpa, io, &.{
        "--extend-select",
        "TS032",
        "--include",
        "*.rs",
        workspace.root,
    });

    defer narrowed.deinit(gpa);

    try expect_contains(.{ .part = "a.rs", .text = narrowed.stdout });
    try expect_lacks(.{ .part = "b.py", .text = narrowed.stdout });
}

test "an include glob and an exclude glob compose" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var workspace: Workspace = try .init(gpa, io, .{ .name = "include-exclude", .suite = suite });
    defer workspace.deinit();

    _ = try workspace.write(.{ .body = camel, .name = "a.rs" });
    _ = try workspace.write(.{ .body = camel, .name = "b.rs" });

    var output = try check(gpa, io, &.{
        "--extend-select",
        "TS032",
        "--include",
        "*.rs",
        "--exclude",
        "b.rs",
        workspace.root,
    });

    defer output.deinit(gpa);

    try expect_contains(.{ .part = "a.rs", .text = output.stdout });
    try expect_lacks(.{ .part = "b.rs", .text = output.stdout });
}

test "a malformed exclude glob is reported once with its reason" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var workspace: Workspace = try .init(gpa, io, .{ .name = "malformed-glob", .suite = suite });
    defer workspace.deinit();

    _ = try workspace.write(.{ .body = camel, .name = "a.rs" });

    var output = try check(gpa, io, &.{
        "--extend-select",
        "TS032",
        "--exclude",
        "[abc",
        workspace.root,
    });

    defer output.deinit(gpa);

    try expect_contains(.{
        .part = "a pattern is skipped: the character class opens with [",
        .text = output.stderr,
    });

    try expect_lacks(.{
        .part = "more exclude patterns than tigerstyle-lsp reserves",
        .text = output.stderr,
    });

    try expect_contains(.{ .part = "a.rs", .text = output.stdout });
}

test "brackets nested past the pairing bound are reported and the file still checked" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var workspace: Workspace = try .init(gpa, io, .{ .name = "deep-brackets", .suite = suite });
    defer workspace.deinit();

    const depth = 300;
    const opened: [depth]u8 = @splat('(');
    const closed: [depth]u8 = @splat(')');
    const head = "fn helper() {\n    let valueMax = 1;\n    held!(";
    const source = head ++ opened ++ closed ++ ");\n}\n";

    _ = try workspace.write(.{ .body = source, .name = "a.rs" });

    var output = try check(gpa, io, &.{ "--extend-select", "TS032", workspace.root });
    defer output.deinit(gpa);

    try expect_contains(.{
        .part = "a file nests brackets deeper than 256",
        .text = output.stderr,
    });

    try expect_contains(.{ .part = "TS032", .text = output.stdout });
}

test "a configuration search past the path table is reported" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var workspace: Workspace = try .init(gpa, io, .{ .name = "long-start", .suite = suite });
    defer workspace.deinit();

    const outer: [200]u8 = @splat('d');
    const inner: [200]u8 = @splat('e');
    const long_name = outer ++ "/" ++ inner;
    const directory = try workspace.directory(long_name);

    _ = try workspace.write(.{ .body = camel, .name = long_name ++ "/a.rs" });

    var output = try tigerstyle_lsp(gpa, io, &.{ "check", directory });
    defer output.deinit(gpa);

    try expect_contains(.{
        .part = "the search for a configuration stopped",
        .text = output.stderr,
    });

    try expect_contains(.{
        .part = "the start path is longer than the path table holds",
        .text = output.stderr,
    });
}

test "a baseline round trips" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var workspace: Workspace = try .init(gpa, io, .{ .name = "baseline", .suite = suite });
    defer workspace.deinit();

    const source = try workspace.write(.{ .body = camel, .name = "a.rs" });
    const baseline = try workspace.path("base.txt");

    var written = try check(gpa, io, &.{
        "--extend-select",
        "TS032",
        "--write-baseline",
        baseline,
        source,
    });

    defer written.deinit(gpa);

    try expect_code(&written, 0);

    var filtered = try check(gpa, io, &.{
        "--extend-select",
        "TS032",
        "--baseline",
        baseline,
        source,
    });

    defer filtered.deinit(gpa);

    try std.testing.expectEqualStrings("", filtered.stdout);
    try expect_code(&filtered, 0);
}

test "a threshold flag reaches the rule" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var workspace: Workspace = try .init(gpa, io, .{ .name = "threshold-flag", .suite = suite });
    defer workspace.deinit();

    const source = try workspace.write(.{ .body = nested, .name = "a.rs" });
    var standing = try check(gpa, io, &.{source});
    defer standing.deinit(gpa);

    try std.testing.expectEqualStrings("", standing.stdout);

    var lowered = try check(gpa, io, &.{
        "--nesting-depth-max",
        "2",
        "--format",
        "concise",
        source,
    });

    defer lowered.deinit(gpa);

    try expect_contains(.{ .part = "TS008", .text = lowered.stdout });
    try expect_contains(.{ .part = "over the 2 level limit", .text = lowered.stdout });
}

test "completions print for every shell" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    for ([_][]const u8{ "bash", "fish", "zsh" }) |shell| {
        var output = try tigerstyle_lsp(gpa, io, &.{ "completions", shell });
        defer output.deinit(gpa);

        try expect_contains(.{ .part = "tigerstyle-lsp", .text = output.stdout });
    }

    try expect_run_code(gpa, io, &.{ "completions", "nonsense" }, 2);
}

test "force color wins over no color" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var workspace: Workspace = try .init(gpa, io, .{ .name = "color", .suite = suite });
    defer workspace.deinit();

    const source = try workspace.write(.{ .body = camel, .name = "a.rs" });
    const arguments = [_][]const u8{ "check", "--isolated", "--extend-select", "TS032", source };
    var forced = try binary(gpa, io);
    defer forced.deinit(gpa);

    try forced.arguments_add(gpa, &arguments);
    try forced.environment_set(.{ .key = "FORCE_COLOR", .value = "1" });
    try forced.environment_set(.{ .key = "NO_COLOR", .value = "1" });

    var output = try finished(gpa, try forced.output(gpa, io));
    defer output.deinit(gpa);

    try expect_contains(.{ .part = "\x1b", .text = output.stdout });

    var plain = try binary(gpa, io);
    defer plain.deinit(gpa);

    try plain.arguments_add(gpa, &arguments);
    plain.environment_remove("FORCE_COLOR");
    try plain.environment_set(.{ .key = "NO_COLOR", .value = "1" });

    var held = try finished(gpa, try plain.output(gpa, io));
    defer held.deinit(gpa);

    try expect_lacks(.{ .part = "\x1b", .text = held.stdout });
}

test "an unreadable path is an error rather than a finding" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var workspace: Workspace = try .init(gpa, io, .{ .name = "errors", .suite = suite });
    defer workspace.deinit();

    const source = try workspace.write(.{ .body = "\xff\xfe not text\n", .name = "bad.rs" });
    var output = try check(gpa, io, &.{ "--format", "json", source });
    defer output.deinit(gpa);

    try expect_code(&output, 1);
    try std.testing.expectEqualStrings("[]", output.stdout);
    try expect_contains(.{ .part = "error: cannot read ", .text = output.stderr });
    try expect_contains(.{ .part = "the file is not valid UTF-8", .text = output.stderr });
}

test "an unreadable path writes an error line to standard error" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var workspace: Workspace = try .init(gpa, io, .{ .name = "errors-human", .suite = suite });
    defer workspace.deinit();

    const source = try workspace.write(.{ .body = "\xff\xfe not text\n", .name = "bad.rs" });
    var output = try check(gpa, io, &.{ "--format", "concise", source });
    defer output.deinit(gpa);

    try expect_code(&output, 1);
    try std.testing.expectEqualStrings("", output.stdout);
    try expect_contains(.{ .part = "error: cannot read ", .text = output.stderr });
}

test "an inline value splits at the equals sign" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var workspace: Workspace = try .init(gpa, io, .{ .name = "inline-value", .suite = suite });
    defer workspace.deinit();

    const source = try workspace.write(.{ .body = camel, .name = "sample.rs" });
    var joined = try tigerstyle_lsp(gpa, io, &.{ "check", "--isolated", "--format=json", source });
    defer joined.deinit(gpa);

    var spaced = try tigerstyle_lsp(gpa, io, &.{
        "check",
        "--isolated",
        "--format",
        "json",
        source,
    });

    defer spaced.deinit(gpa);

    try std.testing.expectEqual(joined.code, spaced.code);
    try std.testing.expectEqualStrings(joined.stdout, spaced.stdout);
    try std.testing.expectEqualStrings("[]", joined.stdout);
}

test "an argfile expands to the lines it holds" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var workspace: Workspace = try .init(gpa, io, .{ .name = "argfile", .suite = suite });
    defer workspace.deinit();

    const source = try workspace.write(.{ .body = camel, .name = "sample.rs" });
    const listing = try gpa.print("--isolated\n--format\nconcise\n{s}\n", .{source});
    defer gpa.free(listing);

    const argfile = try workspace.write(.{ .body = listing, .name = "arguments.txt" });
    const spelled = try gpa.print("@{s}", .{argfile});
    defer gpa.free(spelled);

    var expanded = try tigerstyle_lsp(gpa, io, &.{ "check", spelled });
    defer expanded.deinit(gpa);

    var direct = try tigerstyle_lsp(gpa, io, &.{
        "check",
        "--isolated",
        "--format",
        "concise",
        source,
    });

    defer direct.deinit(gpa);

    try std.testing.expectEqual(expanded.code, direct.code);
    try std.testing.expectEqualStrings(direct.stdout, expanded.stdout);
}
