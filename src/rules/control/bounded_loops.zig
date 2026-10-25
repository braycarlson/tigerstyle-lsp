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
const Span = scylla.Span;
const Token = scylla.Token;
const TokenRange = Context.TokenRange;
const View = scylla.View;

pub const rule: Rule = .{
    .citations = &.{
        .{
            .standard = "TigerStyle",
            .text = "\"All loops and all queues must have a fixed upper bound to prevent " ++
                "infinite loops or tail latency spikes. [...] Where a loop cannot terminate " ++
                "(e.g. an event loop), this must be asserted.\"",
        },
        .{
            .standard = "NASA",
            .text = "NASA P10 Rule 2: \"All loops must have a fixed upper-bound. It must be " ++
                "trivially possible for a checking tool to prove statically that a preset " ++
                "upper-bound on the number of iterations of a loop cannot be exceeded.\"",
        },
    },
    .code = "TS006",
    .default_on = true,
    .description = "A loop carries a fixed upper bound, so a violation surfaces as a crash " ++
        "rather than as a hang.",
    .explanation = "",
    .fix_title = "",
    .fixable = .sometimes,
    .group = .stable,
    .name = "bounded-loops",
    .severity = .warning,
    .summary = "A loop must have a provable upper bound",
    .url = "",
};

const Verdict = union(enum) {
    bounded,
    called,
    channel,
    endless,
    unbounded,
    unreassigned: []const u8,
};

const assign_operators = [_][]const u8{ "!==", "&&=", "===", "??=", "||=" };
const bounding_adapters = [_][]const u8{ "take", "zip" };
const channel_lookahead_max: u32 = 4;
const decrement_words = [_][]const u8{ "--", "-=" };
const deletion_words = [_][]const u8{ "del", "delete" };
const function_nesting_max: u32 = 1 << 10;
const iteration_method = "iter";
const lifetime_quote = "'";
const make_word = "make";
const step_operators = [_][]const u8{ "++", "--" };
const step_words = [_][]const u8{ "+", "-" };
const stdin_word = "stdin";
const truth_words = [_][]const u8{ "1", "True", "true" };
const unbounded_functions = [_][]const u8{ "from_fn", "repeat", "repeat_with", "successors" };
const unbounded_methods = [_][]const u8{ "cycle", "recv" };
const unbounded_stdin_source = "lines";
const unpacked_target_count_max: u32 = 16;
const while_word = "while";

pub fn run(context: *const Context, sink: *Sink) void {
    for (context.tokens, 0..) |token, position| {
        const index: u32 = @intCast(position);
        const loops = token.is_keyword(.loop) or token.is_keyword(.loop_unbounded);
        if (!loops) continue;
        if (implements_a_trait(context, index)) continue;
        if (control.opens_a_do_loop(context, index)) continue;

        const anchor = loop_anchor(context, index);

        assert(anchor <= index);
        assert(context.tokens[anchor].length > 0);

        if (asserted_non_terminating(context, index, anchor)) continue;

        report(sink, anchor_span(context, anchor), verdict_of(context, index));
    }
}

fn report(sink: *Sink, span: Span, verdict: Verdict) void {
    assert(span.length > 0);

    switch (verdict) {
        .bounded => {},
        .called => sink.report(
            span,
            "the loop runs until a call says stop; assert or decrement a bound in the body",
        ),
        .channel => sink.report(
            span,
            "the loop iterates a channel, which never ends; bound it with a count or a break",
        ),
        .endless => sink.report(
            span,
            "the loop iterates a source that never ends; bound it with take or a count",
        ),
        .unbounded => sink.report(span, "the loop carries no upper bound; give it a fixed maximum"),
        .unreassigned => |name| {
            assert(name.len > 0);

            sink.report_formatted(
                span,
                "the loop carries no upper bound; {s} is never reassigned in the body",
                .{scan.utf8_or(name, "the condition")},
            );
        },
    }
}

fn verdict_of(context: *const Context, index: u32) Verdict {
    assert(index < context.tokens.len);

    if (is_unbounded(context, index)) return .unbounded;
    if (ranges_a_channel(context, index)) return .channel;
    if (iterates_without_end(context, index)) return .endless;
    if (iterates(context, index)) return .bounded;

    if (condition_is_a_call(context, index)) {
        if (body_bounds(context, index)) return .bounded;
        return .called;
    }

    const name = unreassigned_condition_name(context, index) orelse return .bounded;

    assert(name.len > 0);

    return .{ .unreassigned = name };
}

fn implements_a_trait(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);

    const first = stream.line_start_of_token(context.tokens, context.source, index);

    assert(first <= index);

    for (context.tokens[first..index]) |token| {
        if (token.is_keyword(.@"struct")) return true;
    }

    return false;
}

fn loop_anchor(context: *const Context, index: u32) u32 {
    assert(index < context.tokens.len);

    const labelled = label_start(context, index);
    const closed = stream.significant_previous(context.tokens, index) orelse return labelled;
    if (context.tokens[closed].kind != .block_end) return labelled;

    const opened = scylla.Brackets.block_open(context.tokens, closed) orelse return labelled;
    const before = stream.significant_previous(context.tokens, opened) orelse return labelled;
    if (!control.opens_a_do_loop(context, before)) return labelled;

    assert(before < closed);

    return before;
}

fn label_start(context: *const Context, index: u32) u32 {
    const tokens = context.tokens;
    const labelled = stream.label_start(tokens, context.source, index) orelse return index;

    assert(labelled < index);

    if (labelled == 0) return labelled;

    const quote = labelled - 1;
    if (tokens[quote].end() != tokens[labelled].offset) return labelled;
    if (!std.mem.eql(u8, context.text(tokens[quote]), lifetime_quote)) return labelled;
    if (quote == stream.line_start_of_token(tokens, context.source, quote)) return index;

    assert(quote < labelled);

    return quote;
}

fn anchor_span(context: *const Context, anchor: u32) Span {
    assert(anchor < context.tokens.len);

    const token = context.tokens[anchor];
    if (!std.mem.eql(u8, context.text(token), lifetime_quote)) return token.span();

    const label = context.tokens[anchor + 1];

    assert(label.offset == token.end());
    assert(label.kind == .identifier);

    return .{ .offset = token.offset, .length = label.end() - token.offset };
}

fn asserted_non_terminating(context: *const Context, index: u32, anchor: u32) bool {
    assert(anchor <= index);
    assert(index < context.tokens.len);

    const assertion = preceding_assertion(context, anchor) orelse return false;
    const claimed = support.assert_condition(context, assertion) orelse return false;
    if (claimed.start >= claimed.end) return false;

    const claim = stripped_text(context, claimed);
    if (scan.word_in(&truth_words, claim)) return true;

    const condition = control.condition_of(context, index);
    if (condition.start >= condition.end) return false;

    const looped = stripped_text(context, condition);
    if (looped.len == 0) return false;
    return scan.find(claim, looped) != null;
}

fn preceding_assertion(context: *const Context, anchor: u32) ?u32 {
    assert(anchor < context.tokens.len);

    const statement = context.view_at(.loop, context.tokens[anchor].offset) orelse return null;
    const parent = statement.parent() orelse return null;

    var children = parent.children();
    var previous: ?View = null;

    for (0..children.remaining) |_| {
        const child = children.next() orelse break;
        if (child.index() == statement.index()) break;

        previous = child;
    }

    const child_last = previous orelse return null;

    assert(child_last.index() != statement.index());

    if (!context.is_assertion(child_last)) return null;

    for (context.tokens_in(child_last.span())) |token| {
        if (token.is_keyword(.assert)) return context.lexer_index_at(token.offset);
    }

    return null;
}

fn stripped_text(context: *const Context, range: TokenRange) []const u8 {
    assert(range.start < range.end);
    assert(range.end <= context.tokens.len);

    const span = stream.span_of_range(context.tokens, range.start, range.end);
    return scan.stripped_group(context.span_text(span));
}

fn is_unbounded(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);

    if (context.tokens[index].is_keyword(.loop_unbounded)) return true;
    if (clauses_omit_a_condition(context, index)) return true;

    const condition = control.condition_of(context, index);

    assert(condition.start <= condition.end);

    if (condition_is_true(context, condition)) return true;
    return ranges_without_end(context, condition);
}

fn clauses_omit_a_condition(context: *const Context, index: u32) bool {
    const clause = control.clauses(context, index) orelse return false;

    assert(clause.start <= clause.end);
    assert(clause.end <= context.tokens.len);

    return clause.start == clause.end;
}

fn condition_is_true(context: *const Context, condition: TokenRange) bool {
    assert(condition.start <= condition.end);
    assert(condition.end <= context.tokens.len);

    var cursor = condition.start;

    for (context.tokens[condition.start..condition.end]) |token| {
        if (!token.is_punctuation(.paren_open)) break;

        cursor += 1;
    }

    if (cursor >= condition.end) return false;

    const token = context.tokens[cursor];
    const text = context.text(token);

    const literal = switch (token.kind) {
        .identifier => std.mem.eql(u8, text, "true") or std.mem.eql(u8, text, "True"),
        .number => std.mem.eql(u8, text, "1"),
        else => false,
    };

    if (!literal) return false;
    if (cursor + 1 >= condition.end) return true;
    return context.tokens[cursor + 1].is_punctuation(.paren_close);
}

fn ranges_without_end(context: *const Context, condition: TokenRange) bool {
    assert(condition.start <= condition.end);
    assert(condition.end <= context.tokens.len);

    if (condition.end < condition.start + 2) return false;

    const last = context.tokens[condition.end - 1];
    if (!dots_only(context, last)) return false;

    if (last.length == 1) {
        if (condition.end < condition.start + 3) return false;

        const before = context.tokens[condition.end - 2];
        if (!before.is_punctuation(.dot)) return false;
        if (before.offset + 1 != last.offset) return false;
    }

    for (context.tokens[condition.start..condition.end]) |token| {
        if (token.is_punctuation(.comma)) return false;
    }

    return true;
}

fn iterates_without_end(context: *const Context, index: u32) bool {
    const condition = control.condition_of(context, index);
    const stop = @min(condition.end, context.tokens.len -| 1);

    assert(index < context.tokens.len);
    assert(condition.end <= context.tokens.len);

    if (stop <= condition.start) return false;

    var endless = false;

    for (context.tokens[condition.start..stop], condition.start..) |token, offset| {
        if (token.kind != .identifier) continue;
        if (!context.tokens[offset + 1].is_punctuation(.paren_open)) continue;

        const name = context.text(token);
        if (scan.word_in(&bounding_adapters, name)) return false;
        if (endless) continue;

        endless = names_an_endless_source(context, @intCast(offset)) or
            reads_stdin_lines(context, condition, name) or
            iterates_a_channel(context, index, @intCast(offset));
    }

    return endless;
}

fn names_an_endless_source(context: *const Context, index: u32) bool {
    const name = context.text(context.tokens[index]);

    assert(index < context.tokens.len);
    assert(name.len > 0);

    if (scan.word_in(&unbounded_methods, name)) return true;
    if (!scan.word_in(&unbounded_functions, name)) return false;
    if (index == 0) return true;
    return !context.tokens[index - 1].is_punctuation(.dot);
}

fn reads_stdin_lines(context: *const Context, condition: TokenRange, name: []const u8) bool {
    assert(condition.end <= context.tokens.len);
    assert(name.len > 0);

    if (!std.mem.eql(u8, name, unbounded_stdin_source)) return false;

    for (context.tokens[condition.start..condition.end]) |token| {
        if (token.kind != .identifier) continue;
        if (std.mem.eql(u8, context.text(token), stdin_word)) return true;
    }

    return false;
}

fn iterates_a_channel(context: *const Context, index: u32, offset: u32) bool {
    assert(index < context.tokens.len);
    assert(offset < context.tokens.len);

    if (offset < 2) return false;
    if (!std.mem.eql(u8, context.text(context.tokens[offset]), iteration_method)) return false;
    if (!context.tokens[offset - 1].is_punctuation(.dot)) return false;

    const receiver = context.tokens[offset - 2];
    if (receiver.kind != .identifier) return false;
    return declares_a_channel(context, index, context.text(receiver));
}

fn ranges_a_channel(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);

    const iteration_word = context.conventions.iteration_word;

    if (context.conventions.channel_word.len == 0) return false;
    if (iteration_word.len == 0) return false;

    const end = stream.statement_end(context.tokens, index + 1);
    var cursor = index + 1;

    assert(end <= context.tokens.len);

    for (context.tokens[index + 1 .. end]) |token| {
        if (std.mem.eql(u8, context.text(token), iteration_word)) break;

        cursor += 1;
    }

    const first = cursor + 1;
    if (first >= end) return false;
    if (context.tokens[first].kind != .identifier) return false;

    const last = chain_end(context, first, end) - 1;

    assert(last >= first);

    if (last + 1 != end) return false;

    const name = context.text(context.tokens[last]);
    if (last == first) return declares_a_channel(context, index, name);
    return declares_a_channel_in(context, context.tokens, name);
}

fn declares_a_channel(context: *const Context, index: u32, name: []const u8) bool {
    assert(index < context.tokens.len);
    assert(name.len > 0);

    var function = context.function_at(context.tokens[index].offset);

    for (0..function_nesting_max) |_| {
        const held = function orelse return false;
        if (declares_a_channel_in(context, context.tokens_in(held.span()), name)) return true;

        function = held.ancestor_of(.function) orelse held.ancestor_of(.lambda);
    }

    return false;
}

fn declares_a_channel_in(context: *const Context, body: []const Token, name: []const u8) bool {
    assert(body.len <= context.tokens.len);
    assert(name.len > 0);

    for (body, 0..) |token, offset| {
        if (!std.mem.eql(u8, context.text(token), name)) continue;

        const statement_end = stream.statement_end(body, @intCast(offset + 1));
        const stop = @min(statement_end, offset + 1 + channel_lookahead_max);

        for (body[offset + 1 .. stop]) |held| {
            const text = context.text(held);
            if (std.mem.eql(u8, text, context.conventions.channel_word)) return true;
            if (held.kind != .identifier) continue;
            if (!std.mem.eql(u8, text, make_word)) break;
        }
    }

    return false;
}

fn chain_end(context: *const Context, first: u32, end: u32) u32 {
    assert(first < end);
    assert(end <= context.tokens.len);

    var last = first + 1;

    for (0..end - first) |_| {
        if (last + 1 >= end) break;
        if (!dots_only(context, context.tokens[last])) break;
        if (context.tokens[last + 1].kind != .identifier) break;

        last += 2;
    }

    assert(last > first);

    return last;
}

fn condition_is_a_call(context: *const Context, index: u32) bool {
    const condition = control.condition_of(context, index);
    const end = condition.end;

    assert(end <= context.tokens.len);

    var first = condition.start;

    if (first < end) {
        if (context.tokens[first].is_keyword(.declare)) {
            const declared: TokenRange = .{ .end = end, .start = first };

            const assigned = control.top_level_punctuation(context, declared, .assign) orelse
                return false;

            first = assigned + 1;
        }
    }

    if (first < end) {
        if (context.tokens[first].is_punctuation(.bang)) first += 1;
    }

    if (first + 2 > end) return false;

    assert(first + 1 < end);

    if (context.tokens[first].kind != .identifier) return false;
    if (!context.tokens[end - 1].is_punctuation(.paren_close)) return false;
    return chains_a_call(context, first, end);
}

fn chains_a_call(context: *const Context, first: u32, end: u32) bool {
    assert(first < end);
    assert(end <= context.tokens.len);

    var depth: u32 = 0;

    for (context.tokens[first..end]) |token| {
        if (token.opens_a_group_or_block()) {
            depth += 1;

            continue;
        }

        if (token.closes_a_group_or_block()) {
            depth -|= 1;

            continue;
        }

        if (depth > 0) continue;
        if (token.kind == .identifier) continue;
        if (dots_only(context, token)) continue;
        if (!token.is_punctuation(.colon)) return false;
    }

    return true;
}

fn dots_only(context: *const Context, token: Token) bool {
    if (!token.is_punctuation(.dot)) return false;

    const text = context.text(token);

    assert(token.kind == .punctuation);
    assert(text.len > 0);

    return std.mem.allEqual(u8, text, '.');
}

fn body_bounds(context: *const Context, index: u32) bool {
    const frame = control.keyword_frame(context, index) orelse return false;
    const body = frame.body(context.tokens);

    assert(index < context.tokens.len);
    assert(body.len <= context.tokens.len);

    for (body, frame.start..) |token, position| {
        if (token.is_keyword(.assert)) return true;

        if (token.kind == .identifier) {
            if (context.calls_an_expectation_alias(@intCast(position))) return true;
        }

        if (!token.is_punctuation(.other)) continue;
        if (decrements(context, token)) return true;
    }

    return false;
}

fn decrements(context: *const Context, token: Token) bool {
    assert(token.is_punctuation(.other));

    const text = context.text(token);

    assert(text.len == token.length);

    return scan.word_in(&decrement_words, text);
}

fn iterates(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);

    const token = context.tokens[index];
    if (token.is_keyword(.loop_unbounded)) return false;
    if (std.mem.eql(u8, context.text(token), while_word)) return false;
    if (captures_after_the_header(context, index)) return true;

    const header = control.header_range(context, index);

    assert(header.start <= header.end);

    for (context.tokens[header.start..header.end]) |held| {
        const keyword = switch (held.kind) {
            .keyword => |keyword| keyword,
            else => continue,
        };

        switch (keyword) {
            .constant, .declare, .other => return true,
            else => {},
        }
    }

    return destructures_a_struct(context, header);
}

fn destructures_a_struct(context: *const Context, header: TokenRange) bool {
    const iteration_word = context.conventions.iteration_word;

    assert(header.start <= header.end);
    assert(header.end <= context.tokens.len);

    if (iteration_word.len == 0) return false;
    if (header.end == context.tokens.len) return false;
    if (context.tokens[header.end].kind != .block_start) return false;

    const close = context.pairs.partner_of(header.end) orelse return false;
    if (close <= header.end) return false;

    const after = control.significant_after(context, close + 1) orelse return false;

    assert(after > close);

    return std.mem.eql(u8, context.text(context.tokens[after]), iteration_word);
}

fn captures_after_the_header(context: *const Context, index: u32) bool {
    const group = control.header_group(context, index) orelse return false;

    assert(group.open == index + 1);
    assert(group.closed > group.open);

    const after = control.significant_after(context, group.closed + 1) orelse return false;
    return control.captures(context, after);
}

fn unreassigned_condition_name(context: *const Context, index: u32) ?[]const u8 {
    const frame = control.keyword_frame(context, index) orelse return null;
    const opened = frame.start;
    const condition = control.condition_of(context, index);

    assert(opened < context.tokens.len);

    if (condition.start >= condition.end) return null;
    if (condition.end > opened) return null;
    if (reads_beyond_a_name(context, condition)) return null;

    const body = frame.body(context.tokens);
    const tail = context.tokens[condition.end..opened];

    var first: ?u32 = null;

    for (context.tokens[condition.start..condition.end], condition.start..) |token, offset| {
        if (token.kind != .identifier) continue;

        const name = context.text(token);
        if (reassigned(context, body, name)) return null;
        if (reassigned(context, tail, name)) return null;

        if (first == null) first = @intCast(offset);
    }

    const named = first orelse return null;
    const last = chain_end(context, named, condition.end);

    assert(named < last);
    assert(last <= condition.end);

    return context.span_text(stream.span_of_range(context.tokens, named, last));
}

fn reads_beyond_a_name(context: *const Context, condition: TokenRange) bool {
    assert(condition.start < condition.end);
    assert(condition.end <= context.tokens.len);

    for (context.tokens[condition.start..condition.end]) |token| {
        const beyond = switch (token.kind) {
            .keyword => |keyword| keyword == .other,
            .punctuation => |punctuation| switch (punctuation) {
                .assign, .assign_declare, .bracket_open, .colon, .paren_open => true,
                else => scan.word_in(&assign_operators, context.text(token)),
            },
            else => false,
        };

        if (beyond) return true;
    }

    return false;
}

fn reassigned(context: *const Context, body: []const Token, name: []const u8) bool {
    assert(body.len <= context.tokens.len);
    assert(name.len > 0);

    for (body, 0..) |token, offset| {
        if (token.kind != .identifier) continue;
        if (!std.mem.eql(u8, context.text(token), name)) continue;
        if (deleted(context, body, @intCast(offset))) return true;
        if (offset + 1 >= body.len) continue;
        if (written(body[offset + 1])) return true;
        if (stepped(context, body, @intCast(offset))) return true;
        if (compounded(body, @intCast(offset))) return true;
        if (unpacked(body, @intCast(offset))) return true;
    }

    return false;
}

fn deleted(context: *const Context, body: []const Token, offset: u32) bool {
    assert(offset < body.len);
    assert(body.len <= context.tokens.len);

    if (offset == 0) return false;
    return scan.word_in(&deletion_words, context.text(body[offset - 1]));
}

fn unpacked(body: []const Token, offset: u32) bool {
    assert(offset + 1 < body.len);

    if (!opens_a_statement(body, offset)) return false;

    var cursor = offset + 1;

    for (0..unpacked_target_count_max) |_| {
        if (cursor + 1 >= body.len) return false;
        if (!body[cursor].is_punctuation(.comma)) break;
        if (body[cursor + 1].kind != .identifier) return false;

        cursor += 2;
    }

    if (cursor == offset + 1) return false;
    if (cursor >= body.len) return false;

    if (body[cursor].is_punctuation(.paren_close)) cursor += 1;
    if (cursor >= body.len) return false;
    return body[cursor].is_punctuation(.assign);
}

fn opens_a_statement(body: []const Token, offset: u32) bool {
    assert(offset < body.len);

    var cursor = offset;

    if (cursor > 0) {
        if (body[cursor - 1].is_punctuation(.paren_open)) cursor -= 1;
    }

    if (cursor == 0) return true;

    const before = body[cursor - 1];
    if (before.kind == .newline) return true;
    if (before.kind == .block_start) return true;
    if (before.kind == .block_end) return true;
    return before.is_punctuation(.semicolon);
}

fn written(next: Token) bool {
    const punctuation = switch (next.kind) {
        .punctuation => |punctuation| punctuation,
        else => return false,
    };

    assert(next.kind == .punctuation);

    const writes = switch (punctuation) {
        .assign, .assign_declare, .dot, .other => true,
        else => false,
    };

    if (writes) assert(punctuation != .semicolon);

    return writes;
}

fn stepped(context: *const Context, body: []const Token, offset: u32) bool {
    assert(offset < body.len);
    assert(body.len <= context.tokens.len);

    if (offset < 1) return false;

    const operator = body[offset - 1];
    if (!operator.is_punctuation(.other)) return false;

    const text = context.text(operator);
    if (scan.word_in(&step_operators, text)) return true;
    if (offset < 2) return false;

    const doubled = body[offset - 2];
    if (!doubled.is_punctuation(.other)) return false;
    if (doubled.end() != operator.offset) return false;
    if (!scan.word_in(&step_words, text)) return false;
    return std.mem.eql(u8, context.text(doubled), text);
}

fn compounded(body: []const Token, offset: u32) bool {
    assert(offset + 1 < body.len);

    const operator = body[offset + 1];

    const compound = operator.is_punctuation(.ampersand) or
        operator.is_punctuation(.bang) or
        operator.is_punctuation(.slash) or
        operator.is_punctuation(.star);

    if (!compound) return false;
    if (offset + 2 >= body.len) return false;

    assert(offset + 2 < body.len);

    return body[offset + 2].is_punctuation(.assign);
}

fn expect_count(language: Language, source: []const u8, expected: u32) !void {
    assert(source.len > 0);
    assert(expected <= testing.limits.diagnostic_count_max);

    var findings = try testing.analyze(@This(), language, source);
    defer findings.deinit();

    if (findings.count() != expected) findings.print();

    try std.testing.expectEqual(expected, findings.count());
}

fn expect_count_naming(
    language: Language,
    source: []const u8,
    expected: u32,
    named: []const u8,
) !void {
    assert(source.len > 0);
    assert(named.len > 0);

    var findings = try testing.analyze(@This(), language, source);
    defer findings.deinit();

    if (findings.count() != expected) findings.print();

    try std.testing.expectEqual(expected, findings.count());
    try std.testing.expect(std.mem.find(u8, findings.message(0), named) != null);
}

test "a range over a channel is unbounded" {
    const source = "package main\n\nfunc drain(ch chan int) int {\n\ttotal := 0\n\tfor value " ++
        ":= range ch {\n\t\ttotal += value\n\t}\n\treturn total\n}\n";

    try expect_count_naming(.go, source, 1, "channel");
}

test "a range over a slice is bounded" {
    const source = "package main\n\nfunc total(items []int) int {\n\tsum := 0\n\tfor _, value " ++
        ":= range items {\n\t\tsum += value\n\t}\n\treturn sum\n}\n";

    try testing.expect_quiet(@This(), .go, source);
}

test "a range over a field of a channel holder is bounded" {
    const source = "package main\n\nfunc run(req request, done chan int) int {\n\tfound := 0\n" ++
        "\tfor _, file := range req.Files {\n\t\tfound += file\n\t}\n\treturn " ++
        "found\n}\n";

    try testing.expect_quiet(@This(), .go, source);
}

test "a three clause loop with a true condition is unbounded" {
    const source = "package main\n\nfunc run(limit int) int {\n\tfor i := 0; true; i++ {\n\t\t" ++
        "if i > limit {\n\t\t\treturn i\n\t\t}\n\t}\n\treturn 0\n}\n";

    try expect_count(.go, source, 1);
}

test "a three clause loop with a real condition is bounded" {
    const source = "package main\n\nfunc run(limit int) int {\n\tsum := 0\n\tfor i := 0; i < " ++
        "limit; i++ {\n\t\tsum += i\n\t}\n\treturn sum\n}\n";

    try testing.expect_quiet(@This(), .go, source);
}

test "a loop after an assertion is exempt" {
    const source = "fn f() {\n    assert!(true);\n\n    loop {\n        break;\n    }\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
}

test "a loop after an unrelated assertion is reported" {
    const source = "fn f(limit: u32) {\n    assert!(limit > 0);\n\n    loop {\n" ++
        "break;\n    }\n}\n";

    try expect_count(.rust, source, 1);
}

test "a loop after an assertion naming its condition is exempt" {
    const source = "fn f() void {\n    assert(running);\n    while (running) {\n" ++
        "work();\n    }\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "a javascript clause loop without a condition is reported" {
    const source = "function f() {\n    for (;;) {\n        work();\n    }\n}\n";

    try expect_count(.javascript, source, 1);
}

test "a javascript while one is reported" {
    const source = "function f() {\n    while (1) {\n        work();\n    }\n}\n";

    try expect_count(.javascript, source, 1);
}

test "a do while true anchors at the do" {
    const source = "function f() {\n    do {\n        work();\n    } while (true);\n}\n";

    try testing.expect_anchors(@This(), .javascript, source, &.{.{ 2, 5 }});
}

test "a python while one is reported" {
    try expect_count(.python, "def f():\n    while 1:\n        work()\n", 1);
}

test "a python condition the body never reassigns is reported" {
    try expect_count_naming(.python, "def f(done):\n    while done:\n        work()\n", 1, "done");
}

test "a python name the body deletes from or unpacks into is reassigned" {
    const source = "def parse(bits, i, ready, deferred):\n    while bits:\n" ++
        "        del bits[:1]\n    while i != 0:\n        i, n = divmod(i, 36)\n" ++
        "    while deferred:\n        if not deferred:\n            log()\n" ++
        "        deferred, more = analyze()\n    while ready:\n        work(ready, n=3)\n";

    try expect_count_naming(.python, source, 1, "ready");
}

test "a python for over a parenthesized target iterates" {
    const source = "def walk(models, running):\n" ++
        "    for (label, name), state in models.items():\n        work(label)\n" ++
        "    while running:\n        work(name)\n";

    try expect_count_naming(.python, source, 1, "running");
}

test "a python condition the body reassigns is quiet" {
    const source = "def f(done):\n    while done:\n        done = False\n";

    try testing.expect_quiet(@This(), .python, source);
}

test "a rust endless iterator is reported" {
    const source = "fn f() {\n    for x in std::iter::repeat(1) {\n        work(x);\n    }\n" ++
        "for line in stdin().lock().lines() {\n        work(line);\n    }\n" ++
        "for x in 0.. {\n        work(x);\n    }\n}\n";

    try expect_count(.rust, source, 3);
}

test "a method sharing an endless function's name is no endless source" {
    const getter = "fn f(find: &Find) {\n    for _ in 0..find.repeat() {\n        work();\n" ++
        "    }\n}\n";

    const text = "fn f() {\n    for c in \"ab\".repeat(3).chars() {\n        work(c);\n    }\n}\n";
    const bare = "fn f() {\n    for x in repeat(1) {\n        work(x);\n    }\n}\n";

    try testing.expect_quiet(@This(), .rust, getter);
    try testing.expect_quiet(@This(), .rust, text);
    try expect_count(.rust, bare, 1);
}

test "a rust endless iterator cut by take is quiet" {
    const source = "fn f() {\n    for x in std::iter::repeat(1).take(8) {\n        work(x);\n" ++
        "}\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
}

test "a rust receiver is a channel" {
    const source = "fn f(rx: Receiver<u32>) {\n    for v in rx {\n        work(v);\n    }\n" ++
        "for v in rx.iter() {\n        work(v);\n    }\n" ++
        "while let Ok(v) = rx.recv() {\n        work(v);\n    }\n}\n";

    try expect_count(.rust, source, 3);
}

test "a rust while let over a pop is reported" {
    const source = "fn f(stack: &mut Vec<u32>) {\n    while let Some(x) = stack.pop() {\n" ++
        "work(x);\n    }\n}\n";

    try expect_count(.rust, source, 1);
}

test "a rust while let whose body asserts a bound is quiet" {
    const source = "fn f(stack: &mut Vec<u32>) {\n    while let Some(x) = stack.pop() {\n" ++
        "assert!(stack.len() < LIMIT);\n        work(x);\n    }\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
}

test "a zig open range is reported" {
    const source = "fn f() void {\n    for (0..) |i| {\n        work(i);\n    }\n}\n";

    try expect_count(.zig, source, 1);
}

test "a zig open range beside a slice is bounded" {
    const source = "fn f(items: []u32) void {\n    for (items, 0..) |item, i| {\n" ++
        "work(item, i);\n    }\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "a zig range ending in a dereference or an unwrap is bounded" {
    const source = "fn f(count: *u32, limit: ?u32) void {\n    for (0..count.*) |_| work();\n" ++
        "    for (0..limit.?) |_| work();\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "a zig payload capture over a call is reported" {
    const source = "fn f(it: Iterator) void {\n    while (it.next()) |x| {\n        work(x);\n" ++
        "}\n}\n";

    try expect_count(.zig, source, 1);
}

test "a zig payload capture whose body decrements is quiet" {
    const source = "fn f(it: Iterator) void {\n    var remaining: u32 = 8;\n" ++
        "while (it.next()) |x| {\n        remaining -= 1;\n        work(x);\n" ++
        "}\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "a go range over a channel field is reported" {
    const source = "package main\n\ntype worker struct {\n\tch chan int\n}\n\n" ++
        "func f(w worker) {\n\tfor v := range w.ch {\n\t\twork(v)\n\t}\n}\n";

    try expect_count_naming(.go, source, 1, "channel");
}

test "a go method call condition is reported" {
    const source = "package main\n\nfunc f(s *bufio.Scanner) {\n\tfor s.Scan() {\n" ++
        "\t\twork(s.Text())\n\t}\n}\n";

    try expect_count(.go, source, 1);
}

test "an odin dotted condition the body never reassigns is reported" {
    const source = "package main\n\nf :: proc(s: ^State) {\n    for !s.done {\n" ++
        "work()\n    }\n}\n";

    try expect_count_naming(.odin, source, 1, "s.done");
}

test "a loop bound to a name after an assertion is reported" {
    const source = "fn f() {\n    assert!(true);\n\n    let value = loop {\n" ++
        "break 1;\n    };\n}\n";

    try expect_count(.rust, source, 1);
}

test "a go clause loop without a condition is reported" {
    const source = "package main\n\nfunc f() {\n\tfor i := 0; ; i++ {\n\t\tg(i)\n\t}\n}\n";

    try expect_count(.go, source, 1);
}

test "a go clause loop with a condition is quiet" {
    const source = "package main\n\nfunc f() {\n\tfor i := 0; i < 8; i++ {\n\t\tg(i)\n\t}\n}\n";

    try testing.expect_quiet(@This(), .go, source);
}

test "a zig while over an unreassigned name is reported" {
    const source =
        "fn f() void {\n    while (!timed_out) {\n        try self.flush(true);\n    }\n}\n";

    try expect_count_naming(.zig, source, 1, "timed_out");
}

test "a zig while with a continue expression is quiet" {
    const source = "fn f() void {\n    while (index < limit) : (index += 1) {\n" ++
        "g(index);\n    }\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "an unbounded loop without an exit is reported" {
    try expect_count(.rust, "fn f() {\n    loop {\n        work();\n    }\n}\n", 1);
}

test "an unbounded loop with a break is still reported" {
    try expect_count(.rust, "fn f() {\n    loop {\n        break;\n    }\n}\n", 1);
}

test "a condition the body never reassigns is reported" {
    try expect_count(.rust, "fn f() {\n    while ready {\n        work();\n    }\n}\n", 1);
}

test "a condition the body divides in place is quiet" {
    const source = "fn f() {\n    while remaining > 0 {\n        remaining /= 10;\n    }\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
}

test "a condition the body reassigns is quiet" {
    const source = "fn f() {\n    while ready {\n        ready = false;\n    }\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
}

test "a while true loop is reported" {
    try expect_count(.python, "def f():\n    while True:\n        work()\n", 1);
}

test "a bounded loop is quiet" {
    const source = "fn f() {\n    for index in 0..10 {\n        work();\n    }\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
}

test "a statement label does not move the loop anchor" {
    const source = "fn f() void {\n    outer: while (true) {\n        break;\n    }\n}\n";

    try testing.expect_anchors(@This(), .zig, source, &.{.{ 2, 12 }});
}

test "a prefix step in the clause bounds the loop" {
    const source = "function f(n: number) {\n    for (let i = 0; i < n; ++i) {\n" ++
        "        work(i);\n    }\n    for (; n >= 0; --n) {\n        work(n);\n    }\n}\n";

    try testing.expect_quiet(@This(), .typescript, source);
}

test "a strict comparison reads beyond the name" {
    const source = "function f(t: T) {\n    while (t.count === 0) {\n        work();\n    }\n" ++
        "    while (t.state !== 1) {\n        work();\n    }\n}\n";

    try testing.expect_quiet(@This(), .typescript, source);
}

test "a javascript decrement bounds a loop a call ends" {
    const source = "function f(it) {\n    while (it.hasNext()) {\n        count--;\n    }\n}\n";

    try testing.expect_quiet(@This(), .javascript, source);
}

test "an optional chain or an unwrap is not a call condition" {
    const optional = "function f(a) {\n    while (a?.ready()) {\n        work();\n    }\n}\n";

    const unwrapped = "fn f(c: *C) void {\n    while (c.buffer.?.next()) |h| {\n" ++
        "        work(h);\n    }\n}\n";

    try testing.expect_quiet(@This(), .javascript, optional);
    try testing.expect_quiet(@This(), .zig, unwrapped);
}

test "a lifetime label anchors at its quote unless it opens the line" {
    const bound = "fn f() {\n    let v = 'outer: loop {\n        break 'outer 1;\n    };\n}\n";
    const opening = "fn f() {\n    'outer: loop {\n        break;\n    }\n}\n";

    try testing.expect_anchors(@This(), .rust, bound, &.{.{ 2, 13 }});
    try testing.expect_anchors(@This(), .rust, opening, &.{.{ 2, 13 }});
}

test "a lifetime label spans its quote and its name" {
    const source = "fn f() {\n    let v = 'outer: loop {\n        break 'outer 1;\n    };\n}\n";

    try testing.expect_spans(@This(), .rust, source, &.{.{ 21, 27 }});
}

test "a zig loop whose body asserts through an expectation alias is bounded" {
    const source = "const expectEqual = std.testing.expectEqual;\n\n" ++
        "test \"walk\" {\n    var it = map.iterator();\n" ++
        "    while (it.next()) |entry| {\n        try expectEqual(1, entry.value_ptr.*);\n" ++
        "    }\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "a for loop over a struct pattern iterates" {
    const source = "fn f(v: Vec<S>, running: bool) {\n    for S { a, b } in v {\n" ++
        "        g(a, b);\n    }\n\n    for S {\n        a,\n        b,\n    } in v\n    {\n" ++
        "        g(a, b);\n    }\n\n    while running {\n        g(1, 2);\n    }\n}\n";

    try testing.expect_anchors(@This(), .rust, source, &.{.{ 14, 5 }});
}
