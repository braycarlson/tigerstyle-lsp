const std = @import("std");
const assert = std.debug.assert;
const json = @import("json");
const scylla = @import("scylla");
const cli = @import("cli.zig");
const coverage = @import("rules/coverage.zig");
const languages = @import("languages.zig");
const metadata = @import("config/metadata.zig");
const scan = @import("scan.zig");
const Buffer = scylla.Buffer;
const Configuration = @import("config/configuration.zig");
const Language = scylla.Language;
const Limits = @import("limits.zig");
const Options = cli.Options;
const Rule = scylla.rule.Rule;
const Rules = @import("rules.zig");
const Setting = scylla.config.Setting;
const Workspace = @import("workspace.zig");
const log = scylla.log;
const rule_count_max = scylla.limits.rule_count_max;

configuration: Configuration,
io: std.Io,
options: *const Options,
output: Buffer,
overflowed: bool,
rules: Rules,
walked: ?Walked,

const Printer = @This();
pub const Error = std.mem.Allocator.Error || Configuration.LoadError || error{OptionUnknown};

const Walked = struct {
    ignores: Workspace.Ignores,
    workspace: Workspace,
};

const files_fallback = "<line>";
const option_separator: [option_separator_bytes]u8 = @splat('-');
const option_separator_bytes: u32 = 72;

const schema_options: json.Writer.Options = .{
    .indent = 2,
    .layout = .pretty,
    .non_finite = .refused,
    .notation = .ecmascript,
    .utf8 = .checked,
};

pub fn prints(options: *const Options) bool {
    return switch (options.mode) {
        .artifacts, .config, .rule => true,
        .lint => options.show_files or options.show_settings,
        .clean, .format, .selftest, .server, .tokens => false,
    };
}

pub fn init(
    printer: *Printer,
    gpa: std.mem.Allocator,
    io: std.Io,
    options: *const Options,
    limits: *const Limits,
) Error!void {
    assert(prints(options));
    assert(limits.artifact_bytes_max > 0);

    printer.io = io;
    printer.options = options;
    printer.overflowed = false;
    printer.walked = null;
    printer.rules = try .init(gpa);
    printer.configuration = try .init(gpa, &limits.configuration());

    try printer.configuration.load(io, &printer.rules.registry, options);
    try config_name_validate(options);

    if (options.show_files) try printer.walk(gpa, limits);

    printer.output = try .init(gpa, output_bytes_of(options, limits));
}

fn output_bytes_of(options: *const Options, limits: *const Limits) u32 {
    assert(limits.artifact_bytes_max > 0);
    assert(limits.workspace_bytes_max >= limits.path_bytes_max);

    if (!options.show_files) return limits.artifact_bytes_max;

    const line_bytes_extra: u64 = 1 + files_fallback.len;

    const listing_bytes_max = limits.workspace_bytes_max +
        limits.workspace_file_count_max * line_bytes_extra;

    assert(listing_bytes_max <= std.math.maxInt(u32));

    return @max(limits.artifact_bytes_max, @as(u32, @intCast(listing_bytes_max)));
}

fn config_name_validate(options: *const Options) error{OptionUnknown}!void {
    if (options.mode != .config) return;
    if (options.show_settings) return;
    if (options.all) return;
    if (options.paths.empty()) return;

    const name = options.paths.get(0);
    if (option_named(name) != null) return;

    log.line("error: {s} names no option; run `tigerstyle-lsp config --all` to see them all", .{
        scan.utf8_or(name, "<line>"),
    });

    return error.OptionUnknown;
}

fn walk(
    printer: *Printer,
    gpa: std.mem.Allocator,
    limits: *const Limits,
) std.mem.Allocator.Error!void {
    assert(printer.options.show_files);
    assert(printer.walked == null);

    printer.walked = .{
        .ignores = try .init(gpa, limits.ignores()),
        .workspace = try .init(gpa, &limits.workspace()),
    };

    const walked = &printer.walked.?;

    walked.ignores.apply(&printer.configuration.draft);
    walked.workspace.collect(printer.io, printer.options.paths.const_slice(), &walked.ignores);
}

pub fn run(printer: *Printer) u8 {
    printer.output.clear();
    printer.overflowed = false;

    switch (printer.options.mode) {
        .artifacts => printer.artifacts_write(),
        .config => printer.config_write(),
        .lint => printer.lint_write(),
        .rule => printer.rule_write(),
        .clean, .format, .selftest, .server, .tokens => unreachable,
    }

    if (printer.overflowed) {
        log.line("the artifact outgrew the {d} byte buffer", .{printer.output.capacity()});
    }

    const stdout = std.Io.File.stdout();

    stdout.writeStreamingAll(printer.io, printer.output.const_slice()) catch {
        return cli.exit_failure;
    };

    if (printer.overflowed) return cli.exit_failure;
    return cli.exit_success;
}

fn put(printer: *Printer, comptime format: []const u8, arguments: anytype) void {
    assert(format.len > 0);

    printer.output.print_pieces(format, arguments) catch |err| switch (err) {
        error.Overflow => printer.overflowed = true,
    };
}

fn artifacts_write(printer: *Printer) void {
    assert(printer.options.mode == .artifacts);

    const subject = printer.options.subject orelse "";
    if (std.mem.eql(u8, subject, "coverage")) return printer.coverage_write();
    if (std.mem.eql(u8, subject, "rules")) return printer.rules_table();
    if (std.mem.eql(u8, subject, "schema")) return printer.schema_write();

    if (std.mem.eql(u8, subject, "settings")) {
        Setting.documentation_write(&printer.output, &metadata.options) catch {
            printer.overflowed = true;
        };

        return;
    }

    log.line("artifacts takes coverage, rules, schema, or settings", .{});
}

fn schema_write(printer: *Printer) void {
    assert(printer.output.empty());

    var sink = printer.output.writer();
    var writer: json.Writer = .init(&sink.interface, schema_options);

    Setting.schema_write(&writer, "tigerstyle.toml", &metadata.options) catch |err| switch (err) {
        error.WriteFailed => {
            printer.overflowed = true;

            return;
        },
        error.DepthExceeded,
        error.EnumerationUnrecognized,
        error.FloatNonFinite,
        error.RawMalformed,
        => unreachable,
    };

    writer.finish();
}

fn coverage_write(printer: *Printer) void {
    assert(printer.rules.count() > 0);
    assert(printer.output.empty());

    printer.put("# Coverage\n", .{});
    printer.put("\n", .{});

    printer.put(
        "Every cell is `Checked.`, `Inapplicable.`, or `Unimplemented.`, resolved from the\n",
        .{},
    );

    printer.put("rule registry and the gap table in `src/rules/coverage.zig`.\n", .{});
    printer.put("\n", .{});
    printer.coverage_matrix();
    printer.put("\n", .{});
    printer.put("## Gaps\n", .{});
    printer.put("\n", .{});
    printer.coverage_gaps();
}

fn coverage_matrix(printer: *Printer) void {
    assert(printer.rules.count() > 0);

    printer.put("| Rule |", .{});

    for (languages.linted) |language| {
        printer.put(" ", .{});
        printer.titled_write(language);
        printer.put(" |", .{});
    }

    printer.put("\n", .{});
    printer.put("|---|", .{});

    for (languages.linted) |_| printer.put("---|", .{});

    printer.put("\n", .{});

    var previous: []const u8 = "";

    for (0..rule_count_max) |_| {
        const rule = rule_after(&printer.rules, previous) orelse break;

        previous = rule.code;

        printer.put("| {s} |", .{rule.code});

        for (languages.linted) |language| {
            const gap = coverage.gap_of(rule.code, language);
            const state = if (gap) |found| found.support.text() else "Checked";

            printer.put(" {s}. |", .{state});
        }

        printer.put("\n", .{});
    }

    assert(previous.len > 0);
}

fn coverage_gaps(printer: *Printer) void {
    assert(coverage.gaps.len > 0);

    printer.put("| Rule | Language | Support | Reason |\n", .{});
    printer.put("|---|---|---|---|\n", .{});

    for (coverage.gaps) |gap| {
        printer.put("| {s} | {s} | {s} | {s} |\n", .{
            gap.code,
            gap.language.name(),
            gap.support.text(),
            gap.reason,
        });
    }
}

fn titled_write(printer: *Printer, language: Language) void {
    const identifier = language.name();

    assert(identifier.len > 0);

    const spelled: ?[]const u8 = switch (language) {
        .go => "Go",
        .javascript => "JavaScript",
        .odin => "Odin",
        .python => "Python",
        .rust => "Rust",
        .typescript => "TypeScript",
        .zig => "Zig",
        .css, .markup => null,
    };

    if (spelled) |text| return printer.put("{s}", .{text});

    printer.put("{c}{s}", .{ std.ascii.toUpper(identifier[0]), identifier[1..] });
}

fn rules_table(printer: *Printer) void {
    assert(printer.rules.count() > 0);

    printer.put("| Code | Name | Default | Severity | What it means | Languages |\n", .{});
    printer.put("|---|---|---|---|---|---|\n", .{});

    var previous: []const u8 = "";

    for (0..rule_count_max) |_| {
        const rule = rule_after(&printer.rules, previous) orelse break;

        previous = rule.code;

        printer.put("| {s} | `{s}` | {s} | {s} | {s} | ", .{
            rule.code,
            rule.name,
            default_text(rule),
            rule.severity.name(),
            rule.summary,
        });

        if (reached_count(rule) == languages.linted.len) {
            printer.put("All", .{});
        } else {
            printer.languages_listed(rule);
        }

        printer.put(" |\n", .{});
    }

    assert(previous.len > 0);
}

fn languages_listed(printer: *Printer, rule: *const Rule) void {
    var written: u32 = 0;

    for (languages.linted) |language| {
        if (coverage.gap_of(rule.code, language) != null) continue;

        if (written > 0) printer.put(", ", .{});

        printer.titled_write(language);
        written += 1;
    }

    assert(written < languages.linted.len);
}

fn reached_count(rule: *const Rule) u32 {
    var named: u32 = 0;

    for (languages.linted) |language| {
        if (coverage.gap_of(rule.code, language) == null) named += 1;
    }

    assert(named <= languages.linted.len);

    return named;
}

fn config_write(printer: *Printer) void {
    const options = printer.options;

    assert(options.mode == .config);

    if (options.show_settings) return printer.resolved_write();
    if (options.all) return printer.options_write();
    if (options.paths.empty()) return printer.options_write();

    const option = option_named(options.paths.get(0)).?;

    printer.option_write(option);
}

fn options_write(printer: *Printer) void {
    assert(metadata.options.len > 0);
    assert(printer.output.empty());

    for (&metadata.options, 0..) |*option, index| {
        if (index > 0) {
            printer.put("\n", .{});
            printer.put("{s}\n", .{&option_separator});
            printer.put("\n", .{});
        }

        printer.option_write(option);
    }
}

fn option_write(printer: *Printer, option: *const Setting) void {
    assert(option.name.len > 0);
    assert(option.example.len > 0);

    printer.put("{s}\n", .{option.name});
    printer.put("\n", .{});
    printer.put("{s}\n", .{option.description});
    printer.put("\n", .{});
    printer.put("Default: {s}\n", .{option.default});
    printer.put("\n", .{});
    printer.put("Example:\n", .{});
    printer.put("\n", .{});
    printer.put("{s}\n", .{option.example});
}

fn option_named(name: []const u8) ?*const Setting {
    for (&metadata.options) |*option| {
        if (std.mem.eql(u8, option.name, name)) return option;
    }

    return null;
}

fn lint_write(printer: *Printer) void {
    assert(printer.options.mode == .lint);

    if (printer.options.show_files) return printer.files_write();

    assert(printer.options.show_settings);

    printer.resolved_write();
}

fn files_write(printer: *Printer) void {
    const workspace = &printer.walked.?.workspace;

    assert(printer.options.show_files);
    assert(printer.output.empty());

    for (0..workspace.count()) |index| {
        const path = workspace.path(@intCast(index));

        printer.put("{s}\n", .{scan.utf8_or(path, files_fallback)});
    }

    assert(!printer.overflowed);
}

fn resolved_write(printer: *Printer) void {
    const registry = &printer.rules.registry;
    const draft = &printer.configuration.draft;
    const settings = draft.settings(null, registry);
    const thresholds = settings.thresholds;
    const preview = draft.selection.preview.enabled;

    assert(thresholds.validate());
    assert(printer.output.empty());

    printer.put("assertions_per_function_min = {d}\n", .{thresholds.assertions_per_function_min});
    printer.put("declaration_distance_max = {d}\n", .{thresholds.declaration_distance_max});
    printer.put("else_if_chain_max = {d}\n", .{thresholds.else_if_chain_max});
    printer.put("function_lines_max = {d}\n", .{thresholds.function_lines_max});
    printer.put("line_length_max = {d}\n", .{thresholds.line_length_max});
    printer.put("nesting_depth_max = {d}\n", .{thresholds.nesting_depth_max});
    printer.put("parameters_max = {d}\n", .{thresholds.parameters_max});
    printer.put("preview = {s}\n", .{if (preview) "true" else "false"});

    for (0..printer.rules.count()) |index| {
        if (!settings.enables(@intCast(index))) continue;

        const rule = printer.rules.at(@intCast(index));

        printer.put("select = {s} ({s})\n", .{ rule.code, rule.name });
    }
}

fn rule_write(printer: *Printer) void {
    assert(printer.options.mode == .rule);

    const subject = printer.options.subject orelse return printer.rules_list();
    const found = printer.rules.find(subject) orelse printer.rules.find_name(subject);

    const rule = found orelse {
        log.line("no rule named {s}", .{scan.utf8_or(subject, "<line>")});

        return;
    };

    printer.put("{s} {s}\n", .{ rule.code, rule.name });
    printer.put("\n", .{});
    printer.put("{s}\n", .{rule.description});
    printer.put("\n", .{});
    printer.rule_languages_write(rule);
    printer.put("severity: {s}\n", .{rule.severity.name()});
    printer.put("default: {s}\n", .{default_text(rule)});
    printer.put("group: {s}\n", .{rule.group.name()});

    for (coverage.gaps) |gap| {
        if (!std.mem.eql(u8, gap.code, rule.code)) continue;

        printer.put("{s}: {s}\n", .{ gap.language.name(), gap.reason });
    }

    printer.rule_citations_write(rule);
}

fn rules_list(printer: *Printer) void {
    assert(printer.rules.count() > 0);
    assert(printer.output.empty());

    for (0..printer.rules.count()) |index| {
        const rule = printer.rules.at(@intCast(index));

        printer.put("{s} {s}\n", .{ rule.code, rule.name });
    }
}

fn rule_languages_write(printer: *Printer, rule: *const Rule) void {
    assert(rule.code.len > 0);

    printer.put("languages:", .{});

    for (languages.linted) |language| {
        if (coverage.gap_of(rule.code, language) != null) continue;

        printer.put(" {s}", .{language.name()});
    }

    printer.put("\n", .{});
}

fn rule_citations_write(printer: *Printer, rule: *const Rule) void {
    assert(rule.code.len > 0);

    if (rule.citations.len > 0) printer.put("\n", .{});

    for (rule.citations) |citation| {
        if (std.mem.eql(u8, citation.standard, "TigerStyle")) {
            printer.put("TigerStyle: {s}\n", .{citation.text});
        } else {
            printer.put("{s}\n", .{citation.text});
        }
    }
}

fn rule_after(rules: *const Rules, previous: []const u8) ?*const Rule {
    var found: ?*const Rule = null;

    for (0..rules.count()) |index| {
        const rule = rules.at(@intCast(index));
        if (std.mem.order(u8, rule.code, previous) != .gt) continue;

        const held = found orelse {
            found = rule;

            continue;
        };

        if (std.mem.order(u8, rule.code, held.code) == .lt) found = rule;
    }

    if (found) |rule| assert(std.mem.order(u8, rule.code, previous) == .gt);

    return found;
}

fn default_text(rule: *const Rule) []const u8 {
    assert(rule.code.len > 0);

    if (rule.is_preview()) return "preview";
    if (rule.default_on) return "on";
    return "opt-in";
}

test "every schema key is written once" {
    const name_bytes_max = scylla.limits.config_name_bytes_max;

    var buffers: [metadata.options.len][name_bytes_max]u8 = undefined;
    var keys: [metadata.options.len * 2][]const u8 = undefined;
    var key_count: u32 = 0;

    for (metadata.options, &buffers) |option, *buffer| {
        keys[key_count] = option.name;
        key_count += 1;

        if (Setting.kebab_of(option.name, buffer)) |spelled| {
            keys[key_count] = spelled;
            key_count += 1;
        }
    }

    try std.testing.expect(key_count >= metadata.options.len);

    for (keys[0..key_count], 0..) |key, index| {
        for (keys[index + 1 .. key_count]) |other| {
            try std.testing.expect(!std.mem.eql(u8, key, other));
        }
    }
}
