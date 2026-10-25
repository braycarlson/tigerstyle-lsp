const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const Arguments = scylla.Arguments;
const Format = scylla.report.Format;
const Selftest = @import("selftest.zig");

pub const Options = struct {
    add_suppressions: bool,
    all: bool,
    baseline: ?[]const u8,
    cache_dir: ?[]const u8,
    check: bool,
    color: ?[]const u8,
    config: ?[]const u8,
    diff: bool,
    excludes: List,
    exit_non_zero_on_fix: bool,
    exit_zero: bool,
    extend_fixable: List,
    extend_select: List,
    fix: bool,
    fix_only: bool,
    fixable: List,
    force_exclude: bool,
    format: Format,
    ignore: List,
    includes: List,
    isolated: bool,
    language: ?[]const u8,
    mode: Mode,
    no_cache: bool,
    output_file: ?[]const u8,
    paths: List,
    per_file_ignores: List,
    preview: bool,
    quiet: bool,
    respect_gitignore: ?bool,
    select: List,
    show_files: bool,
    show_fixes: bool,
    show_settings: bool,
    silent: bool,
    statistics: bool,
    stdin_filename: ?[]const u8,
    subject: ?[]const u8,
    thresholds: Thresholds,
    unfixable: List,
    unsafe_fixes: bool,
    verbose: bool,
    watch: bool,
    write_baseline: ?[]const u8,

    pub fn init(gpa: std.mem.Allocator) std.mem.Allocator.Error!Options {
        var options: Options = undefined;

        options.excludes = try .init(gpa, argument_count_max);
        options.extend_fixable = try .init(gpa, argument_count_max);
        options.extend_select = try .init(gpa, argument_count_max);
        options.fixable = try .init(gpa, argument_count_max);
        options.ignore = try .init(gpa, argument_count_max);
        options.includes = try .init(gpa, argument_count_max);
        options.paths = try .init(gpa, argument_count_max);
        options.per_file_ignores = try .init(gpa, argument_count_max);
        options.select = try .init(gpa, argument_count_max);
        options.thresholds = try .init(gpa, argument_count_max);
        options.unfixable = try .init(gpa, argument_count_max);

        options.defaults_set(.lint, null);

        assert(options.paths.empty());
        assert(options.select.capacity() == argument_count_max);

        return options;
    }

    pub fn deinit(options: *Options, gpa: std.mem.Allocator) void {
        assert(options.paths.capacity() == argument_count_max);
        assert(options.thresholds.capacity() == argument_count_max);

        options.excludes.deinit(gpa);
        options.extend_fixable.deinit(gpa);
        options.extend_select.deinit(gpa);
        options.fixable.deinit(gpa);
        options.ignore.deinit(gpa);
        options.includes.deinit(gpa);
        options.paths.deinit(gpa);
        options.per_file_ignores.deinit(gpa);
        options.select.deinit(gpa);
        options.thresholds.deinit(gpa);
        options.unfixable.deinit(gpa);
        options.* = undefined;
    }

    pub fn colored(
        options: *const Options,
        io: std.Io,
        environment: *const std.process.Environ.Map,
    ) bool {
        if (!options.format.colors()) return false;
        if (options.output_file != null) return false;

        const named = options.color orelse "auto";
        const chosen = scylla.Terminal.Color.of(named) orelse .auto;
        const terminal = std.Io.File.stdout().isTty(io) catch false;

        return chosen.resolved(.{
            .force_color = environment.get("FORCE_COLOR"),
            .no_color = environment.get("NO_COLOR"),
            .term = environment.get("TERM"),
            .terminal = terminal,
        });
    }

    fn defaults_set(options: *Options, mode: Mode, subject: ?[]const u8) void {
        inline for (@typeInfo(Options).@"struct".field_names) |name| {
            const Field = @FieldType(Options, name);

            if (Field == bool) @field(options, name) = false;
            if (Field == ?[]const u8) @field(options, name) = null;
            if (Field == List) @field(options, name).clear();
        }

        options.format = .full;
        options.mode = mode;
        options.respect_gitignore = null;
        options.subject = subject;

        options.thresholds.clear();

        assert(!options.fix);
        assert(options.paths.empty());
    }
};

const Mode = union(enum) {
    artifacts,
    clean,
    config,
    format,
    lint,
    rule,
    selftest: Selftest.Case,
    server,
    tokens,
};

pub const Exit = union(enum) {
    completions: []const u8,
    help,
    unexpected: []const u8,
    usage,
    usage_message: []const u8,
    version,

    pub fn code(exit: Exit) u8 {
        const result: u8 = switch (exit) {
            .completions, .help, .version => exit_success,
            .unexpected, .usage, .usage_message => exit_usage,
        };

        assert(result == exit_success or result == exit_usage);

        return result;
    }
};

const Threshold = struct {
    key: []const u8,
    value: []const u8,
};

const List = scylla.ArrayType([]const u8);

const Next = union(enum) {
    absent,
    option: []const u8,
    text: []const u8,
};

const Thresholds = scylla.ArrayType(Threshold);

const Flag = enum {
    add_suppressions,
    all,
    check,
    diff,
    exit_non_zero_on_fix,
    exit_zero,
    fix,
    fix_only,
    force_exclude,
    isolated,
    no_cache,
    preview,
    quiet,
    show_files,
    show_fixes,
    show_settings,
    silent,
    statistics,
    unsafe_fixes,
    verbose,
    watch,
};

const Value = enum {
    baseline,
    cache_dir,
    color,
    config,
    exclude,
    extend_fixable,
    extend_select,
    fixable,
    format,
    ignore,
    include,
    language,
    output_file,
    per_file_ignores,
    respect_gitignore,
    select,
    stdin_filename,
    unfixable,
    write_baseline,
};

const Word = enum {
    artifacts,
    check,
    clean,
    completions,
    config,
    format,
    lint,
    rule,
    selftest,
    server,
    tokens,
    version,
};

const argument_count_max: u32 = 1 << 12;
const argument_bytes_max: u32 = 1 << 20;
pub const exit_failure: u8 = 1;
pub const exit_success: u8 = 0;
pub const exit_usage: u8 = 2;
pub const version = "0.1.0";

pub const arguments_capacity: Arguments.Capacity = .{
    .argfile_bytes_max = argument_bytes_max,
    .word_bytes_max = argument_bytes_max,
    .word_count_max = argument_count_max,
};

const flags = std.StaticStringMap(Flag).initComptime(.{
    .{ "--add-suppressions", .add_suppressions },
    .{ "--all", .all },
    .{ "--check", .check },
    .{ "--diff", .diff },
    .{ "--exit-non-zero-on-fix", .exit_non_zero_on_fix },
    .{ "--exit-zero", .exit_zero },
    .{ "--fix", .fix },
    .{ "--fix-only", .fix_only },
    .{ "--force-exclude", .force_exclude },
    .{ "--isolated", .isolated },
    .{ "--no-cache", .no_cache },
    .{ "--preview", .preview },
    .{ "--quiet", .quiet },
    .{ "--show-files", .show_files },
    .{ "--show-fixes", .show_fixes },
    .{ "--show-settings", .show_settings },
    .{ "--silent", .silent },
    .{ "--statistics", .statistics },
    .{ "--unsafe-fixes", .unsafe_fixes },
    .{ "--verbose", .verbose },
    .{ "--watch", .watch },
    .{ "-q", .quiet },
    .{ "-s", .silent },
    .{ "-v", .verbose },
});

const values = std.StaticStringMap(Value).initComptime(.{
    .{ "--baseline", .baseline },
    .{ "--cache-dir", .cache_dir },
    .{ "--color", .color },
    .{ "--config", .config },
    .{ "--exclude", .exclude },
    .{ "--extend-exclude", .exclude },
    .{ "--extend-fixable", .extend_fixable },
    .{ "--extend-include", .include },
    .{ "--extend-per-file-ignores", .per_file_ignores },
    .{ "--extend-select", .extend_select },
    .{ "--fixable", .fixable },
    .{ "--format", .format },
    .{ "--ignore", .ignore },
    .{ "--include", .include },
    .{ "--language", .language },
    .{ "--output-file", .output_file },
    .{ "--output-format", .format },
    .{ "--per-file-ignores", .per_file_ignores },
    .{ "--respect-gitignore", .respect_gitignore },
    .{ "--select", .select },
    .{ "--stdin-filename", .stdin_filename },
    .{ "--unfixable", .unfixable },
    .{ "--write-baseline", .write_baseline },
});

const thresholds = std.StaticStringMap([]const u8).initComptime(.{
    .{ "--assertions-per-function-min", "assertions_per_function_min" },
    .{ "--declaration-distance-max", "declaration_distance_max" },
    .{ "--else-if-chain-max", "else_if_chain_max" },
    .{ "--function-lines-max", "function_lines_max" },
    .{ "--line-length-max", "line_length_max" },
    .{ "--nesting-depth-max", "nesting_depth_max" },
    .{ "--parameters-max", "parameters_max" },
});

const words = std.StaticStringMap(Word).initComptime(.{
    .{ "artifacts", .artifacts },
    .{ "check", .check },
    .{ "clean", .clean },
    .{ "completions", .completions },
    .{ "config", .config },
    .{ "format", .format },
    .{ "lint", .lint },
    .{ "rule", .rule },
    .{ "selftest", .selftest },
    .{ "server", .server },
    .{ "tokens", .tokens },
    .{ "version", .version },
});

pub const usage =
    \\usage:
    \\  tigerstyle-lsp check [options] [<path>...]
    \\  tigerstyle-lsp clean [<path>...]
    \\  tigerstyle-lsp config [--all|--show-settings|<key>]
    \\  tigerstyle-lsp format [--check|--diff] [<path>...]
    \\  tigerstyle-lsp rule [<code>]
    \\  tigerstyle-lsp server
    \\  tigerstyle-lsp tokens <path>
    \\  tigerstyle-lsp version
    \\  tigerstyle-lsp selftest <allocate|deallocate|panic|reallocate>
    \\
    \\output:
    \\      --format <f>          full (default), concise, grouped, json, json-lines, junit,
    \\                            github, gitlab, sarif, pylint, rdjson, or azure
    \\      --output-format <f>   The same option under the predecessor's name
    \\      --output-file <path>  Write the report to a file, with the colour stripped
    \\      --color <when>        always, never, or auto
    \\      --statistics          Print a count per rule rather than one line per finding
    \\      --show-fixes          Name the fix each finding carries
    \\      --show-files          Print the files a run would check and exit
    \\      --show-settings       Print the resolved settings and exit
    \\  -v, --verbose             Print the limits and the freeze report to standard error
    \\  -q, --quiet               Hold back the fix summary
    \\  -s, --silent              Print nothing at all
    \\
    \\fixes:
    \\      --fix                 Apply every safe fix and rewrite the files
    \\      --unsafe-fixes        Apply the unsafe fixes too
    \\      --fix-only            Apply the fixes and print nothing about what is left
    \\      --diff                Print what a fix run would change, and change nothing
    \\      --add-suppressions    Insert a directive for each finding, in place
    \\      --fixable <s>         Replace the fixable set with what a selector names
    \\      --extend-fixable <s>  Add the rules a selector names to the fixable set
    \\      --unfixable <s>       Take the rules a selector names out of the fixable set
    \\
    \\selection:
    \\      --select <s>          Replace the default rule set with what a selector names
    \\      --extend-select <s>   Turn on the rules a selector names, beside the default set
    \\      --ignore <selector>   Turn off the rules a selector names
    \\      --preview             Turn on the rules still in preview
    \\      --per-file-ignores <pattern:RULES>
    \\                            Rule exemptions per path glob, rules separated by |
    \\
    \\configuration:
    \\      --config <path>       Read this configuration file rather than discovering one
    \\      --isolated            Discover no configuration file
    \\      --include <glob>      Check the paths a glob names
    \\      --exclude <glob>      Skip the paths a glob names
    \\      --force-exclude       Apply the exclusions to the paths named on the command line
    \\      --language <name>     The language standard input holds: go, python, rust, or zig
    \\      --stdin-filename <p>  The path standard input stands for
    \\      --assertions-per-function-min <n>
    \\      --declaration-distance-max <n>
    \\      --else-if-chain-max <n>
    \\      --function-lines-max <n>
    \\      --line-length-max <n>
    \\      --nesting-depth-max <n>
    \\      --parameters-max <n>  The seven rule thresholds, as the config file spells them
    \\
    \\run:
    \\      --baseline <path>     Drop the findings a baseline file already records
    \\      --write-baseline <p>  Record the findings and exit 0
    \\      --watch               Re-check when a file changes
    \\      --exit-zero           Exit 0 whatever was found
    \\      --exit-non-zero-on-fix
    \\                            Exit 1 when a fix was applied
    \\  -h, --help                Print this message
    \\  -V, --version             Print the version
    \\
    \\      --respect-gitignore <bool>
    \\                            Honour .gitignore during the walk, overriding the config key
    \\
    \\cache:
    \\      --no-cache            Read and write no clean-file cache
    \\      --cache-dir <path>    Hold the cache under this directory rather than .tigerstyle_cache
    \\
    \\  --extend-exclude, --extend-include, and --extend-per-file-ignores are read as
    \\  --exclude, --include, and --per-file-ignores, which extend rather than replace.
;

const completions_bash = completions_bash_head ++ completions_bash_options ++
    completions_bash_tail;

const completions_bash_head =
    \\_tigerstyle_lsp() {
    \\  local commands='check clean completions config rule server tokens version selftest'
    \\  local options='
;

const completions_bash_options = "--add-suppressions --baseline --color --config --diff " ++
    "--exclude --exit-non-zero-on-fix --exit-zero --extend-select --fix --fix-only " ++
    "--force-exclude --format --ignore --include --isolated --language --output-file " ++
    "--output-format --per-file-ignores --preview --select --show-files --show-fixes " ++
    "--show-settings --statistics --stdin-filename --unsafe-fixes --watch --write-baseline";

const completions_bash_tail =
    \\'
    \\
    \\  if [ "$COMP_CWORD" -eq 1 ]; then
    \\    COMPREPLY=($(compgen -W "$commands" -- "${COMP_WORDS[1]}"))
    \\    return
    \\  fi
    \\
    \\  COMPREPLY=($(compgen -W "$options" -- "${COMP_WORDS[$COMP_CWORD]}"))
    \\}
    \\
    \\complete -F _tigerstyle_lsp tigerstyle-lsp
;

const completions_fish = completions_fish_head ++ completions_fish_subcommand ++
    "tokens -d 'Print the token stream of a file'\n" ++ completions_fish_subcommand ++
    completions_fish_tail;

const completions_fish_subcommand = "complete -c tigerstyle-lsp -n __fish_use_subcommand -a ";

const completions_fish_head =
    \\complete -c tigerstyle-lsp -f
    \\complete -c tigerstyle-lsp -n __fish_use_subcommand -a check -d 'Check the given paths'
    \\complete -c tigerstyle-lsp -n __fish_use_subcommand -a clean -d 'Remove the cache directories'
    \\complete -c tigerstyle-lsp -n __fish_use_subcommand -a config -d 'Print the resolved settings'
    \\complete -c tigerstyle-lsp -n __fish_use_subcommand -a rule -d 'Explain a rule'
    \\complete -c tigerstyle-lsp -n __fish_use_subcommand -a server -d 'Speak LSP over stdio'
    \\
;

const completions_fish_tail =
    \\version -d 'Print the version'
    \\complete -c tigerstyle-lsp -l fix -d 'Apply the safe fixes'
    \\complete -c tigerstyle-lsp -l diff -d 'Print what a fix run would change'
    \\complete -c tigerstyle-lsp -l format -r -d 'Choose an output format'
;

const completions_zsh = completions_zsh_head ++ completions_zsh_arguments ++
    completions_zsh_tail;

const completions_zsh_head =
    \\#compdef tigerstyle-lsp
    \\
    \\_tigerstyle_lsp() {
    \\  local -a commands
    \\  commands=(check clean completions config rule server tokens version selftest)
    \\
    \\  _arguments
;

const completions_zsh_arguments = " '1:command:(${commands})' '--format[Choose an output " ++
    "format]:format:(azure concise full github gitlab grouped json json-lines junit pylint " ++
    "rdjson sarif)' '--fix[Apply the safe fixes]' '--diff[Print what a fix run would " ++
    "change]' '*:file:_files'";

const completions_zsh_tail =
    \\
    \\}
    \\
    \\_tigerstyle_lsp "$@"
;

pub fn parse(options: *Options, arguments: *Arguments) ?Exit {
    assert(options.paths.empty());
    assert(arguments.count() <= argument_count_max);

    if (mode_parse(options, arguments)) |exit| return exit;

    for (0..argument_count_max) |_| {
        const word = arguments.next() orelse break;

        const option = switch (word) {
            .positional => |text| {
                if (options.paths.full()) return .usage;

                options.paths.push(text);

                continue;
            },
            .option => |option| option,
        };

        if (exit_of_name(option.name)) |exit| return exit;

        if (flags.get(option.name)) |flag| {
            if (option.value != null) return .{ .unexpected = option.name };

            flag_set(options, flag);

            continue;
        }

        const value = arguments.value(option.name, option.value) catch |err| switch (err) {
            error.ValueMissing => return .usage,
        };

        if (value_set(options, option.name, value)) |exit| return exit;
    } else return .usage;

    return paths_check(options);
}

fn mode_parse(options: *Options, arguments: *Arguments) ?Exit {
    const first = arguments.next() orelse return .usage;

    const text = switch (first) {
        .positional => |positional| positional,
        .option => |option| return exit_of_name(option.name) orelse .usage,
    };

    const word = words.get(text) orelse return .usage;

    const mode: Mode = switch (word) {
        .artifacts => .artifacts,
        .check, .lint => .lint,
        .clean => .clean,
        .completions => return completions_of(arguments),
        .config => .config,
        .format => .format,
        .rule => .rule,
        .selftest => return selftest_parse(options, arguments),
        .server => .server,
        .tokens => .tokens,
        .version => return .version,
    };

    const subject: ?[]const u8 = switch (mode) {
        .artifacts, .rule => switch (positional_next(arguments)) {
            .absent => null,
            .option => |name| return .{ .unexpected = name },
            .text => |subject_text| subject_text,
        },
        .clean, .config, .format, .lint, .selftest, .server, .tokens => null,
    };

    options.defaults_set(mode, subject);

    assert(options.mode != .selftest);

    return null;
}

fn completions_of(arguments: *Arguments) Exit {
    const name = switch (positional_next(arguments)) {
        .absent => return .usage,
        .option => |option| return .{ .unexpected = option },
        .text => |text| text,
    };

    if (std.mem.eql(u8, name, "bash")) return .{ .completions = completions_bash };
    if (std.mem.eql(u8, name, "fish")) return .{ .completions = completions_fish };
    if (std.mem.eql(u8, name, "zsh")) return .{ .completions = completions_zsh };
    return .usage;
}

fn selftest_parse(options: *Options, arguments: *Arguments) ?Exit {
    const name = switch (positional_next(arguments)) {
        .absent => return .usage,
        .option => |option| return .{ .unexpected = option },
        .text => |text| text,
    };

    const case = std.meta.stringToEnum(Selftest.Case, name) orelse return .usage;

    options.defaults_set(.{ .selftest = case }, null);

    assert(options.mode == .selftest);
    assert(options.paths.empty());

    return null;
}

fn positional_next(arguments: *Arguments) Next {
    const word = arguments.next() orelse return .absent;

    const next: Next = switch (word) {
        .positional => |text| .{ .text = text },
        .option => |option| .{ .option = option.name },
    };

    assert(arguments.consumed_count() > 0);

    return next;
}

fn exit_of_name(name: []const u8) ?Exit {
    assert(name.len > 0);

    if (std.mem.eql(u8, name, "-h")) return .help;
    if (std.mem.eql(u8, name, "--help")) return .help;
    if (std.mem.eql(u8, name, "-V")) return .version;
    if (std.mem.eql(u8, name, "--version")) return .version;
    return null;
}

fn flag_set(options: *Options, flag: Flag) void {
    switch (flag) {
        inline else => |tag| {
            comptime assert(@FieldType(Options, @tagName(tag)) == bool);

            @field(options, @tagName(tag)) = true;
        },
    }
}

fn value_set(options: *Options, name: []const u8, value: []const u8) ?Exit {
    assert(name.len > 0);

    const chosen = values.get(name) orelse return threshold_set(options, name, value);

    switch (chosen) {
        .baseline => options.baseline = value,
        .cache_dir => options.cache_dir = value,
        .color => options.color = value,
        .config => options.config = value,
        .exclude => return list_push(&options.excludes, value),
        .extend_fixable => return list_split(&options.extend_fixable, value),
        .extend_select => return list_split(&options.extend_select, value),
        .fixable => return list_split(&options.fixable, value),
        .format => options.format = Format.of(value) orelse return .usage,
        .ignore => return list_split(&options.ignore, value),
        .include => return list_push(&options.includes, value),
        .language => options.language = value,
        .output_file => options.output_file = value,
        .per_file_ignores => return list_push(&options.per_file_ignores, value),
        .respect_gitignore => {
            options.respect_gitignore = Arguments.boolean_of(value) orelse return .usage;
        },
        .select => return list_split(&options.select, value),
        .stdin_filename => options.stdin_filename = value,
        .unfixable => return list_split(&options.unfixable, value),
        .write_baseline => options.write_baseline = value,
    }

    return null;
}

fn threshold_set(options: *Options, name: []const u8, value: []const u8) ?Exit {
    const key = thresholds.get(name) orelse return .{ .unexpected = name };

    assert(key.len > 0);

    if (options.thresholds.full()) return .usage;

    options.thresholds.push(.{ .key = key, .value = value });

    return null;
}

fn list_push(list: *List, value: []const u8) ?Exit {
    if (list.full()) return .usage;

    list.push(value);

    assert(list.count() > 0);

    return null;
}

fn list_split(list: *List, value: []const u8) ?Exit {
    const list_count_before = list.count();

    Arguments.split_into(list, value) catch |err| switch (err) {
        error.ArgfileExhausted,
        error.CommandLineExhausted,
        error.TargetExhausted,
        error.TextExhausted,
        error.WordsExhausted,
        => return .usage,
    };

    assert(list.count() >= list_count_before);

    return null;
}

fn paths_check(options: *Options) ?Exit {
    switch (options.mode) {
        .format, .lint => {
            if (options.paths.empty()) options.paths.push(".");
        },
        .tokens => {
            if (options.paths.count() != 1) return .usage;
        },
        .selftest, .server => {
            if (!options.paths.empty()) return .usage;
        },
        .artifacts, .clean, .config, .rule => {},
    }

    if (options.mode == .lint) assert(!options.paths.empty());

    return null;
}

fn parsed(given: []const []const u8) !struct { Arguments, Options, ?Exit } {
    const gpa = std.testing.allocator;

    var arguments: Arguments = try .init(gpa, arguments_capacity);
    errdefer arguments.deinit(gpa);

    try arguments.load_words(std.testing.io, given);

    var options: Options = try .init(gpa);
    errdefer options.deinit(gpa);

    const exit = parse(&options, &arguments);
    return .{ arguments, options, exit };
}

test "the level arguments parse into a lint run over one path" {
    const gpa = std.testing.allocator;

    var arguments, var options, const exit = try parsed(&.{
        "check",
        "--isolated",
        "--no-cache",
        "--exit-zero",
        "--color",
        "never",
        "--format",
        "json",
        "--select",
        "ALL",
        "--preview",
        "a.rs",
    });

    defer arguments.deinit(gpa);
    defer options.deinit(gpa);

    try std.testing.expectEqual(null, exit);
    try std.testing.expectEqual(Mode.lint, options.mode);
    try std.testing.expect(options.isolated);
    try std.testing.expect(options.no_cache);
    try std.testing.expect(options.exit_zero);
    try std.testing.expect(options.preview);
    try std.testing.expectEqual(Format.json, options.format);
    try std.testing.expectEqualStrings("never", options.color.?);
    try std.testing.expectEqualStrings("ALL", options.select.get(0));
    try std.testing.expectEqualStrings("a.rs", options.paths.get(0));
}

test "a flag given a value is an unexpected argument" {
    const gpa = std.testing.allocator;

    var arguments, var options, const exit = try parsed(&.{ "check", "--fix=yes" });
    defer arguments.deinit(gpa);
    defer options.deinit(gpa);

    try std.testing.expectEqualStrings("--fix", exit.?.unexpected);
}

test "tokens takes exactly one path" {
    const gpa = std.testing.allocator;

    var arguments, var options, const exit = try parsed(&.{ "tokens", "a.rs", "b.rs" });
    defer arguments.deinit(gpa);
    defer options.deinit(gpa);

    try std.testing.expectEqual(Exit.usage, exit.?);
}

test "a lint run with no path checks the working directory" {
    const gpa = std.testing.allocator;

    var arguments, var options, const exit = try parsed(&.{ "check", "--select", "TS001, ,TS002" });
    defer arguments.deinit(gpa);
    defer options.deinit(gpa);

    try std.testing.expectEqual(null, exit);
    try std.testing.expectEqualStrings(".", options.paths.get(0));
    try std.testing.expectEqual(@as(u32, 2), options.select.count());
    try std.testing.expectEqualStrings("TS002", options.select.get(1));
}

test "a threshold flag is kept under its config key" {
    const gpa = std.testing.allocator;

    var arguments, var options, const exit = try parsed(&.{ "check", "--parameters-max", "9" });
    defer arguments.deinit(gpa);
    defer options.deinit(gpa);

    try std.testing.expectEqual(null, exit);
    try std.testing.expectEqualStrings("parameters_max", options.thresholds.get(0).key);
    try std.testing.expectEqualStrings("9", options.thresholds.get(0).value);
}

test "an unknown option consumes its value and is then refused" {
    const gpa = std.testing.allocator;

    var arguments, var options, const exit = try parsed(&.{ "check", "--bogus", "x" });
    defer arguments.deinit(gpa);
    defer options.deinit(gpa);

    try std.testing.expectEqualStrings("--bogus", exit.?.unexpected);
}
