const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const testing = @import("../testing.zig");
const Context = @import("../context.zig");
const HandOvers = @import("../hand_overs.zig");
const Rule = scylla.rule.Rule;
const Sink = scylla.rule.Sink;
const View = scylla.View;
const words_module = @import("../../words.zig");

pub const rule: Rule = .{
    .citations = &.{
        .{
            .standard = "TigerStyle",
            .text = "\"When a single function calls out to a helper function or callback, " ++
                "prefix the name of the helper function with the name of the calling function " ++
                "to show the call history. For example, `read_sector()` and " ++
                "`read_sector_callback()`.\"",
        },
    },
    .code = "TS057",
    .default_on = false,
    .description = "A callback is named after the function that hands it over, so the call " ++
        "history reads from the name alone.",
    .explanation = "",
    .fix_title = "",
    .fixable = .never,
    .group = .stable,
    .name = "callback-name-prefix",
    .severity = .information,
    .summary = "Name a callback after its caller: `read_sector_callback` for `read_sector`",
    .url = "",
};

const callback_suffixes = [_][]const u8{ "Callback", "_callback" };

pub fn run(context: *const Context, sink: *Sink) void {
    var functions = context.views(.function);

    for (0..functions.remaining) |_| {
        const node = functions.next() orelse break;
        const held = node.as_function() orelse continue;
        if (held.body() == null) continue;

        const named = name_of(node) orelse continue;
        const name = context.front_text(named);
        const caller = caller_of(name) orelse continue;

        assert(caller.len < name.len);
        assert(std.mem.startsWith(u8, name, caller));

        if (caller.len == 0) continue;
        if (declares_a_function_named(context, caller)) continue;
        if (calls_a_function_named(context, caller)) continue;
        if (helps_directly(context, node)) continue;

        const handing = HandOvers.handing_of(context, node);
        if (handing.count != 1) continue;

        if (handing.owner) |owner| {
            if (opens_with_the_owner(context, name, owner)) continue;
        }

        sink.report(
            context.front_token(named).span(),
            "the callback is not named after a function in this file; prefix it with the name " ++
                "of the function that calls it",
        );
    }
}

fn helps_directly(context: *const Context, node: View) bool {
    assert(node.category() == .function);
    assert(node.span().end() <= context.source.len);

    if (!HandOvers.called_directly(context, node)) {
        if (!called_through_a_member(context, node)) return false;
    }

    return !HandOvers.handed_over(context, node);
}

fn opens_with_the_owner(context: *const Context, name: []const u8, owner: View) bool {
    const named = owner.name_token() orelse return false;
    const prefix = context.front_text(named);

    assert(prefix.len > 0);
    assert(name.len > 0);

    var owner_words = words_module.word_parts(prefix);
    var name_words = words_module.word_parts(name);

    for (0..prefix.len + 1) |_| {
        const word = owner_words.next() orelse return true;
        const opening = name_words.next() orelse return false;
        if (!std.ascii.eqlIgnoreCase(word, opening)) return false;
    }

    unreachable;
}

fn called_through_a_member(context: *const Context, node: View) bool {
    const named = name_of(node) orelse return false;
    const name = context.front_text(named);
    const tokens = context.tokens;

    assert(name.len > 0);

    for (context.token_index.identifiers()) |position| {
        if (position == 0) continue;
        if (position + 1 >= tokens.len) break;
        if (!tokens[position - 1].is_punctuation(.dot)) continue;
        if (!tokens[position + 1].is_punctuation(.paren_open)) continue;
        if (std.mem.eql(u8, context.text(tokens[position]), name)) return true;
    }

    return false;
}

fn name_of(node: View) ?u32 {
    assert(node.category() == .function);

    const function = node.as_function() orelse return null;
    return function.name_token();
}

fn caller_of(name: []const u8) ?[]const u8 {
    for (callback_suffixes) |suffix| {
        if (!std.mem.endsWith(u8, name, suffix)) continue;

        assert(name.len >= suffix.len);

        const caller = name[0 .. name.len - suffix.len];

        assert(caller.len + suffix.len == name.len);

        return caller;
    }

    return null;
}

fn calls_a_function_named(context: *const Context, caller: []const u8) bool {
    assert(caller.len > 0);

    var calls = context.views(.call);

    for (0..calls.remaining) |_| {
        const call = calls.next() orelse return false;

        assert(call.category() == .call);

        const invoked = call.as_call() orelse continue;
        const target = invoked.callee() orelse continue;
        if (ends_with_the_caller(target.text(context.source), caller)) return true;

        const named = invoked.name_token() orelse continue;
        if (std.mem.eql(u8, context.front_text(named), caller)) return true;
    }

    return false;
}

fn ends_with_the_caller(text: []const u8, caller: []const u8) bool {
    assert(caller.len > 0);

    if (text.len < caller.len) return false;

    const start = text.len - caller.len;

    assert(start + caller.len == text.len);

    for (text[start..], caller) |byte, wanted| {
        if (byte == wanted) continue;
        if (byte != '.') return false;
        if (wanted != '_') return false;
    }

    if (start == 0) return true;

    return switch (text[start - 1]) {
        '.', ':' => true,
        else => false,
    };
}

fn declares_a_function_named(context: *const Context, caller: []const u8) bool {
    assert(caller.len > 0);

    var functions = context.views(.function);

    for (0..functions.remaining) |_| {
        const node = functions.next() orelse return false;
        const named = name_of(node) orelse continue;
        if (std.mem.eql(u8, context.front_text(named), caller)) return true;
    }

    return false;
}

test "a callback named after a function in the file is quiet" {
    const source = "fn read_sector() {\n    submit(read_sector_callback);\n}\n\n" ++
        "fn read_sector_callback() {\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
}

test "a callback named after a called function is quiet" {
    const source = "fn run(disk: Disk) {\n    disk.read(write_callback);\n    write();\n}\n\n" ++
        "fn write_callback() {\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
}

test "a callback named after a called method is quiet" {
    const source = "fn run(disk: Disk) {\n    disk.read(write_callback);\n" ++
        "    disk.write();\n}\n\nfn write_callback() {\n}\n";

    try testing.expect_quiet(@This(), .rust, source);
}

test "a function the file only calls is a helper rather than a callback" {
    const called = "fn hooked(at: u32) bool {\n    return hooked_callback(at);\n}\n\n" ++
        "fn hooked_callback(at: u32) bool {\n    return at > 0;\n}\n";

    const handed = "fn run() {\n    submit(flush_callback);\n    flush_callback();\n}\n\n" ++
        "fn flush_callback() {\n}\n";

    try testing.expect_quiet(@This(), .zig, called);

    var findings = try testing.analyze(@This(), .rust, handed);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
}

test "a callback named after nothing in the file is reported" {
    const source = "fn run() {\n    submit(flush_callback);\n}\n\nfn flush_callback() {\n}\n";

    var findings = try testing.analyze(@This(), .rust, source);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
    try std.testing.expect(std.mem.find(u8, findings.message(0), "prefix it") != null);
}

test "an odin procedure type or a foreign declaration declares no function" {
    const source = "package p\n\nBad_Free_Callback :: proc(memory: rawptr)\n\n" ++
        "Tracker :: struct {\n\tcallback: Bad_Free_Callback,\n}\n\n" ++
        "foreign import lib \"system:c\"\n\nforeign lib {\n" ++
        "\tsignal_callback :: proc(code: i32) ---\n}\n\nrun :: proc() {\n" ++
        "\tsubmit(flush_callback)\n\tinstall(signal_callback)\n}\n\n" ++
        "flush_callback :: proc() {\n}\n";

    try testing.expect_anchors(@This(), .odin, source, &.{.{ 20, 1 }});
}

test "a method the file calls through a member is a helper" {
    const source = "const Surface = struct {\n    fn update(surface: *Surface) void {\n" ++
        "        surface.colorSchemeCallback(1);\n    }\n\n" ++
        "    fn colorSchemeCallback(surface: *Surface, scheme: u32) void {\n" ++
        "        _ = surface;\n        _ = scheme;\n    }\n};\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "a method handed over as a value is still a callback" {
    const source = "const Surface = struct {\n    fn update(surface: *Surface) void {\n" ++
        "        register(Surface.colorSchemeCallback);\n        _ = surface;\n    }\n\n" ++
        "    fn colorSchemeCallback(surface: *Surface, scheme: u32) void {\n" ++
        "        _ = surface;\n        _ = scheme;\n    }\n};\n";

    var findings = try testing.analyze(@This(), .zig, source);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
}

test "a callback the file never hands over is out of reach" {
    const source = "const Surface = struct {\n" ++
        "    pub fn sizeCallback(surface: *Surface, size: u32) void {\n" ++
        "        _ = surface;\n        _ = size;\n    }\n};\n";

    try testing.expect_quiet(@This(), .zig, source);
}

test "a callback two functions hand over has no single caller" {
    const several = "fn start(timer: *Timer) void {\n    timer.run(tickCallback);\n}\n\n" ++
        "fn drain(timer: *Timer) void {\n    timer.reset(tickCallback);\n}\n\n" ++
        "fn tickCallback() void {\n}\n";

    const single = "fn start(timer: *Timer) void {\n    timer.run(tickCallback);\n}\n\n" ++
        "fn tickCallback() void {\n}\n";

    try testing.expect_quiet(@This(), .zig, several);

    var findings = try testing.analyze(@This(), .zig, single);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
}

test "a callback that hands itself over still has its one caller" {
    const source = "fn start(timer: *Timer) void {\n    timer.run(tickCallback);\n}\n\n" ++
        "fn tickCallback(timer: *Timer) void {\n    timer.run(tickCallback);\n}\n";

    var findings = try testing.analyze(@This(), .zig, source);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
}

test "a callback named through its anonymous container is handed over" {
    const source = "fn open(grid: *Grid) void {\n    grid.open(struct {\n" ++
        "        fn grid_ready_callback(_: *Grid) void {}\n    }.grid_ready_callback);\n}\n";

    var findings = try testing.analyze(@This(), .zig, source);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
}

test "a callback that opens with the name of its one caller carries the call history" {
    const qualified = "fn scan(tree: *Tree) void {\n" ++
        "    tree.lookup(scan_lookup_callback);\n}\n\nfn scan_lookup_callback() void {}\n";

    const camel = "fn scan(tree: *Tree) void {\n    tree.lookup(scanLookupCallback);\n}\n\n" ++
        "fn scanLookupCallback() void {}\n";

    const unrelated = "fn run_query(tree: *Tree) void {\n" ++
        "    tree.lookup(scan_lookup_callback);\n}\n\nfn scan_lookup_callback() void {}\n";

    try testing.expect_quiet(@This(), .zig, qualified);
    try testing.expect_quiet(@This(), .zig, camel);

    var findings = try testing.analyze(@This(), .zig, unrelated);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
}

test "a callback whose words open with its one caller's words in another case carries it" {
    const returned = "pub fn NoopCallback(comptime T: type) Callback(T) {\n" ++
        "    return (struct {\n        fn noopCallback(_: ?*anyopaque) void {}\n" ++
        "    }).noopCallback;\n}\n";

    const exported = "package fixture\n\nfunc Scan(tree *Tree) {\n" ++
        "\ttree.Lookup(scanLookupCallback)\n}\n\nfunc scanLookupCallback() {\n}\n";

    const unrelated = "pub fn Wrap(comptime T: type) Callback(T) {\n" ++
        "    return (struct {\n        fn noopCallback(_: ?*anyopaque) void {}\n" ++
        "    }).noopCallback;\n}\n";

    try testing.expect_quiet(@This(), .zig, returned);
    try testing.expect_quiet(@This(), .go, exported);

    var findings = try testing.analyze(@This(), .zig, unrelated);
    defer findings.deinit();

    try std.testing.expectEqual(@as(u32, 1), findings.count());
}
