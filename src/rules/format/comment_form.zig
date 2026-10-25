const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const scan = @import("../../scan.zig");
const testing = @import("../testing.zig");
const Context = @import("../context.zig");
const Rule = scylla.rule.Rule;
const Sink = scylla.rule.Sink;
const Span = scylla.Span;
const Token = scylla.Token;
const ascii_whitespace = scan.ascii_whitespace;

pub const rule: Rule = .{
    .citations = &.{
        .{
            .standard = "TigerStyle",
            .text = "\"Comments are sentences, with a space after the slash, with a capital " ++
                "letter and a full stop, or a colon if they relate to something that follows. " ++
                "Comments are well-written prose describing the code, not just scribblings in " ++
                "the margin. Comments after the end of a line _can_ be phrases, with no " ++
                "punctuation.\"",
        },
    },
    .code = "TS031",
    .default_on = false,
    .description = "A comment is written as prose: it opens with a capital letter and closes " ++
        "with a full stop.",
    .explanation = "",
    .fix_title = "",
    .fixable = .sometimes,
    .group = .stable,
    .name = "comment-form",
    .severity = .information,
    .summary = "Write comments as sentences",
    .url = "",
};

const CommentLine = struct {
    body: Span,
    carries: bool,
    checkable: bool,
    column: u32,
    line: u32,
    listed: bool,
    marker: u32,
    shared: bool,
    start: u32,
    trailing: bool,
};

const Place = struct {
    closes: bool,
    opens: bool,
};

const closers = "}])";
const code_indent_min: u32 = 4;
const code_span_mark = '`';
const code_link_close = "`]";
const code_terminators = ";{}()[]=";

const directives = @import("../directives.zig").words;

const fence = "```";
const heading_level_max: u32 = 6;
const heading_marks = "#";
const ellipsis_close = "..)";
const link_label_close = "]:";
const link_label_open = '[';
const link_target_open = "](";
const list_continuation_indent_min: u32 = 2;
const list_item_prefixes = [_][]const u8{ "- ", "* ", "+ ", "> ", "| ", "# " };
const parenthetical_close = ')';
const parenthetical_open = '(';
const sentence_ends = ".!?";
const terminators = ".:!?";
const url_scheme_mark = "://";

pub fn run(context: *const Context, sink: *Sink) void {
    var fenced = false;
    var opens = true;
    var pending: ?CommentLine = null;

    for (context.tokens) |token| {
        if (token.kind != .comment) continue;

        var current = comment_line_of(context, token) orelse continue;

        if (current.trailing) {
            comment_space_check(context, sink, &current);

            continue;
        }

        const fence_line = fences(context, &current);

        if (fence_line) fenced = !fenced;

        current.checkable = current.checkable and !fence_line and !fenced;
        current.carries = current.carries and !fence_line and !fenced;

        const previous = pending orelse {
            opens = true;
            pending = current;

            continue;
        };

        assert(previous.line < current.line);

        const continued = continues_a_list_item(context, &previous, &current);

        if (continued) current.listed = true;

        const joined = continues(&previous, &current) and current.carries;

        comment_check(context, sink, &previous, .{ .closes = !joined, .opens = opens });

        opens = !joined or !previous.carries or ends_a_sentence(context, &previous);

        if (continued) opens = previous.checkable and ends_a_sentence(context, &previous);

        pending = current;
    }

    if (pending) |previous| {
        assert(!previous.trailing);

        comment_check(context, sink, &previous, .{ .closes = true, .opens = opens });
    }
}

fn comment_line_of(context: *const Context, token: Token) ?CommentLine {
    assert(token.kind == .comment);

    const line = context.line_of(token.offset);
    const last = token.offset + @max(token.length, 1) - 1;
    if (context.line_of(last) != line) return null;

    const span = context.line_span(line);

    assert(span.offset <= token.offset);

    const before = context.source[span.offset..token.offset];
    const after = context.source[@min(token.end(), span.end())..span.end()];
    const trailing = std.mem.findNone(u8, before, ascii_whitespace) != null;
    const shared = std.mem.findNone(u8, after, ascii_whitespace) != null;
    const trimmed = std.mem.trimEnd(u8, context.text(token), ascii_whitespace);
    const column = token.offset - span.offset;

    if (block_body(context, trimmed)) |body| {
        const marker: u32 = @intCast(context.grammar.comment_block_open.len);

        return .{
            .body = .{ .offset = token.offset + marker, .length = @intCast(body.len) },
            .carries = is_prose(context, body, true),
            .checkable = is_prose(context, body, false),
            .column = column,
            .line = line,
            .listed = opens_a_list_item(body),
            .marker = marker,
            .shared = shared,
            .start = token.offset,
            .trailing = trailing,
        };
    }

    const prefix = context.grammar.comment_prefix;
    if (!std.mem.startsWith(u8, trimmed, prefix)) return null;

    const body = doc_body(context, trimmed[prefix.len..]) orelse return null;
    const marker: u32 = @intCast(trimmed.len - body.len);

    assert(marker >= prefix.len);

    return .{
        .body = .{ .offset = token.offset + marker, .length = @intCast(body.len) },
        .carries = is_prose(context, body, true),
        .checkable = is_prose(context, body, false),
        .column = column,
        .line = line,
        .listed = opens_a_list_item(body),
        .marker = marker,
        .shared = shared,
        .start = token.offset,
        .trailing = trailing,
    };
}

fn opens_a_list_item(body: []const u8) bool {
    const stripped = std.mem.trimStart(u8, body, ascii_whitespace);

    assert(stripped.len <= body.len);

    if (stripped.len == 0) return false;
    return starts_with_any(stripped, &list_item_prefixes);
}

fn continues_a_list_item(
    context: *const Context,
    previous: *const CommentLine,
    current: *const CommentLine,
) bool {
    assert(previous.line < current.line);

    if (!previous.listed) return false;
    if (!continues(previous, current)) return false;

    const body = context.span_text(current.body);
    const indent = body.len - std.mem.trimStart(u8, body, " ").len;

    assert(indent <= body.len);

    return indent >= list_continuation_indent_min;
}

fn block_body(context: *const Context, trimmed: []const u8) ?[]const u8 {
    const open = context.grammar.comment_block_open;
    const close = context.grammar.comment_block_close;

    assert((open.len == 0) == (close.len == 0));

    if (open.len == 0) return null;
    if (!std.mem.startsWith(u8, trimmed, open)) return null;

    const rest = trimmed[open.len..];
    if (!std.mem.endsWith(u8, rest, close)) return null;

    const body = std.mem.trimEnd(u8, rest[0 .. rest.len - close.len], ascii_whitespace);

    assert(body.len + open.len + close.len <= trimmed.len);

    if (body.len == 0) return body;
    if (body[0] == '*') return null;
    if (body[0] == '!') return null;
    return body;
}

fn doc_body(context: *const Context, after_prefix: []const u8) ?[]const u8 {
    const conventions = context.conventions;

    if (conventions.comment_docs_read) assert(conventions.comment_doc_markers.len > 0);

    for (conventions.comment_doc_markers) |marker| {
        if (!std.mem.startsWith(u8, after_prefix, marker)) continue;

        const rest = after_prefix[marker.len..];
        if (std.mem.startsWith(u8, rest, marker)) return after_prefix;
        if (!conventions.comment_docs_read) return null;

        assert(rest.len < after_prefix.len);

        return rest;
    }

    return after_prefix;
}

fn is_prose(context: *const Context, body: []const u8, lenient: bool) bool {
    const stripped = std.mem.trimStart(u8, body, ascii_whitespace);

    assert(stripped.len <= body.len);

    if (stripped.len == 0) return false;
    if (body.len - stripped.len >= code_indent_min) return false;
    if (starts_with_any(stripped, context.conventions.comment_directives)) return false;
    if (starts_with_any(stripped, context.conventions.suppression_markers)) return false;

    if (scan.find(stripped, url_scheme_mark) != null) {
        if (!lenient) return false;
        if (carries_a_bare_url(stripped)) return false;
    }

    for (directives) |marker| {
        if (scan.find(stripped, marker) != null) return false;
    }

    if (starts_with_any(stripped, &list_item_prefixes)) return false;
    if (opens_a_heading(stripped)) return false;
    if (std.mem.startsWith(u8, stripped, "..")) return false;
    if (std.mem.startsWith(u8, stripped, fence)) return false;

    if (is_a_marker(stripped)) {
        if (!lenient) return false;
        if (!closes_with_a_link(stripped)) return false;
    }

    if (defines_a_link(stripped)) return false;

    const last = closing_byte(stripped);

    assert(!scan.is_ascii_whitespace(last));

    if (std.mem.findScalar(u8, code_terminators, last) == null) return true;
    if (!lenient) return false;
    if (opens_a_code_span(stripped)) return true;
    if (std.mem.endsWith(u8, stripped, code_link_close)) return true;
    return closes_a_remark(stripped);
}

fn carries_a_bare_url(stripped: []const u8) bool {
    var rest = stripped;

    for (0..stripped.len) |_| {
        const at = scan.find(rest, url_scheme_mark) orelse return false;
        const target = std.mem.findLast(u8, rest[0..at], link_target_open) orelse return true;
        const between = rest[target + link_target_open.len .. at];

        assert(target < at);

        if (std.mem.findAny(u8, between, ") ") != null) return true;

        rest = rest[at + url_scheme_mark.len ..];
    }

    return false;
}

fn opens_a_code_span(stripped: []const u8) bool {
    assert(stripped.len > 0);

    return std.mem.countScalar(u8, stripped, code_span_mark) % 2 == 1;
}

fn closes_a_remark(stripped: []const u8) bool {
    assert(stripped.len > 0);

    if (stripped[stripped.len - 1] != parenthetical_close) return false;

    var depth: u32 = 0;
    var cursor = stripped.len;

    for (0..stripped.len) |_| {
        cursor -= 1;

        if (stripped[cursor] == parenthetical_close) depth += 1;
        if (stripped[cursor] != parenthetical_open) continue;

        depth -= 1;

        if (depth == 0) break;
    }

    if (depth != 0) return false;
    if (cursor == 0) return false;
    if (stripped[cursor - 1] == link_label_close[0]) return true;
    return scan.is_ascii_whitespace(stripped[cursor - 1]);
}

fn opens_a_heading(stripped: []const u8) bool {
    assert(stripped.len > 0);

    const level = std.mem.findNone(u8, stripped, heading_marks) orelse return false;
    if (level == 0) return false;
    if (level > heading_level_max) return false;
    return stripped[level] == ' ';
}

fn defines_a_link(stripped: []const u8) bool {
    assert(stripped.len > 0);

    if (stripped[0] != link_label_open) return false;

    const close = std.mem.findScalar(u8, stripped, link_label_close[0]) orelse return false;

    assert(close > 0);

    return std.mem.startsWith(u8, stripped[close..], link_label_close);
}

fn closing_byte(text: []const u8) u8 {
    assert(text.len > 0);

    const last = text[text.len - 1];
    if (last != parenthetical_close) return last;
    if (text.len < 2) return last;

    const before = text[text.len - 2];
    if (std.mem.findScalar(u8, sentence_ends, before) == null) return last;
    if (std.mem.endsWith(u8, text, ellipsis_close)) return last;
    return before;
}

fn starts_with_any(text: []const u8, prefixes: []const []const u8) bool {
    assert(text.len > 0);

    for (prefixes) |prefix| {
        assert(prefix.len > 0);

        if (std.mem.startsWith(u8, text, prefix)) return true;
    }

    return false;
}

fn is_a_marker(stripped: []const u8) bool {
    assert(stripped.len > 0);
    assert(!scan.is_ascii_whitespace(stripped[0]));

    if (std.mem.findAny(u8, stripped, ascii_whitespace) != null) return false;
    return std.mem.findAny(u8, stripped, ":/_-") != null;
}

fn closes_with_a_link(stripped: []const u8) bool {
    assert(stripped.len > 0);

    if (stripped[0] == link_label_open) return true;
    return std.mem.findScalar(u8, sentence_ends, stripped[stripped.len - 1]) != null;
}

fn fences(context: *const Context, comment: *const CommentLine) bool {
    assert(!comment.trailing);

    const body = std.mem.trimStart(u8, context.span_text(comment.body), ascii_whitespace);

    assert(body.len <= comment.body.length);

    return std.mem.startsWith(u8, body, fence);
}

fn continues(earlier: *const CommentLine, later: *const CommentLine) bool {
    assert(earlier.line < later.line);
    assert(!later.trailing);

    if (earlier.line + 1 != later.line) return false;
    return earlier.column == later.column;
}

fn ends_a_sentence(context: *const Context, comment: *const CommentLine) bool {
    assert(!comment.trailing);

    const body = std.mem.trimEnd(u8, context.span_text(comment.body), ascii_whitespace);

    assert(body.len <= comment.body.length);

    if (body.len == 0) return false;
    return std.mem.findScalar(u8, sentence_ends, closing_byte(body)) != null;
}

fn comment_check(
    context: *const Context,
    sink: *Sink,
    comment: *const CommentLine,
    place: Place,
) void {
    if (!comment.checkable) return;

    const body = context.span_text(comment.body);
    const stripped = std.mem.trimStart(u8, body, ascii_whitespace);
    const ends = comment.start + comment.marker + comment.body.length;

    assert(stripped.len > 0);
    assert(ends == comment.body.end());

    comment_space(sink, comment, body);

    if (comment.shared) return;

    const first = for (stripped) |byte| {
        if (std.ascii.isAlphabetic(byte)) break byte;
    } else return;

    assert(std.ascii.isAlphabetic(first));

    if (place.opens) {
        if (std.ascii.isLower(stripped[0])) comment_capital(sink, comment, stripped);
    }

    if (!place.closes) return;

    const last = closing_byte(stripped);

    if (std.mem.findScalar(u8, terminators, last) == null) comment_stop(sink, comment, ends);
    if (last != ':') return;
    if (followed(context, comment)) return;

    sink.report(
        .{ .offset = ends - 1, .length = 1 },
        "the comment ends with a colon, but nothing follows it",
    );
}

fn comment_space_check(context: *const Context, sink: *Sink, comment: *const CommentLine) void {
    assert(comment.trailing);
    assert(comment.body.offset == comment.start + comment.marker);

    if (!comment.checkable) return;

    comment_space(sink, comment, context.span_text(comment.body));
}

fn followed(context: *const Context, comment: *const CommentLine) bool {
    assert(comment.line < context.line_count());

    const next = comment.line + 1;
    if (next >= context.line_count()) return false;

    const text = context.line_text(next);
    const trimmed = scan.trim_ascii(text);

    assert(trimmed.len <= text.len);

    if (trimmed.len == 0) return false;
    if (std.mem.findScalar(u8, closers, trimmed[0]) != null) return false;

    const indent = scan.indent_width(context.line_text(comment.line));
    return scan.indent_width(text) >= indent;
}

fn comment_space(sink: *Sink, comment: *const CommentLine, body: []const u8) void {
    assert(body.len > 0);
    assert(body.len == comment.body.length);

    if (body[0] == ' ') return;

    const at: Span = .{ .offset = comment.start + comment.marker, .length = 0 };

    assert(at.offset == comment.body.offset);

    sink.fix_begin("Insert a space", .safe, comment.line);
    sink.fix_edit(at, " ");
    sink.report_fixed(at, "the comment has no space after its marker");
}

fn comment_capital(sink: *Sink, comment: *const CommentLine, stripped: []const u8) void {
    assert(stripped.len <= comment.body.length);
    assert(std.ascii.isLower(stripped[0]));

    const offset = comment.body.end() - @as(u32, @intCast(stripped.len));
    const at: Span = .{ .offset = offset, .length = 1 };
    const upper = [1]u8{std.ascii.toUpper(stripped[0])};

    sink.fix_begin("Capitalize the first word", .safe, comment.line);
    sink.fix_edit(at, &upper);
    sink.report_fixed(at, "the comment opens in lower case");
}

fn comment_stop(sink: *Sink, comment: *const CommentLine, offset: u32) void {
    assert(offset == comment.body.end());
    assert(comment.checkable);

    const at: Span = .{ .offset = offset, .length = 0 };

    sink.fix_begin("Append a full stop", .safe, comment.line);
    sink.fix_edit(at, ".");
    sink.report_fixed(at, "the comment does not close with a full stop");
}

fn expect_count(language: scylla.Language, source: []const u8, expected: u32) !void {
    assert(source.len > 0);

    var findings = try testing.analyze(@This(), language, source);
    defer findings.deinit();

    if (findings.count() != expected) findings.print();

    try std.testing.expectEqual(expected, findings.count());
}

fn expect_mentions(source: []const u8, expected: []const []const u8) !void {
    assert(expected.len > 0);

    var findings = try testing.analyze(@This(), .rust, source);
    defer findings.deinit();

    if (findings.count() != expected.len) findings.print();

    try std.testing.expectEqual(expected.len, findings.count());

    for (expected, 0..) |text, index| {
        try std.testing.expect(std.mem.find(u8, findings.message(@intCast(index)), text) != null);
    }
}

test "a block comment on one line is a comment" {
    const source = "package main\n\n/* lowercase without a stop */\nfunc run() {}\n";

    try expect_count(.go, source, 2);
}

test "a block comment run joins at one column" {
    const source = "package main\n\nfunc run() {\n\t/* one line without a stop */\n" ++
        "\t/* And a second. */\n\twork()\n}\n";

    try expect_count(.go, source, 1);
}

test "a block comment run at two indents does not join" {
    const source = "package main\n\nfunc run() {\n\t/* one line without a stop */\n" ++
        "\t\t/* And a second. */\n\twork()\n}\n";

    try expect_count(.go, source, 2);
}

test "a well formed block comment is quiet" {
    try testing.expect_quiet(@This(), .go, "package main\n\n/* Proper form. */\nfunc run() {}\n");
}

test "a block doc comment stays out of the walk" {
    const source = "package main\n\n/** lowercase without a stop */\nfunc run() {}\n";

    try testing.expect_quiet(@This(), .go, source);
}

test "a comment with no space is reported" {
    try expect_mentions("//This is a note.\nfn f() {}\n", &.{"space"});
}

test "a windows comment takes its space before the carriage return" {
    const source = "//This is a note.\r\nfn f() {}\r\n";

    try testing.expect_fixed(@This(), .rust, source, .safe, "// This is a note.\r\nfn f() {}\r\n");
}

test "a suppression marker is a directive rather than prose" {
    try testing.expect_quiet(@This(), .go, "fn f() {\n    // go:nosplit\n}\n");
    try expect_count(.go, "fn f() {\n    // go nosplit\n}\n", 2);
}

test "the three comment fixes converge one row at a time" {
    const source = "//this is a note\nfn f() {}\n";

    try testing.expect_fixed(@This(), .rust, source, .safe, "// This is a note.\nfn f() {}\n");
}

test "a python comment gains its space" {
    const source = "#a note here.\nvalue = 1\n";

    try testing.expect_fixed(@This(), .python, source, .safe, "# A note here.\nvalue = 1\n");
}

test "a lower case comment is reported" {
    try expect_count(.rust, "// this is a note.\nfn f() {}\n", 1);
}

test "an unterminated comment is reported" {
    try expect_count(.python, "# This is a longer note\ndef f():\n    pass\n", 1);
}

test "a well formed comment is quiet" {
    try testing.expect_quiet(@This(), .rust, "// This is a note.\nfn f() {}\n");
}

test "a comment run reports one capital and one stop" {
    const source = "// this comment wraps\n// across two lines\nfn f() {}\n";

    try expect_mentions(source, &.{ "lower case", "full stop" });
}

test "a byte order mark does not break the run it opens" {
    const plain = "// This comment wraps\n// across two lines.\nfn f() {}\n";
    const marked = "\xef\xbb\xbf// This comment wraps\n// across two lines.\nfn f() {}\n";

    try testing.expect_quiet(@This(), .rust, plain);
    try testing.expect_quiet(@This(), .rust, marked);
}

test "a run breaks where the column moves" {
    try expect_count(.rust, "// one wrapped note\n    // two wrapped note\nfn f() {}\n", 4);
}

test "commented out code is not prose" {
    try testing.expect_quiet(@This(), .rust, "//     let value = 1;\nfn f() {}\n");
}

test "a line closing on a code link carries its sentence" {
    const source = "/// The mesh must be a [`TriangleList`]\n/// and must carry a [`Position`]\n" ++
        "/// attribute.\nfn f() {}\n";

    const alone = "/// See [`TriangleList`]\nfn f() {}\n/// the mesh holds a position\nfn g() {}\n";

    try testing.expect_quiet(@This(), .rust, source);
    try expect_count(.rust, alone, 2);
}

test "a list item is not prose" {
    try testing.expect_quiet(@This(), .rust, "// - one item\n// - two item\nfn f() {}\n");
}

test "a line indented under a list item continues the item's sentence" {
    const continued = "/// Two cases follow:\n/// - Let `A` be the maximum count\n" ++
        "///   due to appends. (In other words, `A` counts appends.)\n" ++
        "/// - Let `B` be the minimum count.\nfn f() {}\n";

    const unstopped = "/// - Let `A` be the maximum count\n///   due to appends\n" ++
        "/// - Let `B` be the minimum count.\nfn f() {}\n";

    const outdented = "/// - Let `A` be the maximum count\n/// due to appends.\nfn f() {}\n";

    try testing.expect_quiet(@This(), .rust, continued);
    try expect_mentions(unstopped, &.{"full stop"});
    try expect_mentions(outdented, &.{"lower case"});
}

test "a language directive is not prose" {
    try testing.expect_quiet(@This(), .rust, "// clippy::all is off here\nfn f() {}\n");
    try testing.expect_quiet(@This(), .go, "//go:generate stringer -type=Kind\nfunc f() {}\n");
    try testing.expect_quiet(@This(), .python, "# type: ignore\ndef f():\n    pass\n");
}

test "a doc comment is a comment in rust and zig" {
    try expect_count(.rust, "/// a doc note\nfn f() {}\n", 2);
    try expect_count(.zig, "/// a doc note\nfn f() void {}\n", 2);
}

test "a markdown heading of any level is not prose" {
    const headings = "//! ## Design\n//!\n//! ### Data formats\n//!\n//! Serde is a framework.\n" ++
        "fn f() {}\n";

    try testing.expect_quiet(@This(), .rust, headings);
    try expect_mentions("/// ##Design\nfn f() {}\n", &.{"full stop"});
}

test "a markdown heading and a fenced block are not prose" {
    const source = "/// # Examples\n///\n/// ```\n/// let held = f();\n/// ```\n/// Runs.\n" ++
        "fn f() {}\n";

    try testing.expect_quiet(@This(), .rust, source);
}

test "a run breaks at a full stop so each sentence is checked" {
    const source = "// First.\n// second no capital\n// Third no stop\n// Fourth.\nfn f() {}\n";

    try expect_mentions(source, &.{"lower case"});
}

test "a colon wants something to follow" {
    try expect_mentions("fn f() {\n    let a = 1;\n    // Then this:\n}\n", &.{"colon"});
    try expect_count(.rust, "fn f() {\n    // Then this:\n\n    let a = 1;\n}\n", 1);
    try testing.expect_quiet(@This(), .rust, "fn f() {\n    // Then this:\n    let a = 1;\n}\n");
}

test "a block comment that code follows on its line shares the line" {
    const source = "package p\n\nVALUES :: [2]u64{\n\t/* seeded value */ 0x2ce57620,\n" ++
        "\t/* plain value */ 0x997f,\n}\n\n/* a lower case comment */\n";

    try expect_count(.odin, source, 2);
}

test "a trailing comment wants its space but no punctuation" {
    try testing.expect_quiet(@This(), .rust, "fn f() {} // a note here\n");
    try expect_mentions("fn f() {} //a note here\n", &.{"space"});
}

test "a sentence closing inside a parenthesis closes with its full stop" {
    const closed = "// The second example costs more for large files. (Of course, chunks may\n" ++
        "// be needed for very large files.)\nfn f() {}\n";

    const open = "// The second example costs more for large files. (Of course, chunks may\n" ++
        "// be needed for very large files)\nfn f() {}\n";

    const variadic = "/// Matches the C declaration:\n/// int foo(int bar, ...)\nfn f() {}\n";

    try testing.expect_quiet(@This(), .rust, closed);
    try testing.expect_quiet(@This(), .rust, variadic);
    try expect_mentions(open, &.{"full stop"});
}

test "a link reference definition is data rather than prose" {
    const definition = "/// See [the module docs] for cancellation.\n///\n" ++
        "/// [the module docs]: crate::task#cancellation\nfn f() {}\n";

    const sentence = "/// [The module docs] describe cancellation\nfn f() {}\n";

    try testing.expect_quiet(@This(), .rust, definition);
    try expect_mentions(sentence, &.{"full stop"});
}

test "a short comment still wants its full stop" {
    try expect_mentions("// MIT\nfn f() {}\n", &.{"full stop"});
}

test "a directive comment is quiet" {
    try testing.expect_quiet(@This(), .rust, "// tigerstyle-ignore: TS002\nfn f() {}\n");
}

test "an indented comment body is code rather than prose" {
    const code = "fn helper() {\n    //     note here\n    let a = 1;\n}\n";
    const prose = "fn helper() {\n    // note here\n    let a = 1;\n}\n";

    try testing.expect_quiet(@This(), .rust, code);

    var findings = try testing.analyze(@This(), .rust, prose);
    defer findings.deinit();

    try std.testing.expect(!findings.empty());
}

test "a markdown link target is prose rather than a bare url" {
    const linked = "/// Alternatively, consider using\n" ++
        "/// [`lazy_static`](https://crates.io/crates/lazy_static)\n/// or\n" ++
        "/// [`once_cell`](https://crates.io/crates/once_cell),\n" ++
        "/// which will guarantee safety for you.\nfn f() {}\n";

    const bare = "/// See the spec at\n/// https://example.com/spec\n/// for details.\nfn f() {}\n";

    try testing.expect_quiet(@This(), .rust, linked);
    try expect_mentions(bare, &.{ "full stop", "lower case" });
}

test "a link that closes a sentence is no marker" {
    const source = "/// Returns a manually set prefilter, if one was set by\n" ++
        "/// [`Config::prefilter`].\nfn f() {}\n";

    try testing.expect_quiet(@This(), .rust, source);
    try testing.expect_quiet(@This(), .rust, "// TODO:refactor\nfn f() {}\n");
}

test "a code span or a remark that runs to the end of a line is prose" {
    const span = "/// This may panic when `at > haystack.len()`. Note that `at ==\n" ++
        "/// haystack.len()` is legal and guaranteed not to panic.\nfn f() {}\n";

    const remark = "/// They get popped after an inductive (i.e., recursive)\n" ++
        "/// step is complete.\nfn f() {}\n";

    const call = "/// Matches the C declaration:\n/// int foo(int bar)\nfn f() {}\n";

    try testing.expect_quiet(@This(), .rust, span);
    try testing.expect_quiet(@This(), .rust, remark);
    try testing.expect_quiet(@This(), .rust, call);
}
