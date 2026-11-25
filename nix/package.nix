{
  lib,
  stdenv,
  rustPlatform,
  makeWrapper,
  bubblewrap,
  callPackage,
  role ? "gateway",
}:
assert lib.elem role [
  "gateway"
  "node"
];
let
  version = (builtins.fromJSON (builtins.readFile ../package.json)).version;
  web = callPackage ./web.nix { };
in
rustPlatform.buildRustPackage {
  pname = "pirc-${role}";
  inherit version;
  # Explicit allowlist: neither local state/credentials nor retired TS sources
  # can enter the server build or runtime closure.
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../Cargo.toml
      ../Cargo.lock
      ../LICENSE
      ../crates
    ];
  };
  cargoHash = "sha256-HsdvpaE6UGk/SyDQ9NopMmjqC8EU5AhryuJBGnbpRXg=";
  cargoBuildFlags = [
    "-p"
    "pirc-${role}"
  ];
  cargoTestFlags = [
    "-p"
    "pirc-${role}"
    "--lib"
  ];
  # The gateway is binary-only; network/process integration tests run in CI,
  # not in the Nix build sandbox. Install checks cover both shipped CLIs.
  doCheck = false;
  nativeBuildInputs = lib.optional (role == "node") makeWrapper;
  postInstall = ''
    # Include nested notices (notably rquickjs-sys/quickjs/LICENSE), not just
    # crate-root licenses. cargoDeps is the locked, unpacked vendor tree.
    licenses=$out/share/licenses/pirc-${role}
    mkdir -p "$licenses/rust"
    install -m644 LICENSE "$licenses/LICENSE"
    (
      cd "$cargoDeps"
      find -L . -type f \( -iname 'license*' -o -iname 'licence*' -o -iname 'notice*' \
        -o -iname 'copying*' -o -iname 'copyright*' \) -print0 > "$TMPDIR/pirc-notices"
      # cp --parents inherits read-only store directory modes; install -D
      # creates writable parents until the output is finalized instead.
      while IFS= read -r -d $'\0' file; do
        install -Dm644 "$file" "$licenses/rust/$file"
      done < "$TMPDIR/pirc-notices"
    )
    cp crates/pirc-node/NOTICE "$licenses/pirc-node-NOTICE"
    cp crates/pirc-node/src/browser/assets/PLAYWRIGHT-{LICENSE,NOTICE} "$licenses/"
  ''
  + lib.optionalString (role == "gateway") ''
    mkdir -p $out/share/pirc
    ln -s ${web}/share/pirc/web $out/share/pirc/web
  ''
  + lib.optionalString (role == "node" && stdenv.hostPlatform.isLinux) ''
    wrapProgram $out/bin/pirc-node --prefix PATH : ${lib.makeBinPath [ bubblewrap ]}
  '';
  doInstallCheck = true;
  installCheckPhase = ''
    test "$($out/bin/pirc-${role} --version)" = "${version}"
    $out/bin/pirc-${role} --help
  ''
  + lib.optionalString (role == "node") ''
    # Exercise the installed wrapper and real JSONL session lifecycle, offline.
    export HOME="$TMPDIR/session-home"
    export PIRC_CONFIG_DIR="$TMPDIR/session-config"
    export PIRC_AGENT_FEATURES=none
    export PIRC_MODE='{"id":"smoke","label":"Smoke","ui":{"noun":"session"},"workdir":"per-session","prompt":["base"],"tools":[],"assistant":"user","schedule_scope":"own"}'
    mkdir -p "$HOME" "$PIRC_CONFIG_DIR" "$TMPDIR/session-work"
    pirc_session_dir="$TMPDIR/session-store"
    for pirc_session_pass in 1 2; do
      (
        cd "$TMPDIR/session-work"
        printf '%s\n' '{"type":"configure","models":{}}' '{"id":"session-check","type":"get_state"}' \
          | $out/bin/pirc-node agent --session-dir "$pirc_session_dir" > "$TMPDIR/session-response"
      )
      grep -q '"id":"session-check"' "$TMPDIR/session-response"
      grep -q '"success":true' "$TMPDIR/session-response"
      test -s "$pirc_session_dir/session.jsonl"
      test -d "$pirc_session_dir/session.jsonl.writer-lock"
      head -n 1 "$pirc_session_dir/session.jsonl" > "$TMPDIR/session-header-$pirc_session_pass"
    done
    cmp "$TMPDIR/session-header-1" "$TMPDIR/session-header-2"
  '';
  passthru = {
    inherit role;
  }
  // lib.optionalAttrs (role == "gateway") { inherit web; };
  meta = {
    description =
      if role == "gateway" then
        "Private forward-authenticated gateway and web UI"
      else
        "Native coding and chat node with a sandboxed agent";
    license = lib.licenses.agpl3Only;
    mainProgram = "pirc-${role}";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
