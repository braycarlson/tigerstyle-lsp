const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const fuzz = @import("testing/fuzz.zig");
const languages = @import("languages.zig");
const LexHarness = scylla.testing.LexHarness;
const PRNG = scylla.testing.PRNG;
const StaticAllocator = scylla.StaticAllocator;

const event_count_default = 1_024;
const source_bytes_max = 4_096;
const token_count_max = 4_096;

const fragments = [_][]const u8{
    "fn",
    "def",
    "func",
    "proc",
    "const",
    "let",
    "if",
    "else",
    "return",
    "struct",
    "(",
    ")",
    "{",
    "}",
    "[",
    "]",
    "<",
    ">",
    ";",
    ",",
    ".",
    ":",
    "::",
    "=",
    "=>",
    "->",
    "\"",
    "'",
    "`",
    "\"\"\"",
    "r#\"",
    "${",
    "\\",
    "\\\\",
    "//",
    "///",
    "#",
    "/*",
    "*/",
    "--",
    "0",
    "0x1f",
    "1.5",
    "1e9",
    "1_000",
    "value",
    "x",
    "Max",
    " ",
    "    ",
    "\t",
    "\n",
    "\r\n",
    "\r",
    "\x00",
    "\x0b",
    "\xff",
    "\xc3",
    "\x80",
    "\u{e9}",
    "\u{2028}",
    "\u{feff}",
    "\u{1F600}",
    "\u{3000}",
};

comptime {
    assert(source_bytes_max <= token_count_max);
    assert(fragments.len > 32);
}

pub fn main(gpa: std.mem.Allocator, _: std.Io, args: fuzz.FuzzArgs) !void {
    var prng = PRNG.init(args.seed);
    const events_max = args.events_max orelse event_count_default;

    var static_allocator: StaticAllocator = .init(gpa);
    defer static_allocator.deinit();

    const static = static_allocator.allocator();

    var harness: LexHarness = try .init(static, token_count_max);
    defer harness.deinit(static);

    var source_buffer: [source_bytes_max]u8 = undefined;

    assert(languages.linted.len > 0);
    assert(harness.tokens.count() == 0);

    static_allocator.transition_from_init_to_static();
    defer static_allocator.transition_from_static_to_deinit();

    for (0..events_max) |_| {
        const source = fuzz.source_generate(&prng, &fragments, &source_buffer);

        for (languages.linted) |language| harness.check(language, source);
    }
}

test "lex fuzz smoke" {
    try main(std.testing.allocator, std.testing.io, .{ .events_max = 64, .seed = 123 });
}
