const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const safety = @import("../safety.zig");
const scan = @import("../../scan.zig");
const stream = @import("../../stream.zig");
const support = @import("../support.zig");
const testing = @import("../testing.zig");
const Category = scylla.View.Category;
const Context = @import("../context.zig");
const Language = scylla.Language;
const Rule = scylla.rule.Rule;
const Sink = scylla.rule.Sink;
const Span = scylla.Span;
const Token = scylla.Token;
const View = scylla.View;

pub const rule: Rule = .{
    .citations = &.{
        .{
            .standard = "TigerStyle",
            .text = "\"All errors must be handled. An analysis of production failures in " ++
                "distributed data-intensive systems found that the majority of catastrophic " ++
                "failures could have been prevented by simple testing of error handling code.\"",
        },
        .{
            .standard = "NASA",
            .text = "NASA P10 Rule 7: \"The return value of non-void functions must be checked " ++
                "by each calling function.\"",
        },
    },
    .code = "TS028",
    .default_on = true,
    .description = "An error is handled, propagated, or crashed on by name, never dropped.",
    .explanation = "",
    .fix_title = "",
    .fixable = .sometimes,
    .group = .stable,
    .name = "no-silent-error-swallow",
    .severity = .@"error",
    .summary = "An error must be handled, not silently discarded",
    .url = "",
};

const Capture = struct {
    head: u32,
    name: ?[]const u8,
};

const absence_methods = [_][]const u8{ "ok_or", "ok_or_else" };
const arm_arrow = "=>";
const binding_categories = [_]Category{ .declaration, .assignment };
const binding_scan_max: u32 = 2_048;
const binding_word = "let";
const bound_names_max: u32 = 16;
const capture_bar = "|";
const capture_scan_max: u32 = 4;
const closure_bars = "||";
const crash_macros = [_][]const u8{ "panic", "todo", "unimplemented", "unreachable" };
const defer_words = [_][]const u8{ "defer", "errdefer", "go" };
const deferral_markers = [_][]const u8{ "FIXME", "TODO" };

const directive_markers = @import("../directives.zig").words;

const discard_name = "_";
const dropping_categories = [_]Category{ .expression, .call };
const error_name = "err";
const error_variant = "Err";
const explanation_lines_max: u32 = 32;
const explanation_words = [_][]const u8{ "error", "ignore", "ignoring" };
const fallback_words = [_][]const u8{ "false", "nil", "true" };
const handler_names = [_][]const u8{ "catch", "then" };
const nil_words = [_][]const u8{ ".None", "nil" };
const or_else_word = "or_else";
const pattern_scan_max: u32 = 64;
const then_name = "then";

pub fn run(context: *const Context, sink: *Sink) void {
    assert(context.tokens.len <= std.math.maxInt(u32));

    for (context.tokens, 0..) |token, position| {
        const index: u32 = @intCast(position);

        if (token.is_keyword(.except)) handler_report(context, sink, index);

        if (token.is_keyword(.branch_else)) {
            if (captures(context, index + 1)) handler_report(context, sink, index);
        }

        if (token.kind == .identifier) {
            callback_report(context, sink, index);
            error_arm_report(context, sink, index);
        }

        if (token.is_keyword(.other)) fallback_report(context, sink, index);
    }

    for (binding_categories) |category| {
        for (context.front.nodes_of(category)) |position| {
            discard_report(context, sink, context.view(position));
        }
    }

    for (dropping_categories) |category| {
        for (context.front.nodes_of(category)) |position| {
            const node = context.view(position);

            dropped_report(context, sink, node);
            drop_report(context, sink, node);
        }
    }

    for (context.front.nodes_of(.call)) |position| {
        const node = context.view(position);

        assert(node.category() == .call);

        bare_report(context, sink, node);
        default_report(context, sink, node);
    }

    empty_error_branch(context, sink);
}

fn handler_report(context: *const Context, sink: *Sink, index: u32) void {
    assert(index < context.tokens.len);

    const capture = capture_skip(context, index + 1);

    assert(capture.head > index);

    if (!block_is_silent(context, capture.head, capture.name)) return;

    const first = call_start(context, index);

    assert(first <= index);

    if (explained_above(context, first)) return;

    sink.report(context.tokens[first].span(), "the handler drops the error it caught");
}

fn explained_above(context: *const Context, first: u32) bool {
    assert(first < context.tokens.len);

    const head = stream.line_start_of_token(context.tokens, context.source, first);
    var cursor = head;
    var line = context.line_of(context.tokens[head].offset);
    var explained = false;

    assert(head <= first);

    for (0..explanation_lines_max) |_| {
        if (cursor == 0) break;

        const comment = context.tokens[cursor - 1];
        if (comment.kind != .comment) break;
        if (context.line_of(comment.end() - 1) + 1 != line) break;
        if (!opens_its_line(context, comment)) break;
        if (defers_the_handling(context, comment)) return false;

        if (explains_a_swallow(context, comment)) explained = true;

        cursor -= 1;
        line = context.line_of(comment.offset);
    }

    return explained;
}

fn opens_its_line(context: *const Context, comment: Token) bool {
    assert(comment.kind == .comment);
    assert(comment.end() <= context.source.len);

    const span = context.line_span(context.line_of(comment.offset));

    assert(span.offset <= comment.offset);

    return scan.trim_ascii(context.source[span.offset..comment.offset]).len == 0;
}

fn defers_the_handling(context: *const Context, comment: Token) bool {
    assert(comment.kind == .comment);
    assert(comment.end() <= context.source.len);

    const text = context.text(comment);

    for (deferral_markers) |marker| {
        if (scan.find(text, marker) != null) return true;
    }

    return false;
}

fn explains_a_swallow(context: *const Context, comment: Token) bool {
    assert(comment.kind == .comment);
    assert(comment.end() <= context.source.len);

    const text = context.text(comment);

    for (directive_markers) |marker| {
        if (scan.find(text, marker) != null) return false;
    }

    for (explanation_words) |word| {
        if (scan.contains_folded(text, word)) return true;
    }

    return false;
}

fn captures(context: *const Context, index: u32) bool {
    assert(index > 0);

    if (index >= context.tokens.len) return false;

    const token = context.tokens[index];
    const captured = std.mem.eql(u8, context.text(token), capture_bar);

    if (captured) assert(token.length == capture_bar.len);

    return captured;
}

fn capture_skip(context: *const Context, start: u32) Capture {
    assert(start > 0);

    const none: Capture = .{ .head = start, .name = null };
    if (start >= context.tokens.len) return none;

    const token = context.tokens[start];

    if (token.is_punctuation(.paren_open)) {
        const close = context.pairs.partner_of(start) orelse return none;

        assert(close > start);

        const name: ?[]const u8 = if (close == start + 2) text_of(context, start + 1) else null;
        return .{ .head = close + 1, .name = name };
    }

    if (!std.mem.eql(u8, context.text(token), capture_bar)) return none;

    const end: u32 = @intCast(@min(start + capture_scan_max, context.tokens.len));

    for (context.tokens[start + 1 .. end], start + 1..) |held, offset| {
        if (!std.mem.eql(u8, context.text(held), capture_bar)) continue;

        const name: ?[]const u8 = if (offset == start + 2) text_of(context, start + 1) else null;

        assert(offset > start);
        assert(offset < end);

        return .{ .head = @intCast(offset + 1), .name = name };
    }

    return none;
}

fn block_is_silent(context: *const Context, start: u32, capture: ?[]const u8) bool {
    if (start >= context.tokens.len) return false;
    if (context.tokens[start].kind != .block_start) return false;

    var cursor = significant_after(context, start);

    assert(cursor > start);

    if (closes_a_block(context, cursor)) return true;

    const name = capture orelse return false;

    if (!text_is(context, cursor, discard_name)) return false;
    if (!punctuation_is(context, cursor + 1, .assign)) return false;
    if (!text_is(context, cursor + 2, name)) return false;

    assert(cursor + 2 < context.tokens.len);

    cursor = significant_after(context, cursor + 2);

    if (punctuation_is(context, cursor, .semicolon)) cursor = significant_after(context, cursor);

    assert(cursor > start);

    return closes_a_block(context, cursor);
}

fn significant_after(context: *const Context, index: u32) u32 {
    const count: u32 = @intCast(context.tokens.len);
    const next = @min(index + 1, count);
    const found = stream.significant_next(context.tokens, next, count) orelse count;

    assert(found >= next);
    assert(found <= count);

    return found;
}

fn callback_report(context: *const Context, sink: *Sink, index: u32) void {
    const token = context.tokens[index];
    const name = context.text(token);
    if (!scan.word_in(&handler_names, name)) return;
    if (index == 0) return;
    if (!context.tokens[index - 1].is_punctuation(.dot)) return;

    const arguments = context.pairs.arguments_of(index + 1) orelse return;
    const open = arguments.first;
    const close = arguments.last;

    assert(open < close);

    const first = if (std.mem.eql(u8, name, then_name)) first: {
        const end = context.pairs.argument_end(open + 1, arguments);
        if (end == close) return;

        break :first end + 1;
    } else open + 1;

    assert(first <= close);

    if (!empty_function_literal(context, first, close)) return;

    const end = context.tokens[close].end();

    assert(end > token.offset);

    sink.report(
        .{ .offset = token.offset, .length = end - token.offset },
        "the handler drops the error it caught",
    );
}

fn empty_function_literal(context: *const Context, first: u32, close: u32) bool {
    assert(first <= close);
    assert(close < context.tokens.len);

    const tokens = context.tokens[first..close];

    const block: u32 = for (tokens, 0..) |token, offset| {
        if (token.kind == .block_start) break @intCast(offset);
    } else return false;

    assert(block < tokens.len);

    if (!introduces_a_literal(context, tokens[0..block])) return false;
    if (!block_is_silent(context, first + block, null)) return false;

    const end = significant_after(context, first + block);
    return significant_after(context, end) == close;
}

fn introduces_a_literal(context: *const Context, tokens: []const Token) bool {
    assert(tokens.len <= context.tokens.len);

    for (tokens) |token| {
        if (token.is_keyword(.lambda)) return true;
        if (std.mem.eql(u8, context.text(token), arm_arrow)) return true;
    }

    return false;
}

fn fallback_report(context: *const Context, sink: *Sink, index: u32) void {
    if (!std.mem.eql(u8, context.text(context.tokens[index]), or_else_word)) return;
    if (index == 0) return;
    if (!context.tokens[index - 1].is_punctuation(.paren_close)) return;

    const open = context.pairs.open_of(index - 1) orelse return;

    assert(open < index - 1);

    if (!callee_is_fallible(context, open)) return;
    if (index + 1 >= context.tokens.len) return;

    const fallback = context.tokens[index + 1];

    const literal = switch (fallback.kind) {
        .number, .string => true,
        else => scan.word_in(&fallback_words, context.text(fallback)),
    };

    const silent = block_is_silent(context, index + 1, null);

    if (!silent) {
        if (!literal) return;
    }

    const last = if (silent) significant_after(context, index + 1) else index + 1;
    const first = call_start(context, index - 1);
    const start = context.tokens[first].offset;
    const end = context.tokens[last].end();

    assert(first < index);
    assert(last > index);
    assert(start < end);

    sink.report(
        .{ .offset = start, .length = end - start },
        "the fallback hides the error; handle it or crash on it by name",
    );
}

fn error_arm_report(context: *const Context, sink: *Sink, index: u32) void {
    const token = context.tokens[index];
    if (!std.mem.eql(u8, context.text(token), error_variant)) return;
    if (!punctuation_is(context, index + 1, .paren_open)) return;

    const arguments = context.pairs.arguments_of(index + 1) orelse return;
    const open = arguments.first;
    const close = arguments.last;
    if (names_a_variant(context, open, close)) return;

    const capture: ?[]const u8 = if (close == open + 2) text_of(context, open + 1) else null;
    const head = arm_head(context, close) orelse return;

    assert(open == index + 1);
    assert(head > close);

    if (head >= context.tokens.len) return;

    const unit = context.tokens[head].is_punctuation(.paren_open) and
        punctuation_is(context, head + 1, .paren_close);

    const silent = block_is_silent(context, head, capture);

    if (!silent) {
        if (!unit) return;
    }

    const last = if (silent) significant_after(context, head) else head + 1;
    const end = context.tokens[last].end();

    assert(last > head);
    assert(end > token.offset);

    sink.report(
        .{ .offset = token.offset, .length = end - token.offset },
        "the error arm catches the error and does nothing with it",
    );
}

fn names_a_variant(context: *const Context, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < context.tokens.len);

    for (context.tokens[open + 1 .. close]) |token| {
        if (context.is_path_separator(token)) return true;
    }

    return false;
}

fn arm_head(context: *const Context, close: u32) ?u32 {
    const after = significant_after(context, close);
    if (after >= context.tokens.len) return null;

    assert(after > close);

    const token = context.tokens[after];
    if (std.mem.eql(u8, context.text(token), arm_arrow)) return significant_after(context, after);
    if (!token.is_punctuation(.assign)) return null;

    const end: u32 = @intCast(@min(after + 1 + pattern_scan_max, context.tokens.len));
    var depth: u32 = 0;

    assert(after < end);

    for (context.tokens[after + 1 .. end], after + 1..) |held, offset| {
        if (held.opens_a_group()) depth += 1;
        if (held.closes_a_group()) depth -|= 1;

        if (depth == 0) {
            if (held.kind == .block_start) return @intCast(offset);
        }

        if (held.is_punctuation(.semicolon)) return null;
    }

    return null;
}

fn bare_report(context: *const Context, sink: *Sink, node: View) void {
    if (context.conventions.compiler_rejects_a_dropped_error) return;

    const span = node.span();
    const first = safety.span_start(context, span);
    const last = safety.span_end(context, span);
    const head = if (deferred(context, first)) first - 1 else first;

    assert(first <= last);
    assert(head <= first);

    if (!stream.opens_a_statement(context.tokens, head)) return;
    if (!ends_a_bare_statement(context, last)) return;
    if (invokes_a_macro(context, node)) return;

    const callee = safety.resolved(context, callee_leaf(context, node));
    const call = node.as_call() orelse return;
    const bare_method = support.bare_call_names_a_method(context, node, callee);
    const elsewhere = support.path_call_leaves_the_file(context, node);

    const dropped = if (call.receiver()) |owner|
        call_is_fallible(context, node, node) or returns_by_method(context, callee, owner)
    else
        !bare_method and !elsewhere and called_function_is_fallible(context, node, callee);

    if (!dropped) return;

    sink.report(span, "the call's error is dropped; handle it or crash on it by name");
}

fn invokes_a_macro(context: *const Context, node: View) bool {
    if (!context.conventions.macros_invoke_with_bang) return false;

    const call = node.as_call() orelse return false;
    const named = call.name_token() orelse return false;
    const name = context.front_token(named);
    const after = context.lexer_index_from(name.end());

    assert(name.end() <= context.source.len);

    if (after >= context.tokens.len) return false;
    return context.tokens[after].is_punctuation(.bang);
}

fn deferred(context: *const Context, first: u32) bool {
    assert(first <= context.tokens.len);

    if (first == 0) return false;

    const before = context.tokens[first - 1];
    if (!before.is_keyword(.other)) return false;

    const listed = scan.word_in(&defer_words, context.text(before));

    if (listed) assert(before.length > 0);

    return listed;
}

fn ends_a_bare_statement(context: *const Context, last: u32) bool {
    assert(last <= context.tokens.len);

    if (last == context.tokens.len) return true;

    const token = context.tokens[last];
    if (token.is_punctuation(.semicolon)) return true;
    if (context.conventions.returns_tail_expression) return false;
    if (token.kind == .block_end) return true;
    return !Token.is_significant(token.kind);
}

fn returns_by_method(context: *const Context, callee: []const u8, owner: View) bool {
    assert(callee.len <= context.source.len);

    if (!scan.word_listed(context.conventions.error_returning_methods, callee)) return false;

    const receiver = context.span_text(owner.span());

    assert(receiver.len <= context.source.len);

    return !names_an_import(context, receiver);
}

fn names_an_import(context: *const Context, receiver: []const u8) bool {
    assert(receiver.len <= context.source.len);

    if (receiver.len == 0) return false;

    for (receiver) |byte| {
        if (!scan.is_identifier_part(byte)) return false;
    }

    for (context.front.nodes_of(.import)) |position| {
        const import = context.view(position);

        assert(import.category() == .import);

        if (scan.find_word(context.span_text(import.span()), receiver)) return true;
    }

    return false;
}

fn default_report(context: *const Context, sink: *Sink, node: View) void {
    const methods = context.conventions.error_default_methods;

    assert(node.category() == .call);

    if (methods.len == 0) return;

    const method = callee_leaf(context, node);
    if (!scan.word_listed(methods, method)) return;

    const receiver = receiver_call(node) orelse return;

    assert(receiver.category() == .call);

    if (propagates_first(node)) return;
    if (converts_an_absence(context, method, receiver)) return;
    if (crashes_in_its_fallback(context, node)) return;
    if (!chain_is_fallible(context, node, receiver)) return;

    sink.report(node.span(), "the default hides the error; handle it or crash on it by name");
}

fn converts_an_absence(context: *const Context, method: []const u8, receiver: View) bool {
    assert(receiver.category() == .call);

    if (!scan.word_in(&absence_methods, method)) return false;

    const discards = context.conventions.error_discard_methods;
    return !scan.word_listed(discards, callee_leaf(context, receiver));
}

fn crashes_in_its_fallback(context: *const Context, node: View) bool {
    const call = node.as_call() orelse return false;
    var arguments = call.arguments();
    if (arguments.count() != 1) return false;

    const argument = arguments.next() orelse return false;
    if (argument.category() != .lambda) return false;

    const span = argument.span();
    const first = context.lexer_index_from(span.offset);
    const end = context.lexer_index_from(span.end());

    assert(first <= end);
    assert(end <= context.tokens.len);

    const body = closure_body_start(context, first, end) orelse return false;
    return crashes_only(context, body, end);
}

fn closure_body_start(context: *const Context, first: u32, end: u32) ?u32 {
    assert(first <= end);
    assert(end <= context.tokens.len);

    for (context.tokens[first..end], first..) |token, position| {
        const index: u32 = @intCast(position);

        if (token.is_keyword(.lambda)) {
            if (token.length == closure_bars.len) return index + 1;

            continue;
        }

        if (!token.is_punctuation(.other)) continue;
        if (std.mem.eql(u8, context.text(token), capture_bar)) return index + 1;
    }

    return null;
}

fn crashes_only(context: *const Context, body: u32, end: u32) bool {
    const tokens = context.tokens;
    const start = significant_from(context, body, end);

    assert(end <= tokens.len);

    if (start >= end) return false;

    var inner = start;
    var limit = end;

    if (tokens[start].kind == .block_start) {
        const partner = context.pairs.partner_of(start) orelse return false;
        if (partner >= end) return false;
        if (significant_from(context, partner + 1, end) != end) return false;

        inner = significant_from(context, start + 1, partner);
        limit = partner;
    }

    if (inner + 2 >= limit) return false;
    if (!scan.word_in(&crash_macros, context.text(tokens[inner]))) return false;
    if (!tokens[inner + 1].is_punctuation(.bang)) return false;

    const closed = context.pairs.partner_of(inner + 2) orelse return false;
    if (closed >= limit) return false;

    var after = significant_from(context, closed + 1, limit);
    const semicolon_follows = after < limit and tokens[after].is_punctuation(.semicolon);

    if (semicolon_follows) {
        after = significant_from(context, after + 1, limit);
    }

    return after == limit;
}

fn significant_from(context: *const Context, index: u32, limit: u32) u32 {
    assert(limit <= context.tokens.len);

    if (index >= limit) return limit;
    return stream.significant_next(context.tokens, index, limit) orelse limit;
}

fn propagates_first(node: View) bool {
    const call = node.as_call() orelse return false;
    const receiver = call.receiver() orelse return false;

    assert(node.category() == .call);
    assert(receiver.index() > node.index());

    return receiver.category() == .@"try";
}

fn receiver_call(node: View) ?View {
    const call = node.as_call() orelse return null;
    const receiver = call.receiver() orelse return null;

    assert(node.category() == .call);
    assert(receiver.index() > node.index());

    if (receiver.category() == .call) return receiver;
    return receiver.child_first_of(.call);
}

fn chain_is_fallible(context: *const Context, node: View, call: View) bool {
    var current = call;

    for (0..safety.call_head_max) |_| {
        assert(current.category() == .call);

        if (call_is_fallible(context, node, current)) return true;

        const callee = callee_leaf(context, current);
        if (!scan.word_listed(context.conventions.error_discard_methods, callee)) return false;

        const receiver = receiver_call(current) orelse return false;

        assert(receiver.index() > current.index());

        current = receiver;
    }

    return false;
}

fn callee_leaf(context: *const Context, call: View) []const u8 {
    assert(call.category() == .call);

    if (call.as_call()) |held| {
        if (held.name_token()) |named| return context.front_text(named);
    }

    const head = safety.call_head(context, call.span());

    assert(head.offset == call.span().offset);

    return leaf_name(context, head);
}

fn callee_is_fallible(context: *const Context, open: u32) bool {
    assert(open < context.tokens.len);

    if (open == 0) return false;

    const before = context.tokens[open - 1];
    if (before.kind != .identifier) return false;

    assert(before.offset <= context.tokens[open].offset);

    return function_is_fallible(context, safety.resolved(context, context.text(before)));
}

fn called_function_is_fallible(context: *const Context, node: View, name: []const u8) bool {
    assert(node.category() == .call);

    if (!function_is_fallible(context, name)) return false;

    const nested = nested_namesake(context, node, name) orelse return true;
    return signature_returns_an_error(context, nested);
}

fn function_is_fallible(context: *const Context, name: []const u8) bool {
    const known = context.tables.function_of(name) orelse return false;

    assert(name.len > 0);
    assert(std.mem.eql(u8, known.name.text(context.source), name));

    return returns_an_error(context, known);
}

fn returns_an_error(context: *const Context, known: *const scylla.Calls.Function) bool {
    return signature_returns_an_error(context, context.view(known.node));
}

fn nested_namesake(context: *const Context, node: View, name: []const u8) ?View {
    if (name.len == 0) return null;

    const enclosing = context.function_at(node.span().offset) orelse return null;
    const outer = enclosing.span();

    assert(outer.offset <= node.span().offset);

    for (context.front.nodes_of(.function)) |position| {
        const candidate = context.view(position);
        const span = candidate.span();
        if (span.offset <= outer.offset) continue;
        if (span.end() > outer.end()) continue;

        const function = candidate.as_function() orelse continue;
        const named = function.name_token() orelse continue;
        if (std.mem.eql(u8, context.front_text(named), name)) return candidate;
    }

    return null;
}

fn signature_returns_an_error(context: *const Context, view: View) bool {
    const function = view.as_function() orelse return false;
    const spelled = function.returns_span() orelse return false;
    const text = context.span_text(spelled);

    assert(spelled.end() <= context.source.len);

    if (spells_an_error(text)) return true;

    const comma = std.mem.findScalarLast(u8, text, ',') orelse return false;
    const tail = scan.trim_ascii(text[comma + 1 ..]);
    const closed = if (std.mem.endsWith(u8, tail, ")")) tail[0 .. tail.len - 1] else tail;
    const last = scan.trim_ascii(closed);
    const named = if (std.mem.findScalarLast(u8, last, ':')) |at| last[at + 1 ..] else last;

    assert(named.len <= text.len);

    return std.mem.eql(u8, scan.trim_ascii(named), "bool");
}

fn spells_an_error(text: []const u8) bool {
    if (scan.contains_folded(text, "error")) return true;
    if (scan.contains_folded(text, "errno")) return true;
    if (scan.find(text, "Result<") != null) return true;

    const trimmed = scan.trim_ascii(text);

    assert(trimmed.len <= text.len);

    if (std.mem.eql(u8, trimmed, "!")) return false;
    return std.mem.findScalar(u8, text, '!') != null;
}

fn call_start(context: *const Context, index: u32) u32 {
    assert(index < context.tokens.len);

    var first = stream.expression_start(context.tokens, context.source, index);

    for (0..safety.call_head_max) |_| {
        if (!context.tokens[first].is_punctuation(.paren_close)) break;

        const open = context.pairs.open_of(first) orelse break;

        assert(open < first);

        first = stream.expression_start(context.tokens, context.source, open);
    }

    assert(first <= index);

    return first;
}

fn dropped_report(context: *const Context, sink: *Sink, node: View) void {
    const methods = context.conventions.error_discard_methods;
    if (methods.len == 0) return;

    const bare = node.category() == .call;

    if (bare) {
        const parent = node.parent() orelse return;
        if (!safety.holds_statements(parent)) return;
    }

    const call = if (bare) node else node.children_of(.call).last() orelse return;
    const after = safety.span_end(context, call.span());

    assert(call.category() == .call);
    assert(after <= context.tokens.len);

    if (!punctuation_is(context, after, .semicolon)) return;

    const held = call.as_call() orelse return;
    const receiver = held.receiver() orelse return;
    const named = held.name_token() orelse return;

    assert(receiver.index() > call.index());
    assert(named < call.token_end());

    if (!scan.word_listed(methods, context.front_text(named))) return;

    sink.report(node.span(), "the error is dropped; handle it or crash on it by name");
}

fn discard_report(context: *const Context, sink: *Sink, node: View) void {
    const name = bound_name_last(context, node) orelse return;

    assert(name.length > 0);

    if (!discards_the_binding(context, context.span_text(name))) return;
    if (!assigns_at(context, safety.span_end(context, name))) return;

    const call = node.child_first_of(.call) orelse {
        const value = node.child_first_of(.value) orelse return;
        const text = scan.trim_ascii(context.span_text(value.span()));
        if (!std.mem.eql(u8, text, error_name)) return;

        sink.report(node.span(), "the error is assigned away; handle it or crash on it by name");

        return;
    };

    assert(call.category() == .call);

    if (!chain_is_fallible(context, node, call)) return;

    sink.report(
        node.span(),
        "the call's error is assigned away; handle it or crash on it by name",
    );
}

fn bound_name_last(context: *const Context, node: View) ?Span {
    const first = safety.span_start(context, node.span());
    const end: u32 = @intCast(@min(first + bound_names_max, context.tokens.len));
    var last: ?Span = null;

    assert(first <= end);
    assert(end <= context.tokens.len);

    for (context.tokens[first..end]) |token| {
        if (token.is_punctuation(.assign)) return last;
        if (token.is_punctuation(.assign_declare)) return last;
        if (stops_a_binding(token)) return null;

        if (token.kind == .identifier) last = token.span();
    }

    return null;
}

fn stops_a_binding(token: Token) bool {
    const stops = switch (token.kind) {
        .block_start, .newline => true,
        .punctuation => |punctuation| punctuation == .colon or punctuation == .semicolon,
        .block_end, .comment, .identifier, .keyword, .number, .string => false,
    };

    if (stops) assert(token.kind != .identifier);
    if (!stops) assert(token.kind != .newline);

    return stops;
}

fn discards_the_binding(context: *const Context, name: []const u8) bool {
    const prefix = context.grammar.discard_prefix;

    assert(name.len > 0);

    if (prefix.len == 0) return false;

    const discard = discard_word(prefix);

    assert(discard.len <= prefix.len);

    if (discard.len == 0) return false;
    if (std.mem.eql(u8, name, discard)) return true;
    if (!std.mem.eql(u8, discard, discard_name)) return false;
    return std.mem.startsWith(u8, name, discard_name);
}

fn discard_word(prefix: []const u8) []const u8 {
    assert(prefix.len > 0);

    var words = std.mem.splitScalar(u8, prefix, ' ');

    for (0..prefix.len + 1) |_| {
        const word = words.next() orelse break;
        if (word.len == 0) continue;
        if (std.mem.eql(u8, word, binding_word)) continue;

        assert(word.len <= prefix.len);

        return word;
    }

    return "";
}

fn call_is_fallible(context: *const Context, node: View, call: View) bool {
    assert(call.category() == .call);

    const callee = safety.resolved(context, callee_leaf(context, call));
    const receiver = if (call.as_call()) |held| held.receiver() else null;

    if (receiver == null) {
        if (support.path_call_leaves_the_file(context, call)) return false;
    }

    const known = if (receiver) |owner| known: {
        const tables = context.tables;
        if (tables.function_of(callee) == null) break :known null;

        const held = tables.receiver_type_of(node, owner) orelse break :known null;

        break :known tables.method_of(held, callee);
    } else context.tables.function_of(callee);

    const found = known orelse return false;

    assert(found.node < context.front.node_count());

    return returns_an_error(context, found);
}

fn drop_report(context: *const Context, sink: *Sink, node: View) void {
    const names = context.conventions.error_discard_names;
    if (names.len == 0) return;
    if (node.category() != .call) return;

    const parent = node.parent() orelse return;
    if (!safety.holds_statements(parent)) return;

    const name = node.child_first_of(.name) orelse return;
    const spelled = scan.trim_ascii(context.span_text(name.span()));

    assert(name.category() == .name);

    if (!scan.word_listed(names, spelled)) return;

    var calls = node.children_of(.call);
    const inner = calls.next() orelse return;

    assert(inner.category() == .call);

    if (!call_is_fallible(context, node, inner)) return;

    sink.report(node.span(), "the call's error is dropped; handle it or crash on it by name");
}

fn leaf_name(context: *const Context, span: Span) []const u8 {
    assert(span.end() <= context.source.len);

    var last: []const u8 = "";

    for (context.tokens_in(span)) |token| {
        if (token.kind == .identifier) last = context.text(token);
    }

    assert(last.len <= span.length);

    return last;
}

fn empty_error_branch(context: *const Context, sink: *Sink) void {
    for (context.front.nodes_of(.branch)) |position| {
        const node = context.view(position);
        const block = node.child_first_of(.block) orelse continue;
        const condition = condition_text(context, node, block) orelse continue;
        const name = checked_error_name(condition) orelse continue;
        const opening = safety.span_start(context, block.span());

        assert(node.category() == .branch);
        assert(name.len > 0);

        if (!block_is_silent(context, opening, name)) continue;
        if (follows_an_else(context, block)) continue;
        if (!names_an_error(context, node, condition, name)) continue;

        sink.report(node.span(), "the branch catches the error and does nothing with it");
    }
}

fn names_an_error(
    context: *const Context,
    node: View,
    condition: []const u8,
    name: []const u8,
) bool {
    assert(name.len > 0);
    assert(name.len < condition.len);

    if (std.mem.eql(u8, name, error_name)) return true;
    if (bound_in_the_header(condition, name)) return true;
    return bound_from_a_fallible_call(context, node, name);
}

fn condition_text(context: *const Context, node: View, block: View) ?[]const u8 {
    const first = safety.span_start(context, node.span());
    const opening = safety.span_start(context, block.span());
    if (opening <= first) return null;
    if (opening >= context.tokens.len) return null;

    var head = first;

    for (context.tokens[first..opening]) |token| {
        if (token.kind != .keyword) break;

        head += 1;
    }

    if (head >= opening) return null;

    const from = context.tokens[head].offset;
    const to = context.tokens[opening].offset;

    assert(head < opening);
    assert(from <= to);

    return context.source[from..to];
}

fn checked_error_name(condition: []const u8) ?[]const u8 {
    const semicolon = std.mem.findScalarLast(u8, condition, ';');
    const clause = if (semicolon) |at| condition[at + 1 ..] else condition;
    const at = scan.find(clause, "!=") orelse return null;
    const name = scan.trim_ascii(clause[0..at]);
    const value = scan.trim_ascii(clause[at + 2 ..]);

    assert(at + 2 <= clause.len);

    if (!scan.word_in(&nil_words, value)) return null;
    if (name.len == 0) return null;

    for (name) |byte| {
        if (!scan.is_identifier_part(byte)) return null;
    }

    assert(name.len < condition.len);

    return name;
}

fn bound_in_the_header(condition: []const u8, name: []const u8) bool {
    assert(name.len > 0);

    const at = std.mem.findScalarLast(u8, condition, ';') orelse return false;

    assert(at < condition.len);

    return scan.find_word(condition[0..at], name);
}

fn bound_from_a_fallible_call(context: *const Context, node: View, name: []const u8) bool {
    const first = safety.span_start(context, node.span());
    const function = context.function_at(node.span().offset);
    const floor = if (function) |held| safety.span_start(context, held.span()) else 0;

    assert(name.len > 0);

    var index = first;

    for (0..binding_scan_max) |_| {
        if (index <= floor) return false;

        index -= 1;

        const token = context.tokens[index];
        if (token.kind != .identifier) continue;
        if (!std.mem.eql(u8, context.text(token), name)) continue;
        if (!assigns_at(context, index + 1)) continue;

        assert(index < first);

        if (index > 0) {
            if (context.tokens[index - 1].is_punctuation(.comma)) return true;
        }

        return right_hand_call_is_fallible(context, index + 2);
    }

    return false;
}

fn right_hand_call_is_fallible(context: *const Context, start: u32) bool {
    const end: u32 = @intCast(@min(start + safety.call_head_max, context.tokens.len));

    assert(start >= 2);
    assert(end <= context.tokens.len);

    if (start >= end) return false;

    for (context.tokens[start..end], start..) |token, offset| {
        if (token.is_punctuation(.paren_open)) return callee_is_fallible(context, @intCast(offset));
    }

    return false;
}

fn follows_an_else(context: *const Context, block: View) bool {
    const after = safety.span_end(context, block.span());

    assert(block.category() == .block);

    if (after >= context.tokens.len) return false;

    assert(context.tokens[after].offset >= block.span().end());

    return context.tokens[after].is_keyword(.branch_else);
}

fn assigns_at(context: *const Context, index: u32) bool {
    if (index >= context.tokens.len) return false;

    const token = context.tokens[index];
    const assigns = token.is_punctuation(.assign) or token.is_punctuation(.assign_declare);

    if (assigns) assert(token.kind == .punctuation);

    return assigns;
}

fn closes_a_block(context: *const Context, index: u32) bool {
    if (index >= context.tokens.len) return false;

    const token = context.tokens[index];
    const closes = token.kind == .block_end;

    if (closes) assert(!token.opens_a_group_or_block());

    return closes;
}

fn punctuation_is(context: *const Context, index: u32, wanted: Token.Punctuation) bool {
    if (index >= context.tokens.len) return false;

    const token = context.tokens[index];
    const held = token.is_punctuation(wanted);

    if (held) assert(token.kind == .punctuation);

    return held;
}

fn text_is(context: *const Context, index: u32, wanted: []const u8) bool {
    if (index >= context.tokens.len) return false;

    const token = context.tokens[index];
    const equal = std.mem.eql(u8, context.text(token), wanted);

    if (equal) assert(token.length == wanted.len);

    return equal;
}

fn text_of(context: *const Context, index: u32) []const u8 {
    assert(index < context.tokens.len);

    const token = context.tokens[index];
    const text = context.text(token);

    assert(text.len == token.length);

    return text;
}

fn expect_count(language: Language, source: []const u8, expected: u32) !void {
    assert(source.len > 0);
    assert(expected <= testing.limits.diagnostic_count_max);

    var findings = try testing.analyze(@This(), language, source);
    defer findings.deinit();

    if (findings.count() != expected) findings.print();

    try std.testing.expectEqual(expected, findings.count());
}

test "an underscore named binding is a discard" {
    const source = "struct Error;\n\nfn step(mode: u8) -> Result<(), Error> {\n    " ++
        "assert!(mode < 8);\n\n    Ok(())\n}\n\nfn run(mode: u8) {\n    let " ++
        "_outcome = step(mode);\n}\n";

    try expect_count(.rust, source, 1);
}

test "a named binding is not a discard" {
    const source = "struct Error;\n\nfn step(mode: u8) -> Result<(), Error> {\n    " ++
        "assert!(mode < 8);\n\n    Ok(())\n}\n\nfn run(mode: u8) {\n    let " ++
        "outcome = step(mode);\n\n    assert!(outcome.is_ok());\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
}

test "a dropped fallible call is reported" {
    const source = "struct Error;\n\nfn step(mode: u8) -> Result<(), Error> {\n    " ++
        "assert!(mode < 8);\n\n    Ok(())\n}\n\nfn run(mode: u8) {\n    " ++
        "drop(step(mode));\n}\n";

    try expect_count(.rust, source, 1);
}

test "a dropped infallible call is quiet" {
    const source = "fn step(mode: u8) -> u8 {\n    assert!(mode < 8);\n\n    mode\n}\n\n" ++
        "fn run(mode: u8) {\n    drop(step(mode));\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
}

test "a forgotten fallible call is reported" {
    const source = "fn load() -> Result<u32, u32> {\n    Ok(1)\n}\n\nfn run() {\n    " ++
        "std::mem::forget(load());\n}\n";

    try expect_count(.rust, source, 1);
}

test "a default over a local fallible call is reported" {
    const source = "fn load() -> Result<u32, u32> {\n    Ok(1)\n}\n\nfn run() -> u32 {\n    " ++
        "let value = load().unwrap_or(0);\n\n    value\n}\n";

    try expect_count(.rust, source, 1);
}

test "a default after a propagated error is quiet" {
    const source = "fn load() -> Result<Option<u32>, u32> {\n    Ok(None)\n}\n\nfn run() -> " ++
        "Result<u32, u32> {\n    let value = load()?.unwrap_or(0);\n    let " ++
        "named = load()?.ok_or_else(|| 1)?;\n\n    Ok(value + named)\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
}

test "a fallback that only crashes is a crash by name" {
    const source = "fn load() -> Result<u32, u32> {\n    Ok(1)\n}\n\nfn run() -> u32 {\n    " ++
        "let a = load().unwrap_or_else(|_| panic!(\"no value\"));\n    " ++
        "let b = load().unwrap_or_else(move |err| {\n        unreachable!(\"{err}\");\n" ++
        "    });\n\n    a + b\n}\n";

    const hidden = "fn load() -> Result<u32, u32> {\n    Ok(1)\n}\n\nfn run() -> u32 {\n    " ++
        "let a = load().unwrap_or_else(|_| 0);\n    let b = load().unwrap_or_else(|_| {\n" ++
        "        log();\n        panic!(\"no value\")\n    });\n\n    a + b\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
    try expect_count(.rust, hidden, 2);
}

test "an ok_or converts an absence unless its receiver drops an error" {
    const source = "fn load() -> Result<u32, u32> {\n    Ok(1)\n}\n\n" ++
        "fn run() -> Result<u32, u32> {\n" ++
        "    let a = load().ok_or_else(|| 2)?;\n    let b = load().ok().ok_or(2)?;\n\n" ++
        "    Ok(a + b)\n}\n";

    try expect_count(.rust, source, 1);
}

test "a default over an unknown call is quiet" {
    const source = "fn run() -> u32 {\n    let value = std::env::var(\"X\").map(|held| " ++
        "held.len()).unwrap_or(0);\n\n    value\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
}

test "a discarded ok chain is reported" {
    const source = "fn load() -> Result<u32, u32> {\n    Ok(1)\n}\n\nfn run() {\n    " ++
        "let _loaded = load().ok();\n}\n";

    try expect_count(.rust, source, 1);
}

test "a dropped ok on a fallible call is reported" {
    const source = "fn load() -> Result<u32, u32> {\n    Ok(1)\n}\n\nfn run() {\n    " ++
        "load().ok();\n    load().err();\n}\n";

    try expect_count(.rust, source, 2);
}

test "a dropped ok on a named result is reported" {
    const source = "fn run(held: Result<u32, u32>, pair: Pair) {\n    held.ok();\n" ++
        "    pair.outcome.err();\n}\n";

    try expect_count(.rust, source, 2);
}

test "a free function named ok drops no error" {
    const source = "fn ok(text: &str) {\n    assert!(!text.is_empty());\n}\n\nfn run() {\n" ++
        "    ok(\"unix\");\n    err(\"windows\");\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
}

test "an empty error arm is reported" {
    const source = "fn load() -> Result<u32, u32> {\n    Ok(1)\n}\n\nfn run() {\n    " ++
        "match load() {\n        Ok(value) => assert!(value > 0),\n        " ++
        "Err(_) => {}\n    }\n}\n";

    try expect_count(.rust, source, 1);
}

test "a unit error arm is reported" {
    const source = "fn run(held: Result<u32, u32>) {\n    match held {\n        Ok(_) => " ++
        "{}\n        Err(_) => (),\n    }\n}\n";

    try expect_count(.rust, source, 1);
}

test "an error arm that names its variant handles that error by name" {
    const source = "fn run(held: Result<u32, Error>) {\n    match held {\n        Ok(_) => {}\n" ++
        "        Err(Error::Omit) => (),\n        Err(error) => {}\n    }\n    " ++
        "if let Err(Error::Empty) = held {}\n}\n";

    try testing.expect_anchors(@This(), .rust, source, &.{.{ 5, 9 }});
}

test "a handled error arm is quiet" {
    const source = "fn run(held: Result<u32, u32>) {\n    match held {\n        Ok(_) => " ++
        "{}\n        Err(error) => panic!(\"{error}\"),\n    }\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
}

test "an empty if let err body is reported" {
    const source = "fn load() -> Result<u32, u32> {\n    Ok(1)\n}\n\nfn run() {\n    " ++
        "if let Err(_) = load() {}\n}\n";

    try expect_count(.rust, source, 1);
}

test "a bare fallible call statement is reported" {
    const source = "package p\n\nfunc load() error {\n\treturn nil\n}\n\nfunc run() {\n\t" ++
        "load()\n\tdefer load()\n\tgo load()\n}\n";

    try expect_count(.go, source, 3);
}

test "a macro sharing a fallible function's name is no call of it" {
    const source = "fn load() -> Result<u32, Error> {\n    Ok(1)\n}\n\nfn run() {\n" ++
        "    macro_rules! load {\n        () => {};\n    }\n\n    load!();\n    load();\n}\n";

    try testing.expect_anchors(@This(), .rust, source, &.{.{ 11, 5 }});
}

test "a bare call reaches no method of the same name" {
    const source = "struct Command;\n\nimpl Command {\n" ++
        "    fn write_help(&mut self) -> Result<u32, Error> {\n        Ok(1)\n    }\n\n" ++
        "    fn print(&mut self) {\n        write_help(self);\n        self.write_help();\n" ++
        "    }\n}\n";

    try testing.expect_anchors(@This(), .rust, source, &.{.{ 10, 9 }});
}

test "a call through another module reaches no namesake in the file" {
    const source = "pub fn find(at: usize) -> Result<usize, Error> {\n    Ok(at)\n}\n\n" ++
        "fn scan(at: usize) -> usize {\n    accel::find(at).unwrap_or(0)\n}\n\n" ++
        "fn step(at: usize) {\n    super::find(at);\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
}

test "a call through this module or an inline module still reaches the file" {
    const source = "pub fn find(at: usize) -> Result<usize, Error> {\n    Ok(at)\n}\n\n" ++
        "mod inner {\n    pub fn find(at: usize) -> Result<usize, Error> {\n        Ok(at)\n" ++
        "    }\n}\n\nfn scan(at: usize) -> usize {\n    self::find(at).unwrap_or(0) + " ++
        "inner::find(at).unwrap_or(0)\n}\n";

    var findings = try testing.analyze(@This(), .rust, source);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 2), findings.count());
}

test "an immediately invoked literal has no namesake to reach" {
    const source = "package p\n\nfunc run() {\n\tfunc() {\n\t\twork()\n\t}()\n}\n";

    try testing.expect_quiet(@This(), .go, source);
}

test "a call reaches the nested function that shadows a namesake" {
    const source = "fn parse(text: &str) -> Result<u32, Error> {\n    Ok(1)\n}\n\n" ++
        "fn check() {\n    fn parse(size: usize, ok: bool) {\n        work(size, ok);\n    }\n\n" ++
        "    parse(1, true);\n}\n";

    const outside = "fn parse(text: &str) -> Result<u32, Error> {\n    Ok(1)\n}\n\n" ++
        "fn check() {\n    parse(\"a\");\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
    try expect_count(.rust, outside, 1);
}

test "a deferred close is reported" {
    try expect_count(.go, "package p\n\nfunc run(f *os.File) {\n\tdefer f.Close()\n}\n", 1);
}

test "a discarded last result is reported" {
    const source = "package p\n\nfunc pair() (int, error) {\n\treturn 1, nil\n}\n\nfunc " ++
        "run() {\n\tx, _ := pair()\n\t_, _ = pair()\n\tassert(x > 0)\n}\n";

    try expect_count(.go, source, 2);
}

test "a bound last result is quiet" {
    const source = "package p\n\nfunc pair() (int, error) {\n\treturn 1, nil\n}\n\nfunc " ++
        "run() error {\n\t_, err := pair()\n\n\treturn err\n}\n";

    try testing.expect_quiet(@This(), .go, source);
}

test "an empty init statement error branch is reported" {
    const source = "package p\n\nfunc run() {\n\tif err := load(); err != nil {\n\t}\n}\n";

    try expect_count(.go, source, 1);
}

test "an empty branch on a renamed error is reported" {
    const source = "package p\n\nfunc load() error {\n\treturn nil\n}\n\nfunc run() {\n\t" ++
        "failure := load()\n\tif failure != nil {\n\t}\n}\n";

    try expect_count(.go, source, 1);
}

test "an empty branch on a pointer is quiet" {
    const source = "package p\n\nfunc find() *int {\n\treturn nil\n}\n\nfunc run() {\n\t" ++
        "held := find()\n\tif held != nil {\n\t}\n}\n";

    try testing.expect_quiet(@This(), .go, source);
}

test "a zig catch with a discarded capture is reported" {
    const source = "fn run() void {\n    load() catch |_| {};\n    load() catch |err| {\n" ++
        "        _ = err;\n    };\n}\n";

    try expect_count(.zig, source, 2);
}

test "a zig catch that logs is quiet" {
    const source = "fn run() void {\n    load() catch |err| {\n        std.log.err(\"{}\", " ++
        ".{err});\n    };\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "an empty zig else capture is reported" {
    const source = "fn run() void {\n    if (load()) |value| {\n        use(value);\n    } " ++
        "else |_| {}\n}\n";

    try expect_count(.zig, source, 1);
}

test "a zig catch inside errdefer is reported" {
    const source = "fn run() !void {\n    errdefer close() catch {};\n    try open();\n}\n";

    try expect_count(.zig, source, 1);
}

test "a commented catch is still reported" {
    const source = "fn run() void {\n    // the failure is benign\n    load() catch {}; // " ++
        "nothing to do\n}\n";

    try expect_count(.zig, source, 1);
}

test "a catch under a comment that names the error is quiet" {
    const source = "fn run() void {\n    start();\n    // The error from load() is ignored, " ++
        "since the next\n    // tick retries it.\n    load() catch {};\n    // Errors only " ++
        "mean the file is gone.\n    defer remove() catch {};\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "a catch the comment above does not explain is reported" {
    const below = "fn run() void {\n    load() catch {};\n    // the error is ignored\n}\n";
    const separated = "fn run() void {\n    // the error is ignored\n\n    load() catch {};\n}\n";
    const inline_comment = "fn run() void {\n    load() catch {}; // the error is ignored\n}\n";
    const unrelated = "fn run() void {\n    // Flush before returning.\n    flush() catch {};\n}\n";
    const directive = "fn run() void {\n    // tigerstyle-ignore: TS012\n    load() catch {};\n}\n";

    const trailing = "fn run() void {\n    start(); // the error is ignored\n" ++
        "    load() catch {};\n}\n";

    const deferred_handling = "fn run() void {\n    // TODO: handle the error.\n" ++
        "    // The error is ignored for now.\n    load() catch {};\n}\n";

    try expect_count(.zig, below, 1);
    try expect_count(.zig, separated, 1);
    try expect_count(.zig, inline_comment, 1);
    try expect_count(.zig, unrelated, 1);
    try expect_count(.zig, directive, 1);
    try expect_count(.zig, trailing, 1);
    try expect_count(.zig, deferred_handling, 1);
}

test "an empty promise handler is reported" {
    const source = "function run(promise) {\n    promise.catch(() => {});\n    " ++
        "promise.then(ok, () => {});\n    promise.catch(function () {});\n}\n";

    try expect_count(.javascript, source, 3);
}

test "a promise handler that reports is quiet" {
    const source = "function run(promise) {\n    promise.catch((error) => {\n        " ++
        "report(error);\n    });\n    promise.then(ok);\n}\n";

    try testing.expect_quiet(@This(), .javascript, source);
}

test "an odin error typed result is fallible" {
    const source = "package p\n\nload :: proc() -> Error {\n    return nil\n}\n\nrun :: " ++
        "proc() {\n    _ = load()\n    load()\n}\n";

    try expect_count(.odin, source, 2);
}

test "an odin literal fallback is reported" {
    const source = "package p\n\npair :: proc() -> (int, bool) {\n    return 1, true\n}\n\n" ++
        "run :: proc() -> int {\n    value := pair() or_else 0\n\n    return " ++
        "value\n}\n";

    try expect_count(.odin, source, 1);
}

test "an empty odin none branch is reported" {
    const source = "package p\n\nload :: proc() -> Error {\n    return nil\n}\n\nrun :: " ++
        "proc() {\n    failure := load()\n    if failure != .None {\n    }\n}\n";

    try expect_count(.odin, source, 1);
}

test "a discarded call with arguments names its callee" {
    const source = "struct Error;\n\nfn print_stats(mode: u8) -> Result<(), Error> {\n    " ++
        "assert!(mode < 8);\n\n    Ok(())\n}\n\nfn run(mode: u8) {\n    let _ = " ++
        "print_stats(mode);\n}\n";

    try expect_count(.rust, source, 1);
}
