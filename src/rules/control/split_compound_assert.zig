const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const stream = @import("../../stream.zig");
const support = @import("../support.zig");
const testing = @import("../testing.zig");
const Context = @import("../context.zig");
const Language = scylla.Language;
const Rule = scylla.rule.Rule;
const Sink = scylla.rule.Sink;
const TokenRange = Context.TokenRange;

pub const rule: Rule = .{
    .citations = &.{
        .{
            .standard = "TigerStyle",
            .text = "\"Split compound assertions: prefer `assert(a); assert(b);` over " ++
                "`assert(a and b);`. The former is simpler to read, and provides more precise " ++
                "information if the condition fails.\"",
        },
    },
    .code = "TS024",
    .default_on = true,
    .description = "A compound assertion splits into one assertion per condition, so a failure " ++
        "reports which half broke.",
    .explanation = "",
    .fix_title = "",
    .fixable = .sometimes,
    .group = .stable,
    .name = "split-compound-assert",
    .severity = .warning,
    .summary = "Prefer `assert(a); assert(b);` over `assert(a and b);`",
    .url = "",
};

const condition_depth_max: u32 = 32;

pub fn run(context: *const Context, sink: *Sink) void {
    for (context.tokens, 0..) |token, position| {
        const index: u32 = @intCast(position);

        if (!token.is_keyword(.assert)) continue;

        const condition = support.assert_condition(context, index) orelse continue;
        if (!splits_into_conjuncts(context, condition)) continue;

        const head = stream.line_start_of_token(context.tokens, context.source, index);

        assert(head <= index);

        sink.report(
            context.tokens[head].span(),
            "the assertion is compound; write one assertion for each condition",
        );
    }
}

fn splits_into_conjuncts(context: *const Context, condition: TokenRange) bool {
    const inner = peeled(context, condition);

    assert(inner.start <= inner.end);
    assert(inner.end <= context.tokens.len);

    var conjunction = false;
    var depth: u32 = 0;

    for (context.tokens[inner.start..inner.end]) |candidate| {
        if (candidate.opens_a_group_or_block()) {
            depth += 1;

            continue;
        }

        if (candidate.closes_a_group_or_block()) {
            depth -|= 1;

            continue;
        }

        if (depth > 0) continue;
        if (candidate.is_punctuation(.bar_double)) return false;

        if (candidate.is_punctuation(.ampersand_double)) conjunction = true;
    }

    return conjunction;
}

fn peeled(context: *const Context, condition: TokenRange) TokenRange {
    assert(condition.start <= condition.end);
    assert(condition.end <= context.tokens.len);

    var start = condition.start;
    var end = condition.end;

    for (0..condition_depth_max) |_| {
        if (start + 2 > end) break;
        if (!context.tokens[start].is_punctuation(.paren_open)) break;

        const partner = context.pairs.partner_of(start) orelse break;
        if (partner != end - 1) break;

        start += 1;
        end -= 1;
    }

    assert(start >= condition.start);
    assert(start <= end);

    return .{ .end = end, .start = start };
}

fn expect_count(language: Language, source: []const u8, expected: u32) !void {
    assert(source.len > 0);
    assert(expected <= testing.limits.diagnostic_count_max);

    var findings = try testing.analyze(@This(), language, source);
    defer findings.deinit();

    if (findings.count() != expected) findings.print();

    try std.testing.expectEqual(expected, findings.count());
}

test "a closure body conjunction does not split the assert" {
    const source = "fn f() {\n    assert!(items.iter().all(|item| {\n" ++
        "item.a > 0 && item.b > 0\n    }));\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
}

test "a negated conjunction does not split the assert" {
    const source = "fn f() void {\n    assert(!(a == 1 and b == 2));\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "a nested disjunction does not veto the split" {
    try expect_count(.zig, "fn f() void {\n    assert(a and (b or c));\n}\n", 1);
}

test "a top level disjunction vetoes the split" {
    try testing.expect_quiet(@This(), .zig, "fn f() void {\n    assert((a and b) or c);\n}\n");
}

test "a python leading group is not the whole condition" {
    try testing.expect_quiet(@This(), .python, "def f(a, b, c):\n    assert (a and b) or c\n");
}

test "a python conjunction of groups splits" {
    try expect_count(.python, "def f(a, b):\n    assert (a) and (b)\n", 1);
}

test "a go testify condition splits" {
    const source = "package main\n\nfunc f(t *testing.T) {\n\trequire.True(t, a && b)\n" ++
        "\tassert.True(t, a && b)\n}\n";

    try expect_count(.go, source, 2);
}

test "a node assert condition splits" {
    try expect_count(.javascript, "function f(a, b) {\n    assert.ok(a && b);\n}\n", 1);
}

test "a negated conjunct still splits the assert" {
    const source = "fn f() void {\n    assert(!a and b);\n    assert(a and !b);\n}\n";

    try expect_count(.zig, source, 2);
}

test "a python not is not a macro bang" {
    try expect_count(.python, "def f(a, b):\n    assert a and not b\n", 1);
}

test "a parenthesis free python assert splits" {
    try expect_count(.python, "def f(value):\n    assert value.args and value.text\n", 1);
}

test "a compound assert is reported" {
    try expect_count(.rust, "fn f() {\n    assert!(a && b);\n}\n", 1);
}
