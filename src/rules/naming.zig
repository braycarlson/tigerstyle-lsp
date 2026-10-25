const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const scan = @import("../scan.zig");
const stream = @import("../stream.zig");
const testing = @import("testing.zig");
const Context = @import("context.zig");
const Declaration = Declarations.Declaration;
const Declarations = @import("declarations.zig");
const Sink = scylla.rule.Sink;
const Span = scylla.Span;
const Token = scylla.Token;
const View = scylla.View;
const Views = Context.Views;

const Names = struct {
    attributes: Bindings,
    context: *const Context,
    declarations: Declarations,
    functions: Views,
    keys: Views,

    pub fn next(names: *Names) ?Declaration {
        assert(names.functions.remaining <= names.functions.positions.len);
        assert(names.keys.remaining <= names.keys.positions.len);

        if (names.declarations.next()) |declaration| return declaration;
        if (names.member_next()) |declaration| return declaration;
        return names.attribute_next();
    }

    pub fn count_max(names: *const Names) u32 {
        const front = names.context.front;
        const bindings = front.bindings().count();
        const count = bindings + front.node_count() * name_count_per_node_max + 1;

        assert(count > bindings);
        assert(count > front.node_count());

        return count;
    }

    fn member_next(names: *Names) ?Declaration {
        if (!names.context.conventions.members_unbound) return null;

        const declaration = names.function_next() orelse names.key_next() orelse return null;

        assert(declaration.token < names.context.tokens.len);
        assert(!declaration.parameter);

        return declaration;
    }

    fn function_next(names: *Names) ?Declaration {
        const context = names.context;

        for (0..names.functions.remaining) |_| {
            const node = names.functions.next() orelse return null;

            assert(node.category() == .function);

            const function = node.as_function() orelse continue;
            const named = function.name_token() orelse continue;

            if (!is_a_member(context, node)) continue;

            const offset = context.front_token(named).offset;
            const token = context.lexer_index_at(offset) orelse continue;

            assert(context.tokens[token].offset == offset);

            return .{
                .field = false,
                .kind = .function,
                .node = node,
                .parameter = false,
                .token = token,
            };
        }

        return null;
    }

    fn key_next(names: *Names) ?Declaration {
        const context = names.context;

        for (0..names.keys.remaining) |_| {
            const node = names.keys.next() orelse return null;

            assert(node.category() == .expression);

            const token = literal_key_of(context, node) orelse continue;

            assert(token < context.tokens.len);

            return .{
                .field = true,
                .kind = .value,
                .node = node,
                .parameter = false,
                .token = token,
            };
        }

        return null;
    }

    fn attribute_next(names: *Names) ?Declaration {
        const context = names.context;
        if (!context.conventions.assignment_declares) return null;
        if (context.conventions.receiver_names.len == 0) return null;

        for (0..names.attributes.count()) |_| {
            const node = names.attributes.next() orelse return null;
            const token = attribute_of(context, node) orelse continue;
            if (attribute_declared_before(context, node, token)) continue;

            assert(token < context.tokens.len);
            assert(context.tokens[token].kind == .identifier);

            return .{
                .field = true,
                .kind = .value,
                .node = node,
                .parameter = false,
                .token = token,
            };
        }

        return null;
    }
};

const Bindings = struct {
    assigned: Views,
    declared: Views,

    pub fn next(bindings: *Bindings) ?View {
        if (bindings.declared.next()) |node| {
            assert(node.category() == .declaration);

            return node;
        }

        const node = bindings.assigned.next() orelse return null;

        assert(node.category() == .assignment);
        assert(bindings.declared.remaining == 0);

        return node;
    }

    pub fn count(bindings: *const Bindings) u32 {
        const total = bindings.assigned.positions.len + bindings.declared.positions.len;

        assert(total >= bindings.assigned.positions.len);
        assert(total >= bindings.declared.positions.len);

        return @intCast(total);
    }
};

pub const Lowered = struct {
    bytes: [word_bytes_max]u8,
    length: u32,

    pub fn of(part: []const u8) Lowered {
        const length: u32 = @intCast(@min(part.len, word_bytes_max));

        var lowered: Lowered = .{ .bytes = @splat(0), .length = length };

        for (part[0..length], 0..) |byte, index| {
            lowered.bytes[index] = std.ascii.toLower(byte);
        }

        assert(lowered.length <= word_bytes_max);
        assert(lowered.length <= part.len);

        return lowered;
    }

    pub fn text(lowered: *const Lowered) []const u8 {
        assert(lowered.length <= word_bytes_max);

        return lowered.bytes[0..lowered.length];
    }
};

pub const Rendered = struct {
    bytes: [rendered_bytes_max]u8,
    length: u32,

    pub const empty: Rendered = .{ .bytes = @splat(0), .length = 0 };

    pub fn append(rendered: *Rendered, byte: u8) void {
        assert(rendered.length < rendered_bytes_max);

        rendered.bytes[rendered.length] = byte;
        rendered.length += 1;

        assert(rendered.length <= rendered_bytes_max);
    }

    pub fn slice(rendered: *const Rendered) []const u8 {
        assert(rendered.length <= rendered_bytes_max);

        return rendered.bytes[0..rendered.length];
    }
};

pub const name_bytes_max: u32 = 128;
pub const rendered_bytes_max: u32 = name_bytes_max * 2;
pub const word_bytes_max: u32 = 16;

const acronyms = [_][]const u8{
    "abi",
    "ack",
    "aes",
    "api",
    "ascii",
    "cli",
    "cpu",
    "crc",
    "css",
    "csv",
    "db",
    "dns",
    "eof",
    "fd",
    "ffi",
    "gc",
    "gpu",
    "html",
    "http",
    "https",
    "id",
    "io",
    "ip",
    "ipc",
    "jit",
    "json",
    "jwt",
    "lru",
    "lsm",
    "mac",
    "md5",
    "nak",
    "os",
    "pid",
    "ram",
    "rpc",
    "rsa",
    "sdk",
    "sha",
    "sql",
    "ssh",
    "ssl",
    "tcp",
    "tls",
    "toml",
    "ttl",
    "udp",
    "ui",
    "uri",
    "url",
    "utf",
    "uuid",
    "vsr",
    "wal",
    "xml",
    "yaml",
};

const decorator_count_max: u32 = 8;
const decorator_mark = "@";
const digits = "0123456789";
const import_closer = "\")";
const import_extension = ".zig";
const import_opener = "@import(\"";
const name_count_per_node_max: u32 = 5;
const stub_only_decorator = "type_check_only";
const version_mark = 'v';

pub fn names_of(context: *const Context) Names {
    const names: Names = .{
        .attributes = bindings_of(context),
        .context = context,
        .declarations = Declarations.of(context),
        .functions = context.views(.function),
        .keys = context.views(.expression),
    };

    assert(names.functions.remaining == names.functions.positions.len);
    assert(names.keys.remaining == names.keys.positions.len);

    return names;
}

pub fn bindings_of(context: *const Context) Bindings {
    const bindings: Bindings = .{
        .assigned = context.views(.assignment),
        .declared = context.views(.declaration),
    };

    assert(bindings.assigned.remaining == bindings.assigned.positions.len);
    assert(bindings.declared.remaining == bindings.declared.positions.len);

    return bindings;
}

pub fn is_screaming(name: []const u8) bool {
    var letters: u32 = 0;

    for (name) |byte| {
        if (std.ascii.isLower(byte)) return false;

        if (std.ascii.isUpper(byte)) letters += 1;
    }

    assert(letters <= name.len);

    return letters > 0;
}

pub fn trimmed_underscores(name: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, name, "_");

    assert(trimmed.len <= name.len);

    if (trimmed.len > 0) assert(trimmed[0] != '_');

    return trimmed;
}

pub fn acronym_length(word: []const u8) ?u32 {
    const lowered: Lowered = .of(word);
    const whole = digits_through(lowered.text());

    assert(whole.len <= word_bytes_max);

    if (scan.word_in(&acronyms, whole)) return @intCast(whole.len);

    const last = std.mem.findLastNone(u8, whole, digits) orelse return null;
    const end: u32 = @intCast(last + 1);
    if (end == whole.len) return null;

    assert(end < whole.len);

    if (end > 1) {
        if (whole[end - 1] == version_mark) {
            if (scan.word_in(&acronyms, whole[0 .. end - 1])) return end - 1;
        }
    }

    if (!scan.word_in(&acronyms, whole[0..end])) return null;
    return end;
}

pub fn aliases_a_foreign_name(
    context: *const Context,
    declaration: *const Declaration,
    name: []const u8,
) bool {
    assert(declaration.token < context.tokens.len);

    if (declaration.parameter) return false;
    if (declaration.field) return false;

    const value = declared_value(context, declaration.token) orelse return false;
    const bare = trimmed_underscores(name);
    if (bare.len == 0) return false;
    if (imported_stem(value)) |stem| return names_either(stem, name, bare);

    var end: usize = value.len;

    for (0..value.len) |_| {
        if (end == 0) break;
        if (scan.is_identifier_part(value[end - 1])) break;

        end -= 1;
    }

    if (std.mem.findScalar(u8, value[end..], ':') != null) return false;

    assert(end <= value.len);

    const tail = value[0..end];
    const dot = std.mem.findScalarLast(u8, tail, '.') orelse return std.mem.eql(u8, tail, name);

    assert(dot < end);

    return names_either(tail[dot + 1 ..], name, bare);
}

fn names_either(spelled: []const u8, name: []const u8, bare: []const u8) bool {
    assert(bare.len <= name.len);

    if (std.mem.eql(u8, spelled, name)) return true;
    return std.mem.eql(u8, spelled, bare);
}

pub fn stub_dictates(context: *const Context, declaration: *const Declaration) bool {
    assert(declaration.token < context.tokens.len);

    if (context.front.flavor != .stub) return false;
    if (declaration.parameter) return !positional_only(context, declaration.token);
    return !checked_only(context, declaration.token);
}

fn positional_only(context: *const Context, token: u32) bool {
    assert(token < context.tokens.len);

    const tokens = context.tokens;
    const enclosing = context.pairs.enclosing_at(tokens[token].offset) orelse return false;
    const close = context.pairs.partner_of(enclosing.open) orelse return false;
    const depth = context.pairs.depth_of(enclosing.open) + 1;

    assert(close > token);

    for (tokens[token + 1 .. close], token + 1..) |held, index| {
        if (!held.is_punctuation(.slash)) continue;
        if (context.pairs.depth_of(@intCast(index)) != depth) continue;
        if (!tokens[index - 1].is_punctuation(.comma)) continue;
        if (tokens[index + 1].is_punctuation(.comma)) return true;
        if (tokens[index + 1].is_punctuation(.paren_close)) return true;
    }

    return false;
}

fn checked_only(context: *const Context, token: u32) bool {
    assert(token < context.tokens.len);

    var line = context.line_of(context.tokens[token].offset);

    for (0..decorator_count_max) |_| {
        if (line == 0) return false;

        line -= 1;

        const text = scan.trim_ascii(context.line_text(line));
        if (!std.mem.startsWith(u8, text, decorator_mark)) return false;
        if (std.mem.endsWith(u8, text, stub_only_decorator)) return true;
    }

    return false;
}

const declaration_test_count_max: u32 = 8;

const DeclarationTests = struct {
    count: u32,
    spans: [declaration_test_count_max]Span,

    const empty: DeclarationTests = .{ .count = 0, .spans = @splat(Span.empty_at(0)) };

    fn slice(tests: *const DeclarationTests) []const Span {
        assert(tests.count <= declaration_test_count_max);

        return tests.spans[0..tests.count];
    }
};

const Renamed = struct {
    binding: u32,
    declared: Span,
    tests: DeclarationTests,
};

pub fn rename_fixed(
    context: *const Context,
    sink: *Sink,
    token: Token,
    title: []const u8,
    rendered: []const u8,
) bool {
    assert(token.end() <= context.source.len);
    assert(rendered.len > 0);

    const binding = renamable_binding(context, token, rendered) orelse return false;
    const tests = declaration_tests_of(context, binding) orelse return false;
    const renamed: Renamed = .{ .binding = binding, .declared = token.span(), .tests = tests };
    const span_count_max = context.front.bindings().reference_count() + tests.count + 1;

    sink.fix_begin(title, .unsafe, token.offset);

    var cursor: u32 = 0;

    for (0..span_count_max) |_| {
        const name = rename_span_next(context, &renamed, cursor) orelse break;

        assert(name.offset >= cursor);

        sink.fix_edit(name, rendered);
        cursor = name.end();
    }

    assert(cursor >= token.end());

    return true;
}

fn rename_span_next(context: *const Context, renamed: *const Renamed, cursor: u32) ?Span {
    const bindings = context.front.bindings();

    assert(renamed.binding < bindings.count());
    assert(renamed.declared.length > 0);

    var found = span_earlier(null, renamed.declared, cursor);
    var references = bindings.references_of(renamed.binding);

    for (0..bindings.reference_count()) |_| {
        const reference = references.next() orelse break;

        found = span_earlier(found, reference.name, cursor);
    }

    for (renamed.tests.slice()) |span| found = span_earlier(found, span, cursor);

    if (found) |held| assert(held.offset >= cursor);

    return found;
}

fn span_earlier(found: ?Span, candidate: Span, cursor: u32) ?Span {
    if (candidate.offset < cursor) return found;

    const held = found orelse return candidate;
    if (held.offset <= candidate.offset) return found;

    assert(candidate.offset < held.offset);

    return candidate;
}

fn declaration_tests_of(context: *const Context, binding: u32) ?DeclarationTests {
    const bindings = context.front.bindings();
    const name = context.span_text(bindings.at(binding).name);
    const tokens = context.tokens;
    const words = context.conventions.declaration_test_words;

    assert(name.len > 0);

    if (words.len == 0) return .empty;
    if (bindings.at(binding).scope > 0) return .empty;

    var tests: DeclarationTests = .empty;

    for (context.token_index.identifiers()) |position| {
        if (position == 0) continue;

        const opener = tokens[position - 1];
        if (opener.kind != .keyword) continue;
        if (!std.mem.eql(u8, context.text(tokens[position]), name)) continue;
        if (!scan.word_listed(words, context.text(opener))) continue;
        if (tests.count == declaration_test_count_max) return null;

        tests.spans[tests.count] = tokens[position].span();
        tests.count += 1;
    }

    if (tests.count == 0) return tests;
    if (named_twice(context, binding)) return null;
    return tests;
}

fn named_twice(context: *const Context, binding: u32) bool {
    const bindings = context.front.bindings();
    const name = context.span_text(bindings.at(binding).name);

    assert(name.len > 0);

    for (0..bindings.count()) |position| {
        const index: u32 = @intCast(position);
        if (index == binding) continue;
        if (std.mem.eql(u8, context.span_text(bindings.at(index).name), name)) return true;
    }

    return false;
}

fn renamable_binding(context: *const Context, token: Token, rendered: []const u8) ?u32 {
    const bindings = context.front.bindings();

    var found: ?u32 = null;

    for (0..bindings.count()) |position| {
        const index: u32 = @intCast(position);
        const name = bindings.at(index).name;
        if (std.mem.eql(u8, context.span_text(name), rendered)) return null;

        if (name.offset == token.offset) found = index;
    }

    const index = found orelse return null;
    const binding = bindings.at(index);

    assert(index < bindings.count());
    assert(binding.name.offset == token.offset);

    switch (binding.class) {
        .constant, .function, .local, .parameter, .type => {},
        .field, .import, .method, .other, .variant => return null,
    }

    if (binding.scope > 0) {
        return switch (bindings.scope_at(binding.scope).class) {
            .block, .function => index,
            .module, .other, .type => null,
        };
    }

    if (!context.conventions.declarations_spell_visibility) return null;
    if (context.declares_publicly(index)) return null;
    return index;
}

fn imported_stem(value: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, value, import_opener)) return null;
    if (!std.mem.endsWith(u8, value, import_closer)) return null;
    if (value.len < import_opener.len + import_closer.len) return null;

    const path = value[import_opener.len .. value.len - import_closer.len];
    const file = scylla.path.file_name(path);

    assert(file.len <= path.len);
    assert(path.len + import_opener.len + import_closer.len == value.len);

    if (!std.mem.endsWith(u8, file, import_extension)) return null;
    return file[0 .. file.len - import_extension.len];
}

pub fn enclosing_loop(node: View) ?View {
    var ancestors = node.ancestors();

    for (0..ancestors.remaining + 1) |_| {
        const parent = ancestors.next() orelse return null;

        assert(parent.index() < node.index());

        if (parent.category() == .loop) return parent;
        if (parent.category() != .declaration) return null;
    }

    return null;
}

pub fn enclosing_body(node: View) ?View {
    var ancestors = node.ancestors();

    for (0..ancestors.remaining + 1) |_| {
        const parent = ancestors.next() orelse return null;

        assert(parent.index() < node.index());

        switch (parent.category()) {
            .function, .lambda => return parent,
            else => {},
        }
    }

    return null;
}

fn declared_value(context: *const Context, token: u32) ?[]const u8 {
    const tokens = context.tokens;
    const end = stream.statement_end(tokens, token);

    assert(token <= end);
    assert(end <= tokens.len);

    const offset: u32 = for (tokens[token..end], token..) |held, index| {
        if (assigns(held)) break @intCast(index);
    } else end;

    if (offset + 1 >= end) return null;

    if (end < tokens.len) {
        if (tokens[end].kind == .block_start) return null;
    }

    const first = tokens[offset + 1].span();
    const last = tokens[end - 1].span();

    assert(first.offset <= last.end());

    return context.source[first.offset..last.end()];
}

fn digits_through(word: []const u8) []const u8 {
    const first = std.mem.findAny(u8, word, digits) orelse return word;
    const end = std.mem.findNonePos(u8, word, first, digits) orelse word.len;

    assert(first < end);
    assert(end <= word.len);

    return word[0..end];
}

fn is_a_member(context: *const Context, node: View) bool {
    assert(node.category() == .function);

    const parent = node.parent() orelse return false;

    assert(parent.index() < node.index());

    return switch (parent.category()) {
        .expression => opens_a_literal(context, parent),
        .block => if (parent.parent()) |owner| owner.category() == .@"struct" else false,
        else => false,
    };
}

fn opens_a_literal(context: *const Context, node: View) bool {
    const text = node.text(context.source);

    assert(text.len <= context.source.len);

    if (text.len == 0) return false;
    return text[0] == '{';
}

fn literal_key_of(context: *const Context, node: View) ?u32 {
    const parent = node.parent() orelse return null;
    if (parent.category() != .expression) return null;
    if (!opens_a_literal(context, parent)) return null;
    if (is_a_pattern(context, parent)) return null;

    const named = node.name_token() orelse return null;
    const offset = context.front_token(named).offset;
    const token = context.lexer_index_at(offset) orelse return null;
    const tokens = context.tokens;

    if (offset != node.span().offset) return null;
    if (token + 1 >= tokens.len) return null;
    if (tokens[token].kind != .identifier) return null;
    if (!tokens[token + 1].is_punctuation(.colon)) return null;

    assert(token + 1 < tokens.len);
    assert(tokens[token].offset == offset);

    return token;
}

fn is_a_pattern(context: *const Context, literal: View) bool {
    assert(literal.category() == .expression);

    const owner = literal.parent() orelse return false;

    assert(owner.index() < literal.index());

    switch (owner.category()) {
        .parameter, .parameters => return true,
        .assignment, .declaration => {},
        else => return false,
    }

    for (context.tokens_in(owner.span())) |token| {
        if (assigns(token)) return literal.span().offset < token.offset;
    }

    return false;
}

fn assigns(token: Token) bool {
    if (token.is_punctuation(.assign)) return true;
    return token.is_punctuation(.assign_declare);
}

fn attribute_of(context: *const Context, node: View) ?u32 {
    if (node.name_token() != null) return null;

    const start = context.lexer_index_at(node.span().offset) orelse return null;
    const tokens = context.tokens;
    const end = stream.statement_end(tokens, start);
    const receiver = context.text(tokens[start]);

    assert(start <= end);

    if (start + 3 >= end) return null;
    if (!scan.word_listed(context.conventions.receiver_names, receiver)) return null;
    if (!tokens[start + 1].is_punctuation(.dot)) return null;
    if (tokens[start + 2].kind != .identifier) return null;
    if (!assigns_an_attribute(tokens[start + 3])) return null;

    assert(start + 2 < end);

    return start + 2;
}

fn assigns_an_attribute(token: Token) bool {
    if (token.is_punctuation(.assign)) return true;
    return token.is_punctuation(.colon);
}

fn attribute_declared_before(context: *const Context, node: View, token: u32) bool {
    assert(token < context.tokens.len);
    assert(context.tokens[token].kind == .identifier);

    const name = context.text(context.tokens[token]);
    const before = node.span().offset;

    var bindings = bindings_of(context);

    for (0..bindings.count()) |_| {
        const held = bindings.next() orelse return false;
        if (held.span().offset >= before) continue;
        if (attribute_named(context, held, name)) return true;
    }

    return false;
}

fn attribute_named(context: *const Context, node: View, name: []const u8) bool {
    assert(name.len > 0);

    const tokens = context.tokens;
    const start = context.lexer_index_at(node.span().offset) orelse return false;
    if (start + 3 >= tokens.len) return false;
    if (!std.mem.eql(u8, context.text(tokens[start + 2]), name)) return false;

    const earlier = attribute_of(context, node) orelse return false;

    assert(earlier == start + 2);

    return true;
}

const named_count_max: u32 = 16;

const Named = struct {
    count: u32,
    texts: [named_count_max][]const u8,
};

fn named_collect(named: *Named, context: *const Context) !void {
    var names = names_of(context);

    for (0..names.count_max()) |_| {
        const declaration = names.next() orelse return;

        try std.testing.expect(named.count < named_count_max);

        named.texts[named.count] = context.text(context.tokens[declaration.token]);
        named.count += 1;
    }
}

test "a computed class field yields its key once" {
    const source = "class Held {\n    readonly [maxCount] = 1;\n    readonly [minSize] = 2;\n}\n";

    var named: Named = .{ .count = 0, .texts = undefined };
    var fixture: testing.Fixture = undefined;

    try fixture.init(.typescript, source);
    defer fixture.deinit();

    try named_collect(&named, &fixture.context);
    try std.testing.expectEqual(@as(u32, 3), named.count);
    try std.testing.expectEqualStrings("Held", named.texts[0]);
    try std.testing.expectEqualStrings("[", named.texts[1]);
    try std.testing.expectEqualStrings("[", named.texts[2]);
}
