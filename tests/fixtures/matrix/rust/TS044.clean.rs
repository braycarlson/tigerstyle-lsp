struct Store;

impl Store {
    const LIMIT: u32 = 4;

    fn read(&self) -> u32 {
        Self::LIMIT
    }
}
