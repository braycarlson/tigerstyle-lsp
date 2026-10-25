const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const safety = @import("../safety.zig");
const scan = @import("../../scan.zig");
const stream = @import("../../stream.zig");
const testing = @import("../testing.zig");
const Context = @import("../context.zig");
const Frame = @import("../frame.zig");
const Language = scylla.Language;
const Rule = scylla.rule.Rule;
const Sink = scylla.rule.Sink;
const Span = scylla.Span;
const Token = scylla.Token;

pub const rule: Rule = .{
    .citations = &.{
        .{
            .standard = "TigerStyle",
            .text = "\"Appreciate, from day one, all compiler warnings at the compiler's " ++
                "strictest setting.\"",
        },
        .{
            .standard = "NASA",
            .text = "NASA P10 Rule 10: \"All code must be compiled, from the first day of " ++
                "development, with all compiler warnings enabled at the compiler's most " ++
                "pedantic setting. All code must compile with these setting without any " ++
                "warnings.\"",
        },
    },
    .code = "TS020",
    .default_on = true,
    .description = "A warning is fixed rather than silenced, because the next reader cannot " ++
        "tell a silenced warning from a checked one.",
    .explanation = "",
    .fix_title = "",
    .fixable = .sometimes,
    .group = .stable,
    .name = "no-warning-suppression",
    .severity = .warning,
    .summary = "Fix the underlying issue rather than silencing the warning",
    .url = "",
};

const Suppression = struct {
    alone: bool,
    end: ?u32,
    span: Span,
    start: u32,
    text: []const u8,
};

const bounds_check_marker = "#no_bounds_check";
const comment_opener_bytes = "!#*/@";
const conditional_attribute = "cfg_attr";
const conditional_suppressors = [_][]const u8{ "allow(", "expect(" };
const disabled_word = "false";
const empty_statement = "pass";
const ignore_word = "ignore";
const inline_whitespace = " \t";
const runtime_safety_names = [_][]const u8{ "@setRuntimeSafety", "setRuntimeSafety" };
const suppressing_attributes = [_][]const u8{ "allow", "cfg_attr", "expect" };
const warning_filter_arguments_max: u32 = 8;
const warning_filter_calls = [_][]const u8{ "filterwarnings", "simplefilter" };

pub fn run(context: *const Context, sink: *Sink) void {
    assert(context.token_index.comments().len <= context.tokens.len);
    assert(context.token_index.identifiers().len <= context.tokens.len);

    report_suppressing_comments(context, sink);
    report_suppressing_attributes(context, sink);
}

fn report_suppressing_comments(context: *const Context, sink: *Sink) void {
    const markers = context.conventions.suppression_markers;

    for (context.token_index.comments()) |index| {
        assert(index < context.tokens.len);

        const token = context.tokens[index];
        const text = context.text(token);

        assert(token.kind == .comment);

        if (suppresses_a_type_only_import(context, index, text)) continue;

        const opener = directive_opener(text, markers) orelse continue;
        const start = token.offset + opener;

        assert(opener < text.len);

        suppression_report(context, sink, .{
            .alone = false,
            .end = token.end(),
            .span = Span.between(start, token.end()),
            .start = start,
            .text = "the comment silences a checker",
        });
    }
}

fn report_suppressing_attributes(context: *const Context, sink: *Sink) void {
    for (context.token_index.identifiers()) |index| {
        assert(index < context.tokens.len);

        const token = context.tokens[index];
        const name = context.text(token);

        assert(token.kind == .identifier);

        const builtin = builtin: {
            if (std.mem.eql(u8, name, bounds_check_marker)) break :builtin true;

            break :builtin disables_runtime_safety(context, index);
        };

        if (heads_an_attribute(context, index)) {
            if (std.mem.eql(u8, name, conditional_attribute)) {
                if (!conditionally_suppresses(context, token)) continue;
            }

            const bracket = index - 1;
            const closing = context.pairs.partner_of(bracket);
            const end = if (closing) |last| context.tokens[last].end() else null;

            attribute_report(context, sink, context.tokens[bracket].offset, token, end);

            continue;
        }

        if (builtin) {
            attribute_report(context, sink, token.offset, token, builtin_end(context, index));

            continue;
        }

        if (!filters_warnings(context, index)) continue;

        call_report(context, sink, index);
    }
}

fn attribute_report(
    context: *const Context,
    sink: *Sink,
    opening: u32,
    token: Token,
    end: ?u32,
) void {
    assert(opening <= token.offset);

    const start = marker_start(context, opening);

    assert(start <= opening);

    suppression_report(context, sink, .{
        .alone = false,
        .end = end,
        .span = token.span(),
        .start = start,
        .text = "the attribute silences a checker",
    });
}

fn builtin_end(context: *const Context, index: u32) ?u32 {
    assert(index < context.tokens.len);

    const token = context.tokens[index];
    if (std.mem.eql(u8, context.text(token), bounds_check_marker)) return token.end();

    assert(context.tokens[index + 1].is_punctuation(.paren_open));

    const closing = context.pairs.partner_of(index + 1) orelse return null;

    assert(closing > index + 1);

    return context.tokens[statement_last(context, closing)].end();
}

fn call_report(context: *const Context, sink: *Sink, index: u32) void {
    assert(context.tokens[index + 1].is_punctuation(.paren_open));

    const tokens = context.tokens;
    const first = context.pairs.receiver_start(index);

    assert(first <= index);

    const last: ?u32 = last: {
        if (!stream.opens_a_statement(tokens, first)) break :last null;

        const closing = context.pairs.partner_of(index + 1) orelse break :last null;

        break :last statement_last(context, closing);
    };

    suppression_report(context, sink, .{
        .alone = if (last) |close| alone_in_suite(context, first, close) else false,
        .end = if (last) |close| tokens[close].end() else null,
        .span = tokens[index].span(),
        .start = tokens[first].offset,
        .text = "the call silences a checker",
    });
}

fn statement_last(context: *const Context, closing: u32) u32 {
    assert(closing < context.tokens.len);

    const next = closing + 1;

    if (next < context.tokens.len) {
        if (context.tokens[next].is_punctuation(.semicolon)) return next;
    }

    return closing;
}

fn alone_in_suite(context: *const Context, first: u32, last: u32) bool {
    assert(first <= last);
    assert(last < context.tokens.len);

    if (context.front.language != .python) return false;

    const tokens = context.tokens;
    const before = stream.significant_previous(tokens, first) orelse return false;
    if (tokens[before].kind != .block_start) return false;

    const after = stream.significant_next(tokens, last + 1, @intCast(tokens.len)) orelse {
        return true;
    };

    return tokens[after].kind == .block_end;
}

fn heads_an_attribute(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);

    if (index == 0) return false;

    const bracket = context.tokens[index - 1];

    assert(bracket.end() <= context.tokens[index].offset);

    if (!bracket.is_punctuation(.bracket_open)) return false;

    if (!scan.word_in(&suppressing_attributes, context.text(context.tokens[index]))) {
        return false;
    }

    return safety.attribute_marked(context, bracket.offset);
}

fn directive_opener(text: []const u8, markers: []const []const u8) ?u32 {
    assert(text.len <= std.math.maxInt(u32));

    var earliest: ?u32 = null;

    for (markers) |marker| {
        assert(marker.len > 0);

        var cursor: usize = 0;

        for (0..text.len + 1) |_| {
            const found = std.mem.findPos(u8, text, cursor, marker) orelse break;

            if (opener_of(text, found)) |opener| {
                earliest = if (earliest) |held| @min(held, opener) else opener;

                break;
            }

            cursor = found + 1;
        }
    }

    return earliest;
}

fn opener_of(text: []const u8, found: usize) ?u32 {
    assert(found <= text.len);

    const before = std.mem.trimEnd(u8, text[0..found], inline_whitespace);
    const opened = std.mem.trimEnd(u8, before, comment_opener_bytes);
    if (opened.len == before.len) return null;
    if (opened.len == 0) return 0;
    if (!std.ascii.isWhitespace(opened[opened.len - 1])) return null;
    return @intCast(opened.len);
}

fn holds_any(text: []const u8, markers: []const []const u8) bool {
    assert(text.len <= std.math.maxInt(u32));

    for (markers) |marker| {
        assert(marker.len > 0);

        if (scan.find(text, marker) != null) return true;
    }

    return false;
}

fn disables_runtime_safety(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);

    const tokens = context.tokens;
    if (!scan.word_in(&runtime_safety_names, context.text(tokens[index]))) return false;
    if (index + 2 >= tokens.len) return false;
    if (!tokens[index + 1].is_punctuation(.paren_open)) return false;

    const argument = tokens[index + 2];

    assert(argument.offset > tokens[index].offset);

    return std.mem.eql(u8, context.text(argument), disabled_word);
}

fn filters_warnings(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);

    const tokens = context.tokens;
    if (!scan.word_in(&warning_filter_calls, context.text(tokens[index]))) return false;

    const arguments = context.pairs.arguments_of(index + 1) orelse return false;

    assert(arguments.first < arguments.last);

    const inside = tokens[arguments.first + 1 .. arguments.last];
    const scanned = inside[0..@min(inside.len, warning_filter_arguments_max)];

    for (scanned) |token| {
        if (token.kind != .string) continue;
        if (std.mem.eql(u8, safety.unquoted(context.text(token)), ignore_word)) return true;
    }

    return false;
}

fn suppresses_a_type_only_import(context: *const Context, index: u32, text: []const u8) bool {
    assert(index < context.tokens.len);

    const codes = context.conventions.unused_import_suppressions;
    const markers = context.conventions.type_checking_markers;

    if (codes.len == 0) return false;
    if (markers.len == 0) return false;
    if (!holds_any(text, codes)) return false;

    const opens = stream.line_start_of_token(context.tokens, context.source, index);

    assert(opens <= index);

    if (!context.tokens[opens].is_keyword(.import)) return false;

    var frames = Frame.covering(context, index);

    for (0..context.front.node_count() + 1) |_| {
        const covering = frames.next() orelse break;
        const opening = covering.frame.opening_line(context);

        for (markers) |marker| {
            if (scan.find_word(opening, marker)) return true;
        }
    }

    return false;
}

fn conditionally_suppresses(context: *const Context, token: Token) bool {
    const line = context.line_of(token.offset);
    const text = context.line_text(line);

    assert(line < context.line_count());
    assert(token.end() <= context.source.len);

    return holds_any(text, &conditional_suppressors);
}

fn marker_start(context: *const Context, offset: u32) u32 {
    assert(offset <= context.source.len);

    var start = offset;

    if (start > 0) {
        if (context.source[start - 1] == '!') start -= 1;
    }

    if (start > 0) {
        switch (context.source[start - 1]) {
            '#', '@' => start -= 1,
            else => {},
        }
    }

    assert(start <= offset);

    return start;
}

fn suppression_report(context: *const Context, sink: *Sink, suppression: Suppression) void {
    assert(suppression.start <= suppression.span.offset);

    const anchored = Span.between(suppression.start, suppression.span.end());

    const end = suppression.end orelse {
        sink.report(anchored, suppression.text);

        return;
    };

    assert(suppression.span.end() <= end);
    assert(end <= context.source.len);

    sink.fix_begin("Remove the suppression", .unsafe, null);

    if (suppression.alone) {
        sink.fix_edit(Span.between(suppression.start, end), empty_statement);
    } else {
        sink.fix_edit(removal_of(context, suppression.start, end), "");
    }

    sink.report_fixed(anchored, suppression.text);
}

fn removal_of(context: *const Context, start: u32, end: u32) Span {
    assert(start < end);
    assert(end <= context.source.len);

    const opening = context.line_span(context.line_of(start));
    const closing = context.line_span(context.line_of(end));
    const trailing = context.source[end..closing.end()];

    assert(opening.offset <= start);
    assert(end <= closing.end());

    if (std.mem.trimStart(u8, trailing, scan.ascii_whitespace).len == 0) {
        const before = context.source[opening.offset..start];
        const kept: u32 = @intCast(std.mem.trimEnd(u8, before, scan.ascii_whitespace).len);

        return Span.between(opening.offset + kept, closing.end());
    }

    const spaces = trailing.len - std.mem.trimStart(u8, trailing, inline_whitespace).len;
    return Span.between(start, end + @as(u32, @intCast(spaces)));
}

fn expect_count(language: Language, source: []const u8, expected: u32) !void {
    assert(source.len > 0);
    assert(expected <= testing.limits.diagnostic_count_max);

    var findings = try testing.analyze(@This(), language, source);
    defer findings.deinit();

    if (findings.count() != expected) findings.print();

    try std.testing.expectEqual(expected, findings.count());
}

test "a marker quoted inside a prose comment is no directive" {
    const python = "class Options:\n    def run(self):\n" ++
        "        # Warn about unused '# type: ignore' comments\n        self.warn = False\n" ++
        "        held = load()  # type: ignore[attr]\n" ++
        "        other = load()  # noqa: E501  # type: ignore\n";

    const typescript = "// @ts-ignore\nconst held = load();\n/* eslint-disable */\n";

    try expect_count(.python, python, 2);
    try expect_count(.typescript, typescript, 2);
}

test "a type only import suppression is quiet" {
    const indent: [23]u8 = @splat(' ');

    const source = "import typing as t\n\nif t.TYPE_CHECKING:\n" ++ indent ++
        "from x import Y  # noqa: F401\n";

    try testing.expect_quiet(@This(), .python, source);
}

test "a blanket suppression on a type only import is reported" {
    const indent: [23]u8 = @splat(' ');

    const source = "import typing as t\n\nif t.TYPE_CHECKING:\n" ++ indent ++
        "from x import Y  # noqa\n";

    try expect_count(.python, source, 1);
}

test "a conditional allow attribute is reported" {
    try expect_count(.rust, "#[cfg_attr(not(test), allow(dead_code))]\nfn f() {}\n", 1);
}

test "a conditional attribute without a suppressor is quiet" {
    const source = "#[cfg_attr(feature = \"serde\", derive(Serialize))]\nstruct Value {}\n";

    try testing.expect_quiet(@This(), .rust, source);
}

test "an unreasoned expect attribute is reported" {
    try expect_count(.rust, "#[expect(dead_code)]\nfn f() {}\n", 1);
}

test "a reasoned expect attribute is still reported" {
    const source = "#[expect(clippy::needless_range_loop, reason = \"the index is used\")]\n" ++
        "fn f() {}\n";

    try expect_count(.rust, source, 1);
}

test "a documented allow attribute is still reported" {
    const source = "/// The helper is kept for symmetry.\n#[allow(dead_code)]\nfn f() {}\n";

    try expect_count(.rust, source, 1);
}

test "a suppression comment with a reason is still reported" {
    try expect_count(.go, "package main\n\n//nolint:errcheck // legacy path\nfunc run() {}\n", 1);
}

test "a stack directive is not a suppression" {
    try testing.expect_quiet(@This(), .go, "package main\n\n//go:nosplit\nfunc run() {}\n");
}

test "a typescript nocheck comment is reported" {
    try expect_count(.typescript, "// @ts-nocheck\nfunction run() {}\n", 1);
}

test "a pylint disable comment is reported" {
    try expect_count(.python, "value = 1  # pylint: disable=invalid-name\n", 1);
}

test "a warnings filter that ignores is reported" {
    const source = "import warnings\n\nwarnings.filterwarnings(\"ignore\", category=Foo)\n";

    try expect_count(.python, source, 1);
}

test "a warnings filter that errors is quiet" {
    const source = "import warnings\n\nwarnings.simplefilter(\"error\")\n";

    try testing.expect_quiet(@This(), .python, source);
}

test "enabling runtime safety is quiet" {
    try testing.expect_quiet(@This(), .zig, "fn run() void {\n    @setRuntimeSafety(true);\n}\n");
}

test "disabling runtime safety is reported" {
    try expect_count(.zig, "fn run() void {\n    @setRuntimeSafety(false);\n}\n", 1);
}

test "an expect attribute with an unqualified lint is reported" {
    try expect_count(.rust, "#[expect(dead_code, reason = \"kept for symmetry\")]\nfn f() {}\n", 1);
}

test "an allow attribute is reported" {
    try expect_count(.rust, "#[allow(dead_code)]\nfn f() {}\n", 1);
}

test "a noqa comment is reported" {
    try expect_count(.python, "value = 1  # noqa\n", 1);
}

test "a suppression comment is deleted through the end of the line" {
    try testing.expect_fixed(@This(), .go, "value := 1  //nolint\n", .unsafe, "value := 1\n");
}

test "a directive after prose in one comment is deleted alone" {
    const source = "def f():\n    # A note on the value  # noqa: RUF003\n    return 1\n";
    const fixed = "def f():\n    # A note on the value\n    return 1\n";
    const whole = "def f():\n    return 1  # noqa: E501  # type: ignore\n";

    try testing.expect_fixed(@This(), .python, source, .unsafe, fixed);
    try testing.expect_fixed(@This(), .python, whole, .unsafe, "def f():\n    return 1\n");
}

test "a suppression attribute is deleted with its marker" {
    const source = "#[allow(dead_code)]\nfn helper() {}\n";

    try testing.expect_fixed(@This(), .rust, source, .unsafe, "\nfn helper() {}\n");
}

test "a zig safety call is deleted with its marker" {
    try testing.expect_fixed(
        @This(),
        .zig,
        "fn helper() void {\n    @setRuntimeSafety(false);\n}\n",
        .unsafe,
        "fn helper() void {\n\n}\n",
    );
}

const inline_attribute = "struct Marker(#[allow(dead_code)] *mut ());\n";
const heading_attribute = "#[allow(dead_code)] fn helper() {}\n";

const spanning_attribute = "#![allow(\n    clippy::cognitive_complexity,\n" ++
    "    clippy::large_enum_variant,\n)]\n\nfn helper() {}\n";

const spanning_filter = "import warnings\n\nwith warnings.catch_warnings():\n" ++
    "    warnings.filterwarnings(\n        \"ignore\", category=UserWarning\n    )\n    run()\n";

const lone_filter = "import warnings\n\nwith warnings.catch_warnings():\n" ++
    "    warnings.simplefilter(\"ignore\")\nrun()\n";

const lone_inline_filter = "import warnings\n\n" ++
    "with warnings.catch_warnings(): warnings.simplefilter(\"ignore\")\nrun()\n";

const bounds_check_directive = "package main\n\ntotal :: proc(values: []int) -> int {\n" ++
    "    sum := 0\n    #no_bounds_check for value in values {\n        sum += value\n    }\n" ++
    "    return sum\n}\n";

test "an inline attribute is deleted without the code after it" {
    const expected = "struct Marker(*mut ());\n";

    try expect_count(.rust, inline_attribute, 1);

    try testing.expect_fixed(@This(), .rust, inline_attribute, .unsafe, expected);
}

test "an attribute heading an item on its line keeps the item" {
    try expect_count(.rust, heading_attribute, 1);

    try testing.expect_fixed(@This(), .rust, heading_attribute, .unsafe, "fn helper() {}\n");
}

test "an attribute spanning lines is deleted whole" {
    try expect_count(.rust, spanning_attribute, 1);

    try testing.expect_fixed(@This(), .rust, spanning_attribute, .unsafe, "\n\nfn helper() {}\n");
}

test "a warnings filter spanning lines is deleted whole" {
    const expected = "import warnings\n\nwith warnings.catch_warnings():\n\n    run()\n";

    try expect_count(.python, spanning_filter, 1);

    try testing.expect_fixed(@This(), .python, spanning_filter, .unsafe, expected);
}

test "a warnings filter alone in its block leaves the block a statement" {
    const expected = "import warnings\n\nwith warnings.catch_warnings():\n    pass\nrun()\n";

    try expect_count(.python, lone_filter, 1);

    try testing.expect_fixed(@This(), .python, lone_filter, .unsafe, expected);
}

test "a warnings filter that is no whole statement reports without a fix" {
    const assigned = "import warnings\n\nresult = warnings.simplefilter(\"ignore\")\n";

    try expect_count(.python, lone_inline_filter, 1);
    try expect_count(.python, assigned, 1);

    try testing.expect_fixed(@This(), .python, lone_inline_filter, .unsafe, lone_inline_filter);
    try testing.expect_fixed(@This(), .python, assigned, .unsafe, assigned);
}

test "a bounds check directive is deleted without the loop it heads" {
    const expected = "package main\n\ntotal :: proc(values: []int) -> int {\n" ++
        "    sum := 0\n    for value in values {\n        sum += value\n    }\n" ++
        "    return sum\n}\n";

    try expect_count(.odin, bounds_check_directive, 1);

    try testing.expect_fixed(@This(), .odin, bounds_check_directive, .unsafe, expected);
}

test "a removed suppression leaves the delimiters balanced" {
    const gpa = std.testing.allocator;

    const cases = [_]struct { Language, []const u8 }{
        .{ .rust, inline_attribute },
        .{ .rust, heading_attribute },
        .{ .rust, spanning_attribute },
        .{ .python, spanning_filter },
        .{ .python, lone_filter },
        .{ .odin, bounds_check_directive },
    };

    for (cases) |case| {
        const language, const source = case;

        assert(scan.balanced(source));

        const fixed = try testing.fixed_once(@This(), language, source, .unsafe);
        defer gpa.free(fixed);

        try std.testing.expect(!std.mem.eql(u8, fixed, source));
        try std.testing.expect(scan.balanced(fixed));
    }
}
