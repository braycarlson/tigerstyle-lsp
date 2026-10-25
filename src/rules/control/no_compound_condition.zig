const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const control = @import("../control.zig");
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
            .standard = "TigerStyle",
            .text = "\"Compound conditions that evaluate multiple booleans make it difficult " ++
                "for the reader to verify that all cases are handled. Split compound conditions " ++
                "into simple conditions using nested `if/else` branches. Split complex " ++
                "`else if` chains into `else { if { } }` trees.\"",
        },
    },
    .code = "TS023",
    .default_on = true,
    .description = "A condition evaluates one boolean, because a compound condition hides which " ++
        "cases are handled; split it into nested branches.",
    .explanation = "",
    .fix_title = "",
    .fixable = .sometimes,
    .group = .stable,
    .name = "no-compound-condition",
    .severity = .warning,
    .summary = "Split a compound condition into simple conditions using nested branches",
    .url = "",
};

const brace_words = [_][]const u8{ "{", "}" };
const case_word = "case";
const chain_keyword = "elif";
const for_word = "for";
const header_scan_max: u32 = 512;
const implementation_word = "impl";
const iteration_words = [_][]const u8{ "in", "of", "range" };

pub fn run(context: *const Context, sink: *Sink) void {
    for (0..context.tokens.len) |position| {
        const index: u32 = @intCast(position);
        if (!opens_a_condition(context, index)) continue;
        if (control.opens_a_do_loop(context, index)) continue;

        const condition = label_of(context, index, control.condition_of(context, index));
        if (condition.start >= condition.end) continue;

        const inside = group_inside(context, condition);
        const operator = control.compound_operator(context, inside) orelse continue;

        assert(operator >= condition.start);
        assert(operator < condition.end);

        sink.report(
            support.literal_span(context, condition.start),
            "the condition combines booleans; split it into nested branches",
        );
    }
}

fn label_of(context: *const Context, index: u32, condition: TokenRange) TokenRange {
    assert(index < context.tokens.len);
    assert(condition.end <= context.tokens.len);

    if (!std.mem.eql(u8, context.text(context.tokens[index]), case_word)) return condition;

    const colon = control.top_level_punctuation(context, condition, .colon) orelse {
        return condition;
    };

    assert(colon >= condition.start);

    return .{ .end = colon, .start = condition.start };
}

fn opens_a_condition(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);

    const token = context.tokens[index];

    const keyword = switch (token.kind) {
        .keyword => |keyword| keyword,
        else => return false,
    };

    assert(token.kind == .keyword);

    const text = context.text(token);

    return switch (keyword) {
        .branch => true,
        .loop => opens_a_loop(context, index),
        .branch_else => std.mem.eql(u8, text, chain_keyword),
        .match, .other => std.mem.eql(u8, text, case_word),
        else => false,
    };
}

fn opens_a_loop(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);
    assert(context.tokens[index].is_keyword(.loop));

    if (walks_a_collection(context, index)) return false;
    return !names_a_type(context, index);
}

fn names_a_type(context: *const Context, index: u32) bool {
    const tokens = context.tokens;

    assert(index < tokens.len);

    if (context.front.language != .rust) return false;
    if (!std.mem.eql(u8, context.text(tokens[index]), for_word)) return false;

    if (index + 1 < tokens.len) {
        if (tokens[index + 1].is_punctuation(.less)) return true;
    }

    var cursor = index;

    for (0..@min(index, header_scan_max)) |_| {
        cursor -= 1;

        const token = tokens[cursor];
        const text = context.text(token);

        if (token.kind == .block_start) return false;
        if (token.kind == .block_end) return false;
        if (token.is_punctuation(.semicolon)) return false;
        if (scan.word_in(&brace_words, text)) return false;
        if (std.mem.eql(u8, text, implementation_word)) return true;
    }

    return false;
}

fn walks_a_collection(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);

    const token = context.tokens[index];

    assert(token.is_keyword(.loop));

    if (!std.mem.eql(u8, context.text(token), for_word)) return false;
    if (control.clauses(context, index) != null) return false;

    const header = control.header_range(context, index);

    assert(header.start <= header.end);
    assert(header.end <= context.tokens.len);

    var depth: u32 = 0;

    for (context.tokens[header.start..header.end]) |held| {
        if (held.opens_a_group_or_block()) depth += 1;
        if (held.closes_a_group_or_block()) depth -|= 1;
        if (depth > 0) continue;
        if (!held.is_keyword(.other)) continue;
        if (scan.word_in(&iteration_words, context.text(held))) return true;
    }

    return false;
}

fn group_inside(context: *const Context, condition: TokenRange) TokenRange {
    assert(condition.start < condition.end);
    assert(condition.end <= context.tokens.len);

    var inside = condition;

    for (0..condition.end - condition.start) |_| {
        const group = group_wrapping(context, inside) orelse break;

        assert(group.start > inside.start);
        assert(group.end < inside.end);

        inside = group;
    }

    assert(inside.start >= condition.start);
    assert(inside.end <= condition.end);

    return inside;
}

fn group_wrapping(context: *const Context, range: TokenRange) ?TokenRange {
    assert(range.start <= range.end);
    assert(range.end <= context.tokens.len);

    const closed = stream.significant_previous(context.tokens, range.end) orelse return null;
    if (closed < range.start) return null;
    if (!context.tokens[closed].is_punctuation(.paren_close)) return null;

    const open = context.pairs.partner_of(closed) orelse return null;

    assert(open < closed);

    if (open < range.start) return null;

    for (context.tokens[range.start..open]) |token| {
        if (!Token.is_significant(token.kind)) continue;
        if (!token.is_punctuation(.bang)) return null;
    }

    return .{ .end = closed, .start = open + 1 };
}

fn expect_count(language: Language, source: []const u8, expected: u32) !void {
    assert(source.len > 0);
    assert(expected <= testing.limits.diagnostic_count_max);

    var findings = try testing.analyze(@This(), language, source);
    defer findings.deinit();

    if (findings.count() != expected) findings.print();

    try std.testing.expectEqual(expected, findings.count());
}

test "a compound condition is reported once" {
    try expect_count(.rust, "fn f() {\n    if a && b || c {\n    }\n}\n", 1);
}

test "a python mixed condition is reported" {
    try expect_count(.python, "def f():\n    if a and b or c:\n        pass\n", 1);
}

test "a single operator condition is reported" {
    try expect_count(.python, "def f():\n    if a and b:\n        pass\n", 1);
}

test "a parenthesized inner half still leaves a compound condition" {
    try expect_count(.rust, "fn f() {\n    if (a && b) || c {\n    }\n}\n", 1);
}

test "a simple condition is quiet" {
    const source = "fn f() {\n    if a {\n    }\n\n    while b {\n    }\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
}

test "a conjunction inside a call belongs to the call" {
    try testing.expect_quiet(@This(), .rust, "fn f() {\n    if any(a && b) {\n    }\n}\n");
}

test "a braceless javascript condition is scanned" {
    const source = "function f(a, b) {\n    if (a && b) return 1;\n    return 0;\n}\n";

    try expect_count(.javascript, source, 1);
}

test "a zig expression condition is scanned" {
    const source = "fn f(a: bool, b: bool) u32 {\n    const v = if (a and b) 1 else 2;\n" ++
        "return v;\n}\n";

    try expect_count(.zig, source, 1);
}

test "an odin case label ends at its colon" {
    const source = "package p\n\nf :: proc(op: Op) -> bool {\n\tswitch op.kind {\n" ++
        "\tcase .A, .B:\n\t\treturn op.kind == .REGISTER && op.reg > 0\n" ++
        "\tcase .C:\n\t\treturn false\n\t}\n\treturn true\n}\n" ++
        "\ng :: proc(a: bool, b: bool) -> bool {\n\tswitch {\n\tcase a && b:\n" ++
        "\t\treturn true\n\t}\n\treturn false\n}\n";

    try testing.expect_anchors(@This(), .odin, source, &.{.{ 15, 7 }});
}

test "a go case label is a condition" {
    const source = "package main\n\nfunc f(a bool, b bool) {\n\tswitch {\n\tcase a && b:\n" ++
        "\t\treturn\n\t}\n}\n";

    try expect_count(.go, source, 1);
}

test "a matches guard ends at the closing parenthesis" {
    const simple = "fn work(kind: Kind, ordered: bool, other: bool) -> bool {\n    let same = " ++
        "matches!(\n        kind,\n        Kind::List { .. } if ordered\n    );\n    " ++
        "let next = other || ordered;\n\n    same && next\n}\n";

    const compound = "fn work(kind: Kind, ordered: bool, other: bool) -> bool {\n    " ++
        "matches!(kind, Kind::List { .. } if ordered || other)\n}\n";

    try testing.expect_quiet(@This(), .rust, simple);
    try expect_count(.rust, compound, 1);
}

test "a rust match guard is a condition" {
    const source = "fn f(v: Option<u32>, a: bool, b: bool) {\n    match v {\n" ++
        "Some(x) if a && b => g(x),\n        _ => {}\n    }\n}\n";

    try expect_count(.rust, source, 1);
}

test "a python elif is a condition" {
    const source = "def f(a, b, c):\n    if c:\n        pass\n    elif a or b:\n        pass\n";

    try expect_count(.python, source, 1);
}

test "a python single line branch body is not its condition" {
    try testing.expect_quiet(@This(), .python, "def f(a, x, y):\n    if a: return x or y\n");
}

test "a condition opening with a format string spans the whole string" {
    const source = "def f(idx, alias, consecutive):\n    if f'%{idx}' in alias and not " ++
        "consecutive:\n        pass\n";

    try testing.expect_spans(@This(), .python, source, &.{.{ 39, 48 }});
}

test "a python comprehension filter is reported once" {
    const source = "def f(items, a, b):\n    return [x for x in items if a and b]\n";

    try expect_count(.python, source, 1);
}

test "a for that walks a collection holds no condition" {
    const python = "def f(a, b):\n    for x in a or b:\n        pass\n";
    const javascript = "function f(a, b) {\n    for (const x of a || b) {\n    }\n}\n";

    try testing.expect_quiet(@This(), .python, python);
    try testing.expect_quiet(@This(), .javascript, javascript);
}

test "a three clause for still reads its middle clause" {
    const source = "function f(n, ok) {\n    for (let i = 0; i < n && ok; i++) {\n    }\n}\n";

    try expect_count(.javascript, source, 1);
}

test "a negated group is read inside" {
    const python = "def f(a, b):\n    if not (a and b):\n        pass\n";
    const rust = "fn f() {\n    if !(a && b) {\n    }\n}\n";

    try expect_count(.python, python, 1);
    try expect_count(.rust, rust, 1);
}

test "a doubled group is read inside" {
    try expect_count(.python, "def f(a, b):\n    if ((a or b)):\n        pass\n", 1);
}

test "a negated group that does not span the condition stays opaque" {
    const source = "def f(text):\n    if not (text or '').strip():\n        pass\n";

    try testing.expect_quiet(@This(), .python, source);
}

test "a negated call keeps its arguments" {
    const source = "def f(a, b):\n    if not g(a and b):\n        pass\n";

    try testing.expect_quiet(@This(), .python, source);
}

test "a rust for inside a type is no loop header" {
    const sources = [_][]const u8{
        "impl<P> Factory for &&&Wrapper<P> {\n    fn build(&self) {}\n}\n",
        "unsafe impl<T> Send for &&Held<T> {}\n",
        "fn apply<F>(f: F)\nwhere\n    F: for<'a> Fn(&'a u8) -> &&'a u8,\n{\n}\n",
    };

    for (sources) |source| {
        try testing.expect_quiet(@This(), .rust, source);
    }
}

test "a condition inside a trait implementation still reports" {
    const source = "impl Factory for &&Wrapper {\n    fn build(&self, a: bool, b: bool) {\n" ++
        "        if a && b {\n        }\n    }\n}\n";

    try expect_count(.rust, source, 1);
}
