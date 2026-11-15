const std = @import("std");
const merged = error{A} || error{B};
const wide = "a\u{1F600}b";
const bits = 0b1010_1010;
const octal = 0o755;
const tiny = 0x1p-4;
pub fn total(a: u32) u32 {
    return a +% 1;
}
test "total" {
    try std.testing.expect(total(1) == 2);
}
