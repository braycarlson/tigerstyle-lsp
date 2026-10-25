const std = @import("std");
const assert = std.debug.assert;
const cli = @import("testing/cli.zig");

const Texts = std.ArrayList([]const u8);

const Sandbox = struct {
    directory: std.testing.TmpDir,
    path: []u8,

    fn of(gpa: std.mem.Allocator, io: std.Io, name: []const u8) !Sandbox {
        assert(name.len > 0);

        var directory = std.testing.tmpDir(.{});
        errdefer directory.cleanup();

        const source = try fixture(gpa, io, name);
        defer gpa.free(source);

        const body = try std.Io.Dir.cwd().readFileAlloc(io, source, gpa, .limited(body_bytes_max));
        defer gpa.free(body);

        const file_name = try gpa.print("{s}.rs", .{name});
        defer gpa.free(file_name);

        try directory.dir.writeFile(io, .{ .sub_path = file_name, .data = body });

        const path = try std.Io.Dir.path.join(gpa, &.{
            std.testing.TmpDir.parent_dir_path,
            &directory.sub_path,
            file_name,
        });

        assert(std.mem.endsWith(u8, path, ".rs"));

        return .{ .directory = directory, .path = path };
    }

    fn deinit(sandbox: *Sandbox, gpa: std.mem.Allocator) void {
        assert(sandbox.path.len > 0);

        gpa.free(sandbox.path);
        sandbox.directory.cleanup();
        sandbox.* = undefined;
    }

    fn read(sandbox: *const Sandbox, gpa: std.mem.Allocator, io: std.Io) ![]u8 {
        assert(sandbox.path.len > 0);

        return std.Io.Dir.cwd().readFileAlloc(io, sandbox.path, gpa, .limited(body_bytes_max));
    }
};

const selected = "TS050,TS001,TS002,TS029,TS037,TS042,TS049";
const unknown_code = "TS050 the directive names a code tigerstyle-lsp does not carry";
const suppresses_nothing = "TS050 the directive suppresses nothing";
const helper_fixed = "fn helper() {\n    let value = 1;\n}\n";
const body_bytes_max = 1 << 20;

fn fixture(gpa: std.mem.Allocator, io: std.Io, name: []const u8) ![]u8 {
    assert(name.len > 0);

    const path = try gpa.print("tests/fixtures/directives/{s}.rs", .{name});
    defer gpa.free(path);

    return cli.rooted(gpa, io, path);
}

fn printed(gpa: std.mem.Allocator, io: std.Io, path: []const u8, fixing: bool) ![]u8 {
    assert(path.len > 0);

    var command: cli.Command = try .init(gpa, io);
    defer command.deinit(gpa);

    try command.arguments_add(gpa, &.{
        "check",
        "--isolated",
        "--no-cache",
        "--exit-zero",
        "--format",
        "concise",
        "--preview",
        "--extend-select",
        selected,
    });

    if (fixing) try command.argument(gpa, "--fix");

    try command.argument(gpa, path);

    var output = try command.output(gpa, io);
    defer gpa.free(output.stderr);
    errdefer gpa.free(output.stdout);

    if (!output.success()) std.debug.print("{s} exits non-zero: {s}\n", .{ path, output.stderr });

    try std.testing.expect(output.success());

    return output.stdout;
}

fn reported(gpa: std.mem.Allocator, io: std.Io, name: []const u8) !Texts {
    const path = try fixture(gpa, io, name);
    defer gpa.free(path);

    const text = try printed(gpa, io, path, false);
    defer gpa.free(text);

    var found: Texts = .empty;
    errdefer cli.lines_free(gpa, &found);

    var lines: cli.Lines = .init(text);

    for (0..text.len + 1) |_| {
        const line = lines.next() orelse break;
        if (std.mem.find(u8, line, "TS050") == null) continue;

        _, const rest = std.mem.cut(u8, line, ": ") orelse return error.TestUnexpectedResult;

        _, const message = std.mem.cutScalar(u8, rest, ' ') orelse {
            return error.TestUnexpectedResult;
        };

        try found.append(gpa, try std.mem.replaceOwned(u8, gpa, message, " [*]", ""));
    }

    return found;
}

fn fixed(gpa: std.mem.Allocator, io: std.Io, name: []const u8) ![]u8 {
    var sandbox: Sandbox = try .of(gpa, io, name);
    defer sandbox.deinit(gpa);

    gpa.free(try printed(gpa, io, sandbox.path, true));

    return sandbox.read(gpa, io);
}

fn windows_endings(gpa: std.mem.Allocator, body: []const u8) ![]u8 {
    var rendered: std.ArrayList(u8) = try .initCapacity(gpa, body.len * 2);
    errdefer rendered.deinit(gpa);

    for (body) |byte| {
        if (byte == '\n') rendered.appendAssumeCapacity('\r');

        rendered.appendAssumeCapacity(byte);
    }

    assert(rendered.items.len >= body.len);
    assert(rendered.items.len <= body.len * 2);

    return rendered.toOwnedSlice(gpa);
}

fn fixed_under_crlf(gpa: std.mem.Allocator, io: std.Io, name: []const u8) ![]u8 {
    var sandbox: Sandbox = try .of(gpa, io, name);
    defer sandbox.deinit(gpa);

    const body = try sandbox.read(gpa, io);
    defer gpa.free(body);

    const rendered = try windows_endings(gpa, body);
    defer gpa.free(rendered);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = sandbox.path, .data = rendered });

    gpa.free(try printed(gpa, io, sandbox.path, true));

    return sandbox.read(gpa, io);
}

fn expect_reported(name: []const u8, expected: []const []const u8) !void {
    const gpa = std.testing.allocator;

    var found = try reported(gpa, std.testing.io, name);
    defer cli.lines_free(gpa, &found);

    try std.testing.expectEqual(expected.len, found.items.len);

    for (expected, found.items) |wanted, line| try std.testing.expectEqualStrings(wanted, line);
}

fn expect_fixed(name: []const u8, expected: []const u8) !void {
    const gpa = std.testing.allocator;
    const text = try fixed(gpa, std.testing.io, name);
    defer gpa.free(text);

    try std.testing.expectEqualStrings(expected, text);
}

test "an unknown code names itself" {
    try expect_reported("unknown", &.{unknown_code});
}

test "an unknown code is removed whole" {
    try expect_fixed("unknown", helper_fixed);
}

test "an orphan enable names the region it closes" {
    try expect_reported("orphan", &.{"TS050 the directive closes no region"});
}

test "an orphan enable is removed whole" {
    try expect_fixed("orphan", helper_fixed);
}

test "a wildcard that suppresses nothing says so" {
    try expect_reported("wildcard", &.{suppresses_nothing});
}

test "a wildcard that suppresses nothing is removed whole" {
    try expect_fixed("wildcard", helper_fixed);
}

test "a wildcard that suppresses nothing is removed whole under crlf" {
    const gpa = std.testing.allocator;
    const text = try fixed_under_crlf(gpa, std.testing.io, "wildcard");
    defer gpa.free(text);

    try std.testing.expectEqualStrings("fn helper() {\r\n    let value = 1;\r\n}\r\n", text);
}

test "a partly dead directive says so" {
    try expect_reported("partial", &.{suppresses_nothing});
}

test "a partly dead directive keeps the codes that still fire" {
    try expect_fixed(
        "partial",
        "fn helper() {\n   // tigerstyle-ignore: TS029\n   let value = 1;\n}\n",
    );
}

test "a trailing directive is removed without its line" {
    try expect_reported("trailing", &.{unknown_code});
    try expect_fixed("trailing", helper_fixed);
}

test "a file directive that suppresses something reports nothing" {
    try expect_reported("file", &.{});

    try expect_fixed(
        "file",
        "// tigerstyle-file-ignore: TS029\nfn helper() {\n   let value = 1;\n}\n",
    );
}

test "a region closed before the finding leaves the disable unused" {
    try expect_reported("reopened", &.{suppresses_nothing});
}

test "a closed region takes both directives when the fix converges" {
    try expect_fixed("reopened", "fn helper() {\n   let value = 1;\n}\n");
}

test "a malformed code of any shape is unknown" {
    try expect_reported("malformed", &.{ unknown_code, unknown_code, unknown_code, unknown_code });
    try expect_fixed("malformed", helper_fixed);
}

test "a directive that lists no code reads as a wildcard" {
    try expect_reported("bare", &.{suppresses_nothing});
    try expect_fixed("bare", helper_fixed);
}

test "a directive that keeps two codes writes them with a separator" {
    try expect_reported("kept", &.{suppresses_nothing});

    try expect_fixed(
        "kept",
        "fn helper() {\n   // tigerstyle-ignore: TS029, TS037\n   let btn = 1;\n}\n",
    );
}

test "a suppressed finding reaches no report path" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    try expect_reported("quiet", &.{});

    const path = try fixture(gpa, io, "quiet");
    defer gpa.free(path);

    const text = try printed(gpa, io, path, false);
    defer gpa.free(text);

    try std.testing.expectEqualStrings("", std.mem.trim(u8, text, &std.ascii.whitespace));
}

test "a directive reaches the item its annotation heads" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const path = try fixture(gpa, io, "annotated");
    defer gpa.free(path);

    const text = try printed(gpa, io, path, false);
    defer gpa.free(text);

    var named: Texts = .empty;
    defer named.deinit(gpa);

    var lines: cli.Lines = .init(text);

    for (0..text.len + 1) |_| {
        const line = lines.next() orelse break;

        if (std.mem.find(u8, line, "TS042") != null) try named.append(gpa, line);
    }

    if (named.items.len != 1) std.debug.print("{s}\n", .{text});

    try std.testing.expectEqual(1, named.items.len);
    try std.testing.expect(std.mem.find(u8, named.items[0], "HTTPState") != null);
    try expect_reported("annotated", &.{});
}

test "every report path carries a fixture" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const path = try cli.rooted(gpa, io, "tests/fixtures/directives");
    defer gpa.free(path);

    var directory = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer directory.close(io);

    var named: Texts = .empty;
    defer cli.lines_free(gpa, &named);

    var entries = directory.iterate();

    for (0..body_bytes_max) |_| {
        const entry = try entries.next(io) orelse break;

        try named.append(gpa, try gpa.dupe(u8, entry.name));
    }

    std.mem.sort([]const u8, named.items, {}, cli.text_less);

    const expected = [_][]const u8{
        "annotated.rs",
        "bare.rs",
        "file.rs",
        "kept.rs",
        "malformed.rs",
        "orphan.rs",
        "partial.rs",
        "quiet.rs",
        "reopened.rs",
        "trailing.rs",
        "unknown.rs",
        "wildcard.rs",
    };

    try std.testing.expectEqual(expected.len, named.items.len);

    for (expected, named.items) |wanted, name| try std.testing.expectEqualStrings(wanted, name);
}
