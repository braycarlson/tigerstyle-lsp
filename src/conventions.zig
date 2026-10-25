const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const go = @import("conventions/go.zig");
const javascript = @import("conventions/javascript.zig");
const odin = @import("conventions/odin.zig");
const python = @import("conventions/python.zig");
const rust = @import("conventions/rust.zig");
const zig = @import("conventions/zig.zig");
const Language = scylla.Language;
const Returns = scylla.Calls.Returns;

allocation_functions: []const []const u8 = &.{},
allocation_methods: []const []const u8 = &.{},
arguments_are_named: bool = false,
arms_open_with_else: bool = false,
arrows_open_lambdas: bool = false,
assertion_condition_spans_arguments: bool = false,
assertion_helpers_take_a_context_first: bool = false,
assertions_omit_parentheses: bool = false,
assertions_survive_release: []const []const u8 = &.{},
assignment_declares: bool = false,
bindings_outlive_blocks: bool = false,
boolean_type_names: []const []const u8 = &.{},
brace_literal_markers: []const []const u8 = &.{},
call_checked_methods: []const []const u8 = &.{},
call_exempt_names: []const []const u8 = &.{},
call_value_methods: []const []const u8 = &.{},
call_value_methods_niladic: []const []const u8 = &.{},
call_value_names: []const []const u8 = &.{},
call_value_names_paired: []const []const u8 = &.{},
call_void_methods: []const []const u8 = &.{},
call_void_names: []const []const u8 = &.{},
callback_markers: []const []const u8 = &.{},
channel_word: []const u8 = "",
class_name_suffixes: []const []const u8 = &.{},
class_names_title_case: bool = false,
class_type_names: []const []const u8 = &.{},
collections_allocate: bool = false,
comment_directives: []const []const u8 = &.{},
comment_doc_markers: []const []const u8 = &.{},
comment_docs_read: bool = false,
comparisons_dispatch_to_methods: bool = false,
compiler_rejects_a_dropped_error: bool = false,
compiler_rejects_an_unmutated_variable: bool = false,
compiler_rejects_an_unused_parameter: bool = false,
conditional_markers: []const []const u8 = &.{},
conditional_markers_need_a_branch: bool = false,
conditional_path_suffixes: []const []const u8 = &.{},
constants_bind_objects: bool = false,
container_words: []const []const u8 = &.{},
context_argument_suffixes: []const []const u8 = &.{},
context_words: []const []const u8 = &.{},
declaration_test_words: []const []const u8 = &.{},
declarations_spell_constancy: bool = false,
declarations_spell_types_after_names: bool = false,
declarations_spell_visibility: bool = false,
dictated_name_prefixes: []const []const u8 = &.{},
dictated_names: []const []const u8 = &.{},
division_assumes_integers: bool = false,
division_names_rounding: bool = false,
double_underscore_names_dictated: bool = false,
dynamic_exec_names: []const []const u8 = &.{},
dynamic_exec_paths: []const []const u8 = &.{},
dynamic_exec_string_names: []const []const u8 = &.{},
empty_braces_spell_options: bool = false,
empty_option_suffixes: []const []const u8 = &.{},
error_default_methods: []const []const u8 = &.{},
error_discard_methods: []const []const u8 = &.{},
error_discard_names: []const []const u8 = &.{},
error_returning_methods: []const []const u8 = &.{},
fields_unbound: bool = false,
formatter_splits_one_line_branches: bool = false,
global_host_names: []const []const u8 = &.{},
handlers_end_with_colon: bool = false,
indent_with_tabs: bool = false,
iteration_word: []const u8 = "",
line_length_exempt_prefixes: []const []const u8 = &.{},
macros_invoke_with_bang: bool = false,
measurable_types: []const []const u8 = &.{},
member_field_words: []const []const u8 = &.{},
member_type_words: []const []const u8 = &.{},
members_end_with_comma: bool = false,
members_unbound: bool = false,
mutation_functions: []const []const u8 = &.{},
mutation_methods: []const []const u8 = &.{},
nested_functions_can_be_closures: bool = false,
nesting_words: []const []const u8 = &.{},
optional_markers: []const []const u8 = &.{},
outer_scope_words: []const []const u8 = &.{},
parameter_exempt_prefixes: []const []const u8 = &.{},
parameter_skip_names: []const []const u8 = &.{},
parameter_valueless_types: []const []const u8 = &.{},
plus_plus_concatenates: bool = false,
pointer_boundary_bodies: []const []const u8 = &.{},
pointer_boundary_markers: []const []const u8 = &.{},
pointer_function_markers: []const []const u8 = &.{},
pointer_pointee_markers: []const []const u8 = &.{},
pointer_raw_prefixes: []const []const u8 = &.{},
pointer_sigils: []const []const u8 = &.{},
pointer_unsafe_names: []const []const u8 = &.{},
queue_bound_words: []const []const u8 = &.{},
queue_data_first_names: []const []const u8 = &.{},
queue_unbounded_names: []const []const u8 = &.{},
queue_zero_bound_words: []const []const u8 = &.{},
receiver_names: []const []const u8 = &.{},
reserved_words: []const []const u8 = &.{},
recovery_call_names: []const []const u8 = &.{},
recovery_event_names: []const []const u8 = &.{},
recovery_except_names: []const []const u8 = &.{},
result_flag_types: []const []const u8 = &.{},
result_nil_prefixes: []const []const u8 = &.{},
returns_are_spelled: bool = true,
returns_nothing_words: []const []const u8 = &.{},
returns_tail_expression: bool = false,
scope_words: []const []const u8 = &.{},
slices_copy: bool = false,
statements_need_a_function: bool = false,
stored_value_methods: []const []const u8 = &.{},
strings_build_prefixes: []const []const u8 = &.{},
strings_bytes_prefixes: []const []const u8 = &.{},
strings_concatenate_allocate: bool = false,
suppression_markers: []const []const u8 = &.{},
suspension_methods: []const []const u8 = &.{},
suspension_words: []const []const u8 = &.{},
suspension_words_postfix: []const []const u8 = &.{},
title_case_names_types: bool = false,
type_checking_markers: []const []const u8 = &.{},
type_stop_words: []const []const u8 = &.{},
types_are_values: bool = false,
unsafe_audit_markers: []const []const u8 = &.{},
unsafe_word: []const u8 = "",
unused_import_suppressions: []const []const u8 = &.{},

const Conventions = @This();
pub const Field = std.meta.FieldEnum(Conventions);
pub const default: Conventions = .{};

pub fn of_language(language: Language) *const Conventions {
    const held: *const Conventions = switch (language) {
        .css, .markup => &default,
        .go => &go.conventions,
        .javascript => &javascript.javascript,
        .odin => &odin.conventions,
        .python => &python.conventions,
        .rust => &rust.conventions,
        .typescript => &javascript.typescript,
        .zig => &zig.conventions,
    };

    if (held.comment_docs_read) assert(held.comment_doc_markers.len > 0);
    if (held.conditional_markers_need_a_branch) assert(held.conditional_markers.len > 0);
    if (held.queue_bound_words.len > 0) assert(held.queue_unbounded_names.len > 0);
    if (held.queue_data_first_names.len > 0) assert(held.queue_unbounded_names.len > 0);

    return held;
}

pub fn returns(conventions: *const Conventions) Returns {
    if (conventions.returns_are_spelled) {
        assert(conventions.returns_nothing_words.len == 0);
    } else {
        assert(conventions.returns_nothing_words.len > 0);
    }

    return .{
        .nothing_words = conventions.returns_nothing_words,
        .optional_markers = conventions.optional_markers,
        .spelled = conventions.returns_are_spelled,
    };
}

pub fn carries(conventions: *const Conventions, comptime field: Field) bool {
    const name = @tagName(field);
    const value = @field(conventions, name);
    const value_default = @field(default, name);

    const carried = switch (@FieldType(Conventions, name)) {
        bool => value != value_default,
        []const u8, []const []const u8 => carried: {
            comptime assert(value_default.len == 0);

            break :carried value.len > 0;
        },
        else => comptime unreachable,
    };

    if (conventions == &default) assert(!carried);

    return carried;
}

test {
    _ = go;
    _ = javascript;
    _ = odin;
    _ = python;
    _ = rust;
    _ = zig;
}
