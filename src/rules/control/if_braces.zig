const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const control = @import("../control.zig");
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
            .text = "\"Add braces to the `if` statement unless it fits on a single line for " ++
                "consistency and defense in depth against \\\"goto fail;\\\" bugs.\"",
        },
    },
    .code = "TS030",
    .default_on = true,
    .description = "A branch that spans more than one line carries braces, so a later statement " ++
        "cannot join the body by accident.",
    .explanation = "",
    .fix_title = "",
    .fixable = .sometimes,
    .group = .stable,
    .name = "if-braces",
    .severity = .warning,
    .summary = "A multi-line `if` needs braces",
    .url = "",
};

const Nesting = enum {
    closes,
    neither,
    opens,
};

pub fn run(context: *const Context, sink: *Sink) void {
    for (context.tokens, 0..) |token, position| {
        const index: u32 = @intCast(position);
        const anchor = anchor_of(context, index) orelse continue;

        assert(anchor >= index);
        assert(token.kind == .keyword);

        const body = body_after(context, capture_end(context, anchor) + 1) orelse continue;

        assert(body > anchor);

        if (opens_a_block(context, token, body)) continue;

        const anchor_line = context.line_of(context.tokens[anchor].offset);
        if (anchor_line == context.line_of(context.tokens[body].offset)) continue;

        sink.report(token.span(), "the branch body opens on a later line without braces");
    }
}

fn anchor_of(context: *const Context, index: u32) ?u32 {
    assert(index < context.tokens.len);

    const token = context.tokens[index];
    if (token.is_keyword(.branch)) return branch_anchor(context, index);
    if (!token.is_keyword(.branch_else)) return null;
    if (!chain_opens_a_statement(context, index)) return null;
    return index;
}

fn branch_anchor(context: *const Context, index: u32) ?u32 {
    assert(context.tokens[index].is_keyword(.branch));

    if (!chain_opens_a_statement(context, index)) return null;

    const group = control.header_group(context, index) orelse
        return body_word_after(context, index);

    assert(group.closed > index);

    return group.closed;
}

fn chain_opens_a_statement(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);

    var link = index;

    for (0..index + 1) |_| {
        if (context.tokens[link].is_keyword(.branch_else)) {
            const branch = branch_of(context, link) orelse
                return opens_a_statement(context, link);

            assert(branch < link);

            link = branch;
        } else {
            assert(context.tokens[link].is_keyword(.branch));

            if (opens_a_statement(context, link)) return true;

            const before = else_before(context, link) orelse return false;

            assert(before < link);

            link = before;
        }
    } else unreachable;
}

fn opens_a_statement(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);

    if (!stream.opens_a_statement(context.tokens, index)) return false;

    const before = stream.significant_previous(context.tokens, index) orelse return true;

    assert(before < index);

    const brace = switch (context.tokens[before].kind) {
        .block_start => before,
        .block_end => context.pairs.partner_of(before) orelse return true,
        else => return true,
    };

    assert(brace <= before);

    if (brace == 0) return true;
    return !context.tokens[brace - 1].is_punctuation(.dot);
}

fn opens_a_block(context: *const Context, token: Token, body: u32) bool {
    assert(body < context.tokens.len);
    assert(token.kind == .keyword);

    const opened = context.tokens[body];
    if (opened.kind == .block_start) return true;
    if (!token.is_keyword(.branch_else)) return false;
    return opened.is_keyword(.branch);
}

fn else_before(context: *const Context, index: u32) ?u32 {
    assert(index < context.tokens.len);

    const before = stream.significant_previous(context.tokens, index) orelse return null;

    assert(before < index);

    if (!context.tokens[before].is_keyword(.branch_else)) return null;
    return before;
}

fn body_word_after(context: *const Context, index: u32) ?u32 {
    assert(index < context.tokens.len);

    const end = control.header_end(context, index + 1);

    assert(end > index);
    assert(end <= context.tokens.len);

    const word = end - 1;
    if (word <= index) return null;
    if (!is_body_word(context, word)) return null;
    return word;
}

fn is_body_word(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);

    const token = context.tokens[index];
    if (!token.is_keyword(.other)) return false;

    const word = std.mem.eql(u8, context.text(token), control.body_word);

    if (word) assert(token.length == control.body_word.len);

    return word;
}

fn body_after(context: *const Context, start: u32) ?u32 {
    var body = control.significant_after(context, start) orelse return null;

    if (is_body_word(context, body)) {
        body = control.significant_after(context, body + 1) orelse return null;
    }

    const held = context.tokens[body];
    const synthetic = held.kind == .block_start and held.length == 0;

    if (synthetic) {
        body = control.significant_after(context, body + 1) orelse return null;
    }

    assert(body >= start);
    assert(body < context.tokens.len);

    return body;
}

fn capture_end(context: *const Context, anchor: u32) u32 {
    assert(anchor < context.tokens.len);

    const open = control.significant_after(context, anchor + 1) orelse return anchor;
    if (!control.captures(context, open)) return anchor;

    assert(open > anchor);

    for (context.tokens[open + 1 ..], open + 1..) |token, offset| {
        if (control.captures(context, @intCast(offset))) return @intCast(offset);

        switch (token.kind) {
            .block_end, .block_start, .newline => return anchor,
            else => {},
        }
    }

    return anchor;
}

fn branch_of(context: *const Context, index: u32) ?u32 {
    assert(index < context.tokens.len);

    var depth: u32 = 0;

    for (0..index) |step| {
        const offset: u32 = @intCast(index - 1 - step);
        const token = context.tokens[offset];

        switch (nesting_of(token)) {
            .closes => {
                depth += 1;

                continue;
            },
            .opens => {
                if (depth == 0) return null;

                depth -= 1;

                continue;
            },
            .neither => {},
        }

        if (depth > 0) continue;

        assert(offset < index);

        if (token.is_keyword(.branch)) return offset;
        if (stops_the_search(token)) return null;
    }

    return null;
}

fn nesting_of(token: Token) Nesting {
    const nesting: Nesting = switch (token.kind) {
        .block_end => .closes,
        .block_start => .opens,
        .punctuation => |punctuation| switch (punctuation) {
            .paren_close => .closes,
            .paren_open => .opens,
            else => .neither,
        },
        .comment, .identifier, .keyword, .newline, .number, .string => .neither,
    };

    if (nesting != .neither) assert(token.kind != .keyword);

    return nesting;
}

fn stops_the_search(token: Token) bool {
    const stops = switch (token.kind) {
        .keyword => |keyword| switch (keyword) {
            .loop, .loop_unbounded => true,
            else => false,
        },
        .punctuation => |punctuation| punctuation == .semicolon,
        .block_end, .block_start, .comment, .identifier, .newline, .number, .string => false,
    };

    if (stops) assert(token.kind != .identifier);

    return stops;
}

fn expect_count(language: Language, source: []const u8, expected: u32) !void {
    assert(source.len > 0);
    assert(expected <= testing.limits.diagnostic_count_max);

    var findings = try testing.analyze(@This(), language, source);
    defer findings.deinit();

    if (findings.count() != expected) findings.print();

    try std.testing.expectEqual(expected, findings.count());
}

test "a braceless branch that throws is reported" {
    const source = "function run(a, b) {\n    if (a === b)\n        throw a;\n    return " ++
        "b;\n}\n";

    const braced = "function run(a, b) {\n    if (a === b) {\n        throw a;\n    }\n" ++
        "\n    return b;\n}\n";

    try expect_count(.javascript, source, 1);
    try testing.expect_quiet(@This(), .javascript, braced);
}

test "a payload capture does not hide an unbraced body" {
    try expect_count(.zig, "fn f() void {\n    if (maybe) |value|\n        use(value);\n}\n", 1);
}

test "a payload capture with a same line body is quiet" {
    const source = "fn f() void {\n    if (maybe) |value| use(value);\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "an else after an unterminated body is reported" {
    const source = "fn f() u64 {\n    if (ready)\n        return one()\n    else\n" ++
        "return two();\n}\n";

    try expect_count(.zig, source, 2);
}

test "an else inside a value expression stays out of a statement" {
    const source = "fn f() u64 {\n    const value = if (ready)\n        one\n" ++
        "else\n        two;\n    return value;\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "an else if inside a value expression stays out of a statement" {
    const source = "fn f() u64 {\n    const value = if (first)\n        one\n" ++
        "    else if (second)\n        two\n    else\n        three;\n    return value;\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "a value chain after a typed literal stays out of a statement" {
    const source = "fn f() T {\n    return if (first)\n        T{}\n    else if (second)\n" ++
        "        one\n    else\n        two;\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "a value chain after a labeled block stays out of a statement" {
    const source = "fn f() u8 {\n    const value = if (first) block: {\n" ++
        "        break :block 1;\n    } else\n        2;\n    return value;\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "a value chain after a switch arm stays out of a statement" {
    const source = "fn f() u8 {\n    const value = if (first) switch (kind) {\n" ++
        "        .a => 1,\n        else => 2,\n    } else if (second)\n        3\n" ++
        "    else\n        4;\n    return value;\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "a statement chain after a switch arm is reported" {
    const source = "fn f() void {\n    if (first) switch (kind) {\n        .a => one(),\n" ++
        "        else => two(),\n    } else if (second)\n        three()\n    else\n" ++
        "        four();\n}\n";

    try expect_count(.zig, source, 2);
}

test "an else after an anonymous literal arm stays out of a statement" {
    const value = "fn f(ready: bool) Action {\n    return if (ready)\n" ++
        "        .{ .submitted = {} }\n    else\n        .{ .failed = {} };\n}\n";

    const statement = "fn f(ready: bool) void {\n    if (ready) {\n        submit();\n" ++
        "    } else\n        fail();\n}\n";

    try testing.expect_quiet(@This(), .zig, value);
    try expect_count(.zig, statement, 1);
}

test "a value if inside an anonymous literal stays out of a statement" {
    const source = "fn f(first: bool) Range {\n    return .{\n        if (first)\n" ++
        "            one\n        else\n            0,\n        two,\n    };\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "a braceless multiline branch is reported" {
    try expect_count(.zig, "fn f() void {\n    if (ready)\n        work();\n}\n", 1);
}

test "a single line branch is quiet" {
    try testing.expect_quiet(@This(), .zig, "fn f() void {\n    if (ready) work();\n}\n");
}

test "an else if without braces is reported" {
    const source = "function f(a, b) {\n    if (a) {\n        one();\n    } else if (b)\n" ++
        "two();\n}\n";

    try expect_count(.javascript, source, 1);
}

test "each arm of a braceless else if statement is reported" {
    const source = "fn f() void {\n    if (first)\n        one()\n    else if (second)\n" ++
        "        two()\n    else\n        three();\n}\n";

    try expect_count(.zig, source, 3);
}

test "each arm of a braceless else if statement that tries is reported" {
    const source = "fn f() !void {\n    if (first)\n        try one()\n    else if (second)\n" ++
        "        try two()\n    else\n        try three();\n}\n";

    try expect_count(.zig, source, 3);
}

test "an odin do body on a later line is reported" {
    const source = "package main\n\nf :: proc(a: bool) {\n    if a do\n        work()\n}\n";

    try expect_count(.odin, source, 1);
}

test "an odin do body on the same line is quiet" {
    const source = "package main\n\nf :: proc(a: bool) {\n    if a do work()\n    if a {\n" ++
        "work()\n    }\n}\n";

    try testing.expect_quiet(@This(), .odin, source);
}
