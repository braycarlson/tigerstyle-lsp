const std = @import("std");

var counter: u32 = 0;

pub fn helper(first: u32, second: u32, third: u32, fourth: u32, fifth: u32, sixth: u32, seventh: u32, eighth: u32) u32 {
    while (true) {
        if (first > 0 and second > 0) {
            const idx: u32 = 1;
            counter = idx;
        }
    }
}

pub fn main() void {
    helper(1, 2, 3, 4, 5);
}
