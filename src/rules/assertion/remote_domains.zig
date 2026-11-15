const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const scan = scylla.scan;
const testing = @import("../testing.zig");
const assert_parameters = @import("assert_parameters.zig");
const Context = @import("../context.zig");
const Imports = @import("../../linter/imports.zig");
const Front = scylla.Front;
const Function = scylla.View.Function;
const Span = scylla.Span;
const Token = scylla.Token;
const View = scylla.View;

const Held = struct {
    front: *const Front,
    local: bool,
    path: []const u8,
    source: []const u8,

    fn text_of(held: *const Held, token: Token) []const u8 {
        assert(token.end() <= held.source.len);
        assert(token.length > 0);

        return held.source[token.offset..token.end()];
    }

    fn token_text(held: *const Held, position: u32) []const u8 {
        const tokens = held.front.tokens();

        assert(position < tokens.len);

        return held.text_of(tokens[position]);
    }

    fn span_text(held: *const Held, span: Span) []const u8 {
        assert(span.end() <= held.source.len);
        assert(span.offset <= span.end());

        return held.source[span.offset..span.end()];
    }
};

fn TextType(comptime capacity: u32) type {
    comptime assert(capacity > 0);

    return struct {
        bytes: [capacity]u8,
        length: u32,

        const Text = @This();
        const empty: Text = .{ .bytes = undefined, .length = 0 };

        fn joined(head: []const u8, tail: []const u8) ?Text {
            if (head.len > 0) assert(head[head.len - 1] != '.');
            if (tail.len > 0) assert(tail[0] != '.');

            const separator: usize = @intFromBool(head.len > 0 and tail.len > 0);
            const total = head.len + separator + tail.len;
            if (total > capacity) return null;

            var text: Text = .{ .bytes = undefined, .length = @intCast(total) };

            @memcpy(text.bytes[0..head.len], head);

            if (separator > 0) text.bytes[head.len] = '.';

            @memcpy(text.bytes[head.len + separator ..][0..tail.len], tail);

            assert(text.length == total);
            assert(text.length <= capacity);

            return text;
        }

        fn slice(text: *const Text) []const u8 {
            assert(text.length <= capacity);

            return text.bytes[0..text.length];
        }

        fn first(text: *const Text) []const u8 {
            const whole = text.slice();
            const dot = std.mem.findScalar(u8, whole, '.') orelse return whole;

            assert(dot < whole.len);

            return whole[0..dot];
        }

        fn rest(text: *const Text) []const u8 {
            const whole = text.slice();
            const dot = std.mem.findScalar(u8, whole, '.') orelse return "";

            assert(dot < whole.len);

            return whole[dot + 1 ..];
        }
    };
}

const NameText = TextType(name_bytes_max);
const PathText = TextType(path_bytes_max);

const Item = struct {
    depth: u32,
    from: PathText,
    method: bool,
    path: NameText,
    position: u32,
    scope: u32,
    specifier: PathText,
};

const Cursor = struct {
    held: Held,
    lexical: bool,
    path: NameText,
    scope: View,
};

const Step = union(enum) {
    advance,
    settled: bool,
};

pub const Use = union(enum) {
    aliased: []const u8,
    forwarded: Forward,
    refused,
    total,
};

pub const Forward = struct {
    call: View.Call,
    callee: []const u8,
    position: u32,
};

const Holding = struct {
    call: View.Call,
    position: u32,
};

const Names = struct {
    count: u32,
    values: [alias_count_max][]const u8,

    fn contains(names: *const Names, text: []const u8) bool {
        assert(names.count <= alias_count_max);
        assert(text.len > 0);

        for (names.values[0..names.count]) |name| {
            if (std.mem.eql(u8, name, text)) return true;
        }

        return false;
    }

    fn add(names: *Names, text: []const u8) bool {
        assert(names.count <= alias_count_max);
        assert(text.len > 0);

        if (names.contains(text)) return true;
        if (names.count == alias_count_max) return false;

        names.values[names.count] = text;
        names.count += 1;

        return true;
    }
};

const Query = enum {
    accepts,
    mutates,
};

const Walk = struct {
    context: *const Context,
    count: u32,
    imports: *Imports,
    items: [item_count_max]Item,
    query: Query,

    fn push(walk: *Walk, item: *const Item) bool {
        assert(walk.count <= item_count_max);
        assert(item.depth <= depth_max);

        if (walk.count == item_count_max) return false;

        walk.items[walk.count] = item.*;
        walk.count += 1;

        return true;
    }

    fn pop(walk: *Walk) ?Item {
        assert(walk.count <= item_count_max);

        if (walk.count == 0) return null;

        walk.count -= 1;

        return walk.items[walk.count];
    }

    fn held_of(walk: *Walk, item: *const Item) ?Held {
        assert(item.from.length <= path_bytes_max);

        if (item.from.length == 0) return walk.local();

        const opening: Imports.Opening = .{
            .from = item.from.slice(),
            .specifier = item.specifier.slice(),
        };

        return walk.opened(&opening);
    }

    fn local(walk: *const Walk) Held {
        const context = walk.context;

        assert(context.source.len <= std.math.maxInt(u32));

        return .{
            .front = context.front,
            .local = true,
            .path = context.path,
            .source = context.source,
        };
    }

    fn opened(walk: *Walk, opening: *const Imports.Opening) ?Held {
        assert(opening.specifier.len > 0);

        const file = walk.imports.open(opening) orelse return null;

        assert(file.path.len > 0);

        return .{ .front = file.front, .local = false, .path = file.path, .source = file.source };
    }

    fn settled(walk: *Walk, item: *const Item) bool {
        assert(item.path.length > 0);
        assert(item.depth <= depth_max);

        const held = walk.held_of(item) orelse return false;
        if (item.scope >= held.front.node_count()) return false;

        var cursor: Cursor = .{
            .held = held,
            .lexical = true,
            .path = item.path,
            .scope = held.front.view(item.scope) orelse return false,
        };

        for (0..resolution_step_max) |_| {
            switch (walk.step(&cursor, item)) {
                .advance => continue,
                .settled => |accepted| return accepted,
            }
        }

        return false;
    }

    fn step(walk: *Walk, cursor: *Cursor, item: *const Item) Step {
        assert(cursor.path.length <= name_bytes_max);
        assert(item.depth <= depth_max);

        const held = &cursor.held;
        const head = cursor.path.first();
        const rest = cursor.path.rest();
        if (head.len == 0) return refused_step;

        if (cursor.lexical) {
            cursor.scope = declaring_scope(held, cursor.scope, head) orelse return refused_step;
            cursor.lexical = false;
        }

        if (member_function(held, cursor.scope, head)) |node| {
            if (rest.len > 0) return refused_step;
            return .{ .settled = walk.function_settled(held, node, item) };
        }

        if (member_extern(held, cursor.scope, head)) {
            return .{ .settled = rest.len == 0 and walk.query == .accepts };
        }

        if (member_field_type(held, cursor.scope, head)) |typed| {
            cursor.path = field_path(typed, rest) orelse return refused_step;
            cursor.lexical = true;

            return .advance;
        }

        const value = member_value(held, cursor.scope, head) orelse return refused_step;
        const spelled = scan.trim_ascii(value.text(held.source));
        if (spelled.len == 0) return refused_step;

        if (std.mem.eql(u8, spelled, this_call)) {
            if (rest.len == 0) return refused_step;

            cursor.path = NameText.joined(rest, "") orelse return refused_step;

            return .advance;
        }

        if (value.as_container() != null) {
            if (rest.len == 0) return refused_step;

            cursor.path = NameText.joined(rest, "") orelse return refused_step;
            cursor.scope = value;

            return .advance;
        }

        if (import_specifier(spelled)) |specifier| return walk.imported(cursor, spelled, specifier);

        if (is_name_path(spelled)) {
            cursor.path = NameText.joined(spelled, rest) orelse return refused_step;
            cursor.lexical = true;

            return .advance;
        }

        return .{ .settled = walk.branches_pushed(held, value, rest, item) };
    }

    fn imported(walk: *Walk, cursor: *Cursor, spelled: []const u8, specifier: []const u8) Step {
        assert(specifier.len > 0);
        assert(spelled.len > specifier.len);

        const opening: Imports.Opening = .{ .from = cursor.held.path, .specifier = specifier };
        const rest = cursor.path.rest();

        cursor.path = NameText.joined(import_suffix(spelled), rest) orelse return refused_step;
        if (cursor.path.length == 0) return refused_step;

        cursor.held = walk.opened(&opening) orelse return refused_step;
        cursor.scope = cursor.held.front.root() orelse return refused_step;
        cursor.lexical = false;

        return .advance;
    }

    fn branches_pushed(
        walk: *Walk,
        held: *const Held,
        value: View,
        rest: []const u8,
        item: *const Item,
    ) bool {
        assert(item.depth <= depth_max);
        assert(value.span().end() <= held.source.len);
        assert(rest.len < name_bytes_max);

        const tokens = tokens_within(held, value.span());
        if (tokens.len == 0) return false;

        const leading = held.text_of(tokens[0]);
        if (!std.mem.eql(u8, leading, "if")) {
            if (!std.mem.eql(u8, leading, "switch")) return false;
        }

        if (!results_import(held, tokens)) return false;

        var pushed: u32 = 0;

        for (tokens, 0..) |token, index| {
            if (!std.mem.eql(u8, held.text_of(token), import_word)) continue;

            const branch = branch_item(held, tokens[index..], rest, item) orelse return false;
            if (!walk.push(&branch)) return false;

            pushed += 1;
        }

        assert(pushed <= tokens.len);

        return pushed > 0;
    }

    fn function_settled(walk: *Walk, held: *const Held, node: View, item: *const Item) bool {
        assert(node.span().end() <= held.source.len);
        assert(item.depth <= depth_max);

        if (inside_a_function(node)) return false;

        const function = node.as_function() orelse return false;
        if (walk.query == .mutates) return receiver_mutable(held, function, item);

        const body = function.body() orelse return declares_extern(held, node);
        const index = item.position + @intFromBool(item.method);
        const parameter = parameter_at(function, index) orelse return false;
        const position = parameter.name orelse return false;
        const typed = if (parameter.type_span) |span| scan.trim_ascii(held.span_text(span)) else "";

        if (typed.len == 0) return false;
        if (typed[0] == '*') return true;
        if (std.mem.eql(u8, typed, type_word)) return true;
        if (typed[0] == '[') return false;
        if (typed[0] == '?') return false;

        var names: Names = .{ .count = 0, .values = undefined };
        const added = names.add(held.token_text(position));

        assert(added);

        const opaque_value = !scalar_named(held, node, typed);

        return walk.uses_settled(held, function, body, &names, .{
            .item = item,
            .opaque_value = opaque_value,
        });
    }

    fn uses_settled(
        walk: *Walk,
        held: *const Held,
        function: Function,
        body: View,
        names: *Names,
        options: struct { item: *const Item, opaque_value: bool },
    ) bool {
        assert(body.span().end() <= held.source.len);
        assert(names.count > 0);
        assert(function.view.span().end() <= held.source.len);
        assert(options.item.depth <= depth_max);

        const tokens = held.front.tokens();
        const first = token_index_at(tokens, body.span().offset);
        var used: u32 = 0;

        for (tokens[first..], first..) |token, index| {
            if (token.offset >= body.span().end()) break;
            if (token.kind != .identifier) continue;
            if (!names.contains(held.text_of(token))) continue;
            if (index == 0) return false;
            if (std.mem.eql(u8, held.text_of(tokens[index - 1]), ".")) continue;

            used += 1;

            const occurrence: Occurrence = .{
                .body = body,
                .index = @intCast(index),
                .opaque_value = options.opaque_value,
            };

            switch (use_of(held, &occurrence)) {
                .total => continue,
                .refused => return false,
                .aliased => |alias| if (!names.add(alias)) return false,
                .forwarded => |forward| {
                    if (!walk.forward_pushed(held, function, &forward, options.item)) return false;
                },
            }
        }

        return used > 0;
    }

    fn forward_pushed(
        walk: *Walk,
        held: *const Held,
        function: Function,
        forward: *const Forward,
        item: *const Item,
    ) bool {
        assert(function.view.span().end() <= held.source.len);
        assert(forward.callee.len > 0);
        assert(item.depth <= depth_max);

        if (item.depth == depth_max) return false;

        var next: Item = .{
            .depth = item.depth + 1,
            .from = .empty,
            .method = false,
            .path = .empty,
            .position = forward.position,
            .scope = function.view.index(),
            .specifier = .empty,
        };

        if (!receiver_translated(held, function, forward.callee, &next)) return false;

        if (!held.local) {
            next.from = PathText.joined(held.path, "") orelse return false;
            const basename = std.Io.Dir.path.basename(held.path);

            next.specifier = PathText.joined(basename, "") orelse return false;
        }

        return walk.push(&next);
    }
};

const Occurrence = struct {
    body: View,
    index: u32,
    opaque_value: bool,
};

const alias_count_max: u32 = 8;
const bitwise_words = [_][]const u8{ "&", "|", "^" };
const cast_call = "std.math.cast";
const casts_total = [_][]const u8{ "@backingInt", "@bitCast", "@intFromEnum", "@truncate" };
const comparison_words = [_][]const u8{ "==", "!=", "<", "<=", ">", ">=" };
const compile_error_word = "@compileError";
const declaration_scan_max: u32 = 16;
const depth_max: u32 = 8;
const encode_call = "std.mem.writeInt";
const extern_word = "extern";
const import_word = "@import";
const inspection_words = [_][]const u8{ ".", "[", "(", ".?" };
const item_count_max: u32 = 16;
const name_bytes_max: u32 = 128;
const parameter_count_max = scylla.limits.parameter_count_max;
const path_bytes_max: u32 = 1024;
const processed_max: u32 = 64;
const refused_step: Step = .{ .settled = false };
const resolution_step_max: u32 = 16;
const root_node: u32 = 0;
const scope_depth_max = scylla.limits.parse_depth_max;
const shift_words = [_][]const u8{ "<<", ">>" };
const this_call = "@This()";
const type_word = "type";
const wrapper_depth_max: u32 = 4;

pub fn accepts(context: *const Context, origin: Function, callee: []const u8, position: u32) bool {
    assert(callee.len > 0);
    assert(origin.view.span().end() <= context.source.len);
    assert(position < parameter_count_max);

    return walked(context, origin, callee, .{ .position = position, .query = .accepts });
}

pub fn mutates(context: *const Context, origin: Function, callee: []const u8) bool {
    assert(callee.len > 0);
    assert(origin.view.span().end() <= context.source.len);

    return walked(context, origin, callee, .{ .position = 0, .query = .mutates });
}

fn walked(
    context: *const Context,
    origin: Function,
    callee: []const u8,
    options: struct { position: u32, query: Query },
) bool {
    assert(callee.len > 0);
    assert(origin.view.span().end() <= context.source.len);
    assert(options.position < parameter_count_max);

    if (context.front.language != .zig) return false;

    const imports = context.imports orelse return false;
    const held: Held = .{
        .front = context.front,
        .local = true,
        .path = context.path,
        .source = context.source,
    };

    var first: Item = .{
        .depth = 0,
        .from = .empty,
        .method = false,
        .path = .empty,
        .position = options.position,
        .scope = origin.view.index(),
        .specifier = .empty,
    };

    if (!receiver_translated(&held, origin, callee, &first)) return false;

    var walk: Walk = .{
        .context = context,
        .count = 0,
        .imports = imports,
        .items = undefined,
        .query = options.query,
    };

    if (!walk.push(&first)) return false;

    for (0..processed_max) |_| {
        const item = walk.pop() orelse return true;
        if (!walk.settled(&item)) return false;
    }

    return false;
}

pub fn use_local(context: *const Context, body: View, index: u32, opaque_value: bool) Use {
    assert(body.span().end() <= context.source.len);
    assert(index < context.front.tokens().len);

    const held: Held = .{
        .front = context.front,
        .local = true,
        .path = context.path,
        .source = context.source,
    };

    const occurrence: Occurrence = .{ .body = body, .index = index, .opaque_value = opaque_value };

    return use_of(&held, &occurrence);
}

fn receiver_translated(
    held: *const Held,
    function: Function,
    callee: []const u8,
    item: *Item,
) bool {
    assert(callee.len > 0);
    assert(item.depth <= depth_max);
    assert(function.view.span().end() <= held.source.len);

    const dot = std.mem.findScalar(u8, callee, '.') orelse {
        item.path = NameText.joined(callee, "") orelse return false;

        return true;
    };

    if (dot == 0) return false;

    const head = callee[0..dot];
    const rest = callee[dot + 1 ..];
    const typed = parameter_type_named(held, function, head) orelse {
        item.path = NameText.joined(callee, "") orelse return false;

        return true;
    };

    if (typed.len == 0) return false;

    const stripped = type_stripped(typed);
    if (!is_name_path(stripped)) return false;

    item.path = NameText.joined(stripped, rest) orelse return false;
    item.method = true;

    return true;
}

fn parameter_type_named(held: *const Held, function: Function, name: []const u8) ?[]const u8 {
    assert(name.len > 0);
    assert(function.view.span().end() <= held.source.len);

    var parameters = function.parameters();

    for (0..parameters.remaining) |_| {
        const parameter = parameters.next() orelse return null;
        const position = parameter.name orelse continue;
        if (!std.mem.eql(u8, held.token_text(position), name)) continue;

        const span = parameter.type_span orelse return null;

        return scan.trim_ascii(held.span_text(span));
    }

    return null;
}

fn type_stripped(typed: []const u8) []const u8 {
    assert(typed.len > 0);

    var text = scan.trim_ascii(typed);

    for (0..4) |_| {
        if (std.mem.startsWith(u8, text, "?")) {
            text = scan.trim_ascii(text[1..]);
        } else if (std.mem.startsWith(u8, text, "*")) {
            text = scan.trim_ascii(text[1..]);
        } else if (std.mem.startsWith(u8, text, "const ")) {
            text = scan.trim_ascii(text["const ".len..]);
        } else {
            break;
        }
    }

    assert(text.len <= typed.len);

    return text;
}

fn receiver_mutable(held: *const Held, function: Function, item: *const Item) bool {
    assert(function.view.span().end() <= held.source.len);
    assert(item.depth <= depth_max);

    if (!item.method) return false;

    const receiver = parameter_at(function, 0) orelse return false;
    const span = receiver.type_span orelse return false;
    const typed = scan.trim_ascii(held.span_text(span));

    return std.mem.startsWith(u8, typed, "*") and !scan.find_word(typed, "const");
}

pub fn parameter_at(function: Function, index: u32) ?View.Parameter {
    assert(index < std.math.maxInt(u32));
    assert(function.view.span().length > 0);

    var parameters = function.parameters();

    for (0..parameters.remaining) |position| {
        const parameter = parameters.next() orelse return null;
        if (position == index) return parameter;
    }

    return null;
}

fn member_function(held: *const Held, scope: View, name: []const u8) ?View {
    assert(name.len > 0);
    assert(scope.span().end() <= held.source.len);

    var functions = scope.children_of(.function);

    for (0..functions.remaining) |_| {
        const node = functions.next() orelse break;
        const function = node.as_function() orelse continue;
        const position = function.name_token() orelse continue;

        if (std.mem.eql(u8, held.token_text(position), name)) return node;
    }

    return null;
}

fn member_value(held: *const Held, scope: View, name: []const u8) ?View {
    assert(name.len > 0);
    assert(scope.span().end() <= held.source.len);

    var declarations = scope.children_of(.declaration);

    for (0..declarations.remaining) |_| {
        const node = declarations.next() orelse break;
        const declaration = node.as_declaration() orelse continue;
        const position = declaration.name_token() orelse continue;
        if (!std.mem.eql(u8, held.token_text(position), name)) continue;

        return declaration.value();
    }

    return null;
}

fn member_field_type(held: *const Held, scope: View, name: []const u8) ?[]const u8 {
    assert(name.len > 0);
    assert(scope.span().end() <= held.source.len);

    var declarations = scope.children_of(.declaration);

    for (0..declarations.remaining) |_| {
        const node = declarations.next() orelse break;
        const field = node.as_field() orelse continue;
        const position = field.name_token() orelse continue;
        if (!std.mem.eql(u8, held.token_text(position), name)) continue;

        const typed = field.type_of() orelse return null;
        const text = scan.trim_ascii(typed.text(held.source));
        if (text.len == 0) return null;

        return text;
    }

    return null;
}

fn field_path(typed: []const u8, rest: []const u8) ?NameText {
    assert(typed.len > 0);
    assert(rest.len < name_bytes_max);

    if (rest.len == 0) return null;

    const stripped = type_stripped(typed);
    if (!is_name_path(stripped)) return null;

    return NameText.joined(stripped, rest);
}

fn declaring_scope(held: *const Held, scope: View, name: []const u8) ?View {
    assert(name.len > 0);
    assert(scope.span().end() <= held.source.len);

    var current: ?View = scope;

    for (0..scope_depth_max) |_| {
        const node = current orelse return null;
        const above = node.parent();

        if (opens_a_scope(node, above)) {
            if (declares(held, node, name)) return node;
        }

        current = above;
    }

    return null;
}

fn opens_a_scope(view: View, above: ?View) bool {
    assert(view.index() < view.node_count());
    if (above) |parent| assert(parent.index() < view.index());

    if (above == null) return true;
    return view.as_container() != null;
}

fn declares(held: *const Held, scope: View, name: []const u8) bool {
    assert(name.len > 0);
    assert(scope.span().end() <= held.source.len);

    if (member_function(held, scope, name) != null) return true;
    if (member_extern(held, scope, name)) return true;
    return member_value(held, scope, name) != null;
}

fn inside_a_function(view: View) bool {
    assert(view.index() < view.node_count());

    var current = view.parent();

    for (0..scope_depth_max) |_| {
        const above = current orelse return false;
        if (above.category() == .function) return true;

        current = above.parent();
    }

    return true;
}

fn member_extern(held: *const Held, scope: View, name: []const u8) bool {
    assert(name.len > 0);
    assert(scope.span().end() <= held.source.len);

    var children = scope.children();

    for (0..children.remaining) |_| {
        const node = children.next() orelse break;
        const tokens = tokens_within(held, node.span());
        if (tokens.len < 3) continue;
        if (prototype_named(held, tokens, name)) return true;
    }

    return false;
}

fn prototype_named(held: *const Held, tokens: []const Token, name: []const u8) bool {
    assert(tokens.len >= 3);
    assert(name.len > 0);

    var external = false;

    for (tokens[0 .. tokens.len - 1], 0..) |token, index| {
        const text = held.text_of(token);

        if (std.mem.eql(u8, text, extern_word)) external = true;
        if (std.mem.eql(u8, text, "{")) return false;
        if (!std.mem.eql(u8, text, "fn")) continue;
        if (!external) return false;

        return std.mem.eql(u8, held.text_of(tokens[index + 1]), name);
    }

    return false;
}

fn declares_extern(held: *const Held, node: View) bool {
    assert(node.span().end() <= held.source.len);

    const tokens = tokens_within(held, node.span());

    for (tokens) |token| {
        const text = held.text_of(token);

        if (std.mem.eql(u8, text, "fn")) return false;
        if (std.mem.eql(u8, text, extern_word)) return true;
    }

    return false;
}

fn scalar_named(held: *const Held, function: View, typed: []const u8) bool {
    assert(typed.len > 0);
    assert(function.span().end() <= held.source.len);

    if (integer_type(typed)) return true;
    if (std.mem.eql(u8, typed, "bool")) return true;
    if (!is_name_path(typed)) return false;
    if (std.mem.findScalar(u8, typed, '.') != null) return false;

    const scope = declaring_scope(held, function, typed) orelse return false;
    const value = member_value(held, scope, typed) orelse return false;
    const spelled = scan.trim_ascii(value.text(held.source));

    return integer_type(spelled) or std.mem.eql(u8, spelled, "bool");
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

fn use_of(held: *const Held, occurrence: *const Occurrence) Use {
    const tokens = held.front.tokens();
    const token = tokens[occurrence.index];
    var value: Span = .{ .offset = token.offset, .length = token.length };

    assert(occurrence.index < tokens.len);
    assert(token.kind == .identifier);

    if (inside_assertion(held, occurrence.body, token.offset)) return .refused;
    if (scan.word_in(&inspection_words, token_after(held, token.end()))) return .refused;

    for (0..wrapper_depth_max) |_| {
        const before = token_before(held, value.offset);
        const after = token_after(held, value.end());

        if (scan.word_in(&comparison_words, before)) return .total;
        if (scan.word_in(&comparison_words, after)) return .total;
        if (scan.word_in(&bitwise_words, after)) return .total;
        if (scan.word_in(&shift_words, after)) return .total;
        if (scan.word_in(&shift_words, before)) return .refused;
        if (std.mem.eql(u8, before, "return")) return .total;
        if (subject_of_switch(held, value.offset)) return .total;

        if (std.mem.eql(u8, before, "=")) {
            if (declared_name(held, value.offset)) |name| return .{ .aliased = name };
            if (!scan.word_in(&.{ ";", ",", "}" }, after)) return .refused;
            return if (occurrence.opaque_value) .total else .refused;
        }

        const holding = argument_holding(held, occurrence.body, value) orelse return .refused;
        const callee = callee_text(held, holding.call) orelse return .refused;

        if (std.mem.eql(u8, callee, "assert")) return .refused;
        if (std.mem.eql(u8, callee, encode_call)) return position_use(holding, 2);
        if (std.mem.eql(u8, callee, cast_call)) return position_use(holding, 1);

        if (std.mem.eql(u8, callee, "@intCast")) {
            if (guarded_before(held, occurrence)) return .total;
            return .refused;
        }

        if (scan.word_in(&casts_total, callee)) {
            value = holding.call.view.span();

            continue;
        }

        if (std.mem.eql(u8, callee, "@as")) {
            if (holding.position != 1) return .refused;

            value = holding.call.view.span();

            continue;
        }

        if (callee[0] == '@') return .refused;

        return .{
            .forwarded = .{ .call = holding.call, .callee = callee, .position = holding.position },
        };
    }

    return .refused;
}

fn position_use(holding: Holding, wanted: u32) Use {
    assert(holding.call.view.category() == .call);
    assert(wanted < std.math.maxInt(u32));

    return if (holding.position == wanted) .total else .refused;
}

fn inside_assertion(held: *const Held, body: View, offset: u32) bool {
    assert(offset <= held.source.len);
    assert(body.span().end() <= held.source.len);

    for (held.front.nodes_of(.call)) |position| {
        const node = held.front.view(position) orelse continue;
        if (!node.span().contains(offset)) continue;
        if (!body.span().contains(node.span().offset)) continue;

        const call = node.as_call() orelse continue;
        const callee = callee_text(held, call) orelse continue;

        if (std.mem.eql(u8, callee, "assert")) return true;
    }

    return false;
}

fn subject_of_switch(held: *const Held, offset: u32) bool {
    assert(offset <= held.source.len);

    const tokens = held.front.tokens();
    const index = token_index_at(tokens, offset);
    if (index < 2) return false;

    const open = held.text_of(tokens[index - 1]);
    const keyword = held.text_of(tokens[index - 2]);

    return std.mem.eql(u8, open, "(") and std.mem.eql(u8, keyword, "switch");
}

fn declared_name(held: *const Held, offset: u32) ?[]const u8 {
    assert(offset <= held.source.len);

    const tokens = held.front.tokens();
    const index = token_index_at(tokens, offset);
    if (index < 2) return null;

    var cursor = index - 1;

    for (0..declaration_scan_max) |_| {
        if (cursor == 0) return null;

        cursor -= 1;

        const text = held.text_of(tokens[cursor]);

        if (scan.word_in(&.{ ";", "{", "}" }, text)) return null;

        if (scan.word_in(&.{ "const", "var" }, text)) {
            if (cursor + 1 >= index) return null;

            const name = tokens[cursor + 1];
            if (name.kind != .identifier) return null;

            return held.text_of(name);
        }
    }

    return null;
}

fn guarded_before(held: *const Held, occurrence: *const Occurrence) bool {
    const tokens = held.front.tokens();
    const name = held.text_of(tokens[occurrence.index]);
    const start = token_index_at(tokens, occurrence.body.span().offset);

    assert(occurrence.index < tokens.len);
    assert(start <= occurrence.index);

    var guarded = false;

    for (tokens[start..occurrence.index], start..) |token, index| {
        if (token.kind != .identifier) continue;
        if (!std.mem.eql(u8, held.text_of(token), name)) continue;
        if (index + 1 >= tokens.len) continue;
        if (!scan.word_in(&comparison_words, held.text_of(tokens[index + 1]))) continue;

        guarded = guarded or opens_a_guard(held, @intCast(index));
    }

    return guarded;
}

fn opens_a_guard(held: *const Held, index: u32) bool {
    const tokens = held.front.tokens();

    assert(index < tokens.len);

    var cursor = index;
    var depth: u32 = 0;

    for (0..declaration_scan_max) |_| {
        if (cursor == 0) return false;

        cursor -= 1;

        const text = held.text_of(tokens[cursor]);

        if (std.mem.eql(u8, text, ")")) depth += 1;

        if (std.mem.eql(u8, text, "(")) {
            if (depth == 0) {
                if (cursor == 0) return false;
                return std.mem.eql(u8, held.text_of(tokens[cursor - 1]), "if");
            }

            depth -= 1;
        }
    }

    return false;
}

fn argument_holding(held: *const Held, body: View, value: Span) ?Holding {
    assert(value.end() <= held.source.len);
    assert(body.span().end() <= held.source.len);

    const positions = held.front.nodes_of(.call);
    var found: ?Holding = null;
    var narrowest: u32 = std.math.maxInt(u32);

    for (positions) |position| {
        const node = held.front.view(position) orelse continue;
        if (!node.span().contains(value.offset)) continue;
        if (!body.span().contains(node.span().offset)) continue;

        const call = node.as_call() orelse continue;
        var arguments = call.arguments();

        for (0..arguments.remaining) |index| {
            const argument = arguments.next() orelse break;
            const span = argument.span();
            if (span.offset != value.offset) continue;
            if (span.length != value.length) continue;
            if (node.span().length >= narrowest) continue;

            narrowest = node.span().length;
            found = .{ .call = call, .position = @intCast(index) };
        }
    }

    return found;
}

fn callee_text(held: *const Held, call: View.Call) ?[]const u8 {
    assert(call.view.span().end() <= held.source.len);

    if (call.callee()) |callee| {
        const text = scan.trim_ascii(callee.text(held.source));
        if (text.len == 0) return null;
        return text;
    }

    const position = call.name_token() orelse return null;

    return held.token_text(position);
}

fn results_import(held: *const Held, tokens: []const Token) bool {
    assert(tokens.len > 0);

    for (tokens, 0..) |token, index| {
        const text = held.text_of(token);
        const result = result_after(held, tokens, @intCast(index), text) orelse continue;
        if (result >= tokens.len) return false;

        const opening = held.text_of(tokens[result]);

        if (std.mem.eql(u8, opening, import_word)) continue;
        if (std.mem.eql(u8, opening, compile_error_word)) continue;
        if (std.mem.eql(u8, opening, "if")) continue;
        if (std.mem.eql(u8, opening, "switch")) continue;
        return false;
    }

    return true;
}

fn result_after(held: *const Held, tokens: []const Token, index: u32, text: []const u8) ?u32 {
    assert(index < tokens.len);
    assert(text.len > 0);

    const result: ?u32 = if (std.mem.eql(u8, text, "=>"))
        index + 1
    else if (std.mem.eql(u8, text, "else"))
        else_result(held, tokens, index)
    else if (std.mem.eql(u8, text, "if"))
        condition_result(held, tokens, index)
    else
        null;

    if (result) |position| assert(position > index);

    return result;
}

fn else_result(held: *const Held, tokens: []const Token, index: u32) ?u32 {
    assert(index < tokens.len);
    assert(std.mem.eql(u8, held.text_of(tokens[index]), "else"));

    const next = index + 1;

    if (next < tokens.len) {
        if (std.mem.eql(u8, held.text_of(tokens[next]), "=>")) return null;
    }

    assert(next > index);

    return next;
}

fn condition_result(held: *const Held, tokens: []const Token, index: u32) u32 {
    assert(index < tokens.len);
    assert(std.mem.eql(u8, held.text_of(tokens[index]), "if"));

    const found = group_close(held, tokens, index + 1);
    const result: u32 = if (found) |close| close + 1 else @intCast(tokens.len);

    assert(result > index);

    return result;
}

fn group_close(held: *const Held, tokens: []const Token, open: u32) ?u32 {
    if (open >= tokens.len) return null;
    if (!std.mem.eql(u8, held.text_of(tokens[open]), "(")) return null;

    var depth: u32 = 0;

    for (tokens[open..], open..) |token, index| {
        const text = held.text_of(token);

        if (std.mem.eql(u8, text, "(")) depth += 1;

        if (std.mem.eql(u8, text, ")")) {
            depth -= 1;

            if (depth == 0) {
                const close: u32 = @intCast(index);

                assert(close > open);

                return close;
            }
        }
    }

    return null;
}

fn branch_item(
    held: *const Held,
    tokens: []const Token,
    rest: []const u8,
    item: *const Item,
) ?Item {
    assert(tokens.len > 0);
    assert(std.mem.eql(u8, held.text_of(tokens[0]), import_word));
    assert(rest.len < name_bytes_max);

    if (tokens.len < 4) return null;
    if (!std.mem.eql(u8, held.text_of(tokens[1]), "(")) return null;
    if (tokens[2].kind != .string) return null;

    const quoted = held.text_of(tokens[2]);
    if (quoted.len < 3) return null;

    const specifier = quoted[1 .. quoted.len - 1];
    const suffix = suffix_after(held, tokens[3..]);

    const branch: Item = .{
        .depth = item.depth,
        .from = PathText.joined(held.path, "") orelse return null,
        .method = item.method,
        .path = NameText.joined(suffix, rest) orelse return null,
        .position = item.position,
        .scope = root_node,
        .specifier = PathText.joined(specifier, "") orelse return null,
    };

    if (branch.path.length == 0) return null;

    return branch;
}

fn suffix_after(held: *const Held, tokens: []const Token) []const u8 {
    assert(tokens.len <= held.front.tokens().len);

    if (tokens.len < 3) return "";
    if (!std.mem.eql(u8, held.text_of(tokens[0]), ")")) return "";
    if (!std.mem.eql(u8, held.text_of(tokens[1]), ".")) return "";

    const start = tokens[2].offset;
    var end = tokens[2].end();

    for (tokens[2..], 2..) |token, index| {
        if (index % 2 == 0) {
            if (token.kind != .identifier) break;

            end = token.end();
        } else {
            if (!std.mem.eql(u8, held.text_of(token), ".")) break;
        }
    }

    assert(start <= end);

    return held.source[start..end];
}

fn import_specifier(spelled: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, spelled, import_word ++ "(")) return null;

    const inner = scan.trim_ascii(spelled[import_word.len + 1 ..]);
    if (inner.len < 2) return null;
    if (inner[0] != '"') return null;

    const closing = std.mem.findScalarPos(u8, inner, 1, '"') orelse return null;
    if (closing == 1) return null;

    assert(closing < inner.len);

    return inner[1..closing];
}

fn import_suffix(spelled: []const u8) []const u8 {
    assert(std.mem.startsWith(u8, spelled, import_word));

    const close = std.mem.findScalar(u8, spelled, ')') orelse return "";
    const after = spelled[close + 1 ..];

    if (std.mem.startsWith(u8, after, ".")) return after[1..];
    return "";
}

fn is_name_path(text: []const u8) bool {
    if (text.len == 0) return false;
    if (text[0] == '.') return false;
    if (text[text.len - 1] == '.') return false;
    if (std.mem.find(u8, text, "..") != null) return false;

    for (text) |byte| {
        if (byte == '.') continue;
        if (!scan.is_identifier_part(byte)) return false;
    }

    return !std.ascii.isDigit(text[0]);
}

fn tokens_within(held: *const Held, span: Span) []const Token {
    assert(span.end() <= held.source.len);

    const tokens = held.front.tokens();
    const first = token_index_at(tokens, span.offset);
    var last = first;

    for (tokens[first..]) |token| {
        if (token.offset >= span.end()) break;

        last += 1;
    }

    assert(first <= last);
    assert(last <= tokens.len);

    return tokens[first..last];
}

pub fn token_index_at(tokens: []const Token, offset: u32) u32 {
    assert(tokens.len < std.math.maxInt(u32));

    var low: u32 = 0;
    var high: u32 = @intCast(tokens.len);

    for (0..64) |_| {
        if (low >= high) break;

        const middle = low + (high - low) / 2;

        if (tokens[middle].offset < offset) {
            low = middle + 1;
        } else {
            high = middle;
        }
    }

    assert(low <= tokens.len);

    return low;
}

fn token_before(held: *const Held, offset: u32) []const u8 {
    const tokens = held.front.tokens();
    const index = token_index_at(tokens, offset);

    assert(index <= tokens.len);

    if (index == 0) return "";
    return held.text_of(tokens[index - 1]);
}

fn token_after(held: *const Held, offset: u32) []const u8 {
    const tokens = held.front.tokens();
    const index = token_index_at(tokens, offset);

    assert(index <= tokens.len);

    if (index == tokens.len) return "";
    return held.text_of(tokens[index]);
}

const Source = struct {
    data: []const u8,
    name: []const u8,
};

const imported_code = "pub const Code = enum(u32) { _ };\n";

const imported_queue = "const Code = @import(\"code.zig\").Code;\n\n" ++
    "const Slot = struct {\n    code: Code,\n};\n\n" ++
    "var slot: Slot = undefined;\n\n" ++
    "pub fn post(code: Code) bool {\n    if (!enqueue(code)) return false;\n\n" ++
    "    return true;\n}\n\n" ++
    "fn enqueue(code: Code) bool {\n    slot.code = code;\n\n    return true;\n}\n";

const imported_fake_loop = "const Code = @import(\"code.zig\").Code;\n\n" ++
    "const Event = struct {\n    code: Code,\n};\n\n" ++
    "var queue: Event = undefined;\n\n" ++
    "pub fn post(code: Code) bool {\n    queue = .{ .code = code };\n\n    return true;\n}\n";

const imported_native_loop = "const Code = @import(\"code.zig\").Code;\n" ++
    "const queue = @import(\"queue.zig\");\n\n" ++
    "pub fn post(code: Code) bool {\n    return queue.post(code);\n}\n";

const imported_platform = "pub const backend = if (options.fake)\n    @import(\"fake.zig\")\n" ++
    "else switch (target.os) {\n    .linux => @import(\"native.zig\"),\n" ++
    "    else => @compileError(\"unsupported\"),\n};\n";

const imported_posting = "const Code = @import(\"code.zig\").Code;\n" ++
    "const platform = @import(\"platform.zig\");\n\n" ++
    "const backend = platform.backend.loop;\n\n" ++
    "pub fn post(code: Code) bool {\n    return backend.post(code);\n}\n";

const imported_wire = "pub const Writer = struct {\n    buffer: [8]u8,\n\n" ++
    "    pub fn put_u32(writer: *Writer, value: u32) void {\n" ++
    "        writer.put_raw(u32, value);\n    }\n\n" ++
    "    pub fn put_narrow(writer: *Writer, value: u32) void {\n" ++
    "        assert(value < 10);\n\n        writer.put_raw(u32, value);\n    }\n\n" ++
    "    fn put_raw(writer: *Writer, comptime T: type, value: T) void {\n" ++
    "        std.mem.writeInt(T, writer.buffer[0..@sizeOf(T)], value, .little);\n    }\n};\n";

const imported_writing = "const wire = @import(\"wire.zig\");\n\n" ++
    "const Writer = wire.Writer;\n\n" ++
    "pub fn put(writer: *Writer, value: u32) void {\n    writer.put_u32(value);\n}\n\n" ++
    "pub fn narrow(writer: *Writer, value: u32) void {\n    writer.put_narrow(value);\n}\n";

const imported_native = "pub const loop = @import(\"native_loop.zig\");\n";
const imported_fake = "pub const loop = @import(\"fake_loop.zig\");\n";

const imported_system = "pub const LRESULT = isize;\n" ++
    "pub extern \"user32\" fn PostMessageW(message: u32, wparam: usize) " ++
    "callconv(.winapi) LRESULT;\n\n" ++
    "pub fn deliver(slot: u64) bool {\n    if (slot >= 4) return false;\n\n" ++
    "    const index: u32 = @intCast(slot);\n\n    return index < 4;\n}\n\n" ++
    "const Count = struct {\n    total: u32,\n};\n\nvar count: Count = undefined;\n\n" ++
    "pub fn store(total: u32) void {\n    count.total = total;\n}\n";

const imported_calling = "const system = @import(\"system.zig\");\n\n" ++
    "pub fn post(message: u32, wparam: usize) isize {\n" ++
    "    return system.PostMessageW(message, wparam);\n}\n\n" ++
    "pub fn deliver(wparam: u64) bool {\n    return system.deliver(wparam);\n}\n\n" ++
    "pub fn store(total: u32) void {\n    system.store(total);\n}\n";

const imported_timers = "const TimerTable = @This();\n\n" ++
    "ids: [4]u32,\ncolor: u32,\n\n" ++
    "pub fn stop(table: *TimerTable, id: u32) bool {\n" ++
    "    for (table.ids) |held| {\n        if (held == id) return true;\n    }\n\n" ++
    "    return false;\n}\n\n" ++
    "pub fn recolor(table: *TimerTable, color: u32) void {\n    table.color = color;\n}\n";

const imported_owning = "const TimerTable = @import(\"timers.zig\");\n\n" ++
    "const Owner = @This();\n\n" ++
    "inner: Inner,\ntimers: TimerTable,\n\n" ++
    "const Inner = struct {\n    timers: TimerTable,\n};\n\n" ++
    "pub fn stop(owner: *Owner, id: u32) bool {\n    return owner.timers.stop(id);\n}\n\n" ++
    "pub fn stop_inner(owner: *Owner, id: u32) bool {\n" ++
    "    return owner.inner.timers.stop(id);\n}\n\n" ++
    "pub fn stop_held(inner: *Inner, id: u32) bool {\n    return inner.timers.stop(id);\n}\n\n" ++
    "pub fn recolor(owner: *Owner, color: u32) void {\n    owner.timers.recolor(color);\n}\n";

const imported_ledger = "const Ledger = @This();\n\nids: [4]u32,\n\n" ++
    "pub fn stop(ledger: *Ledger, id: u32) bool {\n" ++
    "    for (ledger.ids) |held| {\n        if (held == id) return true;\n    }\n\n" ++
    "    return false;\n}\n\n" ++
    "pub fn find(ledger: *const Ledger, id: u32) bool {\n" ++
    "    for (ledger.ids) |held| {\n        if (held == id) return true;\n    }\n\n" ++
    "    return false;\n}\n";

const imported_settling = "const Ledger = @import(\"ledger.zig\");\n\n" ++
    "const Owner = @This();\n\nledger: Ledger,\n\n" ++
    "pub fn stop(owner: *Owner, id: u32) bool {\n" ++
    "    const stopped = owner.ledger.stop(id);\n\n" ++
    "    assert(!owner.ledger.find(id));\n\n    return stopped;\n}\n\n" ++
    "pub fn find(owner: *Owner, slot: u32) bool {\n" ++
    "    const found = owner.ledger.find(slot);\n\n" ++
    "    assert(owner.ledger.find(slot));\n\n    return found;\n}\n";

fn imported_findings(files: []const Source, main: []const u8) !testing.Findings {
    assert(files.len > 0);
    assert(main.len > 0);

    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{ .iterate = false });
    defer temporary.cleanup();

    for (files) |file| {
        try temporary.dir.writeFile(io, .{ .sub_path = file.name, .data = file.data });
    }

    try temporary.dir.writeFile(io, .{ .sub_path = "main.zig", .data = main });

    const path = try std.Io.Dir.path.join(gpa, &.{
        std.testing.TmpDir.parent_dir_path,
        &temporary.sub_path,
        "main.zig",
    });
    defer gpa.free(path);

    var imports: Imports = undefined;

    try imports.init(gpa, io, &Imports.test_capacity);
    defer imports.deinit(gpa);

    const imported: testing.Imported = .{ .imports = &imports, .path = path };

    return testing.analyze_imported(assert_parameters, main, &imported);
}

test "a code forwarded through a comptime chosen import reaches functions that accept it" {
    const files = [_]Source{
        .{ .data = imported_code, .name = "code.zig" },
        .{ .data = imported_fake, .name = "fake.zig" },
        .{ .data = imported_fake_loop, .name = "fake_loop.zig" },
        .{ .data = imported_native, .name = "native.zig" },
        .{ .data = imported_native_loop, .name = "native_loop.zig" },
        .{ .data = imported_platform, .name = "platform.zig" },
        .{ .data = imported_queue, .name = "queue.zig" },
    };

    var findings = try imported_findings(&files, imported_posting);
    defer findings.deinit();

    if (findings.count() != 0) findings.print();

    try std.testing.expectEqual(@as(u32, 0), findings.count());
}

test "a method reached through a typed receiver is judged by its own contract" {
    const files = [_]Source{.{ .data = imported_wire, .name = "wire.zig" }};
    var findings = try imported_findings(&files, imported_writing);
    defer findings.deinit();

    if (findings.count() != 1) findings.print();

    const narrowed = std.mem.find(u8, imported_writing, "pub fn narrow").?;

    try std.testing.expectEqual(@as(u32, 1), findings.count());
    try std.testing.expect(std.mem.find(u8, findings.message(0), "assert value at") != null);
    try std.testing.expect(findings.span(0).offset > narrowed);
}

test "a method reached through a chain of fields is judged by its own contract" {
    const files = [_]Source{.{ .data = imported_timers, .name = "timers.zig" }};
    var findings = try imported_findings(&files, imported_owning);
    defer findings.deinit();

    if (findings.count() != 1) findings.print();

    const recolored = std.mem.find(u8, imported_owning, "pub fn recolor").?;

    try std.testing.expectEqual(@as(u32, 1), findings.count());
    try std.testing.expect(std.mem.find(u8, findings.message(0), "assert color at") != null);
    try std.testing.expect(findings.span(0).offset > recolored);

    var unresolved = try testing.analyze(assert_parameters, .zig, imported_owning);
    defer unresolved.deinit();

    try std.testing.expectEqual(@as(u32, 4), unresolved.count());
}

test "an assertion on a receiver a mutating method changed is a postcondition" {
    const files = [_]Source{.{ .data = imported_ledger, .name = "ledger.zig" }};
    var findings = try imported_findings(&files, imported_settling);
    defer findings.deinit();

    if (findings.count() != 1) findings.print();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
    try std.testing.expect(std.mem.find(u8, findings.message(0), "assert slot at") != null);

    var unresolved = try testing.analyze(assert_parameters, .zig, imported_settling);
    defer unresolved.deinit();

    try std.testing.expectEqual(@as(u32, 2), unresolved.count());
}

test "an extern call and a guarded cast accept every value but a remote scalar store does not" {
    const files = [_]Source{.{ .data = imported_system, .name = "system.zig" }};
    var findings = try imported_findings(&files, imported_calling);
    defer findings.deinit();

    if (findings.count() != 1) findings.print();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
    try std.testing.expect(std.mem.find(u8, findings.message(0), "assert total at") != null);
}

test "a forward into another file is reported without an import reader" {
    var findings = try testing.analyze(assert_parameters, .zig, imported_calling);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 3), findings.count());
}

test "a forward through a decl literal call is refused rather than resolved" {
    const source = "const Kind = enum(u8) {\n    a,\n    _,\n\n" ++
        "    pub fn of(value: u8) Kind {\n        return @enumFromInt(value);\n    }\n};\n\n" ++
        "fn pick(value: u8) Kind {\n    return .of(value);\n}\n";

    var findings = try testing.analyze(assert_parameters, .zig, source);
    defer findings.deinit();

    if (findings.count() != 2) findings.print();

    const picked = std.mem.find(u8, source, "fn pick").?;

    try std.testing.expectEqual(@as(u32, 2), findings.count());
    try std.testing.expect(std.mem.find(u8, findings.message(1), "assert value at") != null);
    try std.testing.expect(findings.span(1).offset > picked);
}

test "a name path splits into its first segment and the rest" {
    const path = NameText.joined("platform.backend", "loop.post").?;

    try std.testing.expectEqualStrings("platform.backend.loop.post", path.slice());
    try std.testing.expectEqualStrings("platform", path.first());
    try std.testing.expectEqualStrings("backend.loop.post", path.rest());
    try std.testing.expectEqualStrings("Writer", type_stripped("*const Writer"));
    try std.testing.expectEqualStrings("Writer", type_stripped("?*Writer"));

    const long: [name_bytes_max]u8 = @splat('a');

    try std.testing.expect(NameText.joined(&long, "b") == null);
}
