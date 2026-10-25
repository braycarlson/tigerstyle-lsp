const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const Context = @import("../context.zig");
const Regions = scylla.suppress.Regions;
const Rule = scylla.rule.Rule;
const Sink = scylla.rule.Sink;

pub const rule: Rule = .{
    .citations = &.{
        .{
            .standard = "TigerStyle",
            .text = "\"Appreciate, from day one, all compiler warnings at the compiler's " ++
                "strictest setting.\"",
        },
    },
    .code = "TS050",
    .default_on = true,
    .description = "A suppression directive that suppresses nothing is removed, so the " ++
        "remaining ones still mean something.",
    .explanation = "",
    .fix_title = "",
    .fixable = .sometimes,
    .group = .preview,
    .name = "unused-suppression",
    .severity = .warning,
    .summary = "Remove a suppression directive that suppresses nothing",
    .url = "",
};

const payload_bytes_max: u32 = 512;

pub fn run(context: *const Context, sink: *Sink) void {
    assert(std.mem.eql(u8, sink.code_of(), rule.code));
    assert(sink.regions().count() <= sink.regions().capacity());

    report_unused(sink, context);
}

fn report_unused(sink: *Sink, context: *const Context) void {
    const entry_count = sink.regions().count();

    for (0..entry_count) |index| {
        const enabled = context.settings.rules;
        const found = sink.regions().unused_at(@intCast(index), enabled) orelse continue;

        report_unused_one(sink, context, &found);
    }

    assert(sink.regions().count() == entry_count);
}

fn report_unused_one(
    sink: *Sink,
    context: *const Context,
    found: *const Regions.Unused,
) void {
    const text: []const u8 = switch (found.reason) {
        .closes => "the directive closes no region",
        .dead => "the directive suppresses nothing",
        .unknown => "the directive names a code tigerstyle-lsp does not carry",
    };

    if (found.kept.is_empty()) {
        sink.fix_begin("Remove the unused suppression", .safe, null);
        const removed = found.removal(context.lines, context.source);

        sink.fix_edit(removed, "");
        sink.report_fixed(found.span, text);

        return;
    }

    var listed: [payload_bytes_max]u8 = undefined;

    const length = context.registry.codes_written(&listed, found.kept) catch {
        sink.report(found.span, text);

        return;
    };

    sink.fix_begin("Drop the codes nothing reports", .safe, null);
    sink.fix_edit(found.payload, listed[0..length]);
    sink.report_fixed(found.span, text);
}
