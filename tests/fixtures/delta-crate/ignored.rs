//! Stands for code CI cannot execute: nothing reaches it, so all of its lines are uncovered
//! at the base and at the head, and no diff line touches it. The job commits it unchanged
//! with both versions of `lib.rs`. The scenario that sets `llvm-cov-ignore-filename-regex`
//! must leave it out of the report the recompute builds at the base as well as the head's;
//! the one that does not shows both reports holding it.

/// Reached by nothing.
pub fn ci_cannot_run() -> u32 {
    let a = 5;
    let b = 6;
    a + b
}
