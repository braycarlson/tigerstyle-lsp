const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const toml = @import("toml");
const catalog = @import("../rules/catalog.zig");
const Draft = @import("draft.zig");
const Limits = @import("../limits.zig");
const Setting = scylla.config.Setting;

pub const options = [_]Setting{
    .{
        .default = "2",
        .description = "The assertions a function of more than ten lines is expected to carry.",
        .example = "assertions_per_function_min = 2",
        .kind = .integer,
        .name = "assertions_per_function_min",
    },
    .{
        .default = "",
        .description = "The directory the clean-file cache is written under.",
        .example = "cache_dir = \".tigerstyle_cache\"",
        .kind = .text,
        .name = "cache_dir",
    },
    .{
        .default = "5",
        .description = "The statements a binding may sit above its first use.",
        .example = "declaration_distance_max = 5",
        .kind = .integer,
        .name = "declaration_distance_max",
    },
    .{
        .default = "3",
        .description = "The branches an else-if chain may run before it is split into a tree.",
        .example = "else_if_chain_max = 3",
        .kind = .integer,
        .name = "else_if_chain_max",
    },
    .{
        .default = "",
        .description = "The glob patterns the walk skips, replacing the defaults.",
        .example = "exclude = [\"vendor/**\"]",
        .kind = .strings,
        .name = "exclude",
    },
    .{
        .default = "",
        .description = "A configuration file this one inherits from, resolved outermost first.",
        .example = "extend = \"../tigerstyle.toml\"",
        .kind = .text,
        .name = "extend",
    },
    .{
        .default = "",
        .description = "The glob patterns the walk skips, beside the defaults.",
        .example = "extend_exclude = [\"corpus/**\"]",
        .kind = .strings,
        .name = "extend_exclude",
    },
    .{
        .default = "",
        .description = "The rules whose fixes may be applied, beside the ones fixable names.",
        .example = "extend_fixable = [\"TS031\"]",
        .kind = .strings,
        .name = "extend_fixable",
    },
    .{
        .default = "",
        .description = "The glob patterns the walk takes in, beside the ones include names.",
        .example = "extend_include = [\"scripts/**\"]",
        .kind = .strings,
        .name = "extend_include",
    },
    .{
        .default = "",
        .description = "Per-file rule suppressions, beside the ones per_file_ignores names.",
        .example = "[extend-per-file-ignores]\n\"tests/*\" = [\"TS004\"]",
        .kind = .map,
        .name = "extend_per_file_ignores",
    },
    .{
        .default = "",
        .description = "The rules whose fixes are treated as safe, beside the defaults.",
        .example = "extend_safe_fixes = [\"TS031\"]",
        .kind = .strings,
        .name = "extend_safe_fixes",
    },
    .{
        .default = "",
        .description = "The rules turned on beside the default set.",
        .example = "extend_select = [\"TS032\", \"TS037\"]",
        .kind = .strings,
        .name = "extend_select",
    },
    .{
        .default = "",
        .description = "The rules whose fixes are treated as unsafe, beside the defaults.",
        .example = "extend_unsafe_fixes = [\"TS017\"]",
        .kind = .strings,
        .name = "extend_unsafe_fixes",
    },
    .{
        .default = "",
        .description = "The rules whose fixes may be applied, replacing the default set.",
        .example = "fixable = [\"TS031\"]",
        .kind = .strings,
        .name = "fixable",
    },
    .{
        .default = "false",
        .description = "Apply the exclude patterns to paths named on the command line too.",
        .example = "force_exclude = true",
        .kind = .boolean,
        .name = "force_exclude",
    },
    .{
        .default = "70",
        .description = "The lines a function may span.",
        .example = "function_lines_max = 70",
        .kind = .integer,
        .name = "function_lines_max",
    },
    .{
        .default = "",
        .description = "The rules turned off, whatever else selects them.",
        .example = "ignore = [\"TS042\"]",
        .kind = .strings,
        .name = "ignore",
    },
    .{
        .default = "",
        .description = "The glob patterns the walk takes in, replacing the defaults.",
        .example = "include = [\"src/**\"]",
        .kind = .strings,
        .name = "include",
    },
    .{
        .default = "",
        .description = "Per-language overrides of the limits and the severities.",
        .example = "[language.python]\nline_length_max = 88",
        .kind = .map,
        .name = "language",
    },
    .{
        .default = "100",
        .description = "The columns a line may span.",
        .example = "line_length_max = 100",
        .kind = .integer,
        .name = "line_length_max",
    },
    .{
        .default = "4",
        .description = "The levels a block may nest inside its function.",
        .example = "nesting_depth_max = 4",
        .kind = .integer,
        .name = "nesting_depth_max",
    },
    .{
        .default = "7",
        .description = "The parameters a function may take.",
        .example = "parameters_max = 7",
        .kind = .integer,
        .name = "parameters_max",
    },
    .{
        .default = "",
        .description = "Per-file rule suppressions, replacing the default set.",
        .example = "[per-file-ignores]\n\"tests/*\" = [\"TS004\"]",
        .kind = .map,
        .name = "per_file_ignores",
    },
    .{
        .default = "false",
        .description = "Turn on the rules still in preview.",
        .example = "preview = true",
        .kind = .boolean,
        .name = "preview",
    },
    .{
        .default = "",
        .description = "The versions of tigerstyle-lsp this configuration supports.",
        .example = "required_version = \">=0.1\"",
        .kind = .text,
        .name = "required_version",
    },
    .{
        .default = "true",
        .description = "Skip the paths the nearest .gitignore names.",
        .example = "respect_gitignore = false",
        .kind = .boolean,
        .name = "respect_gitignore",
    },
    .{
        .default = "",
        .description = "The rules turned on, replacing the default set.",
        .example = "select = [\"ALL\"]",
        .kind = .strings,
        .name = "select",
    },
    .{
        .default = "",
        .description = "Per-rule severity overrides.",
        .example = "[severity]\nTS002 = \"error\"",
        .kind = .map,
        .name = "severity",
    },
    .{
        .default = "",
        .description = "The rules whose fixes are never applied.",
        .example = "unfixable = [\"TS017\"]",
        .kind = .strings,
        .name = "unfixable",
    },
};

const example_bytes_max = 64;

const TestDocument = toml.DocumentType(.{
    .line_count_max = null,
    .node_count_max = 64,
    .text_bytes_max = 256,
});

comptime {
    for (options) |option| {
        assert(option.name.len <= scylla.limits.config_name_bytes_max);
        assert(option.example.len < example_bytes_max);
    }
}

test "the options are sorted and named once" {
    for (options, 0..) |option, index| {
        try std.testing.expect(option.description.len > 0);
        try std.testing.expect(option.example.len > 0);

        if (index == 0) continue;

        try std.testing.expect(std.mem.lessThan(u8, options[index - 1].name, option.name));
    }
}

test "every option is accepted by the parser" {
    const gpa = std.testing.allocator;

    var registry = try catalog.registry_init(gpa);
    defer registry.deinit(gpa);

    var draft: Draft = try .init(gpa, Limits.default.draft());
    defer draft.deinit(gpa);

    var document: TestDocument = undefined;

    for (options) |option| {
        var buffer: [example_bytes_max]u8 = undefined;
        const source = try std.mem.print(&buffer, "{s}\n", .{option.example});

        draft.clear();

        try document.parse(source, .{});
        try draft.apply(&document.document, &registry);
    }
}
