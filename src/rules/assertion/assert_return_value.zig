const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const stream = @import("../../stream.zig");
const support = @import("../support.zig");
const testing = @import("../testing.zig");
const Category = scylla.View.Category;
const Context = @import("../context.zig");
const Declaration = scylla.View.Declaration;
const Function = scylla.View.Function;
const Language = scylla.Language;
const Rule = scylla.rule.Rule;
const Sink = scylla.rule.Sink;
const Span = scylla.Span;
const Token = scylla.Token;
const View = scylla.View;
const scan = @import("../../scan.zig");

pub const rule: Rule = .{
    .citations = &.{
        .{
            .standard = "TigerStyle",
            .text = "\"Assert all function arguments and return values, pre/postconditions and " ++
                "invariants. A function must not operate blindly on data it has not checked.\"",
        },
    },
    .code = "TS026",
    .default_on = false,
    .description = "A function asserts the value it returns, so a wrong result fails where it " ++
        "was computed.",
    .explanation = "",
    .fix_title = "",
    .fixable = .sometimes,
    .group = .stable,
    .name = "assert-return-value",
    .severity = .information,
    .summary = "Assert a function's return value before returning it",
    .url = "",
};

const arithmetic = [_][]const u8{
    "%",
    "%%",
    "%%=",
    "*",
    "*%",
    "**",
    "*|",
    "+",
    "+%",
    "++",
    "+|",
    "-",
    "-%",
    "--",
    "-|",
    "/",
    "//",
};

const arithmetic_go = [_][]const u8{ "%", "*", "+", "-", "/", "<<" };
const binding_categories = [_]Category{ .declaration, .assignment };
const composite_openers = [_][]const u8{ "[", "new", "{" };

const literals = [_][]const u8{
    "False",
    "None",
    "True",
    "false",
    "nil",
    "null",
    "true",
    "undefined",
    "unreachable",
};

const negation = "-";

const numeric_types = [_][]const u8{
    "c_int",
    "c_long",
    "c_uint",
    "c_ulong",
    "f128",
    "f16",
    "f32",
    "f64",
    "f80",
    "float",
    "float32",
    "float64",
    "i128",
    "i16",
    "i32",
    "i64",
    "i8",
    "int",
    "int16",
    "int32",
    "int64",
    "int8",
    "isize",
    "number",
    "u128",
    "u16",
    "u32",
    "u64",
    "u8",
    "uint",
    "uint16",
    "uint32",
    "uint64",
    "uint8",
    "uintptr",
    "usize",
};

const postfix_count_max: u32 = 4;
const postfix_operators = [_][]const u8{ "!", ".*", ".?", "?" };
const prefix_operator_count_max: u32 = 4;
const prefix_stars = [_][]const u8{ "*", "**" };
const reference_peel_max: u32 = 4;
const return_markers = [_][]const u8{ "->", ":" };
const success_flag_name = "ok";
const tail_depth_max: u32 = 8;
const wrapper_markers = [_][]const u8{ "?", "!" };
const wrapper_peel_max: u32 = 4;

pub fn run(context: *const Context, sink: *Sink) void {
    var nodes = support.functions_and_bound_lambdas(context);

    for (0..context.front.node_count()) |_| {
        const node = nodes.next() orelse break;
        const function = node.as_function() orelse continue;
        const position = support.bound_name_of(node);
        const name = if (position) |held| context.front_text(held) else "";
        const returns = function.returns_span();
        const spelled = if (returns) |span| context.span_text(span) else "";

        if (position != null) assert(name.len > 0);
        if (returns) |span| assert(spelled.len == span.length);

        if (spelled.len > 0) {
            if (!is_numeric(context, spelled)) continue;
        }

        const body = block_of(function) orelse {
            report_an_expression_body(context, sink, node, spelled, name);

            continue;
        };

        assert(body.category() == .block);

        if (!carries_a_value(context, node, body, spelled)) continue;

        report_a_return(context, sink, node, body, spelled, name);
        report_a_tail(context, sink, body, name);
    }
}

fn block_of(function: Function) ?View {
    const body = function.body() orelse return null;
    if (body.category() != .block) return null;

    assert(body.index() > function.view.index());
    assert(body.span().offset >= function.view.span().offset);

    return body;
}

fn report_an_expression_body(
    context: *const Context,
    sink: *Sink,
    node: View,
    spelled: []const u8,
    name: []const u8,
) void {
    if (node.category() != .lambda) return;

    if (spelled.len == 0) {
        if (context.conventions.returns_are_spelled) return;
    }

    const value = node.children().last() orelse return;

    assert(value.index() > node.index());

    switch (value.category()) {
        .call, .expression => {},
        else => return,
    }

    const tokens = without_comments(context.tokens_in(value.span()));
    if (!is_computed(context, tokens)) return;

    assert(tokens.len > 0);

    report_a_value(sink, value.span(), name);
}

fn report_a_return(
    context: *const Context,
    sink: *Sink,
    node: View,
    body: View,
    spelled: []const u8,
    name: []const u8,
) void {
    const span = body.span();

    assert(body.category() == .block);

    for (context.front.nodes_of(.@"return")) |position| {
        const statement = context.view(position);
        const held = statement.span();

        assert(statement.category() == .@"return");

        if (!covers(span, held)) continue;
        if (!owns(node, statement)) continue;
        if (returns_a_closure(statement)) continue;
        if (returns_a_composite(context, statement)) continue;
        if (returns_a_checked_value(context, body, statement)) continue;
        if (returns_without_a_postcondition(context, body, statement, spelled)) continue;

        assert(held.end() <= span.end());

        report_a_value(sink, held, name);
    }
}

fn report_a_tail(context: *const Context, sink: *Sink, body: View, name: []const u8) void {
    const tail = tail_within(context, body) orelse return;
    const tokens = context.tokens_in(tail.span());

    assert(body.category() == .block);
    assert(tail.index() > body.index());

    if (is_checked(context, body, tokens)) return;
    if (asserted_before(context, tail)) return;

    const bare = without_comments(tokens);
    if (spells_a_tuple(bare)) return;

    if (!is_computed(context, bare)) {
        if (!bound_to_a_computation(context, body, bare)) return;
    }

    assert(bare.len > 0);

    report_a_value(sink, tail.span(), name);
}

fn tail_within(context: *const Context, body: View) ?View {
    var tail = support.tail_site(context, body) orelse return null;

    for (0..tail_depth_max) |_| {
        if (tail.category() != .block) return tail;

        const inner = support.tail_site(context, tail) orelse return null;

        assert(inner.index() > tail.index());

        tail = inner;
    }

    return null;
}

fn report_a_value(sink: *Sink, span: Span, name: []const u8) void {
    const named = scan.utf8_or(name, "the name");

    assert(named.len <= @max(name.len, "the name".len));
    if (name.len > 0) assert(named.len > 0);

    if (named.len == 0) {
        sink.report(span, "the function returns an unasserted value");

        return;
    }

    sink.report_formatted(span, "the function {s} returns an unasserted value", .{named});
}

fn covers(outer: Span, inner: Span) bool {
    if (inner.offset < outer.offset) return false;
    if (inner.end() > outer.end()) return false;

    assert(inner.length <= outer.length);

    return true;
}

fn carries_a_value(context: *const Context, node: View, body: View, spelled: []const u8) bool {
    if (spelled.len > 0) return scylla.Calls.is_value(spelled);
    if (context.conventions.returns_are_spelled) return false;

    const outer = body.span();

    assert(outer.end() <= context.source.len);

    for (context.front.nodes_of(.@"return")) |position| {
        const statement = context.view(position);

        assert(statement.category() == .@"return");

        if (!covers(outer, statement.span())) continue;
        if (!owns(node, statement)) continue;

        var values = statement.children();
        if (values.next() != null) return true;
    }

    return false;
}

fn owns(node: View, statement: View) bool {
    const outer = statement.enclosing_function() orelse return false;

    assert(node.as_function() != null);
    assert(outer.index() < statement.index());

    if (std.meta.eql(outer.span(), node.span())) return true;
    if (outer.category() != .lambda) return false;

    const parent = outer.parent() orelse return false;
    return std.meta.eql(parent.span(), node.span());
}

fn returns_a_composite(context: *const Context, statement: View) bool {
    var values = statement.children();

    assert(statement.category() == .@"return");

    for (0..values.remaining) |_| {
        const value = values.next() orelse break;

        assert(value.index() > statement.index());

        switch (value.category()) {
            .function, .lambda => return true,
            else => {},
        }

        const tokens = without_comments(context.tokens_in(value.span()));
        if (spells_a_composite(context, tokens)) return true;
    }

    return returns_a_bare_tuple(context, statement);
}

fn returns_a_bare_tuple(context: *const Context, statement: View) bool {
    assert(statement.category() == .@"return");

    if (context.front.language != .python) return false;

    const tokens = without_comments(context.tokens_in(statement.span()));

    var depth: u32 = 0;

    for (tokens) |token| {
        if (token.opens_a_group_or_block()) depth += 1;
        if (token.closes_a_group_or_block()) depth -|= 1;
        if (depth > 0) continue;
        if (token.is_punctuation(.comma)) return true;
    }

    return false;
}

fn spells_a_composite(context: *const Context, tokens: []const Token) bool {
    const opens = if (tokens.len > 0) context.text(tokens[0]) else "";
    if (opens.len == 0) return true;
    if (scan.word_in(&composite_openers, opens)) return true;
    return spells_a_tuple(tokens);
}

fn spells_a_tuple(tokens: []const Token) bool {
    if (tokens.len < 2) return false;
    if (!tokens[0].is_punctuation(.paren_open)) return false;
    if (!tokens[tokens.len - 1].is_punctuation(.paren_close)) return false;

    var depth: u32 = 0;

    for (tokens[0 .. tokens.len - 1]) |token| {
        if (token.opens_a_group_or_block()) depth += 1;

        if (token.closes_a_group_or_block()) {
            if (depth <= 1) return false;

            depth -= 1;
        }

        if (depth == 1) {
            if (token.is_punctuation(.comma)) return true;
        }
    }

    assert(depth >= 1);

    return false;
}

fn returns_a_closure(statement: View) bool {
    const lambda = statement.ancestor_of(.lambda) orelse return false;

    assert(lambda.category() == .lambda);
    assert(lambda.index() < statement.index());

    return lambda.ancestor_of(.@"return") != null;
}

fn returns_a_checked_value(context: *const Context, block: View, statement: View) bool {
    var values = statement.children();

    assert(block.category() == .block);

    for (0..values.remaining) |_| {
        const value = values.next() orelse break;

        assert(value.index() > statement.index());

        if (!is_checked(context, block, context.tokens_in(value.span()))) {
            return asserted_before(context, statement);
        }
    }

    return true;
}

fn returns_without_a_postcondition(
    context: *const Context,
    block: View,
    statement: View,
    spelled: []const u8,
) bool {
    var values = statement.children();
    var count: u32 = 0;
    var computed = false;
    var erroneous = false;
    var flagged = false;

    assert(statement.category() == .@"return");

    for (0..values.remaining) |_| {
        const value = values.next() orelse break;
        const tokens = without_comments(context.tokens_in(value.span()));

        count += 1;
        computed = is_computed(context, tokens) or bound_to_a_computation(context, block, tokens);
        erroneous = names_an_error(context, tokens);
        flagged = names_a_success_flag(context, tokens);
    }

    assert(values.remaining == 0);

    if (count == 0) return false;

    if (count == 1) {
        if (computed) return erroneous;
        return true;
    }

    if (erroneous) return true;
    if (flagged) return true;
    return scan.find(spelled, "error") != null;
}

fn bound_to_a_computation(context: *const Context, block: View, value: []const Token) bool {
    const bare = without_comments(value);
    if (bare.len != 1) return false;
    if (bare[0].kind != .identifier) return false;

    const name = context.text(bare[0]);
    const outer = block.span();

    assert(name.len > 0);

    for (binding_categories) |category| {
        for (context.front.nodes_of(category)) |position| {
            const node = context.view(position);

            assert(node.category() == category);

            if (!covers(outer, node.span())) continue;
            if (node.span().offset >= bare[0].offset) continue;

            const declaration = node.as_declaration() orelse continue;
            if (!binds(context, declaration, name)) continue;

            const held = declaration.value() orelse continue;
            const tokens = without_comments(context.tokens_in(held.span()));
            if (is_computed(context, tokens)) return true;
        }
    }

    return false;
}

fn binds(context: *const Context, declaration: Declaration, name: []const u8) bool {
    var names = declaration.names();

    assert(name.len > 0);

    for (0..names.remaining()) |_| {
        const position = names.next() orelse return false;
        if (std.mem.eql(u8, context.front_text(position), name)) return true;
    }

    return false;
}

fn casts(context: *const Context, text: []const u8) bool {
    for (context.grammar.cast_words) |word| {
        const bare = if (std.mem.startsWith(u8, word, "@")) word[1..] else word;

        assert(word.len > 0);
        assert(bare.len <= word.len);

        if (word[word.len - 1] == '*') {
            if (std.mem.startsWith(u8, text, word[0 .. word.len - 1])) return true;

            continue;
        }

        if (std.mem.eql(u8, text, word)) return true;
        if (std.mem.eql(u8, text, bare)) return true;
    }

    return false;
}

fn is_numeric(context: *const Context, spelled: []const u8) bool {
    var text = scan.trim_ascii(spelled);

    for (return_markers) |marker| {
        if (std.mem.startsWith(u8, text, marker)) text = trim_start(text[marker.len..]);
    }

    assert(text.len <= spelled.len);

    for (0..wrapper_peel_max) |_| {
        const inner = peeled(context, stripped_type(text));

        assert(inner.len <= text.len);

        if (std.mem.eql(u8, inner, text)) break;

        text = inner;
    }

    return scan.word_in(&numeric_types, text);
}

fn peeled(context: *const Context, spelled: []const u8) []const u8 {
    var text = scan.trim_ascii(spelled);

    for (wrapper_markers) |marker| {
        if (std.mem.startsWith(u8, text, marker)) text = trim_start(text[marker.len..]);
    }

    if (std.mem.startsWith(u8, text, "(")) text = text[1..];

    for (context.conventions.optional_markers) |marker| {
        assert(marker.len > 0);

        if (!std.mem.startsWith(u8, text, marker)) continue;

        switch (marker[marker.len - 1]) {
            '<', '(', '[' => {
                text = text[marker.len..];

                break;
            },
            else => {},
        }
    }

    const end = std.mem.findAny(u8, text, ",>)]|") orelse text.len;
    const result = scan.trim_ascii(text[0..end]);

    assert(result.len <= spelled.len);

    return result;
}

fn is_computed(context: *const Context, value: []const Token) bool {
    var named = false;
    var operates = false;

    assert(value.len <= context.tokens.len);

    if (negates_a_constant(context, value)) return false;

    for (value, 0..) |token, index| {
        if (token.kind == .string) continue;

        const text = context.text(token);

        if (token.kind == .identifier) named = true;

        if (token.kind == .punctuation) {
            if (is_arithmetic(context, text)) {
                if (applies_to_a_name(context, value, index)) operates = true;
            }
        }

        if (casts(context, text)) {
            named = true;
            operates = true;
        }
    }

    if (operates) assert(value.len > 0);

    return named and operates;
}

fn applies_to_a_name(context: *const Context, value: []const Token, index: usize) bool {
    assert(index < value.len);

    if (dereferences(context, value, index)) return false;

    if (index > 0) {
        if (names_before(context, value, index - 1)) return true;
    }

    return names_after(value, index + 1);
}

fn names_before(context: *const Context, value: []const Token, last: usize) bool {
    assert(last < value.len);

    var cursor = last;

    for (0..postfix_count_max) |_| {
        if (cursor == 0) break;
        if (!scan.word_in(&postfix_operators, context.text(value[cursor]))) break;

        cursor -= 1;
    }

    if (names_a_value(value[cursor])) return true;
    if (!value[cursor].closes_a_group()) return false;

    var depth: u32 = 0;

    for (0..cursor + 1) |_| {
        const token = value[cursor];
        if (names_a_value(token)) return true;

        if (token.closes_a_group()) depth += 1;
        if (token.opens_a_group()) depth -= 1;
        if (depth == 0) break;
        if (cursor == 0) return false;

        cursor -= 1;
    }

    if (cursor == 0) return false;
    return names_a_value(value[cursor - 1]);
}

fn names_after(value: []const Token, first: usize) bool {
    var cursor = first;

    for (0..prefix_operator_count_max) |_| {
        if (cursor >= value.len) return false;
        if (value[cursor].kind != .punctuation) break;
        if (value[cursor].opens_a_group()) break;

        cursor += 1;
    }

    if (cursor >= value.len) return false;
    if (names_a_value(value[cursor])) return true;
    if (!value[cursor].opens_a_group()) return false;

    var depth: u32 = 0;

    for (value[cursor..]) |token| {
        if (names_a_value(token)) return true;

        if (token.opens_a_group()) depth += 1;
        if (token.closes_a_group()) depth -= 1;
        if (depth == 0) return false;
    }

    return false;
}

fn names_a_value(token: Token) bool {
    return switch (token.kind) {
        .identifier => true,
        .keyword => |keyword| keyword == .other,
        else => false,
    };
}

fn dereferences(context: *const Context, value: []const Token, index: usize) bool {
    assert(index < value.len);

    const text = context.text(value[index]);

    assert(text.len > 0);

    if (!scan.word_in(&prefix_stars, text)) return false;
    if (index == 0) return true;
    return !value[index - 1].ends_a_value();
}

fn negates_a_constant(context: *const Context, value: []const Token) bool {
    if (value.len < 4) return false;
    if (!std.mem.eql(u8, context.text(value[0]), negation)) return false;

    assert(value[value.len - 1].end() <= context.source.len);

    var open: u32 = 1;

    for (value[1..]) |token| {
        if (token.is_punctuation(.paren_open)) break;

        if (token.kind != .identifier) {
            if (!token.is_punctuation(.dot)) return false;
        }

        open += 1;
    }

    assert(open <= value.len);

    if (open + 1 >= value.len) return false;
    if (!value[value.len - 1].is_punctuation(.paren_close)) return false;

    for (value[open + 1 .. value.len - 1]) |token| {
        if (!names_no_runtime_value(context, token)) return false;
    }

    return true;
}

fn names_no_runtime_value(context: *const Context, token: Token) bool {
    assert(token.end() <= context.source.len);

    return switch (token.kind) {
        .number, .string => true,
        .punctuation => token.is_punctuation(.comma),
        .identifier, .keyword => support.is_primitive_type(context, context.text(token)),
        .block_end, .block_start, .comment, .newline => false,
    };
}

fn is_arithmetic(context: *const Context, text: []const u8) bool {
    assert(text.len > 0);
    assert(text.len <= context.source.len);

    if (context.front.language == .go) return scan.word_in(&arithmetic_go, text);
    return scan.word_in(&arithmetic, text);
}

fn names_an_error(context: *const Context, value: []const Token) bool {
    if (value.len == 0) return false;

    const text = context.text(value[0]);

    assert(text.len == value[0].length);

    if (std.mem.eql(u8, text, "error")) return true;
    if (std.mem.eql(u8, text, "err")) return true;
    if (!std.mem.startsWith(u8, text, "err")) return false;

    assert(text.len >= "err".len);

    return text.len > 3;
}

fn names_a_success_flag(context: *const Context, value: []const Token) bool {
    const bare = without_comments(value);
    if (bare.len != 1) return false;
    if (bare[0].kind != .identifier) return false;
    return std.mem.eql(u8, context.text(bare[0]), success_flag_name);
}

fn without_comments(value: []const Token) []const Token {
    var start: usize = 0;

    for (value) |token| {
        if (token.kind != .comment) break;

        start += 1;
    }

    var end: usize = value.len;

    for (value[start..]) |_| {
        if (value[end - 1].kind != .comment) break;

        end -= 1;
    }

    assert(start <= end);
    assert(end <= value.len);

    return value[start..end];
}

fn is_checked(context: *const Context, block: View, value: []const Token) bool {
    const bare = without_comments(value);

    assert(block.category() == .block);

    if (bare.len == 0) return true;
    if (bare.len != 1) return false;

    const token = bare[0];
    const text = context.text(token);

    assert(text.len == token.length);

    switch (token.kind) {
        .number, .string => return true,
        .identifier => {},
        else => return scan.word_in(&literals, text),
    }

    if (scan.word_in(&literals, text)) return true;
    return asserted(context, block, text);
}

fn asserted_before(context: *const Context, statement: View) bool {
    const tokens = context.tokens;
    const start = stream.index_starting_from(tokens, statement.span().offset);

    assert(start <= tokens.len);

    if (start == 0) return false;

    var end = start;

    for (0..start) |_| {
        end -= 1;

        if (separates(tokens[end])) continue;
        if (tokens[end].kind == .block_start) return false;

        break;
    }

    var first = end;

    for (0..end) |_| {
        if (stops(tokens[first - 1])) break;

        first -= 1;
    }

    assert(first <= end);
    assert(end < start);

    for (tokens[first .. end + 1]) |token| {
        if (token.is_keyword(.assert)) return true;
    }

    return false;
}

fn separates(token: Token) bool {
    const result = switch (token.kind) {
        .newline, .block_end => true,
        else => token.is_punctuation(.semicolon),
    };

    if (result) assert(!token.opens_a_group_or_block());

    return result;
}

fn stops(token: Token) bool {
    const result = switch (token.kind) {
        .newline, .block_start, .block_end => true,
        else => token.is_punctuation(.semicolon),
    };

    if (result) assert(!token.opens_a_group());

    return result;
}

fn stripped_type(spelled: []const u8) []const u8 {
    var text = scan.trim_ascii(spelled);

    for (0..reference_peel_max) |_| {
        if (!std.mem.startsWith(u8, text, "&")) break;

        text = trim_start(text[1..]);

        if (std.mem.startsWith(u8, text, "'")) {
            const index = std.mem.findAny(u8, text, scan.ascii_whitespace) orelse return text;

            text = trim_start(text[index..]);
        }

        if (std.mem.startsWith(u8, text, "mut ")) text = trim_start(text["mut ".len..]);
    }

    assert(text.len <= spelled.len);

    const bang = std.mem.findScalar(u8, text, '!') orelse return text;
    const result = trim_start(text[bang + 1 ..]);

    assert(result.len < text.len);

    return result;
}

fn trim_start(text: []const u8) []const u8 {
    const trimmed = std.mem.trimStart(u8, text, scan.ascii_whitespace);

    assert(trimmed.len <= text.len);
    if (trimmed.len > 0) assert(!scan.is_ascii_whitespace(trimmed[0]));

    return trimmed;
}

fn asserted(context: *const Context, block: View, name: []const u8) bool {
    var calls = support.calls_within(context, block.span());

    assert(name.len > 0);

    for (0..calls.remaining) |_| {
        const call = calls.next() orelse break;
        const span = call.span();

        assert(covers(block.span(), span));

        const tokens = context.tokens_in(span);
        if (tokens.len == 0) continue;
        if (!tokens[0].is_keyword(.assert)) continue;
        if (scan.find_word(context.span_text(span), name)) return true;
    }

    return false;
}

fn expect_count(language: Language, source: []const u8, count: u32) !void {
    assert(source.len > 0);
    assert(count <= testing.limits.diagnostic_count_max);

    var findings = try testing.analyze(@This(), language, source);
    defer findings.deinit();

    if (findings.count() != count) findings.print();

    try std.testing.expectEqual(count, findings.count());
}

test "an unasserted return is reported" {
    const source = "fn read(a: u32) -> u32 {\n    let total = 1;\n    return total + a;\n}\n";

    var findings = try testing.analyze(@This(), .rust, source);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
    try std.testing.expect(std.mem.find(u8, findings.message(0), "read") != null);
}

test "a hoisted computation is still a computed value" {
    const rust = "fn double(value: u32) -> u32 {\n    let doubled = value * 2;\n\n    return " ++
        "doubled;\n}\n";

    try expect_count(.rust, rust, 1);

    const tail = "fn double(value: u32) -> u32 {\n    let doubled = value * 2;\n\n    " ++
        "doubled\n}\n";

    try expect_count(.rust, tail, 1);

    const go = "package main\n\nfunc double(value int) int {\n\tdoubled := value * 2\n\n\t" ++
        "return doubled\n}\n";

    try expect_count(.go, go, 1);

    const python = "def double(value):\n    doubled = value * 2\n    return doubled\n";

    try expect_count(.python, python, 1);
}

test "a computation bound after the return does not feed it" {
    const later = "def tick():\n    nonlocal time\n    try:\n        return time\n" ++
        "    finally:\n        time = time + 1.0\n";

    const earlier = "def tick():\n    time = start + 1.0\n    return time\n";

    try testing.expect_quiet(@This(), .python, later);
    try expect_count(.python, earlier, 1);
}

test "a forwarded parameter is not computed" {
    const source =
        "fn same(value: u32) -> u32 {\n    let held = value;\n\n    return held;\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
}

test "a javascript function returning a computed value is reported" {
    const source = "function double(value) {\n    return value * 2;\n}\n";

    try expect_count(.javascript, source, 1);

    const asserted_source = "function double(value) {\n    const result = value * 2;\n\n    " ++
        "assert(result >= value);\n\n    return result;\n}\n";

    try testing.expect_quiet(@This(), .javascript, asserted_source);
}

test "a returned function or literal is not a computed value" {
    const closure = "function make(scale) {\n    return (value) => value * scale;\n}\n";

    try testing.expect_quiet(@This(), .javascript, closure);

    const object = "function make(scale) {\n    return { doubled: scale * 2 };\n}\n";

    try testing.expect_quiet(@This(), .javascript, object);
    try testing.expect_quiet(@This(), .python, "def make(scale):\n    return [scale * 2]\n");
}

test "a negated constant is a sentinel rather than a computed value" {
    const source = "fn floor(x: f64) f64 {\n    if (x == 0.0) return -std.math.inf(f64);\n\n" ++
        "    return -x;\n}\n";

    try expect_count(.zig, source, 1);
}

test "an expression bodied arrow function is a return site" {
    try expect_count(.javascript, "const double = (value) => value * 2;\n", 1);
}

test "a wrapped numeric return type is numeric" {
    const rust = "fn read(a: u32) -> Option<u32> {\n    return Some(a * 2);\n}\n";

    try expect_count(.rust, rust, 1);
    try expect_count(.zig, "fn read(a: u32) !u32 {\n    return a * 2;\n}\n", 1);

    const typescript = "function read(a: number): number | null {\n    return a * 2;\n}\n";

    try expect_count(.typescript, typescript, 1);
}

test "a braceless zig branch holds a return site" {
    const source = "fn scan(count: usize, other: usize) usize {\n    if (count > other) " ++
        "return count + 3;\n\n    return count + other;\n}\n";

    try expect_count(.zig, source, 2);
}

test "a zig switch prong holds a return site" {
    const source = "fn pick(kind: u8, other: usize) usize {\n    switch (kind) {\n        0 " ++
        "=> return other + 1,\n        else => return other + 2,\n    }\n}\n";

    try expect_count(.zig, source, 2);
}

test "a trailing comment does not make a literal a value" {
    const source =
        "def choose(flag):\n    if flag:\n        return False  # only one\n    return 1\n";

    try testing.expect_quiet(@This(), .python, source);
}

test "a block tail is judged by its own tail" {
    const source = "fn as_u32(value: usize) -> u32 {\n    #[cfg(debug_assertions)]\n    {\n" ++
        "        u32::try_from(value).expect(\"overflow\")\n    }\n" ++
        "    #[cfg(not(debug_assertions))]\n    {\n        value as u32\n    }\n}\n\n" ++
        "fn plain(value: usize) -> usize {\n    {\n        value\n    }\n}\n";

    try testing.expect_anchors(@This(), .rust, source, &.{.{ 8, 9 }});
}

test "a returned tuple is a composite literal" {
    const source = "fn f(x: u32, slope: f32) -> (f32, f32) {\n" ++
        "    (x as f32, (slope * x as f32) as f32)\n}\n\nfn g(a: u32, b: u32) -> (u32, u32) {\n" ++
        "    return (a + 1, b * 2);\n}\n\nfn h(a: u32, b: u32) -> u32 {\n    (a + 1) * b\n}\n";

    try testing.expect_anchors(@This(), .rust, source, &.{.{ 10, 5 }});
}

test "an assertion above a blank line covers the tail" {
    const source = "fn pair(value: u32) -> Option<(u32, u32)> {\n    assert!(value < 3);\n\n    " ++
        "Some((value, value + 1))\n}\n";

    const bare = "fn pair(value: u32) -> Option<(u32, u32)> {\n    let held = value;\n\n    " ++
        "Some((held, value + 1))\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
    try expect_count(.rust, bare, 1);
}

test "a returned go closure keeps its own returns" {
    const source = "func Minimum(n int) int {\n\tinner := func() int {\n\t\treturn n + 1\n\t" ++
        "}\n\t_ = inner\n\treturn n + 2\n}\n";

    try expect_count(.go, source, 2);
}

test "a rust tail expression is a return site" {
    const source = "fn read(a: u32) -> u32 {\n    let base = 1;\n    compute() + a + base\n}\n";

    try expect_count(.rust, source, 1);
}

test "a tail declaration is not a return site" {
    try testing.expect_quiet(@This(), .rust, "fn read() -> u32 {\n    let total = 1;\n}\n");
}

test "a non numeric return type is quiet" {
    const source = "fn read() -> Reader {\n    let total = 1;\n    return total;\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
}

test "a literal return is quiet" {
    try testing.expect_quiet(@This(), .rust, "fn read() -> u32 {\n    return 0;\n}\n");
}

test "an asserted return is quiet" {
    const source = "fn read() -> u32 {\n    let total = 1;\n    assert!(total > 0);\n" ++
        "return total;\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
}

test "a multi value return checks every value" {
    const source = "func read(a int, b int) int {\n\tassert(a > 0)\n\tx := 1\n" ++
        "\t_ = x\n\treturn a + b\n}\n";

    try expect_count(.go, source, 1);
}

test "a multi value return with every value asserted is quiet" {
    const source = "func read(a int, b int) (int, int) {\n\tassert(a > 0)\n" ++
        "\tassert(b > 0)\n\tx := 1\n\t_ = x\n\treturn a, b\n}\n";

    try testing.expect_quiet(@This(), .go, source);
}

test "a multi value return whose last value is the ok flag is fallible" {
    const source = "package p\n\nget :: proc(b: []byte) -> (f64, bool) {\n" ++
        "\tv, ok := read(b)\n\treturn transmute(f64)v + 1, ok\n}\n\n" ++
        "done :: proc(b: []byte) -> (f64, bool) {\n\tv, finished := read(b)\n" ++
        "\treturn transmute(f64)v + 1, finished\n}\n";

    try testing.expect_anchors(@This(), .odin, source, &.{.{ 10, 2 }});
}

test "a call is one unasserted value however many arguments it takes" {
    const source = "func read(a int) int {\n\tassert(a > 0)\n\tx := 1\n\t_ = x\n" ++
        "\treturn f(a, 1) + 1\n}\n";

    try expect_count(.go, source, 1);
}

test "a leading comment does not make a value unreadable" {
    const source = "def choose(flag):\n    if flag:\n        return  # only one\n    return 1\n";

    try testing.expect_quiet(@This(), .python, source);
}

test "a comment before a returned literal is not part of it" {
    const source = "fn read(sector: u32) -> u32 {\n    let value = sector;\n    return /* " ++
        "note */ 0;\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
}

test "an assertion on the line before checks an expression return" {
    const asserted_source =
        "fn read(sector: u32) -> u32 {\n    assert!(sector > 0);\n    return sector + 1;\n}\n";

    try testing.expect_quiet(@This(), .rust, asserted_source);

    const bare = "fn read(sector: u32) -> u32 {\n    let value = sector + 1;\n    return " ++
        "value + 1;\n}\n";

    try expect_count(.rust, bare, 1);
}

test "an assertion in a nested block still precedes the return" {
    const python = "def read(sector):\n    if sector > 0:\n        assert sector > 0\n    " ++
        "return sector + 1\n";

    try testing.expect_quiet(@This(), .python, python);

    const rust = "fn read(sector: u32) -> u32 {\n    if sector > 0 {\n        assert!(sector " ++
        "> 0);\n    }\n    return sector + 1;\n}\n";

    try testing.expect_quiet(@This(), .rust, rust);
}

test "a checked tail expression is quiet" {
    try testing.expect_quiet(@This(), .rust, "fn helper() -> u32 {\n    0\n}\n");
}

test "a macro invocation is not a tail expression" {
    try testing.expect_quiet(@This(), .rust, "fn helper() -> String {\n    format!(\"x\")\n}\n");
}

test "a fused operator still computes the value" {
    try expect_count(.python, "def power(base):\n    return base ** 2\n", 1);
    try expect_count(.python, "def half(value):\n    return value // 2\n", 1);
    try expect_count(.javascript, "function next(count) {\n    return count++;\n}\n", 1);
    try expect_count(.odin, "floor :: proc(a: int) -> int {\n\treturn a %% 2\n}\n", 1);
    try expect_count(.zig, "fn wrap(a: u32) u32 {\n    return a +% 1;\n}\n", 1);
}

test "only a go left shift computes the value" {
    const go = "package main\n\nfunc grow(a int) int {\n\treturn a << 2\n}\n";
    const go_right = "package main\n\nfunc shrink(a int) int {\n\treturn a >> 2\n}\n";

    try expect_count(.go, go, 1);
    try testing.expect_quiet(@This(), .go, go_right);
    try testing.expect_quiet(@This(), .python, "def shrink(value):\n    return value >> 2\n");
}

test "a cast inside a template substitution is opaque" {
    const source = "function read(value: number): number {\n    return f(`${value as " ++
        "number}`);\n}\n";

    try testing.expect_quiet(@This(), .typescript, source);
}

test "a dereference or a jsx element is not computed" {
    const load = "fn load(a: *const u32) u32 {\n    return a.*;\n}\n";
    const prose = "function Empty() {\n    return <>No errors found.</>;\n}\n";
    const badge = "function Badge(run) {\n    return <Outcome run={run} />;\n}\n";

    try testing.expect_quiet(@This(), .zig, load);
    try testing.expect_quiet(@This(), .javascript, prose);
    try testing.expect_quiet(@This(), .javascript, badge);
}

test "a prefix star dereferences rather than multiplies" {
    const sources = [_]struct { Language, []const u8 }{
        .{ .rust, "fn size(&self) -> Option<usize> {\n    (**self).size()\n}\n" },
        .{ .rust, "fn count(&self, id: &str) -> u8 {\n    *self.get(id).unwrap_or(&0)\n}\n" },
        .{ .go, "func load(a *int) int {\n\treturn *a\n}\n" },
        .{ .python, "def total(*values) -> int:\n    return sum(*values)\n" },
    };

    for (sources) |held| {
        try testing.expect_quiet(@This(), held[0], held[1]);
    }
}

test "arithmetic on literals alone computes nothing" {
    const sources = [_]struct { Language, []const u8 }{
        .{
            .rust,
            "fn capacity(&self) -> usize {\n    self.capacity.unwrap_or(2 * (1 << 20))\n}\n",
        },
        .{ .rust, "fn limit(&self) -> Option<usize> {\n    Some(40 * (1 << 10))\n}\n" },
    };

    for (sources) |held| {
        try testing.expect_quiet(@This(), held[0], held[1]);
    }
}

test "arithmetic that reaches a name through a group or a call computes the value" {
    try expect_count(.rust, "fn scale(a: u32) -> u32 {\n    (a + 1) * 2\n}\n", 1);
    try expect_count(.rust, "fn tail(v: &[u8]) -> usize {\n    v.len() - 1\n}\n", 1);
    try expect_count(.rust, "fn shift(n: u32) -> u32 {\n    2 + n\n}\n", 1);
    try expect_count(.rust, "fn wrap(a: &[u32]) -> u32 {\n    a[0] * 2\n}\n", 1);
    try expect_count(.rust, "fn flip(a: i32) -> i32 {\n    2 * -a\n}\n", 1);
}

test "arithmetic on a receiver or an unwrapped value computes the value" {
    const total = "fn total(&self) -> usize {\n    self.a.len()\n        + self.b\n}\n";

    try expect_count(.zig, "fn bump(blah: ?u32) u32 {\n    return blah.? + 1;\n}\n", 1);
    try expect_count(.rust, total, 1);
    try expect_count(.javascript, "function greet() {\n    return \"Hi \" + this.name;\n}\n", 1);
}

test "a star between two values multiplies" {
    try expect_count(.rust, "fn scale(a: &u32, b: u32) -> u32 {\n    *a * b\n}\n", 1);
    try expect_count(.rust, "fn scale(a: u32, b: &u32) -> u32 {\n    a * *b\n}\n", 1);
    try expect_count(.python, "def square(value) -> int:\n    return value ** 2\n", 1);
}

test "a python bare tuple is a composite literal" {
    const source = "def search(name):\n    return \"%s__iexact\" % name, None\n\n\n" ++
        "def pair(count):\n    return count + 1, None\n\n\n" ++
        "def total(count):\n    return count + 1\n";

    try expect_count(.python, source, 1);
}
