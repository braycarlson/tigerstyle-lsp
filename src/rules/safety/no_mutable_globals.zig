const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const safety = @import("../safety.zig");
const scan = @import("../../scan.zig");
const stream = @import("../../stream.zig");
const support = @import("../support.zig");
const testing = @import("../testing.zig");
const Category = scylla.View.Category;
const Context = @import("../context.zig");
const Frame = @import("../frame.zig");
const Language = scylla.Language;
const Rule = scylla.rule.Rule;
const Sink = scylla.rule.Sink;
const Span = scylla.Span;
const Token = scylla.Token;
const View = scylla.View;

pub const rule: Rule = .{
    .citations = &.{
        .{
            .standard = "TigerStyle",
            .text = "\"Declare variables at the smallest possible scope, and minimize the " ++
                "number of variables in scope, to reduce the probability that variables are " ++
                "misused.\"",
        },
        .{
            .standard = "NASA",
            .text = "NASA P10 Rule 6: \"Data objects must be declared at the smallest possible " ++
                "level of scope.\"",
        },
    },
    .code = "TS005",
    .default_on = true,
    .description = "Global state is immutable, so no two parts of the program race to own it.",
    .explanation = "",
    .fix_title = "",
    .fixable = .sometimes,
    .group = .stable,
    .name = "no-mutable-globals",
    .severity = .@"error",
    .summary = "Module-level state must not be mutable",
    .url = "",
};

const GroupNames = struct {
    close: u32,
    context: *const Context,
    inner: u32,
    offset: u32,
    open: u32,

    fn next(names: *GroupNames) ?u32 {
        const tokens = names.context.tokens;

        assert(names.open < names.offset);
        assert(names.offset <= names.close + 1);

        if (names.offset >= names.close) return null;

        for (tokens[names.offset..names.close], names.offset..) |token, position| {
            const offset: u32 = @intCast(position);

            if (token.kind != .identifier) continue;
            if (names.context.pairs.depth_of(offset) != names.inner) continue;

            if (offset > names.open + 1) {
                if (Token.is_significant(tokens[offset - 1].kind)) continue;
            }

            names.offset = offset + 1;

            return offset;
        }

        names.offset = names.close;

        return null;
    }
};

const Segments = struct {
    offset: u32,
    text: []const u8,

    fn next(segments: *Segments) ?[]const u8 {
        const text = segments.text;

        assert(segments.offset <= text.len);

        const start = for (text[segments.offset..], segments.offset..) |byte, offset| {
            if (scan.is_identifier_part(byte)) break offset;
        } else {
            segments.offset = @intCast(text.len);

            return null;
        };

        const end = for (text[start..], start..) |byte, offset| {
            if (!scan.is_identifier_part(byte)) break offset;
        } else text.len;

        assert(start < end);

        segments.offset = @intCast(end);

        return text[start..end];
    }
};

const assign_ending_operators = [_][]const u8{ "!==", "&&=", "===", "??=", "||=" };
const freeze_path = [_][]const u8{ "Object", ".", "freeze" };
const global_word = "global";
const immutable_annotations = [_][]const u8{ "Final", "TypeAlias" };
const immutable_constructors = [_][]const u8{ "frozenset", "namedtuple", "tuple" };
const interior_mutable_names = [_][]const u8{ "Cell", "Mutex", "RefCell", "RwLock", "UnsafeCell" };
const literal_words = [_][]const u8{ "False", "None", "True" };

const mutable_constructors = [_][]const u8{
    "Counter",
    "OrderedDict",
    "bytearray",
    "defaultdict",
    "deque",
    "dict",
    "list",
    "set",
};

const mutable_message = "the global is mutable";

const python_type_names = [_][]const u8{
    "bool",
    "bytearray",
    "bytes",
    "complex",
    "dict",
    "float",
    "frozenset",
    "int",
    "list",
    "object",
    "set",
    "str",
    "tuple",
    "type",
};

const state_message = "the module binds mutable state as {s}; make it a constant or confine it " ++
    "to a function";

const static_keyword = "static";

const type_constructors = [_][]const u8{
    "NamedTuple",
    "NewType",
    "ParamSpec",
    "TypeAliasType",
    "TypeVar",
    "TypeVarTuple",
    "TypedDict",
};

const type_forms = [_][]const u8{
    "Annotated",
    "Callable",
    "ClassVar",
    "Dict",
    "Final",
    "FrozenSet",
    "Iterable",
    "List",
    "Literal",
    "Mapping",
    "Optional",
    "Sequence",
    "Set",
    "Tuple",
    "Type",
    "Union",
};

pub fn run(context: *const Context, sink: *Sink) void {
    if (context.conventions.assignment_declares) {
        module_bindings(context, sink);
        module_rebindings(context, sink);

        return;
    }

    assert(context.tokens.len <= std.math.maxInt(u32));

    for (0..context.tokens.len) |position| {
        const index: u32 = @intCast(position);
        const interior = interior_mutable_static(context, index);
        const bound = binds_a_mutable_object(context, index);
        const flagged = interior or bound;

        if (!flagged) {
            if (!declares_a_global(context, index)) continue;
        }

        if (!top_level(context, index)) continue;

        const head_index = declaration_head(context, index);
        const head = context.tokens[head_index].span();

        assert(head_index <= index);

        if (flagged) {
            sink.report(head, mutable_message);

            continue;
        }

        global_report(context, sink, index, head);
    }
}

fn global_report(context: *const Context, sink: *Sink, index: u32, head: Span) void {
    assert(index < context.tokens.len);
    assert(head.offset <= context.tokens[index].offset);

    const next = index + 1;

    if (next < context.tokens.len) {
        if (context.tokens[next].is_punctuation(.paren_open)) {
            group_report(context, sink, index);

            return;
        }
    }

    const end = declaration_end(context, next);
    const name = name_after(context, index, end) orelse return;
    if (support.names_the_discard(context, name)) return;

    sink.report(head, mutable_message);
}

fn binds_a_mutable_object(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);

    if (!context.conventions.constants_bind_objects) return false;
    if (!context.tokens[index].is_keyword(.constant)) return false;

    const end = declaration_end(context, index + 1);
    const assign = assign_within(context, index + 1, end) orelse return false;
    const value = context.tokens[assign + 1 .. end];

    assert(assign < end);

    if (value.len == 0) return false;

    const first = value[0];
    if (first.is_punctuation(.bracket_open)) return true;
    if (first.kind == .block_start) return true;
    if (freezes(context, value)) return false;
    if (allocates_at(context, value)) return true;
    if (!std.mem.eql(u8, context.text(first), "new")) return false;
    return allocates_at(context, value[1..]);
}

fn assign_within(context: *const Context, start: u32, end: u32) ?u32 {
    assert(start <= end);
    assert(end <= context.tokens.len);

    for (context.tokens[start..end], start..) |token, offset| {
        if (token.is_punctuation(.assign)) return @intCast(offset);
        if (ends_in_an_assign(context, token)) return @intCast(offset);
    }

    return null;
}

fn ends_in_an_assign(context: *const Context, token: Token) bool {
    assert(token.end() <= context.source.len);

    if (token.kind != .punctuation) return false;

    const ends = scan.word_in(&assign_ending_operators, context.text(token));

    if (ends) assert(token.length == 3);

    return ends;
}

fn allocates_at(context: *const Context, value: []const Token) bool {
    if (value.len < 2) return false;

    const first = value[0];

    assert(value.len >= 2);
    assert(first.end() <= context.source.len);

    if (first.kind != .identifier) return false;

    const name = context.text(first);
    if (!scan.word_listed(context.conventions.allocation_functions, name)) return false;
    return value[1].is_punctuation(.paren_open);
}

fn freezes(context: *const Context, value: []const Token) bool {
    if (value.len < freeze_path.len) return false;

    assert(value.len >= freeze_path.len);
    assert(value[0].end() <= context.source.len);

    for (freeze_path, value[0..freeze_path.len]) |expected, token| {
        if (!std.mem.eql(u8, context.text(token), expected)) return false;
    }

    return true;
}

fn declaration_end(context: *const Context, start: u32) u32 {
    assert(start <= context.tokens.len);

    var depth: u32 = 0;

    const end: u32 = end: for (context.tokens[start..], start..) |token, offset| {
        if (depth == 0) {
            if (token.kind == .newline) break :end @intCast(offset);
            if (token.is_punctuation(.semicolon)) break :end @intCast(offset);
        }

        if (token.closes_a_group_or_block()) {
            if (depth == 0) break :end @intCast(offset);

            depth -= 1;
        }

        if (token.opens_a_group_or_block()) depth += 1;
    } else @intCast(context.tokens.len);

    assert(end >= start);
    assert(end <= context.tokens.len);

    return end;
}

fn declaration_head(context: *const Context, index: u32) u32 {
    assert(index < context.tokens.len);

    const first = stream.line_start_of_token(context.tokens, context.source, index);

    assert(first <= index);

    for (context.tokens[first..index]) |token| {
        if (!token.is_keyword(.other)) return index;
    }

    return first;
}

fn declares_a_global(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);

    const token = context.tokens[index];
    if (!token.is_keyword(.mutable)) return false;

    const text = context.text(token);

    assert(text.len > 0);

    if (std.mem.eql(u8, text, "let")) return true;
    if (std.mem.eql(u8, text, "var")) return true;
    if (index == 0) return false;

    const before = context.tokens[index - 1];
    if (!before.is_keyword(.constant)) return false;
    return !std.mem.eql(u8, context.text(before), static_keyword);
}

fn interior_mutable_static(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);

    const token = context.tokens[index];
    if (!token.is_keyword(.constant)) return false;
    if (!std.mem.eql(u8, context.text(token), static_keyword)) return false;

    const next = index + 1;

    if (next < context.tokens.len) {
        if (context.tokens[next].is_keyword(.mutable)) return true;
    }

    const annotation = annotation_after(context, index) orelse return false;

    assert(annotation.len <= context.source.len);

    if (interior_mutable(annotation)) return true;
    return local_type_is_interior_mutable(context, annotation);
}

fn local_type_is_interior_mutable(context: *const Context, annotation: []const u8) bool {
    assert(annotation.len <= context.source.len);

    var segments: Segments = .{ .offset = 0, .text = annotation };

    for (0..annotation.len + 1) |_| {
        const segment = segments.next() orelse return false;

        assert(segment.len > 0);

        const body = local_type_body(context, segment) orelse continue;
        if (interior_mutable(body)) return true;
    }

    return false;
}

fn local_type_body(context: *const Context, name: []const u8) ?[]const u8 {
    assert(name.len > 0);

    const named = struct_named(context, name) orelse return null;
    const end = declaration_end(context, named + 1);

    assert(end > named);

    const start = context.tokens[named].offset;
    const last = context.tokens[end - 1];

    assert(last.end() >= start);

    return context.source[start..last.end()];
}

fn struct_named(context: *const Context, name: []const u8) ?u32 {
    assert(name.len > 0);

    for (context.tokens, 0..) |token, position| {
        if (position == 0) continue;
        if (token.kind != .identifier) continue;
        if (!context.tokens[position - 1].is_keyword(.@"struct")) continue;
        if (!std.mem.eql(u8, context.text(token), name)) continue;

        assert(token.length == name.len);

        return @intCast(position);
    }

    return null;
}

fn annotation_after(context: *const Context, index: u32) ?[]const u8 {
    assert(index < context.tokens.len);

    const end = declaration_end(context, index + 1);

    var start: ?u32 = null;

    for (context.tokens[index + 1 .. end], index + 1..) |token, position| {
        const offset: u32 = @intCast(position);

        if (start == null) {
            if (token.is_punctuation(.colon)) start = offset + 1;
        }

        const first = start orelse continue;

        if (!token.is_punctuation(.assign)) continue;
        if (offset <= first) continue;

        assert(first <= offset - 1);

        return stream.text_of_range(context.source, context.tokens, first, offset - 1);
    }

    return null;
}

fn interior_mutable(annotation: []const u8) bool {
    var segments: Segments = .{ .offset = 0, .text = annotation };

    assert(annotation.len <= std.math.maxInt(u32));

    for (0..annotation.len + 1) |_| {
        const segment = segments.next() orelse return false;

        assert(segment.len > 0);

        if (std.mem.startsWith(u8, segment, "Atomic")) return true;
        if (scan.word_in(&interior_mutable_names, segment)) return true;
    }

    return false;
}

fn name_after(context: *const Context, index: u32, end: u32) ?[]const u8 {
    assert(index < end);
    assert(end <= context.tokens.len);

    for (context.tokens[index + 1 .. end]) |token| {
        if (token.kind == .identifier) return context.text(token);
    }

    return null;
}

fn group_names(context: *const Context, open: u32, close: u32) GroupNames {
    assert(open < close);
    assert(context.tokens[open].is_punctuation(.paren_open));

    const inner = context.pairs.depth_of(open) + 1;

    return .{
        .close = close,
        .context = context,
        .inner = inner,
        .offset = open + 1,
        .open = open,
    };
}

fn group_report(context: *const Context, sink: *Sink, keyword: u32) void {
    const open = keyword + 1;
    const close = context.pairs.partner_of(open) orelse @as(u32, @intCast(context.tokens.len));

    assert(context.tokens[open].is_punctuation(.paren_open));
    assert(close > open);

    var counted = group_names(context, open, close);
    var count: u32 = 0;

    for (open..close) |_| {
        _ = counted.next() orelse break;

        count += 1;
    }

    const head = context.tokens[declaration_head(context, keyword)].span();

    var names = group_names(context, open, close);

    for (0..count) |_| {
        const index = names.next().?;
        const token = context.tokens[index];
        if (support.names_the_discard(context, context.text(token))) continue;

        const span = if (count == 1) head else token.span();

        sink.report(span, mutable_message);
    }
}

fn module_rebindings(context: *const Context, sink: *Sink) void {
    assert(context.conventions.assignment_declares);

    for (context.tokens, 0..) |token, position| {
        const index: u32 = @intCast(position);

        if (token.kind != .identifier) continue;
        if (!safety.follows_a_statement_break(context, index)) continue;
        if (index + 1 >= context.tokens.len) continue;
        if (!safety.compounds_an_assignment(context, context.tokens[index + 1])) continue;
        if (!module_scope(context, token.offset)) continue;

        const end = stream.statement_end(context.tokens, index + 2);
        const value = context.tokens[index + 2 .. end];

        assert(end >= index + 2);

        if (immutable_body(context, value)) continue;

        const name = context.text(token);

        if (!mutable_body(context, value)) {
            if (std.mem.startsWith(u8, name, "_")) continue;
            if (is_constant_name(name)) continue;
        }

        sink.report_formatted(token.span(), state_message, .{scan.utf8_or(name, "the call")});
    }
}

fn module_scope(context: *const Context, offset: u32) bool {
    assert(offset <= context.source.len);

    if (context.inside(.function, offset)) return false;
    if (context.inside(.@"struct", offset)) return false;

    var handlers = context.views(.except);

    for (0..handlers.remaining) |_| {
        const handler = handlers.next() orelse break;
        const span = handler.span();

        assert(handler.category() == .except);

        if (!span.contains(offset)) continue;
        if (recovers_an_import(context, span)) return false;
    }

    return true;
}

fn module_bindings(context: *const Context, sink: *Sink) void {
    var declarations = context.views(.declaration);

    assert(context.conventions.assignment_declares);

    for (0..declarations.remaining) |_| {
        const node = declarations.next() orelse break;

        assert(node.category() == .declaration);

        if (!module_level(context, node)) continue;

        const declaration = node.as_declaration() orelse continue;

        var names = declaration.names();

        const position = names.next() orelse continue;
        const name = context.front_text(position);
        if (name.len == 0) continue;
        if (!binds_a_bare_name(context, node)) continue;

        if (context.conventions.declarations_spell_constancy) {
            if (declaration.is_constant()) continue;
        } else {
            if (!python_module_state(context, node, name)) continue;
        }

        sink.report_formatted(node.span(), state_message, .{scan.utf8_or(name, "the call")});
    }
}

fn python_module_state(context: *const Context, node: View, name: []const u8) bool {
    assert(name.len > 0);

    const declaration = node.as_declaration().?;
    const value: ?Span = if (declaration.value()) |held| held.span() else null;

    if (value) |span| {
        assert(span.end() <= context.source.len);

        if (mutable_body(context, context.tokens_in(span))) return true;
    }

    if (bound_by_a_type(context, node)) return false;

    if (value) |span| {
        if (immutable_body(context, context.tokens_in(span))) return false;
    }

    if (rebound_by_a_global(context, name)) return true;
    if (rebound_at_module_level(context, name)) return true;
    return mutated_inside_a_function(context, name);
}

fn mutated_inside_a_function(context: *const Context, name: []const u8) bool {
    assert(name.len > 0);

    const tokens = context.tokens;

    for (tokens, 0..) |token, index| {
        if (token.kind != .identifier) continue;
        if (!std.mem.eql(u8, context.text(token), name)) continue;
        if (index + 3 >= tokens.len) continue;
        if (!tokens[index + 1].is_punctuation(.dot)) continue;

        const method = tokens[index + 2];
        if (method.kind != .identifier) continue;

        if (!scan.word_listed(context.conventions.mutation_methods, context.text(method))) {
            continue;
        }

        if (!tokens[index + 3].is_punctuation(.paren_open)) continue;

        assert(method.offset > token.offset);

        if (context.inside(.function, token.offset)) return true;
    }

    return false;
}

fn rebound_at_module_level(context: *const Context, name: []const u8) bool {
    assert(name.len > 0);

    var bindings: u32 = 0;

    for (context.tokens, 0..) |token, position| {
        const index: u32 = @intCast(position);

        if (token.kind != .identifier) continue;
        if (!std.mem.eql(u8, context.text(token), name)) continue;
        if (!safety.follows_a_statement_break(context, index)) continue;
        if (!module_scope(context, token.offset)) continue;
        if (context.inside(.branch, token.offset)) continue;
        if (context.inside(.@"try", token.offset)) continue;
        if (context.inside(.except, token.offset)) continue;
        if (index + 1 >= context.tokens.len) continue;

        if (assigns(context, context.tokens[index + 1])) bindings += 1;
    }

    assert(bindings <= context.tokens.len);

    return bindings >= 2;
}

fn assigns(context: *const Context, token: Token) bool {
    assert(token.end() <= context.source.len);

    if (token.is_punctuation(.assign)) return true;
    if (token.is_punctuation(.colon)) return true;

    const compound = safety.compounds_an_assignment(context, token);

    if (compound) assert(token.length > 1);

    return compound;
}

fn rebound_by_a_global(context: *const Context, name: []const u8) bool {
    assert(name.len > 0);

    for (context.tokens, 0..) |token, index| {
        if (!token.is_keyword(.global)) continue;
        if (!std.mem.eql(u8, context.text(token), global_word)) continue;

        assert(token.length == global_word.len);

        for (context.tokens[index + 1 ..]) |held| {
            if (held.kind == .newline) break;
            if (held.kind != .identifier) continue;
            if (std.mem.eql(u8, context.text(held), name)) return true;
        }
    }

    return false;
}

fn module_level(context: *const Context, node: View) bool {
    var ancestors = node.ancestors();

    assert(node.category() == .declaration);

    for (0..ancestors.remaining + 1) |_| {
        const parent = ancestors.next() orelse return true;

        assert(parent.index() != node.index());

        switch (parent.category()) {
            .function, .lambda, .@"struct" => return false,
            .except => if (recovers_an_import(context, parent.span())) return false,
            else => {},
        }
    }

    return true;
}

fn recovers_an_import(context: *const Context, span: Span) bool {
    assert(span.end() <= context.source.len);

    const text = context.span_text(span);

    assert(text.len == span.length);

    if (scan.find(text, "ImportError") != null) return true;
    return scan.find(text, "ModuleNotFoundError") != null;
}

fn bound_by_a_type(context: *const Context, node: View) bool {
    const declaration = node.as_declaration() orelse return false;
    const annotation_view = declaration.type_of() orelse return false;
    const annotation = context.span_text(annotation_view.span());
    const base = if (scan.find(annotation, "[")) |offset| annotation[0..offset] else annotation;

    assert(annotation.len == annotation_view.span().length);
    assert(base.len <= annotation.len);

    return scan.word_in(&immutable_annotations, segment_last(scan.trim_ascii(base)));
}

fn immutable_body(context: *const Context, body: []const Token) bool {
    if (body.len == 0) return false;

    assert(body.len > 0);
    assert(body[0].offset <= body[body.len - 1].offset);

    if (type_expression(context, body)) return true;

    if (head_before(context, body, .paren_open)) |callee| {
        const name = segment_last(callee);
        if (scan.word_in(&immutable_constructors, name)) return true;
        return scan.word_in(&type_constructors, name);
    }

    if (head_before(context, body, .bracket_open)) |base| {
        return scan.word_in(&type_forms, segment_last(base));
    }

    for (body) |token| {
        if (token.is_punctuation(.dot)) continue;
        if (token.kind != .identifier) return false;
        if (scan.word_in(&literal_words, context.text(token))) return false;
    }

    return true;
}

fn binds_a_bare_name(context: *const Context, node: View) bool {
    const body = context.tokens_in(node.span());
    const start = attribute_end(context, body);

    assert(start <= body.len);

    var depth: u32 = 0;
    var names: u32 = 0;

    for (body[start..], start..) |token, offset| {
        if (depth == 0) {
            if (separates_a_binding(token)) return names == 1 and offset == start + 1;
        }

        if (token.opens_a_group_or_block()) depth += 1;
        if (token.closes_a_group_or_block()) depth -|= 1;
        if (token.kind == .identifier) names += 1;
    }

    assert(names <= body.len);

    return false;
}

fn separates_a_binding(token: Token) bool {
    const punctuation = switch (token.kind) {
        .punctuation => |held| held,
        else => return false,
    };

    assert(token.kind == .punctuation);

    const separates = switch (punctuation) {
        .assign, .assign_declare, .colon => true,
        else => false,
    };

    if (separates) assert(!token.opens_a_group_or_block());

    return separates;
}

fn attribute_end(context: *const Context, body: []const Token) u32 {
    assert(body.len <= context.tokens.len);

    if (body.len < 2) return 0;
    if (!std.mem.eql(u8, context.text(body[0]), "@")) return 0;
    if (!body[1].is_punctuation(.paren_open)) return 0;

    var depth: u32 = 0;

    for (body[1..], 1..) |token, offset| {
        if (token.is_punctuation(.paren_open)) depth += 1;

        if (token.is_punctuation(.paren_close)) {
            depth -= 1;

            if (depth == 0) return @intCast(offset + 1);
        }
    }

    assert(depth > 0);

    return @intCast(body.len);
}

fn trimmed(body: []const Token) []const Token {
    var start: usize = 0;
    var end: usize = body.len;

    for (body) |token| {
        if (Token.is_significant(token.kind)) break;

        start += 1;
    }

    for (0..body.len) |_| {
        if (end <= start) break;
        if (Token.is_significant(body[end - 1].kind)) break;

        end -= 1;
    }

    assert(start <= end);
    assert(end <= body.len);

    return body[start..end];
}

fn unwrapped(body: []const Token) ?[]const Token {
    if (body.len < 2) return null;
    if (!body[0].is_punctuation(.paren_open)) return null;

    var depth: u32 = 0;

    const close = for (body, 0..) |token, offset| {
        if (token.is_punctuation(.paren_open)) depth += 1;

        if (token.is_punctuation(.paren_close)) {
            depth -= 1;

            if (depth == 0) break offset;
        }
    } else return null;

    assert(close > 0);
    assert(depth == 0);

    if (close + 1 != body.len) return null;
    return trimmed(body[1..close]);
}

fn type_expression(context: *const Context, body: []const Token) bool {
    const outer = trimmed(body);
    const wrapped = unwrapped(outer);
    const inner = wrapped orelse outer;

    assert(inner.len <= body.len);

    if (inner.len == 0) return false;

    var depth: u32 = 0;
    var operands: u32 = 0;
    var start: usize = 0;

    for (inner, 0..) |token, offset| {
        if (token.opens_a_group_or_block()) depth += 1;
        if (token.closes_a_group_or_block()) depth -|= 1;
        if (depth > 0) continue;
        if (!separates_a_type(context, token)) continue;
        if (!type_atom(context, trimmed(inner[start..offset]))) return false;

        operands += 1;
        start = offset + 1;
    }

    assert(start <= inner.len);

    const tail = trimmed(inner[start..]);

    if (tail.len == 0) {
        if (wrapped == null) return false;
        return operands > 0;
    }

    if (!type_atom(context, tail)) return false;
    return operands + 1 > 1;
}

fn separates_a_type(context: *const Context, token: Token) bool {
    assert(token.end() <= context.source.len);

    if (token.is_punctuation(.comma)) return true;
    if (!token.is_punctuation(.other)) return false;

    assert(token.kind == .punctuation);

    return std.mem.eql(u8, context.text(token), "|");
}

fn type_atom(context: *const Context, operand: []const Token) bool {
    if (operand.len == 0) return false;

    const first = operand[0];
    if (first.kind == .string) return operand.len == 1;
    if (first.kind != .identifier) return false;

    var length: usize = 1;
    var dotted = false;

    for (0..operand.len) |_| {
        if (length + 1 >= operand.len) break;
        if (!operand[length].is_punctuation(.dot)) break;
        if (operand[length + 1].kind != .identifier) break;

        dotted = true;
        length += 2;
    }

    assert(length >= 1);
    assert(length <= operand.len);

    const last = context.text(operand[length - 1]);

    if (length == operand.len) {
        if (dotted) return true;
        if (scan.word_in(&python_type_names, last)) return true;
        return scan.word_in(&literal_words, last);
    }

    if (!operand[length].is_punctuation(.bracket_open)) return false;
    if (!closes_the_operand(operand, length)) return false;
    if (scan.word_in(&type_forms, last)) return true;
    return scan.word_in(&python_type_names, last);
}

fn closes_the_operand(operand: []const Token, open: usize) bool {
    assert(open < operand.len);
    assert(operand[open].is_punctuation(.bracket_open));

    var depth: u32 = 0;

    for (operand[open..], open..) |token, offset| {
        if (token.is_punctuation(.bracket_open)) depth += 1;

        if (token.is_punctuation(.bracket_close)) {
            depth -= 1;

            if (depth == 0) return offset + 1 == operand.len;
        }
    }

    return false;
}

fn mutable_body(context: *const Context, body: []const Token) bool {
    if (body.len == 0) return false;

    const first = body[0];

    assert(first.end() <= context.source.len);

    if (first.is_punctuation(.bracket_open)) return true;
    if (first.kind == .block_start) return true;

    const callee = head_before(context, body, .paren_open) orelse return false;

    assert(callee.len > 0);

    return scan.word_in(&mutable_constructors, segment_last(callee));
}

fn is_constant_name(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!std.ascii.isUpper(name[0])) return false;

    for (name) |byte| {
        if (std.ascii.isUpper(byte)) continue;
        if (std.ascii.isDigit(byte)) continue;
        if (byte != '_') return false;
    }

    assert(name.len > 0);
    assert(std.ascii.isUpper(name[0]));

    return true;
}

fn head_before(
    context: *const Context,
    body: []const Token,
    opener: Token.Punctuation,
) ?[]const u8 {
    var length: usize = 0;

    for (body) |token| {
        if (token.is_punctuation(opener)) break;

        if (token.kind == .identifier) {
            length += 1;

            continue;
        }

        if (!token.is_punctuation(.dot)) return null;

        length += 1;
    }

    if (length == 0) return null;
    if (length >= body.len) return null;

    const start = body[0].offset;
    const end = body[length - 1].end();

    assert(start <= end);
    assert(end <= context.source.len);

    return context.source[start..end];
}

fn segment_last(name: []const u8) []const u8 {
    const dot = std.mem.findScalarLast(u8, name, '.') orelse return name;

    assert(dot < name.len);

    const last = name[dot + 1 ..];

    assert(std.mem.findScalar(u8, last, '.') == null);

    return last;
}

fn top_level(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);

    const innermost = innermost_strictly_within(context, index) orelse return true;
    if (frames_a_body(context, innermost)) return false;

    var ancestors = innermost.ancestors();

    for (0..ancestors.remaining + 1) |_| {
        const held = ancestors.next() orelse return true;

        assert(held.index() < innermost.index());

        if (frames_a_body(context, held)) return false;
    }

    return false;
}

fn frames_a_body(context: *const Context, view: View) bool {
    const category = view.category();
    const framed = std.mem.findScalar(Category, &Frame.categories, category) != null;
    if (!framed) return false;
    if (holds_members(view)) return false;
    return Frame.of(context, view) != null;
}

fn holds_members(view: View) bool {
    const category = view.category();
    if (category == .@"struct") return true;
    if (category != .block) return false;

    assert(category == .block);

    const parent = view.parent() orelse return false;

    assert(parent.index() != view.index());

    return parent.category() == .@"struct";
}

fn innermost_strictly_within(context: *const Context, token: u32) ?View {
    assert(token < context.tokens.len);

    var frames = Frame.covering(context, token);
    var found: ?View = null;

    for (0..context.front.node_count() + 1) |_| {
        const covering = frames.next() orelse break;
        const view = covering.view;

        if (token == covering.frame.start) continue;
        if (view.parent() == null) continue;

        if (found) |held| {
            if (view.span().offset < held.span().offset) continue;
        }

        found = view;
    }

    if (found) |view| assert(view.parent() != null);

    return found;
}

fn expect_count(language: Language, source: []const u8, expected: u32) !void {
    assert(source.len > 0);
    assert(expected <= testing.limits.diagnostic_count_max);

    var findings = try testing.analyze(@This(), language, source);
    defer findings.deinit();

    if (findings.count() != expected) findings.print();

    try std.testing.expectEqual(expected, findings.count());
}

test "a screaming go global is reported" {
    try expect_count(.go, "package main\n\nvar DEBUG bool\n", 1);
}

test "an underscored go global is reported" {
    try expect_count(.go, "package main\n\nvar _cache bool\n", 1);
}

test "a blank go global is a discard" {
    try testing.expect_quiet(@This(), .go, "package main\n\nvar _ Runner = (*Server)(nil)\n");
}

test "a module level let is reported" {
    try expect_count(.javascript, "let count = 0;\n", 1);
}

test "a constant bound to an object is reported" {
    const source = "const a = [];\nconst b = {};\nconst c = new Map();\nconst d = new " ++
        "Set([1]);\nconst e = Array.from(items);\n";

    try expect_count(.typescript, source, 4);
}

test "a frozen constant is quiet" {
    const source = "const a = Object.freeze([]);\nconst b = Object.freeze({ a: 1 });\nconst " ++
        "c = 1;\nconst d = run();\n";

    try testing.expect_quiet(@This(), .javascript, source);
}

test "an odin inferred declaration is reported" {
    const source = "package main\n\ncount := 0\n@(private) held: int = 0\nnames := " ++
        "map[string]int{}\nCOUNT :: 0\n";

    try expect_count(.odin, source, 3);
}

test "a python comprehension is a mutable literal" {
    try expect_count(.python, "SQUARES = [x * x for x in range(3)]\n", 1);
}

test "a python mutable literal reports whatever its name" {
    try expect_count(.python, "REGISTRY = []\n_cache = {}\nheld: Final = []\n", 3);
}

test "a python binding a function mutates is reported" {
    const source = "store = Store()\nother = Store()\n\n\ndef add():\n    store.add(1)\n    " ++
        "return other\n";

    var findings = try testing.analyze(@This(), .python, source);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
    try std.testing.expect(std.mem.find(u8, findings.message(0), "store") != null);
}

test "an array of atomics is interior mutable" {
    const source = "static HELD: [AtomicU32; 2] = [AtomicU32::new(0), AtomicU32::new(0)];\n";

    try expect_count(.rust, source, 1);
}

test "a local type with a cell field is interior mutable" {
    const source = "static HELD: Holder = Holder { value: Cell::new(0) };\n\nstruct Holder " ++
        "{\n    value: Cell<u32>,\n}\n\nstatic PLAIN: Plain = Plain { value: 0 " ++
        "};\n\nstruct Plain {\n    value: u32,\n}\n";

    try expect_count(.rust, source, 1);
}

test "an underscored go global holding a literal is reported" {
    try expect_count(.go, "package main\n\nvar _cache = []int{1, 2}\n", 1);
}

test "a go group reports every name past a call" {
    const source = "package main\n\nvar (\n\tfirst  = errors.New(\"one\")\n" ++
        "\tsecond = errors.New(\"two\")\n)\n";

    try expect_count(.go, source, 2);
}

test "an interior mutable static is reported" {
    try expect_count(.rust, "static MESSAGES: AtomicBool = AtomicBool::new(false);\n", 1);
}

test "a plain static is quiet" {
    try testing.expect_quiet(@This(), .rust, "static TEST_DIR: &'static str = \"tests\";\n");
}

test "a python union type alias is quiet" {
    const source = "HeaderValue = str | list[str] | tuple[str, ...]\n";

    try testing.expect_quiet(@This(), .python, source);
}

test "a python tuple of type names is quiet" {
    try testing.expect_quiet(@This(), .python, "basestring = (str, bytes)\nintegers = (int,)\n");
}

test "a python binding bound once is a constant" {
    try testing.expect_quiet(@This(), .python, "enabled = True\nmissing = None\n");
}

test "a python binding a function rebinds is reported" {
    const source = "enabled = True\n\n\ndef toggle():\n    global enabled\n    enabled = False\n";

    try expect_count(.python, source, 1);
}

test "a python subscript target is quiet" {
    try testing.expect_quiet(@This(), .python, "import sys\n\nlocals()[\"name\"] = 1\n");
}

test "a module level augmented assignment is reported" {
    try expect_count(.python, "counter = 0\ncounter += 1\n", 2);
}

test "an augmented assignment binding an attribute is quiet" {
    try expect_count(.python, "flags = 0\nflags |= tb.TransferFlags.LINKED\n", 1);
}

test "a mutable static is reported" {
    const source = "static mut COUNTER: u32 = 0;\n\nfn f() {\n    let mut value = 1;\n}\n";

    try expect_count(.rust, source, 1);
}

test "a top level var is reported" {
    const source = "var counter: u32 = 0;\n\nfn f() void {\n    var value: u32 = 1;\n}\n";

    try expect_count(.zig, source, 1);
}

test "a strict comparison after a const enum binds no object" {
    const source = "export const enum State {\n    Idle,\n}\n\nfunction run(state) {\n" ++
        "    if (state === State.Idle) {\n        return 1;\n    }\n\n    const held = [];\n\n" ++
        "    return held;\n}\n";

    try testing.expect_quiet(@This(), .typescript, source);
}
