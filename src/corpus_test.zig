const std = @import("std");
const assert = std.debug.assert;
const cli = @import("testing/cli.zig");

const Texts = std.ArrayList([]const u8);

const corpora = [_][]const u8{
    "alacritty",
    "axum",
    "bat",
    "bevy",
    "bootstrap",
    "bytes",
    "cargo",
    "clap",
    "cobra",
    "django",
    "express",
    "fastapi",
    "flask",
    "fzf",
    "ghostty",
    "httpx",
    "hyper",
    "libxev",
    "mach",
    "minio",
    "mypy",
    "numpy",
    "odin",
    "ols",
    "pandas",
    "pydantic",
    "regex",
    "requests",
    "rich",
    "ripgrep",
    "rust-analyzer",
    "serde",
    "sqlalchemy",
    "starship",
    "tigerbeetle",
    "tokio",
    "zig",
    "zig-clap",
    "zigimg",
    "zls",
    "zod",
};

const snapshot_bytes_max = 1 << 28;

fn binary(gpa: std.mem.Allocator, io: std.Io) !cli.Command {
    var command: cli.Command = try .init(gpa, io);
    errdefer command.deinit(gpa);

    try command.environment_set("TIGERSTYLE_NO_CACHE", "1");

    return command;
}

fn checkout_of(gpa: std.mem.Allocator, io: std.Io, name: []const u8) ![]u8 {
    assert(name.len > 0);

    const relative = try gpa.print("corpus/{s}", .{name});
    defer gpa.free(relative);

    return cli.rooted(gpa, io, relative);
}

fn fetched(gpa: std.mem.Allocator, io: std.Io) !bool {
    for (corpora) |name| {
        const checkout = try checkout_of(gpa, io, name);
        defer gpa.free(checkout);

        if (!cli.is_directory(io, checkout)) return false;
    }

    return true;
}

fn linted(gpa: std.mem.Allocator, io: std.Io, name: []const u8, everything: bool) ![]u8 {
    const checkout = try checkout_of(gpa, io, name);
    defer gpa.free(checkout);

    assert(cli.is_directory(io, checkout));

    var command = try binary(gpa, io);
    defer command.deinit(gpa);

    try command.arguments_add(gpa, &.{ "check", "--isolated", "--format", "concise" });

    if (everything) try command.arguments_add(gpa, &.{ "--select", "ALL", "--preview" });

    try command.argument(gpa, checkout);

    var output = try command.output(gpa, io);
    defer output.deinit(gpa);

    const prefix = try gpa.print("{s}/", .{checkout});
    defer gpa.free(prefix);

    var lines: Texts = .empty;
    defer cli.lines_free(gpa, &lines);

    var rows: cli.Lines = .init(output.stdout);

    for (0..output.stdout.len + 1) |_| {
        const row = rows.next() orelse break;
        const replaced = try std.mem.replaceOwned(u8, gpa, row, prefix, "");
        defer gpa.free(replaced);

        const trimmed = std.mem.trimEnd(u8, replaced, &std.ascii.whitespace);

        try lines.append(gpa, try gpa.dupe(u8, trimmed));
    }

    std.mem.sort([]const u8, lines.items, {}, cli.text_less);

    return std.mem.join(gpa, "\n", lines.items);
}

fn snapshot(gpa: std.mem.Allocator, io: std.Io, name: []const u8, everything: bool) ![]u8 {
    const findings = try linted(gpa, io, name, everything);
    errdefer gpa.free(findings);

    const again = try linted(gpa, io, name, everything);
    defer gpa.free(again);

    if (!std.mem.eql(u8, findings, again)) {
        std.debug.print("{s} lints differently on a second run\n", .{name});
    }

    try std.testing.expectEqualStrings(findings, again);

    return findings;
}

fn compare(gpa: std.mem.Allocator, io: std.Io, name: []const u8, everything: bool) !bool {
    const checkout = try checkout_of(gpa, io, name);
    defer gpa.free(checkout);

    if (!cli.is_directory(io, checkout)) return false;

    const findings = try snapshot(gpa, io, name, everything);
    defer gpa.free(findings);

    const suffix = if (everything) "all.snap" else "snap";

    const relative = try gpa.print("tests/fixtures/snapshots/{s}.{s}", .{
        name,
        suffix,
    });

    defer gpa.free(relative);

    const path = try cli.rooted(gpa, io, relative);
    defer gpa.free(path);

    const cwd = std.Io.Dir.cwd();

    if (cli.blessing()) {
        const parent = std.Io.Dir.path.dirname(path) orelse return error.TestUnexpectedResult;

        try cwd.createDirPath(io, parent);
        try cwd.writeFile(io, .{ .sub_path = path, .data = findings });

        return true;
    }

    const expected = cwd.readFileAlloc(io, path, gpa, .limited(snapshot_bytes_max)) catch |err| {
        std.debug.print("{s}.{s} is present; rerun with TIGERSTYLE_GOLDEN=1\n", .{ name, suffix });

        return err;
    };

    defer gpa.free(expected);

    if (!std.mem.eql(u8, findings, expected)) {
        std.debug.print("{s} has drifted at {s}\n", .{ name, suffix });
    }

    try std.testing.expectEqualStrings(expected, findings);

    return true;
}

fn every_corpus_compared(everything: bool) !void {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    if (!try fetched(gpa, io)) return error.SkipZigTest;

    var checked: u32 = 0;

    for (corpora) |name| {
        if (try compare(gpa, io, name, everything)) checked += 1;
    }

    if (checked == 0) std.debug.print("no corpus checkout was found under corpus/\n", .{});

    try std.testing.expect(checked > 0);
}

test "every corpus matches its snapshot" {
    try every_corpus_compared(false);
}

test "every corpus matches its full set snapshot" {
    try every_corpus_compared(true);
}

test "the corpus list matches the fetch recipe" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const path = try cli.rooted(gpa, io, "corpus.txt");
    defer gpa.free(path);

    const recipe = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(snapshot_bytes_max));
    defer gpa.free(recipe);

    var named: Texts = .empty;
    defer named.deinit(gpa);

    var lines: cli.Lines = .init(recipe);

    for (0..recipe.len + 1) |_| {
        const line = lines.next() orelse break;
        var words = std.mem.tokenizeAny(u8, line, &std.ascii.whitespace);

        if (words.next()) |word| try named.append(gpa, word);
    }

    try std.testing.expectEqual(corpora.len, named.items.len);

    for (corpora, named.items) |name, word| try std.testing.expectEqualStrings(name, word);
}
