const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const Analysis = @import("analysis.zig");
const Configuration = @import("config/configuration.zig");
const Document = @import("document.zig");
const Documents = @import("documents.zig");
const Draft = @import("config/draft.zig");
const FrontCapacity = scylla.Front.Capacity;
const Parallel = @import("parallel.zig");
const Reporter = @import("reporter.zig");
const Watch = @import("watch.zig");
const Workspace = @import("workspace.zig");
const log = scylla.log;

artifact_bytes_max: u32,
baseline_entry_count_max: u32,
cache_bytes_max: u32,
cache_entry_count_max: u32,
call_edge_count_max: u32,
config_bytes_max: u32,
config_extend_depth_max: u32,
depth_max: u32,
diagnostic_bytes_max: u32,
diagnostic_count_max: u32,
document_count_max: u32,
file_bytes_max: u32,
file_line_count_max: u32,
fix_edit_count_max: u32,
fix_pass_count_max: u32,
format_element_count_max: u32,
front: FrontCapacity,
function_count_max: u32,
glob_bytes_max: u32,
glob_count_max: u32,
message_bytes_max: u32,
output_bytes_max: u32,
path_bytes_max: u32,
report_bytes_max: u32,
suppression_count_max: u32,
uri_bytes_max: u32,
walk_bytes_max: u32,
walk_file_count_max: u32,
workspace_bytes_max: u32,
workspace_file_count_max: u32,

const Limits = @This();

const Relation = enum {
    calls_cover_functions,
    events_cover_tokens,
    lines_within_file,
    message_over_file,
    nodes_cover_depth,
    tokens_cover_nodes,
    walk_covers_workspace,
    workspace_covers_path,
};

const artifact_bytes_max_default: u32 = 1 << 18;
const baseline_entry_count_max_default: u32 = 1 << 16;
const binding_count_max_default: u32 = 1 << 16;
const cache_bytes_max_default: u32 = 1 << 22;
const cache_entry_count_max_default: u32 = 1 << 13;
const call_edge_count_max_default: u32 = 1 << 16;
const config_bytes_max_default: u32 = 1 << 16;
const config_extend_depth_max_default: u32 = 16;
const depth_max_default: u32 = 64;
const diagnostic_bytes_max_default: u32 = 1 << 16;
const diagnostic_bytes_max_lint: u32 = 1 << 21;
const diagnostic_count_max_default: u32 = 1_024;
const diagnostic_count_max_lint: u32 = 1 << 14;
const document_count_max_default: u32 = 64;
const error_count_max_default: u32 = 1 << 10;
const event_count_max_default: u32 = 1 << 20;
const fact_count_max_default: u32 = 1 << 12;
const file_bytes_max_default: u32 = 1 << 20;
const file_line_count_max_default: u32 = 1 << 16;
const fix_edit_count_max_default: u32 = 4_096;
const fix_pass_count_max_default: u32 = 1_000;
const format_element_count_max_default: u32 = 1 << 16;
pub const function_count_max_default: u32 = 8_192;
const glob_bytes_max_default: u32 = 1 << 16;
pub const glob_class_count_max: u32 = 64;
const glob_count_max_default: u32 = 512;
const message_bytes_max_default: u32 = 4 << 20;
const node_count_max_default: u32 = 1 << 18;
const output_bytes_max_default: u32 = 1 << 16;
const path_bytes_max_default: u32 = 383;
const reference_count_max_default: u32 = 1 << 18;
const report_bytes_max_default: u32 = 1 << 20;
const report_bytes_max_lint: u32 = 1 << 24;
const scope_count_max_default: u32 = 1 << 14;
pub const selector_count_max: u32 = 64;
const suppression_count_max_default: u32 = 1_024;
const token_count_max_default: u32 = 1 << 20;
const uri_bytes_max_default: u32 = 4_096;
const walk_bytes_max_default: u32 = 1 << 23;
const walk_file_count_max_default: u32 = 1 << 16;
const workspace_bytes_max_default: u32 = 1 << 20;
const workspace_file_count_max_default: u32 = 8_192;

pub const default: Limits = .{
    .artifact_bytes_max = artifact_bytes_max_default,
    .baseline_entry_count_max = baseline_entry_count_max_default,
    .cache_bytes_max = cache_bytes_max_default,
    .cache_entry_count_max = cache_entry_count_max_default,
    .call_edge_count_max = call_edge_count_max_default,
    .config_bytes_max = config_bytes_max_default,
    .config_extend_depth_max = config_extend_depth_max_default,
    .depth_max = depth_max_default,
    .diagnostic_bytes_max = diagnostic_bytes_max_default,
    .diagnostic_count_max = diagnostic_count_max_default,
    .document_count_max = document_count_max_default,
    .file_bytes_max = file_bytes_max_default,
    .file_line_count_max = file_line_count_max_default,
    .fix_edit_count_max = fix_edit_count_max_default,
    .fix_pass_count_max = fix_pass_count_max_default,
    .format_element_count_max = format_element_count_max_default,
    .front = .{
        .diagnostic_count_max = error_count_max_default,
        .event_count_max = event_count_max_default,
        .node_count_max = node_count_max_default,
        .semantic = .{
            .binding_count_max = binding_count_max_default,
            .fact_count_max = fact_count_max_default,
            .reference_count_max = reference_count_max_default,
            .scope_count_max = scope_count_max_default,
        },
        .tag_count_max = fact_count_max_default,
        .token_count_max = token_count_max_default,
    },
    .function_count_max = function_count_max_default,
    .glob_bytes_max = glob_bytes_max_default,
    .glob_count_max = glob_count_max_default,
    .message_bytes_max = message_bytes_max_default,
    .output_bytes_max = output_bytes_max_default,
    .path_bytes_max = path_bytes_max_default,
    .report_bytes_max = report_bytes_max_default,
    .suppression_count_max = suppression_count_max_default,
    .uri_bytes_max = uri_bytes_max_default,
    .walk_bytes_max = walk_bytes_max_default,
    .walk_file_count_max = walk_file_count_max_default,
    .workspace_bytes_max = workspace_bytes_max_default,
    .workspace_file_count_max = workspace_file_count_max_default,
};

pub const lint: Limits = lint: {
    var limits = default;

    limits.diagnostic_bytes_max = diagnostic_bytes_max_lint;
    limits.diagnostic_count_max = diagnostic_count_max_lint;
    limits.report_bytes_max = report_bytes_max_lint;

    break :lint limits;
};

comptime {
    assert(default.floors_hold());
    assert(default.relation_violated() == null);
    assert(lint.floors_hold());
    assert(lint.relation_violated() == null);
}

pub fn validate(limits: *const Limits) void {
    assert(limits.floors_hold());
    assert(limits.relation_violated() == null);
}

pub fn analysis(limits: *const Limits) Analysis.Capacity {
    assert(limits.call_edge_count_max >= limits.function_count_max);
    assert(limits.fix_edit_count_max > 0);

    return .{
        .calls = .{
            .edge_count_max = limits.call_edge_count_max,
            .function_count_max = limits.function_count_max,
        },
        .fixes = .{
            .edit_count_max = limits.fix_edit_count_max,
            .fix_count_max = limits.diagnostic_count_max,
            .text_bytes_max = limits.diagnostic_bytes_max,
        },
        .front = limits.front,
        .suppression_count_max = limits.suppression_count_max,
        .uri_bytes_max = limits.uri_bytes_max,
    };
}

pub fn baseline(limits: *const Limits) scylla.Baseline.Capacity {
    assert(limits.baseline_entry_count_max > 0);
    assert(limits.file_bytes_max > 0);

    return .{
        .entry_count_max = limits.baseline_entry_count_max,
        .file_bytes_max = limits.file_bytes_max,
    };
}

pub fn cache(limits: *const Limits) scylla.Cache.Capacity {
    assert(limits.cache_bytes_max > 0);
    assert(limits.cache_entry_count_max > 0);

    return .{
        .entry_count_max = limits.cache_entry_count_max,
        .file_bytes_max = limits.cache_bytes_max,
        .path_bytes_max = limits.path_bytes_max,
    };
}

pub fn configuration(limits: *const Limits) Configuration.Capacity {
    assert(limits.glob_count_max > 0);
    assert(limits.config_extend_depth_max > 0);

    return .{ .draft = limits.draft(), .resolver = limits.config() };
}

pub fn config(limits: *const Limits) scylla.config.Resolver.Capacity {
    assert(limits.config_bytes_max >= 4_096);
    assert(limits.config_extend_depth_max > 0);

    return .{
        .config_bytes_max = limits.config_bytes_max,
        .extend_depth_max = limits.config_extend_depth_max,
        .path_bytes_max = limits.path_bytes_max,
    };
}

pub fn draft(limits: *const Limits) Draft.Capacity {
    assert(limits.glob_bytes_max >= 256);
    assert(limits.glob_count_max > 0);

    return .{
        .glob_bytes_max = limits.glob_bytes_max,
        .glob_count_max = limits.glob_count_max,
    };
}

pub fn document(limits: *const Limits) Document.Capacity {
    assert(limits.file_line_count_max <= limits.file_bytes_max);
    assert(limits.diagnostic_count_max > 0);

    return .{
        .diagnostic_bytes_max = limits.diagnostic_bytes_max,
        .diagnostic_count_max = limits.diagnostic_count_max,
        .line_count_max = limits.file_line_count_max,
        .text_bytes_max = limits.file_bytes_max,
        .uri_bytes_max = limits.uri_bytes_max,
    };
}

pub fn documents(limits: *const Limits) Documents.Capacity {
    assert(limits.document_count_max > 0);
    assert(limits.file_line_count_max <= limits.file_bytes_max);

    return .{
        .state = .{
            .diagnostic_bytes_max = limits.diagnostic_bytes_max,
            .diagnostic_count_max = limits.diagnostic_count_max,
        },
        .texts = .{
            .document_count_max = limits.document_count_max,
            .line_count_max = limits.file_line_count_max,
            .pool_bytes_max = limits.document_count_max *| limits.file_bytes_max,
            .text_bytes_max = limits.file_bytes_max,
            .text_bytes_min = limits.file_bytes_max,
            .uri_bytes_max = limits.uri_bytes_max,
        },
    };
}

pub fn formatters(limits: *const Limits) scylla.Formatters.Capacity {
    assert(limits.file_bytes_max > 0);
    assert(limits.format_element_count_max > 0);

    var front = limits.front;

    front.semantic = null;

    return .{
        .arena_bytes_max = limits.file_bytes_max,
        .element_count_max = limits.format_element_count_max,
        .front = front,
        .line_count_max = limits.file_line_count_max,
        .pragma_count_max = limits.suppression_count_max,
    };
}

pub fn ignores(limits: *const Limits) Workspace.Ignores.Capacity {
    assert(limits.glob_bytes_max >= 256);
    assert(limits.glob_count_max > 0);

    return .{
        .glob_bytes_max = limits.glob_bytes_max,
        .glob_count_max = limits.glob_count_max,
    };
}

pub fn parallel(limits: *const Limits) Parallel.Capacity {
    assert(limits.workspace_file_count_max > 0);
    assert(limits.diagnostic_count_max > 0);

    return .{ .analysis = limits.analysis(), .document = limits.document() };
}

pub fn reporter(limits: *const Limits) Reporter.Capacity {
    assert(limits.output_bytes_max > 0);
    assert(limits.report_bytes_max >= limits.output_bytes_max);

    return .{
        .line_count_max = limits.file_line_count_max,
        .output_bytes_max = limits.output_bytes_max,
        .report_bytes_max = limits.report_bytes_max,
    };
}

pub fn watch(limits: *const Limits) Watch.Capacity {
    assert(limits.config_extend_depth_max > 0);
    assert(limits.workspace_file_count_max > 0);

    return .{
        .config_count_max = limits.config_extend_depth_max,
        .file_count_max = limits.workspace_file_count_max,
    };
}

pub fn workspace(limits: *const Limits) Workspace.Capacity {
    assert(limits.walk_file_count_max >= limits.workspace_file_count_max);
    assert(limits.walk_bytes_max >= limits.workspace_bytes_max);

    return .{
        .entry_bytes_max = limits.workspace_bytes_max,
        .entry_count_max = limits.workspace_file_count_max,
        .path_bytes_max = limits.path_bytes_max,
        .walk_bytes_max = limits.walk_bytes_max,
        .walk_count_max = limits.walk_file_count_max,
    };
}

pub fn log_report(limits: *const Limits) void {
    const rows = limits.report_rows();
    const front_count = @typeInfo(FrontCapacity).@"struct".field_names.len - 1;
    const semantic_count = @typeInfo(FrontCapacity.Semantic).@"struct".field_names.len;
    const limit_count = @typeInfo(Limits).@"struct".field_names.len - 1;

    assert(rows.len == limit_count + front_count + semantic_count);

    for (rows) |row| {
        log.line("limit {s} = {d}", .{ row.name, row.value });
    }
}

const Row = struct {
    name: []const u8,
    value: u32,
};

fn report_rows(limits: *const Limits) [38]Row {
    const front = &limits.front;
    const semantic = &front.semantic.?;

    return .{
        .{ .name = "artifact_bytes_max", .value = limits.artifact_bytes_max },
        .{ .name = "baseline_entry_count_max", .value = limits.baseline_entry_count_max },
        .{ .name = "binding_count_max", .value = semantic.binding_count_max },
        .{ .name = "cache_bytes_max", .value = limits.cache_bytes_max },
        .{ .name = "cache_entry_count_max", .value = limits.cache_entry_count_max },
        .{ .name = "call_edge_count_max", .value = limits.call_edge_count_max },
        .{ .name = "config_bytes_max", .value = limits.config_bytes_max },
        .{ .name = "config_extend_depth_max", .value = limits.config_extend_depth_max },
        .{ .name = "depth_max", .value = limits.depth_max },
        .{ .name = "diagnostic_bytes_max", .value = limits.diagnostic_bytes_max },
        .{ .name = "diagnostic_count_max", .value = limits.diagnostic_count_max },
        .{ .name = "document_count_max", .value = limits.document_count_max },
        .{ .name = "error_count_max", .value = front.diagnostic_count_max },
        .{ .name = "event_count_max", .value = front.event_count_max },
        .{ .name = "fact_count_max", .value = semantic.fact_count_max },
        .{ .name = "file_bytes_max", .value = limits.file_bytes_max },
        .{ .name = "file_line_count_max", .value = limits.file_line_count_max },
        .{ .name = "fix_edit_count_max", .value = limits.fix_edit_count_max },
        .{ .name = "fix_pass_count_max", .value = limits.fix_pass_count_max },
        .{ .name = "format_element_count_max", .value = limits.format_element_count_max },
        .{ .name = "function_count_max", .value = limits.function_count_max },
        .{ .name = "glob_bytes_max", .value = limits.glob_bytes_max },
        .{ .name = "glob_count_max", .value = limits.glob_count_max },
        .{ .name = "message_bytes_max", .value = limits.message_bytes_max },
        .{ .name = "node_count_max", .value = front.node_count_max },
        .{ .name = "output_bytes_max", .value = limits.output_bytes_max },
        .{ .name = "path_bytes_max", .value = limits.path_bytes_max },
        .{ .name = "reference_count_max", .value = semantic.reference_count_max },
        .{ .name = "report_bytes_max", .value = limits.report_bytes_max },
        .{ .name = "scope_count_max", .value = semantic.scope_count_max },
        .{ .name = "suppression_count_max", .value = limits.suppression_count_max },
        .{ .name = "tag_count_max", .value = front.tag_count_max },
        .{ .name = "token_count_max", .value = front.token_count_max },
        .{ .name = "uri_bytes_max", .value = limits.uri_bytes_max },
        .{ .name = "walk_bytes_max", .value = limits.walk_bytes_max },
        .{ .name = "walk_file_count_max", .value = limits.walk_file_count_max },
        .{ .name = "workspace_bytes_max", .value = limits.workspace_bytes_max },
        .{ .name = "workspace_file_count_max", .value = limits.workspace_file_count_max },
    };
}

fn floors_hold(limits: *const Limits) bool {
    const front = &limits.front;
    const semantic = front.semantic orelse return false;

    const floors = [_]bool{
        semantic.binding_count_max > 0,
        limits.cache_bytes_max >= 4_096,
        limits.cache_entry_count_max > 0,
        limits.call_edge_count_max > 0,
        limits.depth_max >= 8,
        limits.depth_max <= depth_max_default,
        limits.diagnostic_bytes_max >= 256,
        limits.diagnostic_count_max > 0,
        limits.document_count_max > 0,
        front.diagnostic_count_max > 0,
        front.event_count_max > 0,
        semantic.fact_count_max > 0,
        limits.baseline_entry_count_max > 0,
        limits.config_bytes_max >= 4_096,
        limits.config_extend_depth_max > 0,
        limits.artifact_bytes_max >= 1 << 16,
        limits.file_bytes_max >= 4_096,
        limits.file_line_count_max > 0,
        limits.format_element_count_max > 0,
        limits.fix_edit_count_max > 0,
        limits.fix_pass_count_max > 0,
        limits.function_count_max > 0,
        limits.glob_bytes_max >= 256,
        limits.glob_count_max > 0,
        front.node_count_max > 0,
        limits.output_bytes_max >= 4_096,
        limits.path_bytes_max >= 256,
        limits.path_bytes_max < 384,
        semantic.reference_count_max > 0,
        limits.report_bytes_max >= limits.output_bytes_max,
        semantic.scope_count_max > 0,
        limits.suppression_count_max > 0,
        front.tag_count_max > 0,
        front.token_count_max > 0,
        limits.uri_bytes_max >= 256,
        limits.workspace_file_count_max > 0,
    };

    for (floors) |floor| {
        if (!floor) return false;
    }

    return true;
}

fn relation_violated(limits: *const Limits) ?Relation {
    const front = &limits.front;

    if (limits.file_line_count_max > limits.file_bytes_max) return .lines_within_file;
    if (limits.message_bytes_max <= limits.file_bytes_max) return .message_over_file;
    if (limits.call_edge_count_max < limits.function_count_max) return .calls_cover_functions;
    if (front.node_count_max < limits.depth_max) return .nodes_cover_depth;
    if (front.token_count_max < front.node_count_max) return .tokens_cover_nodes;
    if (front.event_count_max < front.token_count_max) return .events_cover_tokens;
    if (limits.walk_bytes_max < limits.workspace_bytes_max) return .walk_covers_workspace;
    if (limits.walk_file_count_max < limits.workspace_file_count_max) return .walk_covers_workspace;
    if (limits.workspace_bytes_max < limits.path_bytes_max) return .workspace_covers_path;
    return null;
}

test "defaults are consistent" {
    default.validate();
    lint.validate();

    try std.testing.expect(default.floors_hold());
    try std.testing.expectEqual(null, default.relation_violated());
}

test "message smaller than file is rejected" {
    var limits = default;

    limits.message_bytes_max = default.file_bytes_max;

    try std.testing.expect(limits.floors_hold());
    try std.testing.expectEqual(Relation.message_over_file, limits.relation_violated().?);
}

test "fewer tokens than nodes is rejected" {
    var limits = default;

    limits.front.token_count_max = default.front.node_count_max - 1;

    try std.testing.expect(limits.floors_hold());
    try std.testing.expectEqual(Relation.tokens_cover_nodes, limits.relation_violated().?);
}

test "a walk smaller than the workspace it fills is rejected" {
    var limits = default;

    limits.walk_file_count_max = default.workspace_file_count_max - 1;

    try std.testing.expect(limits.floors_hold());
    try std.testing.expectEqual(Relation.walk_covers_workspace, limits.relation_violated().?);

    limits = default;
    limits.walk_bytes_max = default.workspace_bytes_max - 1;

    try std.testing.expectEqual(Relation.walk_covers_workspace, limits.relation_violated().?);
}

test "the limits report names every bound once" {
    const rows = default.report_rows();

    for (rows, 0..) |row, index| {
        for (rows[index + 1 ..]) |other| {
            try std.testing.expect(!std.mem.eql(u8, row.name, other.name));
        }

        if (index > 0) try std.testing.expect(std.mem.lessThan(u8, rows[index - 1].name, row.name));
    }

    try std.testing.expectEqual(@as(u32, 64), rows[11].value);
    try std.testing.expectEqualStrings("document_count_max", rows[11].name);
}
