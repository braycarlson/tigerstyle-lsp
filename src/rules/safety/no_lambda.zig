const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const scan = @import("../../scan.zig");
const stream = @import("../../stream.zig");
const testing = @import("../testing.zig");
const Context = @import("../context.zig");
const Language = scylla.Language;
const Rule = scylla.rule.Rule;
const Sink = scylla.rule.Sink;
const Token = scylla.Token;

pub const rule: Rule = .{
    .citations = &.{
        .{
            .standard = "TigerStyle",
            .text = "\"Get the nouns and verbs just right. Great names are the essence of great " ++
                "code, they capture what a thing is or does, and provide a crisp, intuitive " ++
                "mental model.\"",
        },
        .{
            .standard = "TigerStyle",
            .text = "\"All control flow should be handled by one function, the rest shouldn't " ++
                "care about control flow at all. In other words, push ifs up and fors down.\"",
        },
    },
    .code = "TS015",
    .default_on = true,
    .description = "A named function carries a name in the traceback, where a lambda carries none.",
    .explanation = "",
    .fix_title = "",
    .fixable = .sometimes,
    .group = .stable,
    .name = "no-lambda",
    .severity = .warning,
    .summary = "An anonymous function cannot be named or tested; use a named one",
    .url = "",
};

const arm_arrow = "=>";
const async_word = "async";
const deferring_words = [_][]const u8{ "defer", "go" };
const procedure_binding = ":=";
const unnamed_message = "the expression is an unnamed function";

pub fn run(context: *const Context, sink: *Sink) void {
    const tokens = context.tokens;

    assert(tokens.len <= std.math.maxInt(u32));

    for (tokens, 0..) |token, position| {
        const index: u32 = @intCast(position);

        if (opens_an_arrow(context, index)) {
            arrow_report(context, sink, index);

            continue;
        }

        if (!token.is_keyword(.lambda)) {
            if (!binds_a_procedure_literal(context, index)) continue;
        }

        if (!carries_a_body(context, index)) continue;
        if (inside_a_signature(context, token.offset)) continue;
        if (passed_as_an_argument(context, index)) continue;
        if (invoked_immediately(context, index)) continue;

        const start = stream.modifier_start(
            context.pairs,
            tokens,
            context.source,
            index,
            stream.modifier_count_max,
        );

        assert(start <= index);

        if (invoked_in_parentheses(context, start)) continue;

        sink.report(tokens[start].span(), unnamed_message);
    }
}

fn opens_an_arrow(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);

    const token = context.tokens[index];

    if (!context.conventions.arrows_open_lambdas) return false;
    if (!token.is_punctuation(.other)) return false;

    const arrow = std.mem.eql(u8, context.text(token), arm_arrow);

    if (arrow) assert(token.length == arm_arrow.len);

    return arrow;
}

fn binds_a_procedure_literal(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);

    if (!context.tokens[index].is_keyword(.function)) return false;
    if (index == 0) return false;

    const before = context.tokens[index - 1];
    if (!before.is_punctuation(.assign_declare)) return false;

    const binds = std.mem.eql(u8, context.text(before), procedure_binding);

    if (binds) assert(before.length == procedure_binding.len);

    return binds;
}

fn arrow_report(context: *const Context, sink: *Sink, arrow: u32) void {
    assert(arrow < context.tokens.len);

    const start = arrow_start(context, arrow) orelse return;
    const token = context.tokens[start];

    assert(start < arrow);

    if (inside_a_signature(context, token.offset)) return;
    if (passed_as_an_argument(context, start)) return;
    if (invoked_in_parentheses(context, start)) return;

    sink.report(token.span(), unnamed_message);
}

fn arrow_start(context: *const Context, arrow: u32) ?u32 {
    assert(arrow < context.tokens.len);

    if (arrow == 0) return null;

    const previous = arrow - 1;
    const token = context.tokens[previous];

    const start = start: {
        if (token.kind == .identifier) break :start previous;
        if (!token.is_punctuation(.paren_close)) return null;

        break :start context.pairs.open_of(previous) orelse return null;
    };

    assert(start <= previous);

    if (start == 0) return start;

    const asynchronous = std.mem.eql(u8, context.text(context.tokens[start - 1]), async_word);
    return if (asynchronous) start - 1 else start;
}

fn invoked_in_parentheses(context: *const Context, start: u32) bool {
    assert(start < context.tokens.len);

    if (start == 0) return false;

    const before = start - 1;
    if (!context.tokens[before].is_punctuation(.paren_open)) return false;

    const close = context.pairs.partner_of(before) orelse return false;

    assert(close > before);

    if (close + 1 >= context.tokens.len) return false;
    return context.tokens[close + 1].is_punctuation(.paren_open);
}

fn carries_a_body(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);

    const tokens = context.tokens;
    if (index + 1 >= tokens.len) return true;
    if (!tokens[index + 1].is_punctuation(.paren_open)) return true;

    if (index > 0) {
        if (tokens[index - 1].is_punctuation(.bracket_close)) return false;
    }

    const arguments = context.pairs.arguments_of(index) orelse return true;

    assert(arguments.first < arguments.last);

    var depth: u32 = 0;

    for (tokens[arguments.last + 1 ..]) |token| {
        if (token.kind == .block_start) return depth == 0;

        if (token.opens_a_group()) {
            depth += 1;
        } else if (token.closes_a_group()) {
            if (depth == 0) return false;

            depth -= 1;
        } else if (depth == 0) {
            if (stops_a_signature(token)) return false;
        } else {}
    }

    return false;
}

fn invoked_immediately(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);

    const tokens = context.tokens;
    if (index + 1 >= tokens.len) return false;
    if (!tokens[index + 1].is_punctuation(.paren_open)) return false;

    const arguments = context.pairs.arguments_of(index) orelse return false;

    assert(arguments.first < arguments.last);

    var depth: u32 = 0;

    for (tokens[arguments.last + 1 ..], arguments.last + 1..) |token, offset| {
        if (depth == 0) {
            if (token.is_punctuation(.semicolon)) return false;
        }

        if (token.kind == .block_start) depth += 1;
        if (token.kind != .block_end) continue;
        if (depth == 0) return false;

        depth -= 1;

        if (depth > 0) continue;
        if (offset + 1 >= tokens.len) return false;
        return tokens[offset + 1].is_punctuation(.paren_open);
    }

    return false;
}

fn stops_a_signature(token: Token) bool {
    const stops = switch (token.kind) {
        .block_end, .newline => true,
        .punctuation => |punctuation| switch (punctuation) {
            .comma, .semicolon => true,
            else => false,
        },
        else => false,
    };

    if (stops) assert(token.kind != .identifier);
    if (stops) assert(!token.opens_a_group_or_block());

    return stops;
}

fn inside_a_signature(context: *const Context, offset: u32) bool {
    assert(offset <= context.source.len);

    if (context.view_at(.lambda, offset)) |lambda| {
        assert(lambda.category() == .lambda);

        return false;
    }

    if (context.inside(.parameters, offset)) return true;
    return context.inside(.type, offset);
}

fn passed_as_an_argument(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);

    const tokens = context.tokens;

    if (index > 0) {
        if (scan.word_in(&deferring_words, context.text(tokens[index - 1]))) return true;
    }

    var depth: u32 = 0;
    var offset = index;

    for (0..index) |_| {
        offset -= 1;

        const token = tokens[offset];

        if (token.closes_a_group_or_block()) {
            depth += 1;

            continue;
        }

        if (token.opens_a_group_or_block()) {
            if (depth > 0) {
                depth -= 1;

                continue;
            }

            if (token.kind == .block_start) return false;
            if (offset == 0) return false;
            if (calls(tokens[offset - 1])) return true;
            if (!wraps_a_lambda_argument(context, offset, index)) return false;

            continue;
        }

        if (depth == 0) {
            if (stops_an_argument(token)) return false;
        }
    }

    assert(offset == 0);

    return false;
}

fn wraps_a_lambda_argument(context: *const Context, open: u32, index: u32) bool {
    assert(open < index);
    assert(index < context.tokens.len);

    const tokens = context.tokens;

    if (open == 0) return false;
    if (!tokens[open].is_punctuation(.paren_open)) return false;
    if (!opens_an_argument(tokens[open - 1])) return false;

    const close = context.pairs.partner_of(open) orelse return false;

    assert(close > open);

    if (close + 1 >= tokens.len) return false;
    if (!closes_an_argument(tokens[close + 1])) return false;

    const start = stream.modifier_start(
        context.pairs,
        tokens,
        context.source,
        index,
        stream.modifier_count_max,
    );

    const lambda = context.view_at(.lambda, tokens[start].offset) orelse
        context.view_at(.lambda, tokens[index].offset) orelse return false;

    const end = context.lexer_index_from(lambda.span().end());

    assert(start <= index);

    if (start != open + 1) return false;
    return end == close;
}

fn opens_an_argument(token: Token) bool {
    if (token.is_punctuation(.comma)) return true;
    return token.is_punctuation(.paren_open);
}

fn closes_an_argument(token: Token) bool {
    if (token.is_punctuation(.comma)) return true;
    return token.is_punctuation(.paren_close);
}

fn stops_an_argument(token: Token) bool {
    const stops = switch (token.kind) {
        .newline => true,
        .punctuation => |punctuation| punctuation == .semicolon,
        else => false,
    };

    if (stops) assert(token.kind != .identifier);
    if (stops) assert(!token.opens_a_group_or_block());

    return stops;
}

fn calls(token: Token) bool {
    const called = switch (token.kind) {
        .identifier => true,
        .keyword => |keyword| keyword == .assert,
        .punctuation => |punctuation| switch (punctuation) {
            .bang, .bracket_close, .greater, .paren_close => true,
            else => false,
        },
        else => false,
    };

    if (called) assert(token.kind != .newline);
    if (called) assert(!token.opens_a_group_or_block());

    return called;
}

fn expect_count(language: Language, source: []const u8, expected: u32) !void {
    assert(source.len > 0);
    assert(expected <= testing.limits.diagnostic_count_max);

    var findings = try testing.analyze(@This(), language, source);
    defer findings.deinit();

    if (findings.count() != expected) findings.print();

    try std.testing.expectEqual(expected, findings.count());
}

test "a closure after a brace argument is still an argument" {
    const source = "fn f() {\n" ++
        "let total = items.fold(Start { value: 0 }, |acc, item| acc + item);\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
}

test "a closure after a turbofish call is still an argument" {
    const source = "fn f() {\n    round_trip::<A, B>(\n        \"NAME\",\n" ++
        "&[],\n        |value| A::from(value),\n    );\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
}

test "a bar pair after an expression is an operator" {
    const source = "fn work(other: bool, bytes: &[u8]) -> bool {\n    let first = self || " ++
        "other;\n    let second = bytes.is_empty()? || other;\n    first && " ++
        "second\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
}

test "a bound closure is still reported" {
    try expect_count(.rust, "fn f() {\n    let double = |value: u32| value * 2;\n}\n", 1);
}

test "a go function type in a composite literal is not a lambda" {
    const source = "package main\n\nfunc f() {\n\ttodo := [3]func(){}\n\t_ = todo\n}\n";

    try testing.expect_quiet(@This(), .go, source);
}

test "a go immediately invoked literal is a call target" {
    const source = "package main\n\nvar bits = func() (out [4]byte) {\n\tout[0] = 1\n" ++
        "\treturn\n}()\n";

    try testing.expect_quiet(@This(), .go, source);
}

test "a lambda wrapped in parentheses and invoked in place is quiet" {
    const rust = "fn f() -> Option<u32> {\n    let a = (|| {\n        let b = g()?;\n" ++
        "        Some(b)\n    })();\n    let c = (move || 1)();\n" ++
        "    let d = (|x: u32| x + 1)(2);\n    a\n}\n";

    const javascript = "const a = (function () {\n    return 1;\n})();\n";

    try testing.expect_quiet(@This(), .rust, rust);
    try testing.expect_quiet(@This(), .javascript, javascript);
    try testing.expect_quiet(@This(), .python, "value = (lambda: 1)()\n");
}

test "a lambda wrapped in parentheses but not invoked is reported" {
    try expect_count(.rust, "fn f() {\n    let a = (|| 1);\n    let b = (move || 2);\n}\n", 2);
    try expect_count(.python, "value = (lambda: 1)\n", 1);
}

test "a lambda wrapped in parentheses and passed to a call is an argument" {
    const python = "def run(self, callee):\n    return self.apply(\n        callee,\n" ++
        "        (lambda args, sig: hook(args, sig)),\n    )\n";

    const rust = "fn f() {\n    run(1, (move |x: u32| x + 1));\n}\n";
    const chained = "fn f() {\n    run((|x: u32| x + 1).pipe(other));\n}\n";

    try testing.expect_quiet(@This(), .python, python);
    try testing.expect_quiet(@This(), .rust, rust);
    try expect_count(.python, "register((lambda: 1, 2))\n", 1);
    try expect_count(.rust, chained, 1);
    try expect_count(.javascript, "custom(fn ?? (() => true), params);\n", 1);
}

test "a stored arrow function is reported" {
    const source = "const step = (v) => v + 1;\nelement.onclick = () => {};\nconst table = { " ++
        "key: (v) => v };\nconst bare = v => v + 1;\nexport const handler = " ++
        "async (event) => event;\n";

    try expect_count(.javascript, source, 5);
}

test "an arrow passed straight to a call is quiet" {
    const source = "items.map((v) => v * 2);\n(() => {\n    run();\n})();\nsetTimeout(() => " ++
        "run(), 0);\npromise.then(v => v).catch((e) => e);\n";

    try testing.expect_quiet(@This(), .javascript, source);
}

test "an arrow inside a type is quiet" {
    const source = "type Step = (value: number) => number;\n\ninterface Runner {\n    run: " ++
        "(value: number) => void;\n}\n";

    try testing.expect_quiet(@This(), .typescript, source);
}

test "an odin procedure bound by a variable is reported" {
    const source = "package main\n\nrun :: proc() {\n    step := proc(v: int) -> int { return " ++
        "v + 1 }\n    other := proc(v: int) -> int {\n        return v + 2\n    " ++
        "}\n    call(proc(v: int) -> int { return v })\n}\n";

    try expect_count(.odin, source, 2);
}

test "a lambda is reported" {
    try expect_count(.python, "value = lambda x: x + 1\n", 1);
}

test "a lambda anchors past its move" {
    const source = "fn f() {\n    let worker = move || {\n        let _ = 1;\n    };\n" ++
        "let _ = worker;\n}\n";

    try testing.expect_anchors(@This(), .rust, source, &.{.{ 2, 18 }});
}
