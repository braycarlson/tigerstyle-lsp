const std = @import("std");
const scylla = @import("scylla");
const Hygiene = scylla.testing.Hygiene;

const options: Hygiene.Options = .{
    .banned = &.{
        "std.debug." ++ "assert(",
        "Self = " ++ "@This()",
        "== " ++ "error.",
        "!= " ++ "error.",
        "using" ++ "namespace",
        "@" ++ "Type(",
        "@" ++ "cImport",
    },
    .layers = &.{
        .{ .imports = &.{}, .name = "testing" },
        .{ .imports = &.{"testing"}, .name = "linter" },
        .{ .imports = &.{ "linter", "testing" }, .name = "rules" },
        .{ .imports = &.{ "linter", "rules", "testing" }, .name = "config" },
        .{ .imports = &.{ "config", "linter", "rules", "testing" }, .name = "cli" },
        .{ .imports = &.{ "cli", "config", "linter", "rules", "testing" }, .name = "lsp" },
    },
    .entry_points = &.{
        "examples/lint.zig",
        "src/harness/corpus_test.zig",
        "src/fuzz_tests.zig",
        "src/harness/golden_findings_test.zig",
        "src/harness/golden_tokens_test.zig",
        "src/harness/latency_test.zig",
        "src/main.zig",
        "src/harness/matrix_test.zig",
        "src/harness/precision_test.zig",
        "src/unit_tests.zig",
        "src/harness/watch_test.zig",
    },
    .test_roots = &.{
        "src/harness/corpus_test.zig",
        "src/harness/golden_findings_test.zig",
        "src/harness/golden_tokens_test.zig",
        "src/harness/latency_test.zig",
        "src/harness/matrix_test.zig",
        "src/harness/precision_test.zig",
        "src/unit_tests.zig",
        "src/harness/watch_test.zig",
    },
};

test "tidy" {
    const problems = try Hygiene.check(std.testing.allocator, std.testing.io, &options);

    try std.testing.expectEqual(0, problems);
}
