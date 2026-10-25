const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const scan = @import("../../scan.zig");
const shape = @import("../shape.zig");
const support = @import("../support.zig");
const testing = @import("../testing.zig");
const Context = @import("../context.zig");
const Frame = @import("../frame.zig");
const Function = scylla.View.Function;
const HandOvers = @import("../hand_overs.zig");
const Parameter = scylla.View.Parameter;
const Rule = scylla.rule.Rule;
const Sink = scylla.rule.Sink;
const View = scylla.View;
const parameter_count_max = scylla.limits.parameter_count_max;

pub const rule: Rule = .{
    .citations = &.{
        .{
            .standard = "TigerStyle",
            .text = "\"Zig has named arguments through the `options: struct` pattern. Use it " ++
                "when arguments can be mixed up. A function taking two `u64` must use an " ++
                "options struct. If an argument can be `null`, it should be named so that the " ++
                "meaning of `null` literal at the call site is clear.\"",
        },
    },
    .code = "TS033",
    .default_on = false,
    .description = "Two parameters of one type can be transposed at the call site; take a " ++
        "struct whose fields are named.",
    .explanation = "",
    .fix_title = "",
    .fixable = .sometimes,
    .group = .stable,
    .name = "options-struct",
    .severity = .warning,
    .summary = "Take an options struct rather than two same-typed parameters",
    .url = "",
};

const Pair = struct {
    earlier: Parameter,
    later: Parameter,
    measure: []const u8,
};

const Signatures = struct {
    count: u32,
    nodes: [signature_count_max]u32,
    state: HandOvers.State,

    fn build(signatures: *Signatures, context: *const Context) void {
        var functions = context.views(.function);

        assert(signatures.state == .unbuilt);

        signatures.count = 0;
        signatures.state = .overflowed;

        for (0..context.front.node_count()) |_| {
            const held = functions.next() orelse break;
            const function = held.as_function() orelse continue;
            if (function.body() != null) continue;
            if (signatures.count == signature_count_max) return;

            signatures.nodes[signatures.count] = held.index();
            signatures.count += 1;
        }

        signatures.state = .built;

        assert(signatures.count <= signature_count_max);
    }
};

const comparator_contexts = [_][]const u8{ "@This()", "void" };
const comparator_order = "Order";
const comparator_verdict = "bool";
const foreign_words = [_][]const u8{"foreign"};
const signature_count_max: u32 = 1_024;
const spread_prefix = "...";
const stub_body = "...";

pub fn run(context: *const Context, sink: *Sink) void {
    var functions = support.functions_and_bound_lambdas(context);
    var hand_overs: HandOvers = undefined;
    var signatures: Signatures = undefined;

    hand_overs.begin();
    signatures.state = .unbuilt;

    for (0..context.front.node_count()) |_| {
        const function = functions.next() orelse break;
        const held = function.as_function() orelse continue;

        if (binds_a_foreign_signature(context, function)) continue;
        if (stubs_a_signature(context, held)) continue;

        const pair = transposable_pair(context, held) orelse continue;

        if (hand_overs.covers(context, function)) continue;
        if (shapes_a_comparator(context, held, pair)) continue;
        if (implements_overloads(context, &signatures, held)) continue;

        assert(std.mem.eql(u8, pair.measure, measure_of(context, pair.later, null).?));
        assert(pair.later.span.offset >= pair.earlier.span.offset);

        report_a_pair(context, sink, pair);
    }
}

fn implements_overloads(context: *const Context, signatures: *Signatures, function: Function) bool {
    const name = function.name_token() orelse return false;
    const start = function.view.span().offset;
    const named = context.front_text(name);

    assert(start <= context.source.len);
    assert(name < context.front.tokens().len);

    if (signatures.state == .unbuilt) signatures.build(context);

    if (signatures.state == .built) {
        for (signatures.nodes[0..signatures.count]) |node| {
            const other = context.view(node);
            if (other.span().end() > start) continue;
            if (overloads(context, other, function.view, named)) return true;
        }

        return false;
    }

    var functions = context.views(.function);

    for (0..functions.remaining) |_| {
        const other = functions.next() orelse return false;
        if (other.span().end() > start) continue;
        if (overloads(context, other, function.view, named)) return true;
    }

    return false;
}

fn overloads(context: *const Context, signature: View, function: View, named: []const u8) bool {
    const held = signature.as_function() orelse return false;
    const name = held.name_token() orelse return false;

    assert(signature.span().end() <= function.span().offset);
    assert(named.len > 0);

    if (held.body() != null) return false;
    if (!std.mem.eql(u8, context.front_text(name), named)) return false;

    const parent = signature.parent() orelse return function.parent() == null;
    const owner = function.parent() orelse return false;

    return parent.index() == owner.index();
}

fn transposable_pair(context: *const Context, function: Function) ?Pair {
    const keyed = keyed_from(context, function);
    var parameters = function.parameters();

    if (keyed) |from| assert(from <= context.source.len);

    for (0..parameter_count_max + 1) |index| {
        const earlier = parameters.next() orelse return null;
        const measure = measure_of(context, earlier, keyed) orelse continue;

        const later = later_matching(context, function, @intCast(index + 1), measure, keyed) orelse
            continue;

        assert(later.span.offset >= earlier.span.offset);

        return .{ .earlier = earlier, .later = later, .measure = measure };
    }

    return null;
}

fn later_matching(
    context: *const Context,
    function: Function,
    skipped: u32,
    measure: []const u8,
    keyed: ?u32,
) ?Parameter {
    assert(skipped > 0);

    var parameters = function.parameters();

    for (0..parameter_count_max + 1) |index| {
        const later = parameters.next() orelse return null;

        if (index < skipped) continue;

        const held = measure_of(context, later, keyed) orelse continue;
        if (!std.mem.eql(u8, held, measure)) continue;

        assert(index >= skipped);

        return later;
    }

    return null;
}

fn report_a_pair(context: *const Context, sink: *Sink, pair: Pair) void {
    const first = if (pair.earlier.name) |name| context.front_text(name) else "";
    const second = if (pair.later.name) |name| context.front_text(name) else "";

    assert(pair.later.span.end() >= pair.earlier.span.offset);
    assert(pair.later.span.end() <= context.source.len);

    sink.report_formatted(
        .between(pair.earlier.span.offset, pair.later.span.end()),
        "the parameters {s} and {s} are both {s}; a call site can transpose them",
        .{
            scan.utf8_or(first, "the earlier"),
            scan.utf8_or(second, "the later"),
            scan.utf8_or(pair.measure, "one type"),
        },
    );
}

fn keyed_from(context: *const Context, function: Function) ?u32 {
    var from = bare_star_of(context, function);
    var parameters = function.parameters();

    for (0..parameters.remaining) |_| {
        const parameter = parameters.next() orelse break;
        if (!shape.starred(context, parameter)) continue;

        from = @min(from orelse parameter.span.offset, parameter.span.offset);
    }

    if (from) |offset| assert(offset <= context.source.len);
    assert(parameters.remaining < parameter_count_max);

    return from;
}

fn bare_star_of(context: *const Context, function: Function) ?u32 {
    const span = function.parameters_span() orelse return null;
    const tokens = context.tokens_in(span);

    assert(tokens.len <= context.tokens.len);

    for (tokens, 0..) |token, index| {
        if (!token.is_punctuation(.star)) continue;
        if (index + 1 >= tokens.len) continue;

        const next = tokens[index + 1];
        const closes = next.is_punctuation(.comma) or next.is_punctuation(.paren_close);
        if (!closes) continue;

        assert(token.offset >= span.offset);

        return token.offset;
    }

    return null;
}

fn measure_of(context: *const Context, parameter: Parameter, keyed: ?u32) ?[]const u8 {
    assert(parameter.span.end() <= context.source.len);

    if (keyed) |from| {
        if (parameter.span.offset >= from) return null;
    }

    if (parameter.name) |name| {
        if (support.names_the_discard(context, context.front_text(name))) return null;
    }

    if (parameter.name == null) {
        if (discards_by_pattern(context, parameter)) return null;
    }

    const spelled = parameter.type_span orelse return null;
    const measure = normalized(context.span_text(spelled));

    assert(measure.len <= spelled.length);

    if (std.mem.eql(u8, measure, shape.type_word)) return null;
    return measure;
}

fn discards_by_pattern(context: *const Context, parameter: Parameter) bool {
    assert(parameter.name == null);

    const text = context.span_text(parameter.span);
    const pattern = if (std.mem.findScalar(u8, text, ':')) |colon| text[0..colon] else text;
    const trimmed = scan.trim_ascii(pattern);

    assert(trimmed.len <= text.len);

    if (trimmed.len == 0) return false;
    return support.names_the_discard(context, trimmed);
}

fn normalized(spelled: []const u8) []const u8 {
    const spread = std.mem.startsWith(u8, spelled, spread_prefix);
    const opened = if (spread) spelled[spread_prefix.len..] else spelled;
    const closed = if (scan.find(opened, "=")) |index| opened[0..index] else opened;
    const trimmed = scan.trim_ascii(closed);

    assert(trimmed.len <= closed.len);
    assert(closed.len <= spelled.len);

    return trimmed;
}

fn binds_a_foreign_signature(context: *const Context, function: View) bool {
    const offset = function.span().offset;
    const line = context.line_text(context.line_of(offset));

    assert(line.len <= context.source.len);

    for (context.conventions.pointer_boundary_markers) |word| {
        if (scan.find_word(line, word)) return true;
    }

    for (foreign_words) |word| {
        if (scan.find_word(line, word)) return true;
    }

    const token = context.lexer_index_from(offset);
    if (token >= context.tokens.len) return false;

    var frames = Frame.covering(context, token);

    for (0..context.front.node_count()) |_| {
        const covering = frames.next() orelse return false;
        const opening = covering.frame.opening_word(context);

        assert(covering.frame.covers(token));

        if (scan.word_in(&foreign_words, opening)) return true;
    }

    return false;
}

fn shapes_a_comparator(context: *const Context, function: Function, pair: Pair) bool {
    const opened = function.view.span().offset;
    const leading = context.source[opened..@max(opened, pair.earlier.span.offset)];

    assert(leading.len <= context.source.len);

    if (!names_a_comparator_context(leading)) return false;

    const returns = function.returns_span() orelse return false;
    if (!judges_an_order(scan.trim_ascii(context.span_text(returns)))) return false;

    var parameters = function.parameters();

    const first = parameters.next() orelse return false;
    const left = parameters.next() orelse return false;
    const right = parameters.next() orelse return false;

    if (parameters.next() != null) return false;

    assert(first.span.offset <= left.span.offset);
    assert(left.span.offset <= right.span.offset);

    const holder = first.type_span orelse return false;
    return scan.word_in(&comparator_contexts, normalized(context.span_text(holder)));
}

fn names_a_comparator_context(leading: []const u8) bool {
    for (comparator_contexts) |word| {
        if (std.mem.find(u8, leading, word) != null) return true;
    }

    return false;
}

fn judges_an_order(result: []const u8) bool {
    if (std.mem.eql(u8, result, comparator_verdict)) return true;
    return std.mem.endsWith(u8, result, comparator_order);
}

fn stubs_a_signature(context: *const Context, function: Function) bool {
    const body = function.body() orelse return true;
    const text = scan.trim_ascii(context.span_text(body.span()));

    assert(body.index() > function.view.index());
    assert(text.len <= body.span().length);

    return std.mem.eql(u8, text, stub_body);
}

test "two anytype parameters are one type" {
    const source = "fn run(first: anytype, second: anytype) void {\n    _ = first;\n    " ++
        "_ = second;\n}\n";

    var findings = try testing.analyze(@This(), .zig, source);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
    try std.testing.expect(std.mem.find(u8, findings.message(0), "anytype") != null);
}

test "two same typed parameters apart are reported" {
    const source = "fn span(start: u32, name: &str, end: u32) -> u32 {\n    end - start\n}\n";

    var findings = try testing.analyze(@This(), .rust, source);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
    try std.testing.expect(std.mem.find(u8, findings.message(0), "start and end") != null);
}

test "a function handed over as a value takes the signature it fills" {
    const sorted = "fn sort(items: []u32) void {\n    std.mem.sort(u32, items, {}, less);\n}\n\n" ++
        "fn less(_: void, left: u32, right: u32) bool {\n    return left < right;\n}\n";

    const table = "const table: Table = .{ .owes = Rules.owes };\n\n" ++
        "const Rules = struct {\n    fn owes(kind: Kind, parent: Kind) bool {\n" ++
        "        return kind == parent;\n    }\n};\n";

    const called = "fn sort(items: []u32) bool {\n" ++
        "    return less(items[0], items[1]);\n}\n\n" ++
        "fn less(left: u32, right: u32) bool {\n    return left < right;\n}\n";

    try testing.expect_quiet(@This(), .zig, sorted);
    try testing.expect_quiet(@This(), .zig, table);

    var findings = try testing.analyze(@This(), .zig, called);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
}

test "a function handed over with its own arguments keeps its signature" {
    const source = "fn run(first: u32, second: u32) !void {\n" ++
        "    const thread = try std.Thread.spawn(.{}, work, .{ first, second });\n" ++
        "    thread.join();\n}\n\nfn work(first: u32, second: u32) void {\n" ++
        "    _ = first;\n    _ = second;\n}\n";

    var findings = try testing.analyze(@This(), .zig, source);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 2), findings.count());
}

test "an overload implementation is called only through its overload signatures" {
    const overloaded = "class Record {\n" ++
        "    static create(value: string): Record;\n" ++
        "    static create(key: number, value: string): Record;\n" ++
        "    static create(first: any, second?: any): Record {\n" ++
        "        return new Record();\n    }\n}\n";

    const plain = "class Record {\n" ++
        "    static create(first: any, second?: any): Record {\n" ++
        "        return new Record();\n    }\n}\n";

    try testing.expect_quiet(@This(), .typescript, overloaded);

    var findings = try testing.analyze(@This(), .typescript, plain);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
}

test "a function expression assigned to a member fills the member's signature" {
    const assigned = "inst.run = function shim(first: number, second: number): number {\n" ++
        "    return first + second;\n};\n";

    const bound = "const shim = function run(first: number, second: number): number {\n" ++
        "    return first + second;\n};\n";

    const field = "class Sorter {\n    compare = (first: number, second: number): number => {\n" ++
        "        return first - second;\n    };\n}\n";

    const declared = "const Peer = struct {\n    likely: u128,\n\n" ++
        "    pub fn transition(old: u32, new: u32) u32 {\n        return old + new;\n    }\n};\n";

    const method = "const methods = {\n    clone() {\n        return 0;\n    },\n" ++
        "    register(first: number, second: number) {\n        return first + second;\n" ++
        "    },\n};\n";

    try testing.expect_quiet(@This(), .typescript, assigned);

    var bound_findings = try testing.analyze(@This(), .typescript, bound);
    defer bound_findings.deinit();

    var field_findings = try testing.analyze(@This(), .typescript, field);
    defer field_findings.deinit();

    var declared_findings = try testing.analyze(@This(), .zig, declared);
    defer declared_findings.deinit();

    var method_findings = try testing.analyze(@This(), .typescript, method);
    defer method_findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), bound_findings.count());
    try std.testing.expectEqual(@as(u32, 1), field_findings.count());
    try std.testing.expectEqual(@as(u32, 1), declared_findings.count());
    try std.testing.expectEqual(@as(u32, 1), method_findings.count());
}

test "an alias, an export, or a procedure group fixes no signature" {
    const aliased = "pub const build = run;\n\nfn run(first: u32, second: u32) u32 {\n" ++
        "    return first + second;\n}\n";

    const exported = "function run(first: number, second: number): number {\n" ++
        "    return first + second;\n}\n\nexport { run };\nexport default run;\n";

    const grouped = "add :: proc{add_ints, add_floats}\n\n" ++
        "add_ints :: proc(first: int, second: int) -> int {\n    return first + second\n}\n";

    var alias_findings = try testing.analyze(@This(), .zig, aliased);
    defer alias_findings.deinit();

    var export_findings = try testing.analyze(@This(), .typescript, exported);
    defer export_findings.deinit();

    var group_findings = try testing.analyze(@This(), .odin, grouped);
    defer group_findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), alias_findings.count());
    try std.testing.expectEqual(@as(u32, 1), export_findings.count());
    try std.testing.expectEqual(@as(u32, 1), group_findings.count());
}

test "a generic call, a comparison, a prong, or a shadowing parameter hands nothing over" {
    const generic = "fn run<T>(first: u32, second: u32) -> u32 {\n    first + second\n}\n\n" ++
        "fn main() {\n    run::<u8>(1, 2);\n}\n";

    const compared = "function run(first: number, second: number): number {\n" ++
        "    return first + second;\n}\n\nif (handler === run) {\n}\n";

    const selected = "pub const init = switch (mode) {\n    .fast => run,\n" ++
        "    .slow => run,\n};\n\nfn run(first: u32, second: u32) u32 {\n" ++
        "    return first + second;\n}\n";

    const shadowed = "newline :: proc(first: int, second: int) -> int {\n" ++
        "    return first + second\n}\n\nbreak_with :: proc(newline := true) -> Document {\n" ++
        "    return Document{newline = newline}\n}\n";

    var generic_findings = try testing.analyze(@This(), .rust, generic);
    defer generic_findings.deinit();

    var compared_findings = try testing.analyze(@This(), .typescript, compared);
    defer compared_findings.deinit();

    var selected_findings = try testing.analyze(@This(), .zig, selected);
    defer selected_findings.deinit();

    var shadowed_findings = try testing.analyze(@This(), .odin, shadowed);
    defer shadowed_findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), generic_findings.count());
    try std.testing.expectEqual(@as(u32, 1), compared_findings.count());
    try std.testing.expectEqual(@as(u32, 1), selected_findings.count());
    try std.testing.expectEqual(@as(u32, 1), shadowed_findings.count());
}

test "a comparator shaped for a sort or a hash map context fills that interface" {
    const sorted = "pub fn less_than(context: void, left: Row, right: Row) bool {\n" ++
        "    _ = context;\n\n    return left.start < right.start;\n}\n";

    const hashed = "pub fn eql(_: @This(), left: u64, right: u64) bool {\n" ++
        "    return left == right;\n}\n";

    const ordered = "pub fn order(context: void, left: u32, right: u32) std.math.Order {\n" ++
        "    _ = context;\n\n    return std.math.order(left, right);\n}\n";

    const sized = "pub fn span(context: void, left: u32, right: u32) u32 {\n" ++
        "    _ = context;\n\n    return right - left;\n}\n";

    try testing.expect_quiet(@This(), .zig, sorted);
    try testing.expect_quiet(@This(), .zig, hashed);
    try testing.expect_quiet(@This(), .zig, ordered);

    var findings = try testing.analyze(@This(), .zig, sized);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
}

test "a go grouped parameter list reads as a comparator shape without tripping" {
    const source = "package main\n\nfunc equal(t *testing.T, expected, actual any) bool {\n" ++
        "\treturn expected == actual\n}\n";

    var findings = try testing.analyze(@This(), .go, source);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
}

test "a discard parameter carries nothing to transpose" {
    const source = "fn never(_: Kind, _: Kind) bool {\n    return false;\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "a rust wildcard parameter carries nothing to transpose" {
    const wildcard = "fn variant(self, _: &'static str, _: u32, _: &'static str) -> u32 {\n" ++
        "    0\n}\n";

    const named = "fn variant(self, name: &'static str, _: u32, variant: &'static str) " ++
        "-> u32 {\n    0\n}\n";

    var findings = try testing.analyze(@This(), .rust, named);
    defer findings.deinit();

    try testing.expect_quiet(@This(), .rust, wildcard);
    try std.testing.expectEqual(@as(u32, 1), findings.count());
}

test "a grouped go declaration still pairs" {
    const source = "package main\n\nfunc span(start, end int) int {\n\treturn end - start\n}\n";

    var findings = try testing.analyze(@This(), .go, source);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
}
