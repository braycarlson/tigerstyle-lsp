const std = @import("std");
const assert = std.debug.assert;
const cli = @import("testing/cli.zig");
const Workspace = @import("testing/workspace.zig");

const cache_bytes_max = 1 << 22;
const clean_body = "fn helper() {\n    let value = 1;\n}\n";
const dirty_body = "fn helper() {\n    let maxVal= 1;\n}\n";
const signature = "Signature: 8a477f597d28d172789f06886806bc55";

comptime {
    assert(clean_body.len == dirty_body.len);
}

fn workspace_new(gpa: std.mem.Allocator, io: std.Io, name: []const u8) !Workspace {
    assert(name.len > 0);

    var workspace: Workspace = try .init(gpa, io, "cache", name);
    errdefer workspace.deinit();

    _ = try workspace.write("tigerstyle.toml", "extend_select = [\"TS032\"]\n");
    _ = try workspace.write("a.rs", clean_body);

    return workspace;
}

fn command_bare(gpa: std.mem.Allocator, io: std.Io, workspace: *const Workspace) !cli.Command {
    var command: cli.Command = try .init(gpa, io);
    errdefer command.deinit(gpa);

    try command.arguments_add(gpa, &.{ "lint", "--format", "concise", workspace.root });

    assert(command.arguments.items.len == 5);

    return command;
}

fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    workspace: *const Workspace,
    arguments: []const []const u8,
) !cli.Output {
    var command: cli.Command = try .init(gpa, io);
    defer command.deinit(gpa);

    try command.arguments_add(gpa, &.{ "lint", "--format", "concise" });
    try command.arguments_add(gpa, arguments);
    try command.argument(gpa, workspace.root);
    command.environment_remove("FORCE_COLOR");
    command.environment_remove("NO_COLOR");
    command.environment_remove("TIGERSTYLE_CACHE_DIR");
    command.environment_remove("TIGERSTYLE_NO_CACHE");

    return command.output(gpa, io);
}

fn run_discarded(
    gpa: std.mem.Allocator,
    io: std.Io,
    workspace: *const Workspace,
    arguments: []const []const u8,
) !void {
    var output = try run(gpa, io, workspace, arguments);
    defer output.deinit(gpa);

    assert(output.stdout.len <= std.math.maxInt(u32));
}

fn shadow(io: std.Io, workspace: *Workspace, name: []const u8, body: []const u8) !void {
    const path = try workspace.path(name);
    const cwd = std.Io.Dir.cwd();
    const stamp = try cwd.statFile(io, path, .{});

    try cwd.writeFile(io, .{ .sub_path = path, .data = body });

    const file = try cwd.openFile(io, path, .{ .mode = .write_only });
    defer file.close(io);

    try file.setTimestamps(io, .{
        .access_timestamp = .unchanged,
        .modify_timestamp = .{ .new = stamp.mtime },
    });
}

fn contains(text: []const u8, part: []const u8) bool {
    assert(part.len > 0);

    return std.mem.find(u8, text, part) != null;
}

test "a clean file is recorded and skipped" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace = try workspace_new(gpa, io, "skip");
    defer workspace.deinit();

    try run_discarded(gpa, io, &workspace, &.{});
    try shadow(io, &workspace, "a.rs", dirty_body);

    var cached = try run(gpa, io, &workspace, &.{});
    defer cached.deinit(gpa);

    try std.testing.expectEqualStrings("", cached.stdout);

    var uncached = try run(gpa, io, &workspace, &.{"--no-cache"});
    defer uncached.deinit(gpa);

    try std.testing.expect(contains(uncached.stdout, "TS032"));
}

test "the cache root carries a directory tag" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace = try workspace_new(gpa, io, "tag");
    defer workspace.deinit();

    try run_discarded(gpa, io, &workspace, &.{});

    const tag = try workspace.read(".tigerstyle_cache/CACHEDIR.TAG");

    if (!std.mem.startsWith(u8, tag, signature)) std.debug.print("{s}\n", .{tag});

    try std.testing.expect(std.mem.startsWith(u8, tag, signature));
    try std.testing.expect(try workspace.exists(".tigerstyle_cache/1/clean.bin"));
}

test "a settings change discards the cache" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace = try workspace_new(gpa, io, "settings");
    defer workspace.deinit();

    try run_discarded(gpa, io, &workspace, &.{});
    try shadow(io, &workspace, "a.rs", dirty_body);

    var output = try run(gpa, io, &workspace, &.{ "--line-length-max", "88" });
    defer output.deinit(gpa);

    if (!contains(output.stdout, "TS032")) std.debug.print("{s}\n", .{output.stdout});

    try std.testing.expect(contains(output.stdout, "TS032"));
}

test "a corrupt cache is deleted and treated as empty" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace = try workspace_new(gpa, io, "corrupt");
    defer workspace.deinit();

    try run_discarded(gpa, io, &workspace, &.{});
    _ = try workspace.write(".tigerstyle_cache/1/clean.bin", "not a cache at all");

    try shadow(io, &workspace, "a.rs", dirty_body);

    var output = try run(gpa, io, &workspace, &.{});
    defer output.deinit(gpa);

    if (!contains(output.stdout, "TS032")) std.debug.print("{s}\n", .{output.stdout});

    try std.testing.expect(contains(output.stdout, "TS032"));
    try std.testing.expect(try workspace.exists(".tigerstyle_cache/1/clean.bin"));
}

test "every truncation of the cache is refused" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace = try workspace_new(gpa, io, "truncated");
    defer workspace.deinit();

    _ = try workspace.write("b.rs", dirty_body);

    var expected = try run(gpa, io, &workspace, &.{"--no-cache"});
    defer expected.deinit(gpa);

    if (!contains(expected.stdout, "TS032")) std.debug.print("{s}\n", .{expected.stdout});

    try std.testing.expect(contains(expected.stdout, "TS032"));
    try run_discarded(gpa, io, &workspace, &.{});

    const whole = try workspace.read(".tigerstyle_cache/1/clean.bin");

    if (whole.len <= 8) std.debug.print("the cache is {d} bytes\n", .{whole.len});

    try std.testing.expect(whole.len > 8);

    const lengths = [_]usize{ 0, 1, 4, 7, whole.len / 3, whole.len / 2, whole.len - 1 };

    for (lengths) |length| {
        try truncation_check(gpa, io, &workspace, whole[0..length], expected.stdout);
    }
}

fn truncation_check(
    gpa: std.mem.Allocator,
    io: std.Io,
    workspace: *Workspace,
    truncated: []const u8,
    expected: []const u8,
) !void {
    _ = try workspace.write(".tigerstyle_cache/1/clean.bin", truncated);

    var output = try run(gpa, io, workspace, &.{});
    defer output.deinit(gpa);

    const broken = contains(output.stderr, "panicked");
    const tripped = contains(output.stderr, "allocation guard tripped");

    if (!std.mem.eql(u8, output.stdout, expected)) {
        std.debug.print("a cache truncated to {d} bytes changed the report\n", .{truncated.len});
    }

    if (broken) {
        std.debug.print("a cache truncated to {d} bytes broke the run: {s}\n", .{
            truncated.len,
            output.stderr,
        });
    }

    if (tripped) {
        std.debug.print("a cache truncated to {d} bytes broke the run: {s}\n", .{
            truncated.len,
            output.stderr,
        });
    }

    if (output.code != 1) {
        std.debug.print("a cache truncated to {d} bytes exited oddly: {s}\n", .{
            truncated.len,
            output.stderr,
        });
    }

    try std.testing.expectEqualStrings(expected, output.stdout);
    try std.testing.expect(!broken);
    try std.testing.expect(!tripped);
    try std.testing.expectEqual(@as(?u8, 1), output.code);
    try std.testing.expect(try workspace.exists(".tigerstyle_cache/1/clean.bin"));
}

test "the cache directory relocates" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace = try workspace_new(gpa, io, "relocate");
    defer workspace.deinit();

    try run_discarded(gpa, io, &workspace, &.{ "--cache-dir", "elsewhere" });

    try std.testing.expect(try workspace.exists("elsewhere/1/clean.bin"));
    try std.testing.expect(!try workspace.exists(".tigerstyle_cache"));
}

test "an empty cache directory is the default" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace = try workspace_new(gpa, io, "empty");
    defer workspace.deinit();

    try run_discarded(gpa, io, &workspace, &.{ "--cache-dir", "" });

    try std.testing.expect(try workspace.exists(".tigerstyle_cache/1/clean.bin"));
}

test "an empty environment cache directory is the default" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace = try workspace_new(gpa, io, "empty-environment");
    defer workspace.deinit();

    var command = try command_bare(gpa, io, &workspace);
    defer command.deinit(gpa);

    try command.environment_set("TIGERSTYLE_CACHE_DIR", "");
    command.environment_remove("TIGERSTYLE_NO_CACHE");

    var output = try command.output(gpa, io);
    defer output.deinit(gpa);

    try std.testing.expect(try workspace.exists(".tigerstyle_cache/1/clean.bin"));
}

test "the environment relocates the cache" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace = try workspace_new(gpa, io, "environment");
    defer workspace.deinit();

    var command = try command_bare(gpa, io, &workspace);
    defer command.deinit(gpa);

    try command.environment_set("TIGERSTYLE_CACHE_DIR", "from-the-environment");

    var output = try command.output(gpa, io);
    defer output.deinit(gpa);

    try std.testing.expect(try workspace.exists("from-the-environment/1/clean.bin"));
}

test "the environment turns the cache off" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace = try workspace_new(gpa, io, "off");
    defer workspace.deinit();

    var command = try command_bare(gpa, io, &workspace);
    defer command.deinit(gpa);

    try command.environment_set("TIGERSTYLE_NO_CACHE", "1");

    var output = try command.output(gpa, io);
    defer output.deinit(gpa);

    try std.testing.expect(!try workspace.exists(".tigerstyle_cache"));
}

test "a fixing run writes no cache" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace = try workspace_new(gpa, io, "fixing");
    defer workspace.deinit();

    try run_discarded(gpa, io, &workspace, &.{"--fix"});

    try std.testing.expect(!try workspace.exists(".tigerstyle_cache"));
}

test "a diff run writes no cache" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace = try workspace_new(gpa, io, "diffing");
    defer workspace.deinit();

    try run_discarded(gpa, io, &workspace, &.{"--diff"});

    try std.testing.expect(!try workspace.exists(".tigerstyle_cache"));
}

test "the clean command removes the directory" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace = try workspace_new(gpa, io, "clean");
    defer workspace.deinit();

    try run_discarded(gpa, io, &workspace, &.{});

    try std.testing.expect(try workspace.exists(".tigerstyle_cache"));

    var command: cli.Command = try .init(gpa, io);
    defer command.deinit(gpa);

    try command.arguments_add(gpa, &.{ "clean", workspace.root });

    var output = try command.output(gpa, io);
    defer output.deinit(gpa);

    if (!contains(output.stdout, "removed 1")) {
        std.debug.print("{s}{s}\n", .{ output.stdout, output.stderr });
    }

    try std.testing.expect(contains(output.stdout, "removed 1"));
    try std.testing.expect(!try workspace.exists(".tigerstyle_cache"));
}

test "a cached run holds the frozen heap" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace = try workspace_new(gpa, io, "frozen");
    defer workspace.deinit();

    try run_discarded(gpa, io, &workspace, &.{});

    var output = try run(gpa, io, &workspace, &.{"--verbose"});
    defer output.deinit(gpa);

    const tripped = contains(output.stderr, "allocation guard tripped");
    const frozen = contains(output.stderr, "frozen: ");

    if (tripped) std.debug.print("{s}\n", .{output.stderr});
    if (!frozen) std.debug.print("{s}\n", .{output.stderr});

    try std.testing.expect(!tripped);
    try std.testing.expect(frozen);
}

test "a stdin run writes no cache" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var workspace = try workspace_new(gpa, io, "stdin");
    defer workspace.deinit();

    var command: cli.Command = try .init(gpa, io);
    defer command.deinit(gpa);

    try command.arguments_add(gpa, &.{ "lint", "--language", "rust", "-" });
    command.directory_set(workspace.root);

    var output = try command.output(gpa, io);
    defer output.deinit(gpa);

    try std.testing.expect(!try workspace.exists(".tigerstyle_cache"));
}
