//! Fixture crate for the action's sharded end-to-end test.
//!
//! Four functions, each reached by exactly one test, plus one reached by none.
//! `cargo llvm-cov nextest --partition count:N/2` splits the tests across two
//! shard jobs, so each shard covers a different half of the crate and only the
//! union of the two reports covers all of it. Nothing here depends on doctests,
//! which nextest does not run.
//!
//! Every function has the same shape (four instrumented lines) so the coverage
//! fractions are easy to reason about: 4 functions x (4 + 3 test lines) + 4 for
//! `never` = 32 lines. All four tests: 28/32 = 87.5%. Without `t4_delta`:
//! 21/32 = 65.6%. A shard alone covers at most 14/32 = 43.75%.

pub fn alpha() -> u32 {
    let a = 1;
    a + 1
}

pub fn bravo() -> u32 {
    let b = 2;
    b + 2
}

pub fn charlie() -> u32 {
    let c = 3;
    c + 3
}

pub fn delta() -> u32 {
    let d = 4;
    d + 4
}

/// Reached by nothing, so the crate is never fully covered.
pub fn never() -> u32 {
    let n = 5;
    n + 5
}

#[cfg(test)]
mod tests {
    use super::*;

    // The numeric prefixes keep the tests in a fixed order, so `count:` partitioning
    // hands the odd-numbered tests to one shard and the even-numbered to the other.

    #[test]
    fn t1_alpha() {
        assert_eq!(alpha(), 2);
    }

    #[test]
    fn t2_bravo() {
        assert_eq!(bravo(), 4);
    }

    #[test]
    fn t3_charlie() {
        assert_eq!(charlie(), 6);
    }

    /// Skipped on pull requests, so the head covers less than the baseline.
    #[test]
    fn t4_delta() {
        assert_eq!(delta(), 8);
    }
}
