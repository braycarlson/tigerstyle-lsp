const std = @import("std");
const assert = std.debug.assert;
const cli = @import("cli.zig");
const Counts = std.StringArrayHashMapUnmanaged(u32);

const Sandbox = struct {
    path: []u8,
    temporary: std.testing.TmpDir,

    fn init(gpa: std.mem.Allocator) !Sandbox {
        var temporary = std.testing.tmpDir(.{ .iterate = false });
        errdefer temporary.cleanup();

        const path = try std.Io.Dir.path.join(gpa, &.{
            std.testing.TmpDir.parent_dir_path,
            &temporary.sub_path,
        });

        assert(path.len > std.testing.TmpDir.parent_dir_path.len);
        assert(!std.Io.Dir.path.isAbsolute(path));

        return .{ .path = path, .temporary = temporary };
    }

    fn deinit(sandbox: *Sandbox, gpa: std.mem.Allocator) void {
        assert(sandbox.path.len > 0);

        gpa.free(sandbox.path);
        sandbox.temporary.cleanup();
        sandbox.* = undefined;
    }

    fn join(sandbox: *const Sandbox, gpa: std.mem.Allocator, name: []const u8) ![]u8 {
        assert(name.len > 0);
        assert(sandbox.path.len > 0);

        return std.Io.Dir.path.join(gpa, &.{ sandbox.path, name });
    }
};

const Source = struct {
    body: []const u8,
    name: []const u8,
};

const fixing_sources = [_]Source{
    .{
        .name = "a.py",
        .body = "#a note about the work\ntry:\n    readValue()\nexcept:\n    pass  # noqa\n",
    },
    .{
        .name = "b.rs",
        .body = "#[allow(dead_code)]\n//a note about the work\nstruct HttpClient {\n}\n\nfn " ++
            "readSector() {\n    // tigerstyle-ignore: TS002\n}\n",
    },
    .{
        .name = "c.go",
        .body = "package main\n\n//a note about the work\nfunc helper() int {\n\tvalue := 1 " ++
            "//nolint\n\treturn value\n}\n",
    },
    .{
        .name = "d.zig",
        .body = "//a note about the work\nfn helper() void {\n    @setRuntimeSafety(false);\n}\n",
    },
};

const guard_values = [_][]const u8{ "", "1", "true", "Observe", "observe ", "observe" };

const matrix_languages = [_][]const u8{
    "go",
    "javascript",
    "odin",
    "python",
    "rust",
    "typescript",
    "zig",
};

const printing_modes = [_][]const []const u8{
    &.{ "artifacts", "coverage", "--verbose" },
    &.{ "artifacts", "rules", "--verbose" },
    &.{ "artifacts", "schema", "--verbose" },
    &.{ "artifacts", "settings", "--verbose" },
    &.{ "config", "--all", "--verbose" },
    &.{ "rule", "TS001", "--verbose" },
};

const tripped = "allocation guard tripped";
const frozen = "frozen: ";
const body_bytes_max = 1 << 24;
const cliff_name_bytes: u32 = 32;
const directory_count_max = 4_096;
const entry_count_max = 1 << 16;
const line_count_max = 1 << 20;

fn run(gpa: std.mem.Allocator, io: std.Io, arguments: []const []const u8) !cli.Output {
    assert(arguments.len > 0);

    var command: cli.Command = try .init(gpa, io);
    defer command.deinit(gpa);

    try command.arguments_add(gpa, arguments);

    return command.output(gpa, io);
}

fn contains(options: struct { part: []const u8, text: []const u8 }) bool {
    assert(options.part.len > 0);

    return std.mem.find(u8, options.text, options.part) != null;
}

fn expect_contains(options: struct { part: []const u8, text: []const u8 }) !void {
    assert(options.part.len > 0);

    if (contains(.{ .part = options.part, .text = options.text })) return;

    std.debug.print("expected \"{s}\" in:\n{s}\n", .{ options.part, options.text });

    return error.TestExpectedContains;
}

fn expect_lacks(options: struct { part: []const u8, text: []const u8 }) !void {
    assert(options.part.len > 0);

    if (!contains(.{ .part = options.part, .text = options.text })) return;

    std.debug.print("expected no \"{s}\" in:\n{s}\n", .{ options.part, options.text });

    return error.TestUnexpectedContains;
}

fn expect_success(output: *const cli.Output) !void {
    assert(output.code_or_negative() >= -1);

    if (output.success()) return;

    std.debug.print("exit {d}:\n{s}\n", .{ output.code_or_negative(), output.stderr });

    return error.TestExpectedSuccess;
}

fn expect_failure(output: *const cli.Output) !void {
    assert(output.code_or_negative() >= -1);

    if (!output.success()) return;

    std.debug.print("expected a failure:\n{s}\n", .{output.stderr});

    return error.TestExpectedFailure;
}

fn expect_guard(options: struct { case: []const u8, message: []const u8 }) !void {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    assert(options.case.len > 0);
    assert(options.message.len > 0);

    var output = try run(gpa, io, &.{ "selftest", options.case });
    defer output.deinit(gpa);

    try expect_failure(&output);
    try expect_contains(.{ .part = options.message, .text = output.stderr });
}

fn expect_tokens(
    options: struct { first: []const u8, fixture: []const u8, last: []const u8 },
) !void {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    assert(options.first.len > 0);
    assert(options.last.len > 0);

    const path = try cli.rooted(gpa, io, options.fixture);
    defer gpa.free(path);

    var output = try run(gpa, io, &.{ "tokens", path });
    defer output.deinit(gpa);

    try expect_success(&output);
    try expect_lacks(.{ .part = tripped, .text = output.stderr });

    var lines: cli.Lines = .init(output.stdout);
    const line_first = lines.next() orelse return error.TestExpectedLine;
    var line_last = line_first;

    for (0..line_count_max) |_| {
        line_last = lines.next() orelse break;
    } else unreachable;

    try std.testing.expectEqualStrings(options.first, line_first);
    try std.testing.expectEqualStrings(options.last, line_last);
}

fn deep_workspace(gpa: std.mem.Allocator, io: std.Io, root: []const u8, bytes: u32) ![]u8 {
    assert(root.len + cliff_name_bytes < bytes);
    assert(bytes <= std.Io.Dir.max_path_bytes);

    const name_directory: [cliff_name_bytes - 1]u8 = @splat('a');
    var held: std.ArrayList(u8) = .empty;
    defer held.deinit(gpa);

    try held.appendSlice(gpa, root);

    for (0..bytes) |_| {
        if (held.items.len + cliff_name_bytes + 4 >= bytes) break;

        try held.append(gpa, '/');
        try held.appendSlice(gpa, &name_directory);
        try std.Io.Dir.cwd().createDirPath(io, held.items);
    } else unreachable;

    const left = bytes - held.items.len - 4;

    try held.append(gpa, '/');
    try held.appendNTimes(gpa, 'b', left);
    try held.appendSlice(gpa, ".rs");

    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = held.items,
        .data = "fn helper() {\n    let maxVal = 1;\n}\n",
    });

    assert(held.items.len == bytes);

    return held.toOwnedSlice(gpa);
}

fn copied(
    gpa: std.mem.Allocator,
    io: std.Io,
    options: struct { from: []const u8, to: []const u8 },
) !void {
    assert(options.from.len > 0);
    assert(options.to.len > 0);

    const cwd = std.Io.Dir.cwd();

    try cwd.createDirPath(io, options.to);

    var source = try cwd.openDir(io, options.from, .{ .iterate = true });
    defer source.close(io);

    var walker = try source.walk(gpa);
    defer walker.deinit();

    var directory_count: u32 = 1;

    for (0..entry_count_max) |_| {
        const entry = try walker.next(io) orelse break;
        const landing = try std.Io.Dir.path.join(gpa, &.{ options.to, entry.path });
        defer gpa.free(landing);

        if (entry.kind == .directory) {
            directory_count += 1;

            assert(directory_count <= directory_count_max);

            try cwd.createDirPath(io, landing);

            continue;
        }

        const body = try entry.dir.readFileAlloc(io, entry.basename, gpa, .limited(body_bytes_max));
        defer gpa.free(body);

        try cwd.writeFile(io, .{ .sub_path = landing, .data = body });
    } else unreachable;
}

fn counted(gpa: std.mem.Allocator, io: std.Io, root: []const u8) !Counts {
    assert(root.len > 0);

    var output = try run(gpa, io, &.{
        "check",
        "--isolated",
        "--no-cache",
        "--exit-zero",
        "--color",
        "never",
        "--format",
        "concise",
        "--select",
        "ALL",
        "--preview",
        root,
    });

    defer output.deinit(gpa);

    try expect_success(&output);
    try expect_lacks(.{ .part = tripped, .text = output.stderr });

    var counts: Counts = .empty;
    errdefer counts_free(gpa, &counts);

    var lines: cli.Lines = .init(output.stdout);

    for (0..line_count_max) |_| {
        const line = lines.next() orelse break;
        const rule = rule_of(line) orelse continue;
        const entry = try counts.getOrPut(gpa, rule);

        if (entry.found_existing) {
            entry.value_ptr.* += 1;

            continue;
        }

        entry.key_ptr.* = try gpa.dupe(u8, rule);
        entry.value_ptr.* = 1;
    } else unreachable;

    return counts;
}

fn rule_of(line: []const u8) ?[]const u8 {
    const split = std.mem.find(u8, line, ": ") orelse return null;
    var words = std.mem.splitScalar(u8, line[split + 2 ..], ' ');

    _ = words.next() orelse return null;

    const rule = words.next() orelse return null;
    if (!std.mem.startsWith(u8, rule, "TS")) return null;

    assert(rule.len >= 2);

    return rule;
}

fn counts_free(gpa: std.mem.Allocator, counts: *Counts) void {
    for (counts.keys()) |key| gpa.free(key);

    counts.deinit(gpa);
    counts.* = undefined;
}

fn fixed_to_fixpoint(gpa: std.mem.Allocator, io: std.Io, root: []const u8) !cli.Output {
    assert(root.len > 0);

    var output = try run(gpa, io, &.{
        "check",
        "--isolated",
        "--no-cache",
        "--exit-zero",
        "--color",
        "never",
        "--format",
        "concise",
        "--select",
        "ALL",
        "--preview",
        "--fix",
        "--unsafe-fixes",
        "--verbose",
        root,
    });

    errdefer output.deinit(gpa);

    try expect_success(&output);
    try expect_lacks(.{ .part = tripped, .text = output.stderr });

    return output;
}

fn expect_no_rise(
    language: []const u8,
    options: struct { after: *const Counts, before: *const Counts },
) !void {
    assert(language.len > 0);
    assert(options.before.count() > 0);

    var risen: u32 = 0;

    for (options.after.keys(), options.after.values()) |rule, count| {
        const was = options.before.get(rule) orelse 0;
        if (count <= was) continue;

        std.debug.print("{s}: {s}: {d} before the fix, {d} after\n", .{
            language,
            rule,
            was,
            count,
        });

        risen += 1;
    }

    try std.testing.expectEqual(@as(u32, 0), risen);
}

test "freeze reports the budget" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var output = try run(gpa, io, &.{ "server", "--verbose" });
    defer output.deinit(gpa);

    try std.testing.expectEqual(@as(?u8, 1), output.code);
    try expect_contains(.{ .part = "limit document_count_max = 64", .text = output.stderr });
    try expect_contains(.{ .part = "limit file_bytes_max = 1048576", .text = output.stderr });
    try expect_contains(.{ .part = frozen, .text = output.stderr });
    try expect_lacks(.{ .part = tripped, .text = output.stderr });
}

test "allocation after freeze trips the guard" {
    try expect_guard(.{
        .case = "allocate",
        .message = "allocation guard tripped: allocation of 64 bytes after freeze",
    });
}

test "deallocation after freeze trips the guard" {
    try expect_guard(.{
        .case = "deallocate",
        .message = "allocation guard tripped: deallocation of 64 bytes after freeze",
    });
}

test "reallocation after freeze trips the guard" {
    try expect_guard(.{
        .case = "reallocate",
        .message = "allocation guard tripped: reallocation of 64 bytes after freeze",
    });
}

test "panic after freeze reports itself" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var output = try run(gpa, io, &.{ "selftest", "panic" });
    defer output.deinit(gpa);

    try expect_failure(&output);
    try expect_contains(.{ .part = "selftest panic after freeze", .text = output.stderr });
    try expect_lacks(.{ .part = tripped, .text = output.stderr });
}

test "usage error exits before freeze" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var output = try run(gpa, io, &.{"nonsense"});
    defer output.deinit(gpa);

    try std.testing.expectEqual(@as(?u8, 2), output.code);
    try expect_contains(.{ .part = "usage:", .text = output.stderr });
    try expect_lacks(.{ .part = frozen, .text = output.stderr });
}

test "a fix cycle over every fixing rule stays clean" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var sandbox: Sandbox = try .init(gpa);
    defer sandbox.deinit(gpa);

    for (fixing_sources) |source| {
        try sandbox.temporary.dir.writeFile(io, .{ .sub_path = source.name, .data = source.body });
    }

    var output = try run(gpa, io, &.{
        "lint",
        "--isolated",
        "--verbose",
        "--preview",
        "--select",
        "ALL",
        "--fix",
        "--unsafe-fixes",
        sandbox.path,
    });

    defer output.deinit(gpa);

    try expect_lacks(.{ .part = tripped, .text = output.stderr });
    try expect_contains(.{ .part = frozen, .text = output.stderr });
    try expect_lacks(.{ .part = "did not converge", .text = output.stderr });
}

test "the tokens mode runs after freeze" {
    try expect_tokens(.{
        .first = "0:2 keyword:function",
        .fixture = "tests/fixtures/matrix/rust/TS001.fire.rs",
        .last = "72:1 block-end",
    });
}

test "the tokens mode serves odin after freeze" {
    try expect_tokens(.{
        .first = "0:7 keyword:other",
        .fixture = "tests/fixtures/matrix/odin/TS001.fire.odin",
        .last = "94:1 newline",
    });
}

test "the tokens mode serves javascript after freeze" {
    try expect_tokens(.{
        .first = "0:8 keyword:function",
        .fixture = "tests/fixtures/matrix/javascript/TS001.fire.js",
        .last = "75:1 block-end",
    });
}

test "the tokens mode serves typescript after freeze" {
    try expect_tokens(.{
        .first = "0:8 keyword:function",
        .fixture = "tests/fixtures/matrix/typescript/TS001.fire.ts",
        .last = "75:1 block-end",
    });
}

test "the guard variable is inert" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    for (guard_values) |value| {
        var command: cli.Command = try .init(gpa, io);
        defer command.deinit(gpa);

        try command.arguments_add(gpa, &.{ "selftest", "allocate" });
        try command.environment_set(.{ .key = "TIGERSTYLE_GUARD", .value = value });

        var output = try command.output(gpa, io);
        defer output.deinit(gpa);

        try expect_failure(&output);
        try expect_contains(.{ .part = tripped, .text = output.stderr });
    }
}

test "every printing mode runs after freeze" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    for (printing_modes) |mode| {
        var output = try run(gpa, io, mode);
        defer output.deinit(gpa);

        try expect_success(&output);
        try expect_contains(.{ .part = frozen, .text = output.stderr });
        try expect_lacks(.{ .part = tripped, .text = output.stderr });
        try std.testing.expect(output.stdout.len > 0);
    }
}

test "the clean mode runs after freeze" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var sandbox: Sandbox = try .init(gpa);
    defer sandbox.deinit(gpa);

    try sandbox.temporary.dir.createDirPath(io, ".tigerstyle_cache/1");

    try sandbox.temporary.dir.writeFile(io, .{
        .sub_path = ".tigerstyle_cache/1/a.bin",
        .data = "x",
    });

    var output = try run(gpa, io, &.{ "clean", "--verbose", sandbox.path });
    defer output.deinit(gpa);

    try expect_success(&output);
    try expect_contains(.{ .part = frozen, .text = output.stderr });
    try expect_lacks(.{ .part = tripped, .text = output.stderr });

    const cache = try sandbox.join(gpa, ".tigerstyle_cache");
    defer gpa.free(cache);

    try std.testing.expect(!cli.is_directory(io, cache));
}

test "the file and settings dumps run after freeze" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    for ([_][]const u8{ "--show-files", "--show-settings" }) |flag| {
        var output = try run(gpa, io, &.{ "lint", flag, "--verbose", "src" });
        defer output.deinit(gpa);

        try expect_success(&output);
        try expect_contains(.{ .part = frozen, .text = output.stderr });
        try expect_lacks(.{ .part = tripped, .text = output.stderr });
        try std.testing.expect(output.stdout.len > 0);
    }
}

test "a path at the cliff lints without allocating" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var sandbox: Sandbox = try .init(gpa);
    defer sandbox.deinit(gpa);

    const named = try deep_workspace(gpa, io, sandbox.path, 383);
    defer gpa.free(named);

    var output = try run(gpa, io, &.{
        "lint",
        "--isolated",
        "--exit-zero",
        "--no-cache",
        "--color",
        "never",
        "--format",
        "concise",
        "--select",
        "ALL",
        "--verbose",
        named,
    });

    defer output.deinit(gpa);

    try expect_success(&output);
    try expect_contains(.{ .part = frozen, .text = output.stderr });
    try expect_lacks(.{ .part = tripped, .text = output.stderr });
    try expect_contains(.{ .part = "TS032", .text = output.stdout });
}

test "a path past the cliff is refused at init" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var sandbox: Sandbox = try .init(gpa);
    defer sandbox.deinit(gpa);

    const named = try deep_workspace(gpa, io, sandbox.path, 384);
    defer gpa.free(named);

    var output = try run(gpa, io, &.{
        "lint",
        "--isolated",
        "--exit-zero",
        "--no-cache",
        "--verbose",
        named,
    });

    defer output.deinit(gpa);

    try expect_lacks(.{ .part = tripped, .text = output.stderr });

    try expect_contains(.{
        .part = "skipping a path longer than 383 bytes",
        .text = output.stderr,
    });

    try std.testing.expectEqual(@as(usize, 0), output.stdout.len);
}

test "the format mode runs after freeze" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const matrix = try cli.rooted(gpa, io, "tests/fixtures/matrix");
    defer gpa.free(matrix);

    var output = try run(gpa, io, &.{ "format", "--check", "--verbose", matrix });
    defer output.deinit(gpa);

    try expect_contains(.{ .part = frozen, .text = output.stderr });
    try expect_lacks(.{ .part = tripped, .text = output.stderr });
    try std.testing.expect(output.stdout.len > 0);
}

test "fixing the matrix tree never raises a rule count" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    for (matrix_languages) |language| {
        var sandbox: Sandbox = try .init(gpa);
        defer sandbox.deinit(gpa);

        const fixture = try gpa.print("tests/fixtures/matrix/{s}", .{language});
        defer gpa.free(fixture);

        const source = try cli.rooted(gpa, io, fixture);
        defer gpa.free(source);

        const root = try sandbox.join(gpa, language);
        defer gpa.free(root);

        try copied(gpa, io, .{ .from = source, .to = root });

        var before = try counted(gpa, io, root);
        defer counts_free(gpa, &before);

        try std.testing.expect(before.count() > 0);

        var fixed = try fixed_to_fixpoint(gpa, io, root);
        defer fixed.deinit(gpa);

        try expect_lacks(.{ .part = "did not converge", .text = fixed.stderr });

        var after = try counted(gpa, io, root);
        defer counts_free(gpa, &after);

        try expect_no_rise(language, .{ .after = &after, .before = &before });
    }
}
