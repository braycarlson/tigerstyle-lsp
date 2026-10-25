const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const control = @import("../control.zig");
const scan = @import("../../scan.zig");
const testing = @import("../testing.zig");
const Context = @import("../context.zig");
const Language = scylla.Language;
const Rule = scylla.rule.Rule;
const Sink = scylla.rule.Sink;
const Token = scylla.Token;
const TokenRange = Context.TokenRange;
const words_module = @import("../../words.zig");

pub const rule: Rule = .{
    .citations = &.{
        .{
            .standard = "TigerStyle",
            .text = "\"Negations are not easy! State invariants positively. When working with " ++
                "lengths and indexes, this form is easy to get right (and understand) [...] " ++
                "This form is harder, and also goes against the grain of how `index` would " ++
                "typically be compared to `length`, for example, in a loop condition.\"",
        },
    },
    .code = "TS038",
    .default_on = true,
    .description = "A branch that negates its condition and carries an else reads backwards; " ++
        "the positive case belongs first.",
    .explanation = "",
    .fix_title = "",
    .fixable = .sometimes,
    .group = .stable,
    .name = "positive-invariants",
    .severity = .information,
    .summary = "State an invariant positively",
    .url = "",
};

const chain_keyword = "elif";
const identity_word = "is";
const measure_words = [_][]const u8{ "cap", "capacity", "count", "len", "length", "size" };
const membership_word = "in";
const negated_membership_word = "not_in";

pub fn run(context: *const Context, sink: *Sink) void {
    for (context.tokens, 0..) |token, position| {
        const index: u32 = @intCast(position);

        if (!token.is_keyword(.branch)) continue;

        const condition = control.condition_of(context, index);
        if (condition.start >= condition.end) continue;

        const negation = negation_in(context, condition) orelse continue;

        assert(negation >= condition.start);
        assert(negation < condition.end);

        if (!branch_has_else(context, index)) continue;
        if (control.compound_operator(context, condition) != null) continue;

        sink.report(
            context.tokens[negation].span(),
            "the branch states its condition negatively and carries an else; swap the arms",
        );
    }
}

fn negation_in(context: *const Context, condition: TokenRange) ?u32 {
    assert(condition.start < condition.end);
    assert(condition.end <= context.tokens.len);

    var depth: u32 = 0;

    for (context.tokens[condition.start..condition.end], condition.start..) |token, position| {
        const offset: u32 = @intCast(position);

        if (token.opens_a_group_or_block()) {
            depth += 1;

            continue;
        }

        if (token.closes_a_group_or_block()) {
            depth -|= 1;

            continue;
        }

        if (depth > 0) continue;

        if (token.is_punctuation(.bang)) {
            if (negates(context, condition, offset)) return offset;

            continue;
        }

        if (inverts(context, condition, token)) return offset;
    }

    return null;
}

fn negates(context: *const Context, condition: TokenRange, offset: u32) bool {
    assert(offset >= condition.start);
    assert(offset < condition.end);

    if (invokes_a_macro(context, offset)) return false;
    if (offset == condition.start) return true;
    return negates_membership(context, offset, condition.end);
}

fn inverts(context: *const Context, condition: TokenRange, token: Token) bool {
    assert(condition.start < condition.end);
    assert(condition.end <= context.tokens.len);

    switch (token.kind) {
        .keyword => |keyword| {
            if (keyword != .other) return false;
            return std.mem.eql(u8, context.text(token), negated_membership_word);
        },
        .punctuation => |punctuation| switch (punctuation) {
            .not_equal => return true,
            .greater_equal, .less_equal => return compares_a_length(context, condition),
            else => return false,
        },
        else => return false,
    }
}

fn compares_a_length(context: *const Context, condition: TokenRange) bool {
    assert(condition.start <= condition.end);
    assert(condition.end <= context.tokens.len);

    for (context.tokens[condition.start..condition.end]) |token| {
        if (token.kind != .identifier) continue;
        if (names_a_measure(context.text(token))) return true;
    }

    return false;
}

fn names_a_measure(name: []const u8) bool {
    assert(name.len > 0);

    var parts = words_module.word_parts(name);

    for (0..name.len) |_| {
        const part = parts.next() orelse return false;

        assert(part.len > 0);

        if (scan.word_in(&measure_words, part)) return true;
    }

    return false;
}

fn invokes_a_macro(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);

    if (!context.conventions.macros_invoke_with_bang) return false;
    if (index == 0) return false;

    assert(index > 0);

    const before = context.tokens[index - 1];
    if (before.kind != .identifier) return false;
    return before.end() == context.tokens[index].offset;
}

fn negates_membership(context: *const Context, index: u32, end: u32) bool {
    assert(index < end);
    assert(end <= context.tokens.len);

    if (index > 0) {
        if (names_a_word(context, index - 1, identity_word)) return true;
    }

    if (index + 1 >= end) return false;
    return names_a_word(context, index + 1, membership_word);
}

fn names_a_word(context: *const Context, index: u32, word: []const u8) bool {
    assert(index < context.tokens.len);
    assert(word.len > 0);

    const token = context.tokens[index];
    if (!token.is_keyword(.other)) return false;
    return std.mem.eql(u8, context.text(token), word);
}

fn branch_has_else(context: *const Context, index: u32) bool {
    const frame = control.keyword_frame(context, index) orelse return false;
    const end = frame.end orelse return false;

    assert(end < context.tokens.len);
    assert(end >= frame.start);

    for (context.tokens[end + 1 ..], end + 1..) |token, offset| {
        if (token.kind == .newline) continue;
        if (!token.is_keyword(.branch_else)) return false;
        if (std.mem.eql(u8, context.text(token), chain_keyword)) return false;
        if (offset + 1 >= context.tokens.len) return true;
        return !context.tokens[offset + 1].is_keyword(.branch);
    }

    return false;
}

fn expect_count(language: Language, source: []const u8, expected: u32) !void {
    assert(source.len > 0);
    assert(expected <= testing.limits.diagnostic_count_max);

    var findings = try testing.analyze(@This(), language, source);
    defer findings.deinit();

    if (findings.count() != expected) findings.print();

    try std.testing.expectEqual(expected, findings.count());
}

test "an elif link is not a terminal else" {
    const source = "def f(first, second):\n    if not first:\n        g()\n" ++
        "elif not second:\n        h()\n";

    try testing.expect_quiet(@This(), .python, source);
}

test "a negated branch with a terminal else is reported" {
    const source = "def f(first):\n    if not first:\n        g()\n    else:\n        h()\n";

    try expect_count(.python, source, 1);
}

test "a negated condition with an else is reported" {
    const source = "fn f() {\n    if !ready {\n        wait();\n    } else {\n" ++
        "work();\n    }\n}\n";

    try expect_count(.rust, source, 1);
}

test "a negated guard is quiet" {
    const source = "fn f() {\n    if !ready {\n        return;\n    }\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
}

test "a bound comparison without a length is positive" {
    const source = "fn f(count: u32, limit: u32) u32 {\n    if (count <= limit) {\n        " ++
        "return 1;\n    } else {\n        return 2;\n    }\n}\n";

    const quiet = "fn f(a: u32, b: u32) u32 {\n    if (a <= b) {\n        return 1;\n    } " ++
        "else {\n        return 2;\n    }\n}\n";

    try expect_count(.zig, source, 1);
    try testing.expect_quiet(@This(), .zig, quiet);
}

test "an inverted comparison with an else is reported" {
    const source = "fn f(index: u32, length: u32) void {\n    if (index >= length) {\n" ++
        "work();\n    } else {\n        rest();\n    }\n}\n";

    try expect_count(.zig, source, 1);
}

test "an inequality with an else is reported" {
    const source = "fn f(a: u32, b: u32) {\n    if a != b {\n        work();\n    } else {\n" ++
        "rest();\n    }\n}\n";

    try expect_count(.rust, source, 1);
}

test "a negated group outside rust is a negation" {
    const source = "package main\n\nfunc f(a bool) {\n\tif !(a) {\n\t\twork()\n\t} else {\n" ++
        "\t\trest()\n\t}\n}\n";

    try expect_count(.go, source, 1);
}

test "a rust macro call in a condition is not a negation" {
    const source = "fn f() {\n    if matches!(x, Some(_)) {\n        work();\n    } else {\n" ++
        "rest();\n    }\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
}

test "a python negated membership with an else is reported" {
    const source = "def f(a, b):\n    if a not in b:\n        work()\n    else:\n        rest()" ++
        "\n    if a is not b:\n        work()\n    else:\n        rest()\n";

    try expect_count(.python, source, 2);
}

test "a macro assert is not a negation" {
    try testing.expect_quiet(@This(), .rust, "fn f() {\n    assert!(ready);\n}\n");
}

test "a positive condition is quiet" {
    try testing.expect_quiet(@This(), .rust, "fn f() {\n    if index < length {\n    }\n}\n");
}
