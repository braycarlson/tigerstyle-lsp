const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const scan = @import("../../scan.zig");
const support = @import("../support.zig");
const testing = @import("../testing.zig");
const Context = @import("../context.zig");
const Rule = scylla.rule.Rule;
const Sink = scylla.rule.Sink;
const Span = scylla.Span;

pub const rule: Rule = .{
    .citations = &.{
        .{
            .standard = "TigerStyle",
            .text = "\"Hard limit all line lengths, without exception, to at most 100 columns " ++
                "for a good typographic 'measure'. Use it up. Never go beyond. [...] just " ++
                "enough to fit two copies of the code side-by-side on a screen.\"",
        },
    },
    .code = "TS012",
    .default_on = true,
    .description = "A line fits in 100 columns, so two files sit side by side without wrapping.",
    .explanation = "",
    .fix_title = "",
    .fixable = .sometimes,
    .group = .stable,
    .name = "line-too-long",
    .severity = .warning,
    .summary = "A line must fit within `line_length_max`",
    .url = "",
};

const Columns = struct {
    columns: u32,
    over: ?u32,
};

const Word = struct {
    end: u32,
    start: u32,
};

pub fn run(context: *const Context, sink: *Sink) void {
    const allowed = context.settings.thresholds.line_length_max;

    assert(allowed > 0);

    for (0..context.line_count()) |line_index| {
        const line: u32 = @intCast(line_index);
        const span = context.line_span(line);
        const text = context.line_text(line);
        if (fits_bytewise(text, allowed)) continue;

        const measured = columns_of(text, allowed);
        const start = measured.over orelse continue;

        if (exempt(context, text)) continue;

        if (unwrappable_word(text, allowed)) |word| {
            report_unwrappable(sink, span, text, word, measured.columns, allowed);

            continue;
        }

        assert(start < text.len);

        const at: Span = .{ .offset = span.offset + start, .length = @intCast(text.len - start) };

        sink.report_formatted(at, "the line is {d} columns, over the {d} column limit", .{
            measured.columns,
            allowed,
        });
    }
}

fn report_unwrappable(
    sink: *Sink,
    span: Span,
    text: []const u8,
    word: Word,
    columns: u32,
    allowed: u32,
) void {
    assert(word.start < word.end);
    assert(word.end <= text.len);

    const before = scan.trim_ascii(text[0..word.start]);
    const after = scan.trim_ascii(text[word.end..]);
    const at: Span = .{ .offset = span.offset + word.start, .length = word.end - word.start };
    const alone = before.len + after.len == 0;

    if (alone) {
        sink.report_formatted(
            at,
            "the line is {d} columns, over the {d} column limit, and its one token cannot " ++
                "be wrapped",
            .{ columns, allowed },
        );

        return;
    }

    sink.report_formatted(
        at,
        "the line is {d} columns, over the {d} column limit, and its widest token cannot " ++
            "be wrapped; move the token to a line of its own",
        .{ columns, allowed },
    );
}

fn columns_of(text: []const u8, allowed: u32) Columns {
    var columns: u32 = 0;
    var over: ?u32 = null;

    for (text, 0..) |byte, offset| {
        columns = support.column_after(columns, byte);

        if (over == null) {
            if (columns > allowed) over = @intCast(offset);
        }
    }

    if (over) |start| assert(start < text.len);

    return .{ .columns = columns, .over = over };
}

fn fits_bytewise(text: []const u8, allowed: u32) bool {
    assert(allowed > 0);

    if (text.len > allowed) return false;

    assert(text.len <= allowed);

    return std.mem.findScalar(u8, text, '\t') == null;
}

fn exempt(context: *const Context, text: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, text, scan.ascii_whitespace);

    assert(trimmed.len <= text.len);

    for (context.conventions.line_length_exempt_prefixes) |prefix| {
        if (std.mem.startsWith(u8, trimmed, prefix)) return true;
    }

    return false;
}

fn unwrappable_word(text: []const u8, allowed: u32) ?Word {
    const indent = scan.indent_width(text);
    const length: u32 = @intCast(text.len);

    var offset: u32 = 0;

    for (0..length + 1) |_| {
        if (offset >= length) break;

        offset = scan.whitespace_scan(text, offset);

        const start = offset;
        var columns: u32 = 0;

        while (offset < length) : (offset += 1) {
            if (scan.is_ascii_whitespace(text[offset])) break;

            if (text[offset] & 0xc0 != 0x80) columns += 1;
        }

        assert(offset >= start);

        if (offset > start) {
            if (indent + columns > allowed) return .{ .end = offset, .start = start };
        }
    }

    return null;
}

fn filler(gpa: std.mem.Allocator, count: u32, each: u32) ![]u8 {
    var line: std.ArrayList(u8) = .empty;
    errdefer line.deinit(gpa);

    for (0..count) |index| {
        if (index > 0) try line.append(gpa, ' ');

        try line.appendNTimes(gpa, 'b', each);
    }

    return line.toOwnedSlice(gpa);
}

fn long_comment(gpa: std.mem.Allocator, newline: []const u8) ![]u8 {
    var source: std.ArrayList(u8) = .empty;
    errdefer source.deinit(gpa);

    try source.print(gpa, "fn f() {{{s}    let value = 1; // ", .{newline});

    for (0..25) |_| try source.appendSlice(gpa, "word ");

    try source.print(gpa, "{s}}}{s}", .{ newline, newline });

    return source.toOwnedSlice(gpa);
}

test "a long line is reported with its width" {
    const source = try long_comment(std.testing.allocator, "\n");
    defer std.testing.allocator.free(source);

    var findings = try testing.analyze(@This(), .rust, source);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
    try std.testing.expect(std.mem.find(u8, findings.message(0), "147 columns") != null);
}

test "a line at the limit is quiet under crlf" {
    const gpa = std.testing.allocator;

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);

    try body.appendSlice(gpa, "fn f() {\r\n    let value = 1; // ");

    const start = std.mem.findScalar(u8, body.items, '\n').? + 1;

    while (body.items.len - start < 100) try body.append(gpa, 'x');

    try body.appendSlice(gpa, "\r\n}\r\n");
    try testing.expect_quiet(@This(), .rust, body.items);
}

test "a long line under crlf reports the same width as under lf" {
    const gpa = std.testing.allocator;
    const unix = try long_comment(gpa, "\n");
    defer gpa.free(unix);

    const windows = try long_comment(gpa, "\r\n");
    defer gpa.free(windows);

    var unix_findings = try testing.analyze(@This(), .rust, unix);
    defer unix_findings.deinit();

    var windows_findings = try testing.analyze(@This(), .rust, windows);
    defer windows_findings.deinit();

    try std.testing.expectEqual(unix_findings.count(), windows_findings.count());

    for (0..unix_findings.count()) |index| {
        const unix_message = unix_findings.message(@intCast(index));

        try std.testing.expectEqualStrings(unix_message, windows_findings.message(@intCast(index)));
    }
}

test "a short line is quiet" {
    try testing.expect_quiet(@This(), .rust, "fn f() {\n    let value = 1;\n}\n");
}

test "a two byte character is one column" {
    const gpa = std.testing.allocator;

    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(gpa);

    try source.appendSlice(gpa, "fn helper() {\n    // ");

    for (0..30) |_| try source.appendSlice(gpa, "\u{e9}\u{e9}\u{e9}\u{e9} ");

    try source.appendSlice(gpa, ".\n}\n");

    var findings = try testing.analyze(@This(), .rust, source.items);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
    try std.testing.expect(std.mem.find(u8, findings.message(0), "158 columns") != null);
}

test "wrappability counts characters not bytes" {
    const gpa = std.testing.allocator;
    const words = try filler(gpa, 12, 4);
    defer gpa.free(words);

    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(gpa);

    try source.appendSlice(gpa, "fn helper() {\n    // ");

    for (0..60) |_| try source.appendSlice(gpa, "\u{e9}");

    try source.print(gpa, " {s}.\n}}\n", .{words});

    var findings = try testing.analyze(@This(), .rust, source.items);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
}

test "a line with no wrappable word is reported at the word" {
    const gpa = std.testing.allocator;
    const word: [110]u8 = @splat('a');
    const source = try gpa.print("fn helper() {{\n    let x = {s};\n}}\n", .{&word});
    defer gpa.free(source);

    var findings = try testing.analyze(@This(), .rust, source);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
    try std.testing.expect(std.mem.find(u8, findings.message(0), "cannot be wrapped") != null);
    try std.testing.expectEqual(@as(u32, 111), findings.span(0).length);
}

test "a tab counts to the next tab stop" {
    const gpa = std.testing.allocator;

    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(gpa);

    try source.appendSlice(gpa, "package main\n\nfunc f() {\n\t\t");
    try source.appendNTimes(gpa, 'x', 93);
    try source.appendSlice(gpa, "\n}\n");

    var findings = try testing.analyze(@This(), .go, source.items);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
    try std.testing.expect(std.mem.find(u8, findings.message(0), "101 columns") != null);
}

test "a word that reaches the limit exactly is still wrappable" {
    const gpa = std.testing.allocator;
    const word: [96]u8 = @splat('a');
    const source = try gpa.print("fn helper() {{\n    {s} bb;\n}}\n", .{&word});
    defer gpa.free(source);

    var findings = try testing.analyze(@This(), .rust, source);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
}

test "a line of only whitespace is still wrappable" {
    const gpa = std.testing.allocator;
    const blank: [105]u8 = @splat(' ');
    const source = try gpa.print("fn helper() {{\n{s}\n    let a = 1;\n}}\n", .{&blank});
    defer gpa.free(source);

    var findings = try testing.analyze(@This(), .rust, source);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
    try std.testing.expect(std.mem.find(u8, findings.message(0), "105 columns") != null);
}

test "a zig multiline string line is exempt" {
    const gpa = std.testing.allocator;
    const words = try filler(gpa, 25, 4);
    defer gpa.free(words);

    const exempt_source = try gpa.print(
        "fn helper() void {{\n    const a =\n        \\\\{s}\n    ;\n}}\n",
        .{words},
    );

    defer gpa.free(exempt_source);

    try testing.expect_quiet(@This(), .zig, exempt_source);

    const plain = try gpa.print("fn helper() void {{\n    // {s}.\n}}\n", .{words});
    defer gpa.free(plain);

    var findings = try testing.analyze(@This(), .zig, plain);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
}

test "a trailing directive suppresses its own line" {
    const source = "x = 1  # tigerstyle-ignore: TS012\ny = 2\n";

    try testing.expect_quiet(@This(), .python, source);
}
