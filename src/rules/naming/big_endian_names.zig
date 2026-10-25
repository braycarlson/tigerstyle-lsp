const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const naming = @import("../naming.zig");
const scan = @import("../../scan.zig");
const testing = @import("../testing.zig");
const Context = @import("../context.zig");
const Declaration = Declarations.Declaration;
const Declarations = @import("../declarations.zig");
const Frame = @import("../frame.zig");
const Lowered = naming.Lowered;
const NameKind = Declarations.NameKind;
const Rule = scylla.rule.Rule;
const Sink = scylla.rule.Sink;
const word_in = scan.word_in;
const words_module = @import("../../words.zig");

pub const rule: Rule = .{
    .citations = &.{
        .{
            .standard = "TigerStyle",
            .text = "\"Add units or qualifiers to variable names, and put the units or " ++
                "qualifiers last, sorted by descending significance, so that the variable " ++
                "starts with the most significant word, and ends with the least significant " ++
                "word. For example, `latency_ms_max` rather than `max_latency_ms`.\"",
        },
    },
    .code = "TS025",
    .default_on = true,
    .description = "A name is ordered from most significant word to least, so related names " ++
        "sort and read together.",
    .explanation = "",
    .fix_title = "",
    .fixable = .sometimes,
    .group = .stable,
    .name = "big-endian-names",
    .severity = .information,
    .summary = "Qualifiers go last: `latency_ms_max`, never `max_latency_ms`",
    .url = "",
};

const Misordered = struct {
    earlier: []const u8,
    later: []const u8,
};

const Ranked = struct {
    tier: u8,
    word: []const u8,
};

const Squashed = struct {
    bytes: [naming.name_bytes_max]u8,
    length: u32,

    fn of(text: []const u8) ?Squashed {
        var squashed: Squashed = .{ .bytes = @splat(0), .length = 0 };

        for (text) |byte| {
            if (!std.ascii.isAlphanumeric(byte)) continue;
            if (squashed.length == naming.name_bytes_max) return null;

            squashed.bytes[squashed.length] = std.ascii.toLower(byte);
            squashed.length += 1;
        }

        assert(squashed.length <= naming.name_bytes_max);
        assert(squashed.length <= text.len);

        return squashed;
    }

    fn slice(squashed: *const Squashed) []const u8 {
        assert(squashed.length <= naming.name_bytes_max);

        return squashed.bytes[0..squashed.length];
    }
};

const attribute_line_count_max: u32 = 16;
const attribute_openings = [_][]const u8{ "#[", "#![" };

const bound_words = [_][]const u8{
    "average",
    "avg",
    "cur",
    "current",
    "first",
    "initial",
    "last",
    "max",
    "maximum",
    "mean",
    "min",
    "minimum",
    "new",
    "next",
    "num",
    "old",
    "previous",
    "sum",
    "total",
};

const leading_measures = [_][]const u8{ "index", "offset", "size" };
const measure_words = [_][]const u8{ "count", "index", "len", "length", "n", "offset", "size" };
const serde_markers = [_][]const u8{ "Deserialize", "Serialize", "serde(" };
const tier_bound: u8 = 3;
const tier_measure: u8 = 1;
const tier_unit: u8 = 2;
const unit_words = [_][]const u8{ "bytes", "ms", "ns", "us" };
const verb_qualifiers = [_][]const u8{ "average", "count", "new", "next", "sum", "total" };

comptime {
    assert(tier_measure < tier_unit);
    assert(tier_unit < tier_bound);
}

pub fn run(context: *const Context, sink: *Sink) void {
    var names = naming.names_of(context);

    for (0..names.count_max()) |_| {
        const declaration = names.next() orelse break;

        assert(declaration.token < context.tokens.len);

        if (declaration.kind == .type) continue;
        if (naming.stub_dictates(context, &declaration)) continue;

        name_check(context, sink, &declaration);
    }
}

fn name_check(context: *const Context, sink: *Sink, declaration: *const Declaration) void {
    assert(declaration.kind != .type);
    assert(declaration.token < context.tokens.len);

    const token = context.tokens[declaration.token];
    const name = context.text(token);
    if (std.mem.startsWith(u8, name, "_")) return;

    if (declaration.field) {
        if (serde_contract(context, declaration.token)) return;
    }

    if (leading_qualifier(name, declaration.kind)) |leading| {
        if (names_its_own_type(context, declaration, name)) return;

        sink.report_formatted(
            token.span(),
            "the name leads with the qualifier {s}; put it last",
            .{scan.utf8_or(leading, "the word")},
        );

        return;
    }

    const misordered = misordered_qualifiers(name) orelse return;

    sink.report_formatted(
        token.span(),
        "the name puts {s} before {s}; order the qualifiers by descending significance, " ++
            "as in latency_ms_max",
        .{
            scan.utf8_or(misordered.earlier, "the word"),
            scan.utf8_or(misordered.later, "the word"),
        },
    );
}

fn leading_qualifier(name: []const u8, kind: NameKind) ?[]const u8 {
    var words = words_module.word_parts(name);
    const first = words.next() orelse return null;

    if (words.next() == null) return null;

    const lowered: Lowered = .of(first);
    const word = lowered.text();

    assert(first.len > 0);
    assert(first.len < name.len);

    if (word_in(&leading_measures, word)) return null;

    if (kind == .function) {
        if (word_in(&verb_qualifiers, word)) return null;
    }

    const tier = tier_of(word) orelse return null;
    if (outranks_the_rest(name, tier)) return null;
    return first;
}

fn outranks_the_rest(name: []const u8, tier: u8) bool {
    assert(tier >= tier_measure);
    assert(tier <= tier_bound);

    var words = words_module.word_parts(name);
    const first = words.next() orelse return false;

    assert(first.len < name.len);

    for (0..name.len) |_| {
        const word = words.next() orelse return true;
        const lowered: Lowered = .of(word);
        const later = tier_of(lowered.text()) orelse return false;
        if (later <= tier) return false;
    }

    return true;
}

fn misordered_qualifiers(name: []const u8) ?Misordered {
    var words = words_module.word_parts(name);
    var highest: ?Ranked = null;

    for (0..name.len) |_| {
        const word = words.next() orelse break;
        const lowered: Lowered = .of(word);
        const tier = tier_of(lowered.text()) orelse continue;

        assert(tier >= tier_measure);
        assert(tier <= tier_bound);

        if (highest) |seen| {
            if (tier < seen.tier) return .{ .earlier = seen.word, .later = word };
            if (tier == seen.tier) continue;
        }

        highest = .{ .tier = tier, .word = word };
    }

    return null;
}

fn tier_of(word: []const u8) ?u8 {
    assert(word.len <= naming.word_bytes_max);

    if (word_in(&bound_words, word)) return tier_bound;
    if (word_in(&unit_words, word)) return tier_unit;
    if (word_in(&measure_words, word)) return tier_measure;
    return null;
}

fn names_its_own_type(
    context: *const Context,
    declaration: *const Declaration,
    name: []const u8,
) bool {
    assert(name.len > 0);

    const spelled = declaration.node.type_of() orelse return false;
    const declared = Squashed.of(spelled.text(context.source)) orelse return false;
    const wanted = Squashed.of(name) orelse return false;
    if (wanted.length == 0) return false;

    assert(wanted.length <= name.len);

    return scan.find(declared.slice(), wanted.slice()) != null;
}

fn serde_contract(context: *const Context, token: u32) bool {
    assert(token < context.tokens.len);

    const container = enclosing_type(context, token) orelse return false;

    var line = context.line_of(context.tokens[container].offset);

    for (0..attribute_line_count_max) |_| {
        if (line == 0) return false;

        line -= 1;

        assert(line < context.line_count());

        const text = scan.trim_ascii(context.line_text(line));
        if (!opens_an_attribute(text)) return false;

        for (serde_markers) |marker| {
            if (scan.find(text, marker) != null) return true;
        }
    }

    return false;
}

fn opens_an_attribute(text: []const u8) bool {
    assert(std.mem.findScalar(u8, text, '\n') == null);

    for (attribute_openings) |opening| {
        if (std.mem.startsWith(u8, text, opening)) return true;
    }

    return false;
}

fn enclosing_type(context: *const Context, token: u32) ?u32 {
    assert(token < context.tokens.len);

    var frames = Frame.covering(context, token);

    for (0..context.front.node_count()) |_| {
        const covering = frames.next() orelse return null;
        if (covering.view.category() != .@"struct") continue;
        if (covering.frame.end == null) continue;
        if (token <= covering.frame.start) continue;

        assert(covering.frame.header < context.tokens.len);

        return covering.frame.header;
    }

    return null;
}

fn expect_count(language: scylla.Language, source: []const u8, expected: u32) !void {
    assert(source.len > 0);
    assert(expected <= testing.limits.diagnostic_count_max);

    var findings = try testing.analyze(@This(), language, source);
    defer findings.deinit();

    if (findings.count() != expected) findings.print();

    try std.testing.expectEqual(expected, findings.count());
}

fn expect_named(name: []const u8, expected: u32) !void {
    assert(name.len > 0);

    const gpa = std.testing.allocator;
    const source = try gpa.print("fn f() {{\n    let {s} = 1;\n}}\n", .{name});
    defer gpa.free(source);

    try expect_count(.rust, source, expected);
}

test "a name a python stub declares is the runtime's spelling" {
    try testing.expect_stub_names(@This(), testing.stub_source, &.{"max_width"});

    var module = try testing.analyze(@This(), .python, testing.stub_source);
    defer module.deinit();

    if (module.count() != 3) module.print();

    try std.testing.expectEqual(@as(u32, 3), module.count());
}

test "a python annotated declaration is a declaration" {
    try expect_count(.python, "class Adapter:\n    max_retries: Retry\n", 1);
}

test "a python annotated binding is a declaration" {
    try expect_count(.python, "old_value: str | None = None\n", 1);
}

test "a little endian name is reported" {
    var findings = try testing.analyze(
        @This(),
        .rust,
        "fn f() {\n    let max_connection_delay = 1;\n}\n",
    );

    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
    try std.testing.expect(std.mem.find(u8, findings.message(0), "max") != null);
}

test "a big endian name is quiet" {
    try testing.expect_quiet(@This(), .rust, "fn f() {\n    let connection_delay_max = 1;\n}\n");
}

test "a camel case qualifier leads without an underscore" {
    const source = "package main\n\nfunc run() int {\n\tmaxSize := 1\n\tMaxRetries := 3\n" ++
        "\treturn maxSize + MaxRetries\n}\n";

    try expect_count(.go, source, 2);
}

test "every qualifier the standard names is known" {
    const reported = [_][]const u8{
        "count_items",
        "len_items",
        "first_index",
        "n_items",
        "sum_total",
    };

    const quiet = [_][]const u8{
        "latency_ms_max",
        "items_count",
        "index_first",
        "size_max",
        "max",
    };

    for (reported) |name| try expect_named(name, 1);
    for (quiet) |name| try expect_named(name, 0);
}

test "a qualifier that outranks every later word is the subject" {
    const reported = [_][]const u8{
        "bytes_count",
        "count_items_max",
        "max_count",
        "minimum_count",
    };

    const quiet = [_][]const u8{
        "bytes_max",
        "count_max",
        "count_maximum",
        "count_new",
        "length_bytes_max",
    };

    for (reported) |name| try expect_named(name, 1);
    for (quiet) |name| try expect_named(name, 0);
}

test "a unit after a bound is misordered" {
    const source = "fn f() {\n    let latency_max_ms = 1;\n    let buffer_max_size = 2;\n}\n";

    var findings = try testing.analyze(@This(), .rust, source);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 2), findings.count());
    try std.testing.expect(std.mem.find(u8, findings.message(0), "max before ms") != null);
}

test "a function name leads with a qualifier unless it is a verb" {
    try expect_count(.rust, "fn max_connections() {}\n\nfn count_items() {}\n", 1);
}

test "a python attribute assignment declares a field once" {
    const source = "class Held:\n    def __init__(self):\n        self.max_count = 1\n\n" ++
        "    def reset(self):\n        self.max_count = 0\n";

    try expect_count(.python, source, 1);
}
