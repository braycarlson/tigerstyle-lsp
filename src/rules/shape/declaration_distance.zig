const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const scan = @import("../../scan.zig");
const shape = @import("../shape.zig");
const support = @import("../support.zig");
const testing = @import("../testing.zig");
const Context = @import("../context.zig");
const Declaration = scylla.View.Declaration;
const Rule = scylla.rule.Rule;
const Sink = scylla.rule.Sink;
const Span = scylla.Span;
const View = scylla.View;

pub const rule: Rule = .{
    .citations = &.{
        .{
            .standard = "TigerStyle",
            .text = "\"Calculate or check variables close to where/when they are used. **Don't " ++
                "introduce variables before they are needed.** Don't leave them around where " ++
                "they are not. This will reduce the probability of a POCPOU (place-of-check to " ++
                "place-of-use), a distant cousin to the infamous TOCTOU. Most bugs come down to " ++
                "a semantic gap, caused by a gap in time or space, because it's harder to check " ++
                "code that's not contained along those dimensions.\"",
        },
        .{
            .standard = "TigerStyle",
            .text = "\"Declare variables at the **smallest possible scope**, and **minimize the " ++
                "number of variables in scope**, to reduce the probability that variables are " ++
                "misused.\"",
        },
        .{
            .standard = "NASA",
            .text = "NASA P10 Rule 6: \"Data objects must be declared at the smallest possible " ++
                "level of scope.\"",
        },
    },
    .code = "TS043",
    .default_on = false,
    .description = "A binding is declared where it is used and in the block that uses it, so a " ++
        "reader holds one value at a time.",
    .explanation = "",
    .fix_title = "",
    .fixable = .sometimes,
    .group = .stable,
    .name = "declaration-distance",
    .severity = .information,
    .summary = "Declare a variable where it is used",
    .url = "",
};

const Mentions = struct {
    first: u32,
    last: u32,
    named: bool,
};

const Site = struct {
    block: View,
    position: u32,
    statement: View,
};

const comparison_operators = [_][]const u8{ "!=", "!==", "<=", "==", "===", ">=" };
const scope_depth_max: u32 = 8;
const template_hole = "${";

pub fn run(context: *const Context, sink: *Sink) void {
    var blocks = context.views(.block);

    for (0..blocks.remaining) |_| {
        const block = blocks.next() orelse break;

        assert(block.category() == .block);

        if (!holds_statements(block)) continue;

        var children = block.children();

        for (0..children.remaining) |position| {
            const statement = children.next() orelse break;

            assert(statement.index() > block.index());

            const site: Site = .{
                .block = block,
                .position = @intCast(position),
                .statement = statement,
            };

            measure_statement(context, sink, site);
        }
    }
}

fn holds_statements(block: View) bool {
    assert(block.category() == .block);

    const parent = block.parent() orelse return true;

    assert(parent.index() < block.index());

    return switch (parent.category()) {
        .file, .@"struct" => false,
        else => true,
    };
}

fn measure_statement(context: *const Context, sink: *Sink, site: Site) void {
    assert(site.statement.index() > site.block.index());
    assert(site.statement.span().end() <= context.source.len);

    if (site.statement.as_declaration()) |declaration| {
        measure_declaration(context, sink, site, declaration);

        return;
    }

    if (site.statement.category() != .declaration) return;

    var children = site.statement.children_of(.declaration);

    for (0..children.remaining) |_| {
        const child = children.next() orelse break;

        if (child.as_declaration()) |declaration| {
            measure_declaration(context, sink, site, declaration);

            continue;
        }

        var grandchildren = child.children_of(.declaration);

        for (0..grandchildren.remaining) |_| {
            const grandchild = grandchildren.next() orelse break;
            const declaration = grandchild.as_declaration() orelse continue;

            measure_declaration(context, sink, site, declaration);
        }
    }
}

fn measure_declaration(
    context: *const Context,
    sink: *Sink,
    site: Site,
    declaration: Declaration,
) void {
    var leading = declaration.names();
    const named = leading.next() orelse return;
    const name = context.front_text(named);

    assert(named < context.front.tokens().len);
    assert(name.len > 0);

    if (support.names_the_discard(context, name)) return;
    if (declares_a_body(site.statement)) return;
    if (names_a_constant(name)) return;
    if (support.names_the_data_model(context, name)) return;
    if (shape.names_a_type(context, name)) return;

    const boundary = names_end_of(context, declaration);
    if (!may_report(context, site, declaration, boundary)) return;
    if (holds_a_literal(context, declaration)) return;

    var names = declaration.names();
    var nearest: ?u32 = null;
    var shared: ?View = null;
    var split = false;

    for (0..names.remaining()) |_| {
        const held = names.next() orelse break;
        const text = name_measured(context, site, declaration, held) orelse continue;
        const distance = distance_to_use(context, site, text) orelse continue;

        nearest = @min(nearest orelse distance, distance);

        if (split) continue;

        const scope = confined_to_a_block(context, site, text) orelse {
            split = true;

            continue;
        };

        if (shared) |first| {
            if (first.index() != scope.index()) split = true;
        } else {
            shared = scope;
        }
    }

    if (split) {
        report_a_distance(context, sink, named, nearest);

        return;
    }

    const scope = shared orelse return;

    report_the_scope(context, sink, site, declaration, scope);
}

fn name_measured(
    context: *const Context,
    site: Site,
    declaration: Declaration,
    held: u32,
) ?[]const u8 {
    const text = context.front_text(held);

    assert(held < context.front.tokens().len);
    assert(text.len > 0);

    if (names_end_of(context, declaration)) |end| {
        if (context.front_token(held).offset >= end) return null;
    }

    if (support.names_the_discard(context, text)) return null;

    if (declaration.value()) |value| {
        if (snapshots_a_read(context, site, value, text)) return null;
    }

    return text;
}

fn report_the_scope(
    context: *const Context,
    sink: *Sink,
    site: Site,
    declaration: Declaration,
    scope: View,
) void {
    var names = declaration.names();

    assert(scope.index() > site.block.index());

    for (0..names.remaining()) |_| {
        const held = names.next() orelse break;
        const text = name_measured(context, site, declaration, held) orelse continue;
        if (distance_to_use(context, site, text) == null) continue;

        report_a_scope(context, sink, held, scope);
    }
}

fn report_a_scope(context: *const Context, sink: *Sink, named: u32, scope: View) void {
    const line = context.line_of(scope.span().offset) + 1;

    assert(line >= 1);
    assert(named < context.front.tokens().len);

    sink.report_formatted(
        context.front_token(named).span(),
        "the binding is used only inside the block that opens on line {d}; declare it inside " ++
            "that block",
        .{line},
    );
}

fn report_a_distance(context: *const Context, sink: *Sink, named: u32, nearest: ?u32) void {
    const distance = nearest orelse return;
    const allowed = context.settings.thresholds.declaration_distance_max;
    if (distance <= allowed) return;

    assert(distance >= 1);
    assert(named < context.front.tokens().len);

    sink.report_formatted(
        context.front_token(named).span(),
        "the binding is declared {d} statements before it is used, not counting declarations, " ++
            "over the {d} allowed",
        .{ distance, allowed },
    );
}

fn names_end_of(context: *const Context, declaration: Declaration) ?u32 {
    if (declaration.value()) |value| {
        const valued = value.span().offset;

        assert(valued >= declaration.view.span().offset);

        if (!context.conventions.declarations_spell_types_after_names) return valued;

        const listed = names_listed_end(context, declaration) orelse return valued;

        assert(listed >= declaration.view.span().offset);

        return @min(listed, valued);
    }

    if (declaration.type_of()) |type_of| return type_of.span().offset;
    return names_listed_end(context, declaration);
}

fn names_listed_end(context: *const Context, declaration: Declaration) ?u32 {
    const tokens = context.tokens_in(declaration.view.span());
    var expecting_a_name = true;

    assert(tokens.len <= context.tokens.len);

    for (tokens, 0..) |token, index| {
        switch (token.kind) {
            .comment, .keyword, .newline => continue,
            else => {},
        }

        if (expecting_a_name) {
            if (token.kind == .identifier) {
                const after = index + 1;
                const continued = after < tokens.len and tokens[after].is_punctuation(.comma);
                if (!continued) return token.end();

                expecting_a_name = false;

                continue;
            }
        }

        if (token.is_punctuation(.comma)) {
            expecting_a_name = true;

            continue;
        }

        assert(token.offset >= declaration.view.span().offset);

        return token.offset;
    }

    return null;
}

fn may_report(context: *const Context, site: Site, declaration: Declaration, boundary: ?u32) bool {
    const allowed = context.settings.thresholds.declaration_distance_max;
    var names = declaration.names();

    assert(site.position < site.block.children().remaining);

    for (0..names.remaining()) |_| {
        const held = names.next() orelse return false;

        if (boundary) |end| {
            if (context.front_token(held).offset >= end) continue;
        }

        const text = context.front_text(held);

        assert(text.len > 0);

        if (support.names_the_discard(context, text)) continue;
        if (confined_to_a_block(context, site, text) != null) return true;

        const distance = distance_to_use(context, site, text) orelse continue;
        if (distance > allowed) return true;
    }

    return false;
}

fn holds_a_literal(context: *const Context, declaration: Declaration) bool {
    if (!declaration.is_constant()) return false;

    const value = declaration.value() orelse return false;
    const tokens = context.tokens_in(value.span());

    assert(tokens.len <= context.tokens.len);
    assert(value.span().end() <= context.source.len);

    if (tokens.len == 0) return false;

    for (tokens, 0..) |token, index| {
        const text = context.text(token);

        switch (token.kind) {
            .block_end, .block_start, .comment, .newline, .number => continue,
            .string => if (std.mem.startsWith(u8, text, template_hole)) return false,
            .punctuation => if (token.is_punctuation(.paren_open)) return false,
            .keyword => if (!token.is_keyword(.constant)) return false,
            .identifier => {
                if (support.is_literal_constant(text)) continue;
                if (support.is_primitive_type(context, text)) continue;
                if (support.names_the_discard(context, text)) continue;
                if (index == 0) return false;
                if (!tokens[index - 1].is_punctuation(.dot)) return false;
            },
        }
    }

    return true;
}

fn snapshots_a_read(context: *const Context, site: Site, value: View, name: []const u8) bool {
    var children = site.block.children();

    assert(name.len > 0);
    assert(value.span().end() <= context.source.len);

    for (0..children.remaining) |offset| {
        const statement = children.next() orelse return false;

        if (offset <= site.position) continue;
        if (scan.find_word(statement.text(context.source), name)) return false;

        const target = assignment_target(context, statement) orelse continue;
        if (reads_the_path(context, value, target)) return true;
    }

    return false;
}

fn assignment_target(context: *const Context, statement: View) ?[]const u8 {
    const tokens = context.tokens_in(statement.span());
    const start = dereferences_of(tokens);
    const last = path_last_at(context, tokens, start) orelse return null;
    const target = context.source[tokens[start].offset..tokens[last].end()];

    assert(last >= start);
    assert(target.len > 0);

    switch (statement.category()) {
        .assignment => return target,
        .expression => {},
        else => return null,
    }

    if (last + 1 >= tokens.len) return null;
    if (!compounds_an_assignment(context, tokens[last + 1])) return null;
    return target;
}

fn compounds_an_assignment(context: *const Context, token: scylla.Token) bool {
    if (!token.is_punctuation(.other)) return false;

    const text = context.text(token);

    assert(text.len == token.length);

    if (text.len < 2) return false;
    if (text[text.len - 1] != '=') return false;
    return !scan.word_in(&comparison_operators, text);
}

fn dereferences_of(tokens: []const scylla.Token) u32 {
    var count: u32 = 0;

    for (tokens) |token| {
        if (!token.is_punctuation(.star)) break;

        count += 1;
    }

    assert(count <= tokens.len);
    assert(count == tokens.len or !tokens[count].is_punctuation(.star));

    return count;
}

fn reads_the_path(context: *const Context, value: View, target: []const u8) bool {
    const tokens = context.tokens_in(value.span());

    assert(target.len > 0);
    assert(tokens.len <= context.tokens.len);

    for (tokens, 0..) |token, index| {
        if (token.kind != .identifier) continue;

        if (index > 0) {
            if (tokens[index - 1].is_punctuation(.dot)) continue;
        }

        const read = path_at(context, tokens, @intCast(index)) orelse continue;
        if (paths_overlap(read, target)) return true;
    }

    return false;
}

fn path_at(context: *const Context, tokens: []const scylla.Token, start: u32) ?[]const u8 {
    const last = path_last_at(context, tokens, start) orelse return null;

    assert(last >= start);
    assert(last < tokens.len);

    return context.source[tokens[start].offset..tokens[last].end()];
}

fn path_last_at(context: *const Context, tokens: []const scylla.Token, start: u32) ?u32 {
    if (start >= tokens.len) return null;
    if (tokens[start].kind != .identifier) return null;

    var last = start;

    for (0..tokens.len) |_| {
        if (last + 2 >= tokens.len) break;
        if (!tokens[last + 1].is_punctuation(.dot)) break;
        if (!std.mem.eql(u8, context.text(tokens[last + 1]), ".")) break;
        if (tokens[last + 2].kind != .identifier) break;

        last += 2;
    }

    assert(last >= start);
    assert(last < tokens.len);

    return last;
}

fn paths_overlap(left: []const u8, right: []const u8) bool {
    assert(left.len > 0);
    assert(right.len > 0);

    const shorter = if (left.len <= right.len) left else right;
    const longer = if (left.len <= right.len) right else left;
    if (!std.mem.startsWith(u8, longer, shorter)) return false;
    if (longer.len == shorter.len) return true;
    return longer[shorter.len] == '.';
}

fn names_a_constant(name: []const u8) bool {
    var letters: u32 = 0;

    assert(name.len > 0);

    for (name) |byte| {
        if (std.ascii.isLower(byte)) return false;

        if (std.ascii.isUpper(byte)) letters += 1;
    }

    assert(letters <= name.len);

    return letters > 1;
}

fn declares_a_body(statement: View) bool {
    var children = statement.children();

    assert(statement.parent() != null);

    for (0..children.remaining) |_| {
        const child = children.next() orelse return false;

        assert(child.index() > statement.index());

        if (is_a_body(child)) return true;
        if (child.category() != .declaration) continue;
        if (holds_a_body(child)) return true;
    }

    return false;
}

fn holds_a_body(declarator: View) bool {
    var children = declarator.children();

    assert(declarator.category() == .declaration);

    for (0..children.remaining) |_| {
        const child = children.next() orelse return false;

        assert(child.index() > declarator.index());

        if (is_a_body(child)) return true;
    }

    return false;
}

fn is_a_body(view: View) bool {
    return switch (view.category()) {
        .function, .lambda => true,
        else => false,
    };
}

fn distance_to_use(context: *const Context, site: Site, name: []const u8) ?u32 {
    var children = site.block.children();
    var distance: u32 = 0;

    assert(name.len > 0);

    for (0..children.remaining) |offset| {
        const statement = children.next() orelse return null;

        if (offset <= site.position) continue;

        switch (statement.category()) {
            .attribute, .block, .declaration => {},
            else => distance += 1,
        }

        if (scan.find_word(statement.text(context.source), name)) return @max(distance, 1);

        assert(distance <= offset);
    }

    return null;
}

fn confined_to_a_block(context: *const Context, site: Site, name: []const u8) ?View {
    if (mentioned_after_the_block(context, site, name)) return null;

    var children = site.block.children();
    var holder: ?View = null;
    var interpolated = false;
    var mentions: Mentions = .{ .first = std.math.maxInt(u32), .last = 0, .named = false };

    for (0..children.remaining) |offset| {
        const statement = children.next() orelse break;

        if (offset <= site.position) continue;

        const found = mentions_in(context, statement, name) orelse continue;

        if (holder != null) return null;
        if (interpolated) return null;

        if (!found.named) {
            interpolated = true;

            continue;
        }

        holder = statement;
        mentions = found;
    }

    const held = holder orelse return null;

    assert(mentions.first < mentions.last);
    assert(held.index() > site.block.index());

    switch (held.category()) {
        .block, .branch, .match, .@"try" => {},
        else => return null,
    }

    return block_holding(held, mentions);
}

fn mentioned_after_the_block(context: *const Context, site: Site, name: []const u8) bool {
    assert(name.len > 0);

    if (!context.conventions.bindings_outlive_blocks) return false;

    const function = site.block.ancestor_of(.function) orelse return false;
    const start = site.block.span().end();
    const end = function.span().end();
    if (end <= start) return false;

    const rest: Span = .{ .length = end - start, .offset = start };
    return mentions_in_span(context, rest, name) != null;
}

fn mentions_in(context: *const Context, statement: View, name: []const u8) ?Mentions {
    return mentions_in_span(context, statement.span(), name);
}

fn mentions_in_span(context: *const Context, span: Span, name: []const u8) ?Mentions {
    var first: ?u32 = null;
    var last: ?u32 = null;
    var named = false;

    assert(name.len > 0);

    for (context.tokens_in(span)) |token| {
        const text = context.text(token);

        const mentioned = switch (token.kind) {
            .identifier => std.mem.eql(u8, text, name),
            .string => interpolates(text, name),
            else => false,
        };

        const pieced = token.kind == .string and std.mem.eql(u8, text, name);

        if (!mentioned) {
            if (!pieced) continue;
        }

        if (mentioned) named = true;
        if (first == null) first = token.offset;

        last = token.end();
    }

    const opens = first orelse return null;
    const closes = last orelse return null;

    assert(opens < closes);

    return .{ .first = opens, .last = closes, .named = named };
}

fn interpolates(text: []const u8, name: []const u8) bool {
    assert(name.len > 0);

    var cursor: usize = 0;

    for (0..text.len) |_| {
        const found = std.mem.findPos(u8, text, cursor, name) orelse return false;
        const end = found + name.len;

        assert(end <= text.len);

        cursor = end;

        if (found == 0) continue;
        if (end == text.len) continue;
        if (text[found - 1] != '{') continue;

        if (found >= 2) {
            if (text[found - 2] == '{') continue;
        }

        if (text[end] == '}') return true;
        if (text[end] == ':') return true;
    }

    return false;
}

fn block_holding(holder: View, mentions: Mentions) ?View {
    var current = holder;

    assert(mentions.first < mentions.last);

    for (0..scope_depth_max) |_| {
        const child = covering_child(current, mentions) orelse return innermost(current);

        assert(child.index() > current.index());

        switch (child.category()) {
            .block => return child,
            .branch, .match, .@"try" => {},
            else => return innermost(current),
        }

        current = child;
    }

    return null;
}

fn covering_child(view: View, mentions: Mentions) ?View {
    var children = view.children();

    for (0..children.remaining) |_| {
        const child = children.next() orelse return null;
        const span = child.span();

        assert(child.index() > view.index());

        if (span.offset > mentions.first) continue;
        if (mentions.last > span.end()) continue;

        assert(span.length > 0);

        return child;
    }

    return null;
}

fn innermost(view: View) ?View {
    if (view.category() != .block) return null;
    if (view.holds(.block)) return null;

    assert(view.index() > 0);
    assert(view.parent() != null);

    return view;
}

fn expect_one(language: scylla.Language, source: []const u8, wanted: ?[]const u8) !void {
    var findings = try testing.analyze(@This(), language, source);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());

    if (wanted) |text| {
        try std.testing.expect(std.mem.find(u8, findings.message(0), text) != null);
    }
}

test "a discard carries no declaration distance" {
    const source = "package main\n\nfunc run() {\n\t_, err := call()\n\tif err != nil {\n\t\t" ++
        "return\n\t}\n\n\tfirst()\n\tsecond()\n\tthird()\n\tfourth()\n\tfifth()\n\t" ++
        "_ = sixth()\n}\n";

    try testing.expect_quiet(@This(), .go, source);
}

test "a named binding still carries its distance" {
    const source = "package main\n\nfunc run() {\n\theld, extra := 1, 2\n\n\tfirst()\n\t" ++
        "second()\n\tthird()\n\tfourth()\n\tfifth()\n\tsixth()\n\t_ = held\n\t_ = " ++
        "extra\n}\n";

    try expect_one(.go, source, null);
}

test "a binding used only inside one block is reported" {
    const source = "fn run(flag: bool, value: u32) {\n    let held = value;\n\n    if flag {\n" ++
        "work(held);\n    }\n}\n";

    try expect_one(.rust, source, "declare it inside");
}

test "a python binding used after its block is not confined to a nested block" {
    const after = "def run(socket, telemetry):\n    with operation():\n" ++
        "        result = solve(socket)\n        if telemetry is not None:\n" ++
        "            telemetry.values = result.values\n    if result.errors:\n" ++
        "        raise Error(result.errors)\n";

    const inside = "def run(socket, telemetry):\n    with operation():\n" ++
        "        result = solve(socket)\n        if telemetry is not None:\n" ++
        "            telemetry.values = result.values\n    finish()\n";

    try testing.expect_quiet(@This(), .python, after);
    try expect_one(.python, inside, "declare it inside");
}

test "a binding used in the condition is not confined" {
    const source = "fn run(value: u32) {\n    let held = value;\n\n    if held > 0 {\n        " ++
        "work(1);\n    }\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
}

test "a pair whose names land in the condition and the block is not confined" {
    const source = "fn run(pairs: &[(u32, u32)]) {\n    let (index, value) = pairs[0];\n" ++
        "    if index > 0 {\n        work(value);\n    }\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
}

test "a pair whose names are both used inside one block is reported for each" {
    const source = "fn run(flag: bool, pairs: &[(u32, u32)]) {\n    let (index, value) = " ++
        "pairs[0];\n    if flag {\n        work(index, value);\n    }\n}\n";

    var findings = try testing.analyze(@This(), .rust, source);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 2), findings.count());
    try std.testing.expect(std.mem.find(u8, findings.message(0), "declare it inside") != null);
    try std.testing.expect(std.mem.find(u8, findings.message(1), "declare it inside") != null);
}

test "an attribute on a statement adds no distance" {
    const source = "fn run(value: u32) {\n    let held = value;\n    first();\n    second();\n" ++
        "    #[cfg(feature = \"x\")]\n    third();\n    fourth();\n    work(held);\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
}

test "a use six statements away past an attribute is over the distance" {
    const source = "fn run(value: u32) {\n    let held = value;\n    first();\n    second();\n" ++
        "    #[cfg(feature = \"x\")]\n    third();\n    fourth();\n    fifth();\n" ++
        "    work(held);\n}\n";

    try expect_one(.rust, source, "declared 6 statements before");
}

test "the type of a typed declaration with a value is not one of its names" {
    const source = "package main\n\nfunc run(flag bool) {\n\tvar held int64 = -1\n\tif flag {\n" ++
        "\t\twork(int64(held))\n\t}\n}\n";

    try testing.expect_anchors(@This(), .go, source, &.{.{ 4, 6 }});
}

test "a snapshot read through a dereference stays where it reads" {
    const snapshot = "fn run(atlas: &[A], current: &mut usize, flag: bool) {\n    let held = " ++
        "atlas[*current].gles;\n    *current += 1;\n    if flag {\n        work(held);\n" ++
        "    }\n}\n";

    const unwritten = "fn run(atlas: &[A], current: &mut usize, flag: bool) {\n    let held = " ++
        "atlas[*current].gles;\n    if flag {\n        work(held);\n    }\n}\n";

    try testing.expect_quiet(@This(), .rust, snapshot);
    try expect_one(.rust, unwritten, "declare it inside");
}

test "a binding a format string reads outside the block is not confined" {
    const before = "fn run(flag: bool, value: u32) {\n    let held = value;\n" ++
        "    print!(\"{held}\");\n    if flag {\n        work(held);\n    }\n}\n";

    const arms = "fn run(flag: bool, value: u32) {\n    let held = value;\n    if flag {\n" ++
        "        work(held);\n    } else {\n        print!(\"{held:?}\");\n    }\n}\n";

    const escaped = "fn run(flag: bool, value: u32) {\n    let held = value;\n" ++
        "    print!(\"{{held}}\");\n    if flag {\n        work(held);\n    }\n}\n";

    try testing.expect_quiet(@This(), .rust, before);
    try testing.expect_quiet(@This(), .rust, arms);
    try expect_one(.rust, escaped, "declare it inside");
}

test "a name a python f-string interpolates in the other arm is not confined" {
    const arms = "def emit(op, obj, flag):\n    cast = f\"({op.name} *)\"\n    if flag:\n" ++
        "        line = f\"({cast}{obj})->vtable\"\n        return line\n    else:\n" ++
        "        return work(cast)\n";

    const confined = "def emit(op, obj, flag):\n    cast = f\"({op.name} *)\"\n    if flag:\n" ++
        "        return 1\n    else:\n        return work(cast)\n";

    try testing.expect_quiet(@This(), .python, arms);
    try expect_one(.python, confined, "declare it inside");
}

test "a python name the data model reads is no local binding" {
    const exports = "import sys\n\nif sys.platform != \"win32\":\n    __all__ = [\"setraw\"]\n" ++
        "    if sys.version_info >= (3, 12):\n        __all__ += [\"cfmakeraw\"]\n";

    const local = "import sys\n\nif sys.platform != \"win32\":\n    names = [\"setraw\"]\n" ++
        "    if sys.version_info >= (3, 12):\n        names += [\"cfmakeraw\"]\n";

    try testing.expect_quiet(@This(), .python, exports);
    try expect_one(.python, local, "declare it inside");
}

test "a binding used only inside a loop is not confined" {
    const source = "fn run(value: u32) {\n    let held = value;\n\n    for index in 0..4 {\n" ++
        "work(held, index);\n    }\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
}

test "a binding whose value is a call is measured" {
    const source = "fn run(value: u32) -> u32 {\n    let first = read(value);\n\n    " ++
        "work(value);\n    work(value);\n    work(value);\n    work(value);\n    " ++
        "work(value);\n    work(value);\n\n    first\n}\n";

    try expect_one(.rust, source, null);
}

test "a javascript arrow function bound by const is a definition" {
    const source = "function run(value) {\n    const helper = item => item.x;\n" ++
        "    const held = compute((item) => item.x);\n\n    work(value);\n    work(value);\n" ++
        "    work(value);\n    work(value);\n    work(value);\n    work(value);\n\n" ++
        "    return helper(held);\n}\n";

    try expect_one(.javascript, source, null);
}

test "a declaration inside a nested block is measured against its siblings" {
    const source = "fn run(flag: bool, value: u32) -> u32 {\n    if flag {\n        let first = " ++
        "value;\n\n        work(value);\n        work(value);\n        work(value);\n" ++
        "work(value);\n        work(value);\n        work(value);\n\n        return " ++
        "first;\n    }\n\n    0\n}\n";

    try expect_one(.rust, source, null);
}

test "a go declaration without an initializer is measured" {
    const source = "package main\n\nfunc run(value int) int {\n\tvar held int\n\n\t" ++
        "report(value)\n\treport(value)\n\treport(value)\n\treport(value)\n\t" ++
        "report(value)\n\treport(value)\n\n\theld = value\n\n\treturn held\n}\n";

    try expect_one(.go, source, null);
}

test "a constant holding a literal is a constant whatever its case" {
    const source = "fn curve(x: f64) f64 {\n    const scale: f64 = 6.666e-1;\n" ++
        "    const names = [_][]const u8{ \"a\", \"b\" };\n    var total = x;\n\n" ++
        "    work(x);\n    work(x);\n    work(x);\n    work(x);\n    work(x);\n    work(x);\n\n" ++
        "    total += scale * x;\n\n    return total + names.len;\n}\n";

    try testing.expect_anchors(@This(), .zig, source, &.{.{ 4, 9 }});
}

test "a template with a hole reads a name rather than holding a literal" {
    const source = "function render(code: string): string {\n" ++
        "    const text = `run ${code}`;\n    const plain = `run`;\n\n" ++
        "    work();\n    work();\n    work();\n    work();\n    work();\n    work();\n\n" ++
        "    if (code.length > 0) {\n        return text + plain;\n    }\n\n    return code;\n}\n";

    try testing.expect_anchors(@This(), .typescript, source, &.{.{ 2, 11 }});
}

test "a snapshot of state written before its use stays where it reads" {
    const source = "fn next(prng: *Prng) u64 {\n    const result = prng.state[0] +% 1;\n\n" ++
        "    prng.state[0] ^= prng.state[1];\n\n    if (prng.ready) {\n" ++
        "        return result;\n    }\n\n    return 0;\n}\n";

    try testing.expect_quiet(@This(), .zig, source);
}
