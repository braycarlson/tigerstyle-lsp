const std = @import("std");
const scylla = @import("scylla");
const Context = @import("../context.zig");
const Limits = @import("../../limits.zig");
const scan = @import("../../scan.zig");
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
            if (scan.find_word(text, name)) return true;
        }

        return false;
    }
};

pub const empty: Domains = .{ .functions = .empty };
const parameter_count_max = scylla.limits.parameter_count_max;

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
        if (domains.accepts(context, function, parameter)) continue;
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

    if (!scalar_type(context, typed)) {
        if (std.mem.startsWith(u8, typed, "[")) return false;

        if (scan.word_in(&.{ "f16", "f32", "f64", "f80", "f128", "comptime_float" }, typed)) {
            return false;
        }

        return copied_only(context, body, name);
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

    return domains.accepts_calls(context, body, typed, &names);
}

fn accepts_calls(
    domains: *const Domains,
    context: *const Context,
    body: View,
    typed: []const u8,
    names: *const Names,
) bool {
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

        if (fuzz_integer_input(context.path, typed)) {
            if (call.callee() != null) continue;
        }

        if (!domains.called_checked(context, written)) return false;
    }

    return true;
}

fn body_views(context: *const Context, category: View.Category, body: View) Context.Views {
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

fn position_from(context: *const Context, positions: []const u32, offset: u32) usize {
    assert(offset <= context.source.len);
    assert(positions.len <= context.front.node_count());

    var first: usize = 0;
    var after = positions.len;

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

fn fuzz_integer_input(path: []const u8, typed: []const u8) bool {
    if (!std.mem.endsWith(u8, path, "_fuzz.zig")) return false;
    return integer_type(typed);
}

fn returns_record(context: *const Context, body: View, name: []const u8) bool {
    var returns = body_views(context, .@"return", body);

    for (0..returns.remaining) |_| {
        const node = returns.next() orelse break;
        if (!body.span().contains(node.span().offset)) continue;

        const text = node.text(context.source);
        if (!std.mem.startsWith(u8, text, "return .{")) continue;
        if (scan.find_word(text, name)) return true;
    }

    return false;
}

fn compiler_checks_format(
    context: *const Context,
    body: View,
    parameter: Parameter,
    name: []const u8,
) bool {
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
    const called = context.tables.function_of(name) orelse return false;

    for (context.tables.functions(), 0..) |function, index| {
        if (index >= Marks.bit_length) return false;
        if (function.node != called.node) continue;
        return domains.functions.isSet(index);
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
    var fields = container.fields();

    for (0..fields.remaining + 1) |_| {
        const field = fields.next() orelse return true;
        if (std.mem.eql(u8, scan.trim_ascii(field.text(context.source)), "_")) return false;
    }

    return false;
}

fn aliases_collect(context: *const Context, function: Function, names: *Names) bool {
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
            if (!names.mentions(value.text(context.source))) continue;
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

fn expression_checked(
    context: *const Context,
    function: Function,
    value: View,
    names: *const Names,
) bool {
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
    const body = function.body() orelse return false;
    var children = body.children();
    var used = false;

    for (0..children.remaining) |_| {
        const statement = children.next() orelse break;
        if (!scan.find_word(statement.text(context.source), name)) continue;
        if (direct_assertion(context, statement)) return used;
        if (is_guard(context, statement)) return used;

        used = true;
    }

    return false;
}

fn checked_before_use(context: *const Context, body: View, name: []const u8) bool {
    var children = body.children();

    for (0..children.remaining) |_| {
        const statement = children.next() orelse return false;
        if (!scan.find_word(statement.text(context.source), name)) continue;
        return direct_assertion(context, statement) or is_guard(context, statement);
    }

    return false;
}

pub fn is_guard(context: *const Context, statement: View) bool {
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

    return scan.word_in(&.{ "return null", "return false", "return true", "unreachable" }, value);
}
