const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const scan = @import("../../scan.zig");
const stream = @import("../../stream.zig");
const support = @import("../support.zig");
const testing = @import("../testing.zig");
const Category = scylla.View.Category;
const Context = @import("../context.zig");
const Frame = @import("../frame.zig");
const Function = scylla.View.Function;
const Rule = scylla.rule.Rule;
const Sink = scylla.rule.Sink;
const Span = scylla.Span;
const View = scylla.View;

pub const rule: Rule = .{
    .citations = &.{
        .{
            .standard = "TigerStyle",
            .text = "\"The assertion density of the code must average a minimum of two " ++
                "assertions per function.\"",
        },
        .{
            .standard = "NASA",
            .text = "NASA P10 Rule 5: \"The assertion density of the code should average to a " ++
                "minimum of two assertions per function. [...] Any assertion for which a static " ++
                "checking tool can prove that it can never fail or never hold violates this " ++
                "rule. (I.e., it is not possible to satisfy the rule by adding unhelpful " ++
                "\"assert(true)\" statements.)\"",
        },
    },
    .code = "TS004",
    .default_on = false,
    .description = "A function carries at least two assertions on average, covering its " ++
        "preconditions and its postconditions.",
    .explanation = "",
    .fix_title = "",
    .fixable = .sometimes,
    .group = .stable,
    .name = "assert-density",
    .severity = .information,
    .summary = "A function needs at least `assertions_per_function_min` assertions",
    .url = "",
};

const AliasCalls = struct {
    count: u32,
    indices: [alias_calls_max]u32,
    overflowed: bool,

    fn collect(aliases: *AliasCalls, context: *const Context) void {
        assert(context.token_index.identifiers().len <= context.tokens.len);

        aliases.count = 0;
        aliases.overflowed = false;

        if (!context.declares_an_expectation_name()) return;

        for (context.token_index.identifiers()) |index| {
            if (!context.calls_an_expectation_alias(index)) continue;

            if (aliases.count == alias_calls_max) {
                aliases.overflowed = true;

                return;
            }

            aliases.indices[aliases.count] = index;
            aliases.count += 1;
        }

        assert(aliases.count <= alias_calls_max);
    }

    fn within(aliases: *const AliasCalls, context: *const Context, first: u32, last: u32) u32 {
        assert(first <= last);
        assert(last <= context.tokens.len);

        if (aliases.overflowed) return scanned_within(context, first, last);

        const indices = aliases.indices[0..aliases.count];
        const start = std.sort.lowerBound(u32, indices, first, order_of_index);
        const end = std.sort.lowerBound(u32, indices, last, order_of_index);

        assert(start <= end);

        return @intCast(end - start);
    }
};

const alias_calls_max: u32 = 4_096;
const guard_depth_max: u32 = 4;
const panic_names = [_][]const u8{ "@panic", "panic" };

const statement_categories = [_]Category{
    .assignment,
    .branch,
    .call,
    .declaration,
    .except,
    .expression,
    .function,
    .loop,
    .match,
    .@"return",
    .@"struct",
    .@"try",
};

const terminated_categories = [_]Category{ .assignment, .call, .expression };

pub fn run(context: *const Context, sink: *Sink) void {
    var aliases: AliasCalls = undefined;
    var assertions: u32 = 0;
    var functions: u32 = 0;
    var views = context.views(.function);

    aliases.collect(context);

    for (0..views.remaining) |_| {
        const function = views.next() orelse break;
        const held = function.as_function() orelse continue;

        if (support.formats_for_a_trait(context, function)) continue;

        if (function.ancestor_of(.function) == null) {
            assertions +|= assertions_in(context, &aliases, function);
        }

        if (statements_of(context, held) > 0) functions += 1;
    }

    if (functions == 0) return;

    const wanted = context.settings.thresholds.assertions_per_function_min;
    const required = functions *| wanted;

    assert(required >= functions);

    if (assertions >= required) return;

    assert(assertions < required);

    sink.report_formatted(
        Span.empty,
        "the file carries {d} assertions across {d} functions, under the {d} the style asks for",
        .{ assertions, functions, required },
    );
}

fn scanned_within(context: *const Context, first: u32, last: u32) u32 {
    var count: u32 = 0;

    assert(first <= last);

    for (context.tokens[first..last], first..) |token, index| {
        if (token.kind != .identifier) continue;

        if (context.calls_an_expectation_alias(@intCast(index))) count += 1;
    }

    assert(count <= last - first);

    return count;
}

fn order_of_index(index: u32, held: u32) std.math.Order {
    return std.math.order(index, held);
}

fn assertions_in(context: *const Context, aliases: *const AliasCalls, function: View) u32 {
    const span = function.span();
    const first = context.lexer_index_from(span.offset);
    const last = @min(context.lexer_index_from(span.end()), context.tokens.len);
    var count: u32 = aliases.within(context, first, last);

    assert(first <= last);

    for (context.tokens[first..last], first..) |token, index| {
        if (!token.is_keyword(.assert)) continue;
        if (defines_a_function(context, @intCast(index))) continue;
        if (support.assertion_is_trivial(context, @intCast(index))) continue;

        count += 1;
    }

    assert(count <= last - first);

    return count +| guarded_panics_in(context, function);
}

fn defines_a_function(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);

    const previous = stream.significant_previous(context.tokens, index) orelse return false;

    assert(previous < index);

    return context.tokens[previous].is_keyword(.function);
}

fn guarded_panics_in(context: *const Context, function: View) u32 {
    var calls = support.calls_within(context, function.span());
    var count: u32 = 0;

    assert(function.span().end() <= context.source.len);

    for (0..calls.remaining) |_| {
        const call = calls.next() orelse break;
        if (!scan.word_in(&panic_names, callee_text(context, call))) continue;
        if (!named_a_panic(context, call)) continue;

        if (guarded_without_an_else(call)) count += 1;
    }

    assert(count <= calls.positions.len);

    return count;
}

fn named_a_panic(context: *const Context, call: View) bool {
    assert(call.category() == .call);

    const held = call.as_call() orelse return true;
    const named = held.name_token() orelse return true;

    return scan.word_in(&panic_names, context.front_text(named));
}

fn callee_text(context: *const Context, call: View) []const u8 {
    assert(call.category() == .call);

    const held = call.as_call() orelse return leading_text(context, call);
    const callee = held.callee() orelse return leading_text(context, call);

    assert(callee.index() > call.index());

    return callee.text(context.source);
}

fn leading_text(context: *const Context, call: View) []const u8 {
    const body = context.tokens_in(call.span());
    if (body.len == 0) return "";

    assert(body[0].offset >= call.span().offset);
    assert(body[0].end() <= context.source.len);

    return context.text(body[0]);
}

fn guarded_without_an_else(call: View) bool {
    var current = call.parent();

    for (0..guard_depth_max) |_| {
        const held = current orelse return false;

        assert(held.index() < call.index());

        if (held.category() == .branch) {
            const blocks = held.children_of(.block).count();

            assert(blocks <= held.children().remaining);

            if (blocks != 1) return false;
            return !held.holds(.branch);
        }

        const passes = held.category() == .block or held.category() == .expression;
        if (!passes) return false;

        current = held.parent();
    }

    return false;
}

fn statements_of(context: *const Context, function: Function) u32 {
    const body = function.body() orelse return 0;
    const macros = macros_of(context, function.view);
    var children = body.children();
    var count: u32 = 0;

    for (0..children.remaining) |_| {
        const child = children.next() orelse break;

        if (is_statement(context, child)) count += 1;
    }

    assert(count <= context.tokens.len);
    assert(macros <= context.tokens.len);

    return count +| macros;
}

fn is_statement(context: *const Context, node: View) bool {
    const category = node.category();

    assert(node.token_start() <= node.token_end());

    if (category == .block) return opens_a_context(context, node);
    if (std.mem.findScalar(Category, &statement_categories, category) == null) return false;

    const terminated = std.mem.findScalar(Category, &terminated_categories, category) != null;
    if (!terminated) return true;
    if (!context.grammar.statements_end_with_semicolon) return true;

    if (position_last(node)) |position| {
        if (context.front_token(position).is_punctuation(.semicolon)) return true;
    }

    const end = node.token_end();

    assert(end <= context.front.tokens().len);

    if (end >= context.front.tokens().len) return false;
    return context.front_token(end).is_punctuation(.semicolon);
}

fn opens_a_context(context: *const Context, node: View) bool {
    assert(node.category() == .block);

    const words = context.conventions.context_words;
    if (words.len == 0) return false;

    const header = Frame.header_of(context, node);
    if (header >= context.tokens.len) return false;
    return scan.word_listed(words, context.text(context.tokens[header]));
}

fn position_last(node: View) ?u32 {
    var positions = node.positions();
    var last: ?u32 = null;

    for (0..positions.remaining) |_| {
        last = positions.next() orelse break;
    }

    if (last) |position| assert(position < node.token_end());
    assert(positions.remaining == 0);

    return last;
}

fn macros_of(context: *const Context, node: View) u32 {
    if (!context.conventions.macros_invoke_with_bang) return 0;

    const body = context.tokens_in(node.span());
    var count: u32 = 0;

    assert(body.len <= context.tokens.len);

    for (body, 0..) |token, index| {
        if (index == 0) continue;
        if (!token.is_punctuation(.bang)) continue;

        const before = body[index - 1];
        const invokes = before.kind == .identifier or before.is_keyword(.assert);

        if (invokes) count += 1;
    }

    if (body.len > 0) assert(count < body.len);

    return count;
}

fn expect_one(language: scylla.Language, source: []const u8, wanted: ?[]const u8) !void {
    var findings = try testing.analyze(@This(), language, source);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());

    if (wanted) |text| {
        try std.testing.expect(std.mem.find(u8, findings.message(0), text) != null);
    }
}

fn repeated(gpa: std.mem.Allocator, opening: []const u8) ![]u8 {
    var source: std.ArrayList(u8) = .empty;
    errdefer source.deinit(gpa);

    try source.appendSlice(gpa, opening);

    for (0..12) |_| try source.appendSlice(gpa, "    let value = 1;\n");

    try source.appendSlice(gpa, "}\n");

    return source.toOwnedSlice(gpa);
}

test "a zig expectation called through a file alias counts" {
    const source = "const expect = std.testing.expect;\n\nfn read(x: u8) !void {\n" ++
        "    try expect(x > 0);\n    try expect(x < 9);\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "a formatting method of a trait owes no assertion" {
    const implemented = "impl fmt::Display for Error {\n    fn fmt(&self, formatter: &mut " ++
        "fmt::Formatter<'_>) -> fmt::Result {\n        let text = " ++
        "\"error\";\n\n        formatter.write_str(text)\n    }\n}\n";

    const free = "fn fmt(value: u32) -> u32 {\n    let doubled = value * 2;\n\n    " ++
        "doubled\n}\n";

    try testing.expect_quiet(@This(), .rust, implemented);
    try expect_one(.rust, free, null);
}

test "a run of macro bangs does not outcount the tree" {
    try expect_one(.rust, "fn f() {\n    a!b!c!d!e!f!g!h!i!j!k!l!m!\n}\n", null);
}

test "a long function without assertions is reported" {
    const gpa = std.testing.allocator;
    const source = try repeated(gpa, "fn wide() {\n");
    defer gpa.free(source);

    try expect_one(.rust, source, "0 assertions");
}

test "a function with two assertions is quiet" {
    const gpa = std.testing.allocator;
    const source = try repeated(gpa, "fn wide() {\n    assert!(a);\n    assert!(b);\n");
    defer gpa.free(source);

    try testing.expect_quiet(@This(), .rust, source);
}

test "the density counts the whole file once" {
    const source = "fn first() {\n    let a = 1;\n    let b = 2;\n    let c = 3;\n}\n\n" ++
        "fn second() {\n    let d = 1;\n    let e = 2;\n    let f = 3;\n}\n";

    var findings = try testing.analyze(@This(), .rust, source);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
    try std.testing.expect(std.mem.find(u8, findings.message(0), "across 2 functions") != null);
    try std.testing.expect(std.mem.find(u8, findings.message(0), "under the 4") != null);
}

test "a function of one statement joins the denominator" {
    try expect_one(.rust, "fn narrow() {\n    work(1);\n}\n", "across 1 functions");
}

test "a function with an empty body stays out of the denominator" {
    try testing.expect_quiet(@This(), .rust, "fn narrow() {\n}\n");
}

test "every function joins the denominator" {
    const source = "def narrow(value):\n    assert value > 0\n    assert value < 9\n\n" ++
        "def wide():\n    a = 1\n    b = 2\n    c = 3\n";

    try expect_one(.python, source, "across 2 functions");
}

test "a trivially true assertion does not count" {
    const source = "fn narrow() {\n    assert!(true);\n    assert!(a == a);\n    work(1);\n}\n";

    try expect_one(.rust, source, "0 assertions");
}

test "a comparison whose first value is a literal counts" {
    const rust = "fn narrow() {\n    assert_eq!(1, padding(11));\n    assert_ne!(true, " ++
        "done());\n    work(1);\n}\n";

    const zig = "fn narrow() !void {\n    try std.testing.expectEqual(1, padding(11));\n    " ++
        "try std.testing.expectEqual(true, done());\n}\n";

    try testing.expect_quiet(@This(), .rust, rust);
    try testing.expect_quiet(@This(), .zig, zig);
}

test "a python definition named like an assertion does not count" {
    try expect_one(.python, "def assert_valid(value):\n    work(value)\n", "0 assertions");
}

test "a go panic under a bare if is an assertion" {
    const source = "package main\n\nfunc scale(value int) int {\n\tif value < 0 {\n\t\t" ++
        "panic(\"negative\")\n\t}\n\tif value > 9 {\n\t\tpanic(\"wide\")\n\t}\n\t" ++
        "return value * 2\n}\n";

    try testing.expect_quiet(@This(), .go, source);
}

test "a go panic under an if with an else is not an assertion" {
    const source = "package main\n\nfunc scale(value int) int {\n\tif value < 0 {\n\t\t" ++
        "panic(\"negative\")\n\t} else {\n\t\treturn 0\n\t}\n\treturn value * 2\n}\n";

    try expect_one(.go, source, "0 assertions");
}

test "a rust panic under a bare if is an assertion" {
    const source = "fn scale(value: i32) -> i32 {\n    if value < 0 {\n" ++
        "        panic!(\"negative\");\n    }\n    if value > 9 {\n" ++
        "        panic!(\"wide\");\n    }\n    value * 2\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
}

test "a method of a value named panic is not a panic" {
    const source = "fn release(handle: Handle) {\n    let panic = catch(handle);\n" ++
        "    if panic.is_err() {\n        work(1);\n    }\n}\n";

    try expect_one(.rust, source, "0 assertions");
}

test "a test function counts like any other" {
    try expect_one(.rust, "fn test_narrow() {\n    work(1);\n}\n", null);
}

test "a rust macro statement counts twice" {
    const source = "fn narrow() {\n    println!(\"one\");\n    let value = 1;\n}\n";

    try expect_one(.rust, source, "across 1 functions");
}

test "an item a body declares is a statement" {
    const source = "fn root() {\n    fn inner() {}\n}\n\nfn other() {\n    struct Local;\n}\n\n" ++
        "fn third() {\n    impl Local {}\n}\n\nfn tail() -> u32 {\n    value\n}\n";

    try expect_one(.rust, source, "across 3 functions");
}

test "a python with is a statement" {
    const source = "def first(self):\n    with lock:\n        self.assertTrue(ready)\n\n\n" ++
        "def second(self):\n    value = 1\n";

    try expect_one(.python, source, "across 2 functions");
}

test "a rust tail expression alone is not a statement" {
    try testing.expect_quiet(@This(), .rust, "fn narrow() -> u32 {\n    value\n}\n");
}
