const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const scan = @import("../../scan.zig");
const stream = @import("../../stream.zig");
const support = @import("../support.zig");
const testing = @import("../testing.zig");
const Call = scylla.View.Call;
const Callable = scylla.View.Function;
const Context = @import("../context.zig");
const Frame = @import("../frame.zig");
const Function = scylla.Calls.Function;
const Language = scylla.Language;
const Rule = scylla.rule.Rule;
const Sink = scylla.rule.Sink;
const Span = scylla.Span;
const Token = scylla.Token;
const View = scylla.View;
const parameter_count_max = scylla.limits.parameter_count_max;

pub const rule: Rule = .{
    .citations = &.{
        .{
            .standard = "TigerStyle",
            .text = "\"Use only very simple, explicit control flow for clarity. Do not use " ++
                "recursion to ensure that all executions that should be bounded are bounded.\"",
        },
        .{
            .standard = "NASA",
            .text = "NASA P10 Rule 1: \"Restrict all code to very simple control flow " ++
                "constructs — do not use goto statements, setjmp or longjmp constructs, and " ++
                "direct or indirect recursion.\"",
        },
    },
    .code = "TS001",
    .default_on = true,
    .description = "A function does not call itself, so stack usage is bounded by the call " ++
        "graph rather than by the input.",
    .explanation = "",
    .fix_title = "",
    .fixable = .sometimes,
    .group = .stable,
    .name = "no-recursion",
    .severity = .@"error",
    .summary = "A function must not call itself, directly or through a cycle",
    .url = "",
};

const comptime_word = "comptime";
const exporting_words = [_][]const u8{ "export", "pub" };
const implementation_target_word = "for";
const implementation_word = "impl";
const try_mark = "?";

pub fn run(context: *const Context, sink: *Sink) void {
    const functions = context.tables.functions();

    assert(functions.len <= std.math.maxInt(u32));

    for (functions, 0..) |*function, position| {
        if (!function.recursive) continue;
        if (function.@"comptime") continue;
        if (runs_only_at_compile_time(context, function)) continue;
        if (delegates_to_a_namesake(context, function, @intCast(position))) continue;
        if (reaches_no_namesake(context, function, @intCast(position))) continue;

        const anchor = anchor_of(context, function, @intCast(position)) orelse continue;
        const name = function.name.text(context.source);

        assert(anchor < context.tokens.len);

        sink.report_formatted(
            context.tokens[anchor].span(),
            "{s} takes part in a call cycle; give it an explicit stack or a bound",
            .{scan.utf8_or(name, "the call")},
        );
    }
}

fn runs_only_at_compile_time(context: *const Context, function: *const Function) bool {
    const tokens = context.tokens;
    const span = context.view(function.node).span();
    const name = function.name.text(context.source);
    const first = context.lexer_index_from(span.offset);

    assert(name.len > 0);
    assert(first < tokens.len);

    if (exported(context, first)) return false;

    var outside: u32 = 0;

    for (context.token_index.identifiers()) |index| {
        const token = tokens[index];
        if (span.contains(token.offset)) continue;
        if (!std.mem.eql(u8, context.text(token), name)) continue;

        const before = context.significant_before(index) orelse return false;
        if (!std.mem.eql(u8, context.text(tokens[before]), comptime_word)) return false;

        outside += 1;
    }

    return outside > 0;
}

fn delegates_to_a_namesake(context: *const Context, function: *const Function, position: u32) bool {
    assert(position < context.tables.functions().len);

    if (context.front.language != .rust) return false;

    for (context.tables.edges_of(function)) |edge| {
        if (edge.target != position) return false;
    }

    const view = context.view(function.node);
    const held = view.as_function() orelse return false;
    const body = held.body() orelse return false;
    const first = context.lexer_index_from(view.span().offset);
    if (first >= context.tokens.len) return false;
    if (!support.implements_a_trait(context, first)) return false;

    const statement = statement_first_of(body) orelse return false;
    const name = context.span_text(function.name);

    assert(name.len > 0);

    return evaluates_the_namesake(context, statement, name);
}

fn statement_first_of(body: View) ?View {
    var children = body.children();

    for (0..children.count()) |_| {
        const child = children.next() orelse return null;
        if (child.category() == .attribute) continue;
        return child;
    }

    return null;
}

fn evaluates_the_namesake(context: *const Context, statement: View, name: []const u8) bool {
    switch (statement.category()) {
        .branch, .loop, .match => return false,
        else => {},
    }

    var calls = support.calls_within(context, statement.span());

    for (0..calls.remaining) |_| {
        const found = calls.next() orelse return false;
        const call = found.as_call() orelse continue;
        const named = call.name_token() orelse continue;
        if (!std.mem.eql(u8, context.front_text(named), name)) continue;
        if (branches_before(context, statement, found)) return false;
        return runs_unconditionally(statement, found);
    }

    return false;
}

fn branches_before(context: *const Context, statement: View, call: View) bool {
    const first = context.lexer_index_from(statement.span().offset);
    const last = context.lexer_index_from(call.span().offset);

    assert(first <= last);
    assert(last <= context.tokens.len);

    for (context.tokens[first..last]) |token| {
        if (token.is_keyword(.lambda)) return true;
        if (token.is_keyword(.@"return")) return true;
        if (token.is_punctuation(.ampersand_double)) return true;
        if (token.is_punctuation(.bar_double)) return true;
        if (token.is_punctuation(.bang)) return true;
        if (!token.is_punctuation(.other)) continue;
        if (std.mem.eql(u8, context.text(token), try_mark)) return true;
    }

    return false;
}

fn runs_unconditionally(statement: View, call: View) bool {
    assert(call.index() >= statement.index());

    if (call.index() == statement.index()) return true;

    var ancestors = call.ancestors();

    for (0..ancestors.remaining + 1) |_| {
        const held = ancestors.next() orelse return false;
        if (held.index() == statement.index()) return true;

        switch (held.category()) {
            .branch, .condition, .except, .function, .lambda, .loop, .match => return false,
            else => {},
        }
    }

    return false;
}

fn reaches_no_namesake(context: *const Context, function: *const Function, position: u32) bool {
    assert(position < context.tables.functions().len);

    if (context.front.language != .rust) return false;

    const edges = context.tables.edges_of(function);
    if (edges.len == 0) return false;

    const view = context.view(function.node);
    const held = view.as_function() orelse return false;

    for (edges) |edge| {
        if (edge.target != position) return false;

        const call = call_of_edge(context, edge.call) orelse return false;
        if (!cannot_reach(context, view, held, call)) return false;
    }

    return true;
}

fn call_of_edge(context: *const Context, span: Span) ?Call {
    var calls = support.calls_within(context, span);

    for (0..calls.remaining) |_| {
        const found = calls.next() orelse return null;
        const held = found.span();
        if (held.offset != span.offset) continue;
        if (held.length != span.length) continue;
        return found.as_call();
    }

    return null;
}

fn cannot_reach(context: *const Context, view: View, held: Callable, call: Call) bool {
    const named = call.name_token() orelse return false;
    const name = context.lexer_index_at(context.front_token(named).offset) orelse return false;
    const method = call.receiver() != null;

    assert(name < context.tokens.len);

    if (method) {
        if (held.receiver() == null) return true;
    }

    if (arity_differs(context, held, call, name, method)) return true;
    if (method) return false;
    return qualifies_by_a_type_parameter(context, view, name);
}

fn arity_differs(
    context: *const Context,
    held: Callable,
    call: Call,
    name: u32,
    method: bool,
) bool {
    assert(name < context.tokens.len);

    if (name + 1 >= context.tokens.len) return false;
    if (!context.tokens[name + 1].is_punctuation(.paren_open)) return false;

    var parameters = held.parameters();
    var arguments = call.arguments();
    const receiver_count: u32 = @intFromBool(method);
    const parameter_count = parameters.count();
    const argument_count = arguments.count();

    assert(parameter_count <= parameter_count_max);

    return argument_count + receiver_count != parameter_count;
}

fn qualifies_by_a_type_parameter(context: *const Context, view: View, name: u32) bool {
    const tokens = context.tokens;

    assert(name < tokens.len);

    if (name < 2) return false;
    if (!context.is_path_separator(tokens[name - 1])) return false;
    if (tokens[name - 2].kind != .identifier) return false;

    if (name >= 3) {
        if (context.is_path_separator(tokens[name - 3])) return false;
    }

    const qualifier = context.text(tokens[name - 2]);
    const own = Frame.of(context, view) orelse return false;
    if (declares_a_type_parameter(context, own.header, own.start, qualifier)) return true;

    const implementation = enclosing_implementation(context, own.header) orelse return false;
    if (implements_for(context, implementation, qualifier)) return false;

    const first = implementation.header;
    const last = implementation.start;

    return declares_a_type_parameter(context, first, last, qualifier);
}

fn enclosing_implementation(context: *const Context, token: u32) ?Frame {
    assert(token < context.tokens.len);

    var frames = Frame.covering(context, token);

    for (0..context.front.node_count()) |_| {
        const covering = frames.next() orelse return null;
        const header = context.tokens[covering.frame.header];
        if (std.mem.eql(u8, context.text(header), implementation_word)) return covering.frame;
    }

    return null;
}

fn declares_a_type_parameter(
    context: *const Context,
    first: u32,
    last: u32,
    name: []const u8,
) bool {
    const tokens = context.tokens;
    const end = @min(last, @as(u32, @intCast(tokens.len)));

    assert(first <= end);

    if (end < first + 3) return false;

    for (first..end - 2) |index| {
        const opener = tokens[index];
        const declared = tokens[index + 1];
        const closer = tokens[index + 2];

        if (!opener.is_punctuation(.less)) {
            if (!opener.is_punctuation(.comma)) continue;
        }

        if (declared.kind != .identifier) continue;
        if (!std.mem.eql(u8, context.text(declared), name)) continue;
        if (closes_a_type_parameter(context, closer)) return true;
    }

    return false;
}

fn closes_a_type_parameter(context: *const Context, token: Token) bool {
    if (token.is_punctuation(.comma)) return true;
    if (token.is_punctuation(.greater)) return true;
    if (!token.is_punctuation(.colon)) return false;
    return !context.is_path_separator(token);
}

fn implements_for(context: *const Context, implementation: Frame, name: []const u8) bool {
    const tokens = context.tokens;
    const end = @min(implementation.start, @as(u32, @intCast(tokens.len)));

    assert(implementation.header <= end);

    if (end < implementation.header + 2) return false;

    for (implementation.header..end - 1) |index| {
        if (!std.mem.eql(u8, context.text(tokens[index]), implementation_target_word)) continue;

        const target = tokens[index + 1];
        if (target.kind != .identifier) continue;
        if (std.mem.eql(u8, context.text(target), name)) return true;
    }

    return false;
}

fn exported(context: *const Context, first: u32) bool {
    assert(first < context.tokens.len);

    if (scan.word_in(&exporting_words, context.text(context.tokens[first]))) return true;

    const before = context.significant_before(first) orelse return false;
    return scan.word_in(&exporting_words, context.text(context.tokens[before]));
}

fn anchor_of(context: *const Context, function: *const Function, position: u32) ?u32 {
    assert(function.recursive);
    assert(position < context.tables.functions().len);

    for (context.tables.edges_of(function)) |edge| {
        if (edge.target != position) continue;

        const index = context.lexer_index_at(edge.call.offset) orelse break;
        if (context.tokens[index].kind == .string) break;

        const start = context.pairs.receiver_start(index);

        assert(start <= index);

        return start;
    }

    const offset = context.view(function.node).span().offset;
    const declared = context.lexer_index_at(offset) orelse return null;
    const line = stream.line_start_of_token(context.tokens, context.source, declared);

    assert(line <= declared);

    return line;
}

fn expect_count(language: Language, source: []const u8, expected: u32) !void {
    assert(source.len > 0);
    assert(expected <= testing.limits.diagnostic_count_max);

    var findings = try testing.analyze(@This(), language, source);
    defer findings.deinit();

    if (findings.count() != expected) findings.print();

    try std.testing.expectEqual(expected, findings.count());
}

test "a private zig function called only at compile time is exempt" {
    const comptime_only = "fn embed(comptime path: []const u8) []const u8 {\n" ++
        "    return comptime expand(path);\n}\n\n" ++
        "fn expand(text: []const u8) []const u8 {\n    if (text.len == 0) return text;\n\n" ++
        "    return expand(text[1..]);\n}\n";

    const runtime = "fn embed(path: []const u8) []const u8 {\n    return expand(path);\n}\n\n" ++
        "fn expand(text: []const u8) []const u8 {\n    if (text.len == 0) return text;\n\n" ++
        "    return expand(text[1..]);\n}\n";

    const public = "fn embed(comptime path: []const u8) []const u8 {\n" ++
        "    return comptime expand(path);\n}\n\n" ++
        "pub fn expand(text: []const u8) []const u8 {\n    if (text.len == 0) return text;\n\n" ++
        "    return expand(text[1..]);\n}\n";

    try testing.expect_quiet(@This(), .zig, comptime_only);
    try expect_count(.zig, runtime, 1);
    try expect_count(.zig, public, 1);
}

test "a self call on a method the container lacks binds nothing" {
    const source = "class A:\n    def run(self):\n        return self.helper()\n\n\ndef " ++
        "helper():\n    a = A()\n    return a.run()\n";

    try testing.expect_quiet(@This(), .python, source);
}

test "a self call through a field resolves by the field type" {
    const source = "struct Inner;\n\nimpl Inner {\n    fn step(&self, outer: &Outer) -> u32 " ++
        "{\n        outer.run()\n    }\n}\n\nstruct Outer {\n    inner: Inner,\n}\n" ++
        "\nimpl Outer {\n    fn run(&self) -> u32 {\n        " ++
        "self.inner.step(self)\n    }\n}\n";

    try expect_count(.rust, source, 2);
}

test "an associated path call resolves by the enclosing container" {
    const source = "struct A;\n\nimpl A {\n    fn run(&self) -> u32 {\n        " ++
        "Self::run(self)\n    }\n}\n";

    try expect_count(.rust, source, 1);
}

test "a trait method whose body only calls its namesake delegates to the inherent method" {
    const source = "struct Listener;\n\nimpl Listener {\n" ++
        "    fn poll_accept(&mut self, cx: u32) -> u32 {\n        cx\n    }\n}\n\n" ++
        "impl Accept for Listener {\n    fn poll_accept(&mut self, cx: u32) -> u32 {\n" ++
        "        Self::poll_accept(self, cx)\n    }\n\n    fn kill(&mut self) -> u32 {\n" ++
        "        unsafe { self.kill() }\n    }\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
}

test "a trait method whose first statement calls its namesake delegates" {
    const source = "impl<T: Writer> Erased for T {\n" ++
        "    fn rename(&self, from: &Path, to: &Path) -> Boxed {\n" ++
        "        Box::pin(Self::rename(self, from, to))\n    }\n\n" ++
        "    fn read(&self, path: &Path) -> Result<Reader> {\n" ++
        "        let reader = Self::read(self, path)?;\n\n" ++
        "        Ok(Box::new(reader))\n    }\n\n" ++
        "    fn iter(&self) -> Iter {\n        self.iter().copied()\n    }\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
}

test "a call that cannot reach the function closes no cycle" {
    const source = "impl<I: Sorted> Phase<I> {\n    pub fn sort(&mut self) {\n" ++
        "        I::sort(&mut self.items);\n    }\n}\n\nimpl Ray {\n" ++
        "    fn upscaled(context: &Context) -> u32 {\n        context.upscaled()\n    }\n}\n\n" ++
        "impl Small {\n    fn drain(&mut self) -> Vec<u32> {\n        if self.empty() {\n" ++
        "            return Vec::new();\n        }\n\n        self.drain(..).collect()\n" ++
        "    }\n}\n";

    const reachable = "impl Small {\n    fn drain(&mut self, count: u32, step: u32) -> u32 {\n" ++
        "        if count == 0 {\n            return 0;\n        }\n\n" ++
        "        self.drain(count - 1, step)\n    }\n}\n\nimpl<T: Walk> Walk for T {\n" ++
        "    fn walk(&self, depth: u32) -> u32 {\n        if depth == 0 {\n" ++
        "            return 0;\n        }\n\n        T::walk(self, depth - 1)\n    }\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
    try expect_count(.rust, reachable, 2);
}

test "a trait implementation whose header wraps before its for still delegates" {
    const source = "impl<T: Ord, const N: usize> From<Unique<T, N>>\n    for BTreeSet<T>\n{\n" ++
        "    fn from(value: Unique<T, N>) -> Self {\n        BTreeSet::from(value.0)\n" ++
        "    }\n}\n";

    const inherent = "impl<T: Ord, const N: usize> Unique<T, N>\nwhere\n    T: Clone,\n{\n" ++
        "    fn from(value: Unique<T, N>) -> Self {\n        Self::from(value)\n    }\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
    try expect_count(.rust, inherent, 1);
}

test "a trait method that calls itself beside other work is reported" {
    const source = "struct Tester;\n\nimpl Future for Tester {\n" ++
        "    fn poll(&mut self, cx: u32) -> u32 {\n        if cx == 0 {\n" ++
        "            return 0;\n        }\n\n        self.poll(cx - 1)\n    }\n}\n";

    try expect_count(.rust, source, 1);
}

test "a class method call through cls resolves by the class" {
    const source = "class A:\n    @classmethod\n    def make(cls):\n        return cls.make()\n";

    try expect_count(.python, source, 1);
}

test "a lifetime is not a receiver type" {
    const source = "pub struct Held<'a> {\n    values: Vec<&'a str>,\n}\n\nimpl<'a> Held<'a> " ++
        "{\n    pub fn strip(&self, name: &'a str) -> Option<&'a str> {\n        " ++
        "name.strip(self.values[0])\n    }\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
}

test "a this alias names an anonymous container" {
    const source = "pub fn HeldType(comptime T: type) type {\n    return struct {\n        " ++
        "const Held = @This();\n\n        pub fn first(self: *Held) void " ++
        "{\n            self.second();\n        }\n\n        pub fn second(self: " ++
        "*Held) void {\n            self.first();\n        }\n    };\n}\n";

    try expect_count(.zig, source, 2);
}

test "a value bound from a self member is not the container" {
    const source = "class Loader:\n    def templates(self):\n        loader = " ++
        "self.app.loader\n        return loader.templates()\n";

    try testing.expect_quiet(@This(), .python, source);
}

test "a tuple field is a chain step" {
    const source = "struct Held(Vec<u8>);\n\nimpl Held {\n    fn len(&self) -> usize " ++
        "{\n        self.0.len()\n    }\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
}

test "a range element resolves through the type switch case" {
    const source = "package main\n\ntype Value struct {\n\tvalue any\n}\n\nfunc (v Value) " ++
        "Repr() string {\n\tswitch x := v.value.(type) {\n\tcase []Value:\n\t\tfor " ++
        "i, v := range x {\n\t\t\t_ = i\n\t\t\tv.Repr()\n\t\t}\n\t}\n\treturn \"\"" ++
        "\n}\n";

    try expect_count(.go, source, 1);
}

test "a range element resolves through the parameter type" {
    const source = "const Item = struct {\n    fn run(self: *const Item, items: []const Item) " ++
        "void {\n        for (items) |item| {\n            " ++
        "item.run(items);\n        }\n    }\n};\n";

    try expect_count(.zig, source, 1);
}

test "a self call is reported" {
    const source = "fn walk(node: u32) {\n    walk(node);\n}\n";

    var findings = try testing.analyze(@This(), .rust, source);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
    try std.testing.expect(std.mem.find(u8, findings.message(0), "walk") != null);
}

test "mutual recursion is reported" {
    const source = "fn ping(value: u32) {\n    pong(value);\n}\n\n" ++
        "fn pong(value: u32) {\n    ping(value);\n}\n";

    var findings = try testing.analyze(@This(), .rust, source);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 2), findings.count());
    try std.testing.expect(std.mem.find(u8, findings.message(0), "ping") != null);
}

test "a qualified call through a field is quiet" {
    const source = "fn deinit(self: *Client) void {\n    self.pool.deinit();\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "a call to another function is quiet" {
    const source = "fn walk(node: u32) {\n    step(node);\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
}

test "a class method cycle through this is reported" {
    const source = "class Walker {\n    walk(node) {\n        return this.helper(node);\n    " ++
        "}\n\n    helper(node) {\n        return this.walk(node);\n    }\n}\n";

    try expect_count(.javascript, source, 2);
}

test "a lambda bound to a name that calls itself is reported" {
    const source = "const arrow = (d) => arrow(d - 1);\n\nconst viaConst = function (d) {\n    " ++
        "return viaConst(d - 1);\n};\n";

    try expect_count(.typescript, source, 2);
}

test "a go variable assigned a recursive literal is reported" {
    const source = "package main\n\nfunc run() int {\n\tvar inner func(int) int\n\tinner = " ++
        "func(d int) int {\n\t\treturn inner(d - 1)\n\t}\n\treturn inner(3)\n}\n";

    try expect_count(.go, source, 1);
}

test "a zig cycle through a local container is reported" {
    const source = "const S = struct {\n    fn step(d: u32) u32 {\n        return " ++
        "viaStruct(d - 1);\n    }\n};\n\nfn viaStruct(d: u32) u32 {\n    return " ++
        "S.step(d);\n}\n";

    try expect_count(.zig, source, 2);
}

test "a self call inside a template substitution anchors at the declaration" {
    const source = "function walk(node) {\n    return `${walk(node.next)}`;\n}\n";

    try testing.expect_anchors(@This(), .javascript, source, &.{.{ 1, 1 }});
}
