const std = @import("std");
const Conventions = @import("../conventions.zig");

pub const javascript: Conventions = .{
    .allocation_functions = &allocation_functions,
    .allocation_methods = &allocation_methods,
    .arrows_open_lambdas = true,
    .boolean_type_names = &.{"boolean"},
    .brace_literal_markers = &.{""},
    .call_value_methods = &value_methods,
    .call_value_names = &value_names,
    .call_void_names = &void_names,
    .callback_markers = &.{ "=>", "Function", "function(" },
    .collections_allocate = true,
    .comment_directives = &.{ "eslint", "global", "jshint", "prettier", "ts-" },
    .comment_doc_markers = &.{"*"},
    .constants_bind_objects = true,
    .container_words = &.{"class"},
    .dictated_names = &.{ "afterEach", "beforeEach" },
    .dynamic_exec_names = &.{ "Function", "eval" },
    .dynamic_exec_paths = &dynamic_exec_paths,
    .dynamic_exec_string_names = &.{ "setInterval", "setTimeout" },
    .empty_braces_spell_options = true,
    .empty_option_suffixes = &.{"{}"},
    .fields_unbound = true,
    .global_host_names = &.{ "global", "globalThis", "window" },
    .members_unbound = true,
    .mutation_methods = &mutation_methods,
    .nested_functions_can_be_closures = true,
    .nesting_words = &.{ "catch", "finally" },
    .optional_markers = &.{ "null", "undefined" },
    .parameter_skip_names = &.{"this"},
    .recovery_event_names = &.{ "onerror", "uncaughtException", "unhandledRejection" },
    .returns_are_spelled = false,
    .returns_nothing_words = &.{"undefined"},
    .statements_need_a_function = true,
    .strings_build_prefixes = &.{"`"},
    .strings_concatenate_allocate = true,
    .suppression_markers = &suppression_markers,
    .suspension_words = &.{ "await", "yield" },
    .title_case_names_types = true,
};

pub const typescript: Conventions = typescript: {
    var conventions = javascript;
    conventions.container_words = &.{ "class", "interface" };
    conventions.title_case_names_types = true;

    break :typescript conventions;
};

const allocation_functions = [_][]const u8{
    "Array",
    "Array.from",
    "Array.of",
    "ArrayBuffer",
    "BigInt64Array",
    "BigUint64Array",
    "Float32Array",
    "Float64Array",
    "Int16Array",
    "Int32Array",
    "Int8Array",
    "JSON.parse",
    "Map",
    "Object",
    "Object.assign",
    "Object.create",
    "Set",
    "Uint16Array",
    "Uint32Array",
    "Uint8Array",
    "Uint8ClampedArray",
    "WeakMap",
    "WeakSet",
};

const allocation_methods = [_][]const u8{ "concat", "filter", "map", "push", "slice" };

const dynamic_exec_paths = [_][]const u8{
    "globalThis.Function",
    "globalThis.eval",
    "self.Function",
    "self.eval",
    "vm.Script",
    "vm.compileFunction",
    "vm.runInContext",
    "vm.runInNewContext",
    "vm.runInThisContext",
    "window.Function",
    "window.eval",
};

const mutation_methods = [_][]const u8{
    "add",
    "assign",
    "clear",
    "copyWithin",
    "delete",
    "fill",
    "next",
    "pop",
    "push",
    "remove",
    "reverse",
    "set",
    "shift",
    "sort",
    "splice",
    "unshift",
};

const suppression_markers = [_][]const u8{
    "biome-ignore",
    "eslint-disable",
    "ts-expect-error",
    "ts-ignore",
    "ts-nocheck",
    "tslint:disable",
};

const value_methods = [_][]const u8{
    "at",
    "charAt",
    "concat",
    "delete",
    "endsWith",
    "every",
    "filter",
    "find",
    "flat",
    "has",
    "includes",
    "indexOf",
    "join",
    "map",
    "padEnd",
    "padStart",
    "pop",
    "repeat",
    "replace",
    "shift",
    "slice",
    "some",
    "split",
    "startsWith",
    "toLowerCase",
    "toString",
    "toUpperCase",
    "trim",
};

const value_names = [_][]const u8{
    "JSON.parse",
    "JSON.stringify",
    "Number",
    "Object.entries",
    "Object.keys",
    "Object.values",
    "String",
    "fetch",
    "parseFloat",
    "parseInt",
    "structuredClone",
};

const void_names = [_][]const u8{
    "console.debug",
    "console.error",
    "console.info",
    "console.log",
    "console.trace",
    "console.warn",
    "process.exit",
    "queueMicrotask",
    "setImmediate",
    "setInterval",
    "setTimeout",
};

test "the conventions carry every field the lexer sets" {
    try std.testing.expect(javascript.carries(.allocation_functions));
    try std.testing.expect(javascript.carries(.call_value_methods));
    try std.testing.expect(javascript.carries(.call_void_names));
    try std.testing.expect(javascript.carries(.callback_markers));
    try std.testing.expect(javascript.carries(.collections_allocate));
    try std.testing.expect(javascript.carries(.comment_directives));
    try std.testing.expect(javascript.carries(.comment_doc_markers));
    try std.testing.expect(javascript.carries(.container_words));
    try std.testing.expect(javascript.carries(.dynamic_exec_names));
    try std.testing.expect(javascript.carries(.empty_braces_spell_options));
    try std.testing.expect(javascript.carries(.mutation_methods));
    try std.testing.expect(javascript.carries(.nested_functions_can_be_closures));
    try std.testing.expect(javascript.carries(.nesting_words));
    try std.testing.expect(javascript.carries(.optional_markers));
    try std.testing.expect(javascript.carries(.parameter_skip_names));
    try std.testing.expect(javascript.carries(.returns_are_spelled));
    try std.testing.expect(javascript.carries(.returns_nothing_words));
    try std.testing.expect(javascript.carries(.statements_need_a_function));
    try std.testing.expect(javascript.carries(.suppression_markers));
}

test "the typescript conventions carry every field the lexer sets" {
    try std.testing.expect(typescript.carries(.title_case_names_types));
    try std.testing.expectEqual(javascript.returns_are_spelled, typescript.returns_are_spelled);

    try std.testing.expectEqualDeep(
        javascript.returns_nothing_words,
        typescript.returns_nothing_words,
    );
}
