const std = @import("std");
const assert = std.debug.assert;
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
    .{ .name = "corpus_tests", .own = &.{"corpus_test."}, .path = "src/harness/corpus_test.zig" },
    .{
        .name = "golden_findings_tests",
        .own = &.{"golden_findings_test."},
        .path = "src/harness/golden_findings_test.zig",
    },
    .{
        .name = "golden_tokens_tests",
        .own = &.{"golden_tokens_test."},
        .path = "src/harness/golden_tokens_test.zig",
    },
    .{ .name = "matrix_tests", .own = &.{"matrix_test."}, .path = "src/harness/matrix_test.zig" },
    .{
        .name = "precision_tests",
        .own = &.{"precision_test."},
        .path = "src/harness/precision_test.zig",
    },
    .{ .name = "unit_tests", .own = &.{}, .path = "src/unit_tests.zig" },
    .{ .name = "watch_tests", .own = &.{"watch_test."}, .path = "src/harness/watch_test.zig" },
};

const test_roots_timed = [_]TestRoot{
    .{
        .name = "latency_tests",
        .own = &.{"latency_test."},
        .path = "src/harness/latency_test.zig",
    },
};

const Steps = struct {
    check: *std.Build.Step,
    continuous_integration: *std.Build.Step,
    example: *std.Build.Step,
    fuzz: *std.Build.Step,
    fuzz_build: *std.Build.Step,
    @"test": *std.Build.Step,
    test_format: *std.Build.Step,
    test_unit: *std.Build.Step,
};

pub fn build(builder: *std.Build) void {
    const target = builder.standardTargetOptions(.{ .whitelist = null });
    const optimize = builder.standardOptimizeOption(.{ .preferred_optimize_mode = null });

    const filters = builder.option(
        []const []const u8,
        "test-filter",
        "Skip tests that do not match any filter",
    ) orelse &.{};

    const steps = steps_of(builder);
    const imports_held = imports_of(builder);
    const imports: []const std.Build.Module.Import = &imports_held;

    const module = builder.addModule("tigerstyle", .{
        .root_source_file = builder.path("src/tigerstyle.zig"),
        .imports = imports,
    });

    const binary = executable(builder, target, imports, .{
        .name = "tigerstyle-lsp",
        .root = "src/main.zig",
    });

    tests_wired(builder, target, optimize, imports, filters, steps.test_unit);

    const example_run = builder.addRunArtifact(example(builder, target, optimize, module));

    checks_wired(
        builder,
        optimize,
        .{ .imports = imports, .module = module },
        filters,
        steps.check,
    );

    builder.installArtifact(binary);
    steps.example.dependOn(&example_run.step);

    fuzz_wired(builder, fuzz_of(builder, target, imports), steps);

    const format = builder.addFmt(.{
        .paths = builder.pathList(&.{ "build.zig", "examples", "src" }),
        .check = true,
    });

    steps.test_format.dependOn(&format.step);
    steps.@"test".dependOn(steps.test_unit);
    steps.@"test".dependOn(steps.test_format);
    steps.continuous_integration.dependOn(steps.check);
    steps.continuous_integration.dependOn(steps.example);
    steps.continuous_integration.dependOn(steps.@"test");
    steps.continuous_integration.dependOn(builder.getInstallStep());
}

fn fuzz_of(
    builder: *std.Build,
    target: std.Build.ResolvedTarget,
    imports: []const std.Build.Module.Import,
) *std.Build.Step.Compile {
    assert(imports.len > 0);

    return executable(builder, target, imports, .{ .name = "fuzz", .root = "src/fuzz_tests.zig" });
}

fn fuzz_wired(builder: *std.Build, fuzz: *std.Build.Step.Compile, steps: Steps) void {
    assert(steps.fuzz != steps.fuzz_build);

    const fuzz_run = fuzz_run_of(builder, fuzz);

    fuzz_run.addPassthruArgs();

    const fuzz_smoke = fuzz_run_of(builder, fuzz);

    fuzz_smoke.addArg("smoke");

    steps.continuous_integration.dependOn(&fuzz_smoke.step);
    steps.fuzz.dependOn(&fuzz_run.step);
    steps.fuzz_build.dependOn(&builder.addInstallArtifact(fuzz, .{ .dest_dir = .default }).step);
}

fn imports_of(builder: *std.Build) [3]std.Build.Module.Import {
    return .{
        .{ .name = "json", .module = builder.dependency("json", .{}).module("json") },
        .{ .name = "scylla", .module = builder.dependency("scylla", .{}).module("scylla") },
        .{ .name = "toml", .module = builder.dependency("toml", .{}).module("toml") },
    };
}

fn tests_wired(
    builder: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    imports: []const std.Build.Module.Import,
    filters: []const []const u8,
    step: *std.Build.Step,
) void {
    assert(imports.len > 0);

    var runs: [test_roots.len]*std.Build.Step.Run = undefined;

    for (test_roots, &runs) |root, *run| {
        const chosen = if (filters.len > 0) filters else root.own;

        run.* = test_run_of(builder, tests_of(builder, target, optimize, imports, root, chosen));

        step.dependOn(&run.*.step);
    }

    for (test_roots_timed) |root| {
        const chosen = if (filters.len > 0) filters else root.own;

        const run = test_run_of(
            builder,
            tests_of(builder, target, optimize, imports, root, chosen),
        );

        for (runs) |concurrent| run.step.dependOn(&concurrent.step);

        step.dependOn(&run.step);
    }
}

const Modules = struct {
    imports: []const std.Build.Module.Import,
    module: *std.Build.Module,
};

fn checks_wired(
    builder: *std.Build,
    optimize: std.lang.Optimize,
    modules: Modules,
    filters: []const []const u8,
    step: *std.Build.Step,
) void {
    assert(modules.imports.len > 0);

    const imports = modules.imports;

    for (supported_targets) |query| {
        const resolved = builder.resolveTargetQuery(query);

        step.dependOn(&executable(builder, resolved, imports, .{
            .name = "tigerstyle-lsp",
            .root = "src/main.zig",
        }).step);

        step.dependOn(&executable(builder, resolved, imports, .{
            .name = "fuzz",
            .root = "src/fuzz_tests.zig",
        }).step);

        step.dependOn(&example(builder, resolved, optimize, modules.module).step);

        for (test_roots ++ test_roots_timed) |root| {
            const chosen = if (filters.len > 0) filters else root.own;

            step.dependOn(&tests_of(builder, resolved, optimize, imports, root, chosen).step);
        }
    }
}

fn example(
    builder: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    module: *std.Build.Module,
) *std.Build.Step.Compile {
    return builder.addExecutable(.{
        .name = example_name,
        .root_module = builder.createModule(.{
            .root_source_file = builder.path(example_root),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "tigerstyle", .module = module }},
        }),
    });
}

fn executable(
    builder: *std.Build,
    target: std.Build.ResolvedTarget,
    imports: []const std.Build.Module.Import,
    options: struct { name: []const u8, root: []const u8 },
) *std.Build.Step.Compile {
    assert(imports.len > 0);
    assert(options.name.len > 0);
    assert(options.root.len > 0);

    return builder.addExecutable(.{
        .name = options.name,
        .root_module = builder.createModule(.{
            .root_source_file = builder.path(options.root),
            .target = target,
            .optimize = .safe,
            .omit_frame_pointer = false,
            .imports = imports,
        }),
    });
}

fn test_run_of(builder: *std.Build, tests: *std.Build.Step.Compile) *std.Build.Step.Run {
    const run = builder.addRunArtifact(tests);

    run.has_side_effects = true;

    run.setCwd(builder.path("."));
    run.step.dependOn(builder.getInstallStep());

    return run;
}

fn tests_of(
    builder: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    imports: []const std.Build.Module.Import,
    root: TestRoot,
    filters: []const []const u8,
) *std.Build.Step.Compile {
    assert(imports.len > 0);
    assert(root.name.len > 0);

    return builder.addTest(.{
        .name = root.name,
        .root_module = builder.createModule(.{
            .root_source_file = builder.path(root.path),
            .target = target,
            .optimize = optimize,
            .imports = imports,
        }),
        .filters = filters,
    });
}

fn steps_of(builder: *std.Build) Steps {
    return .{
        .check = builder.step("check", "Compile every artifact for Linux and Windows"),
        .continuous_integration = builder.step("ci", "Run every check, test, and fuzz smoke"),
        .example = builder.step("example", "Build and run the example against the module"),
        .fuzz = builder.step("fuzz", "Run a fuzzer: zig build fuzz -- <fuzzer> [seed]"),
        .fuzz_build = builder.step("fuzz:build", "Compile the fuzzers without running them"),
        .@"test" = builder.step("test", "Run every test suite and the format check"),
        .test_format = builder.step("test:fmt", "Check that every source file is formatted"),
        .test_unit = builder.step("test:unit", "Run the unit tests and the tidy check"),
    };
}

fn fuzz_run_of(builder: *std.Build, fuzz: *std.Build.Step.Compile) *std.Build.Step.Run {
    const run = builder.addRunArtifact(fuzz);

    run.setCwd(builder.path("."));
    run.step.dependOn(builder.getInstallStep());

    return run;
}
