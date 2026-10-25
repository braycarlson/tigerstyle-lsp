const Kind = enum(u8) {
    fn read(self: Kind) u8 {
        return @intFromEnum(self);
    }

    first,
    second,
};
