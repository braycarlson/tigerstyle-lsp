fn walk(depth: u32) {
    let mut left = depth;

    while left > 0 {
        left -= 1;
    }
}

struct Reader {
    handle: u32,
}

impl Reader {
    fn close(&mut self) -> u32 {
        let taken = self.handle;

        drop(taken);

        taken
    }
}

impl Drop for Reader {
    fn drop(&mut self) {
        let closed = self.close();

        assert!(closed == 0);
    }
}

fn matches(interactive: bool) -> bool {
    matches!(interactive, true)
}
