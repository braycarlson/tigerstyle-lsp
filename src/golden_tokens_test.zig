const std = @import("std");
const assert = std.debug.assert;
const cli = @import("testing/cli.zig");

const Texts = std.ArrayList([]const u8);

const Tokens = struct {
    code: i32,
    stdout: []u8,
};

const Shared = struct {
    base: []const u8,
    failed: std.atomic.Value(bool),
    next: std.atomic.Value(usize),
    paths: []const []const u8,
};

const bless = "TIGERSTYLE_GOLDEN=1 zig build test:unit -Dtest-filter=golden_tokens";

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

const full_trees = [_][]const u8{ "lint", "oracle/modern", "oracle/torture" };
const workers = 8;

fn goldens(gpa: std.mem.Allocator, io: std.Io) ![]u8 {
    return cli.rooted(gpa, io, "tests/fixtures/golden-tokens");
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

fn lintable(gpa: std.mem.Allocator, io: std.Io, tree: []const u8) !Texts {
    assert(tree.len > 0);

    var command = try cli.command(gpa, io);
    defer command.deinit(gpa);

    try command.arguments_add(gpa, &.{ "check", "--isolated", "--show-files", tree });

    var output = try command.output(gpa, io);
    defer output.deinit(gpa);

    if (!output.success()) std.debug.print("--show-files failed for {s}\n", .{tree});

    try std.testing.expect(output.success());

    var paths: Texts = .empty;
    errdefer cli.lines_free(gpa, &paths);

    var lines: cli.Lines = .init(output.stdout);

    for (0..output.stdout.len + 1) |_| {
        const line = lines.next() orelse break;
        if (std.mem.trim(u8, line, &std.ascii.whitespace).len == 0) continue;

        try paths.append(gpa, try gpa.dupe(u8, line));
    }

    std.mem.sort([]const u8, paths.items, {}, cli.text_less);

    return paths;
}

fn tokens(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !Tokens {
    assert(path.len > 0);

    var command = try cli.command(gpa, io);
    defer command.deinit(gpa);

    try command.arguments_add(gpa, &.{ "tokens", path });

    const output = try command.output(gpa, io);

    gpa.free(output.stderr);

    return .{ .code = output.code_or_negative(), .stdout = output.stdout };
}

fn dump(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const dumped = try tokens(gpa, io, path);
    if (dumped.code == 0) return dumped.stdout;
    defer gpa.free(dumped.stdout);

    return gpa.print("{s}# exit {d}\n", .{ dumped.stdout, dumped.code });
}

fn hashed(gpa: std.mem.Allocator, io: std.Io, paths: []const []const u8, base: []const u8) !Texts {
    var shared: Shared = .{
        .base = base,
        .failed = .init(false),
        .next = .init(0),
        .paths = paths,
    };

    var collected: [workers]Texts = @splat(.empty);
    var threads: [workers]std.Thread = undefined;

    for (&threads, &collected) |*thread, *mine| {
        thread.* = try std.Thread.spawn(.{}, worker, .{ gpa, io, &shared, mine });
    }

    for (threads) |thread| thread.join();

    var result: Texts = .empty;
    errdefer cli.lines_free(gpa, &result);

    for (&collected) |*mine| {
        try result.appendSlice(gpa, mine.items);
        mine.deinit(gpa);
    }

    try std.testing.expect(!shared.failed.load(.monotonic));
    try std.testing.expectEqual(paths.len, result.items.len);

    std.mem.sort([]const u8, result.items, {}, cli.text_less);

    return result;
}

fn worker(gpa: std.mem.Allocator, io: std.Io, shared: *Shared, mine: *Texts) void {
    for (0..shared.paths.len + 1) |_| {
        const index = shared.next.fetchAdd(1, .monotonic);
        if (index >= shared.paths.len) break;

        const line = hashed_line(gpa, io, shared.paths[index], shared.base) catch {
            shared.failed.store(true, .monotonic);

            return;
        };

        mine.append(gpa, line) catch {
            gpa.free(line);
            shared.failed.store(true, .monotonic);

            return;
        };
    }
}

fn hashed_line(gpa: std.mem.Allocator, io: std.Io, path: []const u8, base: []const u8) ![]u8 {
    const dumped = try tokens(gpa, io, path);
    defer gpa.free(dumped.stdout);

    const name = try cli.relative(gpa, path, base);
    defer gpa.free(name);

    const digest = cli.sha256(dumped.stdout);
    if (dumped.code == 0) return gpa.print("{s}  {s}", .{ name, digest });
    return gpa.print("{s}  {s}  exit {d}", .{ name, digest, dumped.code });
}

fn corpus_manifest(gpa: std.mem.Allocator, io: std.Io, name: []const u8) ![]u8 {
    const checkout = try checkout_of(gpa, io, name);
    defer gpa.free(checkout);

    var paths = try lintable(gpa, io, checkout);
    defer cli.lines_free(gpa, &paths);

    if (paths.items.len == 0) std.debug.print("{s} lints no files\n", .{name});

    try std.testing.expect(paths.items.len > 0);

    var lines = try hashed(gpa, io, paths.items, checkout);
    defer cli.lines_free(gpa, &lines);

    return cli.joined(gpa, lines.items);
}

fn capture_full_trees(gpa: std.mem.Allocator, io: std.Io) !void {
    for (full_trees) |tree| {
        const relative = try gpa.print("tests/fixtures/{s}", .{tree});
        defer gpa.free(relative);

        const directory = try cli.rooted(gpa, io, relative);
        defer gpa.free(directory);

        var paths = try lintable(gpa, io, directory);
        defer cli.lines_free(gpa, &paths);

        for (paths.items) |path| {
            const within = try cli.relative(gpa, path, directory);
            defer gpa.free(within);

            const name = try gpa.print("full/{s}/{s}.tokens", .{ tree, within });
            defer gpa.free(name);

            const text = try dump(gpa, io, path);
            defer gpa.free(text);

            try golden(gpa, io, name, text);
        }
    }
}

test "the token goldens are captured" {
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

    if (corpus_fetched) {
        for (corpora) |name| {
            const text = try corpus_manifest(gpa, io, name);
            defer gpa.free(text);

            const golden_name = try gpa.print("{s}.txt", .{name});
            defer gpa.free(golden_name);

            try golden(gpa, io, golden_name, text);
        }
    }

    try capture_full_trees(gpa, io);
    try manifest_check(gpa, io);
}

test "the full token dumps match their goldens" {
    if (cli.blessing()) return;

    try capture_full_trees(std.testing.allocator, std.testing.io);
}

test "the manifest matches the files on disk" {
    if (cli.blessing()) return;

    try manifest_check(std.testing.allocator, std.testing.io);
}

fn manifest_check(gpa: std.mem.Allocator, io: std.Io) !void {
    const directory = try goldens(gpa, io);
    defer gpa.free(directory);

    const text = try cli.manifest(gpa, io, directory);
    defer gpa.free(text);

    try golden(gpa, io, "MANIFEST.txt", text);
}

test "the hasher matches the published vectors" {
    try std.testing.expectEqualStrings(
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        &cli.sha256(""),
    );

    try std.testing.expectEqualStrings(
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        &cli.sha256("abc"),
    );

    try std.testing.expectEqualStrings(
        "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
        &cli.sha256("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
    );
}
