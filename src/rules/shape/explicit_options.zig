const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const scan = @import("../../scan.zig");
const support = @import("../support.zig");
const testing = @import("../testing.zig");
const Call = scylla.View.Call;
const Context = @import("../context.zig");
const Function = scylla.View.Function;
const Rule = scylla.rule.Rule;
const Sink = scylla.rule.Sink;
const View = scylla.View;

pub const rule: Rule = .{
    .citations = &.{
        .{
            .standard = "TigerStyle",
            .text = "\"Explicitly pass options to library functions at the call site, instead " ++
                "of relying on the defaults. For example, write " ++
                "`@prefetch(a, .{ .cache = .data, .rw = .read, .locality = 3 });` over " ++
                "`@prefetch(a, .{});`. This improves readability but most of all avoids latent, " ++
                "potentially catastrophic bugs in case the library ever changes its defaults.\"",
        },
    },
    .code = "TS053",
    .default_on = false,
    .description = "A call spells the options it passes, so a change to the callee's defaults " ++
        "cannot change what the call does.",
    .explanation = "",
    .fix_title = "",
    .fixable = .never,
    .group = .stable,
    .name = "explicit-options",
    .severity = .information,
    .summary = "Pass options explicitly rather than relying on the callee's defaults",
    .url = "",
};

const Filled = enum {
    any,
    typed,
    unfit,
};

const any_type = "anytype";
const default_type_names = [_][]const u8{ "Default", "Self" };
const default_word = "default";
const empty_braces = "{}";
const option_arguments_max: u32 = 32;
const option_path_bytes = ".:&*";
const option_path_segments_max: u32 = 4;

const option_type_suffixes = [_][]const u8{
    "Args",
    "Config",
    "Flags",
    "Options",
    "Opts",
    "Params",
    "Settings",
};

const option_whitespace_max: u32 = 64;
const text_markers = [_][]const u8{ "\"", "++", "\\\\" };
const update_marker = "..";

pub fn run(context: *const Context, sink: *Sink) void {
    const suffixes = context.conventions.empty_option_suffixes;
    if (suffixes.len == 0) return;

    assert(context.tokens.len <= std.math.maxInt(u32));

    for (suffixes) |suffix| assert(suffix.len > 0);

    report_empty_option_arguments(context, sink);
    report_default_struct_updates(context, sink);
}

fn report_empty_option_arguments(context: *const Context, sink: *Sink) void {
    var calls = context.views(.call);

    for (0..calls.remaining) |_| {
        const call = calls.next() orelse break;
        const held = call.as_call() orelse continue;

        assert(call.category() == .call);
        assert(call.span().end() <= context.source.len);

        report_call(context, sink, held);
    }
}

fn report_call(context: *const Context, sink: *Sink, call: Call) void {
    if (takes_a_context(context, call)) return;
    if (stores_a_value(context, call)) return;
    if (compares_values(context, call)) return;

    const count = arguments_count(call);
    var arguments = call.arguments();
    var follows_text = false;
    var previous: ?View = null;

    assert(count <= option_arguments_max);

    for (0..count) |index| {
        const argument = arguments.next() orelse break;
        const text = argument.text(context.source);

        assert(argument.index() > call.view.index());

        if (!follows_text) {
            if (leaves_options_out(context, call, text, @intCast(index), count, previous)) {
                sink.report(
                    argument.span(),
                    "the argument is an empty literal; pass the options explicitly rather than " ++
                        "relying on the callee's defaults",
                );
            }
        }

        if (!follows_text) follows_text = carries_text(context, argument, text);

        previous = argument;
    }
}

fn leaves_options_out(
    context: *const Context,
    call: Call,
    text: []const u8,
    index: u32,
    count: u32,
    previous: ?View,
) bool {
    assert(index < count);

    const last = index + 1 == count;
    if (!names_empty_options(context, text, count, last)) return false;
    if (follows_an_argument_tuple(context, text, previous)) return false;
    return !fills_an_anytype(context, call, index, count);
}

fn follows_an_argument_tuple(context: *const Context, text: []const u8, previous: ?View) bool {
    const held = previous orelse return false;
    const head = prefix_before_ignoring_whitespace(text, empty_braces) orelse return false;
    if (scan.trim_ascii(head).len != 0) return false;

    const span = held.span();
    const open = context.lexer_index_from(span.offset);

    assert(span.end() <= context.source.len);

    if (open >= context.tokens.len) return false;
    if (!context.tokens[open].is_punctuation(.paren_open)) return false;

    const close = context.pairs.partner_of(open) orelse return false;

    assert(close > open);

    if (context.tokens[close].end() != span.end()) return false;
    if (close == open + 1) return true;

    var depth: u32 = 0;

    for (context.tokens[open + 1 .. close]) |token| {
        if (token.opens_a_group_or_block()) depth += 1;
        if (token.closes_a_group_or_block()) depth -|= 1;
        if (depth > 0) continue;
        if (token.is_punctuation(.comma)) return true;
    }

    return false;
}

fn fills_an_anytype(context: *const Context, call: Call, index: u32, count: u32) bool {
    assert(index < count);

    const named = call.name_token() orelse return false;
    const name = context.front_text(named);

    var agreed = false;

    for (context.tables.functions()) |*row| {
        if (row.name.length == 0) continue;
        if (!std.mem.eql(u8, context.span_text(row.name), name)) continue;

        const function = context.view(row.node).as_function() orelse continue;

        switch (filled_by(context, function, index, count)) {
            .unfit => {},
            .any => agreed = true,
            .typed => return false,
        }
    }

    return agreed;
}

fn filled_by(context: *const Context, function: Function, index: u32, count: u32) Filled {
    assert(index < count);

    var counted = function.parameters();
    var declared: u32 = 0;

    for (0..option_arguments_max + 1) |_| {
        _ = counted.next() orelse break;

        declared += 1;
    }

    if (declared < count) return .unfit;
    if (declared > count + 1) return .unfit;

    const target = index + declared - count;
    var parameters = function.parameters();

    assert(target < declared);

    for (0..target + 1) |position| {
        const parameter = parameters.next() orelse return .unfit;

        if (position < target) continue;

        const span = parameter.type_span orelse return .typed;
        if (std.mem.eql(u8, context.span_text(span), any_type)) return .any;
        return .typed;
    }

    return .unfit;
}

fn takes_a_context(context: *const Context, call: Call) bool {
    const suffixes = context.conventions.context_argument_suffixes;
    if (suffixes.len == 0) return false;

    const named = call.name_token() orelse return false;
    const name = context.front_text(named);

    assert(named < context.front.tokens().len);

    for (suffixes) |suffix| {
        assert(suffix.len > 0);

        if (std.mem.endsWith(u8, name, suffix)) return true;
    }

    return false;
}

fn stores_a_value(context: *const Context, call: Call) bool {
    const methods = context.conventions.stored_value_methods;
    if (methods.len == 0) return false;

    const named = call.name_token() orelse return false;

    assert(named < context.front.tokens().len);

    return scan.word_listed(methods, context.front_text(named));
}

fn compares_values(context: *const Context, call: Call) bool {
    const named = call.name_token() orelse return false;
    const name = context.front_text(named);

    assert(named < context.front.tokens().len);

    if (name.len == 0) return false;
    return support.names_a_value_comparison(name);
}

fn arguments_count(call: Call) u32 {
    var arguments = call.arguments();
    var count: u32 = 0;

    for (0..option_arguments_max) |_| {
        _ = arguments.next() orelse break;

        count += 1;
    }

    assert(count <= option_arguments_max);
    assert(call.view.category() == .call);

    return count;
}

fn carries_text(context: *const Context, argument: View, text: []const u8) bool {
    assert(text.len <= context.source.len);

    if (is_text_literal(context, argument)) return true;

    for (text_markers) |marker| {
        assert(marker.len > 0);

        if (std.mem.find(u8, text, marker) != null) return true;
    }

    return false;
}

fn is_text_literal(context: *const Context, argument: View) bool {
    const constant = argument.as_constant() orelse return false;

    assert(argument.span().end() <= context.source.len);
    assert(constant.view.index() == argument.index());

    return switch (constant.literal_class(context.source)) {
        .bytes, .template, .text => true,
        .boolean, .character, .nil, .number, .other, .regex => false,
    };
}

fn names_empty_options(context: *const Context, text: []const u8, count: u32, last: bool) bool {
    assert(count <= option_arguments_max);

    for (context.conventions.empty_option_suffixes) |suffix| {
        const prefix = prefix_before_ignoring_whitespace(text, suffix) orelse continue;
        const head = scan.trim_ascii(prefix);
        if (!is_a_path(head)) continue;
        if (std.mem.startsWith(u8, head, "&")) continue;

        if (head.len == 0) {
            if (std.mem.startsWith(u8, suffix, "::")) continue;

            if (std.mem.eql(u8, suffix, empty_braces)) {
                if (!context.conventions.empty_braces_spell_options) continue;
                if (!last) continue;
                if (count < 2) continue;
            }

            return true;
        }

        const word = if (std.mem.findLastAny(u8, head, ".:")) |at| head[at + 1 ..] else head;

        assert(word.len <= head.len);

        for (option_type_suffixes) |named| {
            if (std.mem.endsWith(u8, word, named)) return true;
        }
    }

    return false;
}

fn is_a_path(head: []const u8) bool {
    assert(head.len <= std.math.maxInt(u32));

    for (head) |byte| {
        if (scan.is_identifier_part(byte)) continue;
        if (std.mem.findScalar(u8, option_path_bytes, byte) == null) return false;
    }

    assert(std.mem.findScalar(u8, head, ' ') == null);

    return true;
}

fn prefix_before_ignoring_whitespace(text: []const u8, suffix: []const u8) ?[]const u8 {
    var cursor = text.len;

    assert(suffix.len > 0);

    for (0..suffix.len) |step| {
        const byte = suffix[suffix.len - 1 - step];

        for (0..option_whitespace_max) |_| {
            if (cursor == 0) break;
            if (!scan.is_ascii_whitespace(text[cursor - 1])) break;

            cursor -= 1;
        }

        if (cursor == 0) return null;
        if (text[cursor - 1] != byte) return null;

        cursor -= 1;
    }

    assert(cursor <= text.len);

    return text[0..cursor];
}

fn report_default_struct_updates(context: *const Context, sink: *Sink) void {
    const tokens = context.tokens;
    if (tokens.len < 2) return;

    for (0..tokens.len - 1) |position| {
        const index: u32 = @intCast(position);
        if (!tokens[index].is_punctuation(.dot)) continue;
        if (!std.mem.eql(u8, context.text(tokens[index]), update_marker)) continue;
        if (tokens[index + 1].kind != .identifier) continue;

        const close = default_call_end(context, index + 1) orelse continue;

        assert(close > index);
        assert(tokens[close].is_punctuation(.paren_close));

        if (!names_an_options_type(context, close - 4)) continue;

        sink.report(
            .between(tokens[index].offset, tokens[close].end()),
            "the literal fills its remaining fields from the defaults; spell every field",
        );
    }
}

fn names_an_options_type(context: *const Context, named: u32) bool {
    const token = context.tokens[named];
    const name = context.text(token);

    assert(token.kind == .identifier);
    assert(name.len > 0);

    if (scan.word_in(&default_type_names, name)) return true;

    for (option_type_suffixes) |suffix| {
        if (std.mem.endsWith(u8, name, suffix)) return true;
    }

    return false;
}

fn default_call_end(context: *const Context, start: u32) ?u32 {
    const tokens = context.tokens;
    var cursor = start;

    assert(start < tokens.len);

    for (0..option_path_segments_max) |_| {
        if (cursor + 2 >= tokens.len) break;
        if (!context.is_path_separator(tokens[cursor + 1])) break;
        if (tokens[cursor + 2].kind != .identifier) break;

        cursor += 2;
    }

    if (cursor == start) return null;
    if (!std.mem.eql(u8, context.text(tokens[cursor]), default_word)) return null;
    if (cursor + 2 >= tokens.len) return null;
    if (!tokens[cursor + 1].is_punctuation(.paren_open)) return null;
    if (!tokens[cursor + 2].is_punctuation(.paren_close)) return null;

    assert(cursor > start);

    return cursor + 2;
}

test "an odin empty literal without a type name is a value rather than options" {
    const bare = "package fixture\n\nrun :: proc(items: []int) {\n    collect(items, {})\n}\n";

    const typed = "package fixture\n\nrun :: proc(items: []int) {\n" ++
        "    collect(items, Options{})\n}\n";

    try testing.expect_quiet(@This(), .odin, bare);

    var findings = try testing.analyze(@This(), .odin, typed);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
}

test "a struct update from the defaults is reported" {
    const source = "fn f() -> Style {\n    Style { bold: true, ..Default::default() }\n}\n";

    try testing.expect_anchors(@This(), .rust, source, &.{.{ 2, 25 }});
}

test "a struct update from a named type reports only for an options type" {
    const source = "fn f() -> Profile {\n    Profile {\n        name: 1,\n" ++
        "        ..Profile::default()\n    }\n}\n\nfn g() -> Options {\n    Options {\n" ++
        "        name: 1,\n        ..Self::default()\n    }\n}\n\nfn h() -> RenderOptions {\n" ++
        "    RenderOptions {\n        name: 1,\n        ..RenderOptions::default()\n    }\n}\n";

    try testing.expect_anchors(@This(), .rust, source, &.{ .{ 11, 9 }, .{ 18, 9 } });
}

test "an empty literal between other arguments still reports" {
    const source = "fn run(value: Value, writer: Writer) !void {\n" ++
        "    try std.json.stringify(value, .{}, writer);\n}\n";

    try testing.expect_anchors(@This(), .zig, source, &.{.{ 2, 35 }});
}

test "an empty literal to a context method builds the context" {
    const source = "fn run(map: *Map) void {\n    _ = map.getContext(1, .{});\n" ++
        "    _ = map.getAdapted(1, .{});\n    _ = map.fetch(1, .{});\n}\n";

    try testing.expect_anchors(@This(), .zig, source, &.{.{ 4, 22 }});
}

test "an empty literal stored into a container is a value rather than options" {
    const source = "fn run(map: *Map, list: *List) !void {\n" ++
        "    _ = try map.getOrPutValue(gpa, 1, .{});\n    try list.append(gpa, .{});\n" ++
        "    _ = try map.fetch(gpa, 1, .{});\n}\n";

    try testing.expect_anchors(@This(), .zig, source, &.{.{ 4, 31 }});
}

test "an empty literal filling an anytype parameter is an empty tuple rather than options" {
    const source = "fn err(p: *Parser, token: u32, args: anytype) void {\n    _ = p;\n" ++
        "    _ = token;\n    _ = args;\n}\n\nfn open(p: *Parser, options: Options) void {\n" ++
        "    _ = p;\n    _ = options;\n}\n\nfn run(p: *Parser) void {\n    p.err(1, .{});\n" ++
        "    p.open(.{});\n}\n";

    try testing.expect_anchors(@This(), .zig, source, &.{.{ 14, 12 }});
}

test "an empty literal an anytype might fill reports while a namesake declares a type there" {
    const source = "fn write(w: *Writer, args: anytype) void {\n    _ = w;\n    _ = args;\n}\n\n" ++
        "const Value = struct {\n    fn write(value: Value, options: Options) void {\n" ++
        "        _ = value;\n        _ = options;\n    }\n};\n\n" ++
        "fn run(value: Value) void {\n    value.write(.{});\n}\n";

    try testing.expect_anchors(@This(), .zig, source, &.{.{ 14, 17 }});
}

test "an empty literal a comparison is handed is the value it compares" {
    const python = "def run(self, form, url):\n    self.assertEqual(form.errors, {})\n" ++
        "    self.assertNotEqual(form.data, {})\n    configure(url, {})\n";

    const javascript = "function run(result, url) {\n    assert.deepEqual(result, {});\n" ++
        "    configure(url, {});\n}\n";

    try testing.expect_anchors(@This(), .python, python, &.{.{ 4, 20 }});
    try testing.expect_anchors(@This(), .javascript, javascript, &.{.{ 3, 20 }});
}

test "an odin literal a value comparison is handed is the value it compares" {
    const source = "package p\n\nrun :: proc(t: ^testing.T, rex: Regex) {\n" ++
        "\ttesting.expect_value(t, rex.flags, regex.Flags{})\n" ++
        "\tcompile(rex.pattern, regex.Flags{})\n}\n";

    try testing.expect_anchors(@This(), .odin, source, &.{.{ 5, 23 }});
}

test "an empty dict after an argument tuple is the keyword half of the pair" {
    const source = "def run(middleware, request, view, args):\n" ++
        "    middleware.process_view(request, view, (), {})\n" ++
        "    record((request,), {})\n    middleware.process_view(request, view, args, {})\n" ++
        "    record((request), {})\n";

    try testing.expect_anchors(@This(), .python, source, &.{ .{ 4, 50 }, .{ 5, 23 } });
}

test "a default a python mapping returns or stores is a value rather than options" {
    const source = "def run(cache, requested, name, url):\n    cache.setdefault(name, {})\n" ++
        "    requested.get(name, {})\n    configure(url, {})\n";

    try testing.expect_anchors(@This(), .python, source, &.{.{ 4, 20 }});
}

test "an empty literal first among arguments still reports" {
    const source = "fn run() void {\n    _ = std.Thread.spawn(.{}, work, .{});\n}\n";

    try testing.expect_anchors(@This(), .zig, source, &.{ .{ 2, 26 }, .{ 2, 37 } });
}
