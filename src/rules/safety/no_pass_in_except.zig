const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const scan = @import("../../scan.zig");
const stream = @import("../../stream.zig");
const testing = @import("../testing.zig");
const Context = @import("../context.zig");
const Frame = @import("../frame.zig");
const Language = scylla.Language;
const Rule = scylla.rule.Rule;
const Sink = scylla.rule.Sink;
const Token = scylla.Token;

pub const rule: Rule = .{
    .citations = &.{
        .{
            .standard = "TigerStyle",
            .text = "\"All errors must be handled. [...] Specifically, we found that almost all " ++
                "(92%) of the catastrophic system failures are the result of incorrect handling " ++
                "of non-fatal errors explicitly signaled in software.\"",
        },
    },
    .code = "TS010",
    .default_on = true,
    .description = "A handler that does nothing hides the failure it caught.",
    .explanation = "",
    .fix_title = "",
    .fixable = .sometimes,
    .group = .stable,
    .name = "no-pass-in-except",
    .severity = .@"error",
    .summary = "A handler must not silently swallow the error",
    .url = "",
};

const broad_names = [_][]const u8{ "BaseException", "Exception" };
const ellipsis = "...";
const ellipsis_dot_count: u32 = ellipsis.len;
const none_word = "None";
const return_word = "return";
const suppress_name = "suppress";
const swallowing_words = [_][]const u8{ "continue", "pass", "return" };
const with_word = "with";

pub fn run(context: *const Context, sink: *Sink) void {
    var handlers = context.views(.except);

    for (0..handlers.remaining) |_| {
        const handler = handlers.next() orelse break;

        assert(handler.category() == .except);

        const frame = Frame.of(context, handler) orelse continue;

        assert(frame.header < frame.start);

        if (!catches_broadly(context, frame)) continue;
        if (explained(context, frame)) continue;
        if (!swallows(context, frame.body(context.tokens)[1..])) continue;

        sink.report(
            context.tokens[frame.header].span(),
            "the handler does nothing with the error",
        );
    }

    report_suppressions(context, sink);
}

fn catches_broadly(context: *const Context, frame: Frame) bool {
    const clause = context.tokens[frame.header + 1 .. frame.start];

    assert(frame.header < frame.start);
    assert(frame.start < context.tokens.len);

    if (context.tokens[frame.header + 1].is_punctuation(.colon)) return true;
    return names_broadly(context, clause);
}

fn names_broadly(context: *const Context, clause: []const Token) bool {
    assert(clause.len < context.tokens.len);

    for (clause) |token| {
        if (token.kind != .identifier) continue;

        assert(token.end() <= context.source.len);

        if (scan.word_in(&broad_names, context.text(token))) return true;
    }

    return false;
}

fn explained(context: *const Context, frame: Frame) bool {
    const length: u32 = @intCast(context.tokens.len);
    const stop = if (frame.end) |last| @min(last + 2, length) else length;
    const header = context.tokens[frame.header];
    const header_line = scan.line_start_of(context.source, header.offset);
    const margin = scan.indent_width(context.source[header_line..]);

    assert(frame.header < length);
    assert(stop <= length);

    if (stop <= frame.header) return false;

    for (context.tokens[frame.header..stop]) |token| {
        if (token.kind != .comment) continue;

        const line = scan.line_start_of(context.source, token.offset);
        if (line == header_line) return true;
        if (scan.indent_width(context.source[line..]) > margin) return true;
    }

    return false;
}

fn swallows(context: *const Context, body: []const Token) bool {
    var count: u32 = 0;
    var dots: u32 = 0;
    var first: ?Token = null;
    var second: ?Token = null;

    for (body) |token| {
        if (!Token.is_significant(token.kind)) continue;
        if (token.kind == .block_end) continue;
        if (token.kind == .block_start) continue;

        count += 1;

        if (token.is_punctuation(.dot)) dots += 1;

        if (count == 1) first = token;
        if (count == 2) second = token;
    }

    assert(dots <= count);

    if (count > 0) assert(first != null);

    const head = first orelse return false;
    const text = context.text(head);

    if (count == 1) {
        if (std.mem.eql(u8, text, ellipsis)) return true;
    }

    return switch (count) {
        1 => scan.word_in(&swallowing_words, text),
        2 => returns_none(context, text, second.?),
        ellipsis_dot_count => dots == ellipsis_dot_count,
        else => false,
    };
}

fn returns_none(context: *const Context, head: []const u8, tail: Token) bool {
    assert(head.len > 0);
    assert(tail.end() <= context.source.len);

    if (!std.mem.eql(u8, head, return_word)) return false;
    return std.mem.eql(u8, context.text(tail), none_word);
}

fn report_suppressions(context: *const Context, sink: *Sink) void {
    const tokens = context.tokens;

    assert(tokens.len <= std.math.maxInt(u32));

    for (tokens, 0..) |token, position| {
        const index: u32 = @intCast(position);

        if (token.kind != .identifier) continue;
        if (!std.mem.eql(u8, context.text(token), suppress_name)) continue;
        if (index + 1 >= tokens.len) continue;
        if (!tokens[index + 1].is_punctuation(.paren_open)) continue;

        const head = stream.line_start_of_token(tokens, context.source, index);
        const opener = tokens[head];

        assert(head <= index);

        if (!std.mem.eql(u8, context.text(opener), with_word)) continue;

        const close = context.pairs.partner_of(index + 1) orelse continue;

        assert(close >= index + 2);

        if (!names_broadly(context, tokens[index + 2 .. close])) continue;

        sink.report(opener.span(), "the context manager does nothing with the error");
    }
}

fn expect_count(language: Language, source: []const u8, expected: u32) !void {
    assert(source.len > 0);
    assert(expected <= testing.limits.diagnostic_count_max);

    var findings = try testing.analyze(@This(), language, source);
    defer findings.deinit();

    if (findings.count() != expected) findings.print();

    try std.testing.expectEqual(expected, findings.count());
}

test "a pass handler trailed by a comment is explained" {
    const source = "def f():\n    try:\n        g()\n    except Exception:\n" ++
        "        pass  # ignore\n";

    try testing.expect_quiet(@This(), .python, source);
}

test "a silent handler is reported" {
    const source = "def f():\n    try:\n        work()\n    except Exception:\n        pass\n";

    try expect_count(.python, source, 1);
}

test "a handler that names the failure it expects is quiet" {
    const source = "try:\n    import readline\nexcept ImportError:\n    pass\nelse:\n    " ++
        "readline.set_completer(complete)\n\ntry:\n    rows.sort(key=sorts.index(sort))\n" ++
        "except ValueError:\n    pass\n\ndef test_range(client):\n    try:\n        " ++
        "client.create_accounts(accounts)\n    except tb.IntegerOverflowError:\n        pass\n";

    try testing.expect_quiet(@This(), .python, source);
}

test "a tuple of named failures or a named skip is quiet" {
    const source = "def load(loaders):\n    for loader in loaders:\n        try:\n            " ++
        "return loader.load()\n        except TemplateNotFound:\n            continue\n\n" ++
        "    try:\n        import netrc\n    except (ImportError, AttributeError):\n        " ++
        "pass\n\n    try:\n        run()\n    except* KeyError:\n        return None\n";

    try testing.expect_quiet(@This(), .python, source);
}

test "a bare or broad handler that passes is still reported" {
    const source = "try:\n    work()\nexcept:\n    pass\n\ntry:\n    work()\nexcept " ++
        "BaseException:\n    pass\n\ntry:\n    work()\nexcept (ImportError, " ++
        "builtins.Exception):\n    pass\n";

    try expect_count(.python, source, 3);
}

test "a handler on one line is read like an indented one" {
    const source = "try:\n    work()\nexcept Exception: pass\n\ntry:\n    work()\n" ++
        "except KeyError: pass\n";

    try expect_count(.python, source, 1);
}

test "a handler on one line trailed by a comment is explained" {
    const source = "try:\n    work()\nexcept Exception: pass  # ignore\nnext_thing()\n";

    try testing.expect_quiet(@This(), .python, source);
}

test "a comment below the handler at its own margin explains nothing" {
    const source = "def f():\n    try:\n        work()\n    except Exception:\n        pass\n" ++
        "    # the next step\n    next_thing()\n";

    try expect_count(.python, source, 1);
}

test "a handler bound by as or naming a tuple is still silent" {
    const source = "try:\n    work()\nexcept Exception as error:\n    pass\n\ntry:\n    " ++
        "work()\nexcept (ValueError, Exception):\n    pass\n";

    try expect_count(.python, source, 2);
}

test "an ellipsis a continue and a return none swallow" {
    const source = "def f():\n    for item in items:\n        try:\n            work()\n        " ++
        "except Exception:\n            ...\n\n        try:\n            " ++
        "work()\n        except Exception:\n            continue\n\n    " ++
        "try:\n        work()\n    except Exception:\n        return None\n";

    try expect_count(.python, source, 3);
}

test "a handler that returns a value or raises is quiet" {
    const source = "def f():\n    try:\n        work()\n    except Exception:\n        return " ++
        "False\n\n    try:\n        work()\n    except Exception:\n        raise\n";

    try testing.expect_quiet(@This(), .python, source);
}

test "a suppress context manager that names a broad failure is reported" {
    const source = "import contextlib\n\nwith contextlib.suppress(Exception):\n    " ++
        "work()\n\nwith suppress(KeyError, BaseException):\n    work()\n";

    try expect_count(.python, source, 2);
}

test "a suppress context manager that names the failure it expects is quiet" {
    const source = "import contextlib\n\nwith contextlib.suppress(ValueError):\n    " ++
        "work()\n\nwith suppress(KeyError):\n    work()\n";

    try testing.expect_quiet(@This(), .python, source);
}
