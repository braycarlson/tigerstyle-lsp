const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const Context = @import("context.zig");
const Span = scylla.Span;
const Token = scylla.Token;
const View = scylla.View;
const stream = @import("../stream.zig");

pub const call_head_max: u32 = 8;

pub fn attribute_marked(context: *const Context, bracket: u32) bool {
    assert(bracket < context.source.len);

    var start = bracket;

    if (start > 0) {
        if (context.source[start - 1] == '!') start -= 1;
    }

    assert(start <= bracket);

    if (start == 0) return false;
    return context.source[start - 1] == '#';
}

pub fn call_head(context: *const Context, call: Span) Span {
    assert(call.end() <= context.source.len);

    for (context.tokens_in(call)) |token| {
        if (!token.is_punctuation(.paren_open)) continue;

        assert(token.offset >= call.offset);
        assert(token.offset < call.end());

        return .{ .offset = call.offset, .length = token.offset - call.offset };
    }

    return call;
}

pub fn compounds_an_assignment(context: *const Context, token: Token) bool {
    assert(token.end() <= context.source.len);

    if (!token.is_punctuation(.other)) return false;

    const text = context.text(token);

    assert(text.len == token.length);

    if (text.len <= 1) return false;
    return text[text.len - 1] == '=';
}

pub fn follows_a_statement_break(context: *const Context, index: u32) bool {
    assert(index <= context.tokens.len);

    if (index == 0) return true;

    const token = context.tokens[index - 1];

    const breaks = switch (token.kind) {
        .block_end, .block_start, .comment, .newline => true,
        .punctuation => |punctuation| punctuation == .semicolon,
        .identifier, .keyword, .number, .string => false,
    };

    if (breaks) assert(token.kind != .identifier);

    return breaks;
}

pub fn holds_statements(parent: View) bool {
    const holds = switch (parent.category()) {
        .block, .branch, .except, .file, .loop, .match, .@"try" => true,
        else => false,
    };

    if (holds) assert(parent.category() != .call);
    if (!holds) assert(parent.category() != .block);

    return holds;
}

pub fn resolved(context: *const Context, name: []const u8) []const u8 {
    assert(name.len <= context.source.len);

    const target = context.tables.alias_of(name) orelse return name;

    assert(target.end() <= context.source.len);

    return context.span_text(target);
}

pub fn span_end(context: *const Context, span: Span) u32 {
    const index = stream.index_starting_from(context.tokens, span.end());

    assert(index <= context.tokens.len);
    if (index > 0) assert(context.tokens[index - 1].offset < span.end());

    return index;
}

pub fn span_start(context: *const Context, span: Span) u32 {
    const index = stream.index_starting_from(context.tokens, span.offset);

    assert(index <= context.tokens.len);
    if (index < context.tokens.len) assert(context.tokens[index].offset >= span.offset);

    return index;
}

pub fn unquoted(text: []const u8) []const u8 {
    if (text.len < 2) return text;

    const quote = text[0];

    const quoted = switch (quote) {
        '"', '\'', '`' => text[text.len - 1] == quote,
        else => false,
    };

    if (!quoted) return text;

    const inner = text[1 .. text.len - 1];

    assert(inner.len + 2 == text.len);
    assert(text[text.len - 1] == quote);

    return inner;
}
