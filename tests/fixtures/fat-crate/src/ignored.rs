//! Stands for code CI cannot execute (a GPU path, say): nothing reaches it, so all of its
//! lines are uncovered. The scenarios that set `llvm-cov-ignore-filename-regex` exclude this
//! file, and the control that does not shows what it costs.

/// Reached by nothing.
pub fn ci_cannot_run() -> u32 {
    let a = 5;
    let b = 6;
    a + b
}
