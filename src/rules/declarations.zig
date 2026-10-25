const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const BindingClass = scylla.Front.Bindings.Class;
const Children = scylla.View.Children;
const Context = @import("context.zig");
const Field = scylla.View.Field;
const Span = scylla.Span;
const View = scylla.View;

binding_index: u32,
context: *const Context,
field_names: ?FieldNames,
node_index: u32,
seen: Span,

const Declarations = @This();

pub const Declaration = struct {
    field: bool,
    kind: NameKind,
    node: View,
    parameter: bool,
    token: u32,
};

pub const NameKind = enum {
    function,
    type,
    value,
};

const FieldNames = struct {
    boundary: ?u32,
    field: Field,
    names: Children,
    named: bool,
    spent: bool,

    fn next(field_names: *FieldNames, context: *const Context) ?u32 {
        assert(field_names.field.view.category() == .declaration);

        if (field_names.spent) return null;

        for (0..field_names.names.remaining) |_| {
            const name = field_names.names.next() orelse break;
            const offset = name.span().offset;

            assert(offset <= context.source.len);

            if (field_names.boundary) |boundary| {
                if (offset >= boundary) break;
            }

            field_names.named = true;

            return offset;
        }

        field_names.spent = true;

        if (field_names.named) return null;

        const position = field_names.field.name_token() orelse return null;
        return context.front_token(position).offset;
    }
};

fn binding_next(declarations: *Declarations) ?Declaration {
    const context = declarations.context;
    const bindings = context.front.bindings();
    const binding_count = bindings.count();

    assert(declarations.binding_index <= binding_count);

    for (declarations.binding_index..binding_count) |index| {
        const binding = bindings.at(@intCast(index));

        declarations.binding_index = @intCast(index + 1);

        if (std.meta.eql(binding.name, declarations.seen)) continue;

        declarations.seen = binding.name;

        if (binding.node >= context.front.node_count()) continue;

        const node = context.view(binding.node).declaring_of();
        const kind = kind_of(binding.class, node) orelse continue;
        const token = context.lexer_index_at(binding.name.offset) orelse continue;

        return .{
            .field = binding.class == .field,
            .kind = kind,
            .node = node,
            .parameter = binding.class == .parameter,
            .token = token,
        };
    }

    assert(declarations.binding_index == binding_count);

    return null;
}

fn field_name_next(declarations: *Declarations) ?Declaration {
    const field_names = if (declarations.field_names) |*held| held else return null;

    assert(declarations.node_index > 0);

    for (0..field_names.names.remaining + 1) |_| {
        const offset = field_names.next(declarations.context) orelse break;
        const token = declarations.context.lexer_index_at(offset) orelse continue;

        return .{
            .field = true,
            .kind = .value,
            .node = field_names.field.view,
            .parameter = false,
            .token = token,
        };
    }

    assert(field_names.spent);

    declarations.field_names = null;

    return null;
}

fn field_names_of(node: View) ?FieldNames {
    assert(node.category() == .declaration);

    const field = node.as_field() orelse return null;

    assert(field.view.index() == node.index());

    if (node.ancestor_of(.@"struct") == null) return null;
    if (node.is_inside_signature()) return null;

    const boundary: ?u32 = if (field.type_of()) |held| held.span().offset else null;

    return .{
        .boundary = boundary,
        .field = field,
        .names = node.children_of(.name),
        .named = false,
        .spent = false,
    };
}

fn field_next(declarations: *Declarations) ?Declaration {
    const positions = declarations.context.front.nodes_of(.declaration);

    assert(declarations.node_index <= positions.len);

    for (0..positions.len + 1) |_| {
        if (declarations.field_name_next()) |declaration| return declaration;
        if (declarations.node_index == positions.len) return null;

        const node = declarations.context.view(positions[declarations.node_index]);

        declarations.node_index += 1;
        declarations.field_names = field_names_of(node);

        assert(declarations.node_index <= positions.len);
    }

    unreachable;
}

pub fn next(declarations: *Declarations) ?Declaration {
    assert(declarations.binding_index <= declarations.context.front.bindings().count());
    assert(declarations.node_index <= declarations.context.front.node_count());

    if (declarations.binding_next()) |declaration| return declaration;
    if (!declarations.context.conventions.fields_unbound) return null;
    return declarations.field_next();
}

pub fn of(context: *const Context) Declarations {
    const declarations: Declarations = .{
        .binding_index = 0,
        .context = context,
        .field_names = null,
        .node_index = 0,
        .seen = .empty,
    };

    assert(declarations.binding_index == 0);
    assert(declarations.field_names == null);

    return declarations;
}

fn kind_of(class: BindingClass, node: View) ?NameKind {
    const kind: ?NameKind = switch (class) {
        .constant => if (node.declares_a_container()) .type else .value,
        .field, .local, .parameter => .value,
        .function, .method => .function,
        .import, .other => null,
        .type, .variant => .type,
    };

    if (class == .field) assert(kind == .value);
    if (class == .parameter) assert(kind == .value);

    return kind;
}
