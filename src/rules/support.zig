const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const stream = @import("../stream.zig");
const testing = @import("testing.zig");
const Category = scylla.View.Category;
const CallsFunction = scylla.Calls.Function;
const Context = @import("context.zig");
const Declarations = @import("declarations.zig");
const Frame = @import("frame.zig");
const Front = scylla.Front;
const FunctionView = scylla.View.Function;
const JavascriptKind = scylla.javascript.Kind;
const Language = scylla.Language;
const PythonKind = scylla.python.Kind;
const Span = scylla.Span;
const Token = scylla.Token;
const View = scylla.View;
const Views = Context.Views;
const scan = @import("../scan.zig");

const Before = struct {
    front: *const Front,
    offset: u32,

    fn starts_before(before: Before, position: u32) bool {
        return before.front.view(position).?.span().offset < before.offset;
    }
};

const CallsWithin = struct {
    front: *const Front,
    ordered: bool,
    positions: []const u32,
    remaining: u32,
    span: Span,

    pub fn next(calls: *CallsWithin) ?View {
        assert(calls.remaining <= calls.positions.len);

        const first = calls.positions.len - calls.remaining;

        for (calls.positions[first..]) |position| {
            const call = calls.front.view(position).?;
            const held = call.span();

            calls.remaining -= 1;

            if (calls.ordered) {
                if (held.offset > calls.span.end()) break;
            }

            if (held.offset < calls.span.offset) continue;
            if (held.end() > calls.span.end()) continue;

            assert(call.category() == .call);

            return call;
        }

        calls.remaining = 0;

        return null;
    }
};

const FunctionsAndBoundLambdas = struct {
    functions: Views,
    lambdas: Views,

    pub fn next(iterator: *FunctionsAndBoundLambdas) ?View {
        if (iterator.functions.next()) |function| {
            assert(function.category() == .function);

            return function;
        }

        for (0..iterator.lambdas.remaining) |_| {
            const lambda = iterator.lambdas.next() orelse return null;

            assert(lambda.category() == .lambda);

            if (bound_name_of(lambda) != null) return lambda;
        }

        return null;
    }
};

const Quotes = enum {
    f_string,
    template,

    pub fn closes(quotes: Quotes, token: Token) bool {
        return switch (quotes) {
            .f_string => token.exact_kind(PythonKind) == .f_string_end,
            .template => token.exact_kind(JavascriptKind) == .template_end,
        };
    }

    pub fn opens(quotes: Quotes, token: Token) bool {
        return switch (quotes) {
            .f_string => token.exact_kind(PythonKind) == .f_string_start,
            .template => token.exact_kind(JavascriptKind) == .template_start,
        };
    }
};

const binding_word = "let";
const comparison_names = [_][]const u8{"expect_value"};
const comparison_suffixes = [_][]const u8{ "_eq", "_ne" };
const comparison_word = "equal";

const diverging_types = [_][]const u8{
    "!",
    "Never",
    "NoReturn",
    "never",
    "typing.Never",
    "typing.NoReturn",
};

const double_underscore = "__";
const format_method = "fmt";
const implementation_target_word = "for";
const implementation_word = "impl";

const literal_words = [_][]const u8{
    "False",
    "None",
    "True",
    "false",
    "iota",
    "nil",
    "null",
    "true",
    "undefined",
};

const module_word = "mod";
const return_attribute_words = [_][]const u8{ "addrspace", "align", "callconv", "linksection" };
const self_word = "self";
const tab_stop_columns: u32 = 4;
const tautology_operators = [_][]const u8{ "===", "!==", "==", "!=", "<=", ">=", "<", ">" };
const trait_implementation_words = [_][]const u8{ "for", "impl" };
const truth_words = [_][]const u8{ "1", "True", "true" };
const type_word = "type";
const where_word = "where";

comptime {
    assert(stream.modifier_count_max > 0);
}

pub fn bare_call_names_a_method(context: *const Context, call: View, name: []const u8) bool {
    if (context.front.language != .rust) return false;

    const held = call.as_call() orelse return false;
    const callee = held.callee() orelse return false;
    const spelled = callee.text(context.source);

    if (held.receiver() != null) return false;
    if (std.mem.findAny(u8, spelled, ":.") != null) return false;

    const known = context.tables.function_of(name) orelse return false;
    const function = context.view(known.node).as_function() orelse return false;

    return function.receiver() != null;
}

pub fn path_call_leaves_the_file(context: *const Context, call: View) bool {
    if (context.front.language != .rust) return false;

    const held = call.as_call() orelse return false;
    const callee = held.callee() orelse return false;
    const spelled = callee.text(context.source);

    if (held.receiver() != null) return false;

    const separator = std.mem.findLast(u8, spelled, Context.path_separator) orelse return false;
    const path = spelled[0..separator];
    const start = if (std.mem.findLast(u8, path, Context.path_separator)) |at| at + 2 else 0;
    const qualifier = scan.trim_ascii(path[start..]);

    assert(separator < spelled.len);
    assert(qualifier.len <= path.len);

    if (qualifier.len == 0) return false;
    if (!std.ascii.isLower(qualifier[0])) return false;
    if (std.mem.eql(u8, qualifier, self_word)) return false;
    return !declares_a_module(context, qualifier);
}

fn declares_a_module(context: *const Context, name: []const u8) bool {
    const tokens = context.tokens;

    assert(name.len > 0);

    for (tokens, 0..) |token, index| {
        if (index + 1 >= tokens.len) break;
        if (token.length != module_word.len) continue;
        if (!std.mem.eql(u8, context.text(token), module_word)) continue;
        if (std.mem.eql(u8, context.text(tokens[index + 1]), name)) return true;
    }

    return false;
}

pub fn implements_a_trait(context: *const Context, token: u32) bool {
    assert(token < context.tokens.len);

    var frames = Frame.covering(context, token);

    for (0..context.front.node_count()) |_| {
        const covering = frames.next() orelse return false;

        assert(covering.frame.covers(token));

        if (opens_a_trait_implementation(covering.frame.opening_line(context))) return true;
        if (continues_a_trait_implementation(context, covering.frame)) return true;
    }

    return false;
}

fn continues_a_trait_implementation(context: *const Context, frame: Frame) bool {
    const tokens = context.tokens;
    const end = @min(frame.start, @as(u32, @intCast(tokens.len)));
    if (frame.header >= end) return false;
    if (!std.mem.eql(u8, context.text(tokens[frame.header]), implementation_word)) return false;

    var depth: u32 = 0;

    for (tokens[frame.header..end]) |token| {
        const text = context.text(token);
        if (std.mem.eql(u8, text, where_word)) return false;

        if (token.kind == .punctuation) {
            if (std.mem.allEqual(u8, text, '<')) depth += token.length;
            if (std.mem.allEqual(u8, text, '>')) depth -|= token.length;
        }

        if (depth > 0) continue;
        if (std.mem.eql(u8, text, implementation_target_word)) return true;
    }

    return false;
}

fn opens_a_trait_implementation(opening: []const u8) bool {
    comptime assert(trait_implementation_words.len > 0);

    assert(std.mem.findScalar(u8, opening, '\n') == null);

    for (trait_implementation_words) |word| {
        if (!scan.find_word(opening, word)) return false;
    }

    return true;
}

pub fn formats_for_a_trait(context: *const Context, function: View) bool {
    const callable = function.as_function() orelse return false;
    const named = callable.name_token() orelse return false;
    const token = context.lexer_index_at(context.front_token(named).offset) orelse return false;

    assert(token < context.tokens.len);
    assert(context.tokens[token].offset == context.front_token(named).offset);

    if (!std.mem.eql(u8, context.text(context.tokens[token]), format_method)) return false;
    return implements_a_trait(context, token);
}

pub fn tail_site(context: *const Context, block: View) ?View {
    if (!context.conventions.returns_tail_expression) return null;

    const last = block.children().last() orelse return null;

    assert(last.index() > block.index());

    switch (last.category()) {
        .attribute, .branch, .declaration, .import, .loop, .match, .@"return" => return null,
        else => {},
    }

    const extent = last.span();
    const body = context.tokens_in(extent);
    if (invokes_a_macro(body)) return null;

    if (body.len > 0) {
        if (body[body.len - 1].is_punctuation(.semicolon)) return null;
    }

    const after = context.lexer_index_from(extent.end());

    if (after < context.tokens.len) {
        if (context.tokens[after].is_punctuation(.semicolon)) return null;
    }

    assert(last.category() != .@"return");

    return last;
}

fn invokes_a_macro(body: []const Token) bool {
    if (body.len < 2) return false;

    assert(body[0].offset <= body[1].offset);

    if (body[0].kind != .identifier) return false;
    return body[1].is_punctuation(.bang);
}

pub fn opens_with_a_word(context: *const Context, frame: Frame, words: []const []const u8) bool {
    if (words.len == 0) return false;
    if (frame.start <= frame.header) return false;

    assert(frame.header < frame.start);
    assert(frame.header < context.tokens.len);

    return scan.word_listed(words, context.text(context.tokens[frame.header]));
}

pub fn suspends_at(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);

    const token = context.tokens[index];
    const text = context.text(token);

    assert(text.len == token.length);

    if (token.kind == .keyword) {
        if (!scan.word_listed(context.conventions.suspension_words, text)) return false;
        if (!scan.word_listed(context.conventions.suspension_words_postfix, text)) return true;
        if (index == 0) return false;
        return context.tokens[index - 1].is_punctuation(.dot);
    }

    if (token.kind != .identifier) return false;
    if (!scan.word_listed(context.conventions.suspension_methods, text)) return false;
    if (index == 0) return false;
    if (index + 1 == context.tokens.len) return false;
    if (!context.tokens[index - 1].is_punctuation(.dot)) return false;
    return context.tokens[index + 1].is_punctuation(.paren_open);
}

pub fn column_after(columns: u32, byte: u8) u32 {
    assert(columns <= std.math.maxInt(u32) - tab_stop_columns);
    assert(byte != '\n');

    if (byte == '\t') return columns + tab_stop_columns - columns % tab_stop_columns;
    if (byte & 0xc0 == 0x80) return columns;
    return columns + 1;
}

pub fn in_signature(context: *const Context, offset: u32) bool {
    assert(offset <= context.source.len);

    return signature_owner(context, offset) != null;
}

pub fn function_returns_a_value(context: *const Context, function: *const CallsFunction) bool {
    if (!function.value) return false;

    const held = context.view(function.node).as_function() orelse return true;
    const span = returns_span(context, held) orelse return true;

    assert(span.end() <= context.source.len);

    const spelled = span.text(context.source);
    if (scan.word_listed(&diverging_types, spelled)) return false;
    return scylla.Calls.is_value(spelled);
}

pub fn returns_span(context: *const Context, function: FunctionView) ?Span {
    const span = function.returns_span() orelse return null;
    if (context.front.language != .zig) return span;

    const start = context.lexer_index_at(span.offset) orelse return span;
    if (start < 2) return span;
    if (!opens_a_return_attribute(context, start - 2)) return span;

    const first = return_type_start(context, start - 2) orelse return null;
    const end = return_type_end(context, function);
    const offset = context.tokens[first].offset;
    if (offset >= end) return null;

    const text = scan.trim_ascii(context.source[offset..end]);

    assert(text.len <= end - offset);

    return .{ .offset = offset, .length = @intCast(text.len) };
}

fn opens_a_return_attribute(context: *const Context, index: u32) bool {
    const tokens = context.tokens;
    if (index + 1 >= tokens.len) return false;
    if (!tokens[index + 1].is_punctuation(.paren_open)) return false;
    return scan.word_listed(&return_attribute_words, context.text(tokens[index]));
}

fn return_type_start(context: *const Context, word: u32) ?u32 {
    var index = word;

    assert(opens_a_return_attribute(context, word));

    for (0..return_attribute_words.len) |_| {
        if (!opens_a_return_attribute(context, index)) break;

        const close = context.pairs.partner_of(index + 1) orelse return null;

        assert(close > index);

        index = close + 1;
    }

    if (index >= context.tokens.len) return null;
    return index;
}

fn return_type_end(context: *const Context, function: FunctionView) u32 {
    const span = function.view.span();

    assert(span.end() <= context.source.len);

    if (function.view.child_first_of(.block)) |body| return body.span().offset;

    const text = scan.trim_ascii(span.text(context.source));
    const bare = std.mem.trimEnd(u8, text, ";");

    return span.offset + @as(u32, @intCast(bare.len));
}

pub fn signature_owner(context: *const Context, offset: u32) ?View {
    assert(offset <= context.source.len);

    for (Context.callable_categories) |category| {
        for (context.front.nodes_of(category)) |position| {
            const function = context.view(position);

            assert(function.category() == category);

            if (function.signature_covers(offset)) return function;
        }
    }

    return null;
}

pub fn literal_span(context: *const Context, index: u32) Span {
    assert(index < context.tokens.len);

    const token = context.tokens[index];
    const quotes = quotes_of(context.front.language) orelse return token.span();
    if (!quotes.opens(token)) return token.span();

    var depth: u32 = 0;
    var end = token.end();

    for (context.tokens[index..]) |piece| {
        depth = quote_depth(quotes, depth, piece);
        end = piece.end();

        if (depth == 0) break;
    }

    assert(end > token.offset);
    assert(end <= context.source.len);

    return .{ .offset = token.offset, .length = end - token.offset };
}

pub fn literal_start_of(context: *const Context, index: u32) u32 {
    assert(index < context.tokens.len);

    const tokens = context.tokens;
    const quotes = quotes_of(context.front.language) orelse return index;
    if (!quotes.closes(tokens[index])) return index;

    var depth: u32 = 0;
    var cursor = index + 1;

    while (cursor > 0) {
        cursor -= 1;

        if (quotes.closes(tokens[cursor])) depth += 1;
        if (!quotes.opens(tokens[cursor])) continue;

        assert(depth > 0);

        depth -= 1;

        if (depth == 0) return cursor;
    }

    assert(cursor == 0);

    return index;
}

pub fn quote_depth(quotes: Quotes, depth: u32, token: Token) u32 {
    if (quotes.opens(token)) return depth + 1;
    if (quotes.closes(token)) return depth -| 1;
    return depth;
}

pub fn quotes_of(language: Language) ?Quotes {
    return switch (language) {
        .javascript, .typescript => .template,
        .python => .f_string,
        else => null,
    };
}

pub fn is_literal_constant(text: []const u8) bool {
    const literal = scan.word_in(&literal_words, text);

    if (literal) assert(text.len > 0);

    return literal;
}

pub fn is_primitive_type(context: *const Context, text: []const u8) bool {
    for (context.grammar.primitive_types) |marker| {
        assert(marker.len > 0);

        if (std.mem.endsWith(u8, marker, "*")) {
            if (std.mem.startsWith(u8, text, marker[0 .. marker.len - 1])) return true;

            continue;
        }

        if (std.mem.eql(u8, text, marker)) return true;
    }

    return false;
}

pub fn is_type_level(context: *const Context, frame: Frame) bool {
    assert(frame.header < context.tokens.len);

    if (returns_a_namespace(context, frame)) return true;
    if (!context.conventions.types_are_values) return false;

    const first = frame.header + 1;
    const last = @min(frame.start, @as(u32, @intCast(context.tokens.len)));
    if (first >= last) return false;

    for (context.tokens[first..last], first..) |token, offset| {
        assert(offset > 0);

        if (token.kind != .identifier) continue;
        if (!std.mem.eql(u8, context.text(token), type_word)) continue;
        if (context.tokens[offset - 1].is_punctuation(.colon)) return true;
    }

    return false;
}

fn returns_a_namespace(context: *const Context, frame: Frame) bool {
    if (!context.conventions.types_are_values) return false;
    if (frame.start < 2) return false;

    assert(frame.header < context.tokens.len);
    assert(frame.start <= context.tokens.len);

    const spelled = context.tokens[frame.start - 1];
    const closing = context.tokens[frame.start - 2];

    if (spelled.kind != .identifier) return false;
    if (!std.mem.eql(u8, context.text(spelled), type_word)) return false;
    return closing.is_punctuation(.paren_close);
}

pub fn assert_arguments(context: *const Context, index: u32) ?Context.TokenRange {
    assert(index < context.tokens.len);
    assert(context.tokens[index].is_keyword(.assert) or context.tokens[index].kind == .identifier);

    const line = stream.statement_end(context.tokens, index + 1);
    var open = index + 1;

    if (skips_a_bang(context, open, line)) open += 1;
    if (skips_a_method(context, open, line)) open += 2;

    assert(open <= line);

    if (open < line) {
        if (context.tokens[open].is_punctuation(.paren_open)) {
            const group = context.pairs.arguments_of(open) orelse return null;

            assert(group.first == open);

            if (arguments_whole(context, group.last, line)) {
                return .{ .end = group.last + 1, .start = open };
            }
        }
    }

    if (!context.conventions.assertions_omit_parentheses) return null;
    if (open >= line) return null;
    return .{ .end = line, .start = open };
}

fn skips_a_bang(context: *const Context, open: u32, line: u32) bool {
    assert(open <= line);
    assert(line <= context.tokens.len);

    if (!context.conventions.macros_invoke_with_bang) return false;
    if (open >= line) return false;
    return context.tokens[open].is_punctuation(.bang);
}

fn skips_a_method(context: *const Context, open: u32, line: u32) bool {
    assert(open <= line);
    assert(line <= context.tokens.len);

    if (open + 2 >= line) return false;
    if (!context.tokens[open].is_punctuation(.dot)) return false;
    return context.tokens[open + 1].kind == .identifier;
}

fn arguments_whole(context: *const Context, close: u32, line: u32) bool {
    assert(close < context.tokens.len);
    assert(context.tokens[close].is_punctuation(.paren_close));

    if (close + 1 >= line) return true;
    if (context.tokens[close + 1].is_punctuation(.comma)) return true;
    return !context.conventions.assertions_omit_parentheses;
}

pub fn assert_condition(context: *const Context, index: u32) ?Context.TokenRange {
    const arguments = assert_arguments(context, index) orelse return null;

    assert(arguments.start < arguments.end);

    if (!parenthesised(context, arguments)) {
        const end = statement_argument_end(context, arguments.start, arguments.end);
        return .{ .end = end, .start = arguments.start };
    }

    if (context.conventions.assertion_condition_spans_arguments) return arguments;

    const last = arguments.end - 1;
    const group: scylla.Brackets.Range = .{ .first = arguments.start, .last = last };
    var first = arguments.start + 1;

    if (assert_names_a_receiver(context, index, arguments.start)) {
        if (context.conventions.assertion_helpers_take_a_context_first) {
            const skipped = context.pairs.argument_end(first, group);

            first = @min(skipped + 1, last);

            assert(first <= last);
        }
    }

    const end = context.pairs.argument_end(first, group);

    assert(end <= last);

    return .{ .end = end, .start = first };
}

fn parenthesised(context: *const Context, arguments: Context.TokenRange) bool {
    assert(arguments.start < arguments.end);
    assert(arguments.end <= context.tokens.len);

    if (!context.tokens[arguments.start].is_punctuation(.paren_open)) return false;

    const partner = context.pairs.partner_of(arguments.start) orelse return false;
    return partner == arguments.end - 1;
}

fn assert_names_a_receiver(context: *const Context, index: u32, open: u32) bool {
    assert(index < open);
    assert(open < context.tokens.len);

    if (open < index + 3) return false;
    return context.tokens[open - 2].is_punctuation(.dot);
}

fn statement_argument_end(context: *const Context, start: u32, end: u32) u32 {
    assert(start <= end);
    assert(end <= context.tokens.len);

    var depth: u32 = 0;

    for (context.tokens[start..end], start..) |token, offset| {
        if (token.opens_a_group_or_block()) depth += 1;
        if (token.closes_a_group_or_block()) depth -|= 1;
        if (depth > 0) continue;
        if (token.is_punctuation(.comma)) return @intCast(offset);
    }

    return end;
}

pub fn assertion_is_trivial(context: *const Context, index: u32) bool {
    const condition = assert_condition(context, index) orelse return false;
    if (condition.start >= condition.end) return false;

    assert(condition.end <= context.tokens.len);

    const extent = stream.span_of_range(context.tokens, condition.start, condition.end);
    const text = scan.stripped_group(context.span_text(extent));
    if (scan.word_in(&truth_words, text)) return !compares_two_values(context, index);

    for (tautology_operators) |operator| {
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

fn compares_two_values(context: *const Context, index: u32) bool {
    const tokens = context.tokens;

    assert(index < tokens.len);

    var name = context.text(tokens[index]);

    if (index + 2 < tokens.len) {
        const method = tokens[index + 2];

        if (tokens[index + 1].is_punctuation(.dot)) {
            if (method.kind == .identifier) name = context.text(method);
        }
    }

    assert(name.len > 0);

    return names_a_value_comparison(name);
}

pub fn names_a_value_comparison(name: []const u8) bool {
    assert(name.len > 0);

    if (scan.contains_folded(name, comparison_word)) return true;
    if (scan.word_listed(&comparison_names, name)) return true;

    for (comparison_suffixes) |suffix| {
        if (std.mem.endsWith(u8, name, suffix)) return true;
    }

    return false;
}

pub fn names_the_data_model(context: *const Context, name: []const u8) bool {
    assert(name.len > 0);

    if (!context.conventions.double_underscore_names_dictated) return false;
    if (name.len <= double_underscore.len * 2) return false;
    if (!std.mem.startsWith(u8, name, double_underscore)) return false;
    return std.mem.endsWith(u8, name, double_underscore);
}

pub fn names_the_discard(context: *const Context, name: []const u8) bool {
    const prefix = context.grammar.discard_prefix;
    if (prefix.len == 0) return false;

    var words = std.mem.splitScalar(u8, prefix, ' ');

    for (0..prefix.len + 1) |_| {
        const word = words.next() orelse return false;

        assert(word.len <= prefix.len);
        assert(std.mem.findScalar(u8, word, ' ') == null);

        if (word.len == 0) continue;
        if (std.mem.eql(u8, word, binding_word)) continue;
        return std.mem.eql(u8, name, word);
    }

    return false;
}

pub fn is_mutating_name(context: *const Context, name: []const u8) bool {
    const mutating = scan.word_listed(context.conventions.mutation_methods, name);

    if (mutating) assert(name.len > 0);

    return mutating;
}

pub fn calls_within(context: *const Context, span: Span) CallsWithin {
    const positions = context.front.nodes_of(.call);
    const ordered = context.enclosures.calls_ordered;
    const before: Before = .{ .front = context.front, .offset = span.offset };
    var first: usize = 0;

    if (ordered) first = std.sort.partitionPoint(u32, positions, before, Before.starts_before);

    assert(first <= positions.len);
    assert(span.end() <= context.source.len);

    return .{
        .front = context.front,
        .ordered = ordered,
        .positions = positions,
        .remaining = @intCast(positions.len - first),
        .span = span,
    };
}

pub fn functions_and_bound_lambdas(context: *const Context) FunctionsAndBoundLambdas {
    const iterator: FunctionsAndBoundLambdas = .{
        .functions = context.views(.function),
        .lambdas = context.views(.lambda),
    };

    assert(iterator.functions.remaining == iterator.functions.positions.len);
    assert(iterator.lambdas.remaining == iterator.lambdas.positions.len);

    return iterator;
}

pub fn bound_name_of(view: View) ?u32 {
    if (view.category() != .lambda) {
        const function = view.as_function() orelse return null;
        return function.name_token();
    }

    const parent = view.parent() orelse return null;
    const offset = view.span().offset;

    assert(view.category() == .lambda);
    assert(parent.index() < view.index());

    return switch (parent.category()) {
        .declaration => declared_name_of(parent, offset),
        .assignment => name_before(parent, offset),
        .expression => keyed_name_of(parent, view),
        .attribute,
        .block,
        .branch,
        .call,
        .condition,
        .except,
        .file,
        .function,
        .import,
        .lambda,
        .loop,
        .match,
        .name,
        .other,
        .parameter,
        .parameters,
        .@"return",
        .@"struct",
        .@"try",
        .type,
        .value,
        => null,
    };
}

fn declared_name_of(parent: View, offset: u32) ?u32 {
    assert(parent.category() == .declaration);

    if (parent.as_declaration()) |declaration| {
        var names = declaration.names();
        if (names.next()) |position| return position;
    }

    return name_before(parent, offset);
}

fn keyed_name_of(parent: View, view: View) ?u32 {
    assert(parent.category() == .expression);

    var children = parent.children();
    const key = children.next() orelse return null;
    const value = children.next() orelse return null;

    assert(key.index() < value.index());

    if (key.category() != .name) return null;
    if (!std.meta.eql(value.span(), view.span())) return null;

    var positions = key.positions();
    return positions.next();
}

fn name_before(parent: View, offset: u32) ?u32 {
    var names = parent.children_of(.name);

    for (0..names.remaining) |_| {
        const name = names.next() orelse return null;

        assert(name.category() == .name);
        assert(name.index() > parent.index());

        if (name.span().end() > offset) continue;

        var positions = name.positions();
        return positions.next();
    }

    return null;
}

const declaration_count_max: u32 = 256;

const Declared = struct {
    count: u32,
    source: []const u8,
    spans: [declaration_count_max]Span,

    fn contains(declared: *const Declared, name: []const u8) bool {
        return declared.count_of(name) > 0;
    }

    fn count_of(declared: *const Declared, name: []const u8) u32 {
        var found: u32 = 0;

        for (declared.spans[0..declared.count]) |held| {
            if (std.mem.eql(u8, held.text(declared.source), name)) found += 1;
        }

        assert(found <= declared.count);

        return found;
    }

    fn expect_named(declared: *const Declared, name: []const u8) !void {
        if (declared.contains(name)) return;

        declared.print();

        return error.TestExpectedName;
    }

    fn expect_unnamed(declared: *const Declared, name: []const u8) !void {
        if (!declared.contains(name)) return;

        declared.print();

        return error.TestUnexpectedName;
    }

    fn print(declared: *const Declared) void {
        std.debug.print("declared {d} names:\n", .{declared.count});

        for (declared.spans[0..declared.count]) |held| {
            std.debug.print("  {s}\n", .{held.text(declared.source)});
        }
    }
};

fn declared_of(language: Language, source: []const u8) !Declared {
    var declared: Declared = .{ .count = 0, .source = source, .spans = undefined };
    var fixture: testing.Fixture = undefined;

    try fixture.init(language, source);
    defer fixture.deinit();

    try declared_collect(&declared, &fixture.context);

    return declared;
}

fn declared_collect(declared: *Declared, context: *const Context) !void {
    var declarations = Declarations.of(context);

    for (0..declaration_count_max + 1) |_| {
        const declaration = declarations.next() orelse return;

        try std.testing.expect(declared.count < declaration_count_max);

        declared.spans[declared.count] = context.tokens[declaration.token].span();
        declared.count += 1;
    }
}

fn frame_first(context: *const Context, category: Category) !Frame {
    for (context.front.nodes_of(category)) |position| {
        if (Frame.of(context, context.view(position))) |frame| return frame;
    }

    return error.TestExpectedFrame;
}

fn expect_no_arguments(context: *const Context) !void {
    const index = for (context.tokens, 0..) |token, position| {
        if (token.is_keyword(.assert)) break position;
    } else return error.TestExpectedAssert;

    try std.testing.expectEqual(null, assert_arguments(context, @intCast(index)));
    try std.testing.expectEqual(null, assert_condition(context, @intCast(index)));
}

fn expect_namespace(expected: bool, context: *const Context) !void {
    const held = try frame_first(context, .function);

    try std.testing.expectEqual(expected, returns_a_namespace(context, held));
}

fn expect_type_level(expected: bool, context: *const Context) !void {
    const held = try frame_first(context, .function);

    try std.testing.expectEqual(expected, is_type_level(context, held));
}

fn expect_opening(context: *const Context) !void {
    const held = try frame_first(context, .@"struct");

    try std.testing.expectEqualStrings("type", held.opening_word(context));
    try std.testing.expectStringStartsWith(held.opening_line(context), "type Held struct");
}

const Enclosed = struct {
    language: Language,
    source: []const u8,
};

const enclosed_samples = [_]Enclosed{
    .{
        .language = .rust,
        .source = "impl Display for Point {\n" ++
            "    fn fmt(&self, formatter: &mut Formatter) -> Result {\n" ++
            "        let closure = |value: u32| {\n" ++
            "            if value > 0 {\n" ++
            "                return value;\n" ++
            "            }\n" ++
            "            0\n" ++
            "        };\n" ++
            "        match self.x {\n" ++
            "            0 => write!(formatter, \"zero\"),\n" ++
            "            _ => loop {\n" ++
            "                break write!(formatter, \"{}\", closure(1));\n" ++
            "            },\n" ++
            "        }\n" ++
            "    }\n" ++
            "}\n\nstruct Holder {\n    value: u32,\n}\n",
    },
    .{
        .language = .javascript,
        .source = "(function () {\n" ++
            "    class Widget {\n" ++
            "        render() {\n" ++
            "            try {\n" ++
            "                return [1, 2].map((item) => {\n" ++
            "                    if (item) {\n" ++
            "                        return item * 2;\n" ++
            "                    }\n" ++
            "                    return 0;\n" ++
            "                });\n" ++
            "            } catch (error) {\n" ++
            "                return null;\n" ++
            "            }\n" ++
            "        }\n" ++
            "    }\n" ++
            "    const make = function () { return new Widget(); };\n" ++
            "    for (const value of [make()]) { value.render(); }\n" ++
            "})();\n",
    },
    .{
        .language = .python,
        .source = "@decorated\ndef outer(value):\n" ++
            "    def inner(item):\n" ++
            "        return lambda other: item + other\n" ++
            "    try:\n" ++
            "        for index in range(value):\n" ++
            "            if index:\n" ++
            "                yield inner(index)(1)\n" ++
            "    except ValueError:\n" ++
            "        pass\n\n\n" ++
            "class Holder:\n" ++
            "    @property\n" ++
            "    def value(self):\n" ++
            "        return [x for x in range(3)]\n",
    },
    .{
        .language = .go,
        .source = "package main\n\ntype Holder struct {\n\tvalue int\n}\n\n" ++
            "func (holder *Holder) Run() int {\n" ++
            "\tcallback := func(item int) int {\n" ++
            "\t\tswitch item {\n" ++
            "\t\tcase 0:\n" ++
            "\t\t\treturn 1\n" ++
            "\t\tdefault:\n" ++
            "\t\t\tfor index := 0; index < item; index++ {\n" ++
            "\t\t\t\tif index > 2 {\n" ++
            "\t\t\t\t\treturn index\n" ++
            "\t\t\t\t}\n" ++
            "\t\t\t}\n" ++
            "\t\t}\n" ++
            "\t\treturn 0\n" ++
            "\t}\n" ++
            "\treturn callback(holder.value)\n" ++
            "}\n",
    },
    .{
        .language = .zig,
        .source = "const Holder = struct {\n    value: u32,\n\n" ++
            "    pub fn run(holder: *const Holder) u32 {\n" ++
            "        for (0..holder.value) |index| {\n" ++
            "            if (index > 2) return @intCast(index);\n" ++
            "        }\n\n" ++
            "        return switch (holder.value) {\n" ++
            "            0 => 1,\n" ++
            "            else => blk: {\n" ++
            "                break :blk 2;\n" ++
            "            },\n" ++
            "        };\n" ++
            "    }\n" ++
            "};\n",
    },
};

fn calls_agree(context: *const Context) !void {
    var calls: u32 = 0;

    try std.testing.expect(context.enclosures.calls_ordered);

    for ([_]Category{ .function, .block }) |category| {
        var holders = context.views(category);

        for (0..holders.remaining) |_| {
            const holder = holders.next() orelse break;

            calls += try calls_within_agree(context, holder.span());
        }
    }

    try std.testing.expect(calls > 0);
}

fn calls_within_agree(context: *const Context, span: Span) !u32 {
    var indexed = calls_within(context, span);
    var linear = context.views(.call);
    var count: u32 = 0;

    for (0..linear.remaining) |_| {
        const call = linear.next() orelse break;
        const held = call.span();
        if (held.offset < span.offset) continue;
        if (held.end() > span.end()) continue;

        const found = indexed.next() orelse return error.TestUnexpectedResult;

        try std.testing.expectEqual(call.index(), found.index());

        count += 1;
    }

    const surplus = indexed.next();

    try std.testing.expect(surplus == null);

    return count;
}

fn enclosures_agree(context: *const Context) !void {
    var functions: u32 = 0;
    var frames: u32 = 0;

    try std.testing.expect(context.front.node_count() > 0);

    for (0..context.source.len + 1) |offset| {
        const indexed = context.function_at(@intCast(offset));
        const linear = context.front.function_at(@intCast(offset));

        try std.testing.expectEqual(index_of_view(linear), index_of_view(indexed));

        if (indexed != null) functions += 1;
    }

    for (0..context.tokens.len) |token| {
        frames += try frames_agree(context, @intCast(token));
    }

    try std.testing.expect(functions > 0);
    try std.testing.expect(frames > 0);
}

fn index_of_view(view: ?View) ?u32 {
    const held = view orelse return null;
    return held.index();
}

fn frames_agree(context: *const Context, token: u32) !u32 {
    var indexed = Frame.covering(context, token);
    var count: u32 = 0;

    for (Frame.categories) |category| {
        var views = context.views(category);

        for (0..views.remaining) |_| {
            const view = views.next() orelse break;
            const expected = covering_linear(context, view, token) orelse continue;
            const found = indexed.next() orelse return error.TestUnexpectedResult;

            try std.testing.expectEqual(expected.view.index(), found.view.index());
            try std.testing.expectEqual(expected.frame.header, found.frame.header);
            try std.testing.expectEqual(expected.frame.start, found.frame.start);
            try std.testing.expectEqual(expected.frame.end, found.frame.end);

            count += 1;
        }
    }

    const surplus = indexed.next();

    try std.testing.expect(surplus == null);

    return count;
}

fn covering_linear(context: *const Context, view: View, token: u32) ?Frame.Covering {
    const offset = context.tokens[token].offset;
    const extent = view.span();
    const line = context.line_of(extent.end() -| 1);
    const limit = context.line_span(line).end();

    if (offset < extent.offset) return null;
    if (offset >= limit) return null;

    const frame = Frame.of(context, view) orelse return null;
    if (!frame.covers(token)) return null;
    return .{ .frame = frame, .view = view };
}

test "the calls within a span agree with a linear scan" {
    for (enclosed_samples) |sample| {
        var fixture: testing.Fixture = undefined;

        try fixture.init(sample.language, sample.source);
        defer fixture.deinit();

        try calls_agree(&fixture.context);
    }
}

test "the enclosures agree with a linear scan" {
    for (enclosed_samples) |sample| {
        var fixture: testing.Fixture = undefined;

        try fixture.init(sample.language, sample.source);
        defer fixture.deinit();

        try enclosures_agree(&fixture.context);
    }
}

test "an assertion with no argument names no arguments" {
    const sources = [_][]const u8{ "assert", "assert\n", "assert  " };

    for (sources) |source| {
        var fixture: testing.Fixture = undefined;

        try fixture.init(.python, source);
        defer fixture.deinit();

        try expect_no_arguments(&fixture.context);
    }
}

test "a parameter names itself past its attributes" {
    const declared = try declared_of(.rust, "fn f(#[allow(unused)] value: u32) {\n}\n");

    try declared.expect_named("value");
    try declared.expect_unnamed("allow");
}

test "a with expression binds nothing" {
    const source = "def generator(ctx):\n    with ctx:\n        return None\n";
    const declared = try declared_of(.python, source);

    try std.testing.expectEqual(1, declared.count_of("ctx"));
}

test "an annotated name outside a with still binds" {
    const declared = try declared_of(.python, "def f():\n    total: int = 0\n    return total\n");

    try declared.expect_named("total");
}

test "a struct pattern parameter binds nothing" {
    const declared = try declared_of(.rust, "fn f(Point { x, y }: Point) {\n}\n");

    try declared.expect_unnamed("Point");
}

test "a qualified name is not a binding" {
    const source = "fn f<'t, I>(mappings: I) -> HashMap<&'t str, Vec<String>>\nwhere\n" ++
        "I: IntoIterator<Item = (&'t GlobMatcher, &'t MappingTarget<'t>)>,\n{\n" ++
        "for mapping in mappings {\n" ++
        "if let (matcher, MappingTarget::MapTo(s)) = mapping {\n" ++
        "g(matcher, s);\n        }\n    }\n}\n";

    const declared = try declared_of(.rust, source);

    try declared.expect_unnamed("MappingTarget");
}

test "a name run binds each name" {
    const declared = try declared_of(.go, "package main\n\nvar first, second int\n");

    try declared.expect_named("first");
    try declared.expect_named("second");
}

test "a modifier does not close a statement" {
    const source = "fn f() void {\n    comptime var len: usize = 0;\n    _ = len;\n}\n";
    const declared = try declared_of(.zig, source);

    try declared.expect_named("len");
}

test "a zig comptime type parameter returns a namespace" {
    const source = "fn Held(comptime T: type) type {\n    return struct { value: T };\n}\n";

    var fixture: testing.Fixture = undefined;

    try fixture.init(.zig, source);
    defer fixture.deinit();

    try expect_namespace(true, &fixture.context);
}

test "a zig function returning a value is no namespace" {
    const source = "fn held(value: u32) u32 {\n    return value;\n}\n";

    var fixture: testing.Fixture = undefined;

    try fixture.init(.zig, source);
    defer fixture.deinit();

    try expect_namespace(false, &fixture.context);
}

test "a folded needle is found whatever the case" {
    try std.testing.expect(scan.contains_folded("HeldValue", "value"));
    try std.testing.expect(scan.contains_folded("value", "value"));
    try std.testing.expect(!scan.contains_folded("HeldValu", "value"));
    try std.testing.expect(!scan.contains_folded("", "value"));
    try std.testing.expect(!scan.contains_folded("value", ""));
}

test "a zig type parameter makes a declaration type level" {
    const source = "const Held = struct {\n    fn make(comptime T: type) T {\n" ++
        "        return undefined;\n    }\n};\n";

    var fixture: testing.Fixture = undefined;

    try fixture.init(.zig, source);
    defer fixture.deinit();

    try expect_type_level(true, &fixture.context);
}

test "a zig value parameter leaves it alone" {
    const source = "const Held = struct {\n    fn make(value: u32) u32 {\n" ++
        "        return value;\n    }\n};\n";

    var fixture: testing.Fixture = undefined;

    try fixture.init(.zig, source);
    defer fixture.deinit();

    try expect_type_level(false, &fixture.context);
}

test "a block opens with the word that declares it" {
    const source = "package main\n\ntype Held struct {\n\tvalue int\n}\n";

    var fixture: testing.Fixture = undefined;

    try fixture.init(.go, source);
    defer fixture.deinit();

    try expect_opening(&fixture.context);
}

test "a short declaration binds every name before it" {
    const source = "package main\n\nfunc run() {\n\tfirst, second, third := call()\n" ++
        "\t_, _, _ = first, second, third\n}\n";

    const declared = try declared_of(.go, source);

    try declared.expect_named("first");
    try declared.expect_named("second");
    try declared.expect_named("third");
}

test "a grouped declaration binds each line" {
    const source = "package main\n\nvar (\n\tfirst int\n\t// A comment between them.\n" ++
        "\tsecond int\n)\n";

    const declared = try declared_of(.go, source);

    try declared.expect_named("first");
    try declared.expect_named("second");
}

test "a grouped declaration skips a constructed value" {
    const source = "package main\n\nvar (\n\tfirst = make(map[string]int)\n\tsecond int\n)\n";
    const declared = try declared_of(.go, source);

    try declared.expect_named("first");
    try declared.expect_named("second");
    try declared.expect_unnamed("make");
}

test "a grouped declaration stops at its closing parenthesis" {
    const source = "package main\n\nvar (\n\tfirst int\n)\n\nfunc run(outside int) int {\n" ++
        "\treturn outside\n}\n";

    const declared = try declared_of(.go, source);

    try declared.expect_named("first");
    try std.testing.expectEqual(1, declared.count_of("outside"));
}

test "a name run in a group binds every name" {
    const declared = try declared_of(.go, "package main\n\nvar (\n\tfirst, second int\n)\n");

    try declared.expect_named("first");
    try declared.expect_named("second");
}

test "a parameter names itself past two attributes" {
    const source = "fn held(#[allow(unused)] #[cfg(test)] value: u32) {\n}\n";
    const declared = try declared_of(.rust, source);

    try declared.expect_named("value");
    try declared.expect_unnamed("allow");
    try declared.expect_unnamed("cfg");
}

test "a parameter names itself past a nested attribute" {
    const source = "fn held(#[cfg(any(test, feature = \"held\"))] value: u32) {\n}\n";
    const declared = try declared_of(.rust, source);

    try declared.expect_named("value");
    try declared.expect_unnamed("cfg");
}
