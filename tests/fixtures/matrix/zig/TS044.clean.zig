const Store = struct {
    limit: u32,

    fn read(self: Store) u32 {
        return self.limit;
    }
};
