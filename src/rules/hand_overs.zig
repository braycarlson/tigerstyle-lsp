const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const scan = @import("../scan.zig");
const stream = @import("../stream.zig");
const Context = @import("context.zig");
const Enclosures = @import("enclosures.zig");
const Span = scylla.Span;
const Token = scylla.Token;
const View = scylla.View;
const parameter_count_max = scylla.limits.parameter_count_max;

container_lengths: u64,
lengths: u64,
name_count: u32,
names: [hand_over_names_max]u32,
pair_count: u32,
pairs: [hand_over_pairs_max]Pair,
row_count: u32,
row_state: State,
rows: [hand_over_rows_max]NodeRow,
state: State,

const HandOvers = @This();

pub const Handing = struct {
    count: u32,
    owner: ?View,
};

const HandingOwners = struct {
    count: u32,
    first: u32,
    function: u32,

    const file_owner: u32 = std.math.maxInt(u32);

    fn add(owners: *HandingOwners, context: *const Context, offset: u32) void {
        assert(owners.count <= handing_owner_count_max);
        assert(offset <= context.source.len);

        if (owners.count == handing_owner_count_max) return;

        const owner = if (context.function_at(offset)) |held| held.index() else file_owner;
        if (owner == owners.function) return;

        if (owners.count > 0) {
            if (owner == owners.first) return;
        }

        if (owners.count == 0) owners.first = owner;

        owners.count += 1;
    }

    fn add_references(owners: *HandingOwners, context: *const Context, binding: u32) void {
        const bindings = context.front.bindings();

        assert(binding < bindings.count());

        var references = bindings.references_of(binding);

        for (0..bindings.reference_count()) |_| {
            const reference = references.next() orelse return;
            const name = reference.name;

            assert(name.end() <= context.source.len);

            if (!hands_over(context, name.offset, name.end())) continue;
            if (shadowed_by_a_parameter(context, name)) continue;

            owners.add(context, name.offset);
        }
    }

    fn add_qualified(
        owners: *HandingOwners,
        context: *const Context,
        container: Span,
        name: Span,
    ) void {
        const tokens = context.tokens;
        const held = context.span_text(container);
        const named = context.span_text(name);

        assert(held.len > 0);
        assert(named.len > 0);

        for (tokens, 0..) |token, position| {
            const index: u32 = @intCast(position);
            if (index + 2 >= tokens.len) return;
            if (token.kind != .identifier) continue;
            if (!separates_a_path(context, tokens[index + 1])) continue;
            if (!std.mem.eql(u8, context.text(tokens[index + 2]), named)) continue;
            if (!std.mem.eql(u8, context.text(token), held)) continue;
            if (!hands_over(context, token.offset, tokens[index + 2].end())) continue;

            owners.add(context, token.offset);
        }
    }
};

const ContainerReference = struct {
    first: u32,
    reference: u32,
};

const hand_over_names_max: u32 = 2_048;
const hand_over_pairs_max: u32 = 1_024;
const hand_over_rows_max: u32 = 2_048;
const handing_owner_count_max: u32 = 2;
const container_layout_words = [_][]const u8{ "extern", "packed" };
const container_paren_count_max: u32 = 4;
const prong_arrow = "=>";
const prong_nesting_max: u32 = 8;
const generic_scan_max: u32 = 256;
const path_lookbehind_max: u32 = 64;
const name_list_lookbehind_max: u32 = 1_024;
const default_word = "default";

const NodeRow = struct {
    node: u32,
    position: u32,

    fn earlier(_: void, left: NodeRow, right: NodeRow) bool {
        if (left.node != right.node) return left.node < right.node;
        return left.position < right.position;
    }

    fn order(node: u32, held: NodeRow) std.math.Order {
        return std.math.order(node, held.node);
    }
};

const Pair = struct {
    hash: u32,
    token: u32,

    fn earlier(_: void, left: Pair, right: Pair) bool {
        return left.hash < right.hash;
    }

    fn order(hash: u32, pair: Pair) std.math.Order {
        return std.math.order(hash, pair.hash);
    }
};

pub const State = enum {
    built,
    overflowed,
    unbuilt,
};

pub fn begin(hand_overs: *HandOvers) void {
    hand_overs.row_state = .unbuilt;
    hand_overs.state = .unbuilt;

    assert(hand_overs.row_state == hand_overs.state);
}

pub fn covers(hand_overs: *HandOvers, context: *const Context, function: View) bool {
    assert(function.span().end() <= context.source.len);
    assert(hand_overs.state == .unbuilt or hand_overs.pair_count <= hand_over_pairs_max);

    return handed_over_through(context, function, hand_overs);
}

fn build(hand_overs: *HandOvers, context: *const Context) void {
    assert(hand_overs.state == .unbuilt);

    hand_overs.container_lengths = 0;
    hand_overs.lengths = 0;
    hand_overs.name_count = 0;
    hand_overs.pair_count = 0;
    hand_overs.state = .overflowed;

    if (!hand_overs.names_collect(context)) return;
    if (!hand_overs.pairs_collect(context)) return;

    hand_overs.state = .built;

    assert(hand_overs.pair_count <= hand_over_pairs_max);
}

fn row_of(
    hand_overs: *HandOvers,
    context: *const Context,
    function: View,
) ?*const scylla.Calls.Function {
    if (hand_overs.row_state == .unbuilt) hand_overs.rows_collect(context);
    if (hand_overs.row_state != .built) return function_row_of(context, function);

    const node = function.index();
    const rows = hand_overs.rows[0..hand_overs.row_count];
    const first = std.sort.lowerBound(NodeRow, rows, node, NodeRow.order);

    assert(first <= rows.len);

    if (first == rows.len) return null;
    if (rows[first].node != node) return null;

    const row = &context.tables.functions()[rows[first].position];

    assert(row.node == node);

    return row;
}

fn rows_collect(hand_overs: *HandOvers, context: *const Context) void {
    const functions = context.tables.functions();

    assert(hand_overs.row_state == .unbuilt);

    hand_overs.row_count = 0;
    hand_overs.row_state = .overflowed;

    if (functions.len > hand_over_rows_max) return;

    for (functions, 0..) |row, position| {
        hand_overs.rows[hand_overs.row_count] = .{
            .node = row.node,
            .position = @intCast(position),
        };

        hand_overs.row_count += 1;
    }

    const rows = hand_overs.rows[0..hand_overs.row_count];

    std.sort.pdq(NodeRow, rows, {}, NodeRow.earlier);

    hand_overs.row_state = .built;

    assert(rows.len == functions.len);
}

fn names_collect(hand_overs: *HandOvers, context: *const Context) bool {
    assert(hand_overs.name_count == 0);

    for (context.tables.functions()) |*row| {
        if (row.container == null) continue;
        if (row.name.length == 0) continue;
        if (hand_overs.name_count == hand_over_names_max) return false;

        hand_overs.names[hand_overs.name_count] = name_hash(context.span_text(row.name));
        hand_overs.name_count += 1;
        hand_overs.lengths |= bit_of_length(row.name.length);
        hand_overs.container_lengths |= bit_of_length(row.container.?.length);
    }

    const names = hand_overs.names[0..hand_overs.name_count];

    std.sort.pdq(u32, names, {}, std.sort.asc(u32));

    assert(names.len <= hand_over_names_max);

    return true;
}

fn pairs_collect(hand_overs: *HandOvers, context: *const Context) bool {
    const tokens = context.tokens;

    assert(hand_overs.pair_count == 0);

    if (hand_overs.name_count == 0) return true;

    for (context.token_index.identifiers()) |index| {
        if (index + 2 >= tokens.len) break;

        assert(tokens[index].kind == .identifier);

        if (hand_overs.container_lengths & bit_of_length(tokens[index].length) == 0) continue;
        if (hand_overs.lengths & bit_of_length(tokens[index + 2].length) == 0) continue;
        if (opens_a_call_at(tokens, index + 3)) continue;
        if (!separates_a_path(context, tokens[index + 1])) continue;

        const hash = name_hash(context.text(tokens[index + 2]));
        if (!hand_overs.names_a_row(hash)) continue;
        if (!hands_over_from(context, index, tokens[index + 2].end())) continue;
        if (hand_overs.pair_count == hand_over_pairs_max) return false;

        hand_overs.pairs[hand_overs.pair_count] = .{ .hash = hash, .token = index };
        hand_overs.pair_count += 1;
    }

    const pairs = hand_overs.pairs[0..hand_overs.pair_count];

    std.sort.pdq(Pair, pairs, {}, Pair.earlier);

    assert(pairs.len <= hand_over_pairs_max);

    return true;
}

fn names_a_row(hand_overs: *const HandOvers, hash: u32) bool {
    const names = hand_overs.names[0..hand_overs.name_count];
    const first = std.sort.lowerBound(u32, names, hash, order_of_hash);

    assert(names.len <= hand_over_names_max);
    assert(first <= names.len);

    if (first == names.len) return false;
    return names[first] == hash;
}

fn qualified(
    hand_overs: *const HandOvers,
    context: *const Context,
    container: Span,
    name: Span,
) bool {
    const named = context.span_text(name);
    const held = context.span_text(container);
    const hash = name_hash(named);
    const pairs = hand_overs.pairs[0..hand_overs.pair_count];
    const first = std.sort.lowerBound(Pair, pairs, hash, Pair.order);

    assert(hand_overs.state == .built);
    assert(first <= pairs.len);

    for (pairs[first..]) |pair| {
        if (pair.hash != hash) return false;

        assert(pair.token + 2 < context.tokens.len);

        if (!std.mem.eql(u8, context.text(context.tokens[pair.token + 2]), named)) continue;
        if (std.mem.eql(u8, context.text(context.tokens[pair.token]), held)) return true;
    }

    return false;
}

pub fn handed_over(context: *const Context, function: View) bool {
    assert(function.span().end() <= context.source.len);

    return handed_over_through(context, function, null);
}

pub fn handing_of(context: *const Context, function: View) Handing {
    assert(function.as_function() != null);
    assert(function.index() < context.front.node_count());

    if (handed_over_in_place(context, function)) return .{ .count = 1, .owner = null };

    var owners: HandingOwners = .{ .count = 0, .first = 0, .function = function.index() };

    if (container_reference(context, function)) |named| {
        const token = context.tokens[named.reference];

        if (hands_over_after(context, named.reference, named.first, token.end())) {
            owners.add(context, token.offset);
        }
    }

    if (function_row_of(context, function)) |row| {
        if (row.binding) |binding| owners.add_references(context, binding);
        if (row.container) |container| owners.add_qualified(context, container, row.name);
    }

    assert(owners.count <= handing_owner_count_max);

    if (owners.count != 1) return .{ .count = owners.count, .owner = null };
    if (owners.first == HandingOwners.file_owner) return .{ .count = 1, .owner = null };
    return .{ .count = 1, .owner = context.view(owners.first) };
}

pub fn called_directly(context: *const Context, function: View) bool {
    assert(function.as_function() != null);

    const row = function_row_of(context, function) orelse return false;
    const binding = row.binding orelse return false;
    const bindings = context.front.bindings();

    assert(binding < bindings.count());

    var references = bindings.references_of(binding);

    for (0..bindings.reference_count()) |_| {
        const reference = references.next() orelse return false;
        const after = context.significant_from(reference.name.end()) orelse continue;
        if (context.tokens[after].is_punctuation(.paren_open)) return true;
    }

    return false;
}

fn handed_over_through(
    context: *const Context,
    function: View,
    hand_overs: ?*HandOvers,
) bool {
    const held = function.as_function() orelse return false;

    assert(function.span().end() <= context.source.len);
    assert(function.index() < context.front.node_count());

    if (!found_handed_over(context, function, hand_overs)) return false;
    return held.body() != null;
}

fn found_handed_over(context: *const Context, function: View, hand_overs: ?*HandOvers) bool {
    assert(function.as_function() != null);
    assert(function.index() < context.front.node_count());

    if (handed_over_in_place(context, function)) return true;
    if (handed_over_through_its_container(context, function)) return true;

    const row = row_through(context, function, hand_overs) orelse return false;

    assert(row.node == function.index());

    if (row.binding) |binding| {
        if (referenced_uncalled(context, binding)) return true;
    }

    const container = row.container orelse return false;

    if (hand_overs) |index| {
        if (index.state == .unbuilt) index.build(context);
        if (index.state == .built) return index.qualified(context, container, row.name);
    }

    return qualified_uncalled(context, container, row.name);
}

fn handed_over_through_its_container(context: *const Context, function: View) bool {
    const named = container_reference(context, function) orelse return false;
    const token = context.tokens[named.reference];

    assert(token.kind == .identifier);
    assert(token.offset > function.span().offset);

    return hands_over_after(context, named.reference, named.first, token.end());
}

fn container_reference(context: *const Context, function: View) ?ContainerReference {
    const tokens = context.tokens;
    const named = function.name_token() orelse return null;
    const name = context.front_text(named);
    const enclosing = context.pairs.enclosing_at(function.span().offset) orelse return null;

    assert(name.len > 0);
    assert(enclosing.open < tokens.len);

    if (tokens[enclosing.open].kind != .block_start) return null;

    const close = context.pairs.partner_of(enclosing.open) orelse return null;
    const wrapped = container_wrapped(context, enclosing.open, close);
    const end = if (wrapped) |range| range.end else close;
    const dot = context.significant_after(end) orelse return null;
    const reference = context.significant_after(dot) orelse return null;

    if (!tokens[dot].is_punctuation(.dot)) return null;
    if (tokens[reference].kind != .identifier) return null;
    if (!std.mem.eql(u8, context.text(tokens[reference]), name)) return null;

    assert(reference > close);

    const first = if (wrapped) |range| range.start else reference;
    return .{ .first = first, .reference = reference };
}

fn container_wrapped(context: *const Context, open: u32, close: u32) ?Context.TokenRange {
    assert(open < close);
    assert(close < context.tokens.len);

    const header = container_header_start(context, open) orelse return null;

    var wrapped: Context.TokenRange = .{ .end = close, .start = header };

    for (0..container_paren_count_max) |_| {
        const paren = context.significant_after(wrapped.end) orelse break;
        if (!context.tokens[paren].is_punctuation(.paren_close)) break;

        const partner = context.pairs.partner_of(paren) orelse break;
        const inner = context.significant_after(partner) orelse break;
        if (inner != wrapped.start) break;

        wrapped = .{ .end = paren, .start = partner };
    }

    assert(wrapped.start < open);
    assert(wrapped.end >= close);

    return wrapped;
}

fn container_header_start(context: *const Context, open: u32) ?u32 {
    const tokens = context.tokens;

    assert(open < tokens.len);
    assert(tokens[open].kind == .block_start);

    var keyword = context.significant_before(open) orelse return null;

    if (tokens[keyword].is_punctuation(.paren_close)) {
        const partner = context.pairs.partner_of(keyword) orelse return null;

        keyword = context.significant_before(partner) orelse return null;
    }

    if (!tokens[keyword].is_keyword(.@"struct")) return null;

    var start = keyword;

    for (0..stream.modifier_count_max) |_| {
        const before = context.significant_before(start) orelse break;
        if (!scan.word_listed(&container_layout_words, context.text(tokens[before]))) break;

        start = before;
    }

    assert(start <= keyword);

    return start;
}

fn row_through(
    context: *const Context,
    function: View,
    hand_overs: ?*HandOvers,
) ?*const scylla.Calls.Function {
    assert(function.index() < context.front.node_count());

    if (hand_overs) |index| return index.row_of(context, function);
    return function_row_of(context, function);
}

fn function_row_of(context: *const Context, function: View) ?*const scylla.Calls.Function {
    const node = function.index();

    assert(node < context.front.node_count());

    for (context.tables.functions()) |*row| {
        if (row.node != node) continue;

        assert(row.name.end() <= context.source.len);

        return row;
    }

    return null;
}

fn referenced_uncalled(context: *const Context, binding: u32) bool {
    const bindings = context.front.bindings();

    assert(binding < bindings.count());

    var references = bindings.references_of(binding);

    for (0..bindings.reference_count()) |_| {
        const reference = references.next() orelse return false;

        assert(reference.name.end() <= context.source.len);

        if (!hands_over(context, reference.name.offset, reference.name.end())) continue;
        if (!shadowed_by_a_parameter(context, reference.name)) return true;
    }

    return false;
}

fn handed_over_in_place(context: *const Context, function: View) bool {
    const start = context.lexer_index_from(function.span().offset);
    if (start >= context.tokens.len) return false;

    const before = context.significant_before(start) orelse return false;

    assert(before < start);
    assert(context.tokens[before].end() <= context.tokens[start].offset);

    if (!fills_a_slot(context, before)) return false;
    if (declares_in_a_scope(function)) return false;
    return !opens_with_its_name(context, start);
}

fn fills_a_slot(context: *const Context, before: u32) bool {
    const token = context.tokens[before];

    assert(before < context.tokens.len);
    assert(token.end() <= context.source.len);

    if (token.is_punctuation(.paren_open)) return true;
    if (token.is_punctuation(.comma)) return true;
    if (token.is_punctuation(.colon)) return !context.is_path_separator(token);
    if (!token.is_punctuation(.assign)) return false;

    const target = context.significant_before(before) orelse return false;
    const dot = context.significant_before(target) orelse return false;

    return context.tokens[dot].is_punctuation(.dot);
}

fn opens_with_its_name(context: *const Context, start: u32) bool {
    assert(start < context.tokens.len);

    var cursor = start;

    for (0..stream.modifier_count_max) |_| {
        if (!context.tokens[cursor].is_keyword(.other)) break;

        cursor = context.significant_after(cursor) orelse return false;
    }

    assert(cursor >= start);

    return context.tokens[cursor].kind == .identifier;
}

fn declares_in_a_scope(function: View) bool {
    const parent = function.parent() orelse return true;

    assert(parent.index() < function.index());
    assert(parent.span().offset <= function.span().offset);

    return switch (parent.category()) {
        .block, .file, .@"struct" => true,
        else => false,
    };
}

fn bit_of_length(length: u32) u64 {
    const shift: u6 = @intCast(@min(length, 63));
    const bit = @as(u64, 1) << shift;

    assert(@popCount(bit) == 1);

    return bit;
}

fn opens_a_call_at(tokens: []const Token, index: u32) bool {
    if (index >= tokens.len) return false;
    return tokens[index].is_punctuation(.paren_open);
}

fn name_hash(text: []const u8) u32 {
    assert(text.len > 0);

    return std.hash.Fnv1a_32.hash(text);
}

fn order_of_hash(hash: u32, held: u32) std.math.Order {
    return std.math.order(hash, held);
}

fn shadowed_by_a_parameter(context: *const Context, name: Span) bool {
    const enclosing = context.function_at(name.offset) orelse return false;
    const held = enclosing.as_function() orelse return false;
    const named = context.span_text(name);
    var parameters = held.parameters();

    assert(named.len > 0);
    assert(enclosing.span().offset <= name.offset);

    for (0..parameter_count_max + 1) |_| {
        const parameter = parameters.next() orelse return false;
        const declared = parameter.name orelse continue;
        if (std.mem.eql(u8, context.front_text(declared), named)) return true;
    }

    return false;
}

fn qualified_uncalled(context: *const Context, container: Span, name: Span) bool {
    const tokens = context.tokens;
    const held = context.span_text(container);
    const named = context.span_text(name);

    assert(held.len > 0);
    assert(named.len > 0);

    for (tokens, 0..) |token, position| {
        const index: u32 = @intCast(position);
        if (index + 2 >= tokens.len) return false;
        if (token.kind != .identifier) continue;
        if (!separates_a_path(context, tokens[index + 1])) continue;
        if (!std.mem.eql(u8, context.text(tokens[index + 2]), named)) continue;
        if (!std.mem.eql(u8, context.text(token), held)) continue;
        if (hands_over(context, token.offset, tokens[index + 2].end())) return true;
    }

    return false;
}

fn hands_over(context: *const Context, start: u32, end: u32) bool {
    assert(start < end);
    assert(end <= context.source.len);

    return hands_over_from(context, context.lexer_index_from(start), end);
}

fn hands_over_from(context: *const Context, leading: u32, end: u32) bool {
    assert(leading < context.tokens.len);

    return hands_over_after(context, leading, path_start(context, leading), end);
}

fn hands_over_after(context: *const Context, leading: u32, leading_first: u32, end: u32) bool {
    assert(leading < context.tokens.len);
    assert(leading_first <= leading);
    assert(context.tokens[leading].offset < end);

    var start = leading;
    var first = leading_first;
    var stop = end;

    for (0..prong_nesting_max) |_| {
        if (!hands_over_at(context, start, stop)) return false;
        if (follows_a_comparison(context, first)) return false;
        if (!follows_a_prong(context, first)) return hands_over_unlisted(context, first);

        const owner = prong_owner(context, first) orelse return false;
        const span = owner.span();

        assert(span.offset < context.tokens[first].offset);
        assert(span.end() <= context.source.len);

        start = context.lexer_index_from(span.offset);
        first = path_start(context, start);
        stop = span.end();
    }

    return false;
}

fn hands_over_unlisted(context: *const Context, first: u32) bool {
    assert(first < context.tokens.len);

    if (aliases_at(context, first)) return false;
    if (exports_by_default(context, first)) return false;
    return !lists_a_name(context, first);
}

fn follows_a_comparison(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);

    const before = context.significant_before(index) orelse return false;

    assert(before < index);

    return compares(context.tokens[before]);
}

fn follows_a_prong(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);

    const before = context.significant_before(index) orelse return false;

    assert(before < index);

    return std.mem.eql(u8, context.text(context.tokens[before]), prong_arrow);
}

fn prong_owner(context: *const Context, first: u32) ?View {
    assert(first < context.tokens.len);

    if (context.conventions.arrows_open_lambdas) return null;

    const arrow = context.significant_before(first) orelse return null;
    const offset = context.tokens[arrow].offset;
    const slot = Enclosures.slot_of(.match).?;

    assert(arrow < first);

    const found = switch (context.enclosures.innermost(context.front, slot, offset)) {
        .absent => return null,
        .found => |position| context.view(position),
        .unordered => match_covering(context, offset) orelse return null,
    };

    assert(found.category() == .match);
    assert(found.span().contains(offset));

    return found;
}

fn match_covering(context: *const Context, offset: u32) ?View {
    assert(offset <= context.source.len);

    var found: ?View = null;
    var matches = context.views(.match);

    for (0..matches.remaining) |_| {
        const held = matches.next() orelse break;
        const span = held.span();
        if (!span.contains(offset)) continue;

        if (found) |inner| {
            if (inner.span().offset > span.offset) continue;
        }

        found = held;
    }

    if (found) |held| assert(held.span().contains(offset));

    return found;
}

fn compares(token: Token) bool {
    return token.is_punctuation(.equal) or token.is_punctuation(.not_equal);
}

fn past_generic_arguments(context: *const Context, index: u32) ?u32 {
    assert(index < context.tokens.len);

    if (!std.mem.eql(u8, context.text(context.tokens[index]), Context.path_separator)) return index;

    const opener = context.significant_after(index) orelse return index;
    if (!context.tokens[opener].is_punctuation(.less)) return index;

    assert(opener > index);

    var depth: u32 = 0;
    var cursor = opener;

    for (0..generic_scan_max) |_| {
        const token = context.tokens[cursor];

        if (token.is_punctuation(.less)) depth += 1;
        if (token.is_punctuation(.greater)) depth -= 1;
        if (depth == 0) return context.significant_after(cursor);

        cursor = context.significant_after(cursor) orelse return null;
    }

    return null;
}

fn path_start(context: *const Context, index: u32) u32 {
    assert(index < context.tokens.len);

    var first = index;

    for (0..path_lookbehind_max) |_| {
        const dot = context.significant_before(first) orelse return first;
        if (!context.tokens[dot].is_punctuation(.dot)) return first;

        const root = context.significant_before(dot) orelse return first;
        if (context.tokens[root].kind != .identifier) return first;

        first = root;
    }

    assert(first <= index);

    return first;
}

fn aliases_at(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);

    const operator = context.significant_before(index) orelse return false;
    const name = context.significant_before(operator) orelse return false;
    const token = context.tokens[operator];

    assert(name < operator);

    if (context.tokens[name].kind != .identifier) return false;
    if (token.is_punctuation(.assign_declare)) return true;
    if (!token.is_punctuation(.assign)) return false;

    const keyword = context.significant_before(name) orelse return false;
    return declares_a_binding(context.tokens[keyword]);
}

fn declares_a_binding(token: Token) bool {
    return switch (token.kind) {
        .keyword => |keyword| switch (keyword) {
            .constant, .declare, .mutable => true,
            else => false,
        },
        else => false,
    };
}

fn exports_by_default(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);

    const word = context.significant_before(index) orelse return false;
    if (!std.mem.eql(u8, context.text(context.tokens[word]), default_word)) return false;

    const keyword = context.significant_before(word) orelse return false;

    assert(keyword < word);

    return context.tokens[keyword].kind.eql(.{ .keyword = .import });
}

fn lists_a_name(context: *const Context, index: u32) bool {
    assert(index < context.tokens.len);

    var cursor = index;

    for (0..name_list_lookbehind_max) |_| {
        cursor = context.significant_before(cursor) orelse return false;

        const token = context.tokens[cursor];
        if (token.kind == .block_start) return opens_a_name_list(context, cursor);
        if (!continues_a_name_list(token)) return false;
    }

    assert(cursor < index);

    return false;
}

fn continues_a_name_list(token: Token) bool {
    return switch (token.kind) {
        .identifier => true,
        .keyword => |keyword| keyword == .other,
        .punctuation => |punctuation| punctuation == .comma or punctuation == .dot,
        else => false,
    };
}

fn opens_a_name_list(context: *const Context, brace: u32) bool {
    assert(brace < context.tokens.len);
    assert(context.tokens[brace].kind == .block_start);

    const before = context.significant_before(brace) orelse return false;

    return switch (context.tokens[before].kind) {
        .keyword => |keyword| keyword == .function or keyword == .import,
        else => false,
    };
}

fn hands_over_at(context: *const Context, leading: u32, end: u32) bool {
    assert(end <= context.source.len);
    assert(leading < context.tokens.len);

    const next = context.significant_from_hint(end, leading) orelse return true;
    const after = past_generic_arguments(context, next) orelse return false;
    const token = context.tokens[after];

    assert(token.offset >= end);

    if (token.is_punctuation(.paren_open)) return false;
    if (token.is_punctuation(.assign)) return false;
    if (token.is_punctuation(.assign_declare)) return false;
    if (compares(token)) return false;
    if (!token.is_punctuation(.comma)) return true;
    return !opens_a_tuple(context, after);
}

fn opens_a_tuple(context: *const Context, comma: u32) bool {
    const dot = context.significant_after(comma) orelse return false;

    assert(dot < context.tokens.len);

    if (!context.tokens[dot].is_punctuation(.dot)) return false;

    const brace = context.significant_after(dot) orelse return false;

    assert(brace > dot);

    return context.tokens[brace].kind == .block_start;
}

fn separates_a_path(context: *const Context, token: Token) bool {
    assert(token.end() <= context.source.len);

    if (token.is_punctuation(.dot)) return std.mem.eql(u8, context.text(token), ".");
    return context.is_path_separator(token);
}
