const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const control = @import("../control.zig");
const scan = @import("../../scan.zig");
const stream = @import("../../stream.zig");
const support = @import("../support.zig");
const testing = @import("../testing.zig");
const Context = @import("../context.zig");
const Rule = scylla.rule.Rule;
const RustKind = scylla.rust.Kind;
const Sink = scylla.rule.Sink;
const Span = scylla.Span;
const Token = scylla.Token;

pub const rule: Rule = .{
    .citations = &.{
        .{
            .standard = "TigerStyle",
            .text = "\"To wrap a function signature, call or data structure, add a trailing " ++
                "comma, close your eyes and let `zig fmt` do the rest.\"",
        },
    },
    .code = "TS055",
    .default_on = false,
    .description = "A wrapped list ends with a trailing comma, so the formatter keeps one " ++
        "element per line and the next element is a one-line change.",
    .explanation = "",
    .fix_title = "Add the trailing comma",
    .fixable = .sometimes,
    .group = .stable,
    .name = "trailing-comma",
    .severity = .information,
    .summary = "A wrapped list ends with a trailing comma",
    .url = "",
};

const Element = struct {
    last: u32,
    start: u32,
};

const arm_arrow = "=>";
const data_structure_words = [_][]const u8{ "enum", "export", "import", "struct", "union" };
const header_lookbehind_max: u32 = 256;
const list_tokens_max: u32 = 1 << 14;
const macro_definition_word = "macro_rules";
const membership_word = "in";
const message = "the wrapped list ends without a trailing comma";
const metavariable_sigil = "$";
const repetition_operators = [_][]const u8{ "*", "+", "?" };
const significant_lookbehind_max: u32 = 16;

pub fn run(context: *const Context, sink: *Sink) void {
    const tokens = context.tokens;

    for (tokens, 0..) |token, token_index| {
        const index: u32 = @intCast(token_index);

        if (!token.opens_a_group_or_block()) continue;
        if (token.length == 0) continue;

        const close = context.pairs.partner_of(index) orelse continue;
        if (close <= index) continue;
        if (context.line_of(token.offset) == context.line_of(tokens[close].offset)) continue;

        if (token.kind == .block_start) {
            if (!opens_a_data_structure(context, index)) continue;
        }

        const element = element_last_of(context, index, close) orelse continue;
        const held = tokens[element.last];

        assert(element.last < close);

        if (held.is_punctuation(.comma)) continue;
        if (held.is_punctuation(.semicolon)) continue;
        if (held.kind == .block_end) continue;
        if (closes_a_do_body(context, element.last, close)) continue;
        if (spreads(context, element)) continue;
        if (repeats(context, element.last)) continue;
        if (matches_a_pattern(context, index)) continue;

        if (!lays_one_per_line(context, index, close, element.last)) {
            sink.report(span_reported(context, element.last), message);

            continue;
        }

        comma_report(context, sink, element.last);
    }
}

fn lays_one_per_line(context: *const Context, open: u32, close: u32, last: u32) bool {
    const tokens = context.tokens;

    assert(open < last);
    assert(last < close);

    if (context.line_of(tokens[close].offset) == context.line_of(tokens[last].offset)) return false;

    var cursor = open + 1;
    var before = open;
    var starting = true;

    for (0..list_tokens_max) |_| {
        if (cursor >= close) break;

        const token = tokens[cursor];

        if (Token.is_significant(token.kind)) {
            if (starting) {
                if (context.line_of(token.offset) == context.line_of(tokens[before].offset)) {
                    return false;
                }

                starting = false;
            }

            if (token.is_punctuation(.comma)) {
                starting = true;
                before = cursor;
            }
        }

        if (token.opens_a_group_or_block()) {
            if (nested_close(context, cursor, close)) |partner| cursor = partner;
        }

        cursor += 1;
    }

    return true;
}

fn closes_a_do_body(context: *const Context, last: u32, close: u32) bool {
    assert(last < close);
    assert(close < context.tokens.len);

    if (context.front.language != .odin) return false;

    const tokens = context.tokens;

    const ended = for (tokens[last + 1 .. close]) |token| {
        if (token.kind == .newline) break true;
    } else false;

    if (!ended) return false;

    var cursor = last + 1;

    for (0..list_tokens_max) |_| {
        if (cursor == 0) return false;

        cursor -= 1;

        const token = tokens[cursor];
        if (token.kind == .newline) return false;
        if (!token.is_keyword(.other)) continue;
        if (std.mem.eql(u8, context.text(token), "do")) return true;
    }

    assert(cursor < last + 1);

    return false;
}

fn comma_report(context: *const Context, sink: *Sink, last: u32) void {
    const held = context.tokens[last];

    assert(Token.is_significant(held.kind));
    assert(!held.is_punctuation(.comma));

    const at: Span = .{ .offset = held.end(), .length = 0 };
    const reported = span_reported(context, last);

    sink.fix_begin("Add the trailing comma", .safe, null);

    if (std.mem.startsWith(u8, context.text(held), "\\\\")) {
        const line = context.line_text(context.line_of(held.offset));
        const indent = line.len - std.mem.trimStart(u8, line, scan.ascii_whitespace).len;

        sink.fix_edit_formatted(at, "\n{[empty]s:[indent]},", .{ .empty = "", .indent = indent });
    } else {
        sink.fix_edit(at, ",");
    }

    sink.report_fixed(reported, message);
}

fn element_last_of(context: *const Context, open: u32, close: u32) ?Element {
    assert(open < close);
    assert(close < context.tokens.len);

    if (holds_a_comprehension(context, open, close)) return null;

    const tokens = context.tokens;

    var comma_seen = false;
    var cursor = open + 1;
    var last: ?u32 = null;
    var start = open + 1;

    for (0..list_tokens_max) |_| {
        if (cursor >= close) break;

        const token = tokens[cursor];
        if (token.is_punctuation(.semicolon)) return null;

        if (Token.is_significant(token.kind)) {
            if (token.is_punctuation(.comma)) {
                comma_seen = true;
                start = cursor + 1;
            }

            last = cursor;
        }

        if (token.opens_a_group_or_block()) {
            if (nested_close(context, cursor, close)) |partner| {
                cursor = partner;
                last = cursor;
            }
        }

        cursor += 1;
    }

    const ended = last orelse return null;

    if (!comma_seen) return null;

    assert(ended > open);
    assert(start <= close);

    return .{ .last = ended, .start = start };
}

fn holds_a_comprehension(context: *const Context, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < context.tokens.len);

    var cursor = open + 1;
    var iterates = false;

    for (0..list_tokens_max) |_| {
        if (cursor >= close) return false;

        const token = context.tokens[cursor];

        if (token.is_keyword(.loop)) iterates = true;

        if (iterates) {
            if (std.mem.eql(u8, context.text(token), membership_word)) return true;
        }

        if (token.opens_a_group_or_block()) {
            if (nested_close(context, cursor, close)) |partner| cursor = partner;
        }

        cursor += 1;
    }

    return false;
}

fn is_javascript_spread(context: *const Context, token: Token) bool {
    assert(token.length > 0);
    assert(token.end() <= context.source.len);

    switch (context.front.language) {
        .javascript, .typescript => {},
        else => return false,
    }

    return std.mem.eql(u8, context.text(token), "...");
}

fn matches_a_pattern(context: *const Context, open: u32) bool {
    const tokens = context.tokens;

    assert(open < tokens.len);
    assert(tokens[open].opens_a_group_or_block());

    if (!context.conventions.macros_invoke_with_bang) return false;

    var group = open;

    for (0..scylla.limits.bracket_depth_max) |_| {
        const enclosing = context.pairs.enclosing_at(tokens[group].offset) orelse return false;

        assert(enclosing.open < group);

        if (defines_a_macro(context, enclosing.open)) return precedes_an_arm(context, group);

        group = enclosing.open;
    }

    return false;
}

fn defines_a_macro(context: *const Context, open: u32) bool {
    const tokens = context.tokens;

    assert(open < tokens.len);

    if (open < 3) return false;
    if (tokens[open - 1].kind != .identifier) return false;
    if (!tokens[open - 2].is_punctuation(.bang)) return false;
    return std.mem.eql(u8, context.text(tokens[open - 3]), macro_definition_word);
}

fn precedes_an_arm(context: *const Context, open: u32) bool {
    const tokens = context.tokens;
    const close = context.pairs.partner_of(open) orelse return false;

    assert(close > open);

    if (close + 1 >= tokens.len) return false;

    const after = stream.significant_next(
        tokens,
        close + 1,
        @intCast(tokens.len),
    ) orelse return false;

    assert(after > close);

    return std.mem.eql(u8, context.text(tokens[after]), arm_arrow);
}

fn repeats(context: *const Context, last: u32) bool {
    const tokens = context.tokens;

    assert(last < tokens.len);

    if (!context.conventions.macros_invoke_with_bang) return false;
    if (!scan.word_in(&repetition_operators, context.text(tokens[last]))) return false;

    var group_close = significant_before(tokens, last) orelse return false;

    if (!tokens[group_close].is_punctuation(.paren_close)) {
        group_close = significant_before(tokens, group_close) orelse return false;
    }

    if (!tokens[group_close].is_punctuation(.paren_close)) return false;

    const group_open = context.pairs.open_of(group_close) orelse return false;

    assert(group_open < group_close);

    if (group_open == 0) return false;
    return std.mem.eql(u8, context.text(tokens[group_open - 1]), metavariable_sigil);
}

fn names_a_lifetime(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);
    assert(Token.is_significant(context.tokens[index].kind));

    if (context.front.language != .rust) return false;
    if (index == 0) return false;

    const quote = context.tokens[index - 1];
    if (quote.exact_kind(RustKind) != .apostrophe) return false;
    return quote.end() == context.tokens[index].offset;
}

fn nested_close(context: *const Context, open: u32, close: u32) ?u32 {
    assert(open < close);
    assert(context.tokens[open].opens_a_group_or_block());

    const partner = context.pairs.partner_of(open) orelse return null;
    if (partner <= open) return null;
    if (partner >= close) return null;
    return partner;
}

fn opens_a_data_structure(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);
    assert(context.tokens[index].kind == .block_start);

    const tokens = context.tokens;
    const previous = significant_before(tokens, index) orelse return false;
    if (opens_a_literal(context, piece_last(context, previous))) return true;
    if (tokens[previous].kind != .identifier) return false;
    if (opens_a_line_block(context, previous, index)) return false;
    if (closes_a_header(context, index)) return false;

    const earlier = significant_before(tokens, previous) orelse return false;
    if (opens_a_literal(context, piece_last(context, earlier))) return true;
    if (closes_an_array_type(context, earlier)) return true;

    return switch (tokens[earlier].kind) {
        .keyword => |keyword| switch (keyword) {
            .constant, .declare, .mutable => true,
            else => false,
        },
        else => false,
    };
}

fn opens_a_line_block(context: *const Context, previous: u32, index: u32) bool {
    const tokens = context.tokens;

    assert(previous < index);
    assert(tokens[index].kind == .block_start);

    if (context.grammar.statements_end_with_semicolon) return false;

    const named = context.line_of(tokens[previous].offset);
    const opened = context.line_of(tokens[index].offset);

    assert(named <= opened);

    return named < opened;
}

fn closes_a_header(context: *const Context, index: u32) bool {
    const tokens = context.tokens;
    const step_count: u32 = @min(index, header_lookbehind_max);

    assert(index < tokens.len);
    assert(tokens[index].kind == .block_start);

    const separated = context.grammar.statements_end_with_semicolon;

    var depth: u32 = 0;

    for (0..step_count) |step| {
        const cursor = index - 1 - @as(u32, @intCast(step));
        const token = tokens[cursor];
        if (token.kind == .block_start) return false;
        if (token.kind == .block_end) return false;

        if (separated) {
            if (token.is_punctuation(.semicolon)) return false;
        }

        if (token.closes_a_group()) {
            depth += 1;

            continue;
        }

        if (token.opens_a_group()) {
            if (depth == 0) return false;

            depth -= 1;

            continue;
        }

        if (depth > 0) continue;
        if (!opens_a_header(token)) continue;
        return control.header_end(context, cursor + 1) == index;
    }

    return false;
}

fn opens_a_header(token: Token) bool {
    return switch (token.kind) {
        .keyword => |keyword| switch (keyword) {
            .branch, .loop, .match => true,
            else => false,
        },
        else => false,
    };
}

fn closes_an_array_type(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);

    if (!context.tokens[index].is_punctuation(.bracket_close)) return false;

    const open = context.pairs.open_of(index) orelse return false;

    assert(open < index);

    const before = significant_before(context.tokens, open) orelse return false;
    return opens_a_literal(context, piece_last(context, before));
}

fn opens_a_literal(context: *const Context, token: Token) bool {
    assert(Token.is_significant(token.kind));
    assert(token.end() <= context.source.len);

    const opens = switch (token.kind) {
        .punctuation => |punctuation| switch (punctuation) {
            .assign, .assign_declare, .bracket_open, .colon, .comma, .dot, .paren_open => true,
            else => false,
        },
        .keyword => |keyword| switch (keyword) {
            .import, .@"return", .@"struct" => true,
            else => false,
        },
        else => false,
    };

    if (opens) return true;
    return scan.word_in(&data_structure_words, context.text(token));
}

fn piece_last(context: *const Context, index: u32) Token {
    assert(index < context.tokens.len);

    const token = context.tokens[index];
    if (std.meta.activeTag(token.kind) != .punctuation) return token;
    if (is_javascript_spread(context, token)) return token;

    var offset = token.offset;
    var piece = scan.punctuation_of(context.source, offset);
    if (piece.length >= token.length) return token;

    for (0..token.length) |_| {
        if (offset + piece.length >= token.end()) break;

        offset += piece.length;
        piece = scan.punctuation_of(context.source, offset);
    }

    assert(offset > token.offset);
    assert(offset < token.end());

    return .{
        .offset = offset,
        .length = token.end() - offset,
        .kind = .{ .punctuation = piece.punctuation },
    };
}

fn significant_before(tokens: []const Token, index: u32) ?u32 {
    assert(index < tokens.len);

    var cursor = index;

    for (0..significant_lookbehind_max) |_| {
        if (cursor == 0) return null;

        cursor -= 1;

        if (Token.is_significant(tokens[cursor].kind)) return cursor;
    }

    assert(cursor < index);

    return null;
}

fn span_reported(context: *const Context, last: u32) Span {
    assert(last < context.tokens.len);

    const start = if (names_a_lifetime(context, last))
        last - 1
    else
        support.literal_start_of(context, last);

    if (start == last) return piece_last(context, last).span();

    const first = context.tokens[start];
    const held = context.tokens[last];

    assert(first.offset < held.offset);

    return .{ .offset = first.offset, .length = held.end() - first.offset };
}

fn spreads(context: *const Context, element: Element) bool {
    const tokens = context.tokens;

    assert(element.start <= element.last);
    assert(element.last < tokens.len);

    const start = stream.significant_next(
        tokens,
        element.start,
        element.last + 1,
    ) orelse return false;

    const first = tokens[start];
    if (std.mem.startsWith(u8, context.text(first), "..")) return true;
    if (!first.is_punctuation(.dot)) return false;
    if (start + 1 >= tokens.len) return false;

    assert(first.length > 0);

    return tokens[start + 1].is_punctuation(.dot);
}

test "a wrapped call without a trailing comma gains one" {
    const source = "fn f() {\n    call(\n        a,\n        b\n    );\n}\n";
    const expected = "fn f() {\n    call(\n        a,\n        b,\n    );\n}\n";

    try testing.expect_fixed(@This(), .rust, source, .safe, expected);
}

test "a zig multiline string takes its comma on a line of its own" {
    const source = "fn f() void {\n    call(\n        a,\n        \\\\text\n    );\n}\n";

    const expected = "fn f() void {\n    call(\n        a,\n        \\\\text\n" ++
        "        ,\n    );\n}\n";

    try testing.expect_fixed(@This(), .zig, source, .safe, expected);
}

test "a hugged or packed list reports without a fix" {
    const hugged = "fn f() void {\n    call(.{\n        .a = 1,\n    }, 0);\n}\n";
    const packed_list = "fn f() void {\n    call(\n        a, b,\n        c\n    );\n}\n";

    try testing.expect_fixed(@This(), .zig, hugged, .unsafe, hugged);
    try testing.expect_fixed(@This(), .zig, packed_list, .unsafe, packed_list);
    try testing.expect_findings(@This(), .zig, hugged, &.{message});
    try testing.expect_findings(@This(), .zig, packed_list, &.{message});
}

test "two trailing commas land in one pass" {
    const gpa = std.testing.allocator;
    const source = "first = [\n    1,\n    2\n]\nsecond = [\n    3,\n    4\n]\n";
    const expected = "first = [\n    1,\n    2,\n]\nsecond = [\n    3,\n    4,\n]\n";
    const fixed = try testing.fixed_once(@This(), .python, source, .safe);
    defer gpa.free(fixed);

    try std.testing.expectEqualStrings(expected, fixed);
}

test "a template literal anchors at its opening backtick" {
    const source = "call(\n    a,\n    `x${b}y`\n);\n";

    try testing.expect_spans(@This(), .typescript, source, &.{.{ 17, 25 }});
}

test "a comprehension is no list" {
    const comprehension = "values = [\n    item.decode()\n    for _, key, item in pairs\n" ++
        "    if key == wanted\n]\n";

    const generator = "header = \", \".join(\n    f\"{key}={value}\"\n" ++
        "    for key, value in data.items()\n)\n";

    const listed = "values = [\n    first,\n    second\n]\n";

    try testing.expect_quiet(@This(), .python, comprehension);
    try testing.expect_quiet(@This(), .python, generator);
    try testing.expect_findings(@This(), .python, listed, &.{message});
}

test "a python f-string anchors at its prefix" {
    const source = "call(\n    a,\n    f\"x{b}y\"\n)\n";

    try testing.expect_spans(@This(), .python, source, &.{.{ 17, 25 }});
}

test "a postfix increment anchors at its last character" {
    const source = "call(\n    a,\n    b++\n);\n";

    try testing.expect_spans(@This(), .typescript, source, &.{.{ 19, 20 }});
}

test "a rust lifetime anchors at its quote" {
    const source = "fn f(\n    a: u8,\n    b: impl Fn() + 'static\n) {\n}\n";

    try testing.expect_spans(@This(), .rust, source, &.{.{ 36, 43 }});
}

test "a nullish assignment opens a data structure" {
    const source = "options ??= {\n    a: 1,\n    b: 2\n};\n";

    try testing.expect_spans(@This(), .typescript, source, &.{.{ 31, 32 }});
}

test "a spread object literal does not open a data structure" {
    try testing.expect_quiet(@This(), .typescript, "call(...{\n    a: 1,\n    b: 2\n});\n");
}

test "a struct update or a spread after a comment takes no comma" {
    const sources = [_]struct { scylla.Language, []const u8 }{
        .{ .rust, "fn f() -> S {\n    let s = S {\n        a: 1,\n        // The rest.\n" ++
            "        ..S::new()\n    };\n    s\n}\n" },
        .{ .typescript, "function f(\n    a: number,\n    // The rest.\n" ++
            "    ...rest: number[]\n) {}\n" },
    };

    for (sources) |held| {
        try testing.expect_quiet(@This(), held[0], held[1]);
    }
}

test "a field after a comment still takes its comma" {
    const source = "fn f() -> S {\n    let s = S {\n        a: 1,\n        // The rest.\n" ++
        "        b: 2\n    };\n    s\n}\n";

    const expected = "fn f() -> S {\n    let s = S {\n        a: 1,\n        // The rest.\n" ++
        "        b: 2,\n    };\n    s\n}\n";

    try testing.expect_fixed(@This(), .rust, source, .safe, expected);
}

test "an odin half-open range does not open a data structure" {
    const source = "f :: proc() {\n\tfor i in 0..<n {\n\t\ta, b = c()\n\t}\n}\n";

    try testing.expect_quiet(@This(), .odin, source);
}

test "an odin do body ends the list where its statement ends" {
    const source = "f :: proc() {\n\tfor x in s.items {\n\t\tif x do return x, true\n\t}\n}\n";

    try testing.expect_quiet(@This(), .odin, source);
}

test "a macro repetition ending a list supplies its own separators" {
    const source = "macro_rules! array {\n    ($($x:expr),+) => {\n        [\n            " ++
        "$(\n                $x\n            ),+\n        ]\n    };\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
}

test "a macro matcher is a pattern rather than a list" {
    const sources = [_][]const u8{
        "macro_rules! check {\n    (\n        $search:expr, $replace:expr,\n        " ++
            "$result:expr\n    ) => {\n        f($search, $replace, $result)\n    };\n}\n",
        "macro_rules! map {\n    (\n        $ty:ident <K, V>\n    ) => {};\n}\n",
        "macro_rules! group {\n    ($name:ident {\n        $field:ident,\n        " ++
            "$kind:ty\n    }) => {};\n}\n",
    };

    for (sources) |source| {
        try testing.expect_quiet(@This(), .rust, source);
    }
}

test "a list a macro transcriber writes still takes its comma" {
    const source = "macro_rules! check {\n    ($a:expr) => {\n        f(\n            $a,\n" ++
        "            2\n        )\n    };\n}\n";

    const expected = "macro_rules! check {\n    ($a:expr) => {\n        f(\n            $a,\n" ++
        "            2,\n        )\n    };\n}\n";

    try testing.expect_fixed(@This(), .rust, source, .safe, expected);

    const sum = "fn f() {\n    call(\n        a,\n        b + c\n    );\n}\n";

    const match_arm = "fn f(v: V) {\n    match v {\n        V::Pair(\n            a,\n" ++
        "            b\n        ) => {}\n    }\n}\n";

    var findings = try testing.analyze(@This(), .rust, sum);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());

    var arms = try testing.analyze(@This(), .rust, match_arm);
    defer arms.deinit();

    try std.testing.expectEqual(@as(u32, 1), arms.count());
}

test "a braceless zig branch before an array literal opens no header for it" {
    const source = "test \"t\" {\n" ++
        "    if (builtin.zig_backend == .stage2_c) return error.Skip;\n\n" ++
        "    const bytes = [_]u8{\n        0x6a, 0x53,\n        0x2d\n    };\n    _ = bytes;\n}\n";

    try testing.expect_anchors(@This(), .zig, source, &.{.{ 6, 9 }});
}

test "an odin block, switch body, or branch body after a name is no list" {
    const source = "package p\n\nf :: proc(m: M, x: X) -> (int, X) {\n\ttotal: int\n\t{\n" ++
        "\t\ta, b := 1, 2\n\t}\n\tswitch m.mode {\n\tcase .A, .B:\n\t\tsize = 1\n\t}\n" ++
        "\tif x != .None {\n\t\treturn 1, .Bad\n\t}\n\to := pkg.Options{\n\t\ta = 1,\n" ++
        "\t\tb = 2\n\t}\n\treturn total, x\n}\n";

    try testing.expect_anchors(@This(), .odin, source, &.{.{ 17, 7 }});
}
