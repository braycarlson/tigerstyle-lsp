const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const naming = @import("../naming.zig");
const scan = @import("../../scan.zig");
const support = @import("../support.zig");
const testing = @import("../testing.zig");
const Context = @import("../context.zig");
const Declaration = Declarations.Declaration;
const Declarations = @import("../declarations.zig");
const Lowered = naming.Lowered;
const Rule = scylla.rule.Rule;
const Sink = scylla.rule.Sink;
const Span = scylla.Span;
const Token = scylla.Token;
const View = scylla.View;
const word_in = scan.word_in;
const words_module = @import("../../words.zig");

pub const rule: Rule = .{
    .citations = &.{
        .{
            .standard = "TigerStyle",
            .text = "\"Do not abbreviate variable names, unless the variable is a primitive " ++
                "integer type used as an argument to a sort function or matrix calculation. Use " ++
                "long form arguments in scripts: `--force`, not `-f`. Single letter flags are " ++
                "for interactive usage.\"",
        },
    },
    .code = "TS037",
    .default_on = false,
    .description = "A name spells its words out, because an abbreviation saves a few characters " ++
        "and costs every later reader.",
    .explanation = "",
    .fix_title = "",
    .fixable = .sometimes,
    .group = .stable,
    .name = "no-abbreviations",
    .severity = .information,
    .summary = "Do not abbreviate names",
    .url = "",
};

const Abbreviation = struct {
    long: []const u8,
    short: []const u8,
};

const abbreviations = [_]Abbreviation{
    .{ .short = "abs", .long = "absolute" },
    .{ .short = "acc", .long = "accumulator" },
    .{ .short = "addr", .long = "address" },
    .{ .short = "arg", .long = "argument" },
    .{ .short = "args", .long = "arguments" },
    .{ .short = "attr", .long = "attribute" },
    .{ .short = "attrs", .long = "attributes" },
    .{ .short = "auth", .long = "authentication" },
    .{ .short = "btn", .long = "button" },
    .{ .short = "buf", .long = "buffer" },
    .{ .short = "bufs", .long = "buffers" },
    .{ .short = "calc", .long = "calculate" },
    .{ .short = "cb", .long = "callback" },
    .{ .short = "cfg", .long = "configuration" },
    .{ .short = "chan", .long = "channel" },
    .{ .short = "cnt", .long = "count" },
    .{ .short = "col", .long = "column" },
    .{ .short = "cols", .long = "columns" },
    .{ .short = "conf", .long = "configuration" },
    .{ .short = "ctx", .long = "context" },
    .{ .short = "cur", .long = "cursor" },
    .{ .short = "curr", .long = "current" },
    .{ .short = "desc", .long = "description" },
    .{ .short = "dest", .long = "destination" },
    .{ .short = "dict", .long = "dictionary" },
    .{ .short = "dir", .long = "directory" },
    .{ .short = "dst", .long = "destination" },
    .{ .short = "elem", .long = "element" },
    .{ .short = "elems", .long = "elements" },
    .{ .short = "env", .long = "environment" },
    .{ .short = "err", .long = "error" },
    .{ .short = "errs", .long = "errors" },
    .{ .short = "evt", .long = "event" },
    .{ .short = "expr", .long = "expression" },
    .{ .short = "ext", .long = "extension" },
    .{ .short = "fmt", .long = "format" },
    .{ .short = "fns", .long = "functions" },
    .{ .short = "gen", .long = "generate" },
    .{ .short = "hdr", .long = "header" },
    .{ .short = "idx", .long = "index" },
    .{ .short = "img", .long = "image" },
    .{ .short = "impl", .long = "implementation" },
    .{ .short = "info", .long = "information" },
    .{ .short = "init", .long = "initialize" },
    .{ .short = "inst", .long = "instance" },
    .{ .short = "iter", .long = "iterator" },
    .{ .short = "len", .long = "length" },
    .{ .short = "lst", .long = "list" },
    .{ .short = "mem", .long = "memory" },
    .{ .short = "mgr", .long = "manager" },
    .{ .short = "mod", .long = "module" },
    .{ .short = "msg", .long = "message" },
    .{ .short = "msgs", .long = "messages" },
    .{ .short = "num", .long = "number" },
    .{ .short = "obj", .long = "object" },
    .{ .short = "objs", .long = "objects" },
    .{ .short = "opt", .long = "option" },
    .{ .short = "opts", .long = "options" },
    .{ .short = "param", .long = "parameter" },
    .{ .short = "params", .long = "parameters" },
    .{ .short = "pkg", .long = "package" },
    .{ .short = "pos", .long = "position" },
    .{ .short = "prev", .long = "previous" },
    .{ .short = "proc", .long = "process" },
    .{ .short = "prop", .long = "property" },
    .{ .short = "props", .long = "properties" },
    .{ .short = "ptr", .long = "pointer" },
    .{ .short = "qty", .long = "quantity" },
    .{ .short = "recv", .long = "receive" },
    .{ .short = "ref", .long = "reference" },
    .{ .short = "refs", .long = "references" },
    .{ .short = "req", .long = "request" },
    .{ .short = "reqs", .long = "requests" },
    .{ .short = "res", .long = "result" },
    .{ .short = "resp", .long = "response" },
    .{ .short = "ret", .long = "returned" },
    .{ .short = "sep", .long = "separator" },
    .{ .short = "seq", .long = "sequence" },
    .{ .short = "sig", .long = "signature" },
    .{ .short = "spec", .long = "specification" },
    .{ .short = "src", .long = "source" },
    .{ .short = "str", .long = "string" },
    .{ .short = "sync", .long = "synchronize" },
    .{ .short = "tbl", .long = "table" },
    .{ .short = "tmp", .long = "temporary" },
    .{ .short = "txt", .long = "text" },
    .{ .short = "typ", .long = "type" },
    .{ .short = "usr", .long = "user" },
    .{ .short = "val", .long = "value" },
    .{ .short = "vals", .long = "values" },
    .{ .short = "var", .long = "variable" },
    .{ .short = "vars", .long = "variables" },
    .{ .short = "vec", .long = "vector" },
};

const arguments_scanned_max: u32 = 64;
const comparator_words = [_][]const u8{ "cmp", "compare", "dot", "less", "matrix", "mul", "sort" };
const dictated_names = [_][]const u8{"init"};
const enum_parser = "stringToEnum(";
const keyword_word = "keyword";
const lifetime_mark = "'";
const membership_word = "in";
const payload_bar = "|";
const payload_token_count_max: u32 = 16;
const short_name_bytes_max: u32 = 2;

const short_words = [_][]const u8{
    "at",
    "by",
    "do",
    "go",
    "if",
    "in",
    "is",
    "it",
    "no",
    "of",
    "ok",
    "on",
    "or",
    "so",
    "to",
    "up",
    "us",
    "we",
};

comptime {
    for (abbreviations) |abbreviation| {
        assert(abbreviation.short.len <= naming.word_bytes_max);
        assert(abbreviation.short.len < abbreviation.long.len);
    }
}

pub fn run(context: *const Context, sink: *Sink) void {
    var names = naming.names_of(context);

    for (0..names.count_max()) |_| {
        const declaration = names.next() orelse break;

        assert(declaration.token < context.tokens.len);

        if (declaration.kind == .type) continue;
        if (naming.stub_dictates(context, &declaration)) continue;

        if (declaration.kind == .function) {
            if (support.implements_a_trait(context, declaration.token)) continue;
        }

        name_check(context, sink, &declaration);
    }
}

fn name_check(context: *const Context, sink: *Sink, declaration: *const Declaration) void {
    assert(declaration.kind != .type);
    assert(declaration.token < context.tokens.len);

    const token = context.tokens[declaration.token];
    const name = context.text(token);
    const trimmed = naming.trimmed_underscores(name);
    if (trimmed.len == 0) return;
    if (word_in(&dictated_names, trimmed)) return;
    if (support.names_the_data_model(context, name)) return;

    const abbreviated = abbreviation_in(context, trimmed);

    if (abbreviated == null) {
        if (trimmed.len > short_name_bytes_max) return;
    }

    if (naming.aliases_a_foreign_name(context, declaration, name)) return;
    if (names_a_type(context, trimmed)) return;
    if (parses_its_names(context, declaration)) return;

    if (abbreviated) |abbreviation| {
        sink.report_formatted(token.span(), "the name abbreviates {s}; write {s} out", .{
            scan.utf8_or(abbreviation.short, "the word"),
            abbreviation.long,
        });

        return;
    }

    assert(trimmed.len <= short_name_bytes_max);

    if (short_name_exempt(context, declaration, trimmed)) return;

    sink.report_formatted(
        token.span(),
        "the name {s} is too short to spell a word; write the word out",
        .{scan.utf8_or(trimmed, "the word")},
    );
}

fn names_a_type(context: *const Context, name: []const u8) bool {
    assert(name.len > 0);
    assert(name.len <= context.source.len);

    if (!context.conventions.types_are_values) return false;
    if (std.ascii.isUpper(name[0])) return true;
    return support.is_primitive_type(context, name);
}

fn parses_its_names(context: *const Context, declaration: *const Declaration) bool {
    if (!declaration.field) return false;

    const container = declaration.node.ancestor_of(.@"struct") orelse return false;
    const held = container.as_container() orelse return false;
    const named = held.name_token() orelse return false;
    const name = context.front_text(named);

    assert(container.index() < declaration.node.index());
    assert(name.len > 0);

    var rest = context.source;

    for (0..context.source.len) |_| {
        const found = scan.find(rest, enum_parser) orelse return false;
        const after = rest[found + enum_parser.len ..];

        if (std.mem.startsWith(u8, after, name)) {
            if (after.len > name.len) {
                if (after[name.len] == ',') return true;
            }
        }

        rest = after;
    }

    return false;
}

fn abbreviation_in(context: *const Context, trimmed: []const u8) ?*const Abbreviation {
    assert(trimmed.len > 0);

    var words = words_module.word_parts(trimmed);
    var pending: ?*const Abbreviation = null;

    for (0..trimmed.len) |_| {
        const word = words.next() orelse break;
        const lowered: Lowered = .of(word);

        assert(word.len > 0);

        if (pending) |held| {
            if (!std.mem.eql(u8, lowered.text(), keyword_word)) return held;
        }

        pending = abbreviation_of(context, lowered.text());
    }

    return pending;
}

fn abbreviation_of(context: *const Context, word: []const u8) ?*const Abbreviation {
    assert(word.len > 0);

    for (&abbreviations) |*abbreviation| {
        if (!std.mem.eql(u8, abbreviation.short, word)) continue;
        if (scan.word_listed(context.conventions.reserved_words, abbreviation.long)) return null;

        assert(abbreviation.long.len > 0);

        return abbreviation;
    }

    return null;
}

fn short_name_exempt(
    context: *const Context,
    declaration: *const Declaration,
    trimmed: []const u8,
) bool {
    assert(trimmed.len > 0);
    assert(trimmed.len <= short_name_bytes_max);

    const lowered: Lowered = .of(trimmed);
    if (word_in(&short_words, lowered.text())) return true;

    if (naming.acronym_length(lowered.text())) |length| {
        if (length == trimmed.len) return true;
    }

    if (loop_header_binds(context, declaration)) return true;
    if (rebinds_a_loop_variable(context, declaration, trimmed)) return true;

    if (declaration.parameter) {
        if (compares(context, declaration.node)) return true;
    }

    return indexes(context, declaration.node, trimmed);
}

fn loop_header_binds(context: *const Context, declaration: *const Declaration) bool {
    const node = declaration.node;
    if (node.category() != .loop) return naming.enclosing_loop(node) != null;
    return !binds_in_an_else(context, declaration.token);
}

fn rebinds_a_loop_variable(
    context: *const Context,
    declaration: *const Declaration,
    name: []const u8,
) bool {
    assert(name.len > 0);

    if (!context.conventions.bindings_outlive_blocks) return false;

    var ancestors = declaration.node.ancestors();

    for (0..ancestors.remaining + 1) |_| {
        const parent = ancestors.next() orelse return false;
        if (parent.category() == .function) return false;
        if (parent.category() != .loop) continue;
        if (loop_header_names(context, parent, name)) return true;
    }

    return false;
}

fn loop_header_names(context: *const Context, loop: View, name: []const u8) bool {
    assert(loop.category() == .loop);

    var children = loop.children();
    var end = loop.span().end();

    for (0..children.remaining) |_| {
        const child = children.next() orelse break;
        if (child.category() != .block) continue;

        end = child.span().offset;

        break;
    }

    const start = loop.span().offset;

    assert(start <= end);

    const header: Span = .{ .length = end - start, .offset = start };

    var named = false;

    for (context.tokens_in(header)) |token| {
        const text = context.text(token);
        if (std.mem.eql(u8, text, membership_word)) return named;
        if (token.kind != .identifier) continue;

        if (std.mem.eql(u8, text, name)) named = true;
    }

    return false;
}

fn binds_in_an_else(context: *const Context, name: u32) bool {
    assert(name < context.tokens.len);

    var cursor = name;

    for (0..payload_token_count_max) |_| {
        const before = context.significant_before(cursor) orelse return false;
        const token = context.tokens[before];

        if (std.mem.eql(u8, context.text(token), payload_bar)) {
            const opener = context.significant_before(before) orelse return false;
            return context.tokens[opener].is_keyword(.branch_else);
        }

        if (!payload_token(token)) return false;

        cursor = before;
    }

    return false;
}

fn payload_token(token: Token) bool {
    if (token.kind == .identifier) return true;
    if (token.is_punctuation(.comma)) return true;
    return token.is_punctuation(.star);
}

fn compares(context: *const Context, node: View) bool {
    const text = function_name_of(context, node) orelse callee_of(context, node) orelse
        return false;

    assert(text.len <= context.source.len);

    if (names_a_comparator(text)) return true;

    const called = lambda_call_name_of(context, node) orelse return false;
    return names_a_comparator(called);
}

fn names_a_comparator(text: []const u8) bool {
    assert(text.len <= std.math.maxInt(u32));

    for (comparator_words) |word| {
        if (scan.contains_folded(text, word)) return true;
    }

    return false;
}

fn function_name_of(context: *const Context, node: View) ?[]const u8 {
    const function = node.ancestor_of(.function) orelse return null;
    const callable = function.as_function() orelse return null;
    const named = callable.name_token() orelse return null;

    assert(function.index() < node.index());

    return context.front_text(named);
}

fn callee_of(context: *const Context, node: View) ?[]const u8 {
    const call = node.ancestor_of(.call) orelse return null;
    const invoked = call.as_call() orelse return null;
    const callee = invoked.callee() orelse return null;

    assert(call.index() < node.index());

    return callee.text(context.source);
}

fn lambda_call_name_of(context: *const Context, node: View) ?[]const u8 {
    const lambda = lambda_owning(node) orelse return null;
    const call = lambda.ancestor_of(.call) orelse return null;
    const invoked = call.as_call() orelse return null;
    const named = invoked.name_token() orelse return null;
    const span = lambda.span();
    var arguments = invoked.arguments();

    assert(call.index() < lambda.index());

    for (0..arguments_scanned_max) |_| {
        const argument = arguments.next() orelse return null;
        const held = argument.span();
        if (held.offset > span.offset) return null;
        if (held.end() >= span.end()) return context.front_text(named);
    }

    return null;
}

fn lambda_owning(node: View) ?View {
    if (node.category() == .lambda) return node;

    const lambda = node.ancestor_of(.lambda) orelse return null;
    const function = node.ancestor_of(.function) orelse return lambda;

    assert(function.index() != lambda.index());

    if (function.index() > lambda.index()) return null;
    return lambda;
}

fn indexes(context: *const Context, node: View, name: []const u8) bool {
    assert(name.len > 0);

    const tokens = context.tokens;
    const whole: Span = .{ .offset = 0, .length = @intCast(context.source.len) };
    const span = if (naming.enclosing_body(node)) |owner| owner.span() else whole;
    const start = context.lexer_index_from(span.offset);
    const end = @min(context.lexer_index_from(span.end()), tokens.len);

    assert(start <= tokens.len);

    for (start..end) |index| {
        if (!tokens[index].is_punctuation(.bracket_open)) continue;

        const partner = context.pairs.partner_of(@intCast(index)) orelse continue;
        if (partner <= index) continue;
        if (partner > end) continue;

        for (tokens[index + 1 .. partner], index + 1..) |held, position| {
            if (held.kind != .identifier) continue;
            if (names_a_lifetime(context, @intCast(position))) continue;
            if (std.mem.eql(u8, context.text(held), name)) return true;
        }
    }

    return false;
}

fn names_a_lifetime(context: *const Context, index: u32) bool {
    assert(index > 0);
    assert(index < context.tokens.len);

    const mark = context.tokens[index - 1];
    if (mark.end() != context.tokens[index].offset) return false;
    return std.mem.eql(u8, context.text(mark), lifetime_mark);
}

fn expect_count(language: scylla.Language, source: []const u8, expected: u32) !void {
    assert(source.len > 0);
    assert(expected <= testing.limits.diagnostic_count_max);

    var findings = try testing.analyze(@This(), language, source);
    defer findings.deinit();

    if (findings.count() != expected) findings.print();

    try std.testing.expectEqual(expected, findings.count());
}

fn expect_message(findings: *const testing.Findings, index: u32, text: []const u8) !void {
    assert(text.len > 0);

    if (std.mem.find(u8, findings.message(index), text) != null) return;

    findings.print();

    return error.TestUnexpectedMessage;
}

test "a name a python stub declares is the runtime's spelling" {
    try testing.expect_stub_names(@This(), testing.stub_source, &.{"obj"});

    var module = try testing.analyze(@This(), .python, testing.stub_source);
    defer module.deinit();

    if (module.count() != 3) module.print();

    try std.testing.expectEqual(@as(u32, 3), module.count());
}

test "a trait method name belongs to the trait" {
    const source = "impl fmt::Display for Error {\n" ++
        "    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {\n" ++
        "        formatter.write_str(\"error\")\n    }\n}\n\n" ++
        "fn fmt(value: u32) -> u32 {\n    value\n}\n";

    var findings = try testing.analyze(@This(), .rust, source);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
    try expect_message(&findings, 0, "fmt");
}

test "an abbreviated name is reported" {
    var findings = try testing.analyze(@This(), .python, "def read(self):\n    idx_value = 1\n");
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
    try expect_message(&findings, 0, "idx");
}

test "a spelled name is quiet" {
    try testing.expect_quiet(@This(), .python, "def read(self):\n    index_value = 1\n");
}

test "a short name is reported outside the exemptions" {
    const source = "fn f() {\n    let x = 1;\n    let ok = 2;\n}\n";

    var findings = try testing.analyze(@This(), .rust, source);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 2), findings.count());
    try expect_message(&findings, 0, "f is too short");
    try expect_message(&findings, 1, "x is too short");
}

test "a loop counter an index and a comparator argument may be short" {
    const source = "package main\n\nfunc sort_pair(a int, b int) bool {\n" ++
        "\tfor i := 0; i < 10; i++ {\n\t\tuse(i)\n\t}\n\tj := 0\n\tuse(held[j])\n" ++
        "\treturn a < b\n}\n";

    try expect_count(.go, source, 0);
}

test "a lambda handed to a sort call may name its arguments short" {
    const rust = "fn order(values: &mut Vec<u32>) {\n    values.sort_by(|a, b| a.cmp(b));\n" ++
        "    sort_by(values, |a, b| a.cmp(b));\n    values.retain(|v| v > 0);\n}\n";

    const python = "def order(values):\n    values.sort(key=lambda a: a)\n" ++
        "    sorted(values, key=lambda a: a)\n    filter(lambda v: v, values)\n";

    try testing.expect_anchors(@This(), .rust, rust, &.{.{ 4, 20 }});
    try testing.expect_anchors(@This(), .python, python, &.{.{ 4, 19 }});
}

test "a zig loop capture is the variable a loop header binds" {
    const loops = "fn walk(height: usize, items: []const u8) void {\n" ++
        "    for (0..height) |y| {\n        _ = y;\n    }\n\n" ++
        "    for (items, 0..) |b, i| {\n        _ = b;\n        _ = i;\n    }\n\n" ++
        "    while (next()) |w| {\n        _ = w;\n    }\n}\n";

    const captured = "fn walk(item: ?u8) void {\n    if (item) |b| {\n        _ = b;\n    }\n}\n";

    const otherwise = "fn walk() void {\n    while (next()) |value| {\n        _ = value;\n" ++
        "    } else |e| {\n        _ = e;\n    }\n}\n";

    try testing.expect_quiet(@This(), .zig, loops);
    try expect_count(.zig, captured, 1);
    try expect_count(.zig, otherwise, 1);
}

test "a lifetime is not an index use" {
    const source = "fn cycle() {\n    struct B<'a> {\n        a: [Cell<Option<&'a B<'a>>>; 2],\n" ++
        "    }\n}\n";

    var findings = try testing.analyze(@This(), .rust, source);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
    try expect_message(&findings, 0, "a is too short");
}

test "a python data model name is the language's" {
    const source = "class Title:\n    def __str__(self):\n        return self.text\n\n" ++
        "    def _str(self):\n        return self.text\n";

    var findings = try testing.analyze(@This(), .python, source);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
    try expect_message(&findings, 0, "string");
}

test "a python loop variable the body rebinds is still the header's" {
    const rebound = "def redact(items):\n    for k, v in items:\n        if hidden(k):\n" ++
        "            v = mask(v)\n        yield k, v\n";

    const fresh = "def redact(items):\n    for key, value in items:\n        v = mask(value)\n" ++
        "        yield key, v\n";

    const read = "def normalize(x, codes):\n    for c in find(codes, x):\n" ++
        "        x = x.replace(c, c.upper())\n    return x\n";

    try expect_count(.python, rebound, 0);
    try expect_count(.python, fresh, 1);
    try expect_count(.python, read, 2);
}

test "init alone is dictated but not inside a longer name" {
    var findings = try testing.analyze(@This(), .rust, "fn init() {}\n\nfn init_buffer() {}\n");
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
    try expect_message(&findings, 0, "initialize");
}

test "an expansion the language reserves is quiet" {
    const zig = "fn run() void {\n    work() catch |err| report(err);\n}\n";
    const go = "package main\n\nfunc run() {\n\terr := work()\n\treport(err)\n}\n";

    try testing.expect_quiet(@This(), .zig, zig);
    try expect_count(.go, go, 1);
}

test "an acronym is the understood short form" {
    const source = "fn read(io: Io, id: u32, fd: i32) void {\n    work(io, id, fd);\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "a zig type parameter or a tuple field is a type name" {
    const source = "fn List(comptime T: type) type {\n    return struct {\n" ++
        "        pair: struct { T, u8 },\n    };\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "an enum the file parses from text keeps the text's names" {
    const parsed = "const Kind = enum {\n    gen_decl,\n    expr_list,\n\n" ++
        "    fn of_name(text: []const u8) ?Kind {\n" ++
        "        return std.meta.stringToEnum(Kind, text);\n    }\n};\n";

    const named = "const Kind = enum {\n    gen_decl,\n    expr_list,\n};\n";

    try testing.expect_quiet(@This(), .zig, parsed);
    try expect_count(.zig, named, 2);
}

test "a word before keyword spells the keyword" {
    const source = "fn run() void {\n    const var_keyword = 1;\n    work(var_keyword);\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "an import named after its file is a foreign name" {
    try testing.expect_quiet(@This(), .zig, "const ir = @import(\"format/ir.zig\");\n");
}

test "a private alias of a foreign name keeps the foreign spelling" {
    const private = "_GetCursorInfo = windll.kernel32.GetCursorInfo\n";
    const renamed = "_GetInfo = windll.kernel32.GetCursorInfo\n";
    const own = "mgr = self._mgr\nx = x_\n";

    try testing.expect_quiet(@This(), .python, private);
    try expect_count(.python, renamed, 1);
    try expect_count(.python, own, 2);
}
