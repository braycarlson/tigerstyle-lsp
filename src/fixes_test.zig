const std = @import("std");
const assert = std.debug.assert;
const cli = @import("testing/cli.zig");
const Workspace = @import("testing/workspace.zig");

const camel = "fn helper() {\n    let valueMax = 1;\n}\n";
const file_bytes_max = 1 << 20;
const guard_tripped = "allocation guard tripped";
const note = "// this is a note\nfn main() {\n}\n";
const note_fixed = "// This is a note.\nfn main() {\n}\n";
const note_unspaced = "//this is a note\nfn main() {\n}\n";
const padding = "// " ++ padding_body ++ "\n";
const padding_body: [76]u8 = @splat('x');
const suite = "fixes";

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

fn run(gpa: std.mem.Allocator, io: std.Io, arguments: []const []const u8) !cli.Output {
    var command = try binary(gpa, io);
    defer command.deinit(gpa);

    try command.arguments_add(gpa, &.{ "lint", "--isolated" });
    try command.arguments_add(gpa, arguments);

    return finished(gpa, try command.output(gpa, io));
}

fn run_quiet(gpa: std.mem.Allocator, io: std.Io, arguments: []const []const u8) !void {
    var output = try run(gpa, io, arguments);

    output.deinit(gpa);
}

fn configured(
    gpa: std.mem.Allocator,
    io: std.Io,
    config: []const u8,
    source: []const u8,
) !cli.Output {
    var command = try binary(gpa, io);
    defer command.deinit(gpa);

    try command.arguments_add(gpa, &.{ "lint", "--config", config, "--fix", source });

    return finished(gpa, try command.output(gpa, io));
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

fn expect_quiet(gpa: std.mem.Allocator, io: std.Io, arguments: []const []const u8) !void {
    var output = try run(gpa, io, arguments);
    defer output.deinit(gpa);

    try std.testing.expectEqualStrings("", output.stdout);
}

test "a pass that cannot fit leaves the file byte identical" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, suite, "overflow");
    defer workspace.deinit();

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);

    try body.appendSlice(gpa, camel);

    for (0..file_bytes_max) |_| {
        if (body.items.len + padding.len > file_bytes_max) break;

        try body.appendSlice(gpa, padding);
    } else unreachable;

    try body.appendNTimes(gpa, 'x', file_bytes_max - body.items.len);

    assert(body.items.len == file_bytes_max);

    const source = try workspace.write("a.rs", body.items);

    var output = try run(gpa, io, &.{
        "--extend-select",
        "TS032",
        "--fix",
        "--unsafe-fixes",
        source,
    });

    defer output.deinit(gpa);

    try expect_contains(output.stderr, "outgrew the fix buffer");
    try std.testing.expectEqualSlices(u8, body.items, try workspace.read("a.rs"));
}

test "a safe fix converges" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, suite, "converge");
    defer workspace.deinit();

    const source = try workspace.write("a.rs", note);

    try run_quiet(gpa, io, &.{ "--extend-select", "TS031", "--fix", source });
    try std.testing.expectEqualStrings(note_fixed, try workspace.read("a.rs"));
}

test "exit non zero on fix fails a run that wrote a fix" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, suite, "exit-on-fix");
    defer workspace.deinit();

    const source = try workspace.write("a.rs", note);

    const arguments = [_][]const u8{
        "--extend-select",
        "TS031",
        "--fix",
        "--exit-non-zero-on-fix",
        source,
    };

    var fixed = try run(gpa, io, &arguments);
    defer fixed.deinit(gpa);

    try std.testing.expectEqualStrings(note_fixed, try workspace.read("a.rs"));

    if (fixed.code != 1) std.debug.print("{s}\n", .{fixed.stderr});

    try std.testing.expectEqual(@as(?u8, 1), fixed.code);

    var settled = try run(gpa, io, &arguments);
    defer settled.deinit(gpa);

    if (settled.code != 0) std.debug.print("{s}\n", .{settled.stderr});

    try std.testing.expectEqual(@as(?u8, 0), settled.code);
}

test "a fixed file is idempotent" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, suite, "idempotent");
    defer workspace.deinit();

    const source = try workspace.write("a.rs", note);

    for (0..2) |_| {
        try run_quiet(gpa, io, &.{ "--extend-select", "TS031", "--fix", source });
    }

    try std.testing.expectEqualStrings(note_fixed, try workspace.read("a.rs"));
}

test "a diff run writes nothing" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, suite, "diff");
    defer workspace.deinit();

    const source = try workspace.write("a.rs", note);

    var output = try run(gpa, io, &.{ "--extend-select", "TS031", "--diff", source });
    defer output.deinit(gpa);

    try expect_contains(output.stdout, "-// this is a note");
    try expect_contains(output.stdout, "+// This is a note.");
    try std.testing.expectEqualStrings(note, try workspace.read("a.rs"));
}

test "add suppressions writes a trailing directive" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, suite, "suppress");
    defer workspace.deinit();

    const source = try workspace.write("a.rs", camel);

    try run_quiet(gpa, io, &.{ "--extend-select", "TS032", "--add-suppressions", source });
    try expect_contains(try workspace.read("a.rs"), "// tigerstyle-ignore: TS032");
    try expect_quiet(gpa, io, &.{ "--extend-select", "TS032", source });
}

test "a generated file carries no findings" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, suite, "generated");
    defer workspace.deinit();

    const source = try workspace.write(
        "a.rs",
        "// Code generated by protoc. DO NOT EDIT.\n\nfn helper() {\n    let valueMax = 1;\n}\n",
    );

    try expect_quiet(gpa, io, &.{ "--extend-select", "TS032", source });
}

test "a disable region covers its lines" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, suite, "region");
    defer workspace.deinit();

    const source = try workspace.write(
        "a.rs",
        "// tigerstyle-disable: TS032\nfn helper() {\n    let valueMax = 1;\n}\n" ++
            "// tigerstyle-enable: TS032\nfn other() {\n    let valueMin = 1;\n}\n",
    );

    var output = try run(gpa, io, &.{ "--extend-select", "TS032", source });
    defer output.deinit(gpa);

    try expect_lacks(output.stdout, "a.rs:3:");
    try expect_contains(output.stdout, "a.rs:7:");
}

test "a reason does not change the codes" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, suite, "reason");
    defer workspace.deinit();

    const source = try workspace.write(
        "a.rs",
        "fn helper() {\n    let valueMax = 1;  // tigerstyle-ignore: TS032 -- the vendor spells " ++
            "it so\n}\n",
    );

    try expect_quiet(gpa, io, &.{ "--extend-select", "TS032", source });
}

test "an unused directive is reported under preview" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, suite, "unused");
    defer workspace.deinit();

    const source = try workspace.write(
        "a.rs",
        "fn helper() {\n    // tigerstyle-ignore: TS002\n}\n",
    );

    var output = try run(gpa, io, &.{ "--preview", "--extend-select", "TS050", source });
    defer output.deinit(gpa);

    try expect_contains(output.stdout, "TS050");
}

test "a directive naming a disabled rule is left alone" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, suite, "disabled-code");
    defer workspace.deinit();

    const source = try workspace.write(
        "a.rs",
        "fn helper() {\n    // tigerstyle-ignore: TS032\n}\n",
    );

    var output = try run(gpa, io, &.{ "--preview", "--extend-select", "TS050", source });
    defer output.deinit(gpa);

    try expect_lacks(output.stdout, "TS050");
}

test "a directive keeps the codes that still fire" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, suite, "partial-directive");
    defer workspace.deinit();

    const source = try workspace.write(
        "a.py",
        "def f():\n    # tigerstyle-ignore: TS012, TS029\n   x = 1\n",
    );

    try run_quiet(gpa, io, &.{ "--preview", "--extend-select", "TS050", "--fix", source });

    try std.testing.expectEqualStrings(
        "def f():\n    # tigerstyle-ignore: TS029\n   x = 1\n",
        try workspace.read("a.py"),
    );
}

test "an unknown code in a directive is reported" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, suite, "unknown");
    defer workspace.deinit();

    const source = try workspace.write(
        "a.rs",
        "fn helper() {\n    // tigerstyle-ignore: TS999\n}\n",
    );

    var output = try run(gpa, io, &.{ "--preview", "--extend-select", "TS050", source });
    defer output.deinit(gpa);

    try expect_contains(output.stdout, "does not carry");
}

test "unfixable strips the fix and keeps the finding" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, suite, "unfixable");
    defer workspace.deinit();

    const source = try workspace.write("a.rs", note_unspaced);

    var output = try run(gpa, io, &.{
        "--extend-select",
        "TS031",
        "--unfixable",
        "TS031",
        "--fix",
        source,
    });

    defer output.deinit(gpa);

    try expect_contains(output.stdout, "TS031");
    try std.testing.expectEqualStrings(note_unspaced, try workspace.read("a.rs"));
}

test "fixable replaces the default set" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, suite, "fixable-replace");
    defer workspace.deinit();

    const source = try workspace.write("a.rs", note_unspaced);

    try run_quiet(gpa, io, &.{
        "--extend-select",
        "TS031",
        "--fixable",
        "TS002",
        "--fix",
        source,
    });

    try std.testing.expectEqualStrings(note_unspaced, try workspace.read("a.rs"));
}

test "unfixable beats fixable at equal specificity" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, suite, "fixable-tie");
    defer workspace.deinit();

    const source = try workspace.write("a.rs", note_unspaced);

    try run_quiet(gpa, io, &.{
        "--extend-select",
        "TS031",
        "--fixable",
        "TS031",
        "--unfixable",
        "TS031",
        "--fix",
        source,
    });

    try std.testing.expectEqualStrings(note_unspaced, try workspace.read("a.rs"));
}

test "a specific fixable selector beats a broad unfixable one" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, suite, "fixable-specific");
    defer workspace.deinit();

    const source = try workspace.write("a.rs", note_unspaced);

    try run_quiet(gpa, io, &.{
        "--extend-select",
        "TS031",
        "--unfixable",
        "ALL",
        "--extend-fixable",
        "TS031",
        "--fix",
        source,
    });

    try std.testing.expectEqualStrings(note_fixed, try workspace.read("a.rs"));
}

test "extend fixable adds to a replaced set" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, suite, "fixable-extend");
    defer workspace.deinit();

    const source = try workspace.write("a.rs", note_unspaced);

    try run_quiet(gpa, io, &.{
        "--extend-select",
        "TS031",
        "--fixable",
        "TS002",
        "--extend-fixable",
        "TS031",
        "--fix",
        source,
    });

    try std.testing.expectEqualStrings(note_fixed, try workspace.read("a.rs"));
}

test "a fixable key reads from the configuration file" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, suite, "fixable-config");
    defer workspace.deinit();

    const source = try workspace.write("a.rs", note_unspaced);

    const config = try workspace.write(
        "tigerstyle.toml",
        "extend_select = [\"TS031\"]\nunfixable = [\"TS031\"]\n",
    );

    var output = try configured(gpa, io, config, source);
    defer output.deinit(gpa);

    try expect_contains(output.stdout, "TS031");
    try std.testing.expectEqualStrings(note_unspaced, try workspace.read("a.rs"));
}

test "extend unsafe fixes holds a safe fix back" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, suite, "regrade");
    defer workspace.deinit();

    const source = try workspace.write("a.rs", note_unspaced);

    const config = try workspace.write(
        "tigerstyle.toml",
        "extend_select = [\"TS031\"]\nextend_unsafe_fixes = [\"TS031\"]\n",
    );

    var output = try configured(gpa, io, config, source);
    defer output.deinit(gpa);

    try expect_contains(output.stdout, "TS031");
    try std.testing.expectEqualStrings(note_unspaced, try workspace.read("a.rs"));
}

test "extend safe fixes lets an unsafe fix land" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, suite, "promote");
    defer workspace.deinit();

    const source = try workspace.write("a.py", "try:\n    work()\nexcept:\n    pass\n");
    const config = try workspace.write("tigerstyle.toml", "extend_safe_fixes = [\"TS009\"]\n");

    var output = try configured(gpa, io, config, source);
    defer output.deinit(gpa);

    try std.testing.expectEqualStrings(
        "try:\n    work()\nexcept Exception:\n    pass\n",
        try workspace.read("a.py"),
    );
}

test "an acronym two rules rename reaches a fixpoint" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, suite, "acronym");
    defer workspace.deinit();

    const source = try workspace.write(
        "a.go",
        "package main\n\nfunc work() {\n\tTLSUnique := 1\n\tTls_session := 2\n" ++
            "\tuse(TLSUnique, Tls_session)\n}\n",
    );

    var output = try run(gpa, io, &.{
        "--select",
        "TS032,TS042",
        "--fix",
        "--unsafe-fixes",
        source,
    });

    defer output.deinit(gpa);

    try expect_lacks(output.stderr, "did not converge");

    try std.testing.expectEqualStrings(
        "package main\n\nfunc work() {\n\tTLS_unique := 1\n\tTLS_session := 2\n" ++
            "\tuse(TLS_unique, TLS_session)\n}\n",
        try workspace.read("a.go"),
    );
}

test "every fixing rule reaches a fixpoint" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace: Workspace = try .init(gpa, io, suite, "idempotence");
    defer workspace.deinit();

    const source = try workspace.write(
        "a.py",
        "#a note about work\ntry:\n    work()\nexcept:\n    pass  # noqa\n",
    );

    const arguments = [_][]const u8{
        "--preview",
        "--select",
        "ALL",
        "--fix",
        "--unsafe-fixes",
        source,
    };

    try run_quiet(gpa, io, &arguments);

    const once = try workspace.read("a.py");

    try run_quiet(gpa, io, &arguments);
    try std.testing.expectEqualStrings(once, try workspace.read("a.py"));
}
