//! Whether the suite is meant to run against real executables.
//!
//! The tests drive the built `pirc-gateway` and `pirc-node`, which only exist
//! when `PIRC_CONFORMANCE_BIN_DIR` names them. Without it a test used to print a
//! notice and return, which libtest counts as passed. Tests that need the
//! executables now carry
//! `#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]`
//! (checked by `tests/gating.rs`), so without the variable they are reported as
//! ignored, never as passed.
//!
//! `conformance_enabled` is set when the variable is present at build time. It is
//! also set under `PIRC_CONFORMANCE_REQUIRED`, so that a required run without the
//! executables still starts the tests and fails them (`cluster::bin_dir`) instead
//! of ignoring them.

const BIN_DIR: &str = "PIRC_CONFORMANCE_BIN_DIR";
const REQUIRED: &str = "PIRC_CONFORMANCE_REQUIRED";

fn main() {
    println!("cargo::rustc-check-cfg=cfg(conformance_enabled)");
    println!("cargo::rerun-if-changed=build.rs");
    println!("cargo::rerun-if-env-changed={BIN_DIR}");
    println!("cargo::rerun-if-env-changed={REQUIRED}");
    if std::env::var_os(BIN_DIR).is_some() || std::env::var_os(REQUIRED).is_some() {
        println!("cargo::rustc-cfg=conformance_enabled");
    }
}
