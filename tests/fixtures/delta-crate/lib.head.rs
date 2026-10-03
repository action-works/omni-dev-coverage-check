//! Fixture crate for the action's merge-base recompute test.
//!
//! The job commits `lib.base.rs` as `src/lib.rs`, then `lib.head.rs` over it, and
//! runs the action with the first commit as `base-ref`. `kept` and `flips` sit at
//! the same lines in both versions, so every difference the diff shows is below
//! them. Unlike the fat-mode crate, its tests need nothing but `cargo test`,
//! because the recompute replays only `test-args`.

/// Covered at the base and at the head.
pub fn kept() -> u32 {
    1 + 1
}

/// Not covered at the base. The head adds a test for it, so its coverage flips
/// although none of its own lines change: an indirect change.
pub fn flips() -> u32 {
    2 + 2
}

/// New at the head, and covered.
pub fn added_covered() -> u32 {
    3 + 3
}

/// New at the head, and covered by nothing.
pub fn added_uncovered() -> u32 {
    4 + 4
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn kept_works() {
        assert_eq!(kept(), 2);
    }

    #[test]
    fn flips_works() {
        assert_eq!(flips(), 4);
    }

    #[test]
    fn added_covered_works() {
        assert_eq!(added_covered(), 6);
    }
}
