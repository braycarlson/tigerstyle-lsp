const std = @import("std");
const assert = std.debug.assert;
const cli = @import("testing/cli.zig");

const bless = "TIGERSTYLE_GOLDEN=1 zig build test:unit -Dtest-filter=\"the cli surfaces\"";

const pathed = [_][]const u8{
    "format-check.txt",
    "show-files.txt",
    "show-settings.txt",
    "statistics.txt",
};

const golden_bytes_max = 1 << 24;
const line_count_max = 1 << 20;
const rule_count_max = 1 << 8;

fn goldens(gpa: std.mem.Allocator, io: std.Io) ![]u8 {
    return cli.rooted(gpa, io, "tests/fixtures/golden-cli");
}

fn golden(gpa: std.mem.Allocator, io: std.Io, name: []const u8, actual: []const u8) !void {
    assert(name.len > 0);

    const directory = try goldens(gpa, io);
    defer gpa.free(directory);

    try cli.golden(gpa, io, directory, name, actual, bless);
}

fn run(gpa: std.mem.Allocator, io: std.Io, arguments: []const []const u8) !cli.Output {
    assert(arguments.len > 0);

    const fixtures = try cli.rooted(gpa, io, "tests/fixtures/lint");
    defer gpa.free(fixtures);

    var command = try cli.command(gpa, io);
    defer command.deinit(gpa);

    try command.arguments_add(gpa, arguments);
    command.directory_set(fixtures);

    return command.output(gpa, io);
}

fn printed(gpa: std.mem.Allocator, io: std.Io, arguments: []const []const u8, code: u8) ![]u8 {
    assert(arguments.len > 0);
    assert(code <= 2);

    const output = try run(gpa, io, arguments);
    defer gpa.free(output.stderr);
    errdefer gpa.free(output.stdout);

    try std.testing.expect(std.mem.find(u8, output.stderr, "allocation guard tripped") == null);

    if (output.code != code) {
        std.debug.print("{f} exits differently: {s}\n", .{ cli.listed(arguments), output.stderr });
    }

    try std.testing.expectEqual(@as(?u8, code), output.code);

    return output.stdout;
}

fn captured(
    gpa: std.mem.Allocator,
    io: std.Io,
    name: []const u8,
    arguments: []const []const u8,
    code: u8,
) ![]u8 {
    assert(name.len > 0);

    const text = try printed(gpa, io, arguments, code);
    errdefer gpa.free(text);

    try golden(gpa, io, name, text);

    return text;
}

fn tally(text: []const u8) ![]const u8 {
    var lines: cli.Lines = .init(text);

    for (0..line_count_max) |_| {
        const line = lines.next() orelse break;

        var words = std.mem.tokenizeAny(u8, line, " \t");
        var last: []const u8 = "";

        for (0..line.len + 1) |_| {
            last = words.next() orelse break;
        } else unreachable;

        if (!std.mem.eql(u8, last, "total")) continue;

        const end = text.len - lines.rest.len;

        assert(end > 0);
        assert(text[end - 1] == '\n');

        return text[0..end];
    } else unreachable;

    std.debug.print("the statistics output carries a total line:\n{s}\n", .{text});

    return error.TestExpectedTotal;
}

fn rules_capture(gpa: std.mem.Allocator, io: std.Io) !void {
    const index = try captured(gpa, io, "rule-index.txt", &.{"rule"}, 0);
    defer gpa.free(index);

    var lines: cli.Lines = .init(index);
    var code_count: u32 = 0;

    for (0..rule_count_max) |_| {
        const line = lines.next() orelse break;

        var words = std.mem.tokenizeAny(u8, line, " \t");
        const code = words.next() orelse continue;
        const name = try gpa.print("rule/{s}.txt", .{code});
        defer gpa.free(name);

        const text = try captured(gpa, io, name, &.{ "rule", code }, 0);
        defer gpa.free(text);

        code_count += 1;
    } else unreachable;

    try std.testing.expect(code_count > 0);
}

fn statistics_capture(gpa: std.mem.Allocator, io: std.Io) !void {
    var output = try run(gpa, io, &.{ "check", "--statistics", "." });
    defer output.deinit(gpa);

    try std.testing.expectEqual(@as(?u8, 1), output.code);

    const counted = try tally(output.stdout);

    try std.testing.expect(output.stdout.len > counted.len);
    try golden(gpa, io, "statistics.txt", counted);
}

fn capture(gpa: std.mem.Allocator, io: std.Io) !void {
    const surfaces = [_]struct { []const u8, []const []const u8, u8 }{
        .{ "config.txt", &.{"config"}, 0 },
        .{ "format-check.txt", &.{ "format", "--check", "../matrix" }, 1 },
        .{ "show-settings.txt", &.{ "check", "--show-settings", "." }, 0 },
        .{ "show-files.txt", &.{ "check", "--show-files", "." }, 0 },
    };

    try rules_capture(gpa, io);

    for (surfaces) |surface| {
        const text = try captured(gpa, io, surface[0], surface[1], surface[2]);
        defer gpa.free(text);

        assert(surface[1].len > 0);
    }

    try statistics_capture(gpa, io);
}

test "the cli surfaces match their goldens" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    try capture(gpa, io);

    const directory = try goldens(gpa, io);
    defer gpa.free(directory);

    const listing = try cli.manifest(gpa, io, directory);
    defer gpa.free(listing);

    try golden(gpa, io, "MANIFEST.txt", listing);
}

test "no golden carries an absolute path" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    if (cli.blessing()) return;

    const root = try cli.root(gpa, io);
    defer gpa.free(root);

    const directory = try goldens(gpa, io);
    defer gpa.free(directory);

    for (pathed) |name| {
        const path = try std.Io.Dir.path.join(gpa, &.{ directory, name });
        defer gpa.free(path);

        const text = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(golden_bytes_max));
        defer gpa.free(text);

        if (std.mem.find(u8, text, root) != null) {
            std.debug.print("{s} carries an absolute path\n", .{name});
        }

        try std.testing.expect(std.mem.find(u8, text, root) == null);
    }
}
