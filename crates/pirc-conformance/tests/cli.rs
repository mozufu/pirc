//! Public Rust CLI contract, independent of the retired TS executables.
use std::path::{Path, PathBuf};
use std::process::{Output, Stdio};
use std::time::Duration;
use tokio::process::Command;

fn bin_dir() -> Option<PathBuf> {
    let Some(dir) = std::env::var_os("PIRC_CONFORMANCE_BIN_DIR") else {
        assert!(std::env::var_os("PIRC_CONFORMANCE_REQUIRED").is_none());
        return None;
    };
    let dir = PathBuf::from(dir);
    Some(if dir.is_absolute() {
        dir
    } else {
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../..")
            .join(dir)
    })
}

async fn run(bin: &Path, args: &[&str]) -> Output {
    tokio::time::timeout(
        Duration::from_secs(10),
        Command::new(bin)
            .args(args)
            .env_clear()
            .stdin(Stdio::null())
            .kill_on_drop(true)
            .output(),
    )
    .await
    .expect("CLI timed out")
    .expect("run CLI")
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test]
async fn public_cli() {
    let Some(dir) = bin_dir() else { return };
    for role in ["gateway", "node"] {
        let bin = dir.join(format!("pirc-{role}"));
        let prefixes: &[&[&str]] = if role == "node" {
            &[&[], &["chat"]]
        } else {
            &[&[]]
        };
        for prefix in prefixes {
            for flag in ["version", "--version"] {
                let args = [*prefix, &[flag]].concat();
                let out = run(&bin, &args).await;
                assert!(out.status.success());
                assert_eq!(
                    out.stdout,
                    format!("{}\n", env!("CARGO_PKG_VERSION")).as_bytes()
                );
                assert!(out.stderr.is_empty());
            }
            for flag in ["help", "--help", "-h"] {
                let args = [*prefix, &[flag]].concat();
                let out = run(&bin, &args).await;
                assert!(out.status.success());
                assert!(out.stderr.is_empty());
                let help = String::from_utf8(out.stdout).unwrap();
                assert!(help.starts_with(&format!("Usage: pirc-{role} ")));
                for internal in ["agent", "ptc-guest", "sandbox-bridge", "oauth-worker"] {
                    assert!(!help.contains(internal));
                }
            }
            for tail in [
                &["--help", "extra"][..],
                &["--version", "extra"],
                &["unknown"],
            ] {
                let out = run(&bin, &[*prefix, tail].concat()).await;
                assert_eq!(out.status.code(), Some(2));
                assert!(out.stdout.is_empty());
                assert!(String::from_utf8(out.stderr).unwrap().contains("Usage:"));
            }
        }
        for retired in ["node", "gateway", "srt", "oauth-worker", "--chat"] {
            let out = run(&bin, &[retired]).await;
            assert_eq!(out.status.code(), Some(2));
        }
        // With no configuration, dispatch must reach the runtime, not help.
        let out = run(&bin, &[]).await;
        assert_eq!(out.status.code(), Some(1));
        assert!(out.stdout.is_empty());
        assert!(!String::from_utf8(out.stderr).unwrap().contains("Usage:"));
    }
    let node = dir.join("pirc-node");
    let out = run(&node, &["chat"]).await;
    assert_eq!(out.status.code(), Some(1));
    let out = run(&node, &["agent"]).await;
    assert!(
        String::from_utf8(out.stderr)
            .unwrap()
            .contains("--session-dir")
    );
}
