const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const scan = @import("../../scan.zig");
const testing = @import("../testing.zig");
const Call = scylla.View.Call;
const Context = @import("../context.zig");
const Rule = scylla.rule.Rule;
const Sink = scylla.rule.Sink;
const TestScope = @import("../test_scope.zig");
const View = scylla.View;

pub const rule: Rule = .{
    .citations = &.{
        .{
            .standard = "TigerStyle",
            .text = "\"Put a limit on everything because, in reality, this is what we expect " ++
                "[...] everything has a limit. For example, all loops and all queues must have " ++
                "a fixed upper bound to prevent infinite loops or tail latency spikes.\"",
        },
    },
    .code = "TS056",
    .default_on = false,
    .description = "A queue carries a fixed capacity, so a producer that outruns its consumer " ++
        "fails at the bound rather than growing without limit.",
    .explanation = "",
    .fix_title = "",
    .fixable = .never,
    .group = .stable,
    .name = "bounded-queues",
    .severity = .warning,
    .summary = "A queue must have a fixed upper bound",
    .url = "",
};

const generic_marker = "::<";
const one_value_paths = [_][]const u8{ "oneshot", "watch" };
const path_separator = "::";
const pointer_qualifier = "const";
const queue_argument_max: u32 = 8;
const queue_qualifier_max: u32 = 4;

pub fn run(context: *const Context, sink: *Sink) void {
    const names = context.conventions.queue_unbounded_names;
    if (names.len == 0) return;

    assert(names.len > 0);

    var calls = context.views(.call);

    for (0..calls.remaining) |_| {
        const view = calls.next() orelse break;
        const call = view.as_call() orelse continue;
        const span = view.span();
        const callee = call.callee() orelse continue;

        assert(callee.index() > view.index());

        if (std.mem.findScalar(u8, callee.text(context.source), '(') != null) continue;
        if (calls_a_method(call, callee)) continue;

        const start = head_start(context, span.offset);
        const qualified = context.source[start..callee.span().end()];
        if (!names_a_queue(names, qualified)) continue;
        if (declared_in_the_file(context, qualified)) continue;
        if (TestScope.holds(context, span.offset)) continue;
        if (bounded_by_an_argument(context, call, qualified)) continue;
        if (holds_one_value(qualified)) continue;
        if (behind_a_pointer(context, start)) continue;

        sink.report(span, "the queue has no upper bound; give it a fixed capacity");
    }
}

fn head_start(context: *const Context, offset: u32) u32 {
    const tokens = context.tokens;

    var index = context.lexer_index_from(offset);

    for (0..queue_qualifier_max) |_| {
        if (index < 2) break;
        if (!tokens[index - 1].is_punctuation(.dot)) break;
        if (tokens[index - 2].kind != .identifier) break;

        index -= 2;
    }

    const start = if (index < tokens.len) @min(tokens[index].offset, offset) else offset;

    assert(start <= offset);
    assert(start <= context.source.len);

    return start;
}

fn calls_a_method(call: Call, callee: View) bool {
    assert(callee.index() > call.view.index());

    const receiver = call.receiver() orelse return false;

    assert(std.meta.activeTag(receiver) == std.meta.activeTag(callee));

    return receiver.index() == callee.index();
}

fn declared_in_the_file(context: *const Context, qualified: []const u8) bool {
    const name = generics_stripped(qualified);

    assert(name.len <= qualified.len);

    for (context.tables.functions()) |function| {
        if (function.container != null) continue;
        if (std.mem.eql(u8, function.name.text(context.source), name)) return true;
    }

    return false;
}

fn holds_one_value(qualified: []const u8) bool {
    const head = generics_stripped(qualified);
    const separator = std.mem.findLast(u8, head, path_separator) orelse return false;
    const path = head[0..separator];
    const parent = std.mem.findLast(u8, path, path_separator);
    const segment = if (parent) |at| at + path_separator.len else 0;

    assert(segment <= path.len);

    return scan.word_in(&one_value_paths, path[segment..]);
}

fn behind_a_pointer(context: *const Context, start: u32) bool {
    const first = context.lexer_index_from(start);
    var before = context.significant_before(first) orelse return false;

    if (std.mem.eql(u8, context.text(context.tokens[before]), pointer_qualifier)) {
        before = context.significant_before(before) orelse return false;
    }

    assert(before < first);

    return context.tokens[before].is_punctuation(.star);
}

fn names_a_queue(names: []const []const u8, text: []const u8) bool {
    const head = generics_stripped(text);

    assert(head.len <= text.len);

    for (names) |name| {
        assert(name.len > 0);

        if (!std.mem.endsWith(u8, head, name)) continue;

        const prefix = head[0 .. head.len - name.len];
        if (prefix.len == 0) return true;
        if (std.mem.endsWith(u8, prefix, ".")) return true;
        if (std.mem.endsWith(u8, prefix, ":")) return true;
    }

    return false;
}

fn generics_stripped(text: []const u8) []const u8 {
    if (!std.mem.endsWith(u8, text, ">")) return text;

    assert(text.len > 0);

    const at = std.mem.findLast(u8, text, generic_marker) orelse return text;

    assert(at + generic_marker.len <= text.len);

    return text[0..at];
}

fn bounded_by_an_argument(context: *const Context, call: Call, qualified: []const u8) bool {
    const words = context.conventions.queue_bound_words;
    const names_data_first = context.conventions.queue_data_first_names;
    const skipped: u32 = @intFromBool(ends_with_a_name(qualified, names_data_first));

    assert(skipped <= 1);
    assert(qualified.len <= context.source.len);

    var arguments = call.arguments();

    for (0..queue_argument_max) |position| {
        const argument = arguments.next() orelse break;
        const text = scan.trim_ascii(argument.text(context.source));

        assert(text.len <= argument.span().length);

        if (names_a_bound(text, words)) {
            if (std.mem.endsWith(u8, text, "=None")) return false;
            if (!std.mem.endsWith(u8, text, "=0")) return true;
            return names_a_bound(text, context.conventions.queue_zero_bound_words);
        }

        if (words.len > 0) {
            if (names_data_first.len == 0) continue;
        }

        if (position < skipped) continue;
        if (!unbounded(text)) return true;
    }

    return false;
}

fn ends_with_a_name(text: []const u8, names: []const []const u8) bool {
    for (names) |name| {
        assert(name.len > 0);

        if (std.mem.endsWith(u8, text, name)) return true;
    }

    return false;
}

fn names_a_bound(text: []const u8, words: []const []const u8) bool {
    assert(text.len <= std.math.maxInt(u32));

    for (words) |word| {
        assert(word.len > 0);

        if (scan.find_word(text, word)) return true;
    }

    return false;
}

fn unbounded(text: []const u8) bool {
    if (text.len == 0) return true;
    if (std.mem.eql(u8, text, "None")) return true;
    if (std.mem.startsWith(u8, text, ".")) return true;

    assert(text.len > 0);

    for (text) |byte| {
        switch (byte) {
            '0', '_' => {},
            else => return false,
        }
    }

    assert(std.mem.findNone(u8, text, "0_") == null);

    return true;
}

test "a deque capped at zero holds nothing" {
    const source = "def run(items):\n    deque(items, maxlen=0)\n" ++
        "    collections.deque(items, maxlen=0)\n    Queue(maxsize=0)\n" ++
        "    deque(items, maxlen=None)\n";

    var findings = try testing.analyze(@This(), .python, source);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 2), findings.count());
}

test "a queue a pointer names is a queue built elsewhere" {
    const referenced = "const Iterator = struct {\n" ++
        "    queue: *std.PriorityQueue(u32, void, less),\n" ++
        "    held: *const std.PriorityQueue(u32, void, less),\n};\n";

    const built = "fn run(gpa: Allocator) void {\n" ++
        "    var queue = std.PriorityQueue(u32, void, less).init(gpa, {});\n    _ = &queue;\n}\n";

    try testing.expect_quiet(@This(), .zig, referenced);
    try testing.expect_anchors(@This(), .zig, built, &.{.{ 2, 17 }});
}

test "a oneshot channel holds one value" {
    const source = "fn run() {\n    let (tx, rx) = oneshot::channel::<u32>();\n" ++
        "    let (sender, receiver) = mpsc::channel::<u32>();\n}\n";

    try testing.expect_anchors(@This(), .rust, source, &.{.{ 3, 30 }});
}

test "a method of a channel field builds no queue" {
    const source = "impl Pool {\n    fn close(&mut self) {\n" ++
        "        self.channel.as_ref().unwrap().send(1).unwrap();\n" ++
        "        drop(self.channel.take().unwrap());\n" ++
        "        let (sender, receiver) = mpsc::channel();\n    }\n}\n";

    try testing.expect_anchors(@This(), .rust, source, &.{.{ 5, 34 }});
}

test "a function the file declares is no queue constructor" {
    const source = "pub fn channel() -> String {\n    String::new()\n}\n\nfn run() {\n" ++
        "    let name = channel();\n    let (sender, receiver) = mpsc::channel();\n}\n";

    try testing.expect_anchors(@This(), .rust, source, &.{.{ 7, 30 }});
}

test "a watch channel holds one value" {
    const source = "fn run() {\n    let (tx, rx) = crate::sync::watch::channel(0);\n" ++
        "    let (sender, receiver) = std::sync::mpsc::channel();\n}\n";

    try testing.expect_anchors(@This(), .rust, source, &.{.{ 3, 30 }});
}
