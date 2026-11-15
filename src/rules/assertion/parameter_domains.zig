const std = @import("std");
const scylla = @import("scylla");
const Context = @import("../context.zig");
const Limits = @import("../../limits.zig");
const remote_domains = @import("remote_domains.zig");
const scan = scylla.scan;
const assert = std.debug.assert;
const Function = scylla.View.Function;
const Parameter = scylla.View.Parameter;
const View = scylla.View;
const Marks = std.bit_set.Static(Limits.function_count_max_default);

functions: Marks,

const Domains = @This();

const Names = struct {
    values: [64][]const u8,
    count: u32,

    fn contains(names: *const Names, text: []const u8) bool {
        assert(names.count <= names.values.len);
        assert(text.len > 0);

        for (names.values[0..names.count]) |name| {
            if (std.mem.eql(u8, name, text)) return true;
        }

        return false;
    }

    fn mentions(names: *const Names, text: []const u8) bool {
        assert(names.count <= names.values.len);

        for (names.values[0..names.count]) |name| {
            if (references(text, name)) return true;
        }

        return false;
    }
};

const Level = enum {
    nested,
    top,
};

const Local = struct {
    function: *const scylla.Calls.Function,
    offset: u32,
};

pub const empty: Domains = .{ .functions = .empty };
const encode_call = "std.mem.writeInt";
const encode_value_position: u32 = 2;
const parameter_count_max = scylla.limits.parameter_count_max;
const raise_guard_depth_max = 4;
const wrappers_total = [_][]const u8{
    "@as",
    "@backingInt",
    "@bitCast",
    "@intFromEnum",
    "@truncate",
};
const type_word = "type";

pub fn build(domains: *Domains, context: *const Context) void {
    if (context.front.language != .zig) return;

    const functions = context.tables.functions();
    const count = @min(functions.len, Marks.bit_length);

    for (0..count) |_| {
        const before = domains.functions.count();

        for (functions[0..count], 0..) |record, index| {
            if (domains.functions.isSet(index)) continue;

            const function = context.view(record.node).as_function() orelse continue;
            if (!domains.checks_all(context, function)) continue;

            domains.functions.set(index);
        }

        if (domains.functions.count() == before) break;
    }

    assert(domains.functions.count() <= count);
}

fn checks_all(domains: *const Domains, context: *const Context, function: Function) bool {
    assert(function.view.span().end() <= context.source.len);

    const body = function.body() orelse return false;
    var parameters = function.parameters();

    for (0..parameter_count_max + 1) |_| {
        const parameter = parameters.next() orelse return true;
        const position = parameter.name orelse continue;
        const name = context.front_text(position);
        const typed = if (parameter.type_span) |span| context.span_text(span) else "";

        if (std.mem.eql(u8, name, "_")) continue;
        if (std.mem.startsWith(u8, typed, "*")) continue;
        if (std.mem.eql(u8, typed, "type")) continue;
        if (scan.word_listed(context.conventions.parameter_valueless_types, typed)) continue;
        if (checked_before_use(context, body, name)) return false;
        if (domains.accepts_at(context, function, parameter, .nested)) continue;
        return false;
    }

    unreachable;
}

pub fn accepts(
    domains: *const Domains,
    context: *const Context,
    function: Function,
    parameter: Parameter,
) bool {
    assert(function.view.span().end() <= context.source.len);
    assert(parameter.span.end() <= context.source.len);

    return domains.accepts_at(context, function, parameter, .top);
}

fn accepts_at(
    domains: *const Domains,
    context: *const Context,
    function: Function,
    parameter: Parameter,
    level: Level,
) bool {
    assert(function.view.span().end() <= context.source.len);
    assert(parameter.span.end() <= context.source.len);

    if (context.front.language != .zig) return false;

    const position = parameter.name orelse return false;
    const name = context.front_text(position);
    const body = function.body() orelse return false;
    const typed = if (parameter.type_span) |span| scan.trim_ascii(context.span_text(span)) else "";
    if (std.mem.findAny(u8, typed, "?!") != null) return false;
    if (has_late_contract(context, function, name)) return false;
    if (compiler_checks_format(context, body, parameter, name)) return true;

    var names: Names = .{ .values = undefined, .count = 1 };

    names.values[0] = name;

    if (returns_record(context, body, name)) return false;

    const scalar = scalar_type(context, typed) or names_a_type_parameter(context, function, typed);

    if (!scalar) {
        if (std.mem.startsWith(u8, typed, "[")) return false;

        if (scan.word_in(&.{ "f16", "f32", "f64", "f80", "f128", "comptime_float" }, typed)) {
            return false;
        }

        if (copied_only(context, body, name)) return true;

        return domains.forwarded_only(context, function, body, &names, level);
    }

    if (!aliases_collect(context, function, &names)) return false;

    if (names.count == 1) {
        if (integer_type(typed)) {
            if (!std.mem.eql(u8, typed, "u8")) {
                if (copied_only(context, body, name)) return false;
            }
        }
    }

    if (partial_use(context, body, &names)) return false;

    return domains.accepts_calls(context, function, body, .{
        .level = level,
        .names = &names,
        .typed = typed,
    });
}

fn accepts_calls(
    domains: *const Domains,
    context: *const Context,
    function: Function,
    body: View,
    options: struct { level: Level, names: *const Names, typed: []const u8 },
) bool {
    assert(function.view.span().end() <= context.source.len);
    assert(options.names.count > 0);

    const names = options.names;
    const typed = options.typed;

    assert(body.span().end() <= context.source.len);

    var calls = body_views(context, .call, body);

    for (0..calls.remaining) |_| {
        const node = calls.next() orelse break;
        if (!body.span().contains(node.span().offset)) continue;
        if (!names.mentions(node.text(context.source))) continue;

        const call = node.as_call() orelse return false;

        const written = if (call.callee()) |callee|
            callee.text(context.source)
        else if (call.name_token()) |token|
            context.front_text(token)
        else
            return false;

        if (safe_builtin(context, call, written, names)) continue;
        if (std.mem.eql(u8, written, "std.Random.DefaultPrng.init")) continue;
        if (context.is_assertion(node)) continue;
        if (std.mem.eql(u8, written, "assert")) continue;
        if (std.mem.startsWith(u8, written, "std.testing.expect")) continue;

        if (fuzz_integer_input(.{ .path = context.path, .typed = typed })) {
            if (call.callee() != null) continue;
        }

        if (encodes_a_value(context, call, written, names)) continue;
        if (domains.callee_checked(context, call, written)) continue;

        const position = argument_position(context, call, names) orelse return false;

        const accepted = domains.callee_accepts(context, function, call, .{
            .level = options.level,
            .position = position,
            .written = written,
        });

        if (!accepted) return false;
    }

    return true;
}

fn body_views(context: *const Context, category: View.Category, body: View) Context.Views {
    assert(body.span().end() <= context.source.len);

    const positions = context.front.nodes_of(category);
    const first = position_from(context, positions, body.span().offset);
    const after = position_from(context, positions, body.span().end());

    assert(first <= after);
    assert(after <= positions.len);

    return .{
        .front = context.front,
        .positions = positions[first..after],
        .remaining = @intCast(after - first),
    };
}

fn position_from(context: *const Context, positions: []const u32, offset: u32) u32 {
    assert(offset <= context.source.len);
    assert(positions.len <= context.front.node_count());

    var first: u32 = 0;
    var after: u32 = @intCast(positions.len);

    for (0..33) |_| {
        if (first == after) break;

        const middle = first + @divTrunc(after - first, 2);

        if (context.view(positions[middle]).span().offset < offset) {
            first = middle + 1;
        } else {
            after = middle;
        }
    }

    assert(first == after);

    return first;
}

fn fuzz_integer_input(options: struct { path: []const u8, typed: []const u8 }) bool {
    if (!std.mem.endsWith(u8, options.path, "_fuzz.zig")) return false;
    return integer_type(options.typed);
}

fn returns_record(context: *const Context, body: View, name: []const u8) bool {
    assert(body.span().end() <= context.source.len);
    assert(name.len > 0);

    var returns = body_views(context, .@"return", body);

    for (0..returns.remaining) |_| {
        const node = returns.next() orelse break;
        if (!body.span().contains(node.span().offset)) continue;

        const text = node.text(context.source);
        if (!std.mem.startsWith(u8, text, "return .{")) continue;
        if (references(text, name)) return true;
    }

    return false;
}

fn compiler_checks_format(
    context: *const Context,
    body: View,
    parameter: Parameter,
    name: []const u8,
) bool {
    assert(body.span().end() <= context.source.len);
    assert(parameter.span.end() <= context.source.len);
    assert(name.len > 0);

    const position = parameter.name orelse return false;
    const first = context.lexer_index_from(context.front_token(position).offset);
    if (first == 0) return false;
    if (!std.mem.eql(u8, context.text(context.tokens[first - 1]), "comptime")) return false;

    var uses: u32 = 0;

    for (context.tokens_in(body.span())) |token| {
        if (token.kind != .identifier) continue;

        if (std.mem.eql(u8, context.text(token), name)) uses += 1;
    }

    var calls = body_views(context, .call, body);
    var checked: u32 = 0;

    for (0..calls.remaining) |_| {
        const node = calls.next() orelse break;
        if (!body.span().contains(node.span().offset)) continue;

        const call = node.as_call() orelse continue;
        const callee = call.callee() orelse continue;
        const text = callee.text(context.source);
        if (!scan.word_in(&.{ "std.mem.print", "std.fmt.bufPrint" }, text)) continue;

        var arguments = call.arguments();

        _ = arguments.next() orelse continue;

        const format = arguments.next() orelse continue;

        if (std.mem.eql(u8, format.text(context.source), name)) checked += 1;
    }

    return uses > 0 and uses == checked;
}

fn called_checked(domains: *const Domains, context: *const Context, name: []const u8) bool {
    assert(name.len > 0);

    const called = context.tables.function_of(name) orelse return false;

    return domains.marked(context, called);
}

fn callee_checked(
    domains: *const Domains,
    context: *const Context,
    call: scylla.View.Call,
    written: []const u8,
) bool {
    assert(call.view.span().end() <= context.source.len);
    assert(written.len > 0);

    if (domains.called_checked(context, written)) return true;

    const local = local_callee(context, call, written) orelse return false;
    if (local.offset == 0) return false;

    return domains.marked(context, local.function);
}

fn callee_accepts(
    domains: *const Domains,
    context: *const Context,
    function: Function,
    call: scylla.View.Call,
    options: struct { level: Level, position: u32, written: []const u8 },
) bool {
    assert(call.view.span().end() <= context.source.len);
    assert(options.written.len > 0);
    assert(function.view.span().end() <= context.source.len);

    if (domains.callee_checked(context, call, options.written)) return true;

    if (local_callee(context, call, options.written)) |local| {
        if (options.level == .nested) return false;

        return domains.parameter_accepted(context, local, options.position);
    }

    return remote_domains.accepts(context, function, options.written, options.position);
}

fn local_callee(context: *const Context, call: scylla.View.Call, written: []const u8) ?Local {
    assert(call.view.span().end() <= context.source.len);
    assert(written.len > 0);

    if (context.tables.function_of(written)) |found| return .{ .function = found, .offset = 0 };

    const receiver = call.receiver() orelse return null;
    const dot = std.mem.findScalarLast(u8, written, '.') orelse return null;
    const method = written[dot + 1 ..];
    if (method.len == 0) return null;

    const held = context.tables.receiver_type_of(call.view, receiver) orelse return null;
    const found = context.tables.method_of(held, method) orelse return null;

    return .{ .function = found, .offset = 1 };
}

fn parameter_accepted(
    domains: *const Domains,
    context: *const Context,
    local: Local,
    position: u32,
) bool {
    assert(local.function.node < context.front.node_count());
    assert(local.offset <= 1);
    assert(position < parameter_count_max);

    const callee = context.view(local.function.node).as_function() orelse return false;
    const index = position + local.offset;
    const parameter = remote_domains.parameter_at(callee, index) orelse return false;
    const named = parameter.name orelse return false;
    const name = context.front_text(named);
    const typed = if (parameter.type_span) |span| scan.trim_ascii(context.span_text(span)) else "";
    const body = callee.body() orelse return false;

    if (std.mem.startsWith(u8, typed, "*")) return true;
    if (std.mem.eql(u8, typed, type_word)) return true;
    if (scan.word_listed(context.conventions.parameter_valueless_types, typed)) return true;
    if (checked_before_use(context, body, name)) return false;

    return domains.accepts_at(context, callee, parameter, .nested);
}

fn argument_position(context: *const Context, call: scylla.View.Call, names: *const Names) ?u32 {
    assert(call.view.span().end() <= context.source.len);
    assert(names.count > 0);

    var arguments = call.arguments();
    const count = arguments.remaining;
    var found: ?u32 = null;

    for (0..count) |index| {
        const argument = arguments.next() orelse break;
        const text = scan.trim_ascii(argument.text(context.source));
        if (!names.mentions(text)) continue;
        if (found != null) return null;
        if (!passes_whole(text, names)) return null;

        found = @intCast(index);
    }

    if (found) |position| assert(position < count);

    return found;
}

fn passes_whole(text: []const u8, names: *const Names) bool {
    assert(text.len > 0);
    assert(names.count > 0);

    if (names.contains(text)) return true;

    for (wrappers_total) |wrapper| {
        if (!std.mem.startsWith(u8, text, wrapper)) continue;
        if (!std.mem.endsWith(u8, text, ")")) return false;

        const open = std.mem.findScalar(u8, text, '(') orelse return false;
        const inner = scan.trim_ascii(text[open + 1 .. text.len - 1]);
        const comma = std.mem.findScalarLast(u8, inner, ',');
        const value = if (comma) |at| scan.trim_ascii(inner[at + 1 ..]) else inner;

        return names.contains(value);
    }

    return false;
}

fn forwarded_only(
    domains: *const Domains,
    context: *const Context,
    function: Function,
    body: View,
    names: *const Names,
    level: Level,
) bool {
    assert(body.span().end() <= context.source.len);
    assert(names.count == 1);
    assert(function.view.span().end() <= context.source.len);

    const tokens = context.front.tokens();
    const first = remote_domains.token_index_at(tokens, body.span().offset);
    var used: u32 = 0;

    for (tokens[first..], first..) |token, index| {
        if (token.offset >= body.span().end()) break;
        if (token.kind != .identifier) continue;
        if (!std.mem.eql(u8, context.front_text(@intCast(index)), names.values[0])) continue;
        if (index == first) return false;
        if (tokens[index - 1].is_punctuation(.dot)) continue;

        used += 1;

        switch (remote_domains.use_local(context, body, @intCast(index), true)) {
            .total => continue,
            .aliased, .refused => return false,
            .forwarded => |forward| {
                const accepted = domains.callee_accepts(context, function, forward.call, .{
                    .level = level,
                    .position = forward.position,
                    .written = forward.callee,
                });

                if (!accepted) return false;
            },
        }
    }

    assert(used <= tokens.len);

    return used > 0;
}

fn callee_written(context: *const Context, call: scylla.View.Call) ?[]const u8 {
    assert(call.view.span().end() <= context.source.len);

    if (call.callee()) |callee| return callee.text(context.source);

    const token = call.name_token() orelse return null;

    return context.front_text(token);
}

fn marked(
    domains: *const Domains,
    context: *const Context,
    called: *const scylla.Calls.Function,
) bool {
    assert(called.node < context.front.node_count());
    assert(domains.functions.count() <= Marks.bit_length);

    for (context.tables.functions(), 0..) |function, index| {
        if (index >= Marks.bit_length) return false;
        if (function.node != called.node) continue;
        return domains.functions.isSet(index);
    }

    return false;
}

fn encodes_a_value(
    context: *const Context,
    call: scylla.View.Call,
    written: []const u8,
    names: *const Names,
) bool {
    assert(call.view.span().end() <= context.source.len);
    assert(written.len > 0);

    if (!std.mem.eql(u8, written, encode_call)) return false;

    var arguments = call.arguments();
    const count = arguments.remaining;
    var position: u32 = 0;
    var encoded = false;

    for (0..count) |_| {
        const argument = arguments.next() orelse break;
        const mentioned = names.mentions(argument.text(context.source));

        if (position == encode_value_position) {
            encoded = mentioned;
        } else {
            if (mentioned) return false;
        }

        position += 1;
    }

    assert(position <= count);

    return encoded;
}

fn names_a_type_parameter(context: *const Context, function: Function, typed: []const u8) bool {
    assert(function.view.span().end() <= context.source.len);
    assert(typed.len <= context.source.len);

    if (typed.len == 0) return false;

    var parameters = function.parameters();

    for (0..parameter_count_max + 1) |_| {
        const parameter = parameters.next() orelse return false;
        const position = parameter.name orelse continue;
        if (!std.mem.eql(u8, context.front_text(position), typed)) continue;

        const span = parameter.type_span orelse return false;

        return std.mem.eql(u8, scan.trim_ascii(context.span_text(span)), type_word);
    }

    return false;
}

fn scalar_type(context: *const Context, typed: []const u8) bool {
    if (integer_type(typed)) return true;
    if (std.mem.eql(u8, typed, "bool")) return true;
    if (std.mem.startsWith(u8, typed, "@Vector(")) return true;

    var declarations = context.views(.declaration);

    for (0..declarations.remaining) |_| {
        const node = declarations.next() orelse break;
        const declaration = node.as_declaration() orelse continue;
        const position = declaration.name_token() orelse continue;
        if (!std.mem.eql(u8, context.front_text(position), typed)) continue;

        const value = declaration.value() orelse return false;
        const spelled = value.text(context.source);
        if (std.mem.startsWith(u8, spelled, "@Vector(")) return true;

        const container = value.as_container() orelse return false;
        if (std.mem.startsWith(u8, spelled, "enum")) return closed_enum(context, container);
        if (!std.mem.startsWith(u8, spelled, "struct")) return false;

        var fields = container.fields();

        for (0..fields.remaining + 1) |_| {
            const field = fields.next() orelse return true;
            const held = field.as_field() orelse return false;
            const type_of = held.type_of() orelse return false;
            const text = type_of.text(context.source);
            if (integer_type(text)) continue;
            if (std.mem.eql(u8, text, "bool")) continue;
            if (enum_named(context, text)) continue;
            return false;
        }
    }

    return false;
}

fn integer_type(text: []const u8) bool {
    if (std.mem.eql(u8, text, "usize")) return true;
    if (std.mem.eql(u8, text, "isize")) return true;
    if (text.len < 2) return false;

    if (text[0] != 'u') {
        if (text[0] != 'i') return false;
    }

    for (text[1..]) |byte| {
        if (!std.ascii.isDigit(byte)) return false;
    }

    return true;
}

fn enum_named(context: *const Context, name: []const u8) bool {
    assert(name.len > 0);

    var containers = context.views(.@"struct");

    for (0..containers.remaining) |_| {
        const node = containers.next() orelse break;
        const held = node.as_container() orelse continue;
        const position = held.name_token() orelse continue;
        if (!std.mem.eql(u8, context.front_text(position), name)) continue;
        if (!std.mem.startsWith(u8, node.text(context.source), "enum")) return false;
        return closed_enum(context, held);
    }

    return false;
}

fn closed_enum(context: *const Context, container: scylla.View.Container) bool {
    assert(container.view.span().end() <= context.source.len);

    var fields = container.fields();

    for (0..fields.remaining + 1) |_| {
        const field = fields.next() orelse return true;
        if (std.mem.eql(u8, scan.trim_ascii(field.text(context.source)), "_")) return false;
    }

    return false;
}

fn aliases_collect(context: *const Context, function: Function, names: *Names) bool {
    assert(function.view.span().end() <= context.source.len);

    const body = function.body() orelse return false;

    for (0..names.values.len) |_| {
        const before = names.count;
        var declarations = body_views(context, .declaration, body);

        for (0..declarations.remaining) |_| {
            const node = declarations.next() orelse break;
            const owner = context.function_at(node.span().offset) orelse continue;
            if (owner.index() != function.view.index()) continue;

            const declaration = node.as_declaration() orelse continue;
            const position = declaration.name_token() orelse continue;
            const value = declaration.value() orelse continue;
            if (value.as_call() != null) continue;
            if (value.as_container() != null) continue;
            if (!flows_into(context, value, names)) continue;
            if (expression_checked(context, function, value, names)) continue;

            const name = context.front_text(position);
            if (names.contains(name)) continue;
            if (names.count == names.values.len) return false;

            names.values[names.count] = name;
            names.count += 1;
        }

        if (names.count == before) return true;
    }

    return false;
}

fn flows_into(context: *const Context, value: View, names: *const Names) bool {
    assert(value.span().end() <= context.source.len);
    assert(names.count > 0);

    var returns = body_views(context, .@"return", value);
    var cursor = value.span().offset;

    for (0..returns.remaining) |_| {
        const node = returns.next() orelse break;
        const span = node.span();
        if (span.offset < cursor) continue;

        assert(span.end() <= value.span().end());

        if (names.mentions(context.source[cursor..span.offset])) return true;

        cursor = span.end();
    }

    return names.mentions(context.source[cursor..value.span().end()]);
}

fn expression_checked(
    context: *const Context,
    function: Function,
    value: View,
    names: *const Names,
) bool {
    assert(function.view.span().end() <= context.source.len);
    assert(value.span().end() <= context.source.len);

    const body = function.body() orelse return false;
    const text = value.text(context.source);
    var mentioned = false;

    for (names.values[0..names.count]) |name| {
        if (!scan.find_word(text, name)) continue;
        if (!asserted_before(context, body, value.span().offset, name)) return false;

        mentioned = true;
    }

    return mentioned;
}

fn partial_use(context: *const Context, body: View, names: *const Names) bool {
    assert(body.span().end() <= context.source.len);

    const tokens = context.tokens_in(body.span());

    for (tokens, 0..) |token, index| {
        if (token.kind != .identifier) continue;

        const name = context.text(token);
        if (!names.contains(name)) continue;

        if (!std.mem.eql(u8, name, names.values[0])) {
            if (asserted_before(context, body, token.offset, name)) continue;
        }

        if (index > 0) {
            if (tokens[index - 1].is_punctuation(.dot)) continue;

            const previous = context.text(tokens[index - 1]);
            if (scan.word_in(&.{ "+", "-", "*", "/", "%", "<<", ">>" }, previous)) return true;
        }

        if (index + 1 < tokens.len) {
            const next = context.text(tokens[index + 1]);
            if (std.mem.eql(u8, next, "[")) return true;
            if (std.mem.startsWith(u8, next, ".?")) return true;
            if (scan.word_in(&.{ "+", "-", "*", "+=", "-=", "*=" }, next)) return true;
        }

        var enclosing = context.pairs.enclosing_at(token.offset);

        for (0..64) |_| {
            const group = enclosing orelse break;
            const open = context.tokens[group.open];
            if (open.offset < body.span().offset) break;
            if (open.is_punctuation(.bracket_open)) return true;

            enclosing = context.pairs.enclosing_at(open.offset);
        }
    }

    var loops = body_views(context, .loop, body);

    for (0..loops.remaining) |_| {
        const loop = loops.next() orelse break;
        if (!body.span().contains(loop.span().offset)) continue;

        const text = loop.text(context.source);
        const end = std.mem.findScalar(u8, text, '{') orelse continue;
        if (names.mentions(text[0..end])) return true;
    }

    return false;
}

fn safe_builtin(
    context: *const Context,
    call: scylla.View.Call,
    name: []const u8,
    names: *const Names,
) bool {
    assert(call.view.span().end() <= context.source.len);
    assert(name.len > 0);

    const total = [_][]const u8{
        "@abs",   "@as",       "@intCast", "@intFromBool", "@reduce",   "@select",
        "@splat", "@truncate", "@ctz",     "@clz",         "@popCount",
    };

    if (std.mem.eql(u8, name, "@intCast")) return cast_has_contract(context, call, names);
    if (scan.word_in(&total, name)) return true;
    if (!scan.word_in(&.{ "@divTrunc", "@divFloor", "@rem" }, name)) return false;

    var arguments = call.arguments();

    _ = arguments.next() orelse return false;

    const divisor = arguments.next() orelse return false;
    const text = divisor.text(context.source);
    if (names.mentions(text)) return false;

    const value = positive_constant(context, divisor) orelse return false;

    return value > 0;
}

fn direct_assertion(context: *const Context, statement: View) bool {
    if (statement.category() != .call) return false;
    return context.is_assertion(statement);
}

fn asserted_before(context: *const Context, body: View, offset: u32, name: []const u8) bool {
    assert(body.span().end() <= context.source.len);
    assert(name.len > 0);

    var statements = body.children();

    for (0..statements.remaining) |_| {
        const statement = statements.next() orelse break;
        if (statement.span().offset >= offset) break;
        if (!direct_assertion(context, statement)) continue;

        if (scan.find_word(statement.text(context.source), name)) return true;
    }

    return false;
}

fn cast_has_contract(context: *const Context, call: scylla.View.Call, names: *const Names) bool {
    assert(call.view.span().end() <= context.source.len);

    var arguments = call.arguments();
    const argument = arguments.next() orelse return false;
    const text = argument.text(context.source);
    if (scan.find_word(text, "@rem")) return true;

    const owner = context.function_at(argument.span().offset) orelse return false;
    const function = owner.as_function() orelse return false;
    const body = function.body() orelse return false;
    var statements = body.children();

    for (0..statements.remaining) |_| {
        const statement = statements.next() orelse break;
        if (statement.span().offset >= call.view.span().offset) break;
        if (!direct_assertion(context, statement)) continue;

        const contract = statement.text(context.source);

        for (names.values[0..names.count]) |name| {
            if (!scan.find_word(text, name)) continue;
            if (scan.find_word(contract, name)) return true;
        }
    }

    return false;
}

fn positive_constant(context: *const Context, initial: View) ?u64 {
    var node = initial;

    for (0..16) |_| {
        const text = scan.trim_ascii(node.text(context.source));

        const parsed = std.fmt.parseInt(u64, text, 0) catch |err| switch (err) {
            error.InvalidCharacter, error.Overflow => null,
        };

        if (parsed) |value| return value;
        if (node.category() != .name) return null;

        const source = context.declaration_of(node.span().offset) orelse return null;
        const declaration = source.as_declaration() orelse return null;
        if (declaration.is_mutable()) return null;

        node = declaration.value() orelse return null;
    }

    return null;
}

fn copied_only(context: *const Context, body: View, name: []const u8) bool {
    assert(body.span().end() <= context.source.len);
    assert(name.len > 0);

    const tokens = context.tokens_in(body.span());
    var found = false;

    for (tokens, 0..) |token, index| {
        if (token.kind != .identifier) continue;
        if (!std.mem.eql(u8, context.text(token), name)) continue;
        if (index == 0) return false;
        if (index + 1 == tokens.len) return false;
        if (tokens[index - 1].is_punctuation(.dot)) continue;

        const previous = tokens[index - 1];
        const next = tokens[index + 1];

        if (!previous.is_punctuation(.assign)) return false;

        if (!next.is_punctuation(.semicolon)) {
            if (!next.is_punctuation(.comma)) {
                if (!std.mem.eql(u8, context.text(next), "}")) return false;
            }
        }

        found = true;
    }

    return found;
}

fn has_late_contract(context: *const Context, function: Function, name: []const u8) bool {
    assert(function.view.span().end() <= context.source.len);
    assert(name.len > 0);

    const body = function.body() orelse return false;
    var children = body.children();
    var written: Names = .{ .values = undefined, .count = 0 };
    var used = false;

    for (0..children.remaining) |_| {
        const statement = children.next() orelse break;

        written_push(context, &written, statement);

        if (!references(statement.text(context.source), name)) continue;

        if (direct_assertion(context, statement)) {
            if (written.mentions(statement.text(context.source))) continue;

            if (used) {
                if (mutated_before(context, function, statement)) continue;
            }

            return used;
        }

        if (guards_name(context, statement, name)) return used;

        used = true;
    }

    return false;
}

fn written_push(context: *const Context, written: *Names, statement: View) void {
    assert(written.count <= written.values.len);
    assert(statement.span().end() <= context.source.len);

    if (statement.category() != .assignment) return;
    if (written.count == written.values.len) return;

    var children = statement.children();
    const target = children.next() orelse return;
    const text = scan.trim_ascii(target.text(context.source));
    if (text.len == 0) return;

    written.values[written.count] = text;
    written.count += 1;
}

fn mutated_before(context: *const Context, function: Function, contract: View) bool {
    assert(function.view.span().end() <= context.source.len);
    assert(contract.span().end() <= context.source.len);

    const body = function.body() orelse return false;
    const text = contract.text(context.source);
    var calls = body_views(context, .call, body);

    for (0..calls.remaining) |_| {
        const node = calls.next() orelse break;
        if (node.span().offset >= contract.span().offset) break;

        const owner = context.function_at(node.span().offset) orelse continue;
        if (owner.index() != function.view.index()) continue;

        const call = node.as_call() orelse continue;
        const callee = callee_written(context, call) orelse continue;
        const dot = std.mem.findScalarLast(u8, callee, '.') orelse continue;
        if (dot == 0) continue;
        if (!references(text, callee[0..dot])) continue;
        if (remote_domains.mutates(context, function, callee)) return true;
    }

    return false;
}

fn checked_before_use(context: *const Context, body: View, name: []const u8) bool {
    assert(body.span().end() <= context.source.len);
    assert(name.len > 0);

    var children = body.children();

    for (0..children.remaining) |_| {
        const statement = children.next() orelse return false;

        if (!scan.find_word(statement.text(context.source), name)) continue;

        return direct_assertion(context, statement) or guards_name(context, statement, name);
    }

    return false;
}

pub fn is_guard(context: *const Context, statement: View) bool {
    assert(statement.span().end() <= context.source.len);

    if (context.front.language == .python) return is_raise_guard(context, statement);
    if (context.front.language != .zig) return false;
    if (statement.category() != .branch) return false;

    const tokens = context.tokens_in(statement.span());
    if (tokens.len < 4) return false;
    if (!tokens[1].is_punctuation(.paren_open)) return false;

    const first = context.lexer_index_from(tokens[1].offset);
    const close = context.pairs.partner_of(first) orelse return false;

    for (context.tokens[first + 1 .. close]) |token| {
        if (scan.word_in(&.{ "+", "*" }, context.text(token))) return false;
    }

    if (fails_compilation(context, statement, close)) return true;

    const offset = context.tokens[close].end();
    var text = scan.trim_ascii(context.source[offset..statement.span().end()]);

    if (std.mem.startsWith(u8, text, "{")) {
        if (!std.mem.endsWith(u8, text, "}")) return false;

        text = scan.trim_ascii(text[1 .. text.len - 1]);
    }

    const value = if (std.mem.endsWith(u8, text, ";"))
        scan.trim_ascii(text[0 .. text.len - 1])
    else
        text;

    if (std.mem.startsWith(u8, value, "return error.")) {
        return std.mem.findAny(u8, value[13..], " ();{}\n") == null;
    }

    if (returns_a_named_error(context, statement, value)) return true;

    return scan.word_in(&.{ "return null", "return false", "return true", "unreachable" }, value);
}

pub fn guard_condition(context: *const Context, statement: View) ?[]const u8 {
    if (!is_guard(context, statement)) return null;
    if (context.front.language == .python) return raise_guard_condition(context, statement);

    const tokens = context.tokens_in(statement.span());
    const first = context.lexer_index_from(tokens[1].offset);
    const close = context.pairs.partner_of(first) orelse return null;

    assert(close > first);
    assert(context.tokens[close].offset <= context.source.len);

    return context.source[context.tokens[first].end()..context.tokens[close].offset];
}

fn is_raise_guard(context: *const Context, statement: View) bool {
    assert(context.front.language == .python);
    assert(statement.span().end() <= context.source.len);

    return raise_guard_innermost(context, statement) != null;
}

fn raise_guard_innermost(context: *const Context, statement: View) ?View {
    assert(context.front.language == .python);
    assert(statement.span().end() <= context.source.len);

    var current = statement;

    for (0..raise_guard_depth_max) |_| {
        if (current.category() != .branch) return null;

        const tokens = context.tokens_in(current.span());
        if (tokens.len == 0) return null;
        if (!tokens[0].is_keyword(.branch)) return null;

        var blocks = current.children_of(.block);
        if (blocks.count() != 1) return null;

        const body = blocks.next() orelse return null;
        var statements = body.children();
        const count = statements.count();
        if (count == 0) return null;
        if (count > 2) return null;

        const first = statements.next() orelse return null;

        assert(body.category() == .block);
        assert(first.index() > body.index());

        if (count == 2) {
            const second = statements.next() orelse return null;
            if (!raises(context, second)) return null;
            if (!feeds_the_raise(context, .{ .binding = first, .raising = second })) return null;

            return current;
        }

        if (raises(context, first)) return current;

        current = first;
    }

    return null;
}

fn raises(context: *const Context, statement: View) bool {
    assert(statement.span().end() <= context.source.len);

    const tokens = context.tokens_in(statement.span());
    if (tokens.len == 0) return false;
    if (tokens[0].kind != .keyword) return false;
    return std.mem.eql(u8, context.text(tokens[0]), "raise");
}

fn feeds_the_raise(context: *const Context, options: struct { binding: View, raising: View }) bool {
    if (options.binding.category() != .declaration) return false;

    const declaration = options.binding.as_declaration() orelse return false;
    const name = declaration.name_token() orelse return false;
    const text = context.front_text(name);

    assert(text.len > 0);
    assert(options.raising.index() > options.binding.index());

    return scan.find_word(options.raising.text(context.source), text);
}

fn raise_guard_condition(context: *const Context, statement: View) ?[]const u8 {
    assert(statement.span().end() <= context.source.len);

    const tokens = context.tokens_in(statement.span());
    const innermost = raise_guard_innermost(context, statement) orelse return null;
    const body = innermost.child_first_of(.block) orelse return null;

    assert(tokens.len > 0);
    assert(tokens[0].is_keyword(.branch));

    const start = tokens[0].end();
    const finish = body.span().offset;
    if (start > finish) return null;

    const spelled = scan.trim_ascii(context.source[start..finish]);
    const condition = std.mem.trimEnd(u8, spelled, ":");

    return scan.trim_ascii(condition);
}

fn guards_name(context: *const Context, statement: View, name: []const u8) bool {
    assert(statement.span().end() <= context.source.len);
    assert(name.len > 0);

    const condition = guard_condition(context, statement) orelse return false;

    return scan.find_word(condition, name);
}

fn fails_compilation(context: *const Context, statement: View, close: u32) bool {
    assert(statement.span().end() <= context.source.len);
    assert(close < context.tokens.len);

    var index = close + 1;

    if (index < context.tokens.len) {
        if (std.mem.eql(u8, context.text(context.tokens[index]), "{")) index += 1;
    }

    if (index + 1 >= context.tokens.len) return false;
    if (!std.mem.eql(u8, context.text(context.tokens[index]), "@compileError")) return false;
    if (!context.tokens[index + 1].is_punctuation(.paren_open)) return false;

    const partner = context.pairs.partner_of(index + 1) orelse return false;

    assert(partner > index + 1);

    const end = statement.span().end();

    for (context.tokens[partner + 1 ..]) |token| {
        if (token.offset >= end) break;
        if (token.is_punctuation(.semicolon)) continue;
        if (std.mem.eql(u8, context.text(token), "}")) continue;

        return false;
    }

    return true;
}

fn returns_a_named_error(context: *const Context, statement: View, value: []const u8) bool {
    const prefix = "return ";

    if (!std.mem.startsWith(u8, value, prefix)) return false;

    const member = value[prefix.len..];
    const dot = std.mem.findScalar(u8, member, '.') orelse return false;
    const set = member[0..dot];
    const name = member[dot + 1 ..];

    assert(dot < member.len);

    if (set.len == 0) return false;
    if (name.len == 0) return false;
    if (!is_identifier(set)) return false;
    if (!is_identifier(name)) return false;
    if (names_the_returned_error_set(context, statement, set)) return true;
    return declares_an_error_set(context, set);
}

fn names_the_returned_error_set(context: *const Context, statement: View, set: []const u8) bool {
    assert(statement.span().end() <= context.source.len);
    assert(set.len > 0);

    const block = statement.parent() orelse return false;
    const owner = block.parent() orelse return false;
    const function = owner.as_function() orelse return false;
    const parameters = function.parameters_span() orelse return false;
    const body = function.body() orelse return false;

    if (body.index() != block.index()) return false;

    const start = parameters.end();
    const finish = body.span().offset;
    if (start > finish) return false;

    const signature = context.source[start..finish];
    const bang = std.mem.findScalar(u8, signature, '!') orelse return false;

    assert(bang < signature.len);

    return scan.find_word(signature[0..bang], set);
}

fn declares_an_error_set(context: *const Context, set: []const u8) bool {
    var declarations = context.views(.declaration);

    assert(set.len > 0);

    for (0..declarations.remaining) |_| {
        const held = declarations.next() orelse break;
        const parent = held.parent() orelse continue;
        if (parent.category() != .file) continue;

        const public = strip_word(.{ .text = held.text(context.source), .word = "pub" });
        const declared = strip_word(.{ .text = public, .word = "const" });
        if (!std.mem.startsWith(u8, declared, set)) continue;

        const rest = std.mem.trimStart(u8, declared[set.len..], scan.ascii_whitespace);
        if (!std.mem.startsWith(u8, rest, "=")) continue;

        const value = std.mem.trimStart(u8, rest[1..], scan.ascii_whitespace);
        if (!std.mem.startsWith(u8, value, "error")) continue;

        const opening = std.mem.trimStart(u8, value["error".len..], scan.ascii_whitespace);
        if (std.mem.startsWith(u8, opening, "{")) return true;
    }

    return false;
}

fn strip_word(options: struct { text: []const u8, word: []const u8 }) []const u8 {
    assert(options.word.len > 0);

    const trimmed = scan.trim_ascii(options.text);

    if (!std.mem.startsWith(u8, trimmed, options.word)) return trimmed;
    if (trimmed.len == options.word.len) return trimmed;
    if (scan.is_identifier_part(trimmed[options.word.len])) return trimmed;
    return scan.trim_ascii(trimmed[options.word.len..]);
}

fn references(text: []const u8, name: []const u8) bool {
    assert(text.len <= std.math.maxInt(u32));
    assert(name.len > 0);

    var offset: usize = 0;

    for (0..text.len + 1) |_| {
        const at = offset + (std.mem.find(u8, text[offset..], name) orelse return false);
        const end = at + name.len;
        const before: u8 = if (at == 0) ' ' else text[at - 1];
        const after: u8 = if (end == text.len) ' ' else text[end];
        const member = before == '.' and (at < 2 or text[at - 2] != '.');
        const opened = !member and before < 0x80 and !scan.is_identifier_part(before);
        const closed = after < 0x80 and !scan.is_identifier_part(after);

        if (opened) {
            if (closed) return true;
        }

        offset = at + 1;
    }

    return false;
}

test "a name after a member dot is a field, and a name after a range is a reference" {
    try std.testing.expect(references("store(context)", "context"));
    try std.testing.expect(!references("store(done.context)", "context"));
    try std.testing.expect(references(".{ .context = context }", "context"));
    try std.testing.expect(references("buffer[0..count]", "count"));
    try std.testing.expect(!references("context_size + 1", "context"));
    try std.testing.expect(references("assert(!done.context.running())", "done.context"));
    try std.testing.expect(!references("owner.done.context", "done.context"));
}

fn is_identifier(text: []const u8) bool {
    for (text) |byte| {
        if (!scan.is_identifier_part(byte)) return false;
    }

    return true;
}
