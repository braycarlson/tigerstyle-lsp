const std = @import("std");
const assert = std.debug.assert;
const cli = @import("testing/cli.zig");

const Texts = std.ArrayList([]const u8);
const Extension = struct { []const u8, []const u8 };
const Flags = struct { []const u8, []const []const u8 };

const Row = struct {
    code: []const u8,
    states: []const []const u8,
};

const Matrix = struct {
    languages: Texts,
    page: []u8,
    rows: std.ArrayList(Row),

    fn init(gpa: std.mem.Allocator, io: std.Io) !Matrix {
        const page = try printed(gpa, io, &.{ "artifacts", "coverage" });
        errdefer gpa.free(page);

        var matrix: Matrix = .{ .languages = .empty, .page = page, .rows = .empty };
        errdefer matrix.deinit(gpa);

        const table, _ = std.mem.cut(u8, page, "## Gaps") orelse return error.TestUnexpectedResult;

        var lines: cli.Lines = .init(table);

        for (0..table.len + 1) |_| {
            const line = lines.next() orelse break;

            if (std.mem.startsWith(u8, line, "| Rule |")) try matrix.header_read(gpa, line);
            if (std.mem.startsWith(u8, line, "| TS")) try matrix.row_read(gpa, line);
        }

        try std.testing.expect(matrix.languages.items.len > 0);

        return matrix;
    }

    fn deinit(matrix: *Matrix, gpa: std.mem.Allocator) void {
        for (matrix.rows.items) |row| gpa.free(row.states);

        matrix.rows.deinit(gpa);
        cli.lines_free(gpa, &matrix.languages);
        gpa.free(matrix.page);
        matrix.* = undefined;
    }

    fn header_read(matrix: *Matrix, gpa: std.mem.Allocator, line: []const u8) !void {
        assert(std.mem.startsWith(u8, line, "| Rule |"));

        if (matrix.languages.items.len > 0) return;

        var cells = std.mem.splitScalar(u8, line, '|');

        for (0..line.len + 1) |_| {
            const text = std.mem.trim(u8, cells.next() orelse break, " ");
            if (text.len == 0) continue;
            if (std.mem.eql(u8, text, "Rule")) continue;

            try matrix.languages.append(gpa, try std.ascii.allocLowerString(gpa, text));
        }

        assert(matrix.languages.items.len > 0);
    }

    fn row_read(matrix: *Matrix, gpa: std.mem.Allocator, line: []const u8) !void {
        assert(std.mem.startsWith(u8, line, "| TS"));

        var fields: Texts = .empty;
        defer fields.deinit(gpa);

        var cells = std.mem.splitScalar(u8, line, '|');

        for (0..line.len + 1) |_| {
            try fields.append(gpa, std.mem.trim(u8, cells.next() orelse break, " "));
        }

        assert(fields.items.len >= 3);

        const states = try gpa.dupe([]const u8, fields.items[2 .. fields.items.len - 1]);
        errdefer gpa.free(states);

        try matrix.rows.append(gpa, .{ .code = fields.items[1], .states = states });
    }

    fn language_index(matrix: *const Matrix, language: []const u8) ?usize {
        assert(language.len > 0);

        for (matrix.languages.items, 0..) |named, index| {
            if (std.mem.eql(u8, named, language)) return index;
        }

        return null;
    }

    fn row_of(matrix: *const Matrix, code: []const u8) ?Row {
        assert(code.len > 0);

        for (matrix.rows.items) |row| {
            if (std.mem.eql(u8, row.code, code)) return row;
        }

        return null;
    }
};

const extensions = [_]Extension{
    .{ "go", "go" },
    .{ "javascript", "js" },
    .{ "odin", "odin" },
    .{ "python", "py" },
    .{ "rust", "rs" },
    .{ "typescript", "ts" },
    .{ "zig", "zig" },
};

const flags = [_]Flags{
    .{ "TS002", &.{ "--function-lines-max", "8" } },
    .{ "TS003", &.{ "--parameters-max", "3" } },
    .{ "TS008", &.{ "--nesting-depth-max", "2" } },
    .{ "TS012", &.{ "--line-length-max", "40" } },
    .{ "TS039", &.{ "--else-if-chain-max", "2" } },
    .{ "TS043", &.{ "--declaration-distance-max", "3" } },
    .{ "TS050", &.{ "--extend-select", "TS001" } },
};

const entry_count_max = 1 << 12;

fn printed(gpa: std.mem.Allocator, io: std.Io, arguments: []const []const u8) ![]u8 {
    assert(arguments.len > 0);

    var command: cli.Command = try .init(gpa, io);
    defer command.deinit(gpa);

    try command.arguments_add(gpa, arguments);

    const output = try command.output(gpa, io);

    gpa.free(output.stderr);

    return output.stdout;
}

fn codes(gpa: std.mem.Allocator, io: std.Io) !Texts {
    const listing = try printed(gpa, io, &.{"rule"});
    defer gpa.free(listing);

    var listed: Texts = .empty;
    errdefer cli.lines_free(gpa, &listed);

    var lines: cli.Lines = .init(listing);

    for (0..listing.len + 1) |_| {
        const line = lines.next() orelse break;
        const code, _ = std.mem.cutScalar(u8, line, ' ') orelse continue;

        try listed.append(gpa, try gpa.dupe(u8, code));
    }

    return listed;
}

fn extension_of(language: []const u8) []const u8 {
    assert(language.len > 0);

    for (extensions) |extension| {
        if (std.mem.eql(u8, extension[0], language)) return extension[1];
    }

    std.debug.panic("{s} has no fixture extension", .{language});
}

fn flags_of(code: []const u8) []const []const u8 {
    assert(code.len > 0);

    for (flags) |flag| {
        if (std.mem.eql(u8, flag[0], code)) return flag[1];
    }

    return &.{};
}

fn findings(gpa: std.mem.Allocator, io: std.Io, path: []const u8, code: []const u8) !Texts {
    var command: cli.Command = try .init(gpa, io);
    defer command.deinit(gpa);

    try command.arguments_add(gpa, &.{
        "check",
        "--isolated",
        "--no-cache",
        "--exit-zero",
        "--format",
        "concise",
        "--select",
        code,
        "--preview",
    });

    try command.arguments_add(gpa, flags_of(code));

    const directory = std.Io.Dir.path.dirname(path) orelse return error.TestUnexpectedResult;

    command.directory_set(directory);
    try command.argument(gpa, std.Io.Dir.path.basename(path));

    var output = try command.output(gpa, io);
    defer output.deinit(gpa);

    if (!output.success()) std.debug.print("{s} exits non-zero: {s}\n", .{ path, output.stderr });

    try std.testing.expect(output.success());

    var found: Texts = .empty;
    errdefer cli.lines_free(gpa, &found);

    var lines: cli.Lines = .init(output.stdout);

    for (0..output.stdout.len + 1) |_| {
        const line = lines.next() orelse break;

        if (std.mem.find(u8, line, code) != null) try found.append(gpa, try gpa.dupe(u8, line));
    }

    return found;
}

fn fixture(
    gpa: std.mem.Allocator,
    io: std.Io,
    language: []const u8,
    code: []const u8,
    kind: []const u8,
) ![]u8 {
    const name = try gpa.print("tests/fixtures/matrix/{s}/{s}.{s}.{s}", .{
        language,
        code,
        kind,
        extension_of(language),
    });

    defer gpa.free(name);

    return cli.rooted(gpa, io, name);
}

fn cell(
    gpa: std.mem.Allocator,
    io: std.Io,
    language: []const u8,
    code: []const u8,
    wrong: *Texts,
) !void {
    const fire = try fixture(gpa, io, language, code, "fire");
    defer gpa.free(fire);

    const clean = try fixture(gpa, io, language, code, "clean");
    defer gpa.free(clean);

    if (!pair_found(io, fire, clean)) {
        try wrong.append(gpa, try gpa.print("{s} {s} has no fixture pair", .{
            language,
            code,
        }));

        return;
    }

    var reported = try findings(gpa, io, fire, code);
    defer cli.lines_free(gpa, &reported);

    if (reported.items.len != 1) {
        try wrong.append(gpa, try gpa.print("{s} {s} fires {d} times: {f}", .{
            language,
            code,
            reported.items.len,
            cli.listed(reported.items),
        }));
    }

    var quiet = try findings(gpa, io, clean, code);
    defer cli.lines_free(gpa, &quiet);

    if (quiet.items.len > 0) {
        try wrong.append(gpa, try gpa.print("{s} {s} is not clean: {f}", .{
            language,
            code,
            cli.listed(quiet.items),
        }));
    }
}

test "the registry matches the matrix" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var matrix: Matrix = try .init(gpa, io);
    defer matrix.deinit(gpa);

    try std.testing.expectEqual(57, matrix.rows.items.len);
    try std.testing.expectEqual(7, matrix.languages.items.len);

    var listed = try codes(gpa, io);
    defer cli.lines_free(gpa, &listed);

    var rendered: Texts = .empty;
    defer rendered.deinit(gpa);

    for (matrix.rows.items) |row| try rendered.append(gpa, row.code);

    std.mem.sort([]const u8, listed.items, {}, cli.text_less);
    std.mem.sort([]const u8, rendered.items, {}, cli.text_less);

    try std.testing.expectEqual(listed.items.len, rendered.items.len);

    for (rendered.items, listed.items) |code, named| {
        try std.testing.expectEqualStrings(named, code);
    }

    for (matrix.rows.items) |row| {
        try std.testing.expectEqual(matrix.languages.items.len, row.states.len);
    }
}

test "every checked cell carries a fire and a clean fixture" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var matrix: Matrix = try .init(gpa, io);
    defer matrix.deinit(gpa);

    var wrong: Texts = .empty;
    defer cli.lines_free(gpa, &wrong);

    var checked: u32 = 0;

    for (matrix.rows.items) |row| {
        for (matrix.languages.items, 0..) |language, index| {
            if (!std.mem.eql(u8, row.states[index], "Checked.")) continue;

            try cell(gpa, io, language, row.code, &wrong);

            checked += 1;
        }
    }

    if (wrong.items.len > 0) std.debug.print("{d} cells fail:\n", .{wrong.items.len});

    for (wrong.items) |line| std.debug.print("{s}\n", .{line});

    try std.testing.expectEqual(0, wrong.items.len);
    try std.testing.expect(checked > 0);
}

test "every fixture names a checked cell" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var matrix: Matrix = try .init(gpa, io);
    defer matrix.deinit(gpa);

    for (matrix.languages.items) |language| {
        const relative = try gpa.print("tests/fixtures/matrix/{s}", .{language});
        defer gpa.free(relative);

        const path = try cli.rooted(gpa, io, relative);
        defer gpa.free(path);

        var directory = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch continue;
        defer directory.close(io);

        var entries = directory.iterate();

        for (0..entry_count_max) |_| {
            const entry = try entries.next(io) orelse break;

            try fixture_check(&matrix, language, entry.name);
        } else unreachable;
    }
}

fn pair_found(io: std.Io, fire: []const u8, clean: []const u8) bool {
    assert(fire.len > 0);
    assert(clean.len > 0);

    if (!cli.is_file(io, fire)) return false;
    return cli.is_file(io, clean);
}

fn kind_known(kind: []const u8) bool {
    if (std.mem.eql(u8, kind, "fire")) return true;
    return std.mem.eql(u8, kind, "clean");
}

fn fixture_check(matrix: *const Matrix, language: []const u8, name: []const u8) !void {
    const code, const rest = std.mem.cutScalar(u8, name, '.') orelse {
        return error.TestUnexpectedResult;
    };

    const kind, const extension = std.mem.cutScalar(u8, rest, '.') orelse {
        return error.TestUnexpectedResult;
    };

    if (!kind_known(kind)) {
        std.debug.print("{s} is neither a fire nor a clean fixture\n", .{name});

        return error.TestUnexpectedResult;
    }

    try std.testing.expectEqualStrings(extension_of(language), extension);

    const index = matrix.language_index(language) orelse return error.TestUnexpectedResult;

    const row = matrix.row_of(code) orelse {
        std.debug.panic("{s} names an unregistered rule", .{name});
    };

    if (!std.mem.eql(u8, row.states[index], "Checked.")) {
        std.debug.print("{s} names a gap cell\n", .{name});
    }

    try std.testing.expectEqualStrings("Checked.", row.states[index]);
}
