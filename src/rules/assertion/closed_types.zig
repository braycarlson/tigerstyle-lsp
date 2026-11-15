const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const scan = scylla.scan;
const testing = @import("../testing.zig");
const assert_parameters = @import("assert_parameters.zig");
const Context = @import("../context.zig");
const Imports = @import("../../linter/imports.zig");
const File = Imports.File;
const Function = scylla.View.Function;
const Parameter = scylla.View.Parameter;
const View = scylla.View;

const Origin = enum {
    local,
    remote,
};

const Item = struct {
    optional: bool,
    origin: Origin,
    scope: u32,
    text: []const u8,
};

const Cursor = struct {
    calling: bool,
    declaration: u32,
    origin: Origin,
    pending: Path,
};

const Step = union(enum) {
    advance,
    closed,
    expand: u32,
    open,
};

const Fielded = enum {
    members,
    payloads,
};

const Import = struct {
    specifier: []const u8,
    spelled: []const u8,
};

const Path = struct {
    bytes: [path_bytes_max]u8,
    length: u32,

    fn joined(path: *Path, head: []const u8, tail: []const u8) bool {
        assert(is_name_path(head));
        if (tail.len > 0) assert(is_name_path(tail));

        const separator_length: usize = if (tail.len > 0) 1 else 0;
        const total = head.len + separator_length + tail.len;
        if (total > path_bytes_max) return false;

        @memcpy(path.bytes[0..head.len], head);

        if (separator_length > 0) path.bytes[head.len] = '.';

        @memcpy(path.bytes[head.len + separator_length ..][0..tail.len], tail);
        path.length = @intCast(total);

        assert(path.length == total);
        assert(is_name_path(path.bytes[0..path.length]));

        return true;
    }

    fn spliced(path: *Path, head: []const u8, tail: []const u8) bool {
        if (head.len > 0) assert(is_name_path(head));
        if (tail.len > 0) assert(is_name_path(tail));

        if (head.len > 0) return path.joined(head, tail);
        if (tail.len == 0) return false;
        return path.joined(tail, "");
    }

    fn first(path: *const Path) []const u8 {
        assert(path.length > 0);
        assert(path.length <= path_bytes_max);

        const text = path.bytes[0..path.length];
        const dot = std.mem.findScalar(u8, text, '.') orelse return text;

        assert(dot > 0);

        return text[0..dot];
    }

    fn rest(path: *const Path) []const u8 {
        assert(path.length > 0);
        assert(path.length <= path_bytes_max);

        const text = path.bytes[0..path.length];
        const dot = std.mem.findScalar(u8, text, '.') orelse return "";

        assert(dot + 1 < text.len);

        return text[dot + 1 ..];
    }
};

const Source = struct {
    data: []const u8,
    name: []const u8,
};

const Walk = struct {
    context: *const Context,
    count: u32,
    items: [item_count_max]Item,

    fn push(walk: *Walk, item: *const Item) bool {
        assert(walk.count <= item_count_max);
        assert(item.text.len <= walk.source_of(item.origin).len);

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

    fn source_of(walk: *const Walk, origin: Origin) []const u8 {
        const held = walk.file(origin) orelse return "";

        return held.source;
    }

    fn file(walk: *const Walk, origin: Origin) ?File {
        const context = walk.context;

        switch (origin) {
            .local => return .{
                .front = context.front,
                .path = context.path,
                .source = context.source,
            },
            .remote => {
                const imports = context.imports orelse return null;

                return imports.current();
            },
        }
    }

    fn settled(walk: *Walk, item: *const Item) bool {
        const text = scan.trim_ascii(item.text);

        assert(text.len <= item.text.len);

        if (text.len == 0) return false;
        if (scan.word_in(&closed_words, text)) return true;
        if (text[0] == pointer_marker) return true;
        if (is_error_set_literal(text)) return true;

        if (error_union_bang(text)) |bang| {
            var payload = item.*;
            var set = item.*;

            payload.text = text[bang + 1 ..];
            set.text = text[0..bang];

            if (!walk.push(&payload)) return false;
            return walk.push(&set);
        }

        if (std.mem.eql(u8, text, this_call)) return walk.this_expanded(item);
        if (!is_name_path(text)) return false;

        return walk.resolved(item, text);
    }

    fn this_expanded(walk: *Walk, item: *const Item) bool {
        assert(item.text.len > 0);

        const held = walk.file(item.origin) orelse return false;
        const node = held.front.view(item.scope) orelse return false;
        const container = this_container(node) orelse return false;

        return walk.expanded(item.origin, container.index());
    }

    fn resolved(walk: *Walk, item: *const Item, text: []const u8) bool {
        assert(text.len > 0);
        assert(is_name_path(text));

        var path: Path = undefined;
        if (!path.joined(text, "")) return false;

        const start = walk.file(item.origin) orelse return false;

        var cursor: Cursor = .{
            .calling = false,
            .declaration = scoped_lookup(&start, item.scope, path.first()) orelse return false,
            .origin = item.origin,
            .pending = undefined,
        };

        for (0..resolution_step_max) |_| {
            switch (walk.step(item, &cursor, &path)) {
                .advance => continue,
                .closed => return !cursor.calling,
                .expand => |container| {
                    if (cursor.calling) return false;
                    return walk.expanded(cursor.origin, container);
                },
                .open => return false,
            }
        }

        return false;
    }

    fn step(walk: *Walk, item: *const Item, cursor: *Cursor, path: *Path) Step {
        assert(path.length > 0);
        if (item.origin == .remote) assert(cursor.origin == .remote);

        const held = walk.file(cursor.origin) orelse return .open;
        const node = held.front.view(cursor.declaration) orelse return .open;
        if (node.as_function() != null) return returned(&held, cursor, path, node);

        const declaration = node.as_declaration() orelse return .open;
        const value = declaration.value() orelse return .open;
        const spelled = scan.trim_ascii(value.text(held.source));
        const rest = path.rest();

        if (import_specifier(spelled)) |specifier| {
            const import: Import = .{ .specifier = specifier, .spelled = spelled };

            return walk.imported(item, cursor, path, &import);
        }

        if (is_name_path(spelled)) return aliased(&held, cursor, path, spelled);
        if (is_error_set_literal(spelled)) return if (rest.len == 0) .closed else .open;
        if (builds_a_closed_enum(spelled)) return if (rest.len == 0) .closed else .open;

        if (walk.names_a_pointer_or_function(spelled)) {
            if (item.optional) {
                if (!walk.names_a_function(spelled)) return .open;
            }

            return if (rest.len == 0) .closed else .open;
        }

        if (std.mem.eql(u8, spelled, this_call)) return this_resolved(&held, cursor, path, node);
        if (value.as_call() != null) return called(&held, cursor, path, spelled);

        if (value.as_container() == null) {
            if (!merges_error_sets(spelled)) return .open;
            return if (rest.len == 0) .closed else .open;
        }

        if (rest.len == 0) return .{ .expand = value.index() };

        var next: Path = undefined;
        if (!next.joined(rest, "")) return .open;

        path.* = next;
        cursor.declaration = member_lookup(&held, value.index(), path.first()) orelse return .open;

        return .advance;
    }

    fn names_a_pointer_or_function(walk: *const Walk, spelled: []const u8) bool {
        assert(spelled.len > 0);

        if (spelled[0] == pointer_marker) return true;
        return walk.names_a_function(spelled);
    }

    fn names_a_function(walk: *const Walk, spelled: []const u8) bool {
        assert(spelled.len > 0);

        const markers = walk.context.conventions.callback_markers;
        const pointee = if (spelled[0] == pointer_marker) spelled[1..] else spelled;
        const target = std.mem.cutPrefix(u8, pointee, const_qualifier) orelse pointee;

        assert(markers.len > 0);
        assert(target.len <= spelled.len);

        for (markers) |marker| {
            assert(marker.len > 0);

            if (std.mem.startsWith(u8, target, marker)) return true;
        }

        return false;
    }

    fn imported(
        walk: *Walk,
        item: *const Item,
        cursor: *Cursor,
        path: *Path,
        import: *const Import,
    ) Step {
        assert(import.specifier.len > 0);
        assert(import.spelled.len > import.specifier.len);
        assert(path.length > 0);

        if (item.origin == .remote) return .open;

        const imports = walk.context.imports orelse return .open;
        const from = walk.file(cursor.origin) orelse return .open;
        const suffix = import_suffix(import.spelled);
        const opening: Imports.Opening = .{ .from = from.path, .specifier = import.specifier };

        if (suffix.len > 0) {
            if (!is_name_path(suffix)) return .open;
        } else {
            if (path.rest().len == 0) {
                _ = imports.open(&opening) orelse return .open;

                cursor.origin = .remote;

                return .{ .expand = root_node };
            }
        }

        var next: Path = undefined;
        if (!next.spliced(suffix, path.rest())) return .open;

        const opened = imports.open(&opening) orelse return .open;

        path.* = next;
        cursor.origin = .remote;
        cursor.declaration = member_lookup(&opened, root_node, path.first()) orelse return .open;

        return .advance;
    }

    fn expanded(walk: *Walk, origin: Origin, container: u32) bool {
        const held = walk.file(origin) orelse return false;

        assert(container < held.front.node_count());

        const node = held.front.view(container) orelse return false;
        if (node.parent() == null) return walk.root_fields_pushed(origin, node);

        const text = node.text(held.source);
        const brace = std.mem.findScalar(u8, text, '{') orelse return false;
        const header = text[0..brace];

        assert(brace < text.len);

        if (scan.find_word(header, union_word)) {
            if (std.mem.findScalar(u8, header, '(') == null) return false;
            return walk.fields_pushed(origin, node, .payloads);
        }

        if (scan.find_word(header, enum_word)) {
            return closed_enum(&held, node);
        }

        if (scan.find_word(header, struct_word)) {
            return walk.fields_pushed(origin, node, .members);
        }

        return false;
    }

    fn root_fields_pushed(walk: *Walk, origin: Origin, root: View) bool {
        const held = walk.file(origin) orelse return false;

        assert(root.parent() == null);
        assert(root.span().end() <= held.source.len);

        var declarations = root.children_of(.declaration);

        for (0..declarations.remaining) |_| {
            const declaration = declarations.next() orelse break;
            const member = declaration.as_field() orelse continue;
            const typed = member.type_of() orelse return false;

            const pushed: Item = .{
                .optional = false,
                .origin = origin,
                .scope = root.index(),
                .text = typed.text(held.source),
            };

            if (!walk.push(&pushed)) return false;
        }

        return true;
    }

    fn fields_pushed(walk: *Walk, origin: Origin, node: View, fielded: Fielded) bool {
        const held = walk.file(origin) orelse return false;

        assert(node.span().end() <= held.source.len);

        const container = node.as_container() orelse return false;
        var fields = container.fields();

        for (0..fields.remaining) |_| {
            const field = fields.next() orelse break;
            const member = field.as_field() orelse return false;

            if (fielded == .payloads) {
                if (std.mem.findScalar(u8, field.text(held.source), ':') == null) continue;
            }

            const typed = member.type_of() orelse return false;

            const pushed: Item = .{
                .optional = false,
                .origin = origin,
                .scope = node.index(),
                .text = typed.text(held.source),
            };

            if (!walk.push(&pushed)) return false;
        }

        return true;
    }
};

const closed_enum_builders = [_][]const u8{ "std.meta.DeclEnum(", "std.meta.FieldEnum(" };
const closed_words = [_][]const u8{ "anyerror", "bool", "noreturn", "void" };
const const_qualifier = "const ";
const enum_word = "enum";
const error_merge = "||";
const error_word = "error";
const force_unwrap = ".?";
const import_call = "@import(";
const item_count_max: u32 = 64;
const non_exhaustive_name = "_";
const optional_marker = '?';
const orelse_word = "orelse";
const path_bytes_max: u32 = 256;
const pointer_marker = '*';
const resolution_step_max: u32 = 32;
const root_node: u32 = 0;
const scope_depth_max = scylla.limits.parse_depth_max;
const step_count_max: u32 = 256;
const struct_word = "struct";
const this_call = "@This()";
const union_word = "union";
const unreachable_word = "unreachable";
const imported_deep = "pub const Deep = enum { first, second };\n";

const imported_kinds = "pub const Mode = enum { off, on };\n" ++
    "pub const Open = enum(u8) { off, _ };\n" ++
    "pub const Failure = error{Truncated};\n" ++
    "pub const Kind = union(enum) {\n    word,\n    mode: Mode,\n};\n" ++
    "pub const Sized = union(enum) {\n    count: u32,\n};\n" ++
    "pub const Index = struct {\n    pub const Encoding = enum { utf8, utf16 };\n};\n" ++
    "pub const Deep = @import(\"deep.zig\").Deep;\n" ++
    "pub const Standard = @import(\"std\").lang.Optimize;\n";

const imported_main = "const kinds = @import(\"kinds.zig\");\n" ++
    "const Mode = kinds.Mode;\n" ++
    "const Encoding = @import(\"kinds.zig\").Index.Encoding;\n\n" ++
    "fn moded(mode: Mode) void {\n    work(mode);\n}\n\n" ++
    "fn kinded(kind: kinds.Kind) void {\n    work(kind);\n}\n\n" ++
    "fn failed(err: kinds.Failure) void {\n    work(err);\n}\n\n" ++
    "fn encoded(encoding: Encoding) void {\n    work(encoding);\n}\n\n" ++
    "fn opened(value: kinds.Open) void {\n    work(value);\n}\n\n" ++
    "fn sized(held: kinds.Sized) void {\n    work(held);\n}\n\n" ++
    "fn concluded(outcome: kinds.Failure!void) void {\n    work(outcome);\n}\n\n" ++
    "fn deepened(deep: kinds.Deep) void {\n    work(deep);\n}\n\n" ++
    "fn standard(mode: kinds.Standard) void {\n    work(mode);\n}\n";

const imported_interface = "pub const Listener = *const fn (*anyopaque) void;\n" ++
    "pub const Handle = *opaque {};\n" ++
    "pub const Bytes = []const u8;\n";

const imported_listening = "const interface = @import(\"interface.zig\");\n" ++
    "const Listener = interface.Listener;\n\n" ++
    "fn watch(listener: Listener) void {\n    work(listener);\n}\n\n" ++
    "fn show(handle: interface.Handle) void {\n    work(handle);\n}\n\n" ++
    "fn maybe(listener: ?Listener) void {\n    work(listener);\n}\n";

const imported_reading = "const interface = @import(\"interface.zig\");\n\n" ++
    "fn maybe(handle: ?interface.Handle) void {\n    work(handle);\n}\n\n" ++
    "fn read(bytes: interface.Bytes) void {\n    work(bytes);\n}\n";

const imported_ui = "pub const menu = @import(\"menu.zig\");\n";

const imported_menu = "pub fn MenuType(comptime Platform: type) type {\n    return struct {\n" ++
    "        platform: *Platform,\n\n        pub const Item = struct {\n" ++
    "            pub const Owned = struct {\n                value: Platform.Value,\n" ++
    "            };\n\n            pub const Sized = struct {\n                count: u32,\n" ++
    "            };\n\n            pub const Toggle = struct {\n" ++
    "                checked: bool = false,\n            };\n        };\n\n" ++
    "        pub fn count(menu: *const @This()) u32 {\n" ++
    "            return menu.platform.count();\n        }\n    };\n}\n\n" ++
    "pub fn SplitType(comptime wide: bool) type {\n" ++
    "    if (wide) return struct { flag: bool };\n\n    return struct { flag: bool };\n}\n";

const imported_toggling = "const menu_module = @import(\"ui.zig\").menu;\n\n" ++
    "const Local = LocalType(u8);\n\n" ++
    "fn LocalType(comptime T: type) type {\n    return struct {\n        value: T,\n\n" ++
    "        pub const Mode = enum { off, on };\n    };\n}\n\n" ++
    "fn moded(mode: Local.Mode) void {\n    work(mode);\n}\n\n" ++
    "pub fn BuilderType(comptime Platform: type) type {\n    return struct {\n" ++
    "        const Menu = menu_module.MenuType(Platform);\n\n" ++
    "        pub fn toggle(options: Menu.Item.Toggle) void {\n" ++
    "            work(options);\n        }\n    };\n}\n";

const imported_sizing = "const menu_module = @import(\"ui.zig\").menu;\n\n" ++
    "const Split = menu_module.SplitType(true);\n\n" ++
    "fn split(options: Split) void {\n    work(options);\n}\n\n" ++
    "pub fn BuilderType(comptime Platform: type) type {\n    return struct {\n" ++
    "        const Menu = menu_module.MenuType(Platform);\n\n" ++
    "        pub fn sized(options: Menu.Item.Sized) void {\n" ++
    "            work(options);\n        }\n\n" ++
    "        pub fn owned(options: Menu.Item.Owned) void {\n" ++
    "            work(options);\n        }\n    };\n}\n";

const imported_flags = "flag: bool,\nmode: Mode,\n\npub const Mode = enum { off, on };\n";
const imported_counter = "count: u32,\n";

const imported_holding = "const Counter = @import(\"counter.zig\");\n" ++
    "const Flags = @import(\"flags.zig\");\n\n" ++
    "fn flagged(flags: Flags) void {\n    work(flags);\n}\n\n" ++
    "fn counted(counter: Counter) void {\n    work(counter);\n}\n";

pub fn names_a_closed_type(
    context: *const Context,
    function: Function,
    parameter: Parameter,
    text: []const u8,
) bool {
    assert(function.view.span().end() <= context.source.len);
    assert(parameter.span.end() <= context.source.len);
    assert(text.len <= context.source.len);

    if (context.front.language != .zig) return false;
    if (text.len == 0) return false;

    const entry = optional_child(text) orelse text;

    if (entry.len < text.len) {
        if (forces_a_value(context, function, parameter)) return false;
    }

    var walk: Walk = .{ .context = context, .count = 0, .items = undefined };

    const first: Item = .{
        .optional = entry.len < text.len,
        .origin = .local,
        .scope = function.view.index(),
        .text = entry,
    };

    if (!walk.push(&first)) return false;

    for (0..step_count_max) |_| {
        const item = walk.pop() orelse return true;
        if (!walk.settled(&item)) return false;
    }

    return false;
}

fn optional_child(text: []const u8) ?[]const u8 {
    if (text.len < 2) return null;
    if (text[0] != optional_marker) return null;

    const child = scan.trim_ascii(text[1..]);

    assert(child.len < text.len);

    if (child.len == 0) return null;
    if (child[0] == optional_marker) return null;
    if (child[0] == pointer_marker) return null;
    return child;
}

fn forces_a_value(context: *const Context, function: Function, parameter: Parameter) bool {
    assert(function.view.span().end() <= context.source.len);
    assert(parameter.span.end() <= context.source.len);

    const position = parameter.name orelse return true;
    const name = context.front_text(position);
    const body = function.body() orelse return false;
    const tokens = context.tokens_in(body.span());

    assert(name.len > 0);

    for (tokens, 0..) |token, index| {
        if (token.kind != .identifier) continue;
        if (!std.mem.eql(u8, context.text(token), name)) continue;
        if (index + 1 == tokens.len) continue;

        const next = context.text(tokens[index + 1]);
        if (std.mem.startsWith(u8, next, force_unwrap)) return true;
        if (index + 2 == tokens.len) continue;
        if (!std.mem.eql(u8, next, orelse_word)) continue;
        if (std.mem.eql(u8, context.text(tokens[index + 2]), unreachable_word)) return true;
    }

    return false;
}

fn aliased(held: *const File, cursor: *Cursor, path: *Path, spelled: []const u8) Step {
    assert(is_name_path(spelled));
    assert(path.length > 0);

    var next: Path = undefined;
    if (!next.joined(spelled, path.rest())) return .open;

    path.* = next;
    cursor.declaration = scoped_lookup(held, cursor.declaration, path.first()) orelse return .open;

    return .advance;
}

fn called(held: *const File, cursor: *Cursor, path: *Path, spelled: []const u8) Step {
    assert(spelled.len > 0);
    assert(path.length > 0);

    if (cursor.calling) return .open;

    const open = std.mem.findScalar(u8, spelled, '(') orelse return .open;
    const callee = scan.trim_ascii(spelled[0..open]);
    const rest = path.rest();
    if (!is_name_path(callee)) return .open;

    cursor.pending.length = 0;

    if (rest.len > 0) {
        if (!cursor.pending.joined(rest, "")) return .open;
    }

    var next: Path = undefined;
    if (!next.joined(callee, "")) return .open;

    path.* = next;
    cursor.calling = true;
    cursor.declaration = scoped_lookup(held, cursor.declaration, path.first()) orelse return .open;

    return .advance;
}

fn returned(held: *const File, cursor: *Cursor, path: *Path, node: View) Step {
    assert(path.length > 0);
    assert(node.span().end() <= held.source.len);

    if (!cursor.calling) return .open;
    if (path.rest().len > 0) return .open;

    const container = returned_container(held, node) orelse return .open;

    cursor.calling = false;

    if (cursor.pending.length == 0) return .{ .expand = container.index() };

    path.* = cursor.pending;
    cursor.declaration = member_lookup(held, container.index(), path.first()) orelse return .open;

    return .advance;
}

fn this_resolved(held: *const File, cursor: *Cursor, path: *Path, node: View) Step {
    assert(path.length > 0);
    assert(node.span().end() <= held.source.len);

    const container = this_container(node) orelse return .open;
    const rest = path.rest();

    if (rest.len == 0) return .{ .expand = container.index() };

    var next: Path = undefined;
    if (!next.joined(rest, "")) return .open;

    path.* = next;
    cursor.declaration = member_lookup(held, container.index(), path.first()) orelse return .open;

    return .advance;
}

fn this_container(view: View) ?View {
    assert(view.index() < view.node_count());

    var current = view.parent();

    for (0..scope_depth_max) |_| {
        const above = current orelse return null;
        if (above.as_container() != null) return above;
        if (above.parent() == null) return above;

        current = above.parent();
    }

    return null;
}

fn returned_container(held: *const File, node: View) ?View {
    assert(node.span().end() <= held.source.len);

    const function = node.as_function() orelse return null;
    const body = function.body() orelse return null;
    var found: ?View = null;

    for (held.front.nodes_of(.@"return")) |position| {
        const statement = held.front.view(position) orelse continue;
        if (!body.span().contains(statement.span().offset)) continue;

        if (found) |container| {
            if (container.span().contains(statement.span().offset)) continue;
            return null;
        }

        const value = statement.child_first() orelse return null;
        if (value.as_container() == null) return null;

        found = value;
    }

    return found;
}

fn scoped_lookup(held: *const File, scope: u32, name: []const u8) ?u32 {
    assert(name.len > 0);
    assert(scope < held.front.node_count());

    var current: ?View = held.front.view(scope);

    for (0..scope_depth_max) |_| {
        const node = current orelse return null;
        const above = node.parent();

        if (opens_a_scope(node, above)) {
            if (member_lookup(held, node.index(), name)) |found| return found;
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

fn member_lookup(held: *const File, container: u32, name: []const u8) ?u32 {
    assert(name.len > 0);
    assert(container < held.front.node_count());

    const node = held.front.view(container) orelse return null;
    var members = node.children_of(.declaration);

    for (0..members.remaining) |_| {
        const member = members.next() orelse break;
        const declaration = member.as_declaration() orelse continue;
        const token = declaration.name_token() orelse continue;

        if (std.mem.eql(u8, token_text(held, token), name)) return member.index();
    }

    return function_lookup(held, node, name);
}

fn function_lookup(held: *const File, node: View, name: []const u8) ?u32 {
    assert(name.len > 0);
    assert(node.span().end() <= held.source.len);

    var functions = node.children_of(.function);

    for (0..functions.remaining) |_| {
        const member = functions.next() orelse break;
        const function = member.as_function() orelse continue;
        const token = function.name_token() orelse continue;

        if (std.mem.eql(u8, token_text(held, token), name)) return member.index();
    }

    return null;
}

fn token_text(held: *const File, position: u32) []const u8 {
    const tokens = held.front.tokens();

    assert(position < tokens.len);

    const token = tokens[position];

    assert(token.end() <= held.source.len);

    return held.source[token.offset..token.end()];
}

fn closed_enum(held: *const File, node: View) bool {
    assert(node.span().end() <= held.source.len);

    const container = node.as_container() orelse return false;
    var fields = container.fields();

    for (0..fields.remaining) |_| {
        const field = fields.next() orelse break;
        const text = scan.trim_ascii(field.text(held.source));
        if (std.mem.eql(u8, text, non_exhaustive_name)) return false;
    }

    return true;
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

fn builds_a_closed_enum(spelled: []const u8) bool {
    assert(spelled.len > 0);
    assert(closed_enum_builders.len > 0);

    for (closed_enum_builders) |builder| {
        if (std.mem.startsWith(u8, spelled, builder)) return true;
    }

    return false;
}

fn is_error_set_literal(text: []const u8) bool {
    if (!std.mem.startsWith(u8, text, error_word)) return false;

    const rest = scan.trim_ascii(text[error_word.len..]);

    return std.mem.startsWith(u8, rest, "{");
}

fn merges_error_sets(spelled: []const u8) bool {
    assert(spelled.len > 0);

    var depth: u32 = 0;

    for (spelled, 0..) |byte, index| {
        switch (byte) {
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => depth -|= 1,
            '|' => if (depth == 0) {
                if (std.mem.startsWith(u8, spelled[index..], error_merge)) return true;
            },
            else => {},
        }
    }

    return false;
}

fn error_union_bang(text: []const u8) ?usize {
    assert(text.len > 0);

    var depth: u32 = 0;

    for (text, 0..) |byte, index| {
        switch (byte) {
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => depth -|= 1,
            '!' => if (depth == 0) return bang_split(text, index),
            else => {},
        }
    }

    return null;
}

fn bang_split(text: []const u8, index: usize) ?usize {
    assert(index < text.len);
    assert(text[index] == '!');

    if (index == 0) return null;
    if (index + 1 == text.len) return null;
    return index;
}

fn import_specifier(spelled: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, spelled, import_call)) return null;

    const inner = scan.trim_ascii(spelled[import_call.len..]);
    if (inner.len < 2) return null;
    if (inner[0] != '"') return null;

    const closing = std.mem.findScalarPos(u8, inner, 1, '"') orelse return null;
    if (closing == 1) return null;

    assert(closing < inner.len);

    return inner[1..closing];
}

fn import_suffix(spelled: []const u8) []const u8 {
    assert(std.mem.startsWith(u8, spelled, import_call));

    const close = std.mem.findScalar(u8, spelled, ')') orelse return "";
    const after = spelled[close + 1 ..];

    if (std.mem.startsWith(u8, after, ".")) return after[1..];
    return "";
}

fn expect_mentions(source: []const u8, parts: []const []const u8) !void {
    assert(source.len > 0);
    assert(parts.len > 0);

    var findings = try testing.analyze(assert_parameters, .zig, source);
    defer findings.deinit();

    if (findings.count() != parts.len) findings.print();

    try std.testing.expectEqual(parts.len, findings.count());

    for (parts, 0..) |part, index| {
        const message = findings.message(@intCast(index));

        try std.testing.expect(std.mem.find(u8, message, part) != null);
    }
}

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

test "a tagged union whose payloads are all closed has no invalid value" {
    const source = "const Keyword = enum { fn_, var_ };\n\n" ++
        "const Kind = union(enum) {\n    identifier,\n    keyword: Keyword,\n" ++
        "    held: *const u32,\n\n    pub fn name(kind: Kind) u32 {\n" ++
        "        return switch (kind) {\n            .identifier => 0,\n" ++
        "            .keyword, .held => 1,\n        };\n    }\n};\n\n" ++
        "const Count = union(enum) {\n    count: u32,\n    none,\n};\n\n" ++
        "const Raw = union {\n    flag: bool,\n    other: bool,\n};\n\n" ++
        "fn mark(kind: Kind) void {\n    work(kind);\n}\n\n" ++
        "fn count(held: Count) void {\n    work(held);\n}\n\n" ++
        "fn raw(value: Raw) void {\n    work(value);\n}\n";

    try expect_mentions(source, &.{ "assert held at", "assert value at" });
}

test "a struct whose fields are all closed has no invalid value" {
    const source = "const Mode = enum { off, on };\n\n" ++
        "const Heads = struct {\n    bodied: bool,\n    mode: Mode = .off,\n};\n\n" ++
        "const Sized = struct {\n    bodied: bool,\n    count: u32,\n};\n\n" ++
        "fn drop(heads: Heads) void {\n    work(heads);\n}\n\n" ++
        "fn size(sized: Sized) void {\n    work(sized);\n}\n";

    try expect_mentions(source, &.{"assert sized at"});
}

test "an error set and an error union without a payload have no invalid value" {
    const source = "const Failure = error{ Truncated, Malformed };\n" ++
        "const Merged = Failure || error{Rejected};\n" ++
        "const Holder = struct {\n    count: u32,\n\n" ++
        "    pub const Error = Failure || error{Full};\n};\n" ++
        "const Bodied = struct {\n    pub const Error = Failure || error{Full};\n};\n\n" ++
        "fn nested(err: Holder.Error) void {\n    work(err);\n}\n\n" ++
        "fn bodied(held: Bodied) void {\n    work(held);\n}\n\n" ++
        "fn named(err: Failure) u32 {\n    return switch (err) {\n" ++
        "        error.Truncated => 0,\n        error.Malformed => 1,\n    };\n}\n\n" ++
        "fn merged(err: Merged) void {\n    work(err);\n}\n\n" ++
        "fn any(err: anyerror) void {\n    work(err);\n}\n\n" ++
        "fn outcome(result: Failure!void) void {\n    work(result);\n}\n\n" ++
        "fn counted(result: Failure!u32) void {\n    work(result);\n}\n";

    try expect_mentions(source, &.{"assert result at"});
}

test "an error merge counts only outside brackets" {
    try std.testing.expect(merges_error_sets("Failure || error{Full}"));
    try std.testing.expect(!merges_error_sets("struct {\n    pub const Error = A || B;\n}"));
    try std.testing.expect(!merges_error_sets("Failure | Other"));
    try std.testing.expect(!merges_error_sets("(A || B)"));
}

test "a nested enum reached through an alias resolves in its own scope" {
    const source = "const Index = struct {\n    pub const Encoding = enum { utf8, utf16 };\n" ++
        "    pub const Open = enum(u8) { utf8, _ };\n};\n\n" ++
        "const Encoding = Index.Encoding;\n\n" ++
        "fn measure(encoding: Encoding) void {\n    work(encoding);\n}\n\n" ++
        "fn qualified(encoding: Index.Encoding) void {\n    work(encoding);\n}\n\n" ++
        "fn widened(open: Index.Open) void {\n    work(open);\n}\n\n" ++
        "fn optional(encoding: ?Encoding) void {\n    work(encoding);\n}\n\n" ++
        "fn forced(encoding: ?Encoding) void {\n    work(encoding.?);\n}\n\n" ++
        "fn reached(encoding: ?Encoding) void {\n" ++
        "    const held = encoding orelse unreachable;\n\n    work(held);\n}\n\n" ++
        "fn widened_optional(open: ?Index.Open) void {\n    work(open);\n}\n\n" ++
        "fn pointed(held: ?*Encoding) void {\n    work(held);\n}\n";

    try expect_mentions(source, &.{
        "assert open at",
        "assert encoding at",
        "assert encoding at",
        "assert open at",
        "assert held at",
    });
}

test "an enum std.meta builds from fields or declarations has no invalid value" {
    const source = "const Fields = std.meta.FieldEnum(struct { a: u8, b: u8 });\n" ++
        "const Decls = std.meta.DeclEnum(struct {\n    pub const a = 1;\n});\n" ++
        "const Tagged = std.meta.Tag(union(enum) { a: u8 });\n\n" ++
        "fn fielded(field: Fields) void {\n    work(field);\n}\n\n" ++
        "fn declared(declaration: Decls) void {\n    work(declaration);\n}\n\n" ++
        "fn tagged(tag: Tagged) void {\n    work(tag);\n}\n";

    try expect_mentions(source, &.{"assert tag at"});
}

test "a type named through @This() closes as the container that declares it" {
    const source = "const Kind = enum {\n    a,\n    b,\n\n    const This = @This();\n\n" ++
        "    fn named(kind: This) void {\n        work(kind);\n    }\n\n" ++
        "    fn direct(kind: @This()) void {\n        work(kind);\n    }\n};\n\n" ++
        "const Pair = struct {\n    left: bool,\n    kind: Kind,\n\n" ++
        "    const This = @This();\n\n" ++
        "    fn paired(pair: This) void {\n        work(pair);\n    }\n};\n\n" ++
        "const Counted = struct {\n    count: u32,\n\n    const This = @This();\n\n" ++
        "    fn counted(held: This) void {\n        work(held);\n    }\n};\n\n" ++
        "fn Generic(comptime T: type) type {\n    return struct {\n        value: T,\n\n" ++
        "        const This = @This();\n\n" ++
        "        fn generic(held: This) void {\n            work(held);\n        }\n    };\n}\n";

    try expect_mentions(source, &.{ "assert held at", "assert held at" });
}

test "a file is the struct of its fields under its @This() name" {
    const closed = "flag: bool,\nmode: Mode,\n\nconst Flags = @This();\n" ++
        "const Mode = enum { off, on };\n\n" ++
        "fn flagged(flags: Flags) void {\n    work(flags);\n}\n";
    const open = "count: u32,\n\nconst Counter = @This();\n\n" ++
        "fn counted(counter: Counter) void {\n    work(counter);\n}\n";

    try testing.expect_quiet(assert_parameters, .zig, closed);
    try expect_mentions(open, &.{"assert counter at"});
}

test "a type no declaration closes is reported" {
    const source = "const Unknown = Elsewhere.Kind;\n\n" ++
        "fn named(kind: Unknown) void {\n    work(kind);\n}\n\n" ++
        "fn standard(mode: std.lang.Optimize) void {\n    work(mode);\n}\n\n" ++
        "fn looped(kind: Looped) void {\n    work(kind);\n}\n\n" ++
        "const Looped = Looped;\n";

    try expect_mentions(source, &.{ "assert kind at", "assert mode at", "assert kind at" });
}

test "the path splits into a first segment and the rest" {
    var path: Path = undefined;

    try std.testing.expect(path.joined("Index", "Encoding.Wide"));
    try std.testing.expectEqualStrings("Index", path.first());
    try std.testing.expectEqualStrings("Encoding.Wide", path.rest());

    var headless: Path = undefined;

    try std.testing.expect(headless.spliced("", "Mode"));
    try std.testing.expectEqualStrings("Mode", headless.first());
    try std.testing.expect(!headless.spliced("", ""));

    var single: Path = undefined;

    try std.testing.expect(single.joined("Kind", ""));
    try std.testing.expectEqualStrings("Kind", single.first());
    try std.testing.expectEqualStrings("", single.rest());

    const long: [path_bytes_max]u8 = @splat('a');

    try std.testing.expect(!single.joined(&long, "b"));
    try std.testing.expectEqualStrings("Kind", single.first());
}

test "an import names its file and the path after it" {
    const spelled = "@import(\"x.zig\").Kind.Wide";

    try std.testing.expectEqualStrings("x.zig", import_specifier(spelled).?);
    try std.testing.expectEqualStrings("Kind.Wide", import_suffix(spelled));
    try std.testing.expectEqualStrings("", import_suffix("@import(\"x.zig\")"));
    try std.testing.expect(import_specifier("@import(\"\")") == null);
    try std.testing.expect(import_specifier("Kind") == null);
    try std.testing.expectEqual(@as(?usize, 7), error_union_bang("Failure!void"));
    try std.testing.expect(error_union_bang("!void") == null);
}

test "a type declared in an imported file closes through the import" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{ .iterate = false });
    defer temporary.cleanup();

    try temporary.dir.writeFile(io, .{ .sub_path = "deep.zig", .data = imported_deep });
    try temporary.dir.writeFile(io, .{ .sub_path = "kinds.zig", .data = imported_kinds });
    try temporary.dir.writeFile(io, .{ .sub_path = "main.zig", .data = imported_main });

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
    var findings = try testing.analyze_imported(assert_parameters, imported_main, &imported);
    defer findings.deinit();

    if (findings.count() != 3) findings.print();

    try std.testing.expectEqual(@as(u32, 3), findings.count());
    try std.testing.expect(std.mem.find(u8, findings.message(0), "assert value at") != null);
    try std.testing.expect(std.mem.find(u8, findings.message(1), "assert held at") != null);
    try std.testing.expect(std.mem.find(u8, findings.message(2), "assert mode at") != null);
    try std.testing.expect(imports.consulted);
}

test "a type an import would close is reported without an import reader" {
    try expect_mentions(imported_main, &.{
        "assert mode at",
        "assert kind at",
        "assert err at",
        "assert encoding at",
        "assert value at",
        "assert held at",
        "assert outcome at",
        "assert deep at",
        "assert mode at",
    });
}

test "an alias across an import to a function or opaque pointer type is exempt" {
    const files = [_]Source{.{ .data = imported_interface, .name = "interface.zig" }};
    var findings = try imported_findings(&files, imported_listening);
    defer findings.deinit();

    if (findings.count() != 0) findings.print();

    try std.testing.expectEqual(@as(u32, 0), findings.count());
    try expect_mentions(imported_listening, &.{
        "assert listener at",
        "assert handle at",
        "assert listener at",
    });
}

test "an optional data pointer or slice alias across an import is reported" {
    const files = [_]Source{.{ .data = imported_interface, .name = "interface.zig" }};
    var findings = try imported_findings(&files, imported_reading);
    defer findings.deinit();

    if (findings.count() != 2) findings.print();

    try std.testing.expectEqual(@as(u32, 2), findings.count());
    try std.testing.expect(std.mem.find(u8, findings.message(0), "assert handle at") != null);
    try std.testing.expect(std.mem.find(u8, findings.message(1), "assert bytes at") != null);
}

test "a type nested in the struct a type function returns closes through the call" {
    const files = [_]Source{
        .{ .data = imported_menu, .name = "menu.zig" },
        .{ .data = imported_ui, .name = "ui.zig" },
    };

    var findings = try imported_findings(&files, imported_toggling);
    defer findings.deinit();

    if (findings.count() != 0) findings.print();

    try std.testing.expectEqual(@as(u32, 0), findings.count());
    try expect_mentions(imported_toggling, &.{"assert options at"});
}

test "a type function result with an open field or more than one return is reported" {
    const files = [_]Source{
        .{ .data = imported_menu, .name = "menu.zig" },
        .{ .data = imported_ui, .name = "ui.zig" },
    };

    var findings = try imported_findings(&files, imported_sizing);
    defer findings.deinit();

    if (findings.count() != 3) findings.print();

    try std.testing.expectEqual(@as(u32, 3), findings.count());

    for (0..findings.count()) |index| {
        const message = findings.message(@intCast(index));

        try std.testing.expect(std.mem.find(u8, message, "assert options at") != null);
    }
}

test "a file imported whole closes when its fields do" {
    const files = [_]Source{
        .{ .data = imported_counter, .name = "counter.zig" },
        .{ .data = imported_flags, .name = "flags.zig" },
    };

    var findings = try imported_findings(&files, imported_holding);
    defer findings.deinit();

    if (findings.count() != 1) findings.print();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
    try std.testing.expect(std.mem.find(u8, findings.message(0), "assert counter at") != null);
    try expect_mentions(imported_holding, &.{ "assert flags at", "assert counter at" });
}
