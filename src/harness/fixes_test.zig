const std = @import("std");
const assert = std.debug.assert;
const cli = @import("cli.zig");
const Workspace = @import("workspace.zig");
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

fn run(gpa: std.mem.Allocator, io: std.Io, arguments: []const []const u8) !cli.Output {
    assert(arguments.len > 0);

    var command = try binary(gpa, io);
    defer command.deinit(gpa);

    try command.arguments_add(gpa, &.{ "lint", "--isolated" });
    try command.arguments_add(gpa, arguments);

    return finished(gpa, try command.output(gpa, io));
}

fn run_quiet(gpa: std.mem.Allocator, io: std.Io, arguments: []const []const u8) !void {
    assert(arguments.len > 0);

    var output = try run(gpa, io, arguments);

    output.deinit(gpa);
}

fn configured(
    gpa: std.mem.Allocator,
    io: std.Io,
    options: struct { config: []const u8, source: []const u8 },
) !cli.Output {
    assert(options.config.len > 0);
    assert(options.source.len > 0);

    var command = try binary(gpa, io);
    defer command.deinit(gpa);

    try command.arguments_add(gpa, &.{
        "lint",
        "--config",
        options.config,
        "--fix",
        options.source,
    });

    return finished(gpa, try command.output(gpa, io));
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

fn expect_quiet(gpa: std.mem.Allocator, io: std.Io, arguments: []const []const u8) !void {
    assert(arguments.len > 0);

    var output = try run(gpa, io, arguments);
    defer output.deinit(gpa);

    try std.testing.expectEqualStrings("", output.stdout);
}

test "a pass that cannot fit leaves the file byte identical" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var workspace: Workspace = try .init(gpa, io, .{ .name = "overflow", .suite = suite });
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

    const source = try workspace.write(.{ .body = body.items, .name = "a.rs" });

    var output = try run(gpa, io, &.{
        "--extend-select",
        "TS032",
        "--fix",
        "--unsafe-fixes",
        source,
    });

    defer output.deinit(gpa);

    try expect_contains(.{ .part = "outgrew the fix buffer", .text = output.stderr });
    try std.testing.expectEqualSlices(u8, body.items, try workspace.read("a.rs"));
}

test "a safe fix converges" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var workspace: Workspace = try .init(gpa, io, .{ .name = "converge", .suite = suite });
    defer workspace.deinit();

    const source = try workspace.write(.{ .body = note, .name = "a.rs" });

    try run_quiet(gpa, io, &.{ "--extend-select", "TS031", "--fix", source });
    try std.testing.expectEqualStrings(note_fixed, try workspace.read("a.rs"));
}

test "exit non zero on fix fails a run that wrote a fix" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var workspace: Workspace = try .init(gpa, io, .{ .name = "exit-on-fix", .suite = suite });
    defer workspace.deinit();

    const source = try workspace.write(.{ .body = note, .name = "a.rs" });

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
    var workspace: Workspace = try .init(gpa, io, .{ .name = "idempotent", .suite = suite });
    defer workspace.deinit();

    const source = try workspace.write(.{ .body = note, .name = "a.rs" });

    for (0..2) |_| {
        try run_quiet(gpa, io, &.{ "--extend-select", "TS031", "--fix", source });
    }

    try std.testing.expectEqualStrings(note_fixed, try workspace.read("a.rs"));
}

test "a diff run writes nothing" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var workspace: Workspace = try .init(gpa, io, .{ .name = "diff", .suite = suite });
    defer workspace.deinit();

    const source = try workspace.write(.{ .body = note, .name = "a.rs" });
    var output = try run(gpa, io, &.{ "--extend-select", "TS031", "--diff", source });
    defer output.deinit(gpa);

    try expect_contains(.{ .part = "-// this is a note", .text = output.stdout });
    try expect_contains(.{ .part = "+// This is a note.", .text = output.stdout });
    try std.testing.expectEqualStrings(note, try workspace.read("a.rs"));
}

test "add suppressions writes a trailing directive" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var workspace: Workspace = try .init(gpa, io, .{ .name = "suppress", .suite = suite });
    defer workspace.deinit();

    const source = try workspace.write(.{ .body = camel, .name = "a.rs" });

    try run_quiet(gpa, io, &.{ "--extend-select", "TS032", "--add-suppressions", source });

    try expect_contains(.{
        .part = "// tigerstyle-ignore: TS032",
        .text = try workspace.read("a.rs"),
    });

    try expect_quiet(gpa, io, &.{ "--extend-select", "TS032", source });
}

test "a generated file carries no findings" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var workspace: Workspace = try .init(gpa, io, .{ .name = "generated", .suite = suite });
    defer workspace.deinit();

    const source = try workspace.write(.{
        .body = "// Code generated by protoc. DO NOT EDIT.\n\nfn helper() {\n" ++
            "    let valueMax = 1;\n}\n",
        .name = "a.rs",
    });

    try expect_quiet(gpa, io, &.{ "--extend-select", "TS032", source });
}

test "a disable region covers its lines" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var workspace: Workspace = try .init(gpa, io, .{ .name = "region", .suite = suite });
    defer workspace.deinit();

    const source = try workspace.write(.{
        .body = "// tigerstyle-disable: TS032\nfn helper() {\n    let valueMax = 1;\n}\n" ++
            "// tigerstyle-enable: TS032\nfn other() {\n    let valueMin = 1;\n}\n",
        .name = "a.rs",
    });

    var output = try run(gpa, io, &.{ "--extend-select", "TS032", source });
    defer output.deinit(gpa);

    try expect_lacks(.{ .part = "a.rs:3:", .text = output.stdout });
    try expect_contains(.{ .part = "a.rs:7:", .text = output.stdout });
}

test "a reason does not change the codes" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var workspace: Workspace = try .init(gpa, io, .{ .name = "reason", .suite = suite });
    defer workspace.deinit();

    const source = try workspace.write(.{
        .body = "fn helper() {\n    let valueMax = 1;  // tigerstyle-ignore: TS032 -- the " ++
            "vendor spells it so\n}\n",
        .name = "a.rs",
    });

    try expect_quiet(gpa, io, &.{ "--extend-select", "TS032", source });
}

test "an unused directive is reported under preview" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var workspace: Workspace = try .init(gpa, io, .{ .name = "unused", .suite = suite });
    defer workspace.deinit();

    const source = try workspace.write(.{
        .body = "fn helper() {\n    // tigerstyle-ignore: TS002\n}\n",
        .name = "a.rs",
    });

    var output = try run(gpa, io, &.{ "--preview", "--extend-select", "TS050", source });
    defer output.deinit(gpa);

    try expect_contains(.{ .part = "TS050", .text = output.stdout });
}

test "a directive naming a disabled rule is left alone" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var workspace: Workspace = try .init(gpa, io, .{ .name = "disabled-code", .suite = suite });
    defer workspace.deinit();

    const source = try workspace.write(.{
        .body = "fn helper() {\n    // tigerstyle-ignore: TS032\n}\n",
        .name = "a.rs",
    });

    var output = try run(gpa, io, &.{ "--preview", "--extend-select", "TS050", source });
    defer output.deinit(gpa);

    try expect_lacks(.{ .part = "TS050", .text = output.stdout });
}

test "a directive keeps the codes that still fire" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var workspace: Workspace = try .init(gpa, io, .{ .name = "partial-directive", .suite = suite });
    defer workspace.deinit();

    const source = try workspace.write(.{
        .body = "def f():\n    # tigerstyle-ignore: TS012, TS029\n   x = 1\n",
        .name = "a.py",
    });

    try run_quiet(gpa, io, &.{ "--preview", "--extend-select", "TS050", "--fix", source });

    try std.testing.expectEqualStrings(
        "def f():\n    # tigerstyle-ignore: TS029\n   x = 1\n",
        try workspace.read("a.py"),
    );
}

test "an unknown code in a directive is reported" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var workspace: Workspace = try .init(gpa, io, .{ .name = "unknown", .suite = suite });
    defer workspace.deinit();

    const source = try workspace.write(.{
        .body = "fn helper() {\n    // tigerstyle-ignore: TS999\n}\n",
        .name = "a.rs",
    });

    var output = try run(gpa, io, &.{ "--preview", "--extend-select", "TS050", source });
    defer output.deinit(gpa);

    try expect_contains(.{ .part = "does not carry", .text = output.stdout });
}

test "unfixable strips the fix and keeps the finding" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var workspace: Workspace = try .init(gpa, io, .{ .name = "unfixable", .suite = suite });
    defer workspace.deinit();

    const source = try workspace.write(.{ .body = note_unspaced, .name = "a.rs" });

    var output = try run(gpa, io, &.{
        "--extend-select",
        "TS031",
        "--unfixable",
        "TS031",
        "--fix",
        source,
    });

    defer output.deinit(gpa);

    try expect_contains(.{ .part = "TS031", .text = output.stdout });
    try std.testing.expectEqualStrings(note_unspaced, try workspace.read("a.rs"));
}

test "fixable replaces the default set" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var workspace: Workspace = try .init(gpa, io, .{ .name = "fixable-replace", .suite = suite });
    defer workspace.deinit();

    const source = try workspace.write(.{ .body = note_unspaced, .name = "a.rs" });

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
    var workspace: Workspace = try .init(gpa, io, .{ .name = "fixable-tie", .suite = suite });
    defer workspace.deinit();

    const source = try workspace.write(.{ .body = note_unspaced, .name = "a.rs" });

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
    var workspace: Workspace = try .init(gpa, io, .{ .name = "fixable-specific", .suite = suite });
    defer workspace.deinit();

    const source = try workspace.write(.{ .body = note_unspaced, .name = "a.rs" });

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
    var workspace: Workspace = try .init(gpa, io, .{ .name = "fixable-extend", .suite = suite });
    defer workspace.deinit();

    const source = try workspace.write(.{ .body = note_unspaced, .name = "a.rs" });

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
    var workspace: Workspace = try .init(gpa, io, .{ .name = "fixable-config", .suite = suite });
    defer workspace.deinit();

    const source = try workspace.write(.{ .body = note_unspaced, .name = "a.rs" });

    const config = try workspace.write(.{
        .body = "extend_select = [\"TS031\"]\nunfixable = [\"TS031\"]\n",
        .name = "tigerstyle.toml",
    });

    var output = try configured(gpa, io, .{ .config = config, .source = source });
    defer output.deinit(gpa);

    try expect_contains(.{ .part = "TS031", .text = output.stdout });
    try std.testing.expectEqualStrings(note_unspaced, try workspace.read("a.rs"));
}

test "extend unsafe fixes holds a safe fix back" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var workspace: Workspace = try .init(gpa, io, .{ .name = "regrade", .suite = suite });
    defer workspace.deinit();

    const source = try workspace.write(.{ .body = note_unspaced, .name = "a.rs" });

    const config = try workspace.write(.{
        .body = "extend_select = [\"TS031\"]\nextend_unsafe_fixes = [\"TS031\"]\n",
        .name = "tigerstyle.toml",
    });

    var output = try configured(gpa, io, .{ .config = config, .source = source });
    defer output.deinit(gpa);

    try expect_contains(.{ .part = "TS031", .text = output.stdout });
    try std.testing.expectEqualStrings(note_unspaced, try workspace.read("a.rs"));
}

test "extend safe fixes lets an unsafe fix land" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var workspace: Workspace = try .init(gpa, io, .{ .name = "promote", .suite = suite });
    defer workspace.deinit();

    const source = try workspace.write(.{
        .body = "try:\n    work()\nexcept:\n    pass\n",
        .name = "a.py",
    });

    const config = try workspace.write(.{
        .body = "extend_safe_fixes = [\"TS009\"]\n",
        .name = "tigerstyle.toml",
    });

    var output = try configured(gpa, io, .{ .config = config, .source = source });
    defer output.deinit(gpa);

    try std.testing.expectEqualStrings(
        "try:\n    work()\nexcept Exception:\n    pass\n",
        try workspace.read("a.py"),
    );
}

test "an acronym two rules rename reaches a fixpoint" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var workspace: Workspace = try .init(gpa, io, .{ .name = "acronym", .suite = suite });
    defer workspace.deinit();

    const source = try workspace.write(.{
        .body = "package main\n\nfunc work() {\n\tTLSUnique := 1\n\tTls_session := 2\n" ++
            "\tuse(TLSUnique, Tls_session)\n}\n",
        .name = "a.go",
    });

    var output = try run(gpa, io, &.{
        "--select",
        "TS032,TS042",
        "--fix",
        "--unsafe-fixes",
        source,
    });

    defer output.deinit(gpa);

    try expect_lacks(.{ .part = "did not converge", .text = output.stderr });

    try std.testing.expectEqualStrings(
        "package main\n\nfunc work() {\n\tTLS_unique := 1\n\tTLS_session := 2\n" ++
            "\tuse(TLS_unique, TLS_session)\n}\n",
        try workspace.read("a.go"),
    );
}

test "every fixing rule reaches a fixpoint" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var workspace: Workspace = try .init(gpa, io, .{ .name = "idempotence", .suite = suite });
    defer workspace.deinit();

    const source = try workspace.write(.{
        .body = "#a note about work\ntry:\n    work()\nexcept:\n    pass  # noqa\n",
        .name = "a.py",
    });

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
