const std = @import("std");
const Conventions = @import("../conventions.zig");

pub const conventions: Conventions = .{
    .allocation_functions = &allocation_functions,
    .arguments_are_named = true,
    .assignment_declares = true,
    .boolean_type_names = &.{"bool"},
    .brace_literal_markers = &.{ "[dynamic]", "map[" },
    .call_value_names = &value_names,
    .call_value_names_paired = &.{ "pop_safe", "strconv.parse_int" },
    .call_void_names = &void_names,
    .callback_markers = &.{ "proc (", "proc(" },
    .comment_directives = &.{ "+build", "odinfmt:" },
    .comment_doc_markers = &.{"/"},
    .conditional_markers = &conditional_markers,
    .conditional_markers_need_a_branch = true,
    .container_words = &.{ "bit_field", "struct", "union" },
    .declarations_spell_constancy = true,
    .empty_option_suffixes = &.{"{}"},
    .indent_with_tabs = true,
    .measurable_types = &measurable_types,
    .members_end_with_comma = true,
    .mutation_methods = &mutation_methods,
    .optional_markers = &.{"Maybe("},
    .parameter_skip_names = &.{"_"},
    .pointer_boundary_bodies = &.{"---"},
    .pointer_boundary_markers = &.{"foreign"},
    .pointer_function_markers = &.{"proc("},
    .pointer_raw_prefixes = &.{ "[^", "transmute(^" },
    .pointer_sigils = &.{ "[^]", "^" },
    .pointer_unsafe_names = &.{ "rawptr", "uintptr" },
    .queue_data_first_names = &.{"init"},
    .queue_unbounded_names = &.{"queue.init"},
    .reserved_words = &.{"package"},
    .result_flag_types = &.{ "Error", "bool" },
    .statements_need_a_function = true,
    .suppression_markers = &.{ "#no_bounds_check", "odinfmt: disable" },
    .title_case_names_types = true,
    .types_are_values = true,
};

const allocation_functions = [_][]const u8{
    "append",
    "fmt.aprintf",
    "fmt.tprintf",
    "make",
    "make_dynamic_array",
    "make_map",
    "make_multi_pointer",
    "make_slice",
    "mem.alloc",
    "new",
    "new_clone",
    "reserve",
    "resize",
    "strings.builder_make",
    "strings.clone",
    "strings.concatenate",
};

const conditional_markers = [_][]const u8{
    "#+build",
    "#config(",
    "//+build",
    "ODIN_ARCH",
    "ODIN_BUILD_MODE",
    "ODIN_DEBUG",
    "ODIN_DISABLE_ASSERT",
    "ODIN_NO_BOUNDS_CHECK",
    "ODIN_OPTIMIZATION_MODE",
    "ODIN_OS",
};

const measurable_types = [_][]const u8{
    "f16",
    "f32",
    "f64",
    "i128",
    "i16",
    "i32",
    "i64",
    "i8",
    "int",
    "u128",
    "u16",
    "u32",
    "u64",
    "u8",
    "uint",
    "uintptr",
};

const mutation_methods = [_][]const u8{
    "append",
    "append_elem",
    "append_elems",
    "append_string",
    "clear",
    "delete_key",
    "inject_at",
    "ordered_remove",
    "pop",
    "pop_front",
    "push",
    "remove_range",
    "reserve",
    "resize",
    "shrink",
    "unordered_remove",
    "write",
    "write_string",
};

const value_names = [_][]const u8{
    "abs",
    "cap",
    "clamp",
    "fmt.aprint",
    "fmt.aprintf",
    "fmt.tprint",
    "fmt.tprintf",
    "len",
    "max",
    "min",
    "pop",
    "pop_front",
    "pop_safe",
    "strconv.atoi",
    "strconv.itoa",
    "strconv.parse_int",
    "strings.clone",
    "strings.concatenate",
    "strings.contains",
    "strings.has_prefix",
    "strings.has_suffix",
    "strings.join",
    "strings.split",
    "strings.to_lower",
    "strings.to_upper",
    "strings.trim",
    "strings.trim_space",
};

const void_names = [_][]const u8{
    "fmt.eprint",
    "fmt.eprintf",
    "fmt.eprintln",
    "fmt.print",
    "fmt.printf",
    "fmt.println",
    "free",
    "free_all",
    "log.debug",
    "log.debugf",
    "log.error",
    "log.errorf",
    "log.fatal",
    "log.info",
    "log.infof",
    "log.warn",
    "log.warnf",
    "os.exit",
    "panic",
    "unimplemented",
};

test "the conventions carry every field the lexer sets" {
    try std.testing.expect(conventions.carries(.allocation_functions));
    try std.testing.expect(conventions.carries(.arguments_are_named));
    try std.testing.expect(conventions.carries(.assignment_declares));
    try std.testing.expect(conventions.carries(.call_value_names_paired));
    try std.testing.expect(conventions.carries(.call_void_names));
    try std.testing.expect(conventions.carries(.callback_markers));
    try std.testing.expect(conventions.carries(.comment_directives));
    try std.testing.expect(conventions.carries(.comment_doc_markers));
    try std.testing.expect(conventions.carries(.conditional_markers_need_a_branch));
    try std.testing.expect(conventions.carries(.container_words));
    try std.testing.expect(conventions.carries(.declarations_spell_constancy));
    try std.testing.expect(conventions.carries(.measurable_types));
    try std.testing.expect(conventions.carries(.members_end_with_comma));
}

test "the conventions carry every type field the lexer sets" {
    try std.testing.expect(conventions.carries(.mutation_methods));
    try std.testing.expect(conventions.carries(.optional_markers));
    try std.testing.expect(conventions.carries(.parameter_skip_names));
    try std.testing.expect(conventions.carries(.pointer_raw_prefixes));
    try std.testing.expect(conventions.carries(.statements_need_a_function));
    try std.testing.expect(conventions.carries(.suppression_markers));
    try std.testing.expect(conventions.carries(.title_case_names_types));
    try std.testing.expect(conventions.carries(.types_are_values));
}
