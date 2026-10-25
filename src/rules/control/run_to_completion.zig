const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const scan = @import("../../scan.zig");
const stream = @import("../../stream.zig");
const support = @import("../support.zig");
const testing = @import("../testing.zig");
const Context = @import("../context.zig");
const Rule = scylla.rule.Rule;
const Sink = scylla.rule.Sink;
const TestScope = @import("../test_scope.zig");
const Token = scylla.Token;
const View = scylla.View;

pub const rule: Rule = .{
    .citations = &.{
        .{
            .standard = "TigerStyle",
            .text = "\"Ensure that functions run to completion without suspending, so that " ++
                "precondition assertions are true throughout the lifetime of the function. " ++
                "These assertions are useful documentation without a suspend, but may be " ++
                "misleading otherwise.\"",
        },
    },
    .code = "TS054",
    .default_on = false,
    .description = "A function that has asserted does not suspend, so what it asserted still " ++
        "holds when the next line runs.",
    .explanation = "",
    .fix_title = "",
    .fixable = .never,
    .group = .stable,
    .name = "run-to-completion",
    .severity = .information,
    .summary = "A function must not suspend after asserting; run to completion",
    .url = "",
};

const block_depth_max: u32 = 64;
const comptime_word = "comptime";
const exit_words = [_][]const u8{ "raise", "throw" };

pub fn run(context: *const Context, sink: *Sink) void {
    const conventions = context.conventions;

    if (conventions.suspension_words.len == 0) {
        if (conventions.suspension_methods.len == 0) return;
    }

    for (context.tokens, 0..) |token, index| {
        if (!support.suspends_at(context, @intCast(index))) continue;

        const function = context.function_at(token.offset) orelse continue;
        if (!asserted_before(context, function, token.offset)) continue;
        if (TestScope.holds(context, token.offset)) continue;

        assert(token.length > 0);
        assert(Token.is_significant(token.kind));

        sink.report(
            token.span(),
            "the function suspends after asserting; what it asserted may not hold when it resumes",
        );
    }
}

fn asserted_before(context: *const Context, function: View, offset: u32) bool {
    const start = function.span().offset;

    assert(offset <= context.source.len);

    if (offset <= start) return false;

    const first = context.lexer_index_from(start);
    const last = context.lexer_index_from(offset);

    assert(first <= last);

    for (context.tokens[first..last], first..) |held, index| {
        if (!held.is_keyword(.assert)) continue;
        if (checked_at_compile_time(context, @intCast(index))) continue;
        if (holds_the_suspension(context, @intCast(index), offset)) continue;
        if (!asserts_in(context, function, held.offset)) continue;
        if (leaves_before(context, function, held.offset, offset)) continue;
        return true;
    }

    return false;
}

fn checked_at_compile_time(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);

    const before = context.significant_before(index) orelse return false;

    assert(before < index);

    return std.mem.eql(u8, context.text(context.tokens[before]), comptime_word);
}

fn holds_the_suspension(context: *const Context, index: u32, offset: u32) bool {
    assert(index < context.tokens.len);
    assert(context.tokens[index].offset < offset);

    var open = index + 1;

    if (open < context.tokens.len) {
        if (context.tokens[open].is_punctuation(.bang)) open += 1;
    }

    if (open >= context.tokens.len) return false;
    if (!context.tokens[open].is_punctuation(.paren_open)) return false;

    const close = context.pairs.partner_of(open) orelse return false;

    assert(close > open);

    return offset < context.tokens[close].offset;
}

fn asserts_in(context: *const Context, function: View, offset: u32) bool {
    assert(function.span().contains(offset));

    const owner = context.function_at(offset) orelse return false;
    return owner.index() == function.index();
}

fn leaves_before(context: *const Context, function: View, assertion: u32, offset: u32) bool {
    assert(assertion < offset);
    assert(function.span().contains(assertion));

    var block = innermost_block(context, function, assertion) orelse return false;

    for (0..block_depth_max) |_| {
        if (block.span().contains(offset)) return false;
        if (block.index() <= function.index()) return false;
        if (ends_in_an_exit(context, block)) return true;

        block = block.ancestor_of(.block) orelse return false;
    }

    return false;
}

fn innermost_block(context: *const Context, function: View, offset: u32) ?View {
    assert(function.span().contains(offset));

    var blocks = context.views(.block);
    var found: ?View = null;

    for (0..blocks.remaining) |_| {
        const block = blocks.next() orelse break;
        const span = block.span();
        if (span.offset > offset) break;
        if (block.index() <= function.index()) continue;
        if (!span.contains(offset)) continue;

        found = block;
    }

    return found;
}

fn ends_in_an_exit(context: *const Context, block: View) bool {
    assert(block.category() == .block);

    var children = block.children();
    var last: ?View = null;

    for (0..children.remaining) |_| {
        last = children.next() orelse break;
    }

    const statement = last orelse return false;
    if (statement.category() == .@"return") return true;

    const first = context.lexer_index_from(statement.span().offset);
    if (first >= context.tokens.len) return false;
    return scan.word_listed(&exit_words, context.text(context.tokens[first]));
}

test "an assertion on a path that returns before the suspension is quiet" {
    const returns = "async def handle(self, scope, context):\n    if context is not None:\n" ++
        "        assert context.app is not None\n        await context.app(scope)\n" ++
        "        return\n    await super().handle(scope)\n";

    const continues = "async def handle(self, scope, context):\n    if context is not None:\n" ++
        "        assert context.app is not None\n        log(scope)\n" ++
        "    await super().handle(scope)\n";

    var findings = try testing.analyze(@This(), .python, returns);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());

    try testing.expect_findings(@This(), .python, continues, &.{
        "the function suspends after asserting; what it asserted may not hold when it resumes",
    });
}

test "a suspension after an assertion is reported" {
    const source = "async function f(a) {\n    assert(a);\n    await g(a);\n}\n";

    try testing.expect_findings(@This(), .javascript, source, &.{
        "the function suspends after asserting; what it asserted may not hold when it resumes",
    });
}

test "an assertion in a closure the suspension runs outside is quiet" {
    const closure = "async fn read(s: &Semaphore) -> u32 {\n" ++
        "    let acquire = async {\n        s.acquire(1).await.unwrap_or_else(|_| {\n" ++
        "            unreachable!()\n        })\n    };\n\n    acquire.await\n}\n";

    const awaited = "async fn write(s: &Semaphore, count: u32) -> u32 {\n" ++
        "    let acquire = async {\n        debug_assert_ne!(count, 0);\n" ++
        "        s.acquire(count).await\n    };\n\n    acquire.await\n}\n";

    try testing.expect_quiet(@This(), .rust, closure);
    try testing.expect_anchors(@This(), .rust, awaited, &.{ .{ 4, 26 }, .{ 7, 13 } });
}

test "an assertion whose arguments hold the suspension runs after it resumes" {
    const enclosing = "async fn run(stream: &mut Stream) {\n" ++
        "    assert_eq!(Some(1), stream.next().await);\n}\n";

    const preceding = "async fn run(stream: &mut Stream) {\n    assert!(stream.ready());\n" ++
        "    assert_eq!(Some(1), stream.next().await);\n}\n";

    try testing.expect_quiet(@This(), .rust, enclosing);
    try testing.expect_anchors(@This(), .rust, preceding, &.{.{ 3, 39 }});
}

test "a comptime assertion is no precondition a suspension can break" {
    const proven = "fn load(group: *Group, io: Io) !void {\n" ++
        "    errdefer comptime unreachable;\n\n    try group.await(io);\n}\n";

    const checked = "fn load(group: *Group, io: Io) !void {\n    assert(group.count > 0);\n\n" ++
        "    try group.await(io);\n}\n";

    try testing.expect_quiet(@This(), .zig, proven);
    try testing.expect_anchors(@This(), .zig, checked, &.{.{ 4, 15 }});
}

test "a rust await written outside its postfix is no suspension" {
    const quiet = "fn parse(p: &mut Parser) {\n    assert!(p.at(DOT));\n\n" ++
        "    if p.nth(1) == T![await] {\n        p.bump(T![await]);\n    }\n}\n";

    const postfix = "async fn wait(s: &Signal) {\n    assert!(s.ready());\n\n" ++
        "    s.changed().await;\n}\n";

    try testing.expect_quiet(@This(), .rust, quiet);
    try testing.expect_anchors(@This(), .rust, postfix, &.{.{ 4, 17 }});
}

test "a suspension before any assertion is quiet" {
    const source = "async function f(a) {\n    await g(a);\n    assert(a);\n}\n";

    try testing.expect_quiet(@This(), .javascript, source);
}

test "a zig enum literal named await is not a suspension" {
    const source = "fn f(kind: Kind) void {\n    assert(kind != .yield);\n\n" ++
        "    switch (kind) {\n        .await => {},\n        else => {},\n    }\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "a zig await call is a suspension" {
    const source = "fn f(group: *Group, io: Io) !void {\n    assert(group.count > 0);\n\n" ++
        "    try group.await(io);\n}\n";

    try testing.expect_findings(@This(), .zig, source, &.{
        "the function suspends after asserting; what it asserted may not hold when it resumes",
    });
}

test "a member named after a suspending keyword is not a suspension" {
    const source = "async function f(a) {\n    assert(a);\n    return a.await;\n}\n";

    try testing.expect_quiet(@This(), .javascript, source);
}
