# Upgrades

[Deployment guide](README.md)

## pirc 0.11.0: fresh start from 0.10.x or earlier

pirc 0.11.0 does not migrate state from 0.10.x or earlier.

- The Gateway and every Node refuse a database created by an earlier release, with
  a message naming the file. Stop the old services, move each state directory away
  after making a backup, and start 0.11.0 on empty state directories.
- Pair every phone again, log in to subscription backends again and recreate
  workspaces, projects, schedules and pots. Configuration files (`models.json`, a
  Node's `config.json`, role files, skills) are read as before; check them against
  the current guides.
- Old Web pages and apps are refused with `426 client_upgrade_required`; reload the
  page or install the matching app.
- Upgrade the Gateway, the chat node, every coding node and every client together:
  only matching versions talk to each other.

Later updates from an installed 0.11.0 keep data through supported forward
migrations ([update plan](../../plans/updates.md#step-3--schema-migrations-from-the-release-on)).
Upgrade notes for older releases are in [historical records](../development/historical-records.md#upgrade-notes-before-0110).

## TLS trust update: October 2026

The Rust gateway's outbound HTTPS and the node's `wss://` connection use
Rustls with `rustls-platform-verifier`. On macOS, it delegates certificate
trust evaluation to Security.framework and Apple's current trust policy. On
Linux, it discovers the host CA bundle and WebPKI validates certificate paths
against those roots. Keep the operating system's trust data current as well as
the pirc dependencies.

The October 2026 eMudhra incident led to [RUSTSEC-2026-0382](https://rustsec.org/advisories/RUSTSEC-2026-0382.html),
which covers acceptance of paths through distrusted emSign intermediates, and
[RUSTSEC-2026-0383](https://rustsec.org/advisories/RUSTSEC-2026-0383.html),
which covers the bundled roots that allowed such paths. This update locks the
patched releases `rustls-webpki` 0.103.16 and `webpki-root-certs` 1.0.10. See
the [incident report](https://emudhra.we-have-a-problem.com/) for the CA event.
Build from the updated lockfile (`nix build .#pirc-gateway .#pirc-node` from
the pirc checkout, or use your deployment's equivalent builder), then replace
and restart the gateway and every chat and coding node, including remote nodes;
a reload does not replace the running TLS verifier.

On NixOS, the pirc repository's pinned flake inputs control its build and
development environment, while the running host's Linux CA bundle comes from
the host's NixOS generation. Updating the project flake alone does not refresh
that host bundle; update and verify the host's CA package and trust policy
separately. External tools such as `gh`, `git`, `curl` and Python have their
own TLS implementations and CA bundles; update them separately. Variables such
as `SSL_CERT_FILE` only affect clients that honor them; see the [sandbox `gh`
setup](sandbox-and-browser.md#https-with-a-token). The Android app uses its
separate OkHttp and Android trust path; this Rust dependency update does not
change it.

The offline regression test is
`cargo test --locked -p pirc-providers --test tls_distrust`. It explicitly trusts
the legacy fixture roots and requires the twelve public incident chains,
including AAA cross-signs, to fail with `CertDistrusted` at a fixed time within
their validity periods. A valid local test CA must still pass. On Linux this
also exercises the platform verifier; on macOS and Windows it exercises WebPKI
rather than the native OS trust service. This test does not validate the
deployed host's CA updates or any external command-line tool's trust store.
