const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const support = @import("../support.zig");
const testing = @import("../testing.zig");
const Context = @import("../context.zig");
const Function = scylla.View.Function;
const Parameter = scylla.View.Parameter;
const Rule = scylla.rule.Rule;
const Sink = scylla.rule.Sink;
const parameter_count_max = scylla.limits.parameter_count_max;

pub const rule: Rule = .{
    .citations = &.{
        .{
            .standard = "TigerStyle",
            .text = "\"Good function shape is often the inverse of an hourglass: a few " ++
                "parameters, a simple return type, and a lot of meaty logic between the braces.\"",
        },
    },
    .code = "TS003",
    .default_on = true,
    .description = "A function takes at most `parameters_max` parameters; past that the " ++
        "arguments are easy to mix up and belong in an options struct.",
    .explanation = "",
    .fix_title = "",
    .fixable = .sometimes,
    .group = .stable,
    .name = "too-many-parameters",
    .severity = .warning,
    .summary = "A signature must not exceed `parameters_max` parameters",
    .url = "",
};

pub fn run(context: *const Context, sink: *Sink) void {
    const allowed = context.settings.thresholds.parameters_max;
    var nodes = support.functions_and_bound_lambdas(context);

    for (0..context.front.node_count()) |_| {
        const node = nodes.next() orelse break;
        const function = node.as_function() orelse continue;
        const parameters = function.parameters_span() orelse continue;
        const count = parameter_count(context, function);

        assert(count <= parameter_count_max);

        if (count <= allowed) continue;

        assert(parameters.end() <= context.source.len);

        sink.report_formatted(
            parameters,
            "the function takes {d} parameters, over the {d} the style allows",
            .{ count, allowed },
        );
    }
}

fn parameter_count(context: *const Context, function: Function) u32 {
    var parameters = function.parameters();
    var count: u32 = 0;

    for (0..parameters.remaining) |index| {
        const parameter = parameters.next() orelse break;
        const receiver = index == 0 and names_a_receiver(context, parameter);

        if (!receiver) count += 1;
    }

    assert(count <= parameter_count_max);
    assert(count <= function.parameters().count());

    return count;
}

fn names_a_receiver(context: *const Context, parameter: Parameter) bool {
    const name = parameter.name orelse return false;
    const text = context.front_text(name);

    assert(text.len <= parameter.span.length);

    for (context.conventions.receiver_names) |receiver| {
        assert(receiver.len > 0);

        if (std.mem.eql(u8, receiver, text)) return true;
    }

    return false;
}

test "parameters are counted without the receiver" {
    const source = "def wide(self, a, b, c, d, e, f, g, h):\n    return 1\n";

    var findings = try testing.analyze(@This(), .python, source);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
    try std.testing.expect(std.mem.find(u8, findings.message(0), "8 parameters") != null);
}

test "a zig parameter named self is counted like any other" {
    const source = "fn wide(self: *IO, a: u32, b: u32, c: u32, d: u32, e: u32, f: u32, " ++
        "g: u32) void {\n}\n";

    var findings = try testing.analyze(@This(), .zig, source);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
    try std.testing.expect(std.mem.find(u8, findings.message(0), "8 parameters") != null);
}

test "a rust parameter named self is the receiver" {
    const source = "fn wide(self, a: u32, b: u32, c: u32, d: u32, e: u32, f: u32, g: u32) {\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
}

test "an unbalanced parameter list is counted without crashing" {
    try testing.expect_quiet(@This(), .rust, "fn narrow(first: Vec<u32>], second: u32) {\n}\n");
}

test "a generic parameter list is counted once" {
    const source = "fn narrow(first: Vec<(u32, u32)>, second: u32) {\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
}

test "a wide arrow function bound to a name is reported" {
    const source = "const wide = (a, b, c, d, e, f, g, h) => a;\n";

    var findings = try testing.analyze(@This(), .javascript, source);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
    try std.testing.expect(std.mem.find(u8, findings.message(0), "8 parameters") != null);
}

test "a wide anonymous function is reported" {
    const source = "run(function (a, b, c, d, e, f, g, h) {\n    return a;\n});\n";

    var findings = try testing.analyze(@This(), .javascript, source);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
}

test "a wide go func literal bound to a name is reported" {
    const source = "package main\n\nvar wide = func(a, b, c, d, e, f, g, h int) int {\n\t" ++
        "return a\n}\n";

    var findings = try testing.analyze(@This(), .go, source);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
}
