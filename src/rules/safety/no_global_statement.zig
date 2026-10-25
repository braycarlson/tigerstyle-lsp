const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const safety = @import("../safety.zig");
const scan = @import("../../scan.zig");
const testing = @import("../testing.zig");
const Context = @import("../context.zig");
const Language = scylla.Language;
const Rule = scylla.rule.Rule;
const Sink = scylla.rule.Sink;

pub const rule: Rule = .{
    .citations = &.{
        .{
            .standard = "TigerStyle",
            .text = "\"Declare variables at the smallest possible scope, and minimize the " ++
                "number of variables in scope.\"",
        },
        .{
            .standard = "NASA",
            .text = "NASA P10 Rule 6: \"Data objects must be declared at the smallest possible " ++
                "level of scope.\"",
        },
    },
    .code = "TS013",
    .default_on = true,
    .description = "A function does not rebind module state, so its effects stay in its return " ++
        "value.",
    .explanation = "",
    .fix_title = "",
    .fixable = .sometimes,
    .group = .stable,
    .name = "no-global-statement",
    .severity = .warning,
    .summary = "`global` widens scope; pass values instead",
    .url = "",
};

const global_word = "global";

pub fn run(context: *const Context, sink: *Sink) void {
    const tokens = context.tokens;

    assert(tokens.len <= std.math.maxInt(u32));

    for (tokens, 0..) |token, position| {
        const index: u32 = @intCast(position);

        if (token.is_keyword(.global)) {
            assert(token.length > 0);

            if (!std.mem.eql(u8, context.text(token), global_word)) continue;

            sink.report(token.span(), "the function rebinds module state");

            continue;
        }

        if (!assigns_through_a_host(context, index)) continue;
        if (!context.inside(.function, token.offset)) continue;

        sink.report(token.span(), "the function rebinds global state by name");
    }
}

fn assigns_through_a_host(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);

    const tokens = context.tokens;
    const token = tokens[index];
    if (token.kind != .identifier) return false;

    if (!scan.word_listed(context.conventions.global_host_names, context.text(token))) {
        return false;
    }

    if (index + 3 >= tokens.len) return false;
    if (!tokens[index + 1].is_punctuation(.dot)) return false;
    if (tokens[index + 2].kind != .identifier) return false;

    const operator = tokens[index + 3];

    assert(operator.offset >= token.end());

    if (operator.is_punctuation(.assign)) return true;
    return safety.compounds_an_assignment(context, operator);
}

fn expect_count(language: Language, source: []const u8, expected: u32) !void {
    assert(source.len > 0);
    assert(expected <= testing.limits.diagnostic_count_max);

    var findings = try testing.analyze(@This(), language, source);
    defer findings.deinit();

    if (findings.count() != expected) findings.print();

    try std.testing.expectEqual(expected, findings.count());
}

test "a nonlocal rebinds the enclosing function's local and is quiet" {
    const source = "def test_run():\n    count = 0\n\n    def bump():\n        nonlocal " ++
        "count\n        count += 1\n\n    async def after(response):\n        nonlocal " ++
        "count\n        count = 2\n        return response\n";

    try testing.expect_quiet(@This(), .python, source);
}

test "a global inside a test's closure is still reported" {
    const source = "count = 0\n\ndef test_run():\n    def bump():\n        global count\n" ++
        "        count += 1\n";

    try expect_count(.python, source, 1);
}

test "an assignment through a global host is reported" {
    const source = "function run() {\n    globalThis.count = 1;\n    window.held += 2;\n    " ++
        "self.count = 3;\n}\n";

    try expect_count(.javascript, source, 2);
}

test "a host assignment at module level is not a rebinding" {
    try testing.expect_quiet(@This(), .typescript, "globalThis.count = 1;\n");
}

test "a global statement is reported" {
    try expect_count(.python, "def f():\n    global counter\n    counter = 1\n", 1);
}

test "a host passed in as a parameter still writes global state" {
    const source = "(function (global, factory) {\n    factory(global);\n})(this, function " ++
        "(window, noGlobal) {\n    var _$ = window.$;\n\n    jQuery.noConflict = function " ++
        "(deep) {\n        if (window.$ === jQuery) {\n            window.$ = _$;\n        }\n" ++
        "\n        return jQuery;\n    };\n\n    if (!noGlobal) {\n        window.jQuery = " ++
        "window.$ = jQuery;\n    }\n});\n";

    try expect_count(.javascript, source, 3);
}
