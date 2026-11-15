const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const scan = scylla.scan;
const stream = scylla.stream;
const testing = @import("../testing.zig");
const Context = @import("../context.zig");
const Language = scylla.Language;
const Rule = scylla.Rule;
const Sink = scylla.rule.Sink;
const View = scylla.View;

pub const rule: Rule = .{
    .citations = &.{
        .{
            .standard = "TigerStyle",
            .text = "\"Use newlines to **group resource allocation and deallocation**, i.e. " ++
                "before the resource allocation and after the corresponding `defer` statement, " ++
                "to make leaks easier to spot.\"",
        },
    },
    .code = "TS046",
    .default_on = false,
    .description = "An allocation and the defer that releases it sit together, set off by blank " ++
        "lines, so a missing defer is visible.",
    .explanation = "",
    .fix_title = "",
    .fixable = .sometimes,
    .group = .stable,
    .name = "allocation-grouping",
    .severity = .information,
    .summary = "Set a resource's allocation apart from the code around it",
    .url = "",
};

const Pairing = struct {
    acquired: View,
    ends: u32,
    fenced: bool,
    opens: u32,
    statement: View,
};

const Siblings = [sibling_scan_max]?View;
const dereference = ".*";
const discard_word = "_";
const error_check_words = [_][]const u8{ "err", "error", "nil", "ok" };
const error_defer_word = "errdefer";
const sibling_scan_max: u32 = 16;
const storage_value = "undefined";

comptime {
    assert(sibling_scan_max > 1);
}

pub fn run(context: *const Context, sink: *Sink) void {
    const word = context.grammar.defer_word;
    if (word.len == 0) return;

    assert(word.len > 0);

    for (context.tokens, 0..) |token, position| {
        const index: u32 = @intCast(position);

        if (!defers(.{ .text = context.text(token), .word = word })) continue;

        const end = deferred_end(context, index + 1) orelse continue;
        const pairing = pairing_of(context, index) orelse continue;
        const last: u32 = @intCast(context.tokens.len - 1);
        const closes = context.line_of(context.tokens[@min(end, last)].offset);

        assert(end > index);

        if (set_apart(context, pairing, closes)) continue;
        if (stands_alone(context, pairing, .{ .closes = closes, .index = index })) continue;

        sink.report(token.span(), "the allocation and its defer are not set off by blank lines");
    }
}

fn defers(options: struct { text: []const u8, word: []const u8 }) bool {
    assert(options.word.len > 0);
    if (std.mem.eql(u8, options.text, options.word)) return true;
    return std.mem.eql(u8, options.text, error_defer_word);
}

fn deferred_end(context: *const Context, start: u32) ?u32 {
    assert(start <= context.tokens.len);

    const end = stream.statement_end(context.tokens, start);

    assert(end >= start);
    assert(end <= context.tokens.len);

    if (end == context.tokens.len) return end;
    if (context.tokens[end].kind != .block_start) return end;
    return context.pairs.partner_of(end);
}

fn set_apart(context: *const Context, pairing: Pairing, closes: u32) bool {
    assert(pairing.opens <= pairing.ends);
    assert(closes < context.line_count());

    if (pairing.opens > 0) {
        const above = pairing.opens - 1;

        if (!is_blank(context, above)) {
            if (!opens_a_group(context, above)) return false;
        }
    }

    const first = pairing.ends + 1;

    if (pairing.fenced) {
        if (!is_blank(context, first)) return false;
    }

    if (first < closes) {
        for (first..closes) |line| {
            if (pairing.fenced) {
                if (line == first) continue;
            }

            if (is_blank(context, @intCast(line))) return false;
        }
    }

    return closes_a_group(context, closes + 1);
}

fn stands_alone(
    context: *const Context,
    pairing: Pairing,
    options: struct { closes: u32, index: u32 },
) bool {
    assert(options.index < context.tokens.len);

    const line = chain_start(context, context.line_of(context.tokens[options.index].offset));

    assert(line <= options.closes);

    if (line == 0) return false;
    if (!is_blank(context, line - 1)) return false;
    if (releases_the_acquisition(context, pairing)) return false;
    return closes_a_group(context, options.closes + 1);
}

fn chain_start(context: *const Context, line: u32) u32 {
    assert(line < context.line_count());

    var result = line;

    for (0..line) |_| {
        if (result == 0) break;
        if (!opens_with_a_defer(context, result - 1)) break;

        result -= 1;
    }

    assert(result <= line);

    return result;
}

fn opens_with_a_defer(context: *const Context, line: u32) bool {
    assert(line < context.line_count());

    const text = scan.trim_ascii(context.line_text(line));

    return defers(.{ .text = leading_word(text), .word = context.grammar.defer_word });
}

fn releases_the_acquisition(context: *const Context, pairing: Pairing) bool {
    assert(pairing.acquired.span().end() <= pairing.statement.span().offset);
    assert(pairing.statement.span().end() <= context.source.len);

    const acquired = pairing.acquired;
    const statement = pairing.statement;

    for (context.tokens_in(statement.span())) |token| {
        if (token.kind != .identifier) continue;
        if (acquires(context, acquired, context.text(token))) return true;
    }

    return false;
}

fn acquires(context: *const Context, acquired: View, name: []const u8) bool {
    assert(name.len > 0);
    assert(acquired.span().end() <= context.source.len);

    if (acquired.as_declaration()) |declaration| {
        if (declaration.name_token()) |named| {
            if (std.mem.eql(u8, context.front_text(named), name)) return true;
        }
    }

    if (leading_root(context, acquired)) |root| {
        if (std.mem.eql(u8, root, name)) return true;
    }

    const tokens = context.tokens_in(acquired.span());

    for (tokens, 0..) |token, position| {
        if (!token.is_punctuation(.ampersand)) continue;
        if (position + 1 >= tokens.len) break;
        if (std.mem.eql(u8, context.text(tokens[position + 1]), name)) return true;
    }

    return false;
}

fn leading_root(context: *const Context, view: View) ?[]const u8 {
    assert(view.span().end() <= context.source.len);

    const tokens = context.tokens_in(view.span());

    assert(tokens.len <= context.tokens.len);

    const start = leading_start(context, tokens);

    assert(start <= tokens.len);

    if (start >= tokens.len) return null;
    if (tokens[start].kind != .identifier) return null;
    return context.text(tokens[start]);
}

fn released_path(context: *const Context, released: View) ?[]const u8 {
    assert(released.span().end() <= context.source.len);

    const tokens = context.tokens_in(released.span());
    if (tokens.len < 2) return null;

    if (!defers(.{
        .text = context.text(tokens[0]),
        .word = context.grammar.defer_word,
    })) return null;

    const start = 1 + leading_start(context, tokens[1..]);

    assert(start >= 1);
    assert(start <= tokens.len);

    return target_path(context, tokens, start);
}

fn target_path(context: *const Context, tokens: []const scylla.Token, start: u32) ?[]const u8 {
    if (start >= tokens.len) return null;
    if (tokens[start].kind != .identifier) return null;

    var last = start;

    for (0..tokens.len) |_| {
        if (last + 2 >= tokens.len) break;
        if (!separates_a_member(context, tokens[last + 1])) break;
        if (tokens[last + 2].kind != .identifier) break;

        last += 2;
    }

    assert(last >= start);
    assert(last < tokens.len);

    const path = context.source[tokens[start].offset..tokens[last].end()];
    if (last + 1 == tokens.len) return path;
    if (!tokens[last + 1].is_punctuation(.paren_open)) return path;

    const dot = std.mem.findScalarLast(u8, path, '.') orelse return null;

    return path[0..dot];
}

fn separates_a_member(context: *const Context, token: scylla.Token) bool {
    assert(token.end() <= context.source.len);

    if (!token.is_punctuation(.dot)) return false;
    return std.mem.eql(u8, context.text(token), ".");
}

fn extends_the_path(options: struct { path: []const u8, prefix: []const u8 }) bool {
    assert(options.prefix.len > 0);
    assert(options.path.len > 0);
    if (!std.mem.startsWith(u8, options.path, options.prefix)) return false;
    if (options.path.len == options.prefix.len) return true;
    return options.path[options.prefix.len] == '.';
}

fn leading_start(context: *const Context, tokens: []const scylla.Token) u32 {
    var start: u32 = 0;

    assert(tokens.len <= context.tokens.len);

    if (tokens.len > 1) {
        if (std.mem.eql(u8, context.text(tokens[0]), discard_word)) {
            if (tokens[1].is_punctuation(.assign)) start = 2;
        }
    }

    if (start < tokens.len) {
        if (tokens[start].is_keyword(.@"try")) start += 1;
    }

    assert(start <= tokens.len);

    return start;
}

fn pairing_of(context: *const Context, index: u32) ?Pairing {
    assert(index < context.tokens.len);

    const statement = owning_statement(context, context.tokens[index].offset) orelse return null;
    const parent = statement.parent() orelse return null;
    const siblings = siblings_before(parent, statement.span().offset);
    const position = acquisition_of(context, &siblings) orelse return null;
    const acquired = siblings[position].?;
    const first = storage_of(context, &siblings, position, statement);
    const top = declarations_top(context, &siblings, first);
    const span = acquired.span();

    const pairing: Pairing = .{
        .acquired = acquired,
        .ends = context.line_of(@max(span.end() -| 1, span.offset)),
        .fenced = !single_line(context, acquired),
        .opens = context.line_of(siblings[top].?.span().offset),
        .statement = statement,
    };

    assert(pairing.opens <= pairing.ends);
    assert(span.offset < statement.span().offset);

    return pairing;
}

fn storage_of(
    context: *const Context,
    siblings: *const Siblings,
    position: u32,
    released: View,
) u32 {
    assert(position < sibling_scan_max);
    assert(released.span().end() <= context.source.len);

    const released_from = released_path(context, released);
    var cursor = position;

    for (0..sibling_scan_max) |_| {
        if (cursor == 0) break;

        const first = siblings[cursor].?;
        const earlier = siblings[cursor - 1] orelse break;
        if (!adjoins(context, .{ .earlier = earlier, .later = first })) break;

        if (!stores_for(
            context,
            .{ .earlier = earlier, .released = released },
            released_from,
            first.span().offset,
        )) break;

        cursor -= 1;
    }

    assert(cursor <= position);
    assert(siblings[cursor] != null);

    return cursor;
}

fn declarations_top(context: *const Context, siblings: *const Siblings, position: u32) u32 {
    assert(position < sibling_scan_max);
    assert(siblings[position] != null);

    if (!single_line_declaration(context, siblings[position].?)) return position;

    var cursor = position;

    for (0..sibling_scan_max) |_| {
        if (cursor == 0) break;

        const earlier = siblings[cursor - 1] orelse break;
        if (!adjoins(context, .{ .earlier = earlier, .later = siblings[cursor].? })) break;
        if (!single_line_declaration(context, earlier)) break;

        cursor -= 1;
    }

    assert(cursor <= position);
    assert(siblings[cursor] != null);

    return cursor;
}

fn single_line_declaration(context: *const Context, view: View) bool {
    assert(view.span().end() <= context.source.len);

    if (view.as_declaration() == null) return false;
    return single_line(context, view);
}

fn single_line(context: *const Context, view: View) bool {
    assert(view.span().end() <= context.source.len);

    const span = view.span();

    assert(span.end() <= context.source.len);

    return context.line_of(span.offset) == context.line_of(@max(span.end() -| 1, span.offset));
}

fn adjoins(context: *const Context, options: struct { earlier: View, later: View }) bool {
    assert(options.earlier.span().end() <= context.source.len);
    assert(options.later.span().end() <= context.source.len);

    const span = options.earlier.span();
    const ends = context.line_of(@max(span.end() -| 1, span.offset));

    assert(span.offset < options.later.span().offset);
    assert(ends <= context.line_of(options.later.span().offset));

    return ends + 1 == context.line_of(options.later.span().offset);
}

fn stores_for(
    context: *const Context,
    options: struct { earlier: View, released: View },
    released_from: ?[]const u8,
    opened: u32,
) bool {
    assert(opened <= options.released.span().offset);

    if (options.earlier.as_declaration()) |declaration| {
        const named = declaration.name_token() orelse return false;
        const name = context.front_text(named);

        if (scan.find_word(context.span_text(options.released.span()), name)) {
            const acquisition = context.tokens_in(.{
                .offset = opened,
                .length = options.released.span().offset - opened,
            });

            if (!names_a_token(context, acquisition, name)) return true;
            if (assigns_the_name(context, acquisition, name)) return true;
        }

        const value = declaration.value() orelse return false;
        const pair = context.source[opened..options.released.span().end()];

        if (!std.mem.eql(u8, value.text(context.source), storage_value)) return false;
        return scan.find_word(pair, name);
    }

    const prefix = released_from orelse return false;
    const tokens = context.tokens_in(options.earlier.span());
    const path = target_path(context, tokens, leading_start(context, tokens)) orelse return false;

    assert(prefix.len > 0);

    return extends_the_path(.{ .path = path, .prefix = prefix });
}

fn names_a_token(context: *const Context, tokens: []const scylla.Token, name: []const u8) bool {
    assert(tokens.len <= context.tokens.len);
    assert(name.len > 0);

    for (tokens) |token| {
        if (token.kind != .identifier) continue;
        if (std.mem.eql(u8, context.text(token), name)) return true;
    }

    return false;
}

fn assigns_the_name(context: *const Context, tokens: []const scylla.Token, name: []const u8) bool {
    assert(tokens.len <= context.tokens.len);
    assert(name.len > 0);

    for (tokens, 0..) |token, index| {
        if (token.kind != .identifier) continue;
        if (!std.mem.eql(u8, context.text(token), name)) continue;

        if (index > 0) {
            if (tokens[index - 1].is_punctuation(.dot)) continue;
        }

        if (assignment_after(context, tokens, @intCast(index + 1))) return true;
    }

    return false;
}

fn assignment_after(context: *const Context, tokens: []const scylla.Token, start: u32) bool {
    assert(start <= tokens.len);

    if (start >= tokens.len) return false;
    if (tokens[start].is_punctuation(.assign)) return true;
    if (start + 1 >= tokens.len) return false;
    if (!std.mem.eql(u8, context.text(tokens[start]), dereference)) return false;
    return tokens[start + 1].is_punctuation(.assign);
}

fn owning_statement(context: *const Context, offset: u32) ?View {
    var found: ?View = null;
    var blocks = context.views(.block);

    assert(offset <= context.source.len);

    for (0..blocks.remaining) |_| {
        const block = blocks.next() orelse break;
        var children = block.children();

        for (0..children.remaining) |_| {
            const child = children.next() orelse break;
            const span = child.span();
            if (span.offset > offset) continue;
            if (offset >= span.end()) continue;

            if (found) |inner| {
                if (inner.span().offset > span.offset) continue;
            }

            found = child;
        }
    }

    if (found) |held| assert(held.span().contains(offset));

    return found;
}

fn siblings_before(parent: View, opened: u32) Siblings {
    var siblings: Siblings = @splat(null);
    var children = parent.children();

    for (0..children.remaining) |_| {
        const child = children.next() orelse break;
        if (child.span().offset >= opened) break;

        assert(child.index() > parent.index());

        std.mem.copyForwards(?View, siblings[0 .. sibling_scan_max - 1], siblings[1..]);
        siblings[sibling_scan_max - 1] = child;
    }

    if (siblings[0] != null) assert(siblings[1] != null);

    return siblings;
}

fn acquisition_of(context: *const Context, siblings: *const Siblings) ?u32 {
    if (siblings[0] != null) assert(siblings[sibling_scan_max - 1] != null);

    var position: u32 = sibling_scan_max - 1;
    if (siblings[position] == null) return null;

    for (0..sibling_scan_max - 1) |_| {
        if (!passed_over(context, siblings[position].?)) break;
        if (siblings[position - 1] == null) break;

        position -= 1;
    }

    assert(siblings[position].?.span().end() <= context.source.len);

    return position;
}

fn passed_over(context: *const Context, view: View) bool {
    assert(view.span().end() <= context.source.len);

    const text = context.span_text(view.span());
    const word = context.grammar.defer_word;

    assert(word.len > 0);
    assert(text.len == view.span().length);

    if (view.category() == .branch) {
        if (checks_an_error(context, view)) return true;
    }

    if (std.mem.startsWith(u8, text, word)) return true;
    return std.mem.startsWith(u8, text, error_defer_word);
}

fn checks_an_error(context: *const Context, branch: View) bool {
    assert(branch.span().end() <= context.source.len);

    const line = context.line_text(context.line_of(branch.span().offset));

    assert(branch.category() == .branch);
    assert(line.len <= context.source.len);

    for (error_check_words) |word| {
        if (scan.find_word(line, word)) return true;
    }

    return false;
}

fn opens_a_group(context: *const Context, line: u32) bool {
    assert(line < context.line_count());

    const text = std.mem.trimEnd(u8, context.line_text(line), scan.ascii_whitespace);
    const prefix = context.grammar.comment_prefix;

    if (std.mem.endsWith(u8, text, "{")) return true;
    if (std.mem.endsWith(u8, text, ":")) return true;
    if (prefix.len == 0) return false;

    const trimmed = std.mem.trimStart(u8, text, scan.ascii_whitespace);

    assert(trimmed.len <= text.len);

    return std.mem.startsWith(u8, trimmed, prefix);
}

fn closes_a_group(context: *const Context, line: u32) bool {
    if (is_blank(context, line)) return true;

    assert(line < context.line_count());

    if (std.mem.startsWith(u8, scan.trim_ascii(context.line_text(line)), "}")) return true;
    return opens_with_a_defer(context, line);
}

fn leading_word(text: []const u8) []const u8 {
    var end: u32 = 0;

    for (text) |byte| {
        if (!scan.is_identifier_part(byte)) break;

        end += 1;
    }

    assert(end <= text.len);

    return text[0..end];
}

fn is_blank(context: *const Context, line: u32) bool {
    if (line >= context.line_count()) return true;

    assert(line < context.line_count());

    const span = context.line_span(line);

    assert(span.end() <= context.source.len);

    return scan.gap_is_blank(context.source, span);
}

fn expect_count(language: Language, source: []const u8, expected: u32) !void {
    assert(source.len > 0);
    assert(expected <= testing.limits.diagnostic_count_max);

    var findings = try testing.analyze(@This(), language, source);
    defer findings.deinit();

    if (findings.count() != expected) findings.print();

    try std.testing.expectEqual(expected, findings.count());
}

test "a closing brace that opens its line ends the block below a defer" {
    const source = "package p\n\nf :: proc() {\n\twork()\n\n\twhen A {\n\t\tx: Element\n" ++
        "\t\tdefer clear(&x)\n\t} else when B {\n\t\twork()\n\t}\n" ++
        "\tbuffer := make([]u8, 4)\n\tdefer delete(buffer)\n\twork()\n}\n";

    try testing.expect_anchors(@This(), .odin, source, &.{.{ 13, 2 }});
}

test "a defer at the end of the token stream stays in bounds" {
    const source = "fn run(list: *List) void {\n    list.reset();\n" ++
        "    var buffer = list.alloc();\n    defer buffer.deinit()";

    try expect_count(.zig, source, 1);
}

test "a crowded defer is reported" {
    const source = "func work() {\n\tfile := open()\n\tdefer file.close()\n\tuse(file)\n}\n";

    try expect_count(.go, source, 1);
}

test "every defer is the release half of a pair" {
    const source = "func work() {\n\tctx, cancel := context.WithCancel(parent)\n" ++
        "\tdefer cancel()\n\tuse(ctx)\n}\n";

    const odin = "package fixture\n\nwork :: proc() {\n    values := make([]int, 4)\n" ++
        "    defer delete(values)\n    use(values)\n}\n";

    try expect_count(.go, source, 1);
    try expect_count(.odin, odin, 1);
}

test "an errdefer is a defer" {
    const source = "fn work(gpa: Allocator) !void {\n    const buffer = try gpa.alloc(u8, 4);\n" ++
        "    errdefer gpa.free(buffer);\n    use(buffer);\n}\n";

    const apart = "fn work(gpa: Allocator) !void {\n    const buffer = try gpa.alloc(u8, 4);\n" ++
        "    errdefer gpa.free(buffer);\n\n    use(buffer);\n}\n";

    try expect_count(.zig, source, 1);
    try testing.expect_quiet(@This(), .zig, apart);
}

test "a set apart defer is quiet" {
    const source = "func work() {\n\n\tfile := open()\n\tdefer file.close()\n\n\tuse(file)\n}\n";

    try testing.expect_quiet(@This(), .go, source);
}

test "a deferred block is read to its own end" {
    const source = "func work() {\n\tfile := open()\n\n\tdefer func() {\n\t\tfile.close()\n" ++
        "\t}()\n\n\tuse(file)\n}\n";

    try expect_count(.go, source, 1);
}

test "a zig deferred block is read to its own end" {
    const source = "fn work() void {\n    const f = open();\n\n    defer {\n" ++
        "        f.deinit();\n    }\n\n    use(f);\n}\n";

    try expect_count(.zig, source, 1);
}

test "a defer at the end of the source is read without running off it" {
    const source = "func work() {\n\tfile := open()\n\tdefer file.close()";

    try testing.expect_quiet(@This(), .go, source);
}

test "a pair opening a block needs no blank line above" {
    const source = "func work() {\n\tfile := open()\n\tdefer file.close()\n\n\tuse(file)\n}\n";

    try testing.expect_quiet(@This(), .go, source);
}

test "an error check between the pair belongs to the acquisition" {
    const source = "func work() {\n\tfile, err := open()\n\tif err != nil {\n\t\treturn\n\t}\n" ++
        "\tdefer file.close()\n\n\tuse(file)\n}\n";

    try testing.expect_quiet(@This(), .go, source);
}

test "an unclosed deferred block is given up on" {
    const source = "func work() {\n\tfile := open()\n\tdefer func() {\n\t\tfile.close()";

    try testing.expect_quiet(@This(), .go, source);
}

test "a blank line inside the pair is still reported" {
    const source = "func work() {\n\tfile := open()\n\n\tdefer file.close()\n\n\tuse(file)\n}\n";

    try expect_count(.go, source, 1);
}

test "storage declared for an acquisition in place belongs to it" {
    const apart = "fn work(gpa: Allocator) !void {\n    const limit = 4;\n\n" ++
        "    var built: Built = undefined;\n    try built.init(gpa, limit);\n" ++
        "    defer built.deinit(gpa);\n\n    use(&built);\n}\n";

    const welded = "fn work(gpa: Allocator) !void {\n    const limit = 4;\n" ++
        "    var built: Built = undefined;\n    try built.init(gpa, limit);\n" ++
        "    defer built.deinit(gpa);\n\n    use(&built);\n}\n";

    const crowded = "fn work(gpa: Allocator) !void {\n    reset(gpa);\n" ++
        "    var built: Built = undefined;\n    try built.init(gpa, 4);\n" ++
        "    defer built.deinit(gpa);\n\n    use(&built);\n}\n";

    try testing.expect_quiet(@This(), .zig, apart);
    try testing.expect_quiet(@This(), .zig, welded);
    try expect_count(.zig, crowded, 1);
}

test "a run of fields the defer releases belongs to the acquisition" {
    const source = "fn init(holder: *Holder, gpa: Allocator) !void {\n" ++
        "    holder.first = null;\n    holder.second = null;\n" ++
        "    errdefer holder.deinit(gpa);\n\n    try holder.load(gpa);\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "a defer set apart from a statement it does not release stands alone" {
    const source = "fn step(shadow: *Shadow) !void {\n" ++
        "    if (shadow.failed) return error.Overflow;\n\n    errdefer shadow.failed = true;\n\n" ++
        "    try shadow.run();\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "a group is closed by a blank line or by the brace" {
    const followed = "func work() {\n\n\tfile := open()\n\tdefer file.close()\n\tuse(file)\n}\n";
    const braced = "func work() {\n\n\tfile := open()\n\tdefer file.close()\n}\n";
    const blank = "func work() {\n\n\tfile := open()\n\tdefer file.close()\n\n\tuse(file)\n}\n";

    try expect_count(.go, followed, 1);
    try testing.expect_quiet(@This(), .go, braced);
    try testing.expect_quiet(@This(), .go, blank);
}

test "a declaration the defer releases joins the acquisition below it" {
    const second = "fn emit(gpa: Allocator) void {\n    var section = Section.init(gpa);\n" ++
        "    var params = Section.init(gpa);\n    defer {\n        section.deinit();\n" ++
        "        params.deinit();\n    }\n\n    use(&section, &params);\n}\n";

    const filled = "fn make(gpa: Allocator) !*Texture {\n" ++
        "    var texture = try gpa.create(Texture);\n    texture.* = .{ .size = 1 };\n" ++
        "    errdefer gpa.destroy(texture);\n\n    return texture;\n}\n";

    const input = "fn run(gpa: Allocator) !void {\n    var iter = Iterator{ .items = &.{} };\n" ++
        "    var res = try parse(gpa, &iter);\n    defer res.deinit();\n\n    use(res);\n}\n";

    const called = "fn run(gpa: Allocator) !void {\n    iter.reset();\n" ++
        "    var res = try parse(gpa, &iter);\n    defer res.deinit();\n\n    use(res);\n}\n";

    try testing.expect_quiet(@This(), .zig, second);
    try testing.expect_quiet(@This(), .zig, filled);
    try testing.expect_quiet(@This(), .zig, input);
    try expect_count(.zig, called, 1);
}

test "a multi-line acquisition is fenced from its defer by exactly one blank line" {
    const fenced = "fn run(gpa: Allocator) u8 {\n    const limit = 4;\n\n" ++
        "    const buffer = gpa.alloc(u8, limit) catch {\n        return 1;\n    };\n\n" ++
        "    defer gpa.free(buffer);\n\n    return use(buffer);\n}\n";

    const chained = "fn run(encoder: *Encoder) !void {\n    work();\n\n" ++
        "    encoder.frames[0] = .{\n        .depth = 0,\n    };\n\n" ++
        "    errdefer encoder.frames_release();\n    errdefer encoder.sections_end();\n\n" ++
        "    try encoder.run();\n}\n";

    const welded = "fn run(gpa: Allocator) u8 {\n    const limit = 4;\n\n" ++
        "    const buffer = gpa.alloc(u8, limit) catch {\n        return 1;\n    };\n" ++
        "    defer gpa.free(buffer);\n\n    return use(buffer);\n}\n";

    const welded_chain = "fn run(gpa: Allocator) u8 {\n    work();\n\n" ++
        "    const result = run_child(.{\n        .gpa = gpa,\n    });\n" ++
        "    defer gpa.free(result.stdout);\n    defer gpa.free(result.stderr);\n\n" ++
        "    return use(result);\n}\n";

    const doubled = "fn run(encoder: *Encoder) !void {\n    work();\n\n" ++
        "    encoder.frames[0] = .{\n        .depth = 0,\n    };\n\n" ++
        "    errdefer encoder.frames_release();\n\n    errdefer encoder.sections_end();\n\n" ++
        "    try encoder.run();\n}\n";

    try testing.expect_quiet(@This(), .zig, fenced);
    try testing.expect_quiet(@This(), .zig, chained);
    try expect_count(.zig, welded, 1);
    try expect_count(.zig, welded_chain, 2);
    try expect_count(.zig, doubled, 1);
}

test "a chain of defers closes the group after its last defer" {
    const welded = "func work() {\n\n\tfile := open()\n\tdefer file.close()\n" ++
        "\tdefer log.flush()\n\n\tuse(file)\n}\n";

    const crowded = "func work() {\n\n\tfile := open()\n\tdefer file.close()\n" ++
        "\tdefer log.flush()\n\tuse(file)\n}\n";

    const deferred = "fn work(gpa: Allocator) !void {\n\n" ++
        "    const buffer = try gpa.alloc(u8, 4);\n    defer gpa.free(buffer);\n" ++
        "    deferred_count += 1;\n\n    use(buffer);\n}\n";

    try testing.expect_quiet(@This(), .go, welded);
    try expect_count(.go, crowded, 1);
    try expect_count(.zig, deferred, 1);
}

test "a chain of defers set apart from the code above stands alone as a whole" {
    const source = "fn run(encoder: *Encoder, problem: *?Problem) !void {\n" ++
        "    if (extended) encoder.attach();\n    defer if (extended) encoder.detach();\n\n" ++
        "    errdefer encoder.output.deinit();\n    errdefer problem.* = encoder.problem;\n\n" ++
        "    try encoder.run();\n}\n";

    const crowded = "fn run(encoder: *Encoder, problem: *?Problem) !void {\n" ++
        "    if (extended) encoder.attach();\n    defer if (extended) encoder.detach();\n\n" ++
        "    errdefer encoder.output.deinit();\n    errdefer problem.* = encoder.problem;\n" ++
        "    try encoder.run();\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
    try expect_count(.zig, crowded, 1);
}

test "a single-line acquisition still welds to its defer" {
    const source = "fn run(gpa: Allocator) !void {\n    work();\n\n" ++
        "    const buffer = try gpa.alloc(u8, 4);\n\n    defer gpa.free(buffer);\n\n" ++
        "    use(buffer);\n}\n";

    try expect_count(.zig, source, 1);
}

test "a run of single-line declarations ending in the acquisition is one group" {
    const declarations = "fn run(gpa: Allocator, io: Io) !void {\n    work();\n\n" ++
        "    const root = paths.root;\n    const sub = paths.sub;\n" ++
        "    var directory = try open(io, root, sub);\n    defer directory.close(io);\n\n" ++
        "    use(directory, gpa);\n}\n";

    const opened = "fn run(gpa: Allocator, io: Io) !void {\n    const root = paths.root;\n" ++
        "    var directory = try open(io, root);\n    defer directory.close(io);\n\n" ++
        "    use(directory, gpa);\n}\n";

    const statement = "fn run(gpa: Allocator, io: Io) !void {\n    work();\n" ++
        "    const root = paths.root;\n    var directory = try open(io, root);\n" ++
        "    defer directory.close(io);\n\n    use(directory, gpa);\n}\n";

    const multi_line = "fn run(gpa: Allocator, io: Io) !void {\n    const options = .{\n" ++
        "        .iterate = true,\n    };\n    var directory = try open(io, options);\n" ++
        "    defer directory.close(io);\n\n    use(directory, gpa);\n}\n";

    try testing.expect_quiet(@This(), .zig, declarations);
    try testing.expect_quiet(@This(), .zig, opened);
    try expect_count(.zig, statement, 1);
    try expect_count(.zig, multi_line, 1);
}

test "a doc comment above a declaration run sets the group apart" {
    const source = "fn run(gpa: Allocator) !void {\n    work();\n    // The scratch buffer.\n" ++
        "    const size = 4;\n    const buffer = try gpa.alloc(u8, size);\n" ++
        "    defer gpa.free(buffer);\n\n    use(buffer);\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
}
