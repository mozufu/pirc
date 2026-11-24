{
  description = "pirc: native Rust gateway and coding/chat node with a NixOS service";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };
  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      ...
    }:
    {
      overlays.default = final: _prev: {
        pirc-gateway = final.callPackage ./nix/package.nix {
          inherit (nixpkgs.legacyPackages.${final.stdenv.hostPlatform.system}) rustPlatform;
          callPackage =
            path: args:
            final.callPackage path (
              args
              // {
                inherit (nixpkgs.legacyPackages.${final.stdenv.hostPlatform.system}) bun;
              }
            );
          role = "gateway";
        };
        pirc-node = final.callPackage ./nix/package.nix {
          inherit (nixpkgs.legacyPackages.${final.stdenv.hostPlatform.system}) rustPlatform;
          role = "node";
        };
      };
      nixosModules = {
        pirc = import ./nix/module.nix;
        default = self.nixosModules.pirc;
      };
    }
    // flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
        pirc-gateway = pkgs.callPackage ./nix/package.nix { role = "gateway"; };
        pirc-node = pkgs.callPackage ./nix/package.nix { role = "node"; };
      in
      {
        packages = {
          inherit pirc-gateway pirc-node;
          default = pirc-gateway;
        };
        checks = {
          gateway = pirc-gateway;
          node = pirc-node;
        };
        devShells.default = pkgs.mkShell {
          packages =
            (with pkgs; [
              bun
              nodejs_22
              cargo
              rustc
              clippy
              rustfmt
              jdk17
              # Flutter includes its matching Dart SDK; avoid mixing Dart versions.
              (flutter344.override {
                supportedTargetFlutterPlatforms = [
                  "universal"
                  "android"
                  "web"
                ];
              })
            ])
            ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [
              pkgs.bubblewrap
              pkgs.chromium
            ];
          JAVA_HOME = "${pkgs.jdk17}";
          shellHook = ''echo "pirc development shell (Rust + Bun + Flutter/Dart + JDK 17)"'';
        };
        formatter = pkgs.nixfmt-rfc-style;
      }
    );
}
