const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const cli = @import("testing/cli.zig");
const Workspace = @import("testing/workspace.zig");

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

    try command.environment_set("TIGERSTYLE_NO_CACHE", "1");

    assert(command.arguments.items.len == 1);

    return command;
}

fn finished(gpa: std.mem.Allocator, output: cli.Output) !cli.Output {
    var held = output;

    if (contains(held.stderr, guard_tripped)) {
        std.debug.print("{s}\n", .{held.stderr});
        held.deinit(gpa);

        return error.TestUnexpectedResult;
    }

    return held;
}

fn tigerstyle_lsp(gpa: std.mem.Allocator, io: std.Io, arguments: []const []const u8) !cli.Output {
    var command = try binary(gpa, io);
    defer command.deinit(gpa);

    try command.arguments_add(gpa, arguments);

    return finished(gpa, try command.output(gpa, io));
}

fn check(gpa: std.mem.Allocator, io: std.Io, arguments: []const []const u8) !cli.Output {
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
    var command = try binary(gpa, io);
    defer command.deinit(gpa);

    try command.arguments_add(gpa, arguments);

    return finished(gpa, try command.output_piped(gpa, io, source));
}

fn contains(text: []const u8, part: []const u8) bool {
    assert(part.len > 0);

    return std.mem.find(u8, text, part) != null;
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

fn expect_contains(text: []const u8, part: []const u8) !void {
    if (!contains(text, part)) std.debug.print("{s}\n", .{text});

    try std.testing.expect(contains(text, part));
}

fn expect_lacks(text: []const u8, part: []const u8) !void {
    if (contains(text, part)) std.debug.print("{s}\n", .{text});

    try std.testing.expect(!contains(text, part));
}

fn expect_run_code(
    gpa: std.mem.Allocator,
    io: std.Io,
    arguments: []const []const u8,
    code: u8,
) !void {
    var output = try tigerstyle_lsp(gpa, io, arguments);
    defer output.deinit(gpa);

    try expect_code(&output, code);
}

test "the tokens mode demands one path of a known language" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, suite, "tokens");
    defer workspace.deinit();

    const source = try workspace.write("sample.rs", camel);
    const other = try workspace.write("other.rs", camel);
    const text = try workspace.write("notes.txt", "plain\n");

    try expect_run_code(gpa, io, &.{"tokens"}, 2);
    try expect_run_code(gpa, io, &.{ "tokens", source, other }, 2);
    try expect_run_code(gpa, io, &.{ "tokens", text }, 2);
    try expect_run_code(gpa, io, &.{ "tokens", source }, 0);
}

test "the tokens mode refuses a file past the limit" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, suite, "tokens-oversized");
    defer workspace.deinit();

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);

    for (0..huge_bytes_min + 1) |_| {
        if (body.items.len > huge_bytes_min) break;

        try body.appendSlice(gpa, huge_unit);
    } else unreachable;

    const source = try workspace.write("huge.rs", body.items);

    var output = try tigerstyle_lsp(gpa, io, &.{ "tokens", source });
    defer output.deinit(gpa);

    try expect_code(&output, 1);
    try expect_contains(output.stderr, "rejected");
}

test "check and lint name the same mode" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, suite, "names");
    defer workspace.deinit();

    const path = try workspace.write("a.rs", camel);

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

    try expect_contains(output.stdout, "no-recursion");
    try expect_contains(output.stdout, "severity: error");
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

    try expect_contains(output.stdout, "line_length_max = 100");
    try expect_contains(output.stdout, "parameters_max = 7");
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
    try expect_contains(output.stdout, "Default: 100");
    try expect_contains(output.stdout, "line_length_max = 100");
}

test "config refuses an unknown option" {
    const gpa = std.testing.allocator;

    var output = try tigerstyle_lsp(gpa, std.testing.io, &.{ "config", "not_a_real_key" });
    defer output.deinit(gpa);

    try expect_code(&output, 2);
    try expect_contains(output.stderr, "names no option");
}

test "config lists every option under all" {
    const gpa = std.testing.allocator;

    var output = try tigerstyle_lsp(gpa, std.testing.io, &.{ "config", "--all" });
    defer output.deinit(gpa);

    try expect_contains(output.stdout, "assertions_per_function_min");
    try expect_contains(output.stdout, "line_length_max");
}

test "rule names the languages it reaches" {
    const gpa = std.testing.allocator;

    var output = try tigerstyle_lsp(gpa, std.testing.io, &.{ "rule", "TS001" });
    defer output.deinit(gpa);

    try expect_contains(output.stdout, "languages: go javascript odin python rust typescript zig");
}

test "a clean run writes nothing to standard error" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, suite, "quiet-run");
    defer workspace.deinit();

    const source = try workspace.write(
        "a.rs",
        "fn helper(value: u32) -> u32 {\n    assert!(value > 0);\n\n    value\n}\n",
    );

    var output = try check(gpa, io, &.{source});
    defer output.deinit(gpa);

    try std.testing.expectEqualStrings("", output.stderr);
}

test "the verbose flag prints the freeze report" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, suite, "verbose");
    defer workspace.deinit();

    const source = try workspace.write("a.rs", camel);

    var output = try check(gpa, io, &.{ "--verbose", source });
    defer output.deinit(gpa);

    try expect_contains(output.stderr, "limit path_bytes_max");
    try expect_contains(output.stderr, "frozen:");
}

test "the silent flag prints nothing" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, suite, "silent");
    defer workspace.deinit();

    const source = try workspace.write("a.rs", camel);

    var output = try check(gpa, io, &.{ "--silent", source });
    defer output.deinit(gpa);

    try std.testing.expectEqualStrings("", output.stdout);
    try std.testing.expectEqualStrings("", output.stderr);
}

test "a refused required version exits two" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, suite, "required-version");
    defer workspace.deinit();

    _ = try workspace.write("tigerstyle.toml", "required_version = \">=99.0.0\"\n");

    const source = try workspace.write("a.rs", camel);

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

    var workspace: Workspace = try .init(gpa, io, suite, "files");
    defer workspace.deinit();

    _ = try workspace.write("a.rs", camel);
    _ = try workspace.write("b.py", "value = 1\n");

    var output = try tigerstyle_lsp(gpa, io, &.{ "check", "--show-files", workspace.root });
    defer output.deinit(gpa);

    try std.testing.expectEqual(@as(u32, 2), line_count(output.stdout));
}

test "show files lists a walk longer than the artifact buffer" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, suite, "files_long");
    defer workspace.deinit();

    const stem: [listing_stem_bytes]u8 = @splat('a');
    var name_buffer: [listing_stem_bytes + 16]u8 = undefined;

    for (0..listing_file_count) |index| {
        const name = try std.mem.print(&name_buffer, "{s}_{d}.py", .{ &stem, index });

        _ = try workspace.write(name, "value = 1\n");
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

    var workspace: Workspace = try .init(gpa, io, suite, "statistics");
    defer workspace.deinit();

    const source = try workspace.write(
        "a.rs",
        "fn helper() {\n    let maxValue = 1;\n    let minValue = 2;\n}\n",
    );

    var output = try check(gpa, io, &.{ "--extend-select", "TS032", "--statistics", source });
    defer output.deinit(gpa);

    try expect_contains(output.stdout, "2  TS032");
}

test "statistics in json are one object a rule" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, suite, "statistics-json");
    defer workspace.deinit();

    const source = try workspace.write(
        "a.rs",
        "fn helper() {\n    let maxValue = 1;\n    let minValue = 2;\n}\n",
    );

    const clean = try workspace.write("b.rs", "fn helper() {\n}\n");

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
    , output.stdout);

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

    var workspace: Workspace = try .init(gpa, io, suite, "statistics-wrapper");
    defer workspace.deinit();

    const source = try workspace.write("a.rs", camel);

    var output = try check(gpa, io, &.{
        "--select",
        "TS032",
        "--format",
        "sarif",
        "--statistics",
        source,
    });

    defer output.deinit(gpa);

    try expect_contains(output.stdout, "1  TS032 snake-case-names");
    try expect_lacks(output.stdout, "$schema");
}

test "a selector whose digits overrun a code names no rule" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, suite, "selector-overrun");
    defer workspace.deinit();

    const source = try workspace.write("a.rs", camel);

    var output = try check(gpa, io, &.{ "--select", "TS9999999999", source });
    defer output.deinit(gpa);

    try expect_contains(output.stderr, "a selector on the command line names no rule");
    try expect_code(&output, 0);
}

test "a report that cannot be written fails the run" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, suite, "output-file-full");
    defer workspace.deinit();

    const source = try workspace.write("a.rs", "fn helper() {\n    let value = 1;\n}\n");

    const target = switch (builtin.target.os.tag) {
        .linux => "/dev/full",
        .windows => try workspace.write("report.json", ""),
        else => return error.SkipZigTest,
    };

    var locked: ?std.Io.File = null;
    defer if (locked) |file| file.close(io);

    if (builtin.target.os.tag == .windows) {
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

    try expect_contains(output.stderr, "the report could not be written in full");
    try expect_code(&output, 1);
}

test "a gitignored directory is skipped" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, suite, "gitignore");
    defer workspace.deinit();

    _ = try workspace.write("a.rs", camel);
    _ = try workspace.write("vendor/b.rs", camel);
    _ = try workspace.write(".gitignore", "vendor/\n");

    var output = try check(gpa, io, &.{ "--extend-select", "TS032", workspace.root });
    defer output.deinit(gpa);

    try expect_contains(output.stdout, "a.rs");
    try expect_lacks(output.stdout, "b.rs");
}

test "stdin reads under its given name" {
    const gpa = std.testing.allocator;

    var output = try piped(gpa, std.testing.io, &.{
        "check",
        "--isolated",
        "--extend-select",
        "TS032",
        "--stdin-filename",
        "a.rs",
        "-",
    }, camel);

    defer output.deinit(gpa);

    const named = std.mem.startsWith(u8, output.stdout, "a.rs:2:9:");

    if (!named) std.debug.print("{s}\n", .{output.stdout});

    try std.testing.expect(named);
    try expect_code(&output, 1);
}

test "a fixed standard input is written to standard output" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, suite, "stdin-fix");
    defer workspace.deinit();

    var output = try piped(gpa, io, &.{
        "check",
        "--isolated",
        "--extend-select",
        "TS031",
        "--stdin-filename",
        "a.rs",
        "--fix-only",
        "-",
    }, note);

    defer output.deinit(gpa);

    try std.testing.expectEqualStrings(note_fixed, output.stdout);
    try expect_code(&output, 0);
    try std.testing.expect(!try workspace.exists("-"));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, "-", .{}));
}

test "a suppressed standard input is written to standard output" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var output = try piped(gpa, io, &.{
        "check",
        "--isolated",
        "--extend-select",
        "TS031",
        "--stdin-filename",
        "a.rs",
        "--add-suppressions",
        "-",
    }, note);

    defer output.deinit(gpa);

    try expect_contains(output.stdout, "tigerstyle-ignore: TS031");
    try expect_code(&output, 0);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, "-", .{}));
}

test "an include glob narrows the scan" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, suite, "include");
    defer workspace.deinit();

    _ = try workspace.write("a.rs", camel);
    _ = try workspace.write("b.py", "def f():\n    maxValue = 1\n");

    var every = try check(gpa, io, &.{ "--extend-select", "TS032", workspace.root });
    defer every.deinit(gpa);

    try expect_contains(every.stdout, "a.rs");
    try expect_contains(every.stdout, "b.py");

    var narrowed = try check(gpa, io, &.{
        "--extend-select",
        "TS032",
        "--include",
        "*.rs",
        workspace.root,
    });

    defer narrowed.deinit(gpa);

    try expect_contains(narrowed.stdout, "a.rs");
    try expect_lacks(narrowed.stdout, "b.py");
}

test "an include glob and an exclude glob compose" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, suite, "include-exclude");
    defer workspace.deinit();

    _ = try workspace.write("a.rs", camel);
    _ = try workspace.write("b.rs", camel);

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

    try expect_contains(output.stdout, "a.rs");
    try expect_lacks(output.stdout, "b.rs");
}

test "a malformed exclude glob is reported once with its reason" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, suite, "malformed-glob");
    defer workspace.deinit();

    _ = try workspace.write("a.rs", camel);

    var output = try check(gpa, io, &.{
        "--extend-select",
        "TS032",
        "--exclude",
        "[abc",
        workspace.root,
    });

    defer output.deinit(gpa);

    try expect_contains(output.stderr, "a pattern is skipped: the character class opens with [");
    try expect_lacks(output.stderr, "more exclude patterns than tigerstyle-lsp reserves");
    try expect_contains(output.stdout, "a.rs");
}

test "brackets nested past the pairing bound are reported and the file still checked" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, suite, "deep-brackets");
    defer workspace.deinit();

    const depth = 300;
    const opened: [depth]u8 = @splat('(');
    const closed: [depth]u8 = @splat(')');
    const head = "fn helper() {\n    let valueMax = 1;\n    held!(";
    const source = head ++ opened ++ closed ++ ");\n}\n";

    _ = try workspace.write("a.rs", source);

    var output = try check(gpa, io, &.{ "--extend-select", "TS032", workspace.root });
    defer output.deinit(gpa);

    try expect_contains(output.stderr, "a file nests brackets deeper than 256");
    try expect_contains(output.stdout, "TS032");
}

test "a configuration search past the path table is reported" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, suite, "long-start");
    defer workspace.deinit();

    const outer: [200]u8 = @splat('d');
    const inner: [200]u8 = @splat('e');
    const long_name = outer ++ "/" ++ inner;
    const directory = try workspace.directory(long_name);

    _ = try workspace.write(long_name ++ "/a.rs", camel);

    var output = try tigerstyle_lsp(gpa, io, &.{ "check", directory });
    defer output.deinit(gpa);

    try expect_contains(output.stderr, "the search for a configuration stopped");
    try expect_contains(output.stderr, "the start path is longer than the path table holds");
}

test "a baseline round trips" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, suite, "baseline");
    defer workspace.deinit();

    const source = try workspace.write("a.rs", camel);
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

    var workspace: Workspace = try .init(gpa, io, suite, "threshold-flag");
    defer workspace.deinit();

    const source = try workspace.write("a.rs", nested);

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

    try expect_contains(lowered.stdout, "TS008");
    try expect_contains(lowered.stdout, "over the 2 level limit");
}

test "completions print for every shell" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    for ([_][]const u8{ "bash", "fish", "zsh" }) |shell| {
        var output = try tigerstyle_lsp(gpa, io, &.{ "completions", shell });
        defer output.deinit(gpa);

        try expect_contains(output.stdout, "tigerstyle-lsp");
    }

    try expect_run_code(gpa, io, &.{ "completions", "nonsense" }, 2);
}

test "force color wins over no color" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, suite, "color");
    defer workspace.deinit();

    const source = try workspace.write("a.rs", camel);
    const arguments = [_][]const u8{ "check", "--isolated", "--extend-select", "TS032", source };

    var forced = try binary(gpa, io);
    defer forced.deinit(gpa);

    try forced.arguments_add(gpa, &arguments);
    try forced.environment_set("FORCE_COLOR", "1");
    try forced.environment_set("NO_COLOR", "1");

    var output = try finished(gpa, try forced.output(gpa, io));
    defer output.deinit(gpa);

    try expect_contains(output.stdout, "\x1b");

    var plain = try binary(gpa, io);
    defer plain.deinit(gpa);

    try plain.arguments_add(gpa, &arguments);
    plain.environment_remove("FORCE_COLOR");
    try plain.environment_set("NO_COLOR", "1");

    var held = try finished(gpa, try plain.output(gpa, io));
    defer held.deinit(gpa);

    try expect_lacks(held.stdout, "\x1b");
}

test "an unreadable path is an error rather than a finding" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, suite, "errors");
    defer workspace.deinit();

    const source = try workspace.write("bad.rs", "\xff\xfe not text\n");

    var output = try check(gpa, io, &.{ "--format", "json", source });
    defer output.deinit(gpa);

    try expect_code(&output, 1);
    try std.testing.expectEqualStrings("[]", output.stdout);
    try expect_contains(output.stderr, "error: cannot read ");
    try expect_contains(output.stderr, "the file is not valid UTF-8");
}

test "an unreadable path writes an error line to standard error" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, suite, "errors-human");
    defer workspace.deinit();

    const source = try workspace.write("bad.rs", "\xff\xfe not text\n");

    var output = try check(gpa, io, &.{ "--format", "concise", source });
    defer output.deinit(gpa);

    try expect_code(&output, 1);
    try std.testing.expectEqualStrings("", output.stdout);
    try expect_contains(output.stderr, "error: cannot read ");
}

test "an inline value splits at the equals sign" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, suite, "inline-value");
    defer workspace.deinit();

    const source = try workspace.write("sample.rs", camel);

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

    var workspace: Workspace = try .init(gpa, io, suite, "argfile");
    defer workspace.deinit();

    const source = try workspace.write("sample.rs", camel);
    const listing = try gpa.print("--isolated\n--format\nconcise\n{s}\n", .{source});
    defer gpa.free(listing);

    const argfile = try workspace.write("arguments.txt", listing);
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
