const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const scan = @import("../../scan.zig");
const stream = @import("../../stream.zig");
const support = @import("../support.zig");
const testing = @import("../testing.zig");
const Context = @import("../context.zig");
const JavascriptKind = scylla.javascript.Kind;
const Language = scylla.Language;
const Limits = @import("../../limits.zig");
const Rule = scylla.rule.Rule;
const Sink = scylla.rule.Sink;
const Span = scylla.Span;
const TestScope = @import("../test_scope.zig");
const Token = scylla.Token;
const View = scylla.View;

pub const rule: Rule = .{
    .citations = &.{
        .{
            .standard = "TigerStyle",
            .text = "\"All memory must be statically allocated at startup. No memory may be " ++
                "dynamically allocated (or freed and reallocated) after initialization.\"",
        },
        .{
            .standard = "NASA",
            .text = "NASA P10 Rule 3: \"Do not use dynamic memory allocation after " ++
                "initialization.\"",
        },
    },
    .code = "TS016",
    .default_on = false,
    .description = "Memory is reserved during initialization, so no later call can fail for " ++
        "want of it.",
    .explanation = "",
    .fix_title = "",
    .fixable = .sometimes,
    .group = .stable,
    .name = "no-dynamic-alloc",
    .severity = .warning,
    .summary = "Do not allocate on the heap after initialization",
    .url = "",
};

const Marks = std.bit_set.Static(function_mark_count);

const PathNames = struct {
    head: []const u8,
    leaf: []const u8,
};

const allocates_format = "{s} allocates; reserve the memory during initialization";
const capture_marker = "|";
const clone_method = "clone";
const error_set_opener = "error{";
const expression_operators = [_][]const u8{ "!==", "&&=", "===", "??=", "||=" };
const function_mark_count: u32 = Limits.function_count_max_default;
const generic_scan_max: u32 = 64;

const initialization_names = [_][]const u8{
    "__init__",
    "init",
    "main",
    "new",
    "reserve",
    "setUp",
    "setup",
};

const label_words = [_][]const u8{ "case", "default" };
const literal_chain_max: u32 = 8;
const map_word = "map";
const out_of_memory_name = "OutOfMemory";
const pattern_word = "of";
const prong_arrow = "=>";
const range_operator = "..";
const reference_depth_max: u32 = 4;
const testing_allocator_name = "testing.allocator";

const value_type_names = [_][]const u8{
    "Range",
    "RangeFrom",
    "RangeFull",
    "RangeInclusive",
    "RangeTo",
    "RangeToInclusive",
};

comptime {
    assert(Marks.bit_length == function_mark_count);
    assert(function_mark_count % 64 == 0);
}

pub fn run(context: *const Context, sink: *Sink) void {
    assert(context.tokens.len <= std.math.maxInt(u32));

    var phases: Marks = .empty;

    phases_build(context, &phases);

    assert(phases.count() <= context.tables.functions().len);

    var scope: TestScope = .unbuilt;

    calls_scan(context, sink, &phases, &scope);
    macros_scan(context, sink, &phases, &scope);
    literals_scan(context, sink, &phases, &scope);
    strings_scan(context, sink, &phases, &scope);
}

fn phases_build(context: *const Context, phases: *Marks) void {
    const functions = context.tables.functions();

    assert(phases.count() == 0);

    for (functions, 0..) |function, row| {
        const name = context.span_text(function.name);

        if (scan.word_in(&initialization_names, name)) mark(phases, @intCast(row));
    }

    var called: Marks = .empty;
    var watched: Marks = .empty;

    for (functions, 0..) |*function, row| {
        const initializes = marked(phases, @intCast(row));

        for (context.tables.edges_of(function)) |edge| {
            mark(&called, edge.target);

            if (!initializes) mark(&watched, edge.target);
        }
    }

    for (0..functions.len) |row| {
        const index: u32 = @intCast(row);
        if (!marked(&called, index)) continue;
        if (marked(&watched, index)) continue;

        mark(phases, index);
    }

    assert(phases.count() <= functions.len);
}

fn marked(marks: *const Marks, row: u32) bool {
    if (row >= function_mark_count) return false;

    assert(row < Marks.bit_length);

    return marks.isSet(row);
}

fn mark(marks: *Marks, row: u32) void {
    if (row >= function_mark_count) return;

    assert(row < Marks.bit_length);

    marks.set(row);

    assert(marks.isSet(row));
}

fn runs_after_initialization(
    context: *const Context,
    phases: *const Marks,
    function: View,
) bool {
    const node = declaration_of(function).index();

    assert(node < context.front.node_count());
    assert(function.as_function() != null);

    for (context.tables.functions(), 0..) |held, row| {
        if (held.node == node) return !marked(phases, @intCast(row));
    }

    return true;
}

fn declaration_of(function: View) View {
    if (function.category() != .lambda) return function;

    const declaration = function.ancestor_of(.function) orelse return function;
    if (declaration.span().end() != function.span().end()) return function;

    assert(declaration.span().offset <= function.span().offset);

    return declaration;
}

fn watched_offset(context: *const Context, phases: *const Marks, offset: u32) bool {
    assert(offset <= context.source.len);

    const function = context.function_at(offset) orelse return false;

    assert(function.span().contains(offset));

    return runs_after_initialization(context, phases, function);
}

fn calls_scan(
    context: *const Context,
    sink: *Sink,
    phases: *const Marks,
    scope: *TestScope,
) void {
    var calls = context.views(.call);

    for (0..calls.remaining) |_| {
        const call = calls.next() orelse break;
        const span = call.span();

        assert(call.category() == .call);

        if (!watched_offset(context, phases, span.offset)) continue;
        if (invokes_a_macro(context, span.offset)) continue;

        const name = head_span(context, call) orelse continue;
        const written = context.span_text(name);

        assert(name.length > 0);

        if (scan.find(written, testing_allocator_name) != null) continue;
        if (!allocates(context, name)) continue;
        if (clones_a_value(context, call, name)) continue;
        if (cannot_run_out_of_memory(context, call)) continue;

        const start = token_start(context, span.offset);

        if (start < context.tokens.len) {
            if (TestScope.nests_a_test(context, start)) continue;
        }

        if (scope.covers(context, span.offset)) continue;

        sink.report_formatted(span, allocates_format, .{scan.utf8_or(written, "the call")});
    }
}

fn head_span(context: *const Context, call: View) ?Span {
    const end = arguments_open(call) orelse return null;
    const last = token_start(context, end);

    var first = last;

    for (0..last) |_| {
        if (first == 0) break;

        const token = context.tokens[first - 1];

        if (continues_a_path(context, token)) {
            first -= 1;

            continue;
        }

        if (token.is_punctuation(.greater)) {
            first = generic_open(context, first - 1) orelse break;

            continue;
        }

        if (!context.is_path_separator(token)) break;

        first -= 1;
    }

    assert(first <= last);

    const named = for (context.tokens[first..last], first..) |token, index| {
        if (token.kind == .identifier) break index;
    } else return null;

    const head = context.tokens[named].offset;

    assert(named < last);
    assert(head < end);

    return .{ .offset = head, .length = end - head };
}

fn continues_a_path(context: *const Context, token: Token) bool {
    if (token.kind == .identifier) return true;
    if (!token.is_punctuation(.dot)) return false;

    const text = context.text(token);

    assert(token.kind == .punctuation);
    assert(text.len > 0);

    return std.mem.allEqual(u8, text, '.');
}

fn arguments_open(call: View) ?u32 {
    assert(call.category() == .call);

    if (paren_open_of(call)) |offset| return offset;

    var children = call.children();

    for (0..children.remaining) |_| {
        const child = children.next() orelse break;

        assert(child.index() > call.index());

        if (paren_open_of(child)) |offset| return offset;
    }

    return null;
}

fn paren_open_of(view: View) ?u32 {
    assert(view.token_start() <= view.token_end());

    var positions = view.positions();

    for (0..positions.remaining) |_| {
        const position = positions.next() orelse return null;
        const token = view.token_at(position);

        assert(position >= view.token_start());

        if (token.is_punctuation(.paren_open)) return token.offset;
    }

    return null;
}

fn generic_open(context: *const Context, close: u32) ?u32 {
    assert(close < context.tokens.len);
    assert(context.tokens[close].is_punctuation(.greater));

    var depth: u32 = 0;
    var cursor = close;

    for (0..generic_scan_max) |_| {
        const token = context.tokens[cursor];

        if (token.is_punctuation(.greater)) depth += 1;

        if (token.is_punctuation(.less)) {
            assert(depth > 0);

            depth -= 1;

            if (depth == 0) return cursor;
        }

        if (stops_a_generic(token)) return null;
        if (cursor == 0) return null;

        cursor -= 1;
    }

    return null;
}

fn stops_a_generic(token: Token) bool {
    const stops = switch (token.kind) {
        .block_start => true,
        .punctuation => |punctuation| switch (punctuation) {
            .paren_close, .paren_open, .semicolon => true,
            else => false,
        },
        .block_end, .comment, .identifier, .keyword, .newline, .number, .string => false,
    };

    if (stops) assert(token.kind != .identifier);

    return stops;
}

fn token_start(context: *const Context, offset: u32) u32 {
    const index = std.sort.partitionPoint(Token, context.tokens, offset, opens_before);

    assert(index <= context.tokens.len);
    if (index < context.tokens.len) assert(context.tokens[index].offset >= offset);

    return @intCast(index);
}

fn opens_before(offset: u32, token: Token) bool {
    return token.offset < offset;
}

fn allocates(context: *const Context, name: Span) bool {
    const written = context.span_text(name);
    const conventions = context.conventions;

    assert(name.end() <= context.source.len);
    assert(written.len == name.length);

    if (scan.word_listed(conventions.allocation_functions, written)) return true;

    const names = path_names(context, name);

    if (names.head.len > 0) {
        if (names_a_qualified_allocation(context, names)) return true;
    }

    if (!invokes_a_method(context, name)) return false;
    return scan.word_listed(conventions.allocation_methods, names.leaf);
}

fn path_names(context: *const Context, span: Span) PathNames {
    assert(span.end() <= context.source.len);

    var depth: u32 = 0;
    var names: PathNames = .{ .head = "", .leaf = "" };

    for (context.tokens_in(span)) |token| {
        const text = context.text(token);

        if (std.mem.eql(u8, text, "<")) {
            depth += 1;

            continue;
        }

        if (std.mem.eql(u8, text, ">")) {
            depth -|= 1;

            continue;
        }

        if (depth > 0) continue;
        if (token.kind != .identifier) continue;

        names = .{ .head = names.leaf, .leaf = text };
    }

    if (names.head.len > 0) assert(names.leaf.len > 0);

    return names;
}

fn names_a_qualified_allocation(context: *const Context, names: PathNames) bool {
    assert(names.head.len > 0);
    assert(names.leaf.len > 0);

    for (context.conventions.allocation_functions) |entry| {
        if (!std.mem.startsWith(u8, entry, names.head)) continue;

        const rest = entry[names.head.len..];
        const tail = separated_tail(rest) orelse continue;
        if (std.mem.eql(u8, tail, names.leaf)) return true;
    }

    return false;
}

fn separated_tail(rest: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, rest, "::")) return rest[2..];
    if (!std.mem.startsWith(u8, rest, ".")) return null;

    assert(rest.len > 0);
    assert(rest[0] == '.');

    return rest[1..];
}

fn invokes_a_method(context: *const Context, name: Span) bool {
    assert(name.end() <= context.source.len);

    if (scan.find(context.span_text(name), ".") != null) return true;

    const start = token_start(context, name.offset);
    if (start == 0) return false;

    assert(start <= context.tokens.len);

    return context.tokens[start - 1].is_punctuation(.dot);
}

fn invokes_a_macro(context: *const Context, offset: u32) bool {
    assert(offset <= context.source.len);

    if (!context.conventions.macros_invoke_with_bang) return false;

    const next = token_start(context, offset) + 1;
    if (next >= context.tokens.len) return false;

    assert(next > 0);

    return context.tokens[next].is_punctuation(.bang);
}

fn clones_a_value(context: *const Context, call: View, name: Span) bool {
    const names = path_names(context, name);

    assert(call.category() == .call);
    assert(name.end() <= context.source.len);

    if (!std.mem.eql(u8, names.leaf, clone_method)) return false;
    if (indexes_a_slice(context, call)) return true;
    return receiver_holds_a_value(context, call);
}

fn indexes_a_slice(context: *const Context, call: View) bool {
    const span = call.span();
    const first = token_start(context, span.offset);
    const last = context.lexer_index_from(span.end());

    assert(first <= context.tokens.len);
    assert(last <= context.tokens.len);

    if (first == 0) return false;
    if (!context.tokens[first - 1].is_punctuation(.bracket_open)) return false;
    if (last >= context.tokens.len) return false;
    return context.tokens[last].is_punctuation(.bracket_close);
}

fn receiver_holds_a_value(context: *const Context, call: View) bool {
    const held = call.as_call() orelse return false;
    const receiver = held.receiver() orelse return false;
    const text = receiver.text(context.source);
    if (text.len == 0) return false;

    for (text) |byte| {
        if (!scan.is_identifier_part(byte)) return false;
    }

    assert(text.len <= context.source.len);
    assert(receiver.span().end() <= context.source.len);

    const declaration = context.declaration_of(receiver.span().offset) orelse
        return false;

    return declares_a_value(context, declaration);
}

fn declares_a_value(context: *const Context, declaration: View) bool {
    if (declaration.type_of()) |annotation| {
        const head = type_head(annotation.text(context.source));

        assert(head.len <= annotation.span().length);

        if (support.is_primitive_type(context, head)) return true;
        return scan.word_in(&value_type_names, head);
    }

    const text = declaration.text(context.source);
    const assign = std.mem.findScalar(u8, text, '=') orelse return false;
    const value = text[assign + 1 ..];

    assert(value.len < text.len);

    if (scan.find(value, range_operator) == null) return false;
    if (std.mem.findScalar(u8, value, '[') != null) return false;
    return std.mem.findScalar(u8, value, '!') == null;
}

fn type_head(spelled: []const u8) []const u8 {
    var text = trimmed_start(spelled);

    for (0..reference_depth_max) |_| {
        if (!std.mem.startsWith(u8, text, "&")) break;

        text = trimmed_start(text[1..]);

        if (std.mem.startsWith(u8, text, "'")) {
            text = trimmed_start(text[identifier_end(text, 1)..]);
        }

        if (std.mem.startsWith(u8, text, "mut ")) text = trimmed_start(text["mut ".len..]);
    }

    const head = text[0..identifier_end(text, 0)];

    assert(head.len <= spelled.len);
    if (head.len > 0) assert(scan.is_identifier_part(head[0]));

    return head;
}

fn identifier_end(text: []const u8, start: u32) u32 {
    assert(start <= text.len);

    const end = for (text[start..], start..) |byte, index| {
        if (!scan.is_identifier_part(byte)) break index;
    } else text.len;

    assert(end >= start);
    assert(end <= text.len);

    return @intCast(end);
}

fn trimmed_start(text: []const u8) []const u8 {
    const trimmed = std.mem.trimStart(u8, text, scan.ascii_whitespace);

    assert(trimmed.len <= text.len);
    if (trimmed.len > 0) assert(!scan.is_ascii_whitespace(trimmed[0]));

    return trimmed;
}

fn cannot_run_out_of_memory(context: *const Context, call: View) bool {
    if (!context.conventions.compiler_rejects_a_dropped_error) return false;

    const span = call.span();
    const first = token_start(context, span.offset);
    const after = context.lexer_index_from(span.end());

    assert(first < after);
    assert(after <= context.tokens.len);

    if (first == 0) return false;
    if (after == context.tokens.len) return false;
    if (discards_its_value(context, first, after)) return true;
    if (switches_on_named_errors(context, after)) return true;
    if (!context.tokens[first - 1].is_keyword(.@"try")) return false;
    return propagates_named_errors(context, span.offset);
}

fn discards_its_value(context: *const Context, first: u32, after: u32) bool {
    assert(first > 0);
    assert(after < context.tokens.len);

    if (!context.tokens[after].is_punctuation(.semicolon)) return false;

    const previous = context.significant_before(first) orelse return false;
    const before = context.tokens[previous];

    assert(previous < first);
    if (before.kind == .block_start) return true;
    if (before.kind == .block_end) return true;
    if (before.is_keyword(.branch_else)) return true;
    if (before.is_punctuation(.paren_close)) return true;
    return before.is_punctuation(.semicolon);
}

fn switches_on_named_errors(context: *const Context, after: u32) bool {
    const tokens = context.tokens;

    assert(after < tokens.len);

    if (!tokens[after].is_keyword(.except)) return false;

    var cursor = after + 1;

    if (cursor + 2 < tokens.len) {
        if (std.mem.eql(u8, context.text(tokens[cursor]), capture_marker)) cursor += 3;
    }

    if (cursor + 1 >= tokens.len) return false;
    if (!tokens[cursor].is_keyword(.match)) return false;
    if (!tokens[cursor + 1].is_punctuation(.paren_open)) return false;

    const subject = context.pairs.partner_of(cursor + 1) orelse return false;
    if (subject + 1 >= tokens.len) return false;

    const open = subject + 1;
    if (tokens[open].kind != .block_start) return false;

    const close = context.pairs.partner_of(open) orelse return false;

    assert(close > open);

    return names_every_error(context, open, close);
}

fn names_every_error(context: *const Context, open: u32, close: u32) bool {
    const tokens = context.tokens;

    assert(open < close);
    assert(close < tokens.len);

    for (tokens[open + 1 .. close], open + 1..) |token, index| {
        if (std.mem.eql(u8, context.text(token), out_of_memory_name)) return false;
        if (!token.is_keyword(.branch_else)) continue;
        if (index + 1 >= close) return false;
        if (std.mem.eql(u8, context.text(tokens[index + 1]), prong_arrow)) return false;
    }

    return true;
}

fn propagates_named_errors(context: *const Context, offset: u32) bool {
    const function = context.function_at(offset) orelse return false;
    const held = function.as_function() orelse return false;
    const returns = held.returns_span() orelse return false;
    const tokens = context.tokens_in(returns);

    assert(returns.end() <= context.source.len);

    const bang = for (tokens, 0..) |token, index| {
        if (token.is_punctuation(.bang)) break index;
    } else return false;

    if (bang == 0) return false;
    return error_set_excludes_oom(context, tokens[0..bang]);
}

fn error_set_excludes_oom(context: *const Context, initial: []const scylla.Token) bool {
    var tokens = initial;

    for (0..64) |_| {
        if (tokens.len == 0) return false;

        const first = context.text(tokens[0]);

        if (std.mem.eql(u8, first, "error")) {
            if (tokens.len < 3) return false;
            if (!tokens[1].opens_a_group_or_block()) return false;
            if (!std.mem.eql(u8, context.text(tokens[tokens.len - 1]), "}")) return false;

            for (tokens[2 .. tokens.len - 1]) |token| {
                if (token.is_punctuation(.comma)) continue;
                if (token.kind != .identifier) return false;
                if (std.mem.eql(u8, context.text(token), out_of_memory_name)) return false;
            }

            return true;
        }

        if (tokens.len != 1) return false;
        if (tokens[0].kind != .identifier) return false;

        const node = context.declaration_of(tokens[0].offset) orelse return false;
        const declaration = node.as_declaration() orelse return false;
        const value = declaration.value() orelse return false;

        tokens = context.tokens_in(value.span());
    }

    return false;
}

fn macros_scan(
    context: *const Context,
    sink: *Sink,
    phases: *const Marks,
    scope: *TestScope,
) void {
    if (!context.conventions.macros_invoke_with_bang) return;

    assert(context.conventions.macros_invoke_with_bang);

    for (context.tokens, 0..) |token, index| {
        if (token.kind != .identifier) continue;
        if (index + 1 >= context.tokens.len) continue;
        if (!context.tokens[index + 1].is_punctuation(.bang)) continue;

        const name = context.text(token);

        assert(name.len == token.length);

        if (!scan.word_listed(context.conventions.allocation_functions, name)) continue;
        if (passes_nothing(context, @intCast(index + 1))) continue;
        if (!watched_offset(context, phases, token.offset)) continue;
        if (scope.covers(context, token.offset)) continue;

        sink.report_formatted(token.span(), allocates_format, .{scan.utf8_or(name, "the call")});
    }
}

fn passes_nothing(context: *const Context, bang: u32) bool {
    assert(bang < context.tokens.len);
    assert(context.tokens[bang].is_punctuation(.bang));

    const open = bang + 1;
    if (open >= context.tokens.len) return false;
    if (!context.tokens[open].opens_a_group_or_block()) return false;

    const close = context.pairs.partner_of(open) orelse return false;

    assert(close > open);

    return close == open + 1;
}

fn literals_scan(
    context: *const Context,
    sink: *Sink,
    phases: *const Marks,
    scope: *TestScope,
) void {
    const conventions = context.conventions;

    if (!conventions.collections_allocate) {
        if (conventions.brace_literal_markers.len == 0) return;
    }

    var functions = context.views(.function);

    for (0..functions.remaining) |_| {
        const function = functions.next() orelse break;

        assert(function.category() == .function);

        if (!runs_after_initialization(context, phases, function)) continue;

        const held = function.as_function() orelse continue;
        const block = held.body() orelse continue;

        assert(block.index() > function.index());

        literals_report(context, sink, block, scope);
    }
}

fn literals_report(
    context: *const Context,
    sink: *Sink,
    block: View,
    scope: *TestScope,
) void {
    const body = block.span();
    const first = token_start(context, body.offset);
    const last = token_start(context, body.end());

    assert(first <= last);
    assert(body.end() <= context.source.len);

    for (context.tokens[first..last], first..) |token, index| {
        if (!opens_a_collection(context, @intCast(index))) continue;
        if (nests_a_function(context, token.offset, body)) continue;
        if (scope.covers(context, token.offset)) continue;

        sink.report(
            token.span(),
            "the expression allocates a collection; reserve the memory during initialization",
        );
    }
}

fn nests_a_function(context: *const Context, offset: u32, body: Span) bool {
    assert(offset >= body.offset);
    assert(offset < body.end());

    var functions = context.views(.function);

    for (0..functions.remaining) |_| {
        const function = functions.next() orelse break;
        const span = function.span();
        if (span.offset < body.offset) continue;
        if (span.end() > body.end()) continue;
        if (span.offset > offset) continue;
        if (offset >= span.end()) continue;
        return true;
    }

    return false;
}

fn opens_a_collection(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);

    const token = context.tokens[index];
    const conventions = context.conventions;

    if (token.is_punctuation(.bracket_open)) {
        if (!conventions.collections_allocate) return false;
        if (opens_a_bracket_literal(context, index)) return !binds_a_pattern(context, index);
        return copies_a_slice(context, index);
    }

    if (token.kind != .block_start) return false;
    if (conventions.brace_literal_markers.len == 0) return false;

    assert(token.kind == .block_start);

    return opens_a_brace_literal(context, index);
}

fn code_token_before(context: *const Context, index: u32) ?u32 {
    assert(index < context.tokens.len);

    for (0..index) |step| {
        const before: u32 = @intCast(index - 1 - step);

        assert(before < index);

        if (context.tokens[before].kind != .comment) return before;
    }

    return null;
}

fn binds_a_pattern(context: *const Context, index: u32) bool {
    const tokens = context.tokens;

    assert(tokens[index].is_punctuation(.bracket_open));

    const close = context.pairs.partner_of(index) orelse return false;

    const after = stream.significant_next(tokens, close + 1, @intCast(tokens.len)) orelse {
        return false;
    };

    assert(after > close);

    if (tokens[after].is_punctuation(.assign)) return true;
    return std.mem.eql(u8, context.text(tokens[after]), pattern_word);
}

fn opens_a_bracket_literal(context: *const Context, index: u32) bool {
    assert(context.tokens[index].is_punctuation(.bracket_open));

    const before = code_token_before(context, index) orelse return true;
    const previous = context.tokens[before];

    assert(previous.kind != .comment);

    return switch (previous.kind) {
        .identifier, .string => false,
        .punctuation => |punctuation| switch (punctuation) {
            .bracket_close, .paren_close => false,
            else => true,
        },
        .block_end, .block_start, .comment, .keyword, .newline, .number => true,
    };
}

fn copies_a_slice(context: *const Context, index: u32) bool {
    if (!context.conventions.slices_copy) return false;
    if (opens_a_bracket_literal(context, index)) return false;

    const close = context.pairs.partner_of(index) orelse return false;

    assert(close > index);
    assert(context.tokens[index].is_punctuation(.bracket_open));

    if (close + 1 < context.tokens.len) {
        if (context.tokens[close + 1].is_punctuation(.assign)) return false;
    }

    var depth: u32 = 0;

    for (context.tokens[index + 1 .. close]) |token| {
        if (token.opens_a_group_or_block()) depth += 1;
        if (token.closes_a_group_or_block()) depth -|= 1;
        if (depth > 0) continue;
        if (token.is_punctuation(.colon)) return true;
    }

    return false;
}

fn opens_a_brace_literal(context: *const Context, index: u32) bool {
    assert(context.tokens[index].kind == .block_start);

    const tokens = context.tokens;

    var cursor = code_token_before(context, index) orelse return false;
    var start = index;

    if (tokens[cursor].kind == .identifier) {
        start = literal_type_start(context, cursor);

        if (start == 0) return false;

        cursor = start - 1;
    }

    if (tokens[cursor].is_punctuation(.bracket_close)) {
        start = context.pairs.partner_of(cursor) orelse return false;

        if (start > 0) {
            if (std.mem.eql(u8, context.text(tokens[start - 1]), map_word)) start -= 1;
        }

        if (start == 0) return false;

        cursor = start - 1;
    }

    assert(cursor < start);
    assert(start <= index);

    if (!opens_an_expression(context, cursor)) return false;

    const text = context.source[tokens[start].offset..tokens[index].offset];

    for (context.conventions.brace_literal_markers) |marker| {
        if (std.mem.startsWith(u8, text, marker)) return true;
    }

    return false;
}

fn literal_type_start(context: *const Context, index: u32) u32 {
    assert(context.tokens[index].kind == .identifier);

    const tokens = context.tokens;

    var cursor = index;

    for (0..literal_chain_max) |_| {
        if (cursor < 2) break;
        if (!tokens[cursor - 1].is_punctuation(.dot)) break;
        if (tokens[cursor - 2].kind != .identifier) break;

        cursor -= 2;
    }

    assert(cursor <= index);

    if (cursor == 0) return cursor;
    if (tokens[cursor - 1].is_punctuation(.ampersand)) return cursor - 1;
    if (tokens[cursor - 1].is_punctuation(.star)) return cursor - 1;
    return cursor;
}

fn opens_an_expression(context: *const Context, index: u32) bool {
    const token = context.tokens[index];
    const text = context.text(token);

    assert(text.len == token.length);

    if (token.is_keyword(.@"return")) return text.len > 0;
    if (std.mem.eql(u8, text, context.conventions.iteration_word)) return text.len > 0;
    if (token.is_punctuation(.colon)) return labels_a_value(context, index);

    const opens = switch (token.kind) {
        .punctuation => |punctuation| switch (punctuation) {
            .assign, .assign_declare, .bracket_open, .comma, .paren_open => true,
            else => scan.word_in(&expression_operators, text),
        },
        .block_end, .block_start, .comment, .identifier, .keyword, .newline, .number => false,
        .string => false,
    };

    if (opens) assert(token.kind == .punctuation);

    return opens;
}

fn labels_a_value(context: *const Context, colon: u32) bool {
    assert(context.tokens[colon].is_punctuation(.colon));

    if (colon == 0) return false;

    const tokens = context.tokens;
    const label = tokens[colon - 1];

    switch (label.kind) {
        .identifier, .number, .string => {},
        else => return false,
    }

    if (scan.word_in(&label_words, context.text(label))) return false;
    if (colon == 1) return true;

    const held = tokens[colon - 2];

    assert(held.offset <= label.offset);

    if (scan.word_in(&label_words, context.text(held))) return false;
    if (label.kind != .identifier) return true;
    if (held.is_keyword(.declare)) return false;
    if (held.is_keyword(.constant)) return false;
    return !held.is_keyword(.mutable);
}

fn strings_scan(
    context: *const Context,
    sink: *Sink,
    phases: *const Marks,
    scope: *TestScope,
) void {
    const conventions = context.conventions;

    if (conventions.strings_build_prefixes.len == 0) {
        if (!conventions.strings_concatenate_allocate) return;
    }

    const quotes = support.quotes_of(context.front.language);

    var depth: u32 = 0;

    for (context.tokens, 0..) |token, position| {
        const index: u32 = @intCast(position);
        const nested = depth > 0;

        if (quotes) |held| depth = support.quote_depth(held, depth, token);
        if (nested) continue;

        const built = builds_a_string(context, index) or concatenates_a_string(context, index);
        if (!built) continue;
        if (!watched_offset(context, phases, token.offset)) continue;
        if (scope.covers(context, token.offset)) continue;

        assert(token.kind != .comment);
        assert(token.length > 0);

        sink.report(
            support.literal_span(context, index),
            "the expression builds a string; format into a fixed buffer reserved during " ++
                "initialization",
        );
    }
}

fn builds_a_string(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);

    const token = context.tokens[index];
    if (token.kind != .string) return false;
    if (spells_jsx_text(context, token)) return false;

    const text = context.text(token);

    assert(text.len == token.length);

    for (context.conventions.strings_build_prefixes) |prefix| {
        if (std.mem.startsWith(u8, text, prefix)) return true;
    }

    return false;
}

fn spells_jsx_text(context: *const Context, token: Token) bool {
    assert(token.kind == .string);
    assert(token.length > 0);

    switch (context.front.language) {
        .javascript, .typescript => {},
        else => return false,
    }

    return token.exact_kind(JavascriptKind) == .jsx_chars;
}

fn concatenates_a_string(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);

    if (!context.conventions.strings_concatenate_allocate) return false;

    const token = context.tokens[index];
    if (!token.is_punctuation(.other)) return false;
    if (!std.mem.startsWith(u8, context.text(token), "+")) return false;
    if (index + 1 >= context.tokens.len) return false;

    const next = context.tokens[index + 1];
    if (next.kind != .string) return false;

    const text = context.text(next);

    assert(next.offset >= token.end());

    if (std.mem.startsWith(u8, text, "'")) return false;

    for (context.conventions.strings_bytes_prefixes) |prefix| {
        if (std.mem.startsWith(u8, text, prefix)) return false;
    }

    return true;
}

fn expect_count(language: Language, source: []const u8, expected: u32) !void {
    assert(source.len > 0);
    assert(expected <= testing.limits.diagnostic_count_max);

    var findings = try testing.analyze(@This(), language, source);
    defer findings.deinit();

    if (findings.count() != expected) findings.print();

    try std.testing.expectEqual(expected, findings.count());
}

test "a heap constructor is reported" {
    const source = "fn work() {\n    let values = Vec::with_capacity(4);\n}\n";

    var findings = try testing.analyze(@This(), .rust, source);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
    try std.testing.expect(std.mem.find(u8, findings.message(0), "Vec::with_capacity") != null);
}

test "an empty collection constructor is quiet and the call that grows it is reported" {
    const empty = "fn work() -> Vec<u8> {\n    let map: HashMap<u8, u8> = HashMap::new();\n" ++
        "    let text = String::new();\n    let values: Vec<u8> = vec![];\n    Vec::default()\n}\n";

    const grown = "fn work() {\n    let mut text = String::new();\n    text.push_str(\"a\");\n" ++
        "    let mut values = vec![];\n    values.push(1);\n}\n";

    const sized = "fn work() {\n    let values = vec![0; 4];\n" ++
        "    let text = String::with_capacity(4);\n}\n";

    try testing.expect_quiet(@This(), .rust, empty);
    try testing.expect_anchors(@This(), .rust, grown, &.{ .{ 3, 5 }, .{ 5, 5 } });
    try expect_count(.rust, sized, 2);
}

test "a read into a buffer and an entry insertion are reported" {
    const source = "fn work(file: &mut File, counts: &mut Counts, block: &mut [u8]) {\n" ++
        "    let mut text = String::new();\n    file.read_to_string(&mut text);\n" ++
        "    counts.entry(1).or_insert(0);\n    file.read_exact(block);\n}\n";

    try testing.expect_anchors(@This(), .rust, source, &.{ .{ 3, 5 }, .{ 4, 5 } });
}

test "a turbofish or a qualified path still names the constructor" {
    const turbofish = "fn work() {\n    let values = Vec::<u8>::with_capacity(4);\n}\n";
    const qualified = "fn work() {\n    let held = std::rc::Rc::new(4);\n}\n";
    const collected = "fn work(items: &[u8]) {\n    let v = items.iter().collect::<Vec<_>>();\n}\n";

    try expect_count(.rust, turbofish, 1);
    try expect_count(.rust, qualified, 1);
    try expect_count(.rust, collected, 1);
}

test "a clone of a range is quiet" {
    const source = "fn work(source: &[u8], range: Range<usize>, held: &Range<usize>) {\n" ++
        "    let raw = &source[range.clone()];\n    read(range.clone());\n" ++
        "    read(held.clone());\n    let root = 0..source.len();\n" ++
        "    read(root.clone());\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
}

test "a clone of a heap value is reported" {
    const source = "fn work(text: String, items: &Vec<u8>) {\n    read(text.clone());\n" ++
        "    read(items.clone());\n    let Some(found) = lookup() else {\n" ++
        "        return;\n    };\n    read(found.clone());\n}\n";

    try expect_count(.rust, source, 3);
}

test "a byte string after a plus is not a concatenation" {
    const source = "fn work(directory: &[u8]) -> usize {\n" ++
        "    directory.len() + b\"_rels/\".len()\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
}

test "a growth method and a string concatenation are reported" {
    const source = "fn work(mut v: Vec<u8>, s: String) -> String {\n    v.push(1);\n" ++
        "    v.clone();\n    s + \"tail\"\n}\n";

    try expect_count(.rust, source, 3);
}

test "an allocation inside a zig test is quiet" {
    const source = "test \"work\" {\n    const values = try gpa.alloc(u8, 4);\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "a zig growth method is reported" {
    const source = "fn work(list: *List) !void {\n    try list.append(1);\n" ++
        "    try map.put(1, 2);\n}\n";

    try expect_count(.zig, source, 2);
}

test "a zig growth call that cannot fail does not allocate" {
    const bare = "fn work(set: *Set, list: *List) void {\n    set.insert(1);\n\n" ++
        "    if (set.full()) list.insert(2);\n}\n";

    const named = "fn work(table: *Table) void {\n" ++
        "    table.insert(1, 2) catch |err| switch (err) {\n" ++
        "        error.Duplicate => unreachable,\n        error.Full => {},\n    };\n}\n\n" ++
        "fn more(table: *Table) error{Full}!void {\n    try table.insert(1, 2);\n}\n";

    const exhausted = "fn grow(list: *List, gpa: Allocator) void {\n" ++
        "    list.append(gpa, 1) catch |err| switch (err) {\n" ++
        "        error.OutOfMemory => unreachable,\n    };\n}\n";

    try testing.expect_quiet(@This(), .zig, bare);
    try testing.expect_quiet(@This(), .zig, named);
    try expect_count(.zig, exhausted, 1);
}

test "a zig growth call standing alone after a comment cannot fail" {
    const commented = "fn mark(set: *Set) void {\n    // Mark the theme.\n" ++
        "    set.insert(.theme);\n}\n";

    const tried = "fn mark(set: *Set) !void {\n    // Mark the theme.\n" ++
        "    try set.insert(.theme);\n}\n";

    try testing.expect_quiet(@This(), .zig, commented);
    try expect_count(.zig, tried, 1);
}

test "a zig helper or type only tests reach is test code" {
    const helper = "fn lexed(gpa: Allocator) !List {\n    var found: List = .empty;\n\n" ++
        "    try found.append(gpa, 1);\n\n    return found;\n}\n\n" ++
        "test \"lexes\" {\n    _ = try lexed(std.testing.allocator);\n}\n";

    const shared = "pub fn run(gpa: Allocator) !void {\n    _ = try lexed(gpa);\n}\n\n" ++
        helper;

    const recorder = "const Recorder = struct {\n    sources: List,\n\n" ++
        "    fn apply(recorder: *Recorder, gpa: Allocator) !void {\n" ++
        "        try recorder.sources.append(gpa, 1);\n    }\n};\n\n" ++
        "fn loaded(recorder: *Recorder) !void {\n    try load(Recorder, recorder);\n}\n\n" ++
        "test \"records\" {\n    var recorder: Recorder = .{ .sources = .empty };\n\n" ++
        "    try loaded(&recorder);\n}\n";

    try testing.expect_quiet(@This(), .zig, helper);
    try expect_count(.zig, shared, 1);
    try testing.expect_quiet(@This(), .zig, recorder);
}

test "an allocation during initialization is quiet" {
    const source = "fn init() {\n    let values = Vec::with_capacity(4);\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
}

test "an odin procedure declared as main or called only from it is initialization" {
    const source = "package p\n\nhelper :: proc() -> int {\n\tlist: [dynamic]int\n" ++
        "\tappend(&list, 1)\n\treturn len(list)\n}\n\nmain :: proc() {\n" ++
        "\tbuilder := strings.builder_make()\n\tcount := helper()\n\t_ = count\n" ++
        "\t_ = builder\n\twork()\n}\n\nwork :: proc() {\n\tlist: [dynamic]int\n" ++
        "\tappend(&list, 1)\n}\n\nserve :: proc() {\n\twork()\n}\n";

    try testing.expect_anchors(@This(), .odin, source, &.{.{ 19, 2 }});
}

test "a function called only from initialization is initialization" {
    const source = "fn main() {\n    load_pool();\n}\n\nfn load_pool() {\n" ++
        "    let v = vec![1, 2];\n}\n";

    const shared = "fn main() {\n    load_pool();\n    work();\n}\n\nfn work() {\n" ++
        "    load_pool();\n}\n\nfn load_pool() {\n    let v = vec![1, 2];\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
    try expect_count(.rust, shared, 1);
}

test "a name that merely opens with an initializer word is watched" {
    const prefixed = "fn init_pool() {\n    let v = vec![1, 2];\n}\n";

    const builder = "fn build_response() -> String {\n    let v = String::from(\"a\");\n" ++
        "    v\n}\n";

    const failing = "fn work() -> Result<(), String> {\n    Err(format!(\"a\"))\n}\n";

    try expect_count(.rust, prefixed, 1);
    try expect_count(.rust, builder, 1);
    try expect_count(.rust, failing, 1);
}

test "an allocating macro is reported" {
    try expect_count(.rust, "fn work() {\n    let values = vec![1, 2];\n}\n", 1);
}

test "a go builtin is reported" {
    const source = "func work() {\n\tvalues := make([]int, 4)\n}\n";

    var findings = try testing.analyze(@This(), .go, source);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
    try std.testing.expect(std.mem.find(u8, findings.message(0), "make") != null);
}

test "a go composite literal is reported where it lives on the heap" {
    const source = "func work() {\n\tvalues := []int{1, 2}\n\tm := map[string]int{}\n" ++
        "\tp := &Point{}\n\tq := Point{}\n\ta := [2]int{1, 2}\n}\n";

    const header = "func work() {\n\tfor _, v := range []int{1} {\n\t\tuse(v)\n\t}\n}\n";

    try expect_count(.go, source, 3);
    try expect_count(.go, header, 1);
}

test "a go string builder is reported" {
    const source = "func work(x int) string {\n\ts := fmt.Sprintf(\"%d\", x)\n" ++
        "\treturn s + \"a\"\n}\n";

    try expect_count(.go, source, 2);
}

test "an odin dynamic literal and an append are reported" {
    const source = "package fixture\n\nwork :: proc() {\n    values := [dynamic]int{}\n" ++
        "    append(&values, 1)\n    p := Point{}\n}\n";

    try expect_count(.odin, source, 2);
}

test "a javascript destructuring pattern binds names rather than building an array" {
    const source = "function run(entries, list) {\n" ++
        "    for (const [key, value] of Object.entries(entries)) {\n" ++
        "        work(key, value);\n    }\n\n    const [first, second] = list;\n" ++
        "    const copy = [first, second];\n\n    return copy;\n}\n";

    const python = "def run(argv, value):\n    if argv[1:] in ([\"--help\"],):\n" ++
        "        return [value] in argv\n    [first] = argv\n    return first\n";

    try expect_count(.javascript, source, 1);
    try expect_count(.python, python, 3);
}

test "a javascript object literal and a typed array are reported" {
    const source = "function work(x) {\n    const o = {};\n    const p = { ...x };\n" ++
        "    if (x) {\n        return o;\n    }\n    return new Uint8Array(4);\n}\n";

    const switched = "function work(x) {\n    switch (x) {\n        case 1: {\n" ++
        "            return 2;\n        }\n    }\n    return x.map(f);\n}\n";

    try expect_count(.javascript, source, 3);
    try expect_count(.javascript, switched, 1);
}

test "a template literal is reported and a type literal is not" {
    const source = "function work(x: number): string {\n" ++
        "    const held: { a: number } = { a: x };\n    return `a${x}`;\n}\n";

    try expect_count(.typescript, source, 2);
}

test "a python slice copy and a format string are reported" {
    const source = "def work(x):\n    a = x[:]\n    b = x[0]\n    c = f\"a{x}\"\n" ++
        "    d = x.copy()\n    return sorted(x)\n";

    try expect_count(.python, source, 4);
}

test "a python slice an assignment writes into copies nothing" {
    try expect_count(.python, "def fill(results, values):\n    results[1:] = values\n", 0);
    try expect_count(.python, "def head(results):\n    first = results[1:]\n    return first\n", 1);
}

test "a python method called only from the constructor is initialization" {
    const source = "class Pool:\n    def __init__(self):\n        self.load()\n\n" ++
        "    def load(self):\n        self.items = [1, 2]\n";

    try testing.expect_quiet(@This(), .python, source);
}

test "a chain anchors past a try expression" {
    const source = "fn f(text: &str) -> Option<String> {\n    Some(\n" ++
        "        text.find(\"a\")\n.map(|found| found + 1)?\n            .to_string(),\n" ++
        "    )\n}\n";

    try testing.expect_anchors(@This(), .rust, source, &.{.{ 3, 9 }});
}

test "a chain anchors past a macro brace group" {
    const source = "fn f() -> String {\n    let value = toml::toml! {\n        a = 1\n" ++
        "    }\n.to_string();\n    value\n}\n";

    try testing.expect_anchors(@This(), .rust, source, &.{.{ 2, 17 }});
}

test "a chain anchors past an indexed literal" {
    const source = "fn f() -> Vec<u8> {\n    b\"ab\"[..].to_owned()\n}\n";

    try testing.expect_anchors(@This(), .rust, source, &.{.{ 2, 5 }});
}

test "a decl literal behind try anchors at the dot" {
    const source = "fn f() void {\n" ++
        "    var list: std.ArrayList(u8) = try .initCapacity(a, 1);\n_ = list;\n}\n";

    try testing.expect_anchors(@This(), .zig, source, &.{.{ 2, 39 }});
}

test "a comment does not hide the name a subscript belongs to" {
    const source = "function work() {\n    const x = items /* note */ [0];\n}\n";
    const literal = "function work() {\n    const values = [ /* note */ 1];\n}\n";

    try testing.expect_quiet(@This(), .javascript, source);
    try expect_count(.javascript, literal, 1);
}

test "a comment ahead of a literal leaves it a literal" {
    const source = "def work():\n    values = (\n        # note\n        [1, 2]\n    )\n";

    try expect_count(.python, source, 1);
}

test "a literal inside a nested function is reported once" {
    const source = "def work():\n    def inner():\n        values = [1, 2]\n    return inner\n";

    const after = "function work() {\n    function a() {\n        const values = [1];\n" ++
        "    }\n    return a;\n}\n";

    try expect_count(.python, source, 1);
    try expect_count(.javascript, after, 1);
}

test "a literal in the second nested function is still reported once" {
    const source = "def work():\n    def first():\n        return 1\n    def second():\n" ++
        "        return [1, 2]\n";

    try expect_count(.python, source, 1);
}

test "a function inside a test block is inside the test" {
    const source = "test \"outer\" {\n    fn work() void {\n" ++
        "        const v = try gpa.alloc(u8, 4);\n    }\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "a bare call is not a method call" {
    try testing.expect_quiet(@This(), .rust, "fn work() {\n    let v = to_vec();\n}\n");
}

test "a reported call span starts at the receiver" {
    const source = "fn work(a: A) {\n    let v = a.b.to_vec();\n}\n";

    var findings = try testing.analyze(@This(), .rust, source);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());

    const span = findings.span(0);

    try std.testing.expectEqualStrings("a.b.to_vec()", source[span.offset..span.end()]);
}

test "a function beside a test block is not inside it" {
    const after = "fn work() void {\n    const v = try gpa.alloc(u8, 4);\n}\n\n" ++
        "test \"t\" {\n    const x = 1;\n}\n";

    const before = "test \"t\" {\n    const x = 1;\n}\n\nfn work() void {\n" ++
        "    const v = try gpa.alloc(u8, 4);\n}\n";

    try expect_count(.zig, after, 1);
    try expect_count(.zig, before, 1);
}

test "a literal ahead of a nested function still belongs to the outer one" {
    const python = "def work():\n    values = [1, 2]\n    def inner():\n        return 1\n";

    const around = "function work() {\n    const a = [1];\n    function inner() {\n" ++
        "        return 2;\n    }\n    const b = [3];\n}\n";

    try expect_count(.python, python, 1);
    try expect_count(.javascript, around, 2);
}

test "a macro belongs to the function whose tokens cover it" {
    const before = "fn work() {\n    let v = vec![1, 2];\n}\n\nfn init() {\n    let a = 1;\n}\n";
    const after = "fn init() {\n    let a = 1;\n}\n\nfn work() {\n    let v = vec![1, 2];\n}\n";

    try expect_count(.rust, before, 1);
    try expect_count(.rust, after, 1);
}

test "an optional chain or an unwrap ends the receiver path" {
    const chained = "function work(a: A) {\n    return a.items?.map(f);\n}\n";
    const unwrapped = "fn work(m: *M) !void {\n    try m.log.?.append(1);\n}\n";
    const mapped = [_][]const u8{"map allocates; reserve the memory during initialization"};
    const appended = [_][]const u8{"append allocates; reserve the memory during initialization"};

    try testing.expect_findings(@This(), .typescript, chained, &mapped);
    try testing.expect_findings(@This(), .zig, unwrapped, &appended);
}

test "a nested template or format string builds one string" {
    const template = "function work(x: number): string {\n" ++
        "    return `a${x ? `b${x}` : ''}`;\n}\n";

    const format = "def work(x):\n    return f'{f\"{x}\"}'\n";

    try expect_count(.typescript, template, 1);
    try expect_count(.python, format, 1);
}

test "jsx text is not a template" {
    const source = "function work(x) {\n    return <p>The `{x}` file</p>;\n}\n";

    try testing.expect_quiet(@This(), .javascript, source);
}

test "a logical assignment opens an object literal" {
    const source = "function work(a: A) {\n    a.x ??= {};\n    a.y ||= {};\n    a.z &&= {};\n}\n";

    try expect_count(.typescript, source, 3);
}

test "a template finding spans the whole literal" {
    const source = "function f(a) {\n    const s = `x${a}`;\n    return s;\n}\n";

    try testing.expect_spans(@This(), .javascript, source, &.{.{ 30, 37 }});
}

test "local error aliases without OutOfMemory do not imply allocation" {
    const source = "const CapacityError = error{Full};\n" ++
        "const WriteError = CapacityError;\n" ++
        "fn write(table: *Table) WriteError!void {\n    try table.insert(1);\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "allocating unresolved and cyclic error aliases remain conservative" {
    const source = "const AllocError = error{OutOfMemory};\n" ++
        "const Cycle = Cycle;\n" ++
        "fn one(list: *List) AllocError!void {\n    try list.append(1);\n}\n" ++
        "fn two(list: *List) Unknown!void {\n    try list.append(1);\n}\n" ++
        "fn three(list: *List) Cycle!void {\n    try list.append(1);\n}\n";

    try expect_count(.zig, source, 3);
}
