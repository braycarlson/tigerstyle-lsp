const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const stream = scylla.stream;
const support = @import("../support.zig");
const testing = @import("../testing.zig");
const Context = @import("../context.zig");
const Domains = @import("parameter_domains.zig");
const closed_types = @import("closed_types.zig");
const Children = scylla.View.Children;
const Function = scylla.View.Function;
const Language = scylla.Language;
const Parameter = scylla.View.Parameter;
const Parameters = scylla.View.Parameters;
const Rule = scylla.Rule;
const Sink = scylla.rule.Sink;
const View = scylla.View;
const parameter_count_max = scylla.limits.parameter_count_max;
const stub_body = "...";
const scan = scylla.scan;

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
            entry.texts[entry.count] = checked_text(context, statement, kind);
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
            if (is_python_keyword_variadic(context, parameter)) continue;
            if (!is_assertable(context, missing.function, parameter)) continue;
            if (asserted_at_entry(context, missing.entry, missing.block, name)) continue;
            if (forwards_a_variadic(context, parameter, position)) continue;
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
const keyword_variadic_marker = "**";
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

        if (body) |block| {
            if (is_stub_body(context, block)) continue;
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
    assert(function.span().end() <= context.source.len);

    const span = function.span();
    const body = context.tokens_in(span);

    assert(span.end() <= context.source.len);

    if (body.len > 0) {
        const last = body[body.len - 1];
        const bodies = context.conventions.pointer_boundary_bodies;

        if (last.is_punctuation(.semicolon)) return false;
        if (scan.word_listed(bodies, context.text(last))) return false;
    }

    const after = stream.index_starting_from(scylla.Token, context.tokens, span.end());

    assert(after <= context.tokens.len);

    if (after == context.tokens.len) return true;
    return !context.tokens[after].is_punctuation(.semicolon);
}

fn is_stub_body(context: *const Context, block: View) bool {
    assert(block.span().end() <= context.source.len);

    var children = block.children();
    const first = children.next() orelse return false;

    if (children.next() != null) return false;

    const tokens = context.tokens_in(first.span());

    assert(first.span().end() <= context.source.len);

    if (tokens.len != 1) return false;
    return std.mem.eql(u8, context.text(tokens[0]), stub_body);
}

fn is_python_keyword_variadic(context: *const Context, parameter: Parameter) bool {
    if (context.front.language != .python) return false;
    if (!parameter.variadic) return false;

    assert(parameter.span.offset <= context.source.len);

    const before = scan.trim_ascii(context.source[0..parameter.span.offset]);

    return std.mem.endsWith(u8, before, keyword_variadic_marker);
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
    assert(parameter.span.end() <= context.source.len);

    const span = parameter.type_span orelse return true;
    const text = scan.trim_ascii(context.span_text(span));

    assert(span.offset >= parameter.span.offset);
    assert(text.len <= span.length);

    if (std.mem.eql(u8, text, type_word)) return false;
    if (scan.word_listed(context.conventions.boolean_type_names, text)) return false;
    if (names_an_exempt_type(context, text)) return false;
    if (names_a_function(context, function, text)) return false;
    if (names_a_fieldless_enum(context, text)) return false;
    if (closed_types.names_a_closed_type(context, function, parameter, text)) return false;
    if (names_an_exempt_subclass(context, text)) return false;

    for (context.conventions.parameter_exempt_prefixes) |prefix| {
        assert(prefix.len > 0);

        if (std.mem.startsWith(u8, text, prefix)) return false;
    }

    return true;
}

fn names_an_exempt_type(context: *const Context, text: []const u8) bool {
    if (text.len == 0) return false;
    if (scan.word_listed(context.conventions.parameter_valueless_types, text)) return true;
    return context.settings.parameter_exempt_types.contains(text);
}

fn names_an_exempt_subclass(context: *const Context, text: []const u8) bool {
    if (text.len == 0) return false;
    if (!is_identifier(text)) return false;

    for (context.front.nodes_of(.@"struct")) |position| {
        const held = context.view(position);
        const container = held.as_container() orelse continue;
        const token = container.name_token() orelse continue;

        assert(held.category() == .@"struct");

        if (!std.mem.eql(u8, context.front_text(token), text)) continue;
        if (derives_an_exempt_type(context, container)) return true;
    }

    return false;
}

fn derives_an_exempt_type(context: *const Context, container: View.Container) bool {
    assert(container.view.span().end() <= context.source.len);

    var bases = container.bases();

    for (0..bases.remaining) |_| {
        const base = bases.next() orelse break;
        const text = scan.trim_ascii(base.text(context.source));

        assert(base.index() > container.view.index());

        if (names_an_exempt_type(context, text)) return true;
    }

    return false;
}

fn names_a_function(context: *const Context, function: Function, text: []const u8) bool {
    assert(function.view.span().end() <= context.source.len);

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
        if (binds_a_callback(context, held, name)) return true;

        const declared = held.text(context.source);
        if (!std.mem.startsWith(u8, declared, name)) continue;

        const rest = std.mem.trimStart(u8, declared[name.len..], scan.ascii_whitespace);
        if (!std.mem.startsWith(u8, rest, alias_marker)) continue;
        if (marks_a_callback(context, rest)) return true;
    }

    return false;
}

fn binds_a_callback(context: *const Context, held: View, name: []const u8) bool {
    assert(held.span().end() <= context.source.len);
    assert(name.len > 0);

    const declaration = held.as_declaration() orelse return false;
    const position = declaration.name_token() orelse return false;
    if (!std.mem.eql(u8, context.front_text(position), name)) return false;

    const value = declaration.value() orelse return false;

    return marks_a_callback(context, value.text(context.source));
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
    assert(text.len <= context.source.len);

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
    assert(held.span().end() <= context.source.len);

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
    assert(field.span().end() <= context.source.len);

    const text = scan.trim_ascii(field.text(context.source));

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
    if (body) |present| assert(present.span().end() <= context.source.len);

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

        if (opening) {
            opening = false;

            if (is_docstring(context, statement)) continue;
        }

        const kind = entry_kind(context, statement) orelse return false;
        const mentioned = scan.find_word(checked_text(context, statement, kind), name);

        switch (kind) {
            .assertion, .discard => if (mentioned) return true,
            .declaration, .effect => if (mentioned) return false,
        }
    }

    return false;
}

fn checked_text(context: *const Context, statement: View, kind: Entry.Kind) []const u8 {
    assert(statement.span().end() <= context.source.len);

    const text = statement.text(context.source);

    assert(text.len == statement.span().length);

    if (kind != .assertion) return text;
    return Domains.guard_condition(context, statement) orelse text;
}

fn forwards_a_variadic(context: *const Context, parameter: Parameter, name: u32) bool {
    assert(name < context.front.tokens().len);

    if (!parameter.variadic) return false;

    const binding = parameter_binding(context, name) orelse return false;
    const bindings = context.front.bindings();
    var references = bindings.references_of(binding);
    var forwarded: u32 = 0;

    assert(binding < bindings.count());

    for (0..bindings.reference_count()) |_| {
        const reference = references.next() orelse break;
        if (reference.is_store) return false;

        const held = context.view(reference.node);
        if (held.spread_call() == null) return false;

        forwarded += 1;
    }

    assert(forwarded <= bindings.reference_count());

    return forwarded > 0;
}

fn parameter_binding(context: *const Context, name: u32) ?u32 {
    assert(name < context.front.tokens().len);

    const bindings = context.front.bindings();
    const offset = context.front_token(name).offset;

    for (0..bindings.count()) |position| {
        const index: u32 = @intCast(position);
        const binding = bindings.at(index);
        if (binding.class != .parameter) continue;
        if (binding.name.offset != offset) continue;

        assert(binding.name.length == context.front_token(name).length);

        return index;
    }

    return null;
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
    assert(statement.span().end() <= context.source.len);

    const prefix = context.grammar.discard_prefix;

    if (!context.conventions.parameter_discards_mark_unread) return false;

    assert(prefix.len > 0);

    const text = scan.trim_ascii(statement.text(context.source));

    assert(text.len <= statement.span().length);

    if (!std.mem.startsWith(u8, text, prefix)) return false;

    const name = std.mem.trimEnd(u8, text[prefix.len..], ";");
    if (name.len == 0) return false;
    return is_identifier(name);
}

fn is_docstring(context: *const Context, statement: View) bool {
    assert(statement.span().end() <= context.source.len);

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

test "a parameter typed by a zig callback alias the file declares has no invalid value" {
    const source = "pub const Callback = *const fn () void;\n" ++
        "const Private = *const fn (u32) void;\n" ++
        "const Count = u32;\n\n" ++
        "pub fn process(callback: Callback) void {\n    callback();\n}\n\n" ++
        "fn notify(callback: Private) void {\n    callback(1);\n}\n\n" ++
        "fn counted(count: Count) void {\n    work(count);\n}\n";

    try expect_mentions(.zig, source, &.{"count"});
}

test "a fieldless enum parameter declared in the file has no invalid value" {
    const source = "enum Kind {\n    Bullet,\n    Ordered,\n}\n\nenum Held {\n    " ++
        "Some(u32),\n    None,\n}\n\nfn mark(kind: Kind) {\n    work(kind);\n}\n\nfn " ++
        "hold(held: Held) {\n    work(held);\n}\n\nfn far(state: TaskState) {\n    " ++
        "work(state);\n}\n";

    try expect_mentions(.rust, source, &.{ "held", "state" });
}

test "a framework request type has no invalid value" {
    const source = "def show(request: HttpRequest, count: int) -> int:\n" ++
        "    return count * 2\n\n\ndef wrapped(request: django.http.HttpRequest) -> None:\n" ++
        "    work(request)\n";

    try expect_mentions(.python, source, &.{"assert count at entry"});
}

test "a class the file derives from a request type has no invalid value" {
    const source = "class CompanyRequest(HttpRequest):\n    pass\n\n\nclass SaveRequest:\n" ++
        "    pass\n\n\ndef show(request: CompanyRequest) -> None:\n    work(request)\n\n\n" ++
        "def save(request: SaveRequest) -> None:\n    work(request)\n";

    var findings = try testing.analyze(@This(), .python, source);
    defer findings.deinit();

    const save = std.mem.find(u8, source, "def save").?;

    try std.testing.expectEqual(@as(u32, 1), findings.count());
    try std.testing.expect(findings.span(0).offset > save);
}

test "a type the configuration names has no invalid value" {
    const source = "def show(request: CompanyRequest, payload: SaveRequest) -> None:\n" ++
        "    work(request, payload)\n";

    const spans = [_]scylla.Span{.{ .offset = 0, .length = 14 }};
    var settings = testing.settings;

    settings.parameter_exempt_types = .{ .bytes = "CompanyRequest", .spans = &spans };

    var findings = try testing.analyze_settled(@This(), .python, source, &settings);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
    try std.testing.expect(std.mem.find(u8, findings.message(0), "assert payload at") != null);
    try expect_mentions(.python, source, &.{"assert request, payload at entry"});
}

test "a variadic spread whole into a call is the callee's to check" {
    const python = "class View:\n    def get(self, request: HttpRequest, *args, **kwargs):\n" ++
        "        return super().get(request, *args, **kwargs)\n";

    const javascript = "function run(...rest) {\n  return work(...rest);\n}\n";
    const go = "package main\n\nfunc run(rest ...int) int {\n\treturn work(rest...)\n}\n";
    const odin = "package main\n\nrun :: proc(rest: ..int) {\n\twork(..rest)\n}\n";

    try testing.expect_quiet(@This(), .python, python);
    try testing.expect_quiet(@This(), .javascript, javascript);
    try testing.expect_quiet(@This(), .go, go);
    try testing.expect_quiet(@This(), .odin, odin);
}

test "a variadic the function reads, rebinds, or passes whole is reported" {
    const read = "def get(*args, **kwargs):\n    first = args[0]\n" ++
        "    return work(first, *args, **kwargs)\n";

    const rebound = "def get(*args):\n    args = list(args)\n    return work(*args)\n";
    const whole = "def get(*args):\n    return work(args)\n";
    const indexed = "package main\n\nfunc run(rest ...int) int {\n\treturn rest[0]\n}\n";

    try expect_mentions(.python, read, &.{"assert args at entry"});
    try expect_mentions(.python, rebound, &.{"assert args at entry"});
    try expect_mentions(.python, whole, &.{"assert args at entry"});
    try expect_mentions(.go, indexed, &.{"rest"});
}

test "a python keyword variadic is always a dict and is exempt however it is used" {
    const unmentioned = "def ensure(**kwargs):\n    work()\n";
    const read = "def get(**kwargs):\n    return kwargs[\"pk\"]\n";
    const annotated = "def get(**options: object):\n    return options[\"pk\"]\n";
    const rebound = "def get(**kwargs):\n    kwargs = dict(kwargs)\n    return kwargs\n";
    const spaced = "def get(** kwargs):\n    return kwargs\n";
    const method = "class View:\n    def get(self, **kwargs):\n        return kwargs\n";

    try testing.expect_quiet(@This(), .python, unmentioned);
    try testing.expect_quiet(@This(), .python, read);
    try testing.expect_quiet(@This(), .python, annotated);
    try testing.expect_quiet(@This(), .python, rebound);
    try testing.expect_quiet(@This(), .python, spaced);
    try testing.expect_quiet(@This(), .python, method);
}

test "the keyword variadic exemption reaches no other parameter or language" {
    const named = "def get(count, **kwargs):\n    return work(count, kwargs)\n";
    const positional = "def get(*args, **kwargs):\n    return work(args, kwargs)\n";
    const named_kwargs = "def get(kwargs):\n    return work(kwargs)\n";
    const javascript = "function run(...rest) {\n  return rest[0];\n}\n";

    try expect_mentions(.python, named, &.{"assert count at entry"});
    try expect_mentions(.python, positional, &.{"assert args at entry"});
    try expect_mentions(.python, named_kwargs, &.{"assert kwargs at entry"});
    try expect_mentions(.javascript, javascript, &.{"rest"});
}

test "a named parameter forwarded to a call is still reported" {
    try expect_mentions(.python, "def show(count):\n    work(count)\n", &.{"count"});
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

test "a python stub whose body is an ellipsis carries none and is exempt" {
    const source = "class Reader(Protocol):\n    def read(self, sector: int) -> list: ...\n\n" ++
        "    def seek(self, sector: int) -> None:\n        ...\n\n\n" ++
        "def walk(sector: int) -> None:\n    work(sector)\n";

    try expect_mentions(.python, source, &.{"sector"});
    try expect_count(.python, source, 1);
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

test "a python discard at entry marks a parameter the body never reads" {
    const discarded = "def authenticate(self, request: Payload, **kwargs: object) -> None:\n" ++
        "    _ = request\n    _ = kwargs\n";

    const late = "def apply(count):\n    work(count + 1)\n    _ = count\n";

    try testing.expect_quiet(@This(), .python, discarded);
    try expect_mentions(.python, late, &.{"assert count at entry"});
}

test "a parameter the body never mentions still needs its discard" {
    const bare = "def ensure(sender, connection, *args):\n    _ = sender\n" ++
        "    connection.close()\n";

    const discarded = "def ensure(sender, connection, *args):\n    _ = sender\n" ++
        "    _ = args\n    connection.close()\n";

    const go = "package main\n\nfunc ensure(count int) {\n\t_ = count\n}\n";

    try expect_mentions(.python, bare, &.{"assert connection, args at entry"});
    try expect_mentions(.python, discarded, &.{"assert connection at entry"});
    try expect_mentions(.go, go, &.{"count"});
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

test "a compile error guard validates a comptime parameter at entry" {
    const source = "fn Ring(comptime capacity: u32) type {\n" ++
        "    if (capacity == 0) {\n        @compileError(\"empty\");\n    }\n\n" ++
        "    return [capacity]u8;\n}\n" ++
        "fn Line(comptime width: u32) type {\n" ++
        "    if (width > 64) @compileError(\"wide\");\n\n    return [width]u8;\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "a parameter named only in a compile error message is not asserted" {
    const source = "fn require(comptime scope: type, comptime name: []const u8, " ++
        "comptime label: []const u8) void {\n" ++
        "    if (!@hasDecl(scope, name)) {\n" ++
        "        @compileError(\"missing \" ++ label ++ \" \" ++ name);\n    }\n}\n";

    try expect_mentions(.zig, source, &.{"label"});
}

test "a compile error branch that also does work is not a guard" {
    const source = "fn Ring(comptime capacity: u32) type {\n" ++
        "    if (capacity == 0) {\n        @compileError(\"empty\");\n        work(capacity);\n" ++
        "    }\n\n    return [capacity]u8;\n}\n";

    try expect_mentions(.zig, source, &.{"capacity"});
}

test "a guard returning a member of the function's named error set validates" {
    const source = "fn write(source: []const u8) Error!void {\n" ++
        "    if (source.len > 16) return Error.Full;\n    copy(source);\n}\n" ++
        "fn send(source: []const u8) (Error || Other)!void {\n" ++
        "    if (source.len > 16) {\n        return Other.Full;\n    }\n\n    copy(source);\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "a guard returning a member of an error set the file declares validates" {
    const source = "const Failure = error{Full};\n\n" ++
        "fn write(source: []const u8) !void {\n" ++
        "    if (source.len > 16) return Failure.Full;\n    copy(source);\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "returning a member of a set that is not an error set is not a guard" {
    const source = "const Mode = enum { off, on };\n\n" ++
        "fn pick(source: []const u8) Mode {\n" ++
        "    if (source.len > 16) return Mode.off;\n    copy(source);\n\n    return .on;\n}\n";

    try expect_mentions(.zig, source, &.{"source"});
}

test "a postcondition on state the function wrote is not a late contract" {
    const source = "const Selection = struct {\n    count: u32,\n};\n\n" ++
        "fn count_set(selection: *Selection, count: u32) void {\n" ++
        "    selection.count = count;\n\n    assert(selection.count == count);\n}\n\n" ++
        "fn count_checked(selection: *Selection, count: u32) void {\n" ++
        "    selection.count = count;\n\n    assert(count < 16);\n}\n";

    try expect_mentions(.zig, source, &.{"assert count at entry"});
}

test "a guard after a use remains too late" {
    const source = "fn write(source: []const u8) error{Full}!void {\n" ++
        "    copy(source);\n    if (source.len > 16) return error.Full;\n}\n";

    try expect_mentions(.zig, source, &.{"source"});
}

test "a python raise guard validates a parameter at entry" {
    const source = "def read(sector):\n    if sector <= 0:\n" ++
        "        raise ValueError('sector')\n\n    return sector\n" ++
        "def write(sector):\n    if sector <= 0: raise ValueError('sector')\n    return sector\n" ++
        "def send(sector):\n    if sector <= 0:\n        message = f'bad {sector}'\n" ++
        "        raise ValueError(message)\n\n    return sector\n";

    try testing.expect_quiet(@This(), .python, source);
}

test "a python raise guard asserts only the names its condition mentions" {
    const source = "def read(sector, label):\n    if sector <= 0:\n" ++
        "        raise ValueError(label)\n\n    return sector\n";

    try expect_mentions(.python, source, &.{"label"});
}

test "a python branch that also does work or carries an else is not a guard" {
    const source = "def read(sector):\n    if sector <= 0:\n        log(sector)\n" ++
        "        raise ValueError('sector')\n\n    return sector\n" ++
        "def write(sector):\n    if sector <= 0:\n        raise ValueError('sector')\n" ++
        "    else:\n        sector = 1\n\n    return sector\n";

    try expect_mentions(.python, source, &.{ "sector", "sector" });
}

test "a python nested raise guard validates an optional parameter at entry" {
    const source = "def read(sector, label):\n    if sector is not None:\n" ++
        "        if sector <= 0:\n            raise ValueError('sector')\n\n" ++
        "    if label is not None:\n        if not label:\n" ++
        "            message = f'bad {label}'\n            raise ValueError(message)\n\n" ++
        "    return sector\n";

    try testing.expect_quiet(@This(), .python, source);
}

test "a python nested branch that handles the inner case is not a guard" {
    const source = "def read(sector):\n    if sector is not None:\n" ++
        "        if sector <= 0:\n            raise ValueError('sector')\n" ++
        "        else:\n            sector = 1\n\n    return sector\n" ++
        "def write(sector):\n    if sector is not None:\n" ++
        "        if sector <= 0:\n            raise ValueError('sector')\n" ++
        "        log(sector)\n\n    return sector\n";

    try expect_mentions(.python, source, &.{ "sector", "sector" });
}

test "a python raise guard after a use remains too late" {
    const source = "def write(sector):\n    copy(sector)\n    if sector <= 0:\n" ++
        "        raise ValueError('sector')\n";

    try expect_mentions(.python, source, &.{"sector"});
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

test "a value the function encodes whole with std.mem.writeInt has no input domain" {
    const source = "const Writer = struct {\n    buffer: [8]u8,\n\n" ++
        "    fn put_raw(writer: *Writer, comptime T: type, value: T) void {\n" ++
        "        std.mem.writeInt(T, writer.buffer[0..@sizeOf(T)], value, .little);\n" ++
        "    }\n\n" ++
        "    pub fn put_u32(writer: *Writer, value: u32) void {\n" ++
        "        writer.put_raw(u32, value);\n    }\n};\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "a value that picks the target of std.mem.writeInt or reaches an unknown method is reported" {
    const source = "fn put(target: *[8]u8, offset: u32) void {\n" ++
        "    std.mem.writeInt(u32, target[offset..][0..4], 1, .little);\n}\n" ++
        "fn send(writer: *Writer, value: u32) void {\n    writer.transmit(value);\n}\n";

    try expect_mentions(.zig, source, &.{ "offset", "value" });
}

test "a method forwarding into a method with a narrower precondition is reported" {
    const source = "const Writer = struct {\n    count: u32,\n\n" ++
        "    fn narrow(writer: *Writer, value: u32) void {\n" ++
        "        assert(value < 10);\n        writer.count = value;\n    }\n\n" ++
        "    pub fn forward(writer: *Writer, value: u32) void {\n" ++
        "        writer.narrow(value);\n    }\n};\n";

    try expect_mentions(.zig, source, &.{"value"});
}

test "a forward is judged by the one parameter it reaches" {
    const source = "fn handle(message: u32, slot: u32) bool {\n" ++
        "    assert(slot < 4);\n\n    return message == slot;\n}\n\n" ++
        "fn forward(message: u32, slot: u32) bool {\n" ++
        "    return handle(message, slot);\n}\n";

    try expect_mentions(.zig, source, &.{"assert slot at entry"});
}

test "a parameter named only inside a return does not flow into the binding" {
    const source = "const Create = struct {\n    params: ?*anyopaque,\n};\n\n" ++
        "fn fallback(message: u32) isize {\n    return if (message == 0) 0 else 1;\n}\n\n" ++
        "fn store(context: *anyopaque) void {\n    _ = context;\n}\n\n" ++
        "fn procedure(message: u32, create: *const Create) isize {\n" ++
        "    if (message == 1) {\n" ++
        "        const context = create.params orelse return fallback(message);\n\n" ++
        "        store(@ptrCast(context));\n    }\n\n" ++
        "    return fallback(message);\n}\n\n" ++
        "fn widened(width: u32) u32 {\n" ++
        "    const value = if (width > 4) width else return width;\n\n" ++
        "    return value * 2;\n}\n";

    try expect_mentions(.zig, source, &.{"assert width at entry"});
}

test "a field named like a parameter is not a use of the parameter" {
    const source = "const Completion = struct {\n    context: ?*anyopaque,\n" ++
        "    callback: *const fn (*Completion) void,\n};\n\n" ++
        "fn next_tick(\n    comptime Context: type,\n    context: Context,\n" ++
        "    comptime callback: fn (Context, *Completion) void,\n" ++
        "    completion: *Completion,\n) void {\n" ++
        "    completion.* = .{\n        .context = context,\n        .callback = struct {\n" ++
        "            fn on_complete(done: *Completion) void {\n" ++
        "                callback(@ptrCast(@alignCast(done.context)), done);\n" ++
        "            }\n        }.on_complete,\n    };\n}\n\n" ++
        "fn scaled(comptime Value: type, value: Value) Value {\n    return value * 2;\n}\n";

    try expect_mentions(.zig, source, &.{"assert value at entry"});
}

test "a type declared in the body is not a copy of the parameter it mentions" {
    const source = "fn TableType(comptime Key: type, comptime sentinel: Key) type {\n" ++
        "    return struct {\n        pub const sentinel_key = sentinel;\n\n" ++
        "        pub const Builder = struct {\n            key_max: Key,\n\n" ++
        "            pub fn finish(builder: *Builder) void {\n" ++
        "                assert(builder.key_max < sentinel_key);\n            }\n        };\n" ++
        "    };\n}\n\n" ++
        "fn LimitType(comptime Key: type, comptime limit: Key) type {\n" ++
        "    return struct {\n        pub const doubled = limit * 2;\n    };\n}\n";

    try expect_mentions(.zig, source, &.{"assert limit at entry"});
}

test "an opaque handle forwarded through a total conversion needs no contract" {
    const source = "const Code = enum(u32) { _ };\n\n" ++
        "fn sink(value: u32) bool {\n    return value == 7;\n}\n\n" ++
        "fn post(code: Code) bool {\n    return sink(@intFromEnum(code));\n}\n\n" ++
        "fn inspect(code: Code) bool {\n    return sink(@intFromEnum(code) + 1);\n}\n";

    try expect_mentions(.zig, source, &.{"assert code at entry"});
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
