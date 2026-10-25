const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const Span = scylla.Span;
const Token = scylla.Token;

pub const modifier_count_max: u32 = 4;

pub fn expression_start(tokens: []const Token, source: []const u8, index: u32) u32 {
    assert(index < tokens.len);

    const line = line_start_of_token(tokens, source, index);
    var first = line;

    assert(line <= index);

    for (tokens[line..index], line..) |token, position| {
        if (token.is_punctuation(.assign)) first = @intCast(position + 1);
        if (token.is_punctuation(.assign_declare)) first = @intCast(position + 1);
    }

    assert(first >= line);
    assert(first <= index);
    if (first > line) assert(tokens[first - 1].kind == .punctuation);

    return first;
}

pub fn in_span(tokens: []const Token, within: Span) []const Token {
    const first = index_from(tokens, within.offset);
    const reach = std.sort.partitionPoint(Token, tokens, within.end(), opens_before);
    const last = @max(reach, first);

    assert(first <= last);
    assert(last <= tokens.len);
    assert(reach <= tokens.len);
    if (last > first) assert(tokens[first].offset >= within.offset);

    return tokens[first..last];
}

pub fn index_at(tokens: []const Token, offset: u32) ?u32 {
    const index = index_from(tokens, offset);

    assert(index <= tokens.len);

    if (index < tokens.len) {
        if (tokens[index].offset == offset) return index;
    }

    if (index < tokens.len) assert(tokens[index].offset > offset);

    return null;
}

pub fn index_from(tokens: []const Token, offset: u32) u32 {
    const index = std.sort.partitionPoint(Token, tokens, offset, ends_before);

    assert(index <= tokens.len);
    if (index < tokens.len) assert(tokens[index].offset >= offset);
    if (index > 0) assert(tokens[index - 1].offset <= offset);

    return @intCast(index);
}

pub fn index_from_hint(tokens: []const Token, offset: u32, hint: u32) u32 {
    assert(hint <= tokens.len);
    if (hint > 0) assert(ends_before(offset, tokens[hint - 1]));

    for (tokens[hint..], hint..) |token, index| {
        if (ends_before(offset, token)) continue;

        assert(token.offset >= offset);

        return @intCast(index);
    }

    return @intCast(tokens.len);
}

pub fn index_starting_from(tokens: []const Token, offset: u32) u32 {
    const index = std.sort.partitionPoint(Token, tokens, offset, opens_before);

    assert(index <= tokens.len);
    if (index < tokens.len) assert(tokens[index].offset >= offset);
    if (index > 0) assert(tokens[index - 1].offset < offset);

    return @intCast(index);
}

pub fn label_start(tokens: []const Token, source: []const u8, index: u32) ?u32 {
    assert(index < tokens.len);

    if (index < 2) return null;

    const colon = index - 1;
    const label = index - 2;

    if (!tokens[colon].is_punctuation(.colon)) return null;
    if (tokens[label].kind != .identifier) return null;
    if (label == line_start_of_token(tokens, source, label)) return null;
    return label;
}

pub fn line_start_of_token(tokens: []const Token, source: []const u8, index: u32) u32 {
    assert(index < tokens.len);

    var first = index;

    while (first > 0) {
        const previous = tokens[first - 1];

        switch (previous.kind) {
            .newline, .block_start, .block_end => break,
            else => {},
        }

        const gap = previous.end();
        const current = tokens[first].offset;
        if (gap > current) break;
        if (current > source.len) break;
        if (std.mem.findScalar(u8, source[gap..current], '\n') != null) break;

        first -= 1;
    }

    assert(first <= index);
    if (first < index) assert(tokens[first].kind != .newline);

    return first;
}

pub fn modifier_start(
    pairs: *const scylla.Brackets,
    tokens: []const Token,
    source: []const u8,
    index: u32,
    skip_count_max: u32,
) u32 {
    assert(index < tokens.len);

    const line = line_start_of_token(tokens, source, index);
    var first = index;
    var skipped: u32 = 0;

    assert(line <= index);

    while (first > line) : (skipped += 1) {
        if (skipped == skip_count_max) break;

        var before = first - 1;

        if (tokens[before].is_punctuation(.paren_close)) {
            const open = pairs.open_of(before) orelse break;

            assert(open < before);

            if (open == 0) break;

            before = open - 1;
        }

        if (before < line) break;
        if (!tokens[before].is_keyword(.other)) break;

        first = before;
    }

    assert(first <= index);
    assert(first >= line);
    assert(skipped <= skip_count_max);
    if (first < index) assert(tokens[first].is_keyword(.other));

    return first;
}

pub fn opens_a_statement(tokens: []const Token, index: u32) bool {
    assert(index <= tokens.len);

    var offset = index;

    while (offset > 0) {
        offset -= 1;

        const token = tokens[offset];

        switch (token.kind) {
            .comment => continue,
            .block_end, .block_start, .newline => return true,
            else => return token.is_punctuation(.semicolon),
        }
    }

    assert(offset == 0);

    return true;
}

pub fn significant_next(tokens: []const Token, from: u32, until: u32) ?u32 {
    assert(until <= tokens.len);

    var index = from;

    while (index < until) : (index += 1) {
        if (Token.is_significant(tokens[index].kind)) return index;
    }

    return null;
}

pub fn significant_previous(tokens: []const Token, before: u32) ?u32 {
    assert(before <= tokens.len);

    var index = before;

    while (index > 0) {
        index -= 1;

        if (Token.is_significant(tokens[index].kind)) return index;
    }

    assert(index == 0);

    return null;
}

pub fn significant_previous_in_line(tokens: []const Token, before: u32) ?u32 {
    assert(before <= tokens.len);

    var index = before;

    while (index > 0) {
        index -= 1;

        switch (tokens[index].kind) {
            .block_end, .block_start, .newline => {},
            else => return index,
        }
    }

    assert(index == 0);

    return null;
}

pub fn span_of_range(tokens: []const Token, start: u32, until: u32) Span {
    assert(start < until);
    assert(until <= tokens.len);

    const opened = tokens[start].offset;
    const closed = tokens[until - 1].end();

    assert(closed >= opened);

    return Span.between(opened, closed);
}

pub fn statement_end(tokens: []const Token, start: u32) u32 {
    assert(start <= tokens.len);

    var offset = start;

    while (offset < tokens.len) : (offset += 1) {
        switch (tokens[offset].kind) {
            .newline, .block_start, .block_end => return offset,
            .punctuation => |punctuation| if (punctuation == .semicolon) return offset,
            else => {},
        }
    }

    assert(offset == tokens.len);

    return @intCast(tokens.len);
}

pub fn text_of_range(source: []const u8, tokens: []const Token, first: u32, last: u32) []const u8 {
    assert(first <= last);
    assert(last < tokens.len);

    const start = tokens[first].offset;
    const stop = tokens[last].end();

    assert(start <= stop);
    assert(stop <= source.len);

    return source[start..stop];
}

fn ends_before(offset: u32, token: Token) bool {
    assert(token.end() >= token.offset);

    if (token.offset < offset) return true;
    if (token.offset > offset) return false;
    return token.end() == offset;
}

fn opens_before(offset: u32, token: Token) bool {
    return token.offset < offset;
}

const TestLexed = struct {
    source: []const u8,
    tokens: scylla.Tokens,

    fn init(language: scylla.Language, source: []const u8) !TestLexed {
        var tokens: scylla.Tokens = try .init(std.testing.allocator, 256);
        errdefer tokens.deinit(std.testing.allocator);

        try tokens.lex(.of(language), source);

        return .{ .source = source, .tokens = tokens };
    }

    fn deinit(lexed: *TestLexed) void {
        lexed.tokens.deinit(std.testing.allocator);
    }

    fn slice(lexed: *const TestLexed) []const Token {
        return lexed.tokens.slice();
    }

    fn word(lexed: *const TestLexed, text: []const u8) u32 {
        for (lexed.slice(), 0..) |token, index| {
            if (std.mem.eql(u8, token.text(lexed.source), text)) return @intCast(index);
        }

        unreachable;
    }
};

fn test_spaced(comptime pairs: []const [2]u32) [pairs.len]Token {
    var tokens: [pairs.len]Token = undefined;

    for (pairs, &tokens) |pair, *token| {
        assert(pair[1] <= std.math.maxInt(u32) - pair[0]);

        token.* = .{ .offset = pair[0], .length = pair[1], .kind = .identifier };
    }

    return tokens;
}

test expression_start {
    var assigned: TestLexed = try .init(.rust, "fn held() {\n    let value = first + second;\n}\n");
    defer assigned.deinit();

    const second = assigned.word("second");

    try std.testing.expectEqual(
        assigned.word("first"),
        expression_start(assigned.slice(), assigned.source, second),
    );

    var called: TestLexed = try .init(.rust, "fn held() {\n    call(first, second);\n}\n");
    defer called.deinit();

    const argument = called.word("second");

    try std.testing.expectEqual(
        called.word("call"),
        expression_start(called.slice(), called.source, argument),
    );
}

test in_span {
    const tokens = test_spaced(&.{ .{ 0, 2 }, .{ 3, 4 }, .{ 8, 1 }, .{ 10, 2 } });

    try std.testing.expectEqual(2, in_span(&tokens, Span.between(3, 9)).len);
    try std.testing.expectEqual(1, in_span(&tokens, Span.between(3, 8)).len);
    try std.testing.expectEqual(4, in_span(&tokens, Span.between(0, 12)).len);
    try std.testing.expectEqual(0, in_span(&tokens, Span.between(1, 3)).len);
    try std.testing.expectEqual(0, in_span(&tokens, Span.between(12, 12)).len);
    try std.testing.expectEqual(0, in_span(&.{}, Span.between(0, 4)).len);
}

test index_at {
    const tokens = test_spaced(&.{ .{ 0, 2 }, .{ 3, 0 }, .{ 3, 4 }, .{ 8, 1 } });

    try std.testing.expectEqual(0, index_at(&tokens, 0));
    try std.testing.expectEqual(2, index_at(&tokens, 3));
    try std.testing.expectEqual(3, index_at(&tokens, 8));
    try std.testing.expectEqual(null, index_at(&tokens, 1));
    try std.testing.expectEqual(null, index_at(&tokens, 9));
    try std.testing.expectEqual(null, index_at(&tokens, 2));
    try std.testing.expectEqual(null, index_at(&.{}, 0));
}

test index_from {
    const tokens = test_spaced(&.{ .{ 0, 2 }, .{ 3, 0 }, .{ 3, 4 }, .{ 8, 1 } });

    try std.testing.expectEqual(0, index_from(&tokens, 0));
    try std.testing.expectEqual(1, index_from(&tokens, 1));
    try std.testing.expectEqual(2, index_from(&tokens, 3));
    try std.testing.expectEqual(4, index_from(&tokens, 9));
    try std.testing.expectEqual(0, index_from(&.{}, 5));
}

test index_from_hint {
    const tokens = test_spaced(&.{ .{ 0, 2 }, .{ 3, 4 }, .{ 8, 1 } });

    for ([_]u32{ 0, 1, 3, 5, 8, 9 }) |offset| {
        const index = index_from(&tokens, offset);

        try std.testing.expectEqual(index, index_from_hint(&tokens, offset, 0));
        try std.testing.expectEqual(index, index_from_hint(&tokens, offset, index));
    }
}

test index_starting_from {
    const tokens = test_spaced(&.{ .{ 0, 2 }, .{ 3, 4 }, .{ 8, 1 } });

    try std.testing.expectEqual(0, index_starting_from(&tokens, 0));
    try std.testing.expectEqual(1, index_starting_from(&tokens, 1));
    try std.testing.expectEqual(2, index_starting_from(&tokens, 5));
    try std.testing.expectEqual(3, index_starting_from(&tokens, 9));
}

test label_start {
    const source = "fn f() void {\n    const x = outer: {\n        break :outer 1;\n    };\n}\n";
    var lexed: TestLexed = try .init(.zig, source);
    defer lexed.deinit();

    const label = lexed.word("outer");
    const brace = label + 2;

    try std.testing.expectEqual(label, label_start(lexed.slice(), source, brace));
    try std.testing.expectEqual(null, label_start(lexed.slice(), source, 1));
}

test line_start_of_token {
    var lexed: TestLexed = try .init(.rust, "fn f() {\n    let a = b;\n}\n");
    defer lexed.deinit();

    const tokens = lexed.slice();
    const b = lexed.word("b");

    try std.testing.expectEqual(lexed.word("let"), line_start_of_token(tokens, lexed.source, b));
    try std.testing.expectEqual(0, line_start_of_token(tokens, lexed.source, 2));
}

test opens_a_statement {
    var lexed: TestLexed = try .init(.rust, "fn f() {\n    a; b\n}\n");
    defer lexed.deinit();

    try std.testing.expect(opens_a_statement(lexed.slice(), 0));
    try std.testing.expect(opens_a_statement(lexed.slice(), lexed.word("b")));
    try std.testing.expect(!opens_a_statement(lexed.slice(), lexed.word("f")));
}

test significant_next {
    var lexed: TestLexed = try .init(.python, "x = 1  # note\ny\n");
    defer lexed.deinit();

    const tokens = lexed.slice();
    const one = lexed.word("1");
    const until: u32 = @intCast(tokens.len);

    try std.testing.expectEqual(lexed.word("y"), significant_next(tokens, one + 1, until));
    try std.testing.expectEqual(null, significant_next(tokens, one + 1, one + 2));
}

test significant_previous {
    var lexed: TestLexed = try .init(.python, "x = 1  # note\ny\n");
    defer lexed.deinit();

    const tokens = lexed.slice();

    try std.testing.expectEqual(lexed.word("1"), significant_previous(tokens, lexed.word("y") - 1));
    try std.testing.expectEqual(null, significant_previous(tokens, 0));
}

test significant_previous_in_line {
    var lexed: TestLexed = try .init(.python, "x = 1\ny\n");
    defer lexed.deinit();

    const tokens = lexed.slice();
    const y = lexed.word("y");

    try std.testing.expectEqual(lexed.word("1"), significant_previous_in_line(tokens, y));
    try std.testing.expectEqual(null, significant_previous_in_line(tokens, 0));
}

test span_of_range {
    const tokens = test_spaced(&.{ .{ 0, 2 }, .{ 3, 4 }, .{ 8, 1 } });

    try std.testing.expectEqual(Span.between(0, 7), span_of_range(&tokens, 0, 2));
    try std.testing.expectEqual(Span.between(8, 9), span_of_range(&tokens, 2, 3));
}

test statement_end {
    var lexed: TestLexed = try .init(.rust, "fn f() {\n    a; b\n}\n");
    defer lexed.deinit();

    const tokens = lexed.slice();
    const end: u32 = @intCast(tokens.len);

    try std.testing.expectEqual(lexed.word("a") + 1, statement_end(tokens, lexed.word("a")));
    try std.testing.expectEqual(end, statement_end(tokens, end));
}

test text_of_range {
    var lexed: TestLexed = try .init(.rust, "let value = first + second;\n");
    defer lexed.deinit();

    const first = lexed.word("first");
    const last = lexed.word("second");
    const text = text_of_range(lexed.source, lexed.slice(), first, last);

    try std.testing.expectEqualStrings("first + second", text);
}
