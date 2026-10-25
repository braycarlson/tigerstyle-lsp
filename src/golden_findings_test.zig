const std = @import("std");
const assert = std.debug.assert;
const cli = @import("testing/cli.zig");

const bless = "TIGERSTYLE_GOLDEN=1 zig build test:unit -Dtest-filter=golden_findings";

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

const golden_bytes_max = 1 << 28;
const entry_count_max = 1 << 12;

fn goldens(gpa: std.mem.Allocator, io: std.Io) ![]u8 {
    return cli.rooted(gpa, io, "tests/fixtures/golden-findings");
}

fn golden(gpa: std.mem.Allocator, io: std.Io, name: []const u8, actual: []const u8) !void {
    assert(name.len > 0);

    const directory = try goldens(gpa, io);
    defer gpa.free(directory);

    try cli.golden(gpa, io, directory, name, actual, bless);
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

fn findings(gpa: std.mem.Allocator, io: std.Io, name: []const u8, everything: bool) ![]u8 {
    const checkout = try checkout_of(gpa, io, name);
    defer gpa.free(checkout);

    var runner = try cli.command(gpa, io);
    defer runner.deinit(gpa);

    try runner.arguments_add(gpa, &.{ "check", "--isolated", "--no-cache", "--format", "concise" });

    if (everything) try runner.arguments_add(gpa, &.{ "--select", "ALL", "--preview" });

    try runner.argument(gpa, checkout);

    var output = try runner.output(gpa, io);
    defer output.deinit(gpa);

    if (std.mem.find(u8, output.stderr, "allocation guard tripped") != null) {
        std.debug.print("{s} tripped the allocation guard: {s}\n", .{ name, output.stderr });

        return error.TestUnexpectedResult;
    }

    const prefix = try gpa.print("{s}/", .{checkout});
    defer gpa.free(prefix);

    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();

    try text.writer.print("# exit {d}\n", .{output.code_or_negative()});

    var lines: cli.Lines = .init(output.stdout);

    for (0..output.stdout.len + 1) |_| {
        const line = lines.next() orelse break;
        const replaced = try std.mem.replaceOwned(u8, gpa, line, prefix, "");
        defer gpa.free(replaced);

        try text.writer.print("{s}\n", .{std.mem.trimEnd(u8, replaced, &std.ascii.whitespace)});
    }

    return text.toOwnedSlice();
}

fn capture(gpa: std.mem.Allocator, io: std.Io, name: []const u8) !void {
    const suffixes = [_]struct { []const u8, bool }{ .{ "default", false }, .{ "all", true } };

    for (suffixes) |suffix| {
        const text = try findings(gpa, io, name, suffix[1]);
        defer gpa.free(text);

        const golden_name = try gpa.print("{s}.{s}.txt", .{ name, suffix[0] });
        defer gpa.free(golden_name);

        try golden(gpa, io, golden_name, text);
    }
}

fn manifest_check(gpa: std.mem.Allocator, io: std.Io) !void {
    const directory = try goldens(gpa, io);
    defer gpa.free(directory);

    const text = try cli.manifest(gpa, io, directory);
    defer gpa.free(text);

    try golden(gpa, io, "MANIFEST.txt", text);
}

test "the finding goldens are captured" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const corpus_fetched = try fetched(gpa, io);

    if (!corpus_fetched) {
        if (!cli.blessing()) return error.SkipZigTest;
    }

    if (!corpus_fetched) {
        std.debug.print("the corpus is not fetched; a bless would write a partial set. " ++
            "run just corpus-fetch\n", .{});
    }

    try std.testing.expect(corpus_fetched or !cli.blessing());

    if (!corpus_fetched) return;

    for (corpora) |name| try capture(gpa, io, name);

    try manifest_check(gpa, io);
}

test "the manifest matches the files on disk" {
    if (cli.blessing()) return;

    try manifest_check(std.testing.allocator, std.testing.io);
}

test "no golden carries an absolute path" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const root = try cli.root(gpa, io);
    defer gpa.free(root);

    const parent = try std.Io.Dir.path.join(gpa, &.{ root, ".." });
    defer gpa.free(parent);

    const name = try cli.relative(gpa, root, parent);
    defer gpa.free(name);

    try std.testing.expect(name.len > 0);

    const path = try goldens(gpa, io);
    defer gpa.free(path);

    var directory = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer directory.close(io);

    var entries = directory.iterate();

    for (0..entry_count_max) |_| {
        const entry = try entries.next(io) orelse break;
        const text = try directory.readFileAlloc(io, entry.name, gpa, .limited(golden_bytes_max));
        defer gpa.free(text);

        if (std.mem.find(u8, text, root) != null) {
            std.debug.print("{s}/{s} carries an absolute path\n", .{ path, entry.name });
        }

        try std.testing.expect(std.mem.find(u8, text, root) == null);
    } else unreachable;
}
