const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const Registry = scylla.rule.Registry;

pub const modules = .{
    @import("safety/no_recursion.zig"),
    @import("shape/function_too_long.zig"),
    @import("shape/too_many_parameters.zig"),
    @import("shape/assert_density.zig"),
    @import("safety/no_mutable_globals.zig"),
    @import("control/bounded_loops.zig"),
    @import("safety/no_dynamic_exec.zig"),
    @import("shape/nesting_depth.zig"),
    @import("safety/no_bare_except.zig"),
    @import("safety/no_pass_in_except.zig"),
    @import("safety/no_star_import.zig"),
    @import("format/line_too_long.zig"),
    @import("safety/no_global_statement.zig"),
    @import("shape/no_nested_functions.zig"),
    @import("safety/no_lambda.zig"),
    @import("safety/no_warning_suppression.zig"),
    @import("control/no_compound_condition.zig"),
    @import("control/split_compound_assert.zig"),
    @import("naming/big_endian_names.zig"),
    @import("format/four_space_indent.zig"),
    @import("control/if_braces.zig"),
    @import("format/comment_form.zig"),
    @import("naming/snake_case_names.zig"),
    @import("naming/no_abbreviations.zig"),
    @import("control/positive_invariants.zig"),
    @import("naming/acronym_case.zig"),
    @import("control/assert_implication.zig"),
    @import("shape/main_first.zig"),
    @import("control/trivial_assert.zig"),
    @import("memory/no_dynamic_alloc.zig"),
    @import("safety/check_return_value.zig"),
    @import("safety/no_complex_macros.zig"),
    @import("types/restrict_pointers.zig"),
    @import("control/no_goto.zig"),
    @import("assertion/assert_parameters.zig"),
    @import("assertion/assert_return_value.zig"),
    @import("types/explicit_sized_types.zig"),
    @import("safety/no_silent_error_swallow.zig"),
    @import("shape/options_struct.zig"),
    @import("shape/callback_last.zig"),
    @import("safety/conditional_compilation.zig"),
    @import("assertion/assert_side_effects.zig"),
    @import("control/else_if_chain.zig"),
    @import("control/division_intent.zig"),
    @import("types/simple_return_type.zig"),
    @import("shape/declaration_distance.zig"),
    @import("shape/member_order.zig"),
    @import("naming/no_alias.zig"),
    @import("memory/allocation_grouping.zig"),
    @import("suppression/unused_suppression.zig"),
    @import("types/pointer_depth.zig"),
    @import("safety/no_panic_recovery.zig"),
    @import("shape/explicit_options.zig"),
    @import("control/run_to_completion.zig"),
    @import("format/trailing_comma.zig"),
    @import("memory/bounded_queues.zig"),
    @import("naming/callback_name_prefix.zig"),
};

pub const rule_count = modules.len;

comptime {
    @setEvalBranchQuota(40_000);

    assert(rule_count == 57);
    assert(rule_count <= scylla.limits.rule_count_max);

    for (modules, 0..) |module, index| {
        assert(@hasDecl(module, "rule"));
        assert(module.rule.code.len == "TS000".len);
        assert(module.rule.description.len > 0);

        for (modules, 0..) |other, other_index| {
            if (other_index == index) continue;

            assert(!std.mem.eql(u8, other.rule.code, module.rule.code));
            assert(!std.mem.eql(u8, other.rule.name, module.rule.name));
        }
    }
}

pub fn registry_init(gpa: std.mem.Allocator) std.mem.Allocator.Error!Registry {
    var registry: Registry = try .init(gpa, rule_count);
    errdefer registry.deinit(gpa);

    inline for (modules) |module| {
        registry.register(&module.rule);
    }

    assert(registry.count() == rule_count);
    assert(registry.find(modules[0].rule.code) != null);

    return registry;
}

test registry_init {
    var registry = try registry_init(std.testing.allocator);
    defer registry.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, rule_count), registry.count());
    try std.testing.expectEqualStrings("TS001", registry.at(0).code);
    try std.testing.expectEqual(@as(?u32, null), registry.index_of("TS999"));
}
