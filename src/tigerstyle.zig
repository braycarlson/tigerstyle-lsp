const std = @import("std");
const scylla = @import("scylla");

pub const Analysis = @import("analysis.zig");
pub const Document = @import("document.zig");
pub const Linter = @import("linter.zig");
pub const Rules = @import("rules.zig");
pub const Settings = @import("settings.zig");

pub const languages = @import("languages.zig");

pub const limits = struct {
    pub const parse_depth_max: u32 = scylla.limits.parse_depth_max;
};

test "the root names each declaration it exports" {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(limits);

    try std.testing.expect(limits.parse_depth_max > 0);
}
