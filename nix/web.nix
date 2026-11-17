{
  lib,
  stdenvNoCC,
  bun,
  nodeModulesHash ? "sha256-PqOcQcu3dPqC62OV7Q7l2BJamg95/ffblSYuIeXNbTE=",
}:
let
  version = (builtins.fromJSON (builtins.readFile ../package.json)).version;
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../package.json
      ../LICENSE
      ../bun.lock
      ../tsconfig.base.json
      (lib.fileset.fileFilter (
        file:
        !(lib.elem file.name [
          ".env"
          ".env.local"
        ])
        && !(lib.hasPrefix ".env." file.name)
      ) ../apps/web/src)
      ../apps/web/public
      ../apps/web/csp-policy.ts
      ../apps/web/package.json
      ../apps/web/index.html
      ../apps/web/tsconfig.json
      ../apps/web/vite.config.ts
    ];
  };
  nodeModules = stdenvNoCC.mkDerivation {
    pname = "pirc-web-node-modules";
    inherit version src;
    nativeBuildInputs = [ bun ];
    dontConfigure = true;
    dontFixup = true;
    buildPhase = ''
      export HOME=$TMPDIR
      bun install --frozen-lockfile --ignore-scripts --no-progress --os='*' --cpu='*'
    '';
    installPhase = ''
      mkdir -p $out/apps/web
      cp -a node_modules $out/
      cp -a apps/web/node_modules $out/apps/web/
    '';
    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
    outputHash = nodeModulesHash;
  };
in
stdenvNoCC.mkDerivation {
  pname = "pirc-web";
  inherit version src;
  nativeBuildInputs = [ bun ];
  configurePhase = ''
    export HOME=$TMPDIR
    cp -a ${nodeModules}/. .
    chmod -R u+w .
    # Vite's executable uses /usr/bin/env node; Nix sandboxes provide neither.
    mkdir -p $TMPDIR/bin
    ln -s ${lib.getExe bun} $TMPDIR/bin/node
    export PATH=$TMPDIR/bin:$PATH
    patchShebangs node_modules apps/web/node_modules
  '';
  buildPhase = "bun run --filter @pirc/web build";
  installPhase = ''
    mkdir -p $out/share/pirc/web
    cp -r apps/web/dist/. $out/share/pirc/web/
    install -Dm644 LICENSE $out/share/licenses/pirc-web/LICENSE
  '';
  passthru = { inherit nodeModules; };
  meta.license = lib.licenses.agpl3Only;
}
