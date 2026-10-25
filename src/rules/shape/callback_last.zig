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
const Parameter = scylla.View.Parameter;
const Rule = scylla.rule.Rule;
const Sink = scylla.rule.Sink;
const View = scylla.View;
const is_identifier_part = scan.is_identifier_part;
const parameter_count_max = scylla.limits.parameter_count_max;

pub const rule: Rule = .{
    .citations = &.{
        .{
            .standard = "TigerStyle",
            .text = "\"Callbacks go last in the list of parameters. This mirrors control flow: " ++
                "callbacks are also _invoked_ last.\"",
        },
    },
    .code = "TS034",
    .default_on = false,
    .description = "A callback parameter comes last, because it is the one the function invokes.",
    .explanation = "",
    .fix_title = "",
    .fixable = .sometimes,
    .group = .stable,
    .name = "callback-last",
    .severity = .warning,
    .summary = "Put callbacks last in the parameter list",
    .url = "",
};

const Aliases = struct {
    count: u32,
    names: [alias_count_max][]const u8,
    state: State,

    const State = enum { listed, overflowed, pending };
    const pending: Aliases = .{ .count = 0, .names = undefined, .state = .pending };

    fn includes(aliases: *Aliases, context: *const Context, name: []const u8) bool {
        assert(name.len > 0);

        if (aliases.state == .pending) aliases.list(context);

        assert(aliases.state != .pending);
        assert(aliases.count <= alias_count_max);

        for (aliases.names[0..aliases.count]) |listed| {
            if (std.mem.eql(u8, listed, name)) return true;
        }

        if (aliases.state == .listed) return false;
        return aliases_a_function(context, name);
    }

    fn list(aliases: *Aliases, context: *const Context) void {
        assert(aliases.state == .pending);
        assert(aliases.count == 0);

        aliases.state = .listed;

        var structs = context.views(.@"struct");

        for (0..structs.remaining) |_| {
            const held = structs.next() orelse break;

            aliases.record(context, held);
        }

        var functions = context.views(.function);

        for (0..functions.remaining) |_| {
            const held = functions.next() orelse break;
            const function = held.as_function() orelse continue;
            if (function.body() != null) continue;

            aliases.record(context, held);
        }

        var declarations = context.views(.declaration);

        for (0..declarations.remaining) |_| {
            const held = declarations.next() orelse break;
            const parent = held.parent() orelse continue;
            if (parent.category() != .file) continue;

            aliases.record(context, held);
        }
    }

    fn record(aliases: *Aliases, context: *const Context, view: View) void {
        assert(aliases.state != .pending);
        assert(aliases.count <= alias_count_max);

        if (aliases.state == .overflowed) return;

        const declared = declared_name_of(context, view);
        if (declared.len == 0) return;
        if (!carries_a_marker(context, alias_head(context, view))) return;

        if (aliases.count == alias_count_max) {
            aliases.state = .overflowed;

            return;
        }

        aliases.names[aliases.count] = declared;
        aliases.count += 1;
    }
};

const alias_count_max: u32 = 256;
const alias_marker_word = "type";
const body_opener = '{';
const class_type_opener = '[';
const bound_ends = ",>{\n";
const bound_introducers = [_][]const u8{ ":", "extends" };
const comptime_word = "comptime";
const mutable_word = "mut ";
const receiver_word = "self";
const reference_mark = "&";
const sequence_opener = "[";
const sequence_prefix_count_max: u32 = 8;
const type_names = [_][]const u8{ "type", "typeid" };
const unsafe_word = "unsafe";

pub fn run(context: *const Context, sink: *Sink) void {
    var aliases: Aliases = .pending;
    var functions = support.functions_and_bound_lambdas(context);

    for (0..context.front.node_count()) |_| {
        const function = functions.next() orelse break;
        const held = function.as_function() orelse continue;
        if (dictated_by_the_other_side(context, function, held)) continue;

        const opening = callback_before_a_required(context, &aliases, held) orelse continue;

        assert(opening.span.end() <= context.source.len);
        assert(opening.span.offset >= function.span().offset);

        sink.report(
            opening.span,
            "the callback comes before another parameter; callbacks go last",
        );
    }
}

fn dictated_by_the_other_side(context: *const Context, function: View, held: Function) bool {
    const markers = context.conventions.pointer_boundary_markers;
    if (markers.len == 0) return false;
    if (declared_in_a_foreign_block(context, function)) return true;

    const span = function.span();
    const parameters = held.parameters_span() orelse return false;
    const open = context.lexer_index_from(parameters.offset);
    const close = context.pairs.partner_of(open) orelse return false;
    if (context.tokens[close].end() > parameters.end()) return false;

    const body = if (held.body()) |found| found.span().offset else span.end();
    const first = context.lexer_index_from(context.line_span(context.line_of(span.offset)).offset);
    const last = context.lexer_index_from(body);

    assert(first <= open);
    assert(close < last);

    for (context.tokens[first..last], first..) |token, index| {
        if (index >= open) {
            if (index <= close) continue;
        }

        if (token.kind != .keyword) continue;
        if (scan.word_listed(markers, context.text(token))) return true;
    }

    return false;
}

fn declared_in_a_foreign_block(context: *const Context, function: View) bool {
    const token = context.lexer_index_from(function.span().offset);
    if (token >= context.tokens.len) return false;

    var frames = Frame.covering(context, token);

    for (0..context.front.node_count()) |_| {
        const covering = frames.next() orelse return false;

        assert(covering.frame.covers(token));

        if (opens_a_foreign_block(context, covering.frame.opening_line(context))) {
            return true;
        }
    }

    return false;
}

fn opens_a_foreign_block(context: *const Context, opening: []const u8) bool {
    const markers = context.conventions.pointer_boundary_markers;
    const trimmed = std.mem.trimStart(u8, opening, scan.ascii_whitespace);
    const word = leading_word(trimmed);

    assert(markers.len > 0);
    assert(std.mem.findScalar(u8, opening, '\n') == null);

    if (!std.mem.eql(u8, word, unsafe_word)) return scan.word_listed(markers, word);

    const rest = std.mem.trimStart(u8, trimmed[word.len..], scan.ascii_whitespace);
    return scan.word_listed(markers, leading_word(rest));
}

fn leading_word(text: []const u8) []const u8 {
    for (text, 0..) |byte, index| {
        if (!is_identifier_part(byte)) return text[0..index];
    }

    return text;
}

fn callback_before_a_required(
    context: *const Context,
    aliases: *Aliases,
    function: Function,
) ?Parameter {
    var parameters = function.parameters();
    var first: ?Parameter = null;
    var last: ?Parameter = null;

    for (0..parameter_count_max + 1) |_| {
        const parameter = parameters.next() orelse break;

        if (first == null) {
            if (is_callback(context, aliases, function, parameter)) {
                first = parameter;

                continue;
            }
        }

        if (first == null) continue;
        if (parameter.default != null) continue;
        if (shape.starred(context, parameter)) continue;

        last = parameter;
    }

    const opening = first orelse return null;
    const closing = last orelse return null;

    assert(closing.span.offset >= opening.span.offset);
    assert(closing.default == null);

    if (opening.group == closing.group) return null;
    if (is_callback(context, aliases, function, closing)) return null;
    return opening;
}

fn is_callback(
    context: *const Context,
    aliases: *Aliases,
    function: Function,
    parameter: Parameter,
) bool {
    assert(parameter.span.end() <= context.source.len);

    if (shape.preceded_by(context, parameter, comptime_word)) return false;

    if (parameter.name) |named| {
        const spelled = context.front_text(named);
        if (std.mem.eql(u8, spelled, receiver_word)) return false;
        if (scan.word_listed(context.conventions.receiver_names, spelled)) return false;
    }

    if (parameter.default) |value| {
        switch (value.category()) {
            .function, .lambda => return true,
            else => {},
        }
    }

    if (parameter.type_span) |spelled| {
        const text = scan.trim_ascii(context.span_text(spelled));

        assert(text.len <= spelled.length);

        if (spells_a_sequence(text)) return false;
        if (scan.word_listed(&type_names, text)) return false;
        if (carries_a_marker(context, text)) return true;
        if (callable_type_parameter(context, aliases, function, text)) return true;
        if (names_a_class_type(context, text)) return false;
    }

    const name = parameter.name orelse return false;
    const text = context.front_text(name);

    assert(text.len > 0);

    if (names_a_class(context, text)) return false;
    return invoked_in(context, function, text);
}

fn spells_a_sequence(text: []const u8) bool {
    var rest = text;

    for (0..sequence_prefix_count_max) |_| {
        const trimmed = std.mem.trimStart(u8, rest, scan.ascii_whitespace);

        if (std.mem.startsWith(u8, trimmed, reference_mark)) {
            rest = trimmed[reference_mark.len..];

            continue;
        }

        if (std.mem.startsWith(u8, trimmed, mutable_word)) {
            rest = trimmed[mutable_word.len..];

            continue;
        }

        return std.mem.startsWith(u8, trimmed, sequence_opener);
    }

    return false;
}

fn callable_type_parameter(
    context: *const Context,
    aliases: *Aliases,
    function: Function,
    text: []const u8,
) bool {
    if (!names_a_type_parameter(context, text)) return false;

    assert(text.len > 0);
    assert(is_identifier_part(text[text.len - 1]));

    if (bounded_as_a_function(context, function, text)) return true;
    return aliases.includes(context, text);
}

fn carries_a_marker(context: *const Context, text: []const u8) bool {
    assert(text.len <= context.source.len);

    for (context.conventions.callback_markers) |marker| {
        assert(marker.len > 0);

        if (spells_a_marker(text, marker)) return true;
    }

    return false;
}

fn spells_a_marker(text: []const u8, marker: []const u8) bool {
    assert(marker.len > 0);
    assert(text.len <= std.math.maxInt(u32));

    const opens_a_word = is_identifier_part(marker[0]);
    const closes_a_word = is_identifier_part(marker[marker.len - 1]);
    var offset: usize = 0;

    for (0..text.len) |_| {
        const found = offset + (scan.find(text[offset..], marker) orelse return false);
        const end = found + marker.len;
        const opened = !opens_a_word or found == 0 or !is_identifier_part(text[found - 1]);
        const closed = !closes_a_word or end == text.len or !is_identifier_part(text[end]);

        assert(found >= offset);
        assert(end <= text.len);

        if (opened) {
            if (closed) return true;
        }

        offset = found + 1;
    }

    return false;
}

fn names_a_class_type(context: *const Context, text: []const u8) bool {
    assert(text.len <= context.source.len);

    for (context.conventions.class_type_names) |name| {
        assert(name.len > 0);

        if (!std.mem.startsWith(u8, text, name)) continue;
        if (text.len == name.len) return true;
        if (text[name.len] == class_type_opener) return true;
    }

    return false;
}

fn names_a_class(context: *const Context, name: []const u8) bool {
    assert(name.len > 0);

    for (context.conventions.class_name_suffixes) |suffix| {
        assert(suffix.len > 0);

        if (std.mem.endsWith(u8, name, suffix)) return true;
    }

    if (!context.conventions.class_names_title_case) return false;
    if (!std.ascii.isUpper(name[0])) return false;

    for (name[1..]) |byte| {
        if (std.ascii.isLower(byte)) return true;
    }

    return false;
}

fn names_a_type_parameter(context: *const Context, text: []const u8) bool {
    if (text.len == 0) return false;

    assert(text.len <= context.source.len);

    for (text) |byte| {
        if (!is_identifier_part(byte)) return false;
    }

    assert(is_identifier_part(text[0]));

    return !support.is_primitive_type(context, text);
}

fn bounded_as_a_function(context: *const Context, function: Function, name: []const u8) bool {
    const parameters = function.parameters_span() orelse return false;
    const span = function.view.span();
    const body_start = if (function.body()) |body| body.span().offset else span.end();
    const opens = @max(body_start, parameters.end());

    assert(parameters.offset >= span.offset);
    assert(opens <= context.source.len);

    const head = context.source[span.offset..parameters.offset];
    const tail = context.source[parameters.end()..opens];

    if (bound_of(head, name)) |bound| {
        if (carries_a_marker(context, bound)) return true;
    }

    const bound = bound_of(tail, name) orelse return false;
    return carries_a_marker(context, bound);
}

fn bound_of(text: []const u8, name: []const u8) ?[]const u8 {
    assert(name.len > 0);

    var cursor: usize = 0;

    for (0..text.len + 1) |_| {
        if (cursor >= text.len) break;

        const found = scan.find(text[cursor..], name) orelse return null;
        const at = cursor + found;
        const after = at + name.len;

        cursor = after;

        if (at > 0) {
            if (is_identifier_part(text[at - 1])) continue;
        }

        if (after < text.len) {
            if (is_identifier_part(text[after])) continue;
        }

        const introduced = introduced_of(text[after..]) orelse continue;
        if (std.mem.startsWith(u8, introduced, ":")) continue;

        const end = std.mem.findAny(u8, introduced, bound_ends) orelse introduced.len;

        assert(end <= introduced.len);

        return introduced[0..end];
    }

    return null;
}

fn introduced_of(text: []const u8) ?[]const u8 {
    const rest = std.mem.trimStart(u8, text, scan.ascii_whitespace);

    assert(rest.len <= text.len);

    for (bound_introducers) |word| {
        if (!std.mem.startsWith(u8, rest, word)) continue;

        assert(rest.len >= word.len);

        return rest[word.len..];
    }

    return null;
}

fn aliases_a_function(context: *const Context, name: []const u8) bool {
    assert(name.len > 0);

    var structs = context.views(.@"struct");

    for (0..structs.remaining) |_| {
        const held = structs.next() orelse break;
        if (declares_a_callable(context, held, name)) return true;
    }

    var functions = context.views(.function);

    for (0..functions.remaining) |_| {
        const held = functions.next() orelse break;
        const function = held.as_function() orelse continue;
        if (function.body() != null) continue;
        if (declares_a_callable(context, held, name)) return true;
    }

    var declarations = context.views(.declaration);

    for (0..declarations.remaining) |_| {
        const held = declarations.next() orelse break;
        const parent = held.parent() orelse continue;

        assert(parent.index() < held.index());

        if (parent.category() != .file) continue;
        if (declares_a_callable(context, held, name)) return true;
    }

    return false;
}

fn declares_a_callable(context: *const Context, view: View, name: []const u8) bool {
    assert(name.len > 0);

    const declared = declared_name_of(context, view);
    if (!std.mem.eql(u8, declared, name)) return false;

    assert(declared.len > 0);

    return carries_a_marker(context, alias_head(context, view));
}

fn alias_head(context: *const Context, view: View) []const u8 {
    const text = view.text(context.source);
    const container = view.as_container() orelse return brace_head(text);
    const body = container.body();
    if (body.index() == view.index()) return brace_head(text);

    const span = view.span();
    const opened = body.span().offset;

    assert(opened >= span.offset);
    assert(opened <= span.end());

    return brace_head(context.source[span.offset..opened]);
}

fn brace_head(text: []const u8) []const u8 {
    const body = std.mem.findScalar(u8, text, body_opener) orelse return text;
    const head = text[0..body];

    assert(head.len < text.len);
    assert(text[head.len] == body_opener);

    return head;
}

fn declared_name_of(context: *const Context, view: View) []const u8 {
    if (view.name_token()) |name| return context.front_text(name);

    const tokens = context.tokens_in(view.span());
    const head = @min(tokens.len, shape.member_modifier_max + 1);

    assert(head <= tokens.len);
    assert(head <= shape.member_modifier_max + 1);

    for (tokens[0..head]) |token| {
        if (token.kind == .identifier) return context.text(token);
        if (token.kind != .keyword) continue;
        if (std.mem.eql(u8, context.text(token), alias_marker_word)) continue;

        break;
    }

    return "";
}

fn invoked_in(context: *const Context, function: Function, name: []const u8) bool {
    const body = function.body() orelse return false;
    var calls = support.calls_within(context, body.span());

    assert(body.span().end() <= context.source.len);

    for (0..calls.remaining) |_| {
        const call = calls.next() orelse break;
        const held = call.as_call() orelse continue;
        const callee = held.callee() orelse continue;

        assert(callee.index() > call.index());

        if (calls_the_name(context, callee, name)) return true;
    }

    return false;
}

fn calls_the_name(context: *const Context, callee: View, name: []const u8) bool {
    assert(name.len > 0);

    if (callee.category() != .name) return false;
    if (!std.mem.eql(u8, callee.text(context.source), name)) return false;

    const start = context.lexer_index_from(callee.span().offset);

    assert(start <= context.tokens.len);

    if (start > 0) {
        if (context.tokens[start - 1].is_punctuation(.dot)) return false;
    }

    const after = context.lexer_index_from(callee.span().end());

    assert(after <= context.tokens.len);

    if (after >= context.tokens.len) return false;
    return context.tokens[after].is_punctuation(.paren_open);
}

fn expect_one(language: scylla.Language, source: []const u8) !void {
    var findings = try testing.analyze(@This(), language, source);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
}

test "a javascript parameter the body invokes is a callback" {
    try expect_one(.javascript, "function run(handler, name) {\n    handler(name);\n}\n");

    const last = "function run(name, handler) {\n    handler(name);\n}\n";

    try testing.expect_quiet(@This(), .javascript, last);
}

test "a parameter whose default is a lambda is a callback" {
    const source = "def run(handler=lambda: 1, value=2):\n    return value\n";

    try testing.expect_quiet(@This(), .python, source);

    const required = "def run(handler=lambda: 1, value):\n    return value\n";

    try expect_one(.python, required);
}

test "a rust type parameter bounded by fn is a callback" {
    const generic = "fn run<F: Fn(u32)>(handler: F, name: &str) {\n    work(name);\n}\n";

    try expect_one(.rust, generic);

    const clause = "fn run<F>(handler: F, name: &str)\nwhere\n    F: FnMut(u32),\n{\n    " ++
        "work(name);\n}\n";

    try expect_one(.rust, clause);
}

test "a file local alias of a function type is a callback" {
    const go = "package main\n\ntype Handler func(int)\n\nfunc run(handler Handler, name " ++
        "string) {\n\twork(name)\n}\n";

    try expect_one(.go, go);

    const typescript = "type Handler = (v: number) => void;\n\nfunction run(handler: Handler, " ++
        "name: string): void {\n    work(name);\n}\n";

    try expect_one(.typescript, typescript);

    const odin = "package main\n\nHandler :: proc(int)\n\nrun :: proc(handler: Handler, name: " ++
        "string) {\n    work(name)\n}\n";

    try expect_one(.odin, odin);
}

test "a function a foreign block declares keeps the order the other side fixes" {
    const declared = "extern \"C\" {\n    fn set_timeout(\n" ++
        "        callback: extern \"C\" fn(*mut c_void),\n        delay: f64,\n" ++
        "        data: *mut c_void,\n    ) -> i32;\n}\n";

    const unsafe_declared = "unsafe extern \"C\" {\n" ++
        "    fn set_timeout(callback: extern \"C\" fn(*mut c_void), delay: f64) -> i32;\n}\n";

    const odin = "package main\n\nforeign lib {\n" ++
        "    set_timeout :: proc(callback: proc \"c\" (rawptr), delay: f64) -> i32 ---\n}\n";

    const defined = "mod timer {\n    fn set_timeout(callback: fn(u32), delay: f64) -> i32 {\n" ++
        "        callback(1);\n        0\n    }\n}\n";

    try testing.expect_quiet(@This(), .rust, declared);
    try testing.expect_quiet(@This(), .rust, unsafe_declared);
    try testing.expect_quiet(@This(), .odin, odin);
    try expect_one(.rust, defined);
}

test "a receiver the body calls is no callback" {
    const rust = "impl<T: Fn(&mut App)> Plugin for T {\n    fn build(&self, app: &mut App) {\n" ++
        "        self(app);\n    }\n}\n";

    const python = "class Hook:\n    def run(self, app):\n        self(app)\n";

    const after = "impl Runner {\n    fn run(&self, handler: impl Fn(u32), name: &str) {\n" ++
        "        handler(1);\n    }\n}\n";

    try testing.expect_quiet(@This(), .rust, rust);
    try testing.expect_quiet(@This(), .python, python);
    try expect_one(.rust, after);
}

test "a sequence of callbacks is not a callback" {
    const source = "fn invoke(list: &[fn(&str) -> Option<u32>], executable: &str) -> u32 {\n" ++
        "    0\n}\n";

    const single = "fn invoke(check: fn(&str) -> bool, executable: &str) -> u32 {\n" ++
        "    0\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
    try expect_one(.rust, single);
}

test "a zig context after the callback is reported" {
    const source = "fn read(callback: *const fn (*Context) void, context: *Context) void {\n    " ++
        "callback(context);\n}\n";

    try expect_one(.zig, source);
}

test "a struct whose body mentions a callable is not an alias" {
    const source = "const Blob = struct {\n    destroy: *const fn () void,\n\n" ++
        "    fn wrap(self: *Blob, name: u32) void {\n        _ = self;\n        _ = name;\n" ++
        "    }\n};\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "a python class whose body mentions a callable is not an alias" {
    const class = "class Action(Holder):\n    def __init__(self, type: Callable[[str], int]) -> " ++
        "None:\n        self.type = type\n\n\ndef check(action: Action, name: str) -> None:\n" ++
        "    work(name)\n";

    const alias = "Handler = Callable[[int], None]\n\n\n" ++
        "def run(handler: Handler, name: str) -> None:\n    work(name)\n";

    try testing.expect_quiet(@This(), .python, class);
    try expect_one(.python, alias);
}

test "a marker inside a longer name is no marker" {
    const longer = "def check(callee_type: CallableType, name: str) -> None:\n" ++
        "    work(callee_type, name)\n";

    const marked = "def check(callee: Callable[[int], None], name: str) -> None:\n" ++
        "    work(callee, name)\n";

    try testing.expect_quiet(@This(), .python, longer);
    try expect_one(.python, marked);
}

test "a zig alias of a function type is still a callback" {
    const source = "const Handler = *const fn (u32) void;\n\n" ++
        "fn run(handler: Handler, name: u32) void {\n    _ = handler;\n    _ = name;\n}\n";

    try expect_one(.zig, source);
}

test "a python parameter annotated as a class is constructed rather than called back" {
    const class = "def parse(parser_type: type[Any], data: bytes) -> Any:\n" ++
        "    return parser_type(data)\n";

    const untyped = "def parse(parser, data):\n    return parser(data)\n";

    try testing.expect_quiet(@This(), .python, class);
    try expect_one(.python, untyped);
}

test "a class method's receiver is constructed rather than called back" {
    const receiver = "class Vector:\n    @classmethod\n    def from_parameter(cls, config):\n" ++
        "        return cls(config)\n";

    const callback = "class Vector:\n    @classmethod\n    def from_parameter(build, config):\n" ++
        "        return build(config)\n";

    try testing.expect_quiet(@This(), .python, receiver);
    try expect_one(.python, callback);
}

test "a python parameter named as a class is constructed rather than called back" {
    const suffixed = "def create(pk, klass, data):\n    return klass(id=pk)\n\n\n" ++
        "def alter(migration_class, name):\n    return migration_class(name)\n";

    const titled = "def build(Model, data, db):\n    return Model(**data)\n";
    const factory = "def create(pk, factory, data):\n    return factory(id=pk)\n";
    const screaming = "def create(PK, FACTORY, data):\n    return FACTORY(id=PK)\n";

    try testing.expect_quiet(@This(), .python, suffixed);
    try testing.expect_quiet(@This(), .python, titled);
    try expect_one(.python, factory);
    try expect_one(.python, screaming);
}

test "a signature the other side dictates keeps its order" {
    const exported = "export fn add_listener(proxy: ?*Proxy, implementation: " ++
        "*const fn () callconv(.c) void, data: ?*anyopaque) c_int {\n" ++
        "    return listen(proxy, implementation, data);\n}\n";

    const convention = "fn add_listener(\n    proxy: ?*Proxy,\n" ++
        "    implementation: *const fn () void,\n    data: ?*anyopaque,\n" ++
        ") callconv(.c) c_int {\n    return listen(proxy, implementation, data);\n}\n";

    const own = "fn add_listener(proxy: ?*Proxy, implementation: " ++
        "*const fn () callconv(.c) void, data: ?*anyopaque) c_int {\n" ++
        "    return listen(proxy, implementation, data);\n}\n";

    try testing.expect_quiet(@This(), .zig, exported);
    try testing.expect_quiet(@This(), .zig, convention);
    try expect_one(.zig, own);
}

test "a parameter list the lexer closes past the parser's parameters dictates nothing" {
    try testing.expect_quiet(@This(), .go, "func([))");
}

test "an odin type parameter or a member call of the same name is no callback" {
    const source = "package p\n\nfixint :: proc($T: typeid, a: f64) -> T {\n\treturn T(a)\n}\n\n" ++
        "wait :: proc(futex: ^Futex, expected: u32) {\n\tlinux.futex(futex, expected)\n}\n\n" ++
        "create :: proc(procedure: Thread_Proc, priority: int) {\n\tt.procedure(t)\n}\n\n" ++
        "run :: proc(callback: Thread_Proc, count: int) {\n\tcallback(count)\n}\n";

    try testing.expect_anchors(@This(), .odin, source, &.{.{ 15, 13 }});
}
