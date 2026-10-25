macro_rules! sum_all {
    ($($value:expr),*) => {
        0 $(+ $value)*
    };
}
