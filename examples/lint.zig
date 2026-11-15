const std = @import("std");
const tigerstyle = @import("tigerstyle");
const assert = std.debug.assert;

const source =
    \\fn total(sectors: []const u32) u32 {
    \\    var sum: u32 = 0;
    \\    var index: u32 = 0;
    \\    while (true) {
    \\        if (index == sectors.len) break;
    \\        sum += sectors[index];
    \\        index += 1;
    \\    }
    \\    return sum;
    \\}
    \\
;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const linter = try gpa.create(tigerstyle.Linter);
    defer gpa.destroy(linter);

    try linter.init(gpa, init.io, &.default);
    defer linter.deinit(gpa);

    const diagnostics = try linter.lint(&.{ .path = "sectors.zig", .text = source });

    for (diagnostics.slice()) |*diagnostic| {
        const message = diagnostics.message_of(diagnostic);

        std.debug.print("{d}: {s} {s}\n", .{ diagnostic.span.offset, diagnostic.code, message });
    }

    assert(!diagnostics.empty());
    assert(linter.fixes().count() <= diagnostics.count());
}
