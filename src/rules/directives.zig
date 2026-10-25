const std = @import("std");
const assert = std.debug.assert;
const scylla = @import("scylla");
const Context = @import("context.zig");
const Regions = scylla.suppress.Regions;
const Span = scylla.Span;
const log = scylla.log;

const disable = "tigerstyle-disable:";
const enable = "tigerstyle-enable:";
const file = "tigerstyle-file-ignore:";
const line = "tigerstyle-ignore:";
pub const words = [_][]const u8{ disable, enable, file, line };

comptime {
    for (words) |word| {
        assert(std.mem.startsWith(u8, word, "tigerstyle-"));
        assert(std.mem.endsWith(u8, word, ":"));
    }
}

fn markers_of(annotation: []const u8) Regions.Markers {
    return .{
        .annotation = annotation,
        .close = "",
        .disable = disable,
        .enable = enable,
        .file = file,
        .line = line,
        .open = "",
    };
}

pub fn scan(regions: *Regions, context: *const Context, comments: *scylla.ArrayType(Span)) void {
    const markers = markers_of(context.grammar.annotation_prefix);

    comments.clear();

    Regions.comment_spans(comments, &markers, context.source, context.tokens) catch |err| {
        switch (err) {
            error.TargetExhausted => {
                log.line("a file carried more directive comments than are tracked", .{});
            },
        }
    };

    regions.scan(context.registry, context.lines, &markers, context.source, comments.const_slice());

    if (regions.dropped_count() > 0) {
        log.line("a file carried {d} directives past the {d} tracked; the rest suppress nothing", .{
            regions.dropped_count(),
            regions.capacity(),
        });
    }
}

test markers_of {
    const markers = markers_of("//");

    try std.testing.expectEqualStrings("//", markers.annotation);
    try std.testing.expectEqualStrings(line, markers.line);
    try std.testing.expectEqualStrings(file, markers.file);
    try std.testing.expectEqual(@as(usize, 0), markers.open.len);
}
