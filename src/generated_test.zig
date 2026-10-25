const std = @import("std");
const assert = std.debug.assert;
const cli = @import("testing/cli.zig");

const Texts = std.ArrayList([]const u8);
const Named = struct { []const u8, []const u8 };

const Tally = struct {
    cells: u32,
    checked: u32,
    gapped: u32,
    unimplemented: u32,
};

const headings = [_][]const u8{
    "## Reports",
    "## Does not report",
    "## Known false positives",
    "## Citations",
};

const decisions = [_][]const u8{ "Reporting unit:", "Anchor:", "Carve-outs:" };

const language_names = [_]Named{
    .{ "go", "Go" },
    .{ "javascript", "JavaScript" },
    .{ "odin", "Odin" },
    .{ "python", "Python" },
    .{ "rust", "Rust" },
    .{ "typescript", "TypeScript" },
    .{ "zig", "Zig" },
};

const body_bytes_max = 1 << 22;

fn printed_by(gpa: std.mem.Allocator, io: std.Io, arguments: []const []const u8) ![]u8 {
    assert(arguments.len > 0);

    var command: cli.Command = try .init(gpa, io);
    defer command.deinit(gpa);

    try command.arguments_add(gpa, arguments);

    const output = try command.output(gpa, io);

    gpa.free(output.stderr);

    return output.stdout;
}

fn artifact(gpa: std.mem.Allocator, io: std.Io, subject: []const u8) ![]u8 {
    return printed_by(gpa, io, &.{ "artifacts", subject });
}

fn artifact_rule(gpa: std.mem.Allocator, io: std.Io, code: []const u8) ![]u8 {
    return printed_by(gpa, io, &.{ "rule", code });
}

fn generated(gpa: std.mem.Allocator, io: std.Io, path: []const u8, body: []const u8) !void {
    const target = try cli.rooted(gpa, io, path);
    defer gpa.free(target);

    const cwd = std.Io.Dir.cwd();

    if (cli.blessing()) {
        if (std.Io.Dir.path.dirname(target)) |parent| try cwd.createDirPath(io, parent);

        try cwd.writeFile(io, .{ .sub_path = target, .data = body });

        return;
    }

    const expected = try cwd.readFileAlloc(io, target, gpa, .limited(body_bytes_max));
    defer gpa.free(expected);

    if (!std.mem.eql(u8, body, expected)) {
        std.debug.print("{s} differs; rerun with TIGERSTYLE_GOLDEN=1\n", .{path});
    }

    try std.testing.expectEqualStrings(expected, body);
}

fn rules(gpa: std.mem.Allocator, io: std.Io) !std.ArrayList(Named) {
    const listing = try printed_by(gpa, io, &.{"rule"});
    var listed: std.ArrayList(Named) = .empty;
    var lines: cli.Lines = .init(listing);

    for (0..listing.len + 1) |_| {
        const line = lines.next() orelse break;
        const code, const name = std.mem.cutScalar(u8, line, ' ') orelse continue;

        try listed.append(gpa, .{ code, name });
    }

    return listed;
}

fn read_contract(gpa: std.mem.Allocator, io: std.Io, code: []const u8) ![]u8 {
    const relative = try gpa.print("docs/rules/{s}.md", .{code});
    const path = try cli.rooted(gpa, io, relative);

    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(body_bytes_max));
}

test "the schema matches the option table" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const body = try artifact(gpa, io, "schema");
    defer gpa.free(body);

    try generated(gpa, io, "tigerstyle.schema.json", body);
}

test "the settings page matches the option table" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const body = try artifact(gpa, io, "settings");
    defer gpa.free(body);

    try generated(gpa, io, "docs/settings.md", body);
}

test "the coverage page matches the gap table" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const body = try artifact(gpa, io, "coverage");
    defer gpa.free(body);

    try generated(gpa, io, "docs/coverage.md", body);
}

test "the coverage matrix counts every cell" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const gpa = arena.allocator();
    const page = try artifact(gpa, std.testing.io, "coverage");

    const matrix, const gaps = std.mem.cut(u8, page, "## Gaps") orelse {
        return error.TestUnexpectedResult;
    };

    const rows = try matrix_rows(gpa, matrix);
    const languages = try matrix_languages(gpa, matrix);
    const named = try gap_names(gpa, gaps);

    try std.testing.expectEqual(57, rows.len);
    try std.testing.expectEqual(7, languages.len);
    try std.testing.expectEqual(73, named.len);

    const counted = try tallied(gpa, rows, languages, named);

    try std.testing.expectEqual(399, counted.cells);
    try std.testing.expectEqual(73, counted.gapped);
    try std.testing.expectEqual(326, counted.checked);
    try std.testing.expectEqual(0, counted.unimplemented);
    try std.testing.expectEqual(counted.cells, counted.checked + counted.gapped);
}

fn matrix_rows(gpa: std.mem.Allocator, matrix: []const u8) ![]const []const u8 {
    var rows: Texts = .empty;
    var lines: cli.Lines = .init(matrix);

    for (0..matrix.len + 1) |_| {
        const line = lines.next() orelse break;

        if (std.mem.startsWith(u8, line, "| TS")) try rows.append(gpa, line);
    }

    return rows.items;
}

fn matrix_languages(gpa: std.mem.Allocator, matrix: []const u8) ![]const []const u8 {
    var lines: cli.Lines = .init(matrix);

    const header = for (0..matrix.len + 1) |_| {
        const line = lines.next() orelse return error.TestUnexpectedResult;
        if (std.mem.startsWith(u8, line, "| Rule |")) break line;
    } else unreachable;

    var languages: Texts = .empty;
    var cells = std.mem.splitScalar(u8, header, '|');

    for (0..header.len + 1) |_| {
        const cell = std.mem.trim(u8, cells.next() orelse break, &std.ascii.whitespace);
        if (cell.len == 0) continue;
        if (std.mem.eql(u8, cell, "Rule")) continue;

        try languages.append(gpa, try std.ascii.allocLowerString(gpa, cell));
    }

    return languages.items;
}

fn fields_of(gpa: std.mem.Allocator, line: []const u8) ![]const []const u8 {
    var fields: Texts = .empty;
    var cells = std.mem.splitScalar(u8, line, '|');

    for (0..line.len + 1) |_| {
        const cell = cells.next() orelse break;

        try fields.append(gpa, std.mem.trim(u8, cell, &std.ascii.whitespace));
    }

    assert(fields.items.len > 0);

    return fields.items;
}

fn gap_names(gpa: std.mem.Allocator, gaps: []const u8) ![]const Named {
    var named: std.ArrayList(Named) = .empty;
    var lines: cli.Lines = .init(gaps);

    for (0..gaps.len + 1) |_| {
        const line = lines.next() orelse break;
        if (!std.mem.startsWith(u8, line, "| TS")) continue;

        const fields = try fields_of(gpa, line);

        try named.append(gpa, .{ fields[1], fields[2] });
    }

    return named.items;
}

fn tallied(
    gpa: std.mem.Allocator,
    rows: []const []const u8,
    languages: []const []const u8,
    named: []const Named,
) !Tally {
    var counted: Tally = .{ .cells = 0, .checked = 0, .gapped = 0, .unimplemented = 0 };

    for (rows) |row| {
        const fields = try fields_of(gpa, row);
        const code = fields[1];

        for (languages, 0..) |language, index| {
            const state = fields[2 + index];

            const listed_gap = for (named) |gap| {
                if (!std.mem.eql(u8, gap[0], code)) continue;
                if (std.mem.eql(u8, gap[1], language)) break true;
            } else false;

            counted.cells += 1;

            if (!listed_gap) {
                try std.testing.expectEqualStrings("Checked.", state);

                counted.checked += 1;

                continue;
            }

            counted.gapped += 1;

            const unimplemented = std.mem.eql(u8, state, "Unimplemented.");

            try std.testing.expect(std.mem.eql(u8, state, "Inapplicable.") or unimplemented);

            if (unimplemented) counted.unimplemented += 1;
        }
    }

    return counted;
}

test "the rules page table matches the registry" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const path = try cli.rooted(gpa, io, "docs/rules.md");
    defer gpa.free(path);

    const page = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(body_bytes_max));
    defer gpa.free(page);

    const table = try artifact(gpa, io, "rules");
    defer gpa.free(table);

    const head = table[0 .. std.mem.findScalar(u8, table, '\n') orelse table.len];

    try std.testing.expect(head.len > 0);

    const start = std.mem.find(u8, page, head) orelse return error.TestUnexpectedResult;

    const end = if (std.mem.find(u8, page[start..], "\n\n")) |offset|
        start + offset + 1
    else
        page.len;

    try std.testing.expectEqualStrings(table, page[start..end]);
}

test "every rule carries a contract document" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const gpa = arena.allocator();
    const io = std.testing.io;
    const listed = try rules(gpa, io);

    try std.testing.expectEqual(57, listed.items.len);

    for (listed.items) |entry| {
        const code, const name = entry;

        if (cli.blessing()) try contract_template(gpa, io, code, name);

        const body = read_contract(gpa, io, code) catch |err| {
            std.debug.print("{s}.md is present; rerun with TIGERSTYLE_GOLDEN=1\n", .{code});

            return err;
        };

        try contract_check(gpa, io, code, name, body);
    }
}

fn contract_template(gpa: std.mem.Allocator, io: std.Io, code: []const u8, name: []const u8) !void {
    const relative = try gpa.print("docs/rules/{s}.md", .{code});
    const path = try cli.rooted(gpa, io, relative);
    if (cli.is_file(io, path)) return;

    const body = try gpa.print("# {s} {s}\n\n## Reports\n\nTODO\n\n" ++
        "## Does not report\n\nTODO\n\n## Known false positives\n\nTODO\n", .{ code, name });

    try std.Io.Dir.cwd().createDirPath(io, std.Io.Dir.path.dirname(path).?);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = body });
}

fn contract_check(
    gpa: std.mem.Allocator,
    io: std.Io,
    code: []const u8,
    name: []const u8,
    body: []const u8,
) !void {
    const title = try gpa.print("# {s} {s}", .{ code, name });

    try std.testing.expect(std.mem.startsWith(u8, body, title));

    for (headings) |heading| try std.testing.expect(std.mem.find(u8, body, heading) != null);

    _, const tail = std.mem.cut(u8, body, "## Reports") orelse return error.TestUnexpectedResult;

    const reports, _ = std.mem.cut(u8, tail, "## Does not report") orelse {
        return error.TestUnexpectedResult;
    };

    for (decisions) |decision| {
        if (std.mem.find(u8, reports, decision) == null) {
            std.debug.print("{s} does not name {s} under ## Reports\n", .{ code, decision });
        }

        try std.testing.expect(std.mem.find(u8, reports, decision) != null);
    }

    try std.testing.expect(std.mem.find(u8, body, "TODO") == null);

    _, const citations = std.mem.cut(u8, body, "## Citations") orelse {
        return error.TestUnexpectedResult;
    };

    const printed = try artifact_rule(gpa, io, code);

    try std.testing.expectEqual(cites(printed), cites(citations));
}

fn cites(text: []const u8) bool {
    if (std.mem.find(u8, text, "TigerStyle:") != null) return true;
    return std.mem.find(u8, text, "NASA P10 Rule") != null;
}

fn reached(gpa: std.mem.Allocator, printed: []const u8) ![]const []const u8 {
    var lines: cli.Lines = .init(printed);

    const listed = for (0..printed.len + 1) |_| {
        const line = lines.next() orelse return error.TestUnexpectedResult;
        if (std.mem.startsWith(u8, line, "languages: ")) break line["languages: ".len..];
    } else unreachable;

    var names: Texts = .empty;

    for (language_names) |language| {
        var words = std.mem.splitScalar(u8, listed, ' ');

        const found = for (0..listed.len + 1) |_| {
            const word = words.next() orelse break false;
            if (std.mem.eql(u8, word, language[0])) break true;
        } else false;

        if (found) try names.append(gpa, language[1]);
    }

    return names.items;
}

fn claimed(gpa: std.mem.Allocator, body: []const u8, code: []const u8) ![]u8 {
    _, const rest = std.mem.cut(u8, body, "## Does not report") orelse {
        std.debug.panic("{s} has no does-not-report heading", .{code});
    };

    const section = if (std.mem.find(u8, rest, "##")) |end| rest[0..end] else rest;
    const opened = std.mem.trimStart(u8, section, &std.ascii.whitespace);

    const sentence, _ = std.mem.cutScalar(u8, opened, '.') orelse {
        std.debug.panic("{s} opens its does-not-report section with no sentence", .{code});
    };

    var words: Texts = .empty;
    var split = std.mem.tokenizeAny(u8, sentence, &std.ascii.whitespace);

    for (0..sentence.len + 1) |_| try words.append(gpa, split.next() orelse break);

    return std.mem.join(gpa, " ", words.items);
}

test "every contract names the languages its rule reaches" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const gpa = arena.allocator();
    const io = std.testing.io;

    var wrong: Texts = .empty;

    for ((try rules(gpa, io)).items) |entry| {
        const code, _ = entry;
        const reaches = try reached(gpa, try artifact_rule(gpa, io, code));
        const sentence = try claimed(gpa, try read_contract(gpa, io, code), code);

        const expected = if (reaches.len == language_names.len)
            "The rule reaches every language tigerstyle-lsp lints"
        else
            try gpa.print("The rule reaches {s}", .{try listed_text(gpa, reaches)});

        if (std.mem.eql(u8, sentence, expected)) continue;

        try wrong.append(gpa, try gpa.print("  {s}: \"{s}\", expected \"{s}\"", .{
            code,
            sentence,
            expected,
        }));
    }

    if (wrong.items.len > 0) {
        std.debug.print("a contract that names the wrong languages is a contract a reader " ++
            "cannot trust:\n", .{});
    }

    for (wrong.items) |line| std.debug.print("{s}\n", .{line});

    try std.testing.expectEqual(0, wrong.items.len);
}

fn listed_text(gpa: std.mem.Allocator, names: []const []const u8) ![]u8 {
    if (names.len == 0) return gpa.dupe(u8, "no language");
    if (names.len == 1) return gpa.dupe(u8, names[0]);
    if (names.len == 2) return gpa.print("{s} and {s}", .{ names[0], names[1] });

    const rest = try std.mem.join(gpa, ", ", names[0 .. names.len - 1]);
    return gpa.print("{s}, and {s}", .{ rest, names[names.len - 1] });
}

test "the rule page prints its citations" {
    const gpa = std.testing.allocator;
    const printed = try artifact_rule(gpa, std.testing.io, "TS001");
    defer gpa.free(printed);

    const tigerstyle = "TigerStyle: \"Use only very simple, explicit control flow for clarity. " ++
        "Do not use recursion to ensure that all executions that should be bounded are bounded.\"";

    const nasa = "NASA P10 Rule 1: \"Restrict all code to very simple control flow constructs " ++
        "\u{2014} do not use goto statements, setjmp or longjmp constructs, and direct or " ++
        "indirect recursion.\"";

    if (std.mem.find(u8, printed, tigerstyle) == null) std.debug.print("{s}\n", .{printed});

    try std.testing.expect(std.mem.find(u8, printed, tigerstyle) != null);

    if (std.mem.find(u8, printed, nasa) == null) std.debug.print("{s}\n", .{printed});

    try std.testing.expect(std.mem.find(u8, printed, nasa) != null);
}
