const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const safety = @import("../safety.zig");
const testing = @import("../testing.zig");
const Context = @import("../context.zig");
const Language = scylla.Language;
const Rule = scylla.rule.Rule;
const Sink = scylla.rule.Sink;
const Span = scylla.Span;
const Token = scylla.Token;

pub const rule: Rule = .{
    .citations = &.{
        .{
            .standard = "TigerStyle",
            .text = "\"All errors must be handled. An analysis of production failures in " ++
                "distributed data-intensive systems found that the majority of catastrophic " ++
                "failures could have been prevented by simple testing of error handling code.\"",
        },
    },
    .code = "TS009",
    .default_on = true,
    .description = "An except clause names the errors it handles, so an unrelated failure is " ++
        "not swallowed with them.",
    .explanation = "",
    .fix_title = "",
    .fixable = .sometimes,
    .group = .stable,
    .name = "no-bare-except",
    .severity = .warning,
    .summary = "A handler must name the exceptions it catches",
    .url = "",
};

const base_exception = "BaseException";

pub fn run(context: *const Context, sink: *Sink) void {
    const tokens = context.tokens;

    assert(tokens.len <= std.math.maxInt(u32));

    for (tokens, 0..) |token, position| {
        const index: u32 = @intCast(position);

        if (!token.is_keyword(.except)) continue;
        if (index + 1 >= tokens.len) continue;

        const next = tokens[index + 1];
        const broad = broadens(context, next);

        assert(next.offset >= token.end());

        if (!broad) {
            if (!bare(context, next)) continue;
        }

        if (!safety.follows_a_statement_break(context, index)) continue;

        if (broad) {
            sink.fix_begin("Narrow `BaseException` to `Exception`", .unsafe, null);
            sink.fix_edit(next.span(), "Exception");
        } else {
            const after: Span = .{ .offset = token.end(), .length = 0 };

            sink.fix_begin("Add `Exception` to bare except", .unsafe, null);
            sink.fix_edit(after, " Exception");
        }

        sink.report_fixed(token.span(), "the handler catches every error");
    }
}

fn bare(context: *const Context, next: Token) bool {
    assert(next.end() <= context.source.len);

    if (next.kind == .block_start) return true;
    if (!context.conventions.handlers_end_with_colon) return false;

    const colon = next.is_punctuation(.colon);

    if (colon) assert(next.kind == .punctuation);

    return colon;
}

fn broadens(context: *const Context, next: Token) bool {
    assert(next.end() <= context.source.len);

    if (next.kind != .identifier) return false;

    const named = std.mem.eql(u8, context.text(next), base_exception);

    if (named) assert(next.length == base_exception.len);

    return named;
}

fn expect_count(language: Language, source: []const u8, expected: u32) !void {
    assert(source.len > 0);
    assert(expected <= testing.limits.diagnostic_count_max);

    var findings = try testing.analyze(@This(), language, source);
    defer findings.deinit();

    if (findings.count() != expected) findings.print();

    try std.testing.expectEqual(expected, findings.count());
}

test "a bare except is reported" {
    try expect_count(.python, "def f():\n    try:\n        work()\n    except:\n        pass\n", 1);
}

test "a named except is quiet" {
    const source = "def f():\n    try:\n        work()\n    except ValueError:\n        raise\n";

    try testing.expect_quiet(@This(), .python, source);
}

test "a catch property key is not a handler" {
    try testing.expect_quiet(@This(), .javascript, "const handlers = {\n    catch: recover,\n};\n");
}

test "a catch property key behind a brace is not a handler" {
    const source = "const handlers = {\n    catch: recover,\n    then: run,\n};\n";

    try testing.expect_quiet(@This(), .typescript, source);
}

test "a javascript handler without a binding is still reported" {
    const source = "function run() {\n    try {\n        work();\n    } catch {\n        " ++
        "recover();\n    }\n}\n";

    try expect_count(.javascript, source, 1);
}

test "a python bare handler is still reported" {
    const source = "def load(path):\n    try:\n        return open(path)\n    " ++
        "except:\n        return None\n";

    try expect_count(.python, source, 1);
}

test "a base exception handler is reported" {
    try expect_count(.python, "try:\n    work()\nexcept BaseException:\n    raise\n", 1);
}

test "a bare except gains an exception type" {
    try testing.expect_fixed(
        @This(),
        .python,
        "try:\n    work()\nexcept:\n    pass\n",
        .unsafe,
        "try:\n    work()\nexcept Exception:\n    pass\n",
    );
}

test "a base exception handler narrows to exception" {
    try testing.expect_fixed(
        @This(),
        .python,
        "try:\n    work()\nexcept BaseException:\n    raise\n",
        .unsafe,
        "try:\n    work()\nexcept Exception:\n    raise\n",
    );
}
