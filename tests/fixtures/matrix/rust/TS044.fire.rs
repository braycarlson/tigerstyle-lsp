struct Store;

impl Store {
    fn read(&self) -> u32 {
        4
    }

    type Item = u32;
}
