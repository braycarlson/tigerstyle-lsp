const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const safety = @import("../safety.zig");
const scan = @import("../../scan.zig");
const Context = @import("../context.zig");
const Rule = scylla.rule.Rule;
const Sink = scylla.rule.Sink;
const TestScope = @import("../test_scope.zig");

pub const rule: Rule = .{
    .citations = &.{
        .{
            .standard = "TigerStyle",
            .text = "\"Assertions detect programmer errors. Unlike operating errors, which are " ++
                "expected and which must be handled, assertion failures are unexpected. The " ++
                "only correct way to handle corrupt code is to crash.\"",
        },
        .{
            .standard = "NASA",
            .text = "NASA P10 Rule 1: \"Restrict all code to very simple control flow " ++
                "constructs; do not use goto statements, setjmp or longjmp constructs, and " ++
                "direct or indirect recursion.\"",
        },
    },
    .code = "TS052",
    .default_on = true,
    .description = "A crash stays a crash, because a recovered panic runs on from state the " ++
        "program has already proven wrong.",
    .explanation = "",
    .fix_title = "",
    .fixable = .never,
    .group = .stable,
    .name = "no-panic-recovery",
    .severity = .@"error",
    .summary = "A panic must not be recovered from; corrupt state has to crash",
    .url = "",
};

const handler_scan_max: u32 = 64;
const host_names = [_][]const u8{ "globalThis", "process", "self", "window" };

const listener_names = [_][]const u8{
    "addListener",
    "on",
    "once",
    "prependListener",
    "prependOnceListener",
};

pub fn run(context: *const Context, sink: *Sink) void {
    assert(context.tokens.len <= std.math.maxInt(u32));
    assert(context.source.len <= std.math.maxInt(u32));

    calls_report(context, sink);
    handlers_report(context, sink);
    listeners_report(context, sink);
}

fn calls_report(context: *const Context, sink: *Sink) void {
    const names = context.conventions.recovery_call_names;
    if (names.len == 0) return;

    assert(names.len > 0);

    for (context.tokens, 0..) |token, position| {
        const index: u32 = @intCast(position);

        if (token.kind != .identifier) continue;
        if (!scan.word_listed(names, context.text(token))) continue;
        if (index + 1 >= context.tokens.len) continue;
        if (!context.tokens[index + 1].is_punctuation(.paren_open)) continue;
        if (owned(context, index)) continue;
        if (TestScope.holds(context, token.offset)) continue;

        assert(index + 1 < context.tokens.len);

        sink.report(token.span(), "the panic is recovered from; corrupt state has to crash");
    }
}

fn owned(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);

    if (index == 0) return false;

    const before = context.tokens[index - 1];

    assert(before.offset <= context.tokens[index].offset);

    if (before.is_punctuation(.dot)) return true;
    return before.is_keyword(.function);
}

fn handlers_report(context: *const Context, sink: *Sink) void {
    const names = context.conventions.recovery_except_names;
    if (names.len == 0) return;

    assert(names.len > 0);

    for (context.tokens, 0..) |token, position| {
        if (!token.is_keyword(.except)) continue;

        const start: u32 = @intCast(position + 1);
        const end: u32 = @intCast(@min(position + handler_scan_max, context.tokens.len));

        assert(start <= end);

        for (context.tokens[start..end]) |held| {
            if (closes_a_handler(held)) break;
            if (held.kind != .identifier) continue;
            if (!scan.word_listed(names, context.text(held))) continue;

            if (!TestScope.holds(context, held.offset)) {
                sink.report(
                    held.span(),
                    "the handler catches an assertion failure; a failed assertion has to crash",
                );
            }

            break;
        }
    }
}

fn closes_a_handler(token: scylla.Token) bool {
    const closes = switch (token.kind) {
        .block_start, .newline => true,
        .punctuation => |punctuation| punctuation == .colon,
        .block_end, .comment, .identifier, .keyword, .number, .string => false,
    };

    if (closes) assert(token.kind != .identifier);
    if (!closes) assert(token.kind != .newline);

    return closes;
}

fn listeners_report(context: *const Context, sink: *Sink) void {
    const names = context.conventions.recovery_event_names;
    if (names.len == 0) return;

    assert(names.len > 0);

    for (context.tokens, 0..) |token, position| {
        const index: u32 = @intCast(position);

        const listed = switch (token.kind) {
            .identifier => scan.word_listed(names, context.text(token)),
            .string => scan.word_listed(names, safety.unquoted(context.text(token))),
            else => false,
        };

        if (!listed) continue;
        if (!registers_a_handler(context, index)) continue;
        if (TestScope.holds(context, token.offset)) continue;

        assert(token.length > 0);

        sink.report(
            token.span(),
            "the handler intercepts an uncaught error; corrupt state has to crash",
        );
    }
}

fn registers_a_handler(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);

    const tokens = context.tokens;

    if (tokens[index].kind == .identifier) {
        if (index < 2) return false;
        if (!tokens[index - 1].is_punctuation(.dot)) return false;
        if (!scan.word_in(&host_names, context.text(tokens[index - 2]))) return false;
        if (index + 1 >= tokens.len) return false;

        assert(index >= 2);

        return tokens[index + 1].is_punctuation(.assign);
    }

    if (index < 4) return false;
    if (!tokens[index - 1].is_punctuation(.paren_open)) return false;
    if (!scan.word_in(&listener_names, context.text(tokens[index - 2]))) return false;
    if (!tokens[index - 3].is_punctuation(.dot)) return false;

    assert(index >= 4);

    return scan.word_in(&host_names, context.text(tokens[index - 4]));
}
