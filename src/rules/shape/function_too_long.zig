const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const scan = @import("../../scan.zig");
const shape = @import("../shape.zig");
const support = @import("../support.zig");
const testing = @import("../testing.zig");
const Context = @import("../context.zig");
const Function = scylla.View.Function;
const Rule = scylla.rule.Rule;
const Sink = scylla.rule.Sink;
const Span = scylla.Span;
const View = scylla.View;

pub const rule: Rule = .{
    .citations = &.{
        .{
            .standard = "TigerStyle",
            .text = "\"There's a sharp discontinuity between a function fitting on a screen, " ++
                "and having to scroll to see how long it is. For this physical reason we " ++
                "enforce a hard limit of 70 lines per function.\"",
        },
        .{
            .standard = "NASA",
            .text = "NASA P10 Rule 4: \"No function should be longer than what can be printed " ++
                "on a single sheet of paper in a standard reference format with one line per " ++
                "statement and one line per declaration. Typically, this means no more than " ++
                "about 60 lines of code per function.\"",
        },
    },
    .code = "TS002",
    .default_on = true,
    .description = "A function fits in 70 lines, so that one screen holds the whole unit of work.",
    .explanation = "",
    .fix_title = "",
    .fixable = .sometimes,
    .group = .stable,
    .name = "function-too-long",
    .severity = .warning,
    .summary = "A function must fit within `function_lines_max`",
    .url = "",
};

const function_trail_max: u32 = 1 << 10;

pub fn run(context: *const Context, sink: *Sink) void {
    const allowed = context.settings.thresholds.function_lines_max;
    var nodes = support.functions_and_bound_lambdas(context);

    for (0..context.front.node_count()) |_| {
        const node = nodes.next() orelse break;
        const function = node.as_function() orelse continue;
        if (returns_a_namespace(context, function)) continue;

        const header = header_offset_of(context, node);
        const end = trailing_end_of(context, node, header);

        assert(end >= header);

        const lines = context.lines_of(.between(header, end));

        assert(lines >= 1);

        if (lines <= allowed) continue;

        sink.report_formatted(
            opening_marker_of(context, node),
            "the function is {d} lines, over the {d} line limit",
            .{ lines, allowed },
        );
    }
}

fn returns_a_namespace(context: *const Context, function: Function) bool {
    if (!context.conventions.types_are_values) return false;

    const span = function.returns_span() orelse return false;

    assert(span.end() <= context.source.len);

    const spelled = scan.trim_ascii(context.span_text(span));

    assert(spelled.len <= span.length);

    return std.mem.eql(u8, spelled, shape.type_word);
}

fn header_offset_of(context: *const Context, node: View) u32 {
    const anchor = anchor_of(context, node) orelse return node.span().offset;
    const start = context.line_span(context.line_of(anchor)).offset;

    assert(start <= anchor);
    assert(anchor <= context.source.len);

    return start;
}

fn anchor_of(context: *const Context, node: View) ?u32 {
    if (support.bound_name_of(node)) |name| return context.front_token(name).offset;

    const function = node.as_function() orelse return null;
    const parameters = function.parameters_span() orelse return null;

    assert(parameters.end() <= context.source.len);
    assert(parameters.length > 0);

    return parameters.offset;
}

fn trailing_end_of(context: *const Context, node: View, header: u32) u32 {
    const span = node.span();
    const opens = indent_of(context, header);
    var line = context.line_of(span.end());
    var end = span.end();

    for (0..function_trail_max) |_| {
        const next = line + 1;
        if (next >= context.line_count()) break;

        const held = context.line_span(next);

        if (scan.trim_ascii(context.span_text(held)).len > 0) {
            if (indent_of(context, held.offset) <= opens) break;

            end = held.end();
        }

        line = next;
    }

    assert(end >= span.end());
    assert(line < context.line_count());

    return end;
}

fn indent_of(context: *const Context, offset: u32) u32 {
    assert(offset <= context.source.len);

    const span = context.line_span(context.line_of(offset));
    const leading = leading_of(context.span_text(span));

    assert(leading <= span.length);

    return leading;
}

fn opening_marker_of(context: *const Context, node: View) Span {
    const span = context.line_span(context.line_of(header_offset_of(context, node)));
    const leading = leading_of(context.span_text(span));

    assert(leading <= span.length);
    assert(span.end() <= context.source.len);

    return .{ .offset = span.offset + leading, .length = 1 };
}

fn leading_of(text: []const u8) u32 {
    const trimmed = std.mem.trimStart(u8, text, scan.ascii_whitespace);

    assert(trimmed.len <= text.len);
    if (trimmed.len > 0) assert(!scan.is_ascii_whitespace(trimmed[0]));

    return @intCast(text.len - trimmed.len);
}

fn repeated(
    gpa: std.mem.Allocator,
    opening: []const u8,
    line: []const u8,
    closing: []const u8,
) ![]u8 {
    var source: std.ArrayList(u8) = .empty;
    errdefer source.deinit(gpa);

    try source.appendSlice(gpa, opening);

    for (0..80) |_| try source.appendSlice(gpa, line);

    try source.appendSlice(gpa, closing);

    return source.toOwnedSlice(gpa);
}

fn python_function_of(gpa: std.mem.Allocator, body: u32, trailer: []const u8) ![]u8 {
    var source: std.ArrayList(u8) = .empty;
    errdefer source.deinit(gpa);

    try source.appendSlice(gpa, "def wide():\n");

    for (0..body) |index| try source.print(gpa, "    value{d} = {d}\n", .{ index, index });

    try source.appendSlice(gpa, trailer);

    return source.toOwnedSlice(gpa);
}

test "a long function is reported once" {
    const gpa = std.testing.allocator;
    const source = try repeated(gpa, "fn wide() {\n", "    let value = 1;\n", "}\n");
    defer gpa.free(source);

    var findings = try testing.analyze(@This(), .rust, source);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
    try std.testing.expect(std.mem.find(u8, findings.message(0), "82 lines") != null);
}

test "a trailing sibling comment is not part of the function" {
    const gpa = std.testing.allocator;
    const bare = try python_function_of(gpa, 69, "");
    defer gpa.free(bare);

    const commented = try python_function_of(gpa, 69, "# a note about what follows\n");
    defer gpa.free(commented);

    try testing.expect_quiet(@This(), .python, bare);
    try testing.expect_quiet(@This(), .python, commented);
}

test "a trailing comment inside the body is part of the function" {
    const gpa = std.testing.allocator;
    const inside = try python_function_of(gpa, 70, "    # a note about the line above\n");
    defer gpa.free(inside);

    var findings = try testing.analyze(@This(), .python, inside);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
    try std.testing.expect(std.mem.find(u8, findings.message(0), "72 lines") != null);
}

test "a trailing sibling comment counts the same as a dedented statement" {
    const gpa = std.testing.allocator;
    const commented = try python_function_of(gpa, 70, "# a note\n");
    defer gpa.free(commented);

    const statement = try python_function_of(gpa, 70, "value = 1\n");
    defer gpa.free(statement);

    var commented_findings = try testing.analyze(@This(), .python, commented);
    defer commented_findings.deinit();

    var statement_findings = try testing.analyze(@This(), .python, statement);
    defer statement_findings.deinit();

    try std.testing.expectEqual(commented_findings.count(), statement_findings.count());

    for (0..commented_findings.count()) |index| {
        const expected = commented_findings.message(@intCast(index));

        try std.testing.expectEqualStrings(expected, statement_findings.message(@intCast(index)));
    }
}

test "a short function is quiet" {
    try testing.expect_quiet(@This(), .rust, "fn narrow() {\n    let value = 1;\n}\n");
}

test "a long arrow function bound to a name is reported" {
    const gpa = std.testing.allocator;
    const source = try repeated(gpa, "const wide = () => {\n", "    const value = 1;\n", "};\n");
    defer gpa.free(source);

    var findings = try testing.analyze(@This(), .javascript, source);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
}

test "a long arrow function passed as an argument is a lambda" {
    const gpa = std.testing.allocator;
    const source = try repeated(gpa, "run(() => {\n", "    const value = 1;\n", "});\n");
    defer gpa.free(source);

    try testing.expect_quiet(@This(), .javascript, source);
}
