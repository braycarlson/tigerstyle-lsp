const std = @import("std");
const assert = std.debug.assert;
const cli = @import("testing/cli.zig");

const formats = [_][]const u8{
    "azure",
    "concise",
    "full",
    "github",
    "gitlab",
    "grouped",
    "json",
    "json-lines",
    "junit",
    "pylint",
    "rdjson",
    "sarif",
};

const golden_bytes_max = 1 << 24;

fn golden(gpa: std.mem.Allocator, io: std.Io, name: []const u8, actual: []const u8) !void {
    assert(name.len > 0);

    const directory = try cli.rooted(gpa, io, "tests/fixtures/golden");
    defer gpa.free(directory);

    const path = try std.Io.Dir.path.join(gpa, &.{ directory, name });
    defer gpa.free(path);

    const cwd = std.Io.Dir.cwd();

    if (cli.blessing()) {
        try cwd.writeFile(io, .{ .sub_path = path, .data = actual });

        return;
    }

    const expected = try cwd.readFileAlloc(io, path, gpa, .limited(golden_bytes_max));
    defer gpa.free(expected);

    if (!std.mem.eql(u8, actual, expected)) {
        std.debug.print("{s} differs; rerun with TIGERSTYLE_GOLDEN=1\n", .{name});
    }

    try std.testing.expectEqualStrings(expected, actual);
}

fn run(gpa: std.mem.Allocator, io: std.Io, arguments: []const []const u8) !cli.Output {
    assert(arguments.len > 0);

    const fixtures = try cli.rooted(gpa, io, "tests/fixtures/lint");
    defer gpa.free(fixtures);

    var command: cli.Command = try .init(gpa, io);
    defer command.deinit(gpa);

    try command.environment_set("TIGERSTYLE_NO_CACHE", "1");
    try command.arguments_add(gpa, arguments);
    command.directory_set(fixtures);
    command.environment_remove("CLICOLOR_FORCE");
    command.environment_remove("FORCE_COLOR");
    command.environment_remove("NO_COLOR");

    return command.output(gpa, io);
}

fn contains(text: []const u8, part: []const u8) bool {
    assert(part.len > 0);

    return std.mem.find(u8, text, part) != null;
}

test "the human output matches the golden file" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var output = try run(gpa, io, &.{
        "lint",
        "sample.go",
        "sample.py",
        "sample.rs",
        "sample.zig",
    });

    defer output.deinit(gpa);

    try std.testing.expect(!contains(output.stderr, "allocation guard tripped"));
    try std.testing.expectEqual(1, output.code);
    try golden(gpa, io, "human.txt", output.stdout);
}

test "every format matches its golden file" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    for (formats) |format| {
        var output = try run(gpa, io, &.{ "lint", "--format", format, "sample.py" });
        defer output.deinit(gpa);

        const name = try gpa.print("{s}.txt", .{format});
        defer gpa.free(name);

        try std.testing.expectEqual(1, output.code);
        try golden(gpa, io, name, output.stdout);
    }
}

test "the diff output matches the golden file" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var output = try run(gpa, io, &.{
        "lint",
        "--isolated",
        "--extend-select",
        "TS031",
        "--diff",
        "diff.rs",
    });

    defer output.deinit(gpa);

    try std.testing.expect(!contains(output.stderr, "allocation guard tripped"));
    try std.testing.expectEqual(1, output.code);
    try golden(gpa, io, "diff.txt", output.stdout);
}

test "an unknown format is a usage error" {
    const gpa = std.testing.allocator;

    var output = try run(gpa, std.testing.io, &.{ "lint", "--format", "nonsense", "sample.py" });
    defer output.deinit(gpa);

    try std.testing.expectEqual(2, output.code);
}

test "a clean file exits without findings" {
    const gpa = std.testing.allocator;

    var output = try run(gpa, std.testing.io, &.{ "lint", "clean.rs" });
    defer output.deinit(gpa);

    try std.testing.expectEqual(0, output.code);
    try std.testing.expectEqualStrings("", output.stdout);
}

test "a suppressed finding is not reported" {
    const gpa = std.testing.allocator;

    var output = try run(gpa, std.testing.io, &.{ "lint", "suppressed.rs" });
    defer output.deinit(gpa);

    if (output.code != 0) std.debug.print("{s}\n", .{output.stdout});

    try std.testing.expectEqual(0, output.code);
}

test "a directory is walked" {
    const gpa = std.testing.allocator;

    var output = try run(gpa, std.testing.io, &.{ "lint", "." });
    defer output.deinit(gpa);

    try std.testing.expect(contains(output.stdout, "sample.py"));
    try std.testing.expect(contains(output.stdout, "sample.rs"));
    try std.testing.expectEqual(1, output.code);
}

test "a missing path counts as a finding" {
    const gpa = std.testing.allocator;

    var output = try run(gpa, std.testing.io, &.{ "lint", "absent.rs" });
    defer output.deinit(gpa);

    try std.testing.expectEqual(1, output.code);
    try std.testing.expect(contains(output.stderr, "could not be opened"));
}

test "a format without a value is a usage error" {
    const gpa = std.testing.allocator;

    var output = try run(gpa, std.testing.io, &.{ "lint", "--format" });
    defer output.deinit(gpa);

    try std.testing.expectEqual(2, output.code);
}
