const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const stream = @import("../../stream.zig");
const support = @import("../support.zig");
const testing = @import("../testing.zig");
const Context = @import("../context.zig");
const Domains = @import("parameter_domains.zig");
const Children = scylla.View.Children;
const Function = scylla.View.Function;
const Language = scylla.Language;
const Parameter = scylla.View.Parameter;
const Parameters = scylla.View.Parameters;
const Rule = scylla.rule.Rule;
const Sink = scylla.rule.Sink;
const View = scylla.View;
const parameter_count_max = scylla.limits.parameter_count_max;
const scan = @import("../../scan.zig");

pub const rule: Rule = .{
    .citations = &.{
        .{
            .standard = "TigerStyle",
            .text = "\"Assert all function arguments and return values, pre/postconditions and " ++
                "invariants. A function must not operate blindly on data it has not checked.\"",
        },
        .{
            .standard = "NASA",
            .text = "NASA P10 Rule 7: \"[...] the validity of parameters must be checked inside " ++
                "each function.\"",
        },
    },
    .code = "TS022",
    .default_on = false,
    .description = "A function asserts what it expects of its parameters, so a wrong argument " ++
        "fails at the call it came from.",
    .explanation = "",
    .fix_title = "",
    .fixable = .sometimes,
    .group = .stable,
    .name = "assert-parameters",
    .severity = .warning,
    .summary = "Assert a function's arguments before operating on them",
    .url = "",
};

const Entry = struct {
    children: ?Children,
    count: u32,
    kinds: [entry_count_max]Kind,
    opening: bool,
    state: State,
    texts: [entry_count_max][]const u8,

    const Kind = enum {
        assertion,
        declaration,
        discard,
        effect,
    };

    const State = enum {
        ended,
        open,
        overflowed,
    };

    fn begin(entry: *Entry, body: ?View) void {
        entry.children = if (body) |block| block.children() else null;
        entry.count = 0;
        entry.opening = true;
        entry.state = if (body == null) .ended else .open;

        assert(entry.count == 0);
        assert((entry.state == .open) == (entry.children != null));
    }

    fn extend(entry: *Entry, context: *const Context) bool {
        assert(entry.state == .open);
        assert(entry.children != null);

        const children = &entry.children.?;

        for (0..children.remaining) |_| {
            const statement = children.next() orelse break;

            if (entry.opening) {
                entry.opening = false;

                if (is_docstring(context, statement)) continue;
            }

            const kind = entry_kind(context, statement) orelse break;

            if (entry.count == entry_count_max) {
                entry.state = .overflowed;

                return false;
            }

            entry.kinds[entry.count] = kind;
            entry.texts[entry.count] = statement.text(context.source);
            entry.count += 1;

            return true;
        }

        entry.state = .ended;

        return false;
    }

    fn asserts(entry: *Entry, context: *const Context, name: []const u8) ?bool {
        var position: u32 = 0;

        assert(name.len > 0);
        assert(entry.state != .overflowed);

        for (0..entry_count_max + 1) |_| {
            if (position == entry.count) {
                if (entry.state != .open) break;
                if (!entry.extend(context)) break;
            }

            const mentioned = scan.find_word(entry.texts[position], name);

            switch (entry.kinds[position]) {
                .assertion, .discard => if (mentioned) return true,
                .declaration, .effect => if (mentioned) return false,
            }

            position += 1;
        }

        if (entry.state == .overflowed) return null;
        return false;
    }
};

const Missing = struct {
    block: ?View,
    context: *const Context,
    entry: *Entry,
    function: Function,
    parameters: Parameters,
    domains: *const Domains,

    fn count(missing: *const Missing) u32 {
        var rest = missing.*;
        var total: u32 = 0;

        for (0..parameter_count_max + 1) |_| {
            _ = rest.next() orelse break;

            total += 1;
        }

        assert(total <= parameter_count_max);
        assert(missing.parameters.remaining == parameter_count_max);

        return total;
    }

    fn next(missing: *Missing) ?[]const u8 {
        const context = missing.context;

        if (missing.block) |block| assert(block.span().end() <= context.source.len);

        for (0..parameter_count_max + 1) |_| {
            const parameter = missing.parameters.next() orelse return null;
            const position = parameter.name orelse continue;
            const name = context.front_text(position);
            if (is_skipped(context, name)) continue;
            if (!is_assertable(context, missing.function, parameter)) continue;
            if (asserted_at_entry(context, missing.entry, missing.block, name)) continue;
            if (missing.domains.accepts(context, missing.function, parameter)) continue;

            assert(name.len > 0);

            return name;
        }

        return null;
    }

    pub fn format(missing: Missing, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        var rest = missing;
        var written: u32 = 0;

        for (0..parameter_count_max + 1) |_| {
            const name = rest.next() orelse break;

            if (written > 0) try writer.writeAll(", ");

            try writer.writeAll(scan.utf8_or(name, "the name"));
            written += 1;
        }

        assert(written > 0);
        assert(written <= parameter_count_max);
    }
};

const alias_marker = "=";
const entry_count_max: u32 = 64;
const enum_word = "enum";
const non_exhaustive_name = "_";
const payload_markers = "(:{";
const type_word = "type";
const union_separator = '|';
const union_word = "union";

pub fn run(context: *const Context, sink: *Sink) void {
    var domains: Domains = .empty;

    domains.build(context);

    var nodes = support.functions_and_bound_lambdas(context);

    for (0..context.front.node_count()) |_| {
        const node = nodes.next() orelse break;
        const function = node.as_function() orelse continue;
        const parameters = function.parameters_span() orelse continue;
        const body = function.body();

        if (body == null) {
            if (is_bodiless(context, node)) continue;
        }

        var entry: Entry = undefined;

        entry.begin(body);

        const missing: Missing = .{
            .block = body,
            .context = context,
            .entry = &entry,
            .function = function,
            .parameters = function.parameters(),
            .domains = &domains,
        };

        const missing_count = missing.count();
        if (missing_count == 0) continue;

        assert(missing_count <= missing.parameters.count());
        assert(parameters.end() <= context.source.len);

        sink.report_formatted(parameters, "the function does not assert {f} at entry", .{missing});
    }
}

fn is_bodiless(context: *const Context, node: View) bool {
    assert(node.as_function() != null);

    if (node.category() == .lambda) return false;

    assert(node.category() == .function);

    return !carries_a_body(context, node);
}

fn carries_a_body(context: *const Context, function: View) bool {
    const span = function.span();
    const body = context.tokens_in(span);

    assert(span.end() <= context.source.len);

    if (body.len > 0) {
        const last = body[body.len - 1];
        const bodies = context.conventions.pointer_boundary_bodies;

        if (last.is_punctuation(.semicolon)) return false;
        if (scan.word_listed(bodies, context.text(last))) return false;
    }

    const after = stream.index_starting_from(context.tokens, span.end());

    assert(after <= context.tokens.len);

    if (after == context.tokens.len) return true;
    return !context.tokens[after].is_punctuation(.semicolon);
}

fn is_skipped(context: *const Context, name: []const u8) bool {
    assert(name.len > 0);

    for (context.conventions.parameter_skip_names) |skipped| {
        assert(skipped.len > 0);

        if (skipped[skipped.len - 1] == '*') {
            if (std.mem.startsWith(u8, name, skipped[0 .. skipped.len - 1])) return true;

            continue;
        }

        if (std.mem.eql(u8, name, skipped)) return true;
    }

    return false;
}

fn is_assertable(context: *const Context, function: Function, parameter: Parameter) bool {
    const span = parameter.type_span orelse return true;
    const text = scan.trim_ascii(context.span_text(span));

    assert(span.offset >= parameter.span.offset);
    assert(text.len <= span.length);

    if (std.mem.eql(u8, text, type_word)) return false;
    if (scan.word_listed(context.conventions.boolean_type_names, text)) return false;
    if (scan.word_listed(context.conventions.parameter_valueless_types, text)) return false;
    if (names_a_function(context, function, text)) return false;
    if (names_a_fieldless_enum(context, text)) return false;

    for (context.conventions.parameter_exempt_prefixes) |prefix| {
        assert(prefix.len > 0);

        if (std.mem.startsWith(u8, text, prefix)) return false;
    }

    return true;
}

fn names_a_function(context: *const Context, function: Function, text: []const u8) bool {
    if (marks_a_callback(context, text)) return true;
    if (unites_callback_aliases(context, text)) return true;
    if (!is_identifier(text)) return false;

    const span = function.view.span();
    const end = if (function.body()) |body| body.span().offset else span.end();

    assert(end >= span.offset);
    assert(end <= context.source.len);

    const signature = context.source[span.offset..end];
    var cursor: usize = 0;

    for (0..signature.len + 1) |_| {
        const found = scan.find(signature[cursor..], text) orelse break;
        const at = cursor + found;
        const after = at + text.len;
        const opened = at == 0 or !scan.is_identifier_part(signature[at - 1]);
        const closed = after == signature.len or !scan.is_identifier_part(signature[after]);
        const whole = opened and closed;

        assert(after <= signature.len);

        cursor = after;

        if (!whole) continue;
        if (bounds_a_callback(context, signature[after..])) return true;
    }

    return false;
}

fn unites_callback_aliases(context: *const Context, text: []const u8) bool {
    assert(text.len <= context.source.len);

    var members = std.mem.splitScalar(u8, text, union_separator);
    var counted: u32 = 0;

    for (0..text.len + 1) |_| {
        const member = members.next() orelse break;
        const name = scan.trim_ascii(member);
        if (name.len == 0) continue;
        if (!is_identifier(name)) return false;
        if (!aliases_a_callback(context, name)) return false;

        counted += 1;
    }

    return counted > 0;
}

fn aliases_a_callback(context: *const Context, name: []const u8) bool {
    assert(name.len > 0);

    var declarations = context.views(.declaration);

    for (0..declarations.remaining) |_| {
        const held = declarations.next() orelse break;
        const parent = held.parent() orelse continue;

        assert(parent.index() < held.index());

        if (parent.category() != .file) continue;

        const declared = held.text(context.source);
        if (!std.mem.startsWith(u8, declared, name)) continue;

        const rest = std.mem.trimStart(u8, declared[name.len..], scan.ascii_whitespace);
        if (!std.mem.startsWith(u8, rest, alias_marker)) continue;
        if (marks_a_callback(context, rest)) return true;
    }

    return false;
}

fn bounds_a_callback(context: *const Context, rest: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, rest, scan.ascii_whitespace);

    assert(trimmed.len <= rest.len);

    if (!std.mem.startsWith(u8, trimmed, ":")) return false;

    const bound = trimmed[1..];
    const end = std.mem.findAny(u8, bound, ",>{") orelse bound.len;

    assert(end <= bound.len);

    return marks_a_callback(context, bound[0..end]);
}

fn marks_a_callback(context: *const Context, text: []const u8) bool {
    assert(context.conventions.callback_markers.len > 0);

    for (context.conventions.callback_markers) |marker| {
        assert(marker.len > 0);

        if (scan.find(text, marker) != null) return true;
    }

    return false;
}

fn is_identifier(text: []const u8) bool {
    for (text) |byte| {
        if (!scan.is_identifier_part(byte)) return false;
    }

    return true;
}

fn names_a_fieldless_enum(context: *const Context, text: []const u8) bool {
    if (text.len == 0) return false;
    if (!is_identifier(text)) return false;

    for (context.front.nodes_of(.@"struct")) |position| {
        const held = context.view(position);
        const container = held.as_container() orelse continue;
        const token = container.name_token() orelse continue;

        assert(held.category() == .@"struct");

        if (!std.mem.eql(u8, context.front_text(token), text)) continue;
        if (is_a_fieldless_enum(context, held)) return true;
    }

    return false;
}

fn is_a_fieldless_enum(context: *const Context, held: View) bool {
    const text = held.text(context.source);
    const open = std.mem.findScalar(u8, text, '{') orelse return false;
    const header = text[0..open];
    const container = held.as_container() orelse return false;

    assert(open < text.len);
    assert(text.len == held.span().length);

    if (!scan.find_word(header, enum_word)) return false;
    if (scan.find_word(header, union_word)) return false;

    var fields = container.fields();

    for (0..fields.remaining + 1) |_| {
        const field = fields.next() orelse return true;
        if (!names_a_variant(context, field)) return false;
    } else unreachable;
}

fn names_a_variant(context: *const Context, field: View) bool {
    const text = scan.trim_ascii(field.text(context.source));

    assert(field.span().end() <= context.source.len);
    assert(text.len <= field.span().length);

    if (std.mem.eql(u8, text, non_exhaustive_name)) return false;
    return std.mem.findAny(u8, text, payload_markers) == null;
}

fn asserted_at_entry(
    context: *const Context,
    entry: *Entry,
    body: ?View,
    name: []const u8,
) bool {
    if (entry.state != .overflowed) {
        if (entry.asserts(context, name)) |held| return held;
    }

    const block = body orelse return false;
    var children = block.children();
    var opening = true;

    assert(name.len > 0);
    assert(block.span().end() <= context.source.len);

    for (0..children.remaining) |_| {
        const statement = children.next() orelse return false;
        const mentioned = scan.find_word(statement.text(context.source), name);

        if (opening) {
            opening = false;

            if (is_docstring(context, statement)) continue;
        }

        const kind = entry_kind(context, statement) orelse return false;

        switch (kind) {
            .assertion, .discard => if (mentioned) return true,
            .declaration, .effect => if (mentioned) return false,
        }
    }

    return false;
}

fn entry_kind(context: *const Context, statement: View) ?Entry.Kind {
    assert(statement.span().end() <= context.source.len);
    assert(statement.index() < context.front.node_count());

    if (context.is_assertion(statement)) return .assertion;
    if (Domains.is_guard(context, statement)) return .assertion;
    if (discards_a_name(context, statement)) return .discard;
    if (statement.category() == .declaration) return .declaration;
    if (context.front.language == .zig) return .effect;
    return null;
}

fn discards_a_name(context: *const Context, statement: View) bool {
    const prefix = context.grammar.discard_prefix;

    if (!context.conventions.compiler_rejects_an_unused_parameter) return false;

    assert(prefix.len > 0);

    const text = scan.trim_ascii(statement.text(context.source));

    assert(text.len <= statement.span().length);

    if (!std.mem.startsWith(u8, text, prefix)) return false;

    const name = std.mem.trimEnd(u8, text[prefix.len..], ";");
    if (name.len == 0) return false;
    return is_identifier(name);
}

fn is_docstring(context: *const Context, statement: View) bool {
    const body = context.tokens_in(statement.span());

    assert(statement.parent() != null);

    if (body.len != 1) return false;

    assert(body[0].end() <= statement.span().end());

    return body[0].kind == .string;
}

fn expect_count(language: Language, source: []const u8, count: u32) !void {
    assert(source.len > 0);
    assert(count <= testing.limits.diagnostic_count_max);

    var findings = try testing.analyze(@This(), language, source);
    defer findings.deinit();

    if (findings.count() != count) findings.print();

    try std.testing.expectEqual(count, findings.count());
}

fn expect_mentions(language: Language, source: []const u8, parts: []const []const u8) !void {
    assert(source.len > 0);
    assert(parts.len > 0);

    var findings = try testing.analyze(@This(), language, source);
    defer findings.deinit();

    if (findings.count() != parts.len) findings.print();

    try std.testing.expectEqual(parts.len, findings.count());

    for (parts, 0..) |part, index| {
        const message = findings.message(@intCast(index));

        try std.testing.expect(std.mem.find(u8, message, part) != null);
    }
}

test "a boolean parameter has no invalid value" {
    const source = "fn read(sector: u32, verbose: bool) {\n    assert!(sector > 0);\n\n    " ++
        "work(sector, verbose);\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
}

test "a function parameter has no invalid value" {
    const source = "fn read<R, F: FnOnce() -> R>(body: F) -> R {\n    body()\n}\n\n" ++
        "fn walk(wanted: impl Fn(u32) -> bool) -> bool {\n    wanted(1)\n}\n\n" ++
        "fn scan(step: &dyn Fn(u32)) {\n    step(1);\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
}

test "a leading union bar names no alias" {
    const source = "type Kind =\n  | \"a\"\n  | \"b\";\n\n" ++
        "function pick(kind: | \"a\" | \"b\", count: number): number {\n  return count;\n}\n";

    var findings = try testing.analyze(@This(), .typescript, source);
    defer findings.deinit();

    try std.testing.expect(findings.count() <= 1);
}

test "a parameter typed by callback aliases the file declares has no invalid value" {
    const source = "SyncHandler = typing.Callable[[Request], Response]\n" ++
        "AsyncHandler = typing.Callable[[Request], typing.Awaitable[Response]]\n\n\n" ++
        "class MockTransport:\n" ++
        "    def __init__(self, handler: SyncHandler | AsyncHandler, name: str) -> None:\n" ++
        "        self.handler = handler\n        self.name = name\n";

    try expect_mentions(.python, source, &.{"assert name at entry"});
}

test "a fieldless enum parameter declared in the file has no invalid value" {
    const source = "enum Kind {\n    Bullet,\n    Ordered,\n}\n\nenum Held {\n    " ++
        "Some(u32),\n    None,\n}\n\nfn mark(kind: Kind) {\n    work(kind);\n}\n\nfn " ++
        "hold(held: Held) {\n    work(held);\n}\n\nfn far(state: TaskState) {\n    " ++
        "work(state);\n}\n";

    try expect_mentions(.rust, source, &.{ "held", "state" });
}

test "an unasserted parameter is reported" {
    try expect_mentions(.rust, "fn read(sector: u32) {\n    work(sector);\n}\n", &.{"sector"});
}

test "an asserted parameter is quiet" {
    const source = "fn read(sector: u32) {\n    assert!(sector > 0);\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
}

test "a receiver is not a parameter" {
    try testing.expect_quiet(@This(), .python, "def read(self):\n    return 1\n");
}

test "every missing parameter is named once" {
    const source = "fn read(sector: u32, count: u32) {\n    work(sector);\n}\n";

    try expect_mentions(.rust, source, &.{"sector, count"});
}

test "an assertion past the entry window does not count" {
    const source = "fn read(sector: u32) {\n    work(sector);\n    assert!(sector > 0);\n}\n";

    try expect_count(.rust, source, 1);
}

test "an assertion after a docstring still counts" {
    const source = "def read(sector):\n    \"\"\"Read it.\"\"\"\n    assert sector > 0\n" ++
        "return sector\n";

    try testing.expect_quiet(@This(), .python, source);
}

test "a parameter of any type can hold an invalid value" {
    try expect_mentions(.rust, "fn read(reader: Reader) {\n    work(reader);\n}\n", &.{"reader"});
}

test "a reference the language proves is exempt" {
    const rust = "fn read(sector: &mut u32, held: &Reader) {\n    work(sector, held);\n}\n";

    try testing.expect_quiet(@This(), .rust, rust);

    const zig = "fn read(held: *Reader, other: *const u32) void {\n    work(held, other);\n}\n";

    try testing.expect_quiet(@This(), .zig, zig);
}

test "a zig slice or optional pointer is reported" {
    const source = "fn read(bytes: []const u8, held: ?*Reader) void {\n    work(bytes, " ++
        "held);\n}\n";

    try expect_mentions(.zig, source, &.{"bytes, held"});
}

test "a type parameter is exempt" {
    const source = "fn Read(comptime T: type, count: usize) type {\n    work(count);\n}\n";

    var findings = try testing.analyze(@This(), .zig, source);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
    try std.testing.expect(std.mem.find(u8, findings.message(0), "count") != null);
    try std.testing.expect(std.mem.findScalar(u8, findings.message(0), 'T') == null);
}

test "a go parameter is gated by name alone" {
    try expect_count(.go, "func read(reader int) {\n\twork(reader)\n}\n", 1);
}

test "a go pointer can be nil and is reported" {
    try expect_count(.go, "func read(reader *Reader) {\n\twork(reader)\n}\n", 1);
}

test "a python parameter without an annotation is reported" {
    try expect_count(.python, "def read(reader):\n    return reader\n", 1);
}

test "an arrow function bound to a name asserts its parameters" {
    const source = "const read = (sector) => {\n    return sector * 2;\n};\n";

    try expect_count(.javascript, source, 1);

    const asserted = "const read = (sector) => {\n    assert(sector > 0);\n\n    return " ++
        "sector * 2;\n};\n";

    try testing.expect_quiet(@This(), .javascript, asserted);
}

test "a zig expectation is an assertion" {
    const source =
        "fn read(sector: u32) void {\n    try std.testing.expectEqual(true, sector > 0);\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "a zig expectation called through a file alias is an assertion" {
    const source = "const expect = std.testing.expect;\n\nfn check(sector: u32) !void {\n" ++
        "    try expect(sector > 0);\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "a python assertion helper is an assertion" {
    const source = "def read(self, sector):\n    self.assertGreater(sector, 0)\n    " ++
        "assert_equal(sector, sector)\n";

    try testing.expect_quiet(@This(), .python, source);
}

test "a declaration that ends in a semicolon carries no body and is exempt" {
    try testing.expect_quiet(@This(), .rust, "trait R {\n    fn read(sector: u32);\n}\n");
    try expect_count(.go, "func read(sector int)\n", 1);
}

test "an odin procedure whose body is three dashes carries none and is exempt" {
    const source = "package p\n\nforeign import lib \"system:c\"\n\nforeign lib {\n" ++
        "\twrite :: proc(fd: i32, data: rawptr, count: uint) -> int ---\n}\n\n" ++
        "copy :: proc(target: rawptr, count: uint) {\n\tassert(target != nil)\n}\n";

    try expect_mentions(.odin, source, &.{"count"});
}

test "a comment before the first statement does not end the entry window" {
    const rust = "fn read(sector: u32) {\n    // note\n    assert!(sector > 0);\n}\n";

    try testing.expect_quiet(@This(), .rust, rust);
    try testing.expect_quiet(@This(), .python, "def f(v):  # note\n    assert v > 0\n");
}

test "a comment before the block is outside it" {
    const source = "fn read(sector: u32) /* note */ {\n    assert!(sector > 0);\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
}

test "a one token statement is not a docstring" {
    try expect_count(.python, "def read(sector: int):\n    pass\n    assert sector > 0\n", 1);

    const quiet = "def read(sector: int):\n    \"\"\"doc\"\"\"\n    assert sector > 0\n";

    try testing.expect_quiet(@This(), .python, quiet);
}

test "one missing name is written without a separator" {
    const source = "fn read(sector: u32) {\n    work(sector);\n}\n";

    try testing.expect_findings(@This(), .rust, source, &.{
        "the function does not assert sector at entry",
    });
}

test "an allocator, an io, or a void parameter carries no value to check" {
    const source = "fn read(gpa: std.mem.Allocator, arena: Allocator, io: std.Io, " ++
        "context: void, count: u32) void {\n    assert(count > 0);\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "a zig discard at entry marks a parameter the body never reads" {
    const source = "fn apply(count: u32, key: []const u8, value: u32) u32 {\n" ++
        "    _ = key;\n    assert(count > 0);\n    assert(value > 0);\n\n" ++
        "    return count + value;\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "an assertion after a declaration that does not read the parameter is at entry" {
    const unrelated = "fn around(pairs: *const Pairs, open: u32, index: u32) u32 {\n" ++
        "    const tokens = pairs.tokens;\n\n    assert(open <= index);\n\n" ++
        "    return tokens[open];\n}\n";

    const used = "fn around(open: u32, index: u32) u32 {\n    const first = open + 1;\n\n" ++
        "    assert(open <= index);\n\n    return first;\n}\n";

    try testing.expect_quiet(@This(), .zig, unrelated);

    try testing.expect_findings(@This(), .zig, used, &.{
        "the function does not assert open at entry",
    });
}

test "a zig enum with methods has no invalid value and a tagged union has a payload" {
    const source = "const Kind = enum(u8) {\n    bullet,\n    ordered,\n\n" ++
        "    pub fn index(kind: Kind) u32 {\n        return @intFromEnum(kind);\n    }\n};\n\n" ++
        "const Held = union(enum) {\n    count: u32,\n    none,\n};\n\n" ++
        "const Open = enum(u8) {\n    bullet,\n    _,\n};\n\n" ++
        "fn mark(kind: Kind) void {\n    work(kind);\n}\n\n" ++
        "fn hold(held: Held) void {\n    work(held);\n}\n\n" ++
        "fn open(value: Open) void {\n    work(value);\n}\n";

    try expect_mentions(.zig, source, &.{ "held", "value" });
}

test "an error union parameter is reported" {
    const source = "fn read(sector: anyerror!u32) void {\n    work(sector);\n}\n";

    try expect_mentions(.zig, source, &.{"sector"});
}

test "recoverable bounds checks validate slices before copying" {
    const source = "fn write(source: []const u8) error{Full}!void {\n" ++
        "    if (source.len > 16) return error.Full;\n    copy(source);\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "a guard after a use remains too late" {
    const source = "fn write(source: []const u8) error{Full}!void {\n" ++
        "    copy(source);\n    if (source.len > 16) return error.Full;\n}\n";

    try expect_mentions(.zig, source, &.{"source"});
}

test "plain numeric payloads and bit comparisons have no extra input domain" {
    const source = "fn digits(value: u64) u64 {\n    return @rem(value, 10);\n}\n" ++
        "fn bits(value: u64) u64 {\n    return value & 255;\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "indexing and variable divisors still require input checks" {
    const source = "fn at(values: *[16]u8, index: u32) u8 {\n" ++
        "    return values[index];\n}\n" ++
        "fn divide(value: u64, divisor: u64) u64 {\n" ++
        "    return @divTrunc(value, divisor);\n}\n";

    try expect_mentions(.zig, source, &.{ "index", "divisor" });
}

test "standard formatting validates a comptime format argument" {
    const source = "fn print(target: *[16]u8, comptime format: []const u8) void {\n" ++
        "    _ = std.mem.print(target, format, .{});\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "comptime parameters used for indexing still need bounds" {
    const source = "fn at(values: *[16]u8, comptime index: u32) u8 {\n" ++
        "    return values[index];\n}\n";

    try expect_mentions(.zig, source, &.{"index"});
}

test "unchecked casts arithmetic shifts and zero divisors remain reported" {
    const source = "const zero = 0;\n" ++
        "fn cast(value: u64) u8 { return @intCast(value); }\n" ++
        "fn add(value: u64) u64 { return 1 + value; }\n" ++
        "fn shift(value: u64) u64 { return @as(u64, 1) << value; }\n" ++
        "fn divide(value: u64) u64 { return @divTrunc(value, zero); }\n";

    try expect_mentions(.zig, source, &.{ "value", "value", "value", "value" });
}

test "random capabilities do not need an artificial value constraint" {
    const source = "fn draw(random: std.Random) u64 {\n" ++
        "    return random.int(u64);\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "opaque payloads can be copied into the final field of a record" {
    const source = "fn store(target: *Record, value: Value) void {\n" ++
        "    target.* = .{ .value = value };\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "inspecting an opaque payload still needs its contract" {
    const source = "fn store(target: *Record, value: Value) void {\n" ++
        "    target.* = .{ .value = value.field };\n}\n";

    try expect_mentions(.zig, source, &.{"value"});
}

test "a derived offset can be checked after full domain computation" {
    const source = "fn render(target: *[16]u8, value: u64) u8 {\n" ++
        "    const offset = if (value > 0) 1 else 0;\n    assert(offset < target.len);\n" ++
        "    return target[offset];\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "a derived offset checked after indexing remains too late" {
    const source = "fn render(target: *[16]u8, value: u64) u8 {\n" ++
        "    const offset = value;\n    const byte = target[offset];\n" ++
        "    assert(offset < target.len);\n    return byte;\n}\n";

    try expect_mentions(.zig, source, &.{"value"});
}

test "a helper with a narrower precondition does not establish a full domain" {
    const source = "fn narrow(value: u64) u8 {\n    assert(value < 10);\n" ++
        "    return @intCast(value);\n}\n" ++
        "fn forward(value: u64) u8 {\n    return narrow(value);\n}\n";

    try expect_mentions(.zig, source, &.{"value"});
}

test "standard PRNG initialization accepts every seed" {
    const source = "fn seeded(seed: u64) std.Random.DefaultPrng {\n" ++
        "    return std.Random.DefaultPrng.init(seed);\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "checked intermediate values stop propagating unchecked input" {
    const source = "fn bucket(value: u64) u64 {\n" ++
        "    const first = value & 15;\n    assert(first < 16);\n" ++
        "    const second = (first + 1) & 15;\n    return second;\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "a conditional check does not validate a derived offset on every path" {
    const source = "fn at(target: *[16]u8, value: u64, checked: bool) u8 {\n" ++
        "    const offset = value;\n    if (checked) assert(offset < target.len);\n" ++
        "    return target[offset];\n}\n";

    try expect_mentions(.zig, source, &.{"value"});
}

test "overflowing arithmetic in a bounds guard is not validation" {
    const source = "fn write(source: []const u8, count: u32) error{Full}!void {\n" ++
        "    if (count + source.len > 16) return error.Full;\n    copy(source);\n}\n";

    try expect_mentions(.zig, source, &.{"source"});
}

test "union payload reads are not plain scalar comparisons" {
    const source = "const Value = union(enum) { number: u64, flag: bool };\n" ++
        "fn compare(value: Value) bool { return value.flag; }\n";

    try expect_mentions(.zig, source, &.{"value"});
}

test "copied sizes and returned state still need their construction contract" {
    const source = "fn size(target: *Record, length: u16) void { target.length = length; }\n" ++
        "fn state(value: u64) Record { return .{ .value = value }; }\n";

    try expect_mentions(.zig, source, &.{ "length", "value" });
}

fn analyze_fuzz(source: []const u8) !testing.Findings {
    const subject = @This();

    const InFuzz = struct {
        pub const rule = subject.rule;

        pub fn run(context: *const Context, sink: *Sink) void {
            var scoped = context.*;

            scoped.path = "src/model_fuzz.zig";

            subject.run(&scoped, sink);
        }
    };

    return testing.analyze(InFuzz, .zig, source);
}

test "full range integer test inputs can be sent to the subject under test" {
    const source = "fn check(value: u64) void { subject.accept(value); }\n";

    var fuzz = try analyze_fuzz(source);
    defer fuzz.deinit();

    try std.testing.expectEqual(@as(u32, 0), fuzz.count());
    try expect_mentions(.zig, source, &.{"value"});
}

test "fuzz inputs still need bounds before indexing or narrowing" {
    const source = "fn at(target: *[16]u8, index: u32) u8 { return target[index]; }\n" ++
        "fn cast(value: u64) u8 { return @intCast(value); }\n";

    var findings = try analyze_fuzz(source);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 2), findings.count());
}

test "a mutable working copy can retain the full numeric domain" {
    const source = "fn digit(value: u64) u64 {\n    var remaining = value;\n" ++
        "    remaining = @divTrunc(remaining, 10);\n    return @rem(remaining, 10);\n}\n" ++
        "fn render(value: u64) u64 { return digit(value); }\n";

    try testing.expect_quiet(@This(), .zig, source);
}
