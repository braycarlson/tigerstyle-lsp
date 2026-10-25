const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const scan = @import("../../scan.zig");
const stream = @import("../../stream.zig");
const support = @import("../support.zig");
const testing = @import("../testing.zig");
const Context = @import("../context.zig");
const Language = scylla.Language;
const Rule = scylla.rule.Rule;
const Sink = scylla.rule.Sink;
const Token = scylla.Token;
const TokenRange = Context.TokenRange;

pub const rule: Rule = .{
    .citations = &.{
        .{
            .standard = "NASA",
            .text = "NASA P10 Rule 5: \"Any assertion for which a static checking tool can " ++
                "prove that it can never fail or never hold violates this rule. (I.e., it is " ++
                "not possible to satisfy the rule by adding unhelpful \"assert(true)\" " ++
                "statements.)\"",
        },
    },
    .code = "TS049",
    .default_on = false,
    .description = "An assertion that cannot fail carries no information and hides the check it " ++
        "was meant to make.",
    .explanation = "",
    .fix_title = "",
    .fixable = .sometimes,
    .group = .stable,
    .name = "trivial-assert",
    .severity = .warning,
    .summary = "Do not write an assertion that cannot fail",
    .url = "",
};

const Finding = enum {
    cannot_fail,
    cannot_hold,
    compares_itself,
};

const comparison_methods = [_][]const u8{
    "__eq__",
    "__ge__",
    "__gt__",
    "__le__",
    "__lt__",
    "__ne__",
};

const comparison_operators = [_][]const u8{
    "===",
    "!==",
    "==",
    "!=",
    ">=",
    "<=",
    ">",
    "<",
    " is not ",
    " is ",
};

const comparison_traits = [_][]const u8{ "Eq", "Ord", "PartialEq", "PartialOrd" };

const condition_helpers = [_][]const u8{
    "False",
    "True",
    "assert",
    "assertFalse",
    "assertTrue",
    "debug_assert",
    "expect",
    "ok",
};

const definition_word = "def";
const equality_markers = [_][]const u8{ "Equal", "Same", "_eq", "_ne", "assertIs", "equal" };
const falsehoods = [_][]const u8{ "0", "False", "false", "not True" };
const identity_helper_prefix = "assertIs";
const implementation_target_word = "for";
const implementation_word = "impl";
const matcher_word = "expect";
const truths = [_][]const u8{ "1", "True", "not False", "true" };

pub fn run(context: *const Context, sink: *Sink) void {
    var compares_its_own: ?bool = null;

    for (context.tokens, 0..) |token, position| {
        const index: u32 = @intCast(position);

        if (!token.is_keyword(.assert)) continue;

        const condition = support.assert_condition(context, index) orelse continue;
        if (condition.start >= condition.end) continue;
        if (matches_through_a_receiver(context, index)) continue;

        const span = stream.span_of_range(context.tokens, condition.start, condition.end);
        const text = scan.stripped_group(context.span_text(span));

        assert(condition.end <= context.tokens.len);
        assert(text.len <= span.length);

        const finding = finding_of(context, index, condition, text) orelse continue;

        if (finding == .compares_itself) {
            const implemented = compares_its_own orelse implements_a_comparison(context);

            compares_its_own = implemented;

            if (implemented) continue;
            if (dispatches_to_the_term(context, index, condition)) continue;
        }

        const message = switch (finding) {
            .cannot_fail => "the assertion cannot fail",
            .cannot_hold => "the assertion cannot hold",
            .compares_itself => "the assertion compares a term with itself",
        };

        sink.report(span, message);
    }
}

fn finding_of(
    context: *const Context,
    index: u32,
    condition: TokenRange,
    text: []const u8,
) ?Finding {
    assert(condition.start < condition.end);
    assert(condition.end <= context.tokens.len);

    if (chains_a_matcher(context, index)) {
        if (matches_the_same_term(context, index, text)) return .compares_itself;
        return null;
    }

    const helper = helper_name(context, index);

    if (names_an_equality_helper(helper)) {
        if (equates_a_term_with_itself(context, index, text, condition.end)) {
            return .compares_itself;
        }

        return null;
    }

    if (!scan.word_in(&condition_helpers, helper)) return null;
    if (passes_a_number_after(context, condition)) return null;
    if (never_fails(context, condition, text)) return .cannot_fail;
    if (scan.word_in(&falsehoods, text)) return .cannot_hold;
    if (compares_itself(text)) return .compares_itself;
    return null;
}

fn helper_name(context: *const Context, index: u32) []const u8 {
    assert(index < context.tokens.len);

    const keyword = context.tokens[index];
    if (index + 2 >= context.tokens.len) return context.text(keyword);
    if (!context.tokens[index + 1].is_punctuation(.dot)) return context.text(keyword);
    if (context.tokens[index + 2].kind != .identifier) return context.text(keyword);

    const method = context.tokens[index + 2];

    assert(method.offset > keyword.offset);

    return context.text(method);
}

fn names_an_equality_helper(name: []const u8) bool {
    assert(name.len <= std.math.maxInt(u32));

    for (equality_markers) |marker| {
        if (scan.find(name, marker) == null) continue;

        assert(name.len >= marker.len);

        return true;
    }

    return false;
}

fn matches_through_a_receiver(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);

    if (!std.mem.eql(u8, context.text(context.tokens[index]), matcher_word)) return false;
    if (index == 0) return false;

    assert(index > 0);

    return context.tokens[index - 1].is_punctuation(.dot);
}

fn chains_a_matcher(context: *const Context, index: u32) bool {
    const arguments = support.assert_arguments(context, index) orelse return false;

    assert(arguments.start < arguments.end);
    assert(arguments.end <= context.tokens.len);

    if (arguments.end >= context.tokens.len) return false;
    return context.tokens[arguments.end].is_punctuation(.dot);
}

fn matches_the_same_term(context: *const Context, index: u32, expected: []const u8) bool {
    if (expected.len == 0) return false;
    if (std.mem.findScalar(u8, expected, '(') != null) return false;

    const arguments = support.assert_arguments(context, index) orelse return false;
    const close = arguments.end;

    assert(arguments.start < close);

    if (close + 2 >= context.tokens.len) return false;
    if (context.tokens[close + 1].kind != .identifier) return false;
    if (!context.tokens[close + 2].is_punctuation(.paren_open)) return false;

    const end = context.pairs.partner_of(close + 2) orelse return false;

    assert(end > close + 2);

    if (end <= close + 3) return false;

    const span = stream.span_of_range(context.tokens, close + 3, end);
    return std.mem.eql(u8, scan.stripped_group(context.span_text(span)), expected);
}

fn equates_a_term_with_itself(
    context: *const Context,
    index: u32,
    first: []const u8,
    close: u32,
) bool {
    if (first.len == 0) return false;
    if (std.mem.findScalar(u8, first, '(') != null) return false;

    const arguments = support.assert_arguments(context, index) orelse return false;
    const end = arguments.end;

    assert(arguments.start < close);
    assert(end <= context.tokens.len);

    if (close + 1 >= end) return false;
    if (!context.tokens[close].is_punctuation(.comma)) return false;

    const group: scylla.Brackets.Range = .{ .first = arguments.start, .last = end - 1 };
    const last = context.pairs.argument_end(close + 1, group);
    if (last <= close + 1) return false;

    const span = stream.span_of_range(context.tokens, close + 1, last);
    return std.mem.eql(u8, first, scan.stripped_group(context.span_text(span)));
}

fn passes_a_number_after(context: *const Context, condition: TokenRange) bool {
    assert(condition.start < condition.end);
    assert(condition.end <= context.tokens.len);

    if (condition.end + 1 >= context.tokens.len) return false;
    if (!context.tokens[condition.end].is_punctuation(.comma)) return false;
    return context.tokens[condition.end + 1].kind == .number;
}

fn never_fails(context: *const Context, condition: TokenRange, text: []const u8) bool {
    assert(condition.start < condition.end);
    assert(condition.end <= context.tokens.len);

    if (scan.word_in(&truths, text)) return true;
    if (!context.conventions.assertions_omit_parentheses) return false;
    if (condition.start + 1 != condition.end) return literal_collection(context, condition);

    const token = context.tokens[condition.start];
    if (token.kind != .string) return false;
    return token.length > 2;
}

fn literal_collection(context: *const Context, condition: TokenRange) bool {
    const open = condition.start;
    const close = condition.end;

    assert(open < close);

    if (close < open + 3) return false;

    const opening = context.tokens[open];
    const bracketed = opening.is_punctuation(.bracket_open);

    if (!bracketed) {
        if (!opening.is_punctuation(.paren_open)) return false;
    }

    const partner = context.pairs.partner_of(open) orelse return false;

    assert(partner > open);

    if (partner != close - 1) return false;

    var depth: u32 = 0;

    for (context.tokens[open + 1 .. close - 1]) |token| {
        if (token.opens_a_group_or_block()) depth += 1;
        if (token.closes_a_group_or_block()) depth -|= 1;
        if (depth > 0) continue;
        if (token.is_keyword(.loop)) return false;
        if (bracketed) continue;
        if (token.is_punctuation(.comma)) return true;
    }

    return bracketed;
}

fn compares_itself(text: []const u8) bool {
    assert(text.len <= std.math.maxInt(u32));

    for (comparison_operators) |operator| {
        const at = scan.find(text, operator) orelse continue;
        const left = scan.trim_ascii(text[0..at]);
        const right = scan.trim_ascii(text[at + operator.len ..]);

        assert(left.len + right.len + operator.len <= text.len);

        if (left.len == 0) return false;
        if (std.mem.findScalar(u8, left, '(') != null) return false;
        return std.mem.eql(u8, left, right);
    }

    return false;
}

fn implements_a_comparison(context: *const Context) bool {
    const tokens = context.tokens;

    for (tokens, 0..) |token, position| {
        if (token.kind != .identifier) continue;
        if (position == 0) continue;

        const name = context.text(token);

        if (scan.word_in(&comparison_methods, name)) {
            const before = context.text(tokens[position - 1]);
            if (std.mem.eql(u8, before, definition_word)) return true;

            continue;
        }

        if (!scan.word_in(&comparison_traits, name)) continue;
        if (implements_on_its_line(context, token)) return true;
    }

    return false;
}

fn implements_on_its_line(context: *const Context, token: Token) bool {
    const line = context.line_span(context.line_of(token.offset));
    const opening = scan.trim_ascii(context.span_text(line));

    assert(token.offset >= line.offset);
    assert(token.end() <= line.end());

    if (opening.len <= implementation_word.len) return false;
    if (!std.mem.startsWith(u8, opening, implementation_word)) return false;

    const follower = opening[implementation_word.len];

    if (follower != '<') {
        if (!std.ascii.isWhitespace(follower)) return false;
    }

    const after = context.source[token.end()..line.end()];
    const rest = std.mem.trimStart(u8, past_generic_arguments(after), scan.ascii_whitespace);
    if (!std.mem.startsWith(u8, rest, implementation_target_word)) return false;
    if (rest.len == implementation_target_word.len) return true;
    return std.ascii.isWhitespace(rest[implementation_target_word.len]);
}

fn past_generic_arguments(text: []const u8) []const u8 {
    const trimmed = std.mem.trimStart(u8, text, scan.ascii_whitespace);
    if (trimmed.len == 0) return trimmed;
    if (trimmed[0] != '<') return trimmed;

    var depth: u32 = 0;

    for (trimmed, 0..) |byte, index| {
        if (byte == '<') depth += 1;
        if (byte != '>') continue;

        if (index > 0) {
            if (trimmed[index - 1] == '-') continue;
        }

        assert(depth > 0);

        depth -= 1;

        if (depth == 0) return trimmed[index + 1 ..];
    }

    return trimmed[trimmed.len..];
}

fn dispatches_to_the_term(context: *const Context, index: u32, condition: TokenRange) bool {
    assert(index < condition.start);
    assert(condition.start < condition.end);
    assert(condition.end <= context.tokens.len);

    if (!context.conventions.comparisons_dispatch_to_methods) return false;
    if (reads_a_member(context, condition)) return true;

    const term = context.tokens[condition.start];
    if (term.kind != .identifier) return false;
    if (std.mem.startsWith(u8, helper_name(context, index), identity_helper_prefix)) return false;

    if (condition.start + 1 < condition.end) {
        if (context.tokens[condition.start + 1].kind != .punctuation) return false;
    }

    return binds_from_a_call(context, term);
}

fn reads_a_member(context: *const Context, condition: TokenRange) bool {
    assert(condition.start < condition.end);
    assert(condition.end <= context.tokens.len);

    const tokens = context.tokens[condition.start..condition.end];

    for (tokens, 0..) |token, position| {
        if (token.is_punctuation(.dot)) return true;
        if (!token.is_punctuation(.bracket_open)) continue;
        if (position == 0) continue;

        const before = tokens[position - 1];
        if (before.kind == .identifier) return true;
        if (before.closes_a_group()) return true;
    }

    return false;
}

fn binds_from_a_call(context: *const Context, term: Token) bool {
    assert(term.kind == .identifier);
    assert(term.end() <= context.source.len);

    const declaring = context.declaration_of(term.offset) orelse return false;
    const declaration = declaring.as_declaration() orelse return false;
    const value = declaration.value() orelse return false;

    assert(value.span().end() <= context.source.len);

    return value.category() == .call;
}

fn expect_count(language: Language, source: []const u8, expected: u32) !void {
    assert(source.len > 0);
    assert(expected <= testing.limits.diagnostic_count_max);

    var findings = try testing.analyze(@This(), language, source);
    defer findings.deinit();

    if (findings.count() != expected) findings.print();

    try std.testing.expectEqual(expected, findings.count());
}

fn expect_one_naming(language: Language, source: []const u8, named: []const u8) !void {
    assert(source.len > 0);
    assert(named.len > 0);

    var findings = try testing.analyze(@This(), language, source);
    defer findings.deinit();

    if (findings.count() != 1) findings.print();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
    try std.testing.expect(std.mem.find(u8, findings.message(0), named) != null);
}

test "a trivial assert is reported" {
    try expect_count(.rust, "fn f() {\n    assert!(true);\n    assert!(value);\n}\n", 1);
}

test "a python bare assert compares a term with itself" {
    try expect_one_naming(.python, "def f(keys):\n    assert keys == keys\n", "compares a term");
}

test "a compared call can answer differently each time" {
    const source = "def f(keys):\n    assert list(keys) == list(keys)\n";

    try testing.expect_quiet(@This(), .python, source);
}

test "a python bare assert keeps its message out of the condition" {
    try expect_count(.python, "def f(keys):\n    assert keys == keys, \"keys differ\"\n", 1);
}

test "a literal followed by values is a helper argument rather than a condition" {
    const source = "func f() {\n\tassert(1, 5, 15, colMatch)\n\tassert(0, 0, 5, " ++
        "tui.NewColorPair(1, 5, tui.AttrUndefined))\n}\n";

    try testing.expect_quiet(@This(), .go, source);
}

test "a literal followed by a message is still reported" {
    try expect_count(.go, "func f() {\n\tassert(1, \"unreachable\")\n}\n", 1);
}

test "a literal with a message is still reported" {
    try expect_count(.rust, "fn f() {\n    assert!(true, \"unreachable\");\n}\n", 1);
}

test "a python literal with a message is still reported" {
    try expect_count(.python, "def f():\n    assert True, \"unreachable\"\n", 1);
}

test "an equality helper comparing a term with itself is reported" {
    try expect_count(.rust, "fn f() {\n    assert_eq!(x, x);\n}\n", 1);
    try expect_count(.zig, "fn f() void {\n    try std.testing.expectEqual(x, x);\n}\n", 1);
    try expect_count(.python, "def f(self):\n    self.assertEqual(x, x)\n", 1);
}

test "an equality helper comparing two terms is quiet" {
    const source = "fn f() {\n    assert_eq!(x, y);\n    assert_ne!(true, x);\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
}

test "a matcher given its own expected value is reported" {
    const source = "test(\"a\", () => {\n    expect(true).toBe(true);\n});\n";

    const live = "test(\"a\", () => {\n    expect(parse(x)).toBe(true);\n    " ++
        "expect(value).toBe(3);\n});\n";

    try expect_count(.javascript, source, 1);
    try testing.expect_quiet(@This(), .javascript, live);
}

test "a strict javascript comparison with itself is reported" {
    const source = "function f(a) {\n    assert(a === a);\n    assert.ok(a > a);\n}\n";

    try expect_count(.javascript, source, 2);
}

test "a python identity with itself is reported" {
    try expect_count(.python, "def f(a):\n    assert a is a\n    assert a is not a\n", 2);
}

test "a python literal that is always truthy is reported" {
    const source = "def f():\n    assert \"s\"\n    assert [1]\n    assert not False\n";

    try expect_count(.python, source, 3);
}

test "a literal that never holds is reported" {
    try expect_one_naming(.rust, "fn f() {\n    assert!(false, \"never\");\n}\n", "cannot hold");
}

test "a literal that never holds on a path that must not run is still reported" {
    const python = "def f(client):\n    try:\n        client.run()\n    except Exception:\n" ++
        "        pass\n    else:\n        assert False\n";

    const javascript = "router.use(function (req, res, next) {\n    assert(false);\n" ++
        "});\napp.get('/bar', function () {\n    assert(0);\n});\n";

    try expect_count(.zig, "fn f() void {\n    comptime assert(false);\n}\n", 1);
    try expect_count(.python, python, 1);
    try expect_count(.javascript, javascript, 2);
}

test "a chained matcher is not a condition" {
    const source = "function f(x) {\n    expect(true).toBe(x);\n}\n";

    try testing.expect_quiet(@This(), .javascript, source);
}

test "a literal that is the whole condition is reported" {
    try expect_count(.go, "func f() {\n\tassert(1)\n}\n", 1);
}

test "a two argument comparison helper is quiet" {
    const source = "fn f() void {\n    try std.testing.expectEqual(true, ready(value));\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "a zig assertion of a bare literal is reported" {
    try expect_count(.zig, "fn f() void {\n    assert(true);\n}\n", 1);
}

test "a python assertion of a bare literal is reported" {
    try expect_count(.python, "def f():\n    assert True\n", 1);
}

test "a first argument that can fail is quiet" {
    try testing.expect_quiet(@This(), .go, "func f() {\n\tassert(ready, 5, 15, colMatch)\n}\n");
}

test "a rust message does not hide the tautology" {
    try expect_count(.rust, "fn f() {\n    assert!(a == a, \"a differs\");\n}\n", 1);
}

test "a rust tautology is reported" {
    try expect_count(.rust, "fn f() {\n    assert!(a == a);\n}\n", 1);
}

test "a self comparison checks the comparison the file implements" {
    const rust = "struct Ordered(f32);\n\nimpl PartialEq for Ordered {\n    fn eq(&self, other: " ++
        "&Self) -> bool {\n        self.0.is_nan() && other.0.is_nan()\n    }\n}\n\n" ++
        "impl PartialOrd<f32> for Ordered {\n}\n\nfn f() {\n    assert_eq!(NAN, NAN);\n" ++
        "    assert!(NAN <= NAN);\n    assert!(true);\n}\n";

    const python = "class Ordered:\n    def __eq__(self, other):\n        return True\n\n\n" ++
        "def f(a):\n    assert a == a\n    assert True\n";

    try expect_count(.rust, rust, 1);
    try expect_count(.python, python, 1);
}

test "a derived comparison leaves a self comparison reported" {
    const source = "#[derive(PartialEq, PartialOrd)]\nstruct Ordered(f32);\n\nfn f() {\n" ++
        "    assert_eq!(a, a);\n    assert!(a <= a);\n}\n";

    try expect_count(.rust, source, 2);
}

test "a python term that reads a member runs code to compare" {
    const source = "def f(self, link, items, box):\n" ++
        "    self.assertIs(link.content_object, link.content_object)\n" ++
        "    self.assertIs(items[0], items[0])\n    assert box.value == box.value\n" ++
        "    self.assertIs(link, link)\n";

    try expect_count(.python, source, 1);
}

test "a python name bound from a call compares through its own equality" {
    const source = "def f(self):\n    constraint = UniqueConstraint(fields=[\"a\"])\n" ++
        "    count = 1\n    self.assertEqual(constraint, constraint)\n" ++
        "    assert constraint == constraint\n    self.assertEqual(count, count)\n" ++
        "    self.assertIs(constraint, constraint)\n";

    try expect_count(.python, source, 2);
}

test "a comprehension is no literal collection" {
    const source = "def f(self, statements):\n" ++
        "    self.assertFalse([sql for sql in statements])\n" ++
        "    self.assertFalse((sql for sql in statements))\n    self.assertFalse([1, 2])\n";

    try expect_count(.python, source, 1);
}

test "a zig unreachable is skipped" {
    const source = "fn f(value: u32) u32 {\n    return value orelse unreachable;\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
}
