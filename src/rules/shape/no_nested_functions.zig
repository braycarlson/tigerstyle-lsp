const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const shape = @import("../shape.zig");
const stream = @import("../../stream.zig");
const support = @import("../support.zig");
const testing = @import("../testing.zig");
const Category = scylla.View.Category;
const Context = @import("../context.zig");
const Frame = @import("../frame.zig");
const Rule = scylla.rule.Rule;
const Sink = scylla.rule.Sink;
const Span = scylla.Span;
const TestScope = @import("../test_scope.zig");
const View = scylla.View;

pub const rule: Rule = .{
    .citations = &.{
        .{
            .standard = "TigerStyle",
            .text = "\"Use only very simple, explicit control flow for clarity.\"",
        },
        .{
            .standard = "NASA",
            .text = "NASA P10 Rule 1: \"Restrict all code to very simple control flow " ++
                "constructs.\"",
        },
    },
    .code = "TS014",
    .default_on = false,
    .description = "A function is declared at the top level rather than inside another " ++
        "function, so the call graph stays flat.",
    .explanation = "",
    .fix_title = "",
    .fixable = .sometimes,
    .group = .stable,
    .name = "no-nested-functions",
    .severity = .warning,
    .summary = "Functions belong at module scope where they can be tested",
    .url = "",
};

const declaring_parents = [_]Category{
    .assignment,
    .branch,
    .declaration,
    .except,
    .loop,
    .match,
    .@"return",
    .@"struct",
    .@"try",
};

const decorator_line_max: u32 = 8;
const module_wrapper_depth_max: u32 = 3;

pub fn run(context: *const Context, sink: *Sink) void {
    if (TestScope.file_is_a_fixture(context)) return;

    var functions = support.functions_and_bound_lambdas(context);

    for (0..context.front.node_count()) |_| {
        const function = functions.next() orelse break;
        const enclosing = function.enclosing_function() orelse continue;
        const name = support.bound_name_of(function) orelse continue;
        const frame = frame_or_extent_of(context, function) orelse continue;

        assert(enclosing.index() < function.index());
        assert(name < context.front.tokens().len);

        if (exempt(context, function, frame, enclosing)) continue;

        const anchor = if (function.category() == .lambda)
            context.front_token(name).span()
        else
            marker_opening(context, frame);

        sink.report(anchor, "the function is declared inside another function");
    }
}

fn exempt(context: *const Context, function: View, frame: Frame, enclosing: View) bool {
    assert(enclosing.index() < function.index());
    assert(frame.header < context.tokens.len);

    if (!stands_as_a_declaration(context, function)) return true;
    if (introduced_by_a_lambda_keyword(context, function)) return true;
    if (wraps_a_module(enclosing)) return true;
    if (nests_a_type(context, function)) return true;
    if (names_a_container_member(context, function)) return true;
    return closes_over_the_enclosing_function(context, function, frame, enclosing);
}

fn frame_or_extent_of(context: *const Context, function: View) ?Frame {
    if (function.category() != .lambda) return Frame.of(context, function);

    const span = function.span();
    const start = context.lexer_index_from(span.offset);
    const limit = context.lexer_index_from(span.end());
    if (limit == 0) return null;

    const end = limit - 1;
    if (end < start) return null;

    assert(start < context.tokens.len);
    assert(end < context.tokens.len);

    return .{ .end = end, .header = start, .start = start };
}

fn introduced_by_a_lambda_keyword(context: *const Context, function: View) bool {
    const body = context.tokens_in(function.span());

    assert(body.len <= context.tokens.len);

    for (body) |token| {
        if (token.is_keyword(.other)) continue;

        assert(token.offset >= function.span().offset);

        return token.is_keyword(.lambda);
    }

    return false;
}

fn marker_opening(context: *const Context, frame: Frame) Span {
    assert(frame.header < context.tokens.len);

    const first = stream.line_start_of_token(context.tokens, context.source, frame.header);

    assert(first <= frame.header);

    return context.tokens[first].span();
}

fn stands_as_a_declaration(context: *const Context, function: View) bool {
    const parent = function.parent() orelse return false;
    const header = shape.header_of(context, function);
    const keyworded = if (header) |index| context.tokens[index].is_keyword(.function) else false;

    assert(parent.index() < function.index());
    if (header) |index| assert(index < context.tokens.len);

    if (std.mem.findScalar(Category, &declaring_parents, parent.category()) != null) return true;

    if (parent.category() == .block) {
        const above = parent.parent() orelse return true;
        if (above.category() != .@"struct") return true;
        return keyworded;
    }

    if (parent.category() != .expression) return false;
    if (!keyworded) return false;
    return !is_an_argument(function);
}

fn is_an_argument(function: View) bool {
    const parent = function.parent() orelse return false;

    assert(parent.index() < function.index());

    if (parent.category() != .expression) return false;

    const above = parent.parent() orelse return false;

    assert(above.index() < parent.index());

    return above.category() == .call;
}

fn wraps_a_module(enclosing: View) bool {
    const start = enclosing.span().offset;
    var current = enclosing.parent();

    for (0..module_wrapper_depth_max) |_| {
        const held = current orelse return false;

        assert(held.index() < enclosing.index());

        if (held.category() == .call) {
            const callee = held.child_first() orelse return false;
            const span = callee.span();

            assert(callee.index() > held.index());

            if (span.offset <= start) {
                if (start < span.end()) return true;
            }

            return is_a_function(callee);
        }

        if (held.category() != .expression) return false;

        current = held.parent();
    }

    return false;
}

fn is_a_function(callee: View) bool {
    var current: ?View = callee;

    for (0..module_wrapper_depth_max) |_| {
        const held = current orelse return false;

        assert(held.index() >= callee.index());

        switch (held.category()) {
            .function, .lambda => return true,
            .expression => {},
            else => return false,
        }

        assert(held.category() == .expression);

        current = held.child_first();
    }

    return false;
}

fn names_a_container_member(context: *const Context, function: View) bool {
    assert(function.span().end() <= context.source.len);

    if (!context.conventions.types_are_values) return false;

    const parent = function.parent() orelse return false;

    assert(parent.index() < function.index());

    return parent.category() == .@"struct";
}

fn nests_a_type(context: *const Context, function: View) bool {
    var ancestors = function.ancestors();

    for (0..ancestors.remaining + 1) |_| {
        const held = ancestors.next() orelse return false;

        assert(held.index() < function.index());

        if (held.category() == .function) {
            if (Frame.of(context, held)) |frame| {
                assert(frame.header < context.tokens.len);

                if (support.is_type_level(context, frame)) return true;
            }
        }
    }

    return false;
}

fn closes_over_the_enclosing_function(
    context: *const Context,
    function: View,
    frame: Frame,
    enclosing: View,
) bool {
    if (!context.conventions.nested_functions_can_be_closures) return false;
    if (a_decorator_introduces(context, frame)) return true;

    const outer = Frame.of(context, enclosing) orelse return false;

    assert(outer.header < context.tokens.len);
    assert(enclosing.index() < function.index());

    return the_enclosing_function_returns(context, function, frame, outer);
}

fn a_decorator_introduces(context: *const Context, frame: Frame) bool {
    const prefix = context.grammar.decorator_prefix;
    if (prefix.len == 0) return false;

    assert(frame.header < context.tokens.len);

    var first = stream.line_start_of_token(context.tokens, context.source, frame.header);

    for (0..decorator_line_max) |_| {
        if (first == 0) return false;

        const previous = stream.significant_previous_in_line(context.tokens, first) orelse
            return false;

        assert(previous < first);

        const opened = group_opening(context, previous);

        first = stream.line_start_of_token(context.tokens, context.source, opened);

        if (context.tokens[first].kind == .comment) continue;

        const text = stream.text_of_range(context.source, context.tokens, first, first);
        return std.mem.startsWith(u8, text, prefix);
    }

    return false;
}

fn the_enclosing_function_returns(
    context: *const Context,
    function: View,
    frame: Frame,
    outer: Frame,
) bool {
    const named = support.bound_name_of(function) orelse return false;
    const name = context.front_text(named);
    const length: u32 = @intCast(context.tokens.len);
    const start = outer.start;
    const end = @min(outer.end orelse length, length);

    assert(start <= end);

    var index = start;

    for (0..end - start) |_| {
        if (index >= end) break;

        if (frame.covers(index)) {
            index = frame.end orelse break;

            continue;
        }

        if (!context.tokens[index].is_keyword(.@"return")) {
            index += 1;

            continue;
        }

        const last = @min(stream.statement_end(context.tokens, index), end - 1);

        assert(last >= index);

        if (names_the_value(context, index, last, name)) return true;

        index = last + 1;
    }

    return false;
}

fn names_the_value(context: *const Context, first: u32, last: u32, name: []const u8) bool {
    assert(first <= last);
    assert(last < context.tokens.len);

    for (context.tokens[first .. last + 1], first..) |token, index| {
        if (token.kind != .identifier) continue;

        const after = index + 1;

        if (after < context.tokens.len) {
            if (context.tokens[after].is_punctuation(.paren_open)) continue;
        }

        if (std.mem.eql(u8, context.text(token), name)) return true;
    }

    return false;
}

test "a container member is not a nested function" {
    const source = "fn outer() void {\n    const helper = struct {\n        fn make(value: " ++
        "u32) u32 {\n            return value + 1;\n        }\n    };\n\n    _ = " ++
        "helper;\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "a python nested class method is still nested" {
    const source = "def outer():\n    class Held:\n        def make(self):\n            " ++
        "return 1\n\n    return Held\n";

    var findings = try testing.analyze(@This(), .python, source);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
}

test "a nested function is reported" {
    const source = "def outer():\n    def inner():\n        return 1\n    return inner(1)\n";

    var findings = try testing.analyze(@This(), .python, source);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
}

test "a returned nested function is quiet" {
    const source = "def outer():\n    def inner():\n        return 1\n    return wrap(inner)\n";

    try testing.expect_quiet(@This(), .python, source);
}

fn group_opening(context: *const Context, index: u32) u32 {
    assert(index < context.tokens.len);

    if (!context.tokens[index].closes_a_group()) return index;

    const partner = context.pairs.partner_of(index) orelse return index;

    assert(partner < index);

    return partner;
}

test "a decorated nested function is quiet" {
    const source = "def outer():\n    @route\n    def inner():\n        return 1\n    call(1)\n";

    try testing.expect_quiet(@This(), .python, source);
}

test "a nested function under a decorator spanning lines is quiet" {
    const decorated = "def outer(router):\n    @router.post(\n        \"/callback\",\n" ++
        "        name=\"callback\",\n    )\n    def inner(item):\n        return item\n" ++
        "    call(1)\n";

    const called = "def outer(router):\n    register(\n        \"/callback\",\n    )\n" ++
        "    def inner(item):\n        return item\n    call(1)\n";

    try testing.expect_quiet(@This(), .python, decorated);

    var findings = try testing.analyze(@This(), .python, called);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
}

test "a returned nested function is reported where closures are not a convention" {
    const source = "fn outer() {\n    fn inner() {\n    }\n    return inner;\n}\n";

    var findings = try testing.analyze(@This(), .rust, source);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
}

test "an arrow function bound inside a function is nested" {
    const source = "function outer() {\n    const inner = () => 2;\n\n    return inner();\n}\n";

    var findings = try testing.analyze(@This(), .javascript, source);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
}

test "a returned arrow function is a closure" {
    const source = "function outer() {\n    const inner = () => 2;\n\n    return inner;\n}\n";

    try testing.expect_quiet(@This(), .javascript, source);
}

test "a function expression bound inside a function is left to the lambda rule" {
    const source = "function outer() {\n    const inner = function () {};\n\n    return " ++
        "inner();\n}\n";

    try testing.expect_quiet(@This(), .javascript, source);
}
