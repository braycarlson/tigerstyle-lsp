const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const stream = @import("../../stream.zig");
const support = @import("../support.zig");
const testing = @import("../testing.zig");
const Context = @import("../context.zig");
const Language = scylla.Language;
const Rule = scylla.rule.Rule;
const Sink = scylla.rule.Sink;
const Token = scylla.Token;
const TokenRange = Context.TokenRange;
const View = scylla.View;
const scan = @import("../../scan.zig");

pub const rule: Rule = .{
    .citations = &.{
        .{
            .standard = "NASA",
            .text = "NASA P10 Rule 5: \"Assertions must always be side-effect free and should " ++
                "be defined as Boolean tests.\"",
        },
    },
    .code = "TS036",
    .default_on = true,
    .description = "An assertion only reads state, because a build that strips assertions must " ++
        "run the same program.",
    .explanation = "",
    .fix_title = "",
    .fixable = .sometimes,
    .group = .stable,
    .name = "assert-side-effects",
    .severity = .@"error",
    .summary = "An assertion must not change the program",
    .url = "",
};

const FunctionBound = struct {
    context: *const Context,
    offset: u32,

    fn before(bound: FunctionBound, position: u32) bool {
        return bound.context.view(position).span().offset < bound.offset;
    }
};

const Modules = struct {
    count: u32,
    names: [module_count_max][]const u8,
    state: State,

    const State = enum { listed, overflowed, pending };
    const pending: Modules = .{ .count = 0, .names = undefined, .state = .pending };

    fn includes(modules: *Modules, context: *const Context, name: []const u8) bool {
        assert(name.len > 0);

        if (modules.state == .pending) modules.list(context);

        assert(modules.state != .pending);
        assert(modules.count <= module_count_max);

        for (modules.names[0..modules.count]) |listed| {
            if (std.mem.eql(u8, listed, name)) return true;
        }

        return false;
    }

    fn list(modules: *Modules, context: *const Context) void {
        assert(modules.state == .pending);
        assert(modules.count == 0);

        modules.state = .listed;

        for (context.tokens, 0..) |token, position| {
            if (token.kind != .identifier) continue;
            if (!binds_a_module(context, @intCast(position))) continue;

            if (modules.count == module_count_max) {
                modules.state = .overflowed;

                return;
            }

            modules.names[modules.count] = context.text(token);
            modules.count += 1;
        }
    }
};

const as_word = "as";
const assigning_operators = [_][]const u8{ "&&=", "&^=", ">>>=", "||=" };
const await_word = "await";
const comparison_operators = [_][]const u8{ "!=", "!==", "<=", "==", "===", "=>", ">=" };
const comparison_prefixes = [_][]const u8{ "!", "!=", "<", "=", "==", ">" };
const import_word = "import";
const module_count_max: u32 = 64;
const receive_operator = "<-";
const shared_receiver = "&self";
const two_value_markers = [_][]const u8{ "_eq", "_matches", "_ne" };
const walrus = ":=";

const synchronous_callers = [_][]const u8{
    "all",
    "any",
    "every",
    "filter",
    "find",
    "forEach",
    "map",
    "reduce",
    "some",
};

pub fn run(context: *const Context, sink: *Sink) void {
    var modules: Modules = .pending;

    for (context.tokens, 0..) |token, index| {
        if (!asserts_at(context, @intCast(index))) continue;

        const arguments = support.assert_arguments(context, @intCast(index)) orelse continue;

        const consequence: []const u8 = if (survives_a_release(context, token))
            "; an assertion only reads, and this one runs in release builds too"
        else
            "; an assertion only reads";

        assert(arguments.start > index);
        assert(arguments.start < arguments.end);

        report_a_side_effect(context, sink, &modules, arguments, consequence);
    }
}

fn asserts_at(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);

    const token = context.tokens[index];

    assert(token.end() <= context.source.len);

    if (token.is_keyword(.assert)) return true;
    if (token.kind != .identifier) return false;
    if (index + 1 == context.tokens.len) return false;
    if (!context.tokens[index + 1].is_punctuation(.paren_open)) return false;
    return context.calls_an_expectation_alias(index);
}

fn survives_a_release(context: *const Context, token: Token) bool {
    const text = context.text(token);

    assert(token.is_keyword(.assert) or token.kind == .identifier);
    assert(text.len > 0);

    return scan.word_listed(context.conventions.assertions_survive_release, text);
}

fn report_a_side_effect(
    context: *const Context,
    sink: *Sink,
    modules: *Modules,
    arguments: TokenRange,
    consequence: []const u8,
) void {
    const open = arguments.start;
    const close = arguments.end;
    const tokens = context.tokens;
    const nested = nests_a_function(context, arguments);

    assert(open < close);
    assert(close <= tokens.len);

    for (open..close) |offset_index| {
        const offset: u32 = @intCast(offset_index);

        if (nested) {
            if (runs_later(context, open, offset)) continue;
        }

        if (changes_state(context, open, offset)) {
            const around = context.pairs.argument_around(.{ .first = open, .last = close }, offset);
            const span = stream.span_of_range(tokens, around.first, around.last);

            assert(around.first <= offset);
            assert(offset < around.last);

            sink.report_formatted(span, "the assertion changes state{s}", .{consequence});

            return;
        }

        const name = mutates(context, modules, offset) orelse continue;
        const first = context.pairs.receiver_start(offset);
        const group = context.pairs.arguments_of(offset + 1);
        const last = if (group) |held| held.last + 1 else offset + 1;
        const span = stream.span_of_range(tokens, first, @min(last, close));

        assert(first <= offset);
        assert(last > offset);

        sink.report_formatted(span, "the assertion calls {s}, which changes state{s}", .{
            scan.utf8_or(name, "the name"),
            consequence,
        });

        return;
    }
}

fn changes_state(context: *const Context, open: u32, index: u32) bool {
    assert(open <= index);
    assert(index < context.tokens.len);

    if (suspends(context, index)) return true;
    if (!assigns(context, index)) return false;
    if (context.tokens[index].is_punctuation(.colon)) return true;
    if (initializes_a_field(context, open, index)) return false;
    if (declares_a_local(context, open, index)) return false;
    return !names_an_argument(context, open, index);
}

fn declares_a_local(context: *const Context, open: u32, index: u32) bool {
    const tokens = context.tokens;

    assert(open <= index);
    assert(index < tokens.len);

    if (!tokens[index].is_punctuation(.assign)) return false;

    var cursor = index;

    for (0..index - open) |_| {
        cursor -= 1;

        if (cursor <= open) return false;

        const token = tokens[cursor];
        if (declares(token)) return true;
        if (token.opens_a_group_or_block()) return false;
        if (token.is_punctuation(.semicolon)) return false;
        if (!token.closes_a_group_or_block()) continue;

        cursor = context.pairs.partner_of(cursor) orelse return false;

        if (cursor <= open) return false;
    }

    return false;
}

fn declares(token: Token) bool {
    const keyword = switch (token.kind) {
        .keyword => |held| held,
        else => return false,
    };

    return switch (keyword) {
        .constant, .declare, .mutable => true,
        else => false,
    };
}

fn suspends(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);

    const text = context.text(context.tokens[index]);

    assert(text.len == context.tokens[index].length);

    if (std.mem.eql(u8, text, receive_operator)) return context.conventions.channel_word.len > 0;
    if (!std.mem.eql(u8, text, await_word)) return false;
    return support.suspends_at(context, index);
}

fn nests_a_function(context: *const Context, arguments: TokenRange) bool {
    const opened = context.tokens[arguments.start].offset;
    const closed = context.tokens[arguments.end - 1].end();

    assert(arguments.start < arguments.end);
    assert(opened < closed);

    for (Context.callable_categories) |category| {
        const positions = context.front.nodes_of(category);
        const bound: FunctionBound = .{ .context = context, .offset = opened };
        const first = std.sort.partitionPoint(u32, positions, bound, FunctionBound.before);

        assert(first <= positions.len);

        if (first == positions.len) continue;
        if (context.view(positions[first]).span().offset < closed) return true;
    }

    return false;
}

fn runs_later(context: *const Context, open: u32, index: u32) bool {
    const opened = context.tokens[open].offset;
    const function = context.function_at(context.tokens[index].offset) orelse return false;

    assert(open <= index);
    assert(function.as_function() != null);

    if (function.span().offset <= opened) return false;
    return passed_along(context, function);
}

fn passed_along(context: *const Context, function: View) bool {
    const parent = function.parent() orelse return false;

    assert(parent.index() < function.index());

    if (parent.category() != .expression) return false;

    const call = parent.parent() orelse return false;
    if (call.category() != .call) return false;

    const start = function.span().offset;
    const callee = call.child_first() orelse return false;
    const span = callee.span();

    assert(call.index() < parent.index());

    if (span.offset <= start) {
        if (start < span.end()) return false;
    }

    return !runs_its_argument(context, callee);
}

fn runs_its_argument(context: *const Context, callee: View) bool {
    const text = callee.text(context.source);
    const dot = std.mem.findScalarLast(u8, text, '.');
    const method = scan.trim_ascii(if (dot) |at| text[at + 1 ..] else text);

    assert(callee.parent() != null);
    assert(method.len <= text.len);

    return scan.word_in(&synchronous_callers, method);
}

fn assigns(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);

    const token = context.tokens[index];
    if (token.is_punctuation(.assign)) return !compares(context, index);
    if (token.is_punctuation(.assign_declare)) return true;
    if (token.is_punctuation(.colon)) return std.mem.eql(u8, context.text(token), walrus);

    const text = context.text(token);

    if (token.kind == .punctuation) {
        if (scan.word_in(&assigning_operators, text)) return true;
    }

    if (!token.is_punctuation(.other)) return false;

    const concatenates = context.conventions.plus_plus_concatenates;

    assert(text.len > 0);

    if (std.mem.eql(u8, text, "+")) {
        if (concatenates) return false;
        return doubled(context, index);
    }

    if (std.mem.eql(u8, text, "-")) return doubled(context, index);
    if (std.mem.eql(u8, text, "++")) return !concatenates;
    if (std.mem.eql(u8, text, "--")) return true;
    if (text.len < 2) return false;
    if (text[text.len - 1] != '=') return false;
    return !scan.word_in(&comparison_operators, text);
}

fn doubled(context: *const Context, index: u32) bool {
    const tokens = context.tokens;

    assert(index < tokens.len);
    assert(tokens[index].length == 1);

    if (index + 1 >= tokens.len) return false;

    const token = tokens[index];
    const next = tokens[index + 1];
    if (next.offset != token.end()) return false;
    return std.mem.eql(u8, context.text(next), context.text(token));
}

fn compares(context: *const Context, index: u32) bool {
    if (index == 0) return false;

    const previous = context.tokens[index - 1];
    const token = context.tokens[index];

    assert(token.is_punctuation(.assign));
    assert(previous.offset <= token.offset);

    if (previous.end() != token.offset) return false;
    return scan.word_in(&comparison_prefixes, context.text(previous));
}

fn names_an_argument(context: *const Context, open: u32, index: u32) bool {
    assert(open <= index);
    assert(index < context.tokens.len);

    if (index < 2) return false;

    const name = context.tokens[index - 1];
    const before = context.tokens[index - 2];

    assert(before.offset <= name.offset);

    if (name.kind != .identifier) return false;

    if (!context.conventions.arguments_are_named) {
        return names_a_macro_argument(context, open, index);
    }

    if (before.is_punctuation(.paren_open)) return true;
    return before.is_punctuation(.comma);
}

fn names_a_macro_argument(context: *const Context, open: u32, index: u32) bool {
    const tokens = context.tokens;

    assert(index >= 2);
    assert(tokens[index - 1].kind == .identifier);

    if (!context.conventions.macros_invoke_with_bang) return false;

    const enclosing = context.pairs.enclosing_at(tokens[index].offset) orelse return false;
    const opener = enclosing.open;

    assert(opener < index);

    if (opener <= open) return names_an_assertion_option(context, opener, index);
    if (opener < 2) return false;
    if (!tokens[opener - 1].is_punctuation(.bang)) return false;
    if (tokens[opener - 2].kind != .identifier) return false;
    if (opener == index - 2) return true;
    return tokens[index - 2].is_punctuation(.comma);
}

fn names_an_assertion_option(context: *const Context, opener: u32, index: u32) bool {
    const tokens = context.tokens;

    assert(opener < index);
    assert(index < tokens.len);

    if (opener < 2) return false;
    if (index < opener + 3) return false;
    if (!tokens[opener - 1].is_punctuation(.bang)) return false;
    if (!tokens[index - 2].is_punctuation(.comma)) return false;

    const named = tokens[opener - 2];

    if (named.kind != .identifier) {
        if (!named.is_keyword(.assert)) return false;
    }

    const macro = context.text(named);
    const compared: u32 = if (compares_two_values(macro)) 2 else 1;
    var commas: u32 = 0;
    var depth: u32 = 0;

    for (tokens[opener + 1 .. index - 1]) |token| {
        if (token.opens_a_group_or_block()) depth += 1;
        if (token.closes_a_group_or_block()) depth -|= 1;
        if (depth > 0) continue;

        if (token.is_punctuation(.comma)) commas += 1;
    }

    assert(commas > 0);

    return commas >= compared;
}

fn compares_two_values(macro: []const u8) bool {
    assert(macro.len > 0);

    for (two_value_markers) |marker| {
        if (std.mem.endsWith(u8, macro, marker)) return true;
    }

    return false;
}

fn initializes_a_field(context: *const Context, open: u32, index: u32) bool {
    assert(index < context.tokens.len);

    if (index < open + 3) return false;

    const tokens = context.tokens;
    const before = index - 3;

    assert(before >= open);

    if (tokens[index - 1].kind != .identifier) return false;
    if (!tokens[index - 2].is_punctuation(.dot)) return false;

    if (!tokens[before].is_punctuation(.comma)) {
        if (!opens_a_brace(context, before)) return false;
    }

    return inside_an_anonymous_literal(context, open, before);
}

fn opens_a_brace(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);

    const token = context.tokens[index];
    if (token.kind == .block_start) return true;

    const brace = std.mem.eql(u8, context.text(token), "{");

    if (brace) assert(token.length == 1);

    return brace;
}

fn inside_an_anonymous_literal(context: *const Context, open: u32, from: u32) bool {
    assert(open > 0);
    assert(open <= from);

    var depth: u32 = 0;
    var cursor = from + 1;

    for (0..from + 1 - open) |_| {
        cursor -= 1;

        const token = context.tokens[cursor];

        if (token.closes_a_group_or_block()) {
            depth += 1;

            continue;
        }

        if (!token.opens_a_group_or_block()) continue;

        if (depth > 0) {
            depth -= 1;

            continue;
        }

        const before = context.tokens[cursor - 1];

        if (!opens_a_brace(context, cursor)) return false;
        if (cursor <= open) return false;
        if (before.is_punctuation(.dot)) return true;
        return before.kind == .identifier;
    }

    return false;
}

fn mutates(context: *const Context, modules: *Modules, index: u32) ?[]const u8 {
    const tokens = context.tokens;

    assert(index < tokens.len);

    if (tokens[index].kind != .identifier) return null;
    if (index + 1 >= tokens.len) return null;
    if (!tokens[index + 1].is_punctuation(.paren_open)) return null;

    const name = context.text(tokens[index]);
    if (!support.is_mutating_name(context, name)) return null;
    if (calls_a_function_of_the_file(context, index, name)) return null;
    if (calls_a_module_function(context, modules, index)) return null;
    if (reads_through_a_shared_receiver(context, name)) return null;

    assert(name.len > 0);

    return name;
}

fn calls_a_function_of_the_file(context: *const Context, index: u32, name: []const u8) bool {
    assert(index < context.tokens.len);
    assert(name.len > 0);

    const functions = context.conventions.mutation_functions;
    if (functions.len == 0) return false;
    if (scan.word_listed(functions, name)) return false;
    if (index == 0) return true;
    return !context.tokens[index - 1].is_punctuation(.dot);
}

fn calls_a_module_function(context: *const Context, modules: *Modules, index: u32) bool {
    assert(index < context.tokens.len);

    if (context.conventions.mutation_functions.len == 0) return false;
    if (index < 2) return false;

    const receiver = context.tokens[index - 2];

    if (!context.tokens[index - 1].is_punctuation(.dot)) return false;
    if (receiver.kind != .identifier) return false;

    if (index > 2) {
        if (context.tokens[index - 3].is_punctuation(.dot)) return false;
    }

    return modules.includes(context, context.text(receiver));
}

fn binds_a_module(context: *const Context, index: u32) bool {
    const tokens = context.tokens;

    assert(index < tokens.len);

    if (index == 0) return false;

    const before = tokens[index - 1];
    const word = context.text(before);
    const line = stream.line_start_of_token(tokens, context.source, index);

    assert(line <= index);

    if (!std.mem.eql(u8, context.text(tokens[line]), import_word)) return false;
    if (std.mem.eql(u8, word, as_word)) return true;
    if (std.mem.eql(u8, word, import_word)) return true;
    return before.is_punctuation(.comma);
}

fn reads_through_a_shared_receiver(context: *const Context, name: []const u8) bool {
    assert(name.len > 0);

    if (context.front.language != .rust) return false;
    if (context.tables.function_of(name) == null) return false;

    var found = false;

    for (context.front.nodes_of(.function)) |position| {
        const function = context.view(position).as_function() orelse continue;
        const named = function.name_token() orelse continue;
        if (!std.mem.eql(u8, context.front_text(named), name)) continue;

        const receiver = function.receiver() orelse return false;
        const spelled = scan.trim_ascii(context.span_text(receiver.span()));
        if (!std.mem.eql(u8, spelled, shared_receiver)) return false;

        found = true;
    }

    return found;
}

test "a zig expectation called through a file alias is an assertion" {
    const source = "const expect = std.testing.expect;\n\nfn f(list: *List) !void {\n" ++
        "    try expect(list.pop() != null);\n}\n";

    const unaliased = "fn f(list: *List) !void {\n    try expect(list.pop() != null);\n}\n";

    try expect_mention(.zig, source, "pop");
    try testing.expect_quiet(@This(), .zig, unaliased);
}

fn expect_count(language: Language, source: []const u8, count: u32) !void {
    assert(source.len > 0);
    assert(count <= testing.limits.diagnostic_count_max);

    var findings = try testing.analyze(@This(), language, source);
    defer findings.deinit();

    if (findings.count() != count) findings.print();

    try std.testing.expectEqual(count, findings.count());
}

fn expect_mention(language: Language, source: []const u8, part: []const u8) !void {
    assert(source.len > 0);
    assert(part.len > 0);

    var findings = try testing.analyze(@This(), language, source);
    defer findings.deinit();

    if (findings.count() != 1) findings.print();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
    try std.testing.expect(std.mem.find(u8, findings.message(0), part) != null);
}

test "an assignment inside an assertion is reported" {
    try expect_count(.rust, "fn f() {\n    debug_assert!(count = 1);\n}\n", 1);
}

test "a named option after the compared values is no assignment" {
    const source = "fn f() {\n    assert_relative_eq!(a, b, epsilon = 1e-6);\n" ++
        "    assert_abs_diff_eq!(a.x, b.x, epsilon = 0.01, max_relative = 0.1);\n" ++
        "    assert!(ready, \"{name}\", name = label);\n}\n";

    const compared = "fn f() {\n    assert_eq!(a, b = 1);\n" ++
        "    debug_assert!(count = 1, \"x\");\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
    try expect_count(.rust, compared, 2);
}

test "a mutating call inside an assertion is reported" {
    try expect_mention(.rust, "fn f() {\n    debug_assert!(queue.push(1));\n}\n", "push");
}

test "a reading assertion is quiet" {
    try testing.expect_quiet(@This(), .rust, "fn f() {\n    debug_assert!(queue.len() > 0);\n}\n");
}

test "an assertion that survives a release is reported too" {
    try expect_mention(.rust, "fn f() {\n    assert!(queue.push(1));\n}\n", "release builds");

    const zig = "test \"f\" {\n    try std.testing.expect(list.pop() > 0);\n}\n";

    try expect_count(.zig, zig, 1);
}

test "a python statement assertion is reached" {
    try expect_count(.python, "def f(items):\n    assert items.append(1)\n", 1);
}

test "a zig field initializer is not an assignment" {
    const source = "fn f() void {\n    assert(std.meta.eql(x, .{ .value = 1, .other = 2 " ++
        "}));\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "a typed zig literal initializes its fields" {
    const source = "fn f() void {\n    try testing.expectEqual(Value{ .key = 2, .value = 2 " ++
        "}, held);\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "a dotted assignment target is a mutation" {
    const javascript = "function f(values) {\n    assert(values.length = 0);\n}\n";

    try expect_count(.javascript, javascript, 1);
    try expect_count(.go, "func f(s *S) {\n\tassert(s.count += 1)\n}\n", 1);

    const rust = "fn f(s: &mut S) {\n    debug_assert!({ s.count = 1; true });\n}\n";

    try expect_count(.rust, rust, 1);
}

test "a callback a synchronous iterator runs is read" {
    const source = "function f(values) {\n    assert(values.filter((v) => v.count++ > " ++
        "0).length);\n}\n";

    try expect_count(.javascript, source, 1);

    const deferred = "function f(values) {\n    assert(later((v) => v.count++ > 0));\n}\n";

    try testing.expect_quiet(@This(), .javascript, deferred);
}

test "a channel receive inside an assertion is reported" {
    try expect_count(.go, "func f(done chan int) {\n\tassert(<-done > 0)\n}\n", 1);
}

test "an await inside an assertion is reported" {
    try expect_count(.javascript, "async function f(task) {\n    assert(await task);\n}\n", 1);
}

test "a zig enum literal named await inside an assertion is quiet" {
    const source = "fn f(kind: Kind) void {\n    assert(kind != .await);\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "the added mutation names are reached" {
    try expect_count(.python, "def f(items):\n    assert next(items)\n", 1);

    const rust = "fn f(held: &Mutex<u32>) {\n    debug_assert!(held.lock().is_ok());\n}\n";

    try expect_count(.rust, rust, 1);
    try expect_count(.go, "func f(m map[int]int) {\n\tassert(delete(m, 1))\n}\n", 1);
}

test "a compound assignment inside an assertion is reported" {
    try expect_count(.rust, "fn f() {\n    debug_assert!(count += 1);\n}\n", 1);
}

test "an increment inside an assertion is reported" {
    try expect_count(.go, "func f() {\n\tassert(count++)\n}\n", 1);
}

test "a zig concatenation inside an assertion is not an increment" {
    const source = "test \"t\" {\n    try std.testing.expectEqual(3, f(word ++ \" = 1\"));\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "a decrement inside an assertion is reported" {
    try expect_count(.go, "func f() {\n\tassert(count--)\n}\n", 1);
}

test "a comparison inside an assertion is not an assignment" {
    const sources = [_][]const u8{
        "fn f() {\n    debug_assert!(count >= 1);\n}\n",
        "fn f() {\n    debug_assert!(count <= 1);\n}\n",
        "fn f() {\n    debug_assert!(count == 1);\n}\n",
        "fn f() {\n    debug_assert!(count != 1);\n}\n",
    };

    for (sources) |source| {
        try testing.expect_quiet(@This(), .rust, source);
    }
}

test "a named argument is not an assignment" {
    const sources = [_][]const u8{
        "def f(items):\n    assert helper(count = 1)\n",
        "def f(items):\n    assert helper(items, count = 1)\n",
    };

    for (sources) |source| {
        try testing.expect_quiet(@This(), .python, source);
    }
}

test "an odin named argument is not an assignment" {
    const named = "package p\n\nf :: proc(items: []int, loc := #caller_location) {\n" ++
        "\tassert(len(items) > 0, loc=loc)\n\tassert(condition=len(items) > 0)\n}\n";

    const mutating = "package p\n\nf :: proc(items: ^[dynamic]int) {\n" ++
        "\tassert(pop(items) > 0)\n}\n";

    try testing.expect_quiet(@This(), .odin, named);
    try expect_count(.odin, mutating, 1);
}

test "a dotted target in a python call is a mutation" {
    try expect_count(.python, "def f(items):\n    assert helper(items.count = 1)\n", 1);
}

test "a one byte operator is not an assignment" {
    const source = "fn helper() {\n    let a = 1;\n    debug_assert!(a + 1 > 0);\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
}

test "a switch prong arrow is not an assignment" {
    const source = "fn helper(kind: Kind) void {\n    std.debug." ++ "assert(switch (kind) {\n" ++
        "        .a => true,\n        else => false,\n    });\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "a bracketed binding is not a named argument" {
    try expect_mention(.python, "def helper():\n    assert [item := 1]\n", "changes state");
    try testing.expect_quiet(@This(), .python, "def helper():\n    assert work(count = 1)\n");
}

test "a lambda default is not a named argument" {
    const source = "def helper():\n    assert (lambda x = 1: x)(2)\n";

    try expect_mention(.python, source, "changes state");
}

test "a mutating call is reported with its own arguments" {
    const source = "fn helper() {\n    debug_assert!(clear());\n}\n";

    var findings = try testing.analyze(@This(), .rust, source);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());

    const span = findings.span(0);

    try std.testing.expectEqualStrings("clear()", source[span.offset..span.end()]);
}

test "a python function named like a mutating method is no mutation" {
    const source = "from django.urls import reverse\n\n\ndef f(self, items, values):\n" ++
        "    self.assertEqual(reverse(\"login\"), \"/login/\")\n    assert next(items)\n" ++
        "    assert values.reverse()\n";

    try expect_count(.python, source, 2);
}

test "a python function declared with an assertion's name is no assertion" {
    const source = "def assert_equal(a: object, b: object, fmt: str = \"{} != {}\") -> None:\n" ++
        "    pass\n\n\ndef f(items):\n    assert_equal(items.pop(), 1)\n";

    try expect_count(.python, source, 1);
}

test "a python call through an imported module is no mutating method" {
    const source = "import numpy as np\nimport flask, heapq\n\n\ndef f(arr, values):\n" ++
        "    assert_equal(np.sort(arr), np.add(arr, 1))\n    assert heapq.pop(values)\n" ++
        "    assert flask.g.pop(\"bar\")\n    assert values.sort()\n";

    try expect_count(.python, source, 2);
}

test "a python keyword argument named match is no assignment" {
    const source = "def f(tm, msg):\n    with tm.assert_produces_warning(\n        Warning,\n" ++
        "        match=msg,\n    ):\n        pass\n";

    try testing.expect_quiet(@This(), .python, source);
}

test "a walrus inside a call is not a named argument" {
    try expect_count(.python, "def f(h):\n    assert helper(count := len(h))\n", 1);
}

test "an operator closed by an equals sign reads as an assignment" {
    try expect_count(.javascript, "function f(a, b) {\n    assert(a ||= b);\n}\n", 1);
}

test "an inclusive range is not an assignment" {
    try testing.expect_quiet(@This(), .rust, "fn f() {\n    assert!((1..=5).contains(&0));\n}\n");
}

test "a named argument of a macro inside an assertion is not an assignment" {
    const sources = [_][]const u8{
        "fn f(x: u32) {\n    assert_eq!(format!(\"{x}\", x = x), \"1\");\n}\n",
        "fn f(cmd: Cmd) {\n    assert!(complete!(cmd, \"a\", current_dir = None).is_empty());\n}\n",
        "fn f() {\n    assert!(check![limit = 4]);\n}\n",
    };

    for (sources) |source| {
        try testing.expect_quiet(@This(), .rust, source);
    }
}

test "a binding the assertion's own block declares changes nothing outside it" {
    const rust = "fn f(cap: Captures) {\n    assert_eq!((0, 3), {\n        let m = " ++
        "cap.get(0).unwrap();\n        (m.start(), m.end())\n    });\n}\n";

    const typed = "fn f() {\n    assert_eq!(parse(), {\n        let (set, union): (S, U) = " ++
        "(S {}, U {});\n        Ok((set, union))\n    });\n}\n";

    const zig = "fn f() void {\n    assert(blk: {\n        const held = g();\n        " ++
        "break :blk held > 0;\n    });\n}\n";

    try testing.expect_quiet(@This(), .rust, rust);
    try testing.expect_quiet(@This(), .rust, typed);
    try testing.expect_quiet(@This(), .zig, zig);
}

test "an assertion that opens on an assignment is reported" {
    try expect_count(.python, "def f():\n    assert = 1\n", 1);
    try expect_count(.python, "def f():\n    assert += 1\n", 1);
}

test "a group opened before an assertion ends the declaration scan" {
    try expect_count(.python, "(assert x) = 1\n", 1);
}

test "a binding that mutates or a reassignment inside an assertion is reported" {
    const popped = "fn f(queue: &mut Q) {\n    debug_assert!({\n        let held = " ++
        "queue.pop();\n        held.is_some()\n    });\n}\n";

    const reassigned = "fn f(total: &mut u32) {\n    debug_assert!({\n        let held = 1;\n" ++
        "        *total = held;\n        true\n    });\n}\n";

    try expect_mention(.rust, popped, "pop");
    try expect_count(.rust, reassigned, 1);
}

test "an assignment beside a macro inside an assertion is reported" {
    const sources = [_][]const u8{
        "fn f() {\n    debug_assert!(count = 1, \"{}\", format!(\"{x}\", x = 2));\n}\n",
        "fn f(s: &mut S) {\n    debug_assert!(check!(s.count = 1));\n}\n",
        "fn f() {\n    debug_assert!(check!({ count = 1; true }));\n}\n",
        "fn f() {\n    debug_assert!(!(count = 1));\n}\n",
    };

    for (sources) |source| {
        try expect_count(.rust, source, 1);
    }
}

test "a file-local method that takes a shared receiver reads state" {
    const shared = "impl Strategy {\n    fn next(&self) -> usize {\n        self.size\n" ++
        "    }\n}\n\nfn f(strategy: &Strategy) {\n    assert_eq!(strategy.next(), 8192);\n}\n";

    const exclusive = "impl Strategy {\n    fn next(&mut self) -> usize {\n        self.size\n" ++
        "    }\n}\n\nfn f(strategy: &mut Strategy) {\n    assert_eq!(strategy.next(), 8192);\n}\n";

    const foreign = "fn f(lines: &mut Lines) {\n    assert!(lines.next().is_some());\n}\n";

    try testing.expect_quiet(@This(), .rust, shared);
    try expect_count(.rust, exclusive, 1);
    try expect_count(.rust, foreign, 1);
}
