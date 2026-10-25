const std = @import("std");
const example_name = "lint";
const example_root = "examples/lint.zig";

const supported_targets = [_]std.Target.Query{
    .{ .cpu_arch = .x86_64, .os_tag = .linux },
    .{ .cpu_arch = .x86_64, .os_tag = .windows },
};

const TestRoot = struct {
    name: []const u8,
    own: []const []const u8,
    path: []const u8,
};

const test_roots = [_]TestRoot{
    .{ .name = "corpus_tests", .own = &.{"corpus_test."}, .path = "src/corpus_test.zig" },
    .{
        .name = "golden_findings_tests",
        .own = &.{"golden_findings_test."},
        .path = "src/golden_findings_test.zig",
    },
    .{
        .name = "golden_tokens_tests",
        .own = &.{"golden_tokens_test."},
        .path = "src/golden_tokens_test.zig",
    },
    .{ .name = "matrix_tests", .own = &.{"matrix_test."}, .path = "src/matrix_test.zig" },
    .{
        .name = "precision_tests",
        .own = &.{"precision_test."},
        .path = "src/precision_test.zig",
    },
    .{ .name = "unit_tests", .own = &.{}, .path = "src/unit_tests.zig" },
    .{ .name = "watch_tests", .own = &.{"watch_test."}, .path = "src/watch_test.zig" },
};

const test_roots_timed = [_]TestRoot{
    .{ .name = "latency_tests", .own = &.{"latency_test."}, .path = "src/latency_test.zig" },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const filters = b.option(
        []const []const u8,
        "test-filter",
        "Skip tests that do not match any filter",
    ) orelse &.{};

    const steps = .{
        .check = b.step("check", "Compile every artifact for Linux and Windows"),
        .ci = b.step("ci", "Run every check, test, and fuzz smoke"),
        .example = b.step("example", "Build and run the example against the module"),
        .fuzz = b.step("fuzz", "Run a fuzzer: zig build fuzz -- <fuzzer> [seed]"),
        .fuzz_build = b.step("fuzz:build", "Compile the fuzzers without running them"),
        .@"test" = b.step("test", "Run every test suite and the format check"),
        .test_fmt = b.step("test:fmt", "Check that every source file is formatted"),
        .test_unit = b.step("test:unit", "Run the unit tests and the tidy check"),
    };

    const imports = imports_of(b);

    const module = b.addModule("tigerstyle", .{
        .root_source_file = b.path("src/tigerstyle.zig"),
        .imports = imports,
    });

    const binary = executable(b, target, imports, "tigerstyle-lsp", "src/main.zig");
    const fuzz = executable(b, target, imports, "fuzz", "src/fuzz_tests.zig");

    tests_wired(b, target, optimize, imports, filters, steps.test_unit);

    const fuzz_run = fuzz_run_of(b, fuzz);

    fuzz_run.addPassthruArgs();

    const fuzz_smoke = fuzz_run_of(b, fuzz);

    fuzz_smoke.addArg("smoke");

    const example_run = b.addRunArtifact(example(b, target, optimize, module));

    const fmt = b.addFmt(.{
        .paths = b.pathList(&.{ "build.zig", "examples", "src" }),
        .check = true,
    });

    checks_wired(b, optimize, .{ .imports = imports, .module = module }, filters, steps.check);

    b.installArtifact(binary);
    steps.example.dependOn(&example_run.step);
    steps.fuzz.dependOn(&fuzz_run.step);
    steps.fuzz_build.dependOn(&b.addInstallArtifact(fuzz, .{}).step);
    steps.test_fmt.dependOn(&fmt.step);
    steps.@"test".dependOn(steps.test_unit);
    steps.@"test".dependOn(steps.test_fmt);
    steps.ci.dependOn(steps.check);
    steps.ci.dependOn(steps.example);
    steps.ci.dependOn(steps.@"test");
    steps.ci.dependOn(&fuzz_smoke.step);
    steps.ci.dependOn(b.getInstallStep());
}

fn imports_of(b: *std.Build) []const std.Build.Module.Import {
    const imports = [_]std.Build.Module.Import{
        .{ .name = "json", .module = b.dependency("json", .{}).module("json") },
        .{ .name = "scylla", .module = b.dependency("scylla", .{}).module("scylla") },
        .{ .name = "toml", .module = b.dependency("toml", .{}).module("toml") },
    };

    return b.allocator.dupe(std.Build.Module.Import, &imports) catch @panic("out of memory");
}

fn tests_wired(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    imports: []const std.Build.Module.Import,
    filters: []const []const u8,
    step: *std.Build.Step,
) void {
    var runs: [test_roots.len]*std.Build.Step.Run = undefined;

    for (test_roots, &runs) |root, *run| {
        const chosen = if (filters.len > 0) filters else root.own;

        run.* = test_run_of(b, tests_of(b, target, optimize, imports, root, chosen));

        step.dependOn(&run.*.step);
    }

    for (test_roots_timed) |root| {
        const chosen = if (filters.len > 0) filters else root.own;
        const run = test_run_of(b, tests_of(b, target, optimize, imports, root, chosen));

        for (runs) |concurrent| run.step.dependOn(&concurrent.step);

        step.dependOn(&run.step);
    }
}

const Modules = struct {
    imports: []const std.Build.Module.Import,
    module: *std.Build.Module,
};

fn checks_wired(
    b: *std.Build,
    optimize: std.lang.Optimize,
    modules: Modules,
    filters: []const []const u8,
    step: *std.Build.Step,
) void {
    const imports = modules.imports;

    for (supported_targets) |query| {
        const resolved = b.resolveTargetQuery(query);

        step.dependOn(&executable(b, resolved, imports, "tigerstyle-lsp", "src/main.zig").step);
        step.dependOn(&executable(b, resolved, imports, "fuzz", "src/fuzz_tests.zig").step);
        step.dependOn(&example(b, resolved, optimize, modules.module).step);

        for (test_roots ++ test_roots_timed) |root| {
            const chosen = if (filters.len > 0) filters else root.own;

            step.dependOn(&tests_of(b, resolved, optimize, imports, root, chosen).step);
        }
    }
}

fn example(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    module: *std.Build.Module,
) *std.Build.Step.Compile {
    return b.addExecutable(.{
        .name = example_name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(example_root),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "tigerstyle", .module = module }},
        }),
    });
}

fn executable(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    imports: []const std.Build.Module.Import,
    name: []const u8,
    root: []const u8,
) *std.Build.Step.Compile {
    return b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(root),
            .target = target,
            .optimize = .safe,
            .omit_frame_pointer = false,
            .imports = imports,
        }),
    });
}

fn test_run_of(b: *std.Build, tests: *std.Build.Step.Compile) *std.Build.Step.Run {
    const run = b.addRunArtifact(tests);

    run.has_side_effects = true;

    run.setCwd(b.path("."));
    run.step.dependOn(b.getInstallStep());

    return run;
}

fn tests_of(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    imports: []const std.Build.Module.Import,
    root: TestRoot,
    filters: []const []const u8,
) *std.Build.Step.Compile {
    return b.addTest(.{
        .name = root.name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(root.path),
            .target = target,
            .optimize = optimize,
            .imports = imports,
        }),
        .filters = filters,
    });
}

fn fuzz_run_of(b: *std.Build, fuzz: *std.Build.Step.Compile) *std.Build.Step.Run {
    const run = b.addRunArtifact(fuzz);

    run.setCwd(b.path("."));
    run.step.dependOn(b.getInstallStep());

    return run;
}
