//! Fixture crate for the action's fat-mode integration test.
//!
//! Each function below is reached by a different part of the coverage run, so
//! the report shows which parts of the action contributed coverage.

/// Code nothing reaches, in a file of its own: what `llvm-cov-ignore-filename-regex` excludes.
pub mod ignored;

/// Reached by the main `cargo test` run.
pub fn main_run() -> u32 {
    1 + 1
}

/// Reached only by the `#[ignore]`d test that `extra-test-commands` runs.
pub fn extra_only() -> u32 {
    2 + 2
}

/// Reached only by the test that `setup-commands` runs, with profiling off.
pub fn setup_only() -> u32 {
    3 + 3
}

/// Reached by nothing.
pub fn never() -> u32 {
    4 + 4
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn main_run_after_setup() {
        // Proof that this test executed, so a failure below is known to come
        // from here and not from an earlier step.
        std::fs::write("main-test-ran.txt", "").unwrap();
        // `setup-commands` must have run first.
        assert!(std::path::Path::new("setup-ran.txt").exists());
        assert_eq!(main_run(), 2);
    }

    #[test]
    #[ignore = "run by extra-test-commands"]
    fn extra_only_works() {
        assert_eq!(extra_only(), 4);
    }

    #[test]
    #[ignore = "run by setup-commands"]
    fn setup_only_works() {
        assert_eq!(setup_only(), 6);
        // Proof that this test executed, so `setup_only` having no coverage is
        // not just because it never ran.
        std::fs::write("setup-test-ran.txt", "").unwrap();
    }
}
