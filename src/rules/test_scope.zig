const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const scan = @import("../scan.zig");
const Context = @import("context.zig");
const Frame = @import("frame.zig");
const Span = scylla.Span;
const View = scylla.View;

reach: TestReach,
state: State,

const TestScope = @This();

pub const State = enum {
    built,
    failed,
    unbuilt,
};

const TestReach = struct {
    count: u32,
    reached: std.bit_set.Static(test_reach_tops_max),
    sorted: bool,
    tops: [test_reach_tops_max]TestTop,

    fn build(reach: *TestReach, context: *const Context) bool {
        reach.count = 0;
        reach.reached = .empty;
        reach.sorted = true;

        if (context.front.bindings().scope_count() == 0) return true;
        if (!reach.collect(context)) return false;

        for (0..test_reach_passes_max) |_| {
            if (!reach.widen(context)) break;
        }

        assert(reach.count <= test_reach_tops_max);
        assert(reach.reached.count() <= reach.count);

        return true;
    }

    fn collect(reach: *TestReach, context: *const Context) bool {
        const bindings = context.front.bindings();

        var scoped = bindings.bindings_of(0);

        for (0..bindings.count()) |_| {
            const index = scoped.next() orelse break;

            assert(index < bindings.count());

            const binding = bindings.at(index);

            switch (binding.class) {
                .constant, .function, .type => {},
                .field, .import, .local, .method, .other, .parameter, .variant => continue,
            }

            if (binding.node >= context.front.node_count()) continue;
            if (reach.count == test_reach_tops_max) return false;

            const span = context.view(binding.node).span();

            if (reach.count > 0) {
                if (span.offset < reach.tops[reach.count - 1].span.offset) reach.sorted = false;
            }

            reach.tops[reach.count] = .{ .binding = index, .span = span };
            reach.count += 1;
        }

        assert(reach.count <= test_reach_tops_max);

        return true;
    }

    fn widen(reach: *TestReach, context: *const Context) bool {
        var widened = false;

        assert(reach.count <= test_reach_tops_max);

        for (reach.tops[0..reach.count], 0..) |top, position| {
            if (reach.reached.isSet(position)) continue;
            if (Context.declares_publicly(context, top.binding)) continue;
            if (!reach.referenced_from_tests(context, top)) continue;

            reach.reached.set(position);
            widened = true;
        }

        assert(reach.reached.count() <= reach.count);

        return widened;
    }

    fn referenced_from_tests(reach: *const TestReach, context: *const Context, top: TestTop) bool {
        const bindings = context.front.bindings();

        assert(top.binding < bindings.count());
        assert(top.span.end() <= context.source.len);

        var references = bindings.references_of(top.binding);
        var referenced = false;

        for (0..bindings.reference_count()) |_| {
            const reference = references.next() orelse return referenced;
            const at = reference.name.offset;
            if (top.span.contains(at)) continue;
            if (!reach.tested_at(context, at)) return false;

            referenced = true;
        }

        return referenced;
    }

    fn tested_at(reach: *const TestReach, context: *const Context, offset: u32) bool {
        assert(offset <= context.source.len);
        assert(reach.count <= test_reach_tops_max);

        if (reach.covers(offset)) return true;
        return inside_a_test_body(context, offset);
    }

    fn covers(reach: *const TestReach, offset: u32) bool {
        assert(reach.count <= test_reach_tops_max);

        const position = reach.top_at(offset) orelse return false;

        assert(position < reach.count);

        return reach.reached.isSet(position);
    }

    fn top_at(reach: *const TestReach, offset: u32) ?u32 {
        assert(reach.count <= test_reach_tops_max);

        const tops = reach.tops[0..reach.count];

        if (!reach.sorted) {
            for (tops, 0..) |top, position| {
                if (top.span.contains(offset)) return @intCast(position);
            }

            return null;
        }

        const after = std.sort.partitionPoint(TestTop, tops, offset, TestTop.starts_by);

        assert(after <= tops.len);

        if (after == 0) return null;
        if (!tops[after - 1].span.contains(offset)) return null;
        return @intCast(after - 1);
    }
};

const TestTop = struct {
    binding: u32,
    span: Span,

    fn starts_by(offset: u32, top: TestTop) bool {
        return top.span.offset <= offset;
    }
};

pub const unbuilt: TestScope = .{ .reach = undefined, .state = .unbuilt };
const fixture_directories = [_][]const u8{ ".snapshots", "__snapshots__", "snapshots", "testdata" };
const fixture_roots = [_][]const u8{ "__tests__", "spec", "test", "tests" };
const test_attributes = [_][]const u8{ "#[test]", "@(test)", "cfg(test)" };
const test_calls = [_][]const u8{ "bench", "describe", "it", "test" };

const test_directories = [_][]const u8{
    "__tests__",
    "bench",
    "benches",
    "benchmarks",
    "spec",
    "test",
    "tests",
};

const test_file_markers = [_][]const u8{ ".test.", ".spec." };
const test_file_suffixes = [_][]const u8{ "_test.go", "_test.py", "_test.zig", "_test.odin" };
const test_function_prefixes = [_][]const u8{ "Benchmark", "Test", "bench", "test" };
const test_module_extension = ".py";
const test_module_prefix = "test_";
const test_reach_passes_max: u32 = 16;
const test_reach_tops_max: u32 = 1_024;
const test_support_directories = [_][]const u8{"testing"};
const test_word = "test";

pub fn covers(scope: *TestScope, context: *const Context, offset: u32) bool {
    assert(offset <= context.source.len);

    if (names_a_test_path(context.path)) return true;
    if (names_a_test_support_path(context.path)) return true;
    if (inside_a_test_body(context, offset)) return true;
    if (!context.conventions.declarations_spell_visibility) return false;

    if (scope.state == .unbuilt) {
        scope.state = if (scope.reach.build(context)) .built else .failed;
    }

    assert(scope.state != .unbuilt);

    if (scope.state == .failed) return false;
    return scope.reach.covers(offset);
}

pub fn holds(context: *const Context, offset: u32) bool {
    var scope: TestScope = .unbuilt;

    assert(offset <= context.source.len);

    const covered = scope.covers(context, offset);

    if (scope.state == .unbuilt) {
        assert(covered or !context.conventions.declarations_spell_visibility);
    }

    return covered;
}

pub fn file_is_a_fixture(context: *const Context) bool {
    if (names_a_fixture_path(context.path)) return true;
    if (!path_holds_a_segment(context.path, &fixture_roots)) return false;
    return !file_holds_a_test(context);
}

pub fn nests_a_test(context: *const Context, token: u32) bool {
    assert(token < context.tokens.len);

    var frames = Frame.covering(context, token);

    for (0..context.front.node_count()) |_| {
        const covering = frames.next() orelse return false;

        assert(covering.frame.covers(token));

        if (covering.view.category() != .function) continue;
        if (std.mem.eql(u8, covering.frame.opening_word(context), test_word)) return true;
    }

    return false;
}

fn names_a_fixture_path(path: []const u8) bool {
    const named = path_holds_a_segment(path, &fixture_directories);

    if (named) assert(path.len > 0);

    return named;
}

fn file_holds_a_test(context: *const Context) bool {
    for (test_attributes) |marker| {
        if (scan.find(context.source, marker) != null) return true;
    }

    for (Context.callable_categories) |category| {
        for (context.front.nodes_of(category)) |position| {
            const function = context.view(position);

            assert(function.category() == category);

            if (tests_by_name(context, function)) return true;
            if (runs_as_a_test_callback(context, function)) return true;
        }
    }

    return false;
}

fn names_a_test_path(path: []const u8) bool {
    if (path_holds_a_segment(path, &test_directories)) return true;

    const file = scylla.path.file_name(path);

    assert(file.len <= path.len);
    assert(std.mem.findScalar(u8, file, '/') == null);

    for (test_file_suffixes) |suffix| {
        if (std.mem.endsWith(u8, file, suffix)) return true;
    }

    if (std.mem.startsWith(u8, file, test_module_prefix)) {
        if (std.mem.endsWith(u8, file, test_module_extension)) return true;
    }

    for (test_file_markers) |marker| {
        if (scan.find(file, marker) != null) return true;
    }

    return false;
}

fn names_a_test_support_path(path: []const u8) bool {
    const named = path_holds_a_segment(path, &test_support_directories);

    if (named) assert(path.len > 0);

    return named;
}

fn path_holds_a_segment(path: []const u8, comptime directories: []const []const u8) bool {
    comptime assert(directories.len > 0);

    var segments = scylla.path.segments(path);

    for (0..path.len + 1) |_| {
        const segment = segments.next() orelse return false;

        assert(segment.len > 0);

        if (scan.word_in(directories, segment)) return true;
    }

    return false;
}

fn inside_a_test_body(context: *const Context, offset: u32) bool {
    assert(offset <= context.source.len);

    if (inside_a_test_function(context, offset)) return true;

    const token = context.lexer_index_from(offset);
    if (token >= context.tokens.len) return false;

    var frames = Frame.covering(context, token);

    for (0..context.front.node_count()) |_| {
        const covering = frames.next() orelse return false;

        assert(covering.frame.covers(token));

        if (attributes_mark(context, covering.frame, &test_attributes)) return true;
    }

    return false;
}

fn inside_a_test_function(context: *const Context, offset: u32) bool {
    assert(offset <= context.source.len);

    const innermost = context.function_at(offset) orelse return false;
    if (runs_as_a_test(context, innermost)) return true;

    var ancestors = innermost.ancestors();

    for (0..ancestors.remaining + 1) |_| {
        const held = ancestors.next() orelse return false;

        switch (held.category()) {
            .function, .lambda => if (runs_as_a_test(context, held)) return true,
            else => {},
        }
    }

    return false;
}

fn runs_as_a_test(context: *const Context, function: View) bool {
    assert(function.as_function() != null);

    if (tests_by_name(context, function)) return true;
    return runs_as_a_test_callback(context, function);
}

fn attributes_mark(context: *const Context, frame: Frame, markers: []const []const u8) bool {
    assert(frame.header < context.tokens.len);
    assert(markers.len > 0);

    var line = context.line_of(context.tokens[frame.header].offset);

    for (0..Frame.attribute_count_max) |_| {
        if (line == 0) return false;

        line -= 1;

        const text = scan.trim_ascii(context.line_text(line));

        if (!std.mem.startsWith(u8, text, "#[")) {
            if (!std.mem.startsWith(u8, text, "@")) return false;
        }

        for (markers) |marker| {
            if (scan.find(text, marker) != null) return true;
        }
    }

    return false;
}

fn tests_by_name(context: *const Context, function: View) bool {
    assert(function.as_function() != null);

    const header = Frame.header_of(context, function);

    assert(header <= context.tokens.len);

    if (header < context.tokens.len) {
        if (std.mem.eql(u8, context.text(context.tokens[header]), test_word)) return true;
    }

    const name = function.name_token() orelse return false;
    const text = context.front_text(name);

    for (test_function_prefixes) |prefix| {
        if (std.mem.startsWith(u8, text, prefix)) return true;
    }

    return false;
}

fn runs_as_a_test_callback(context: *const Context, function: View) bool {
    assert(function.as_function() != null);

    const arguments = function.parent() orelse return false;
    if (arguments.category() != .expression) return false;

    const call = arguments.parent() orelse return false;

    assert(call.index() < arguments.index());

    if (call.category() != .call) return false;

    const callee = call.child_first() orelse return false;
    const head = identifier_head(context.span_text(callee.span()));

    return scan.word_in(&test_calls, head);
}

fn identifier_head(text: []const u8) []const u8 {
    for (text, 0..) |byte, index| {
        if (scan.is_identifier_part(byte)) continue;

        assert(index < text.len);

        return text[0..index];
    }

    return text;
}
