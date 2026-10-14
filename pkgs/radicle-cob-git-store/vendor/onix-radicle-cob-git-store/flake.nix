{
  description = "Product-neutral local Radicle COB Git storage";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, rust-overlay }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      eachSystem = f: nixpkgs.lib.genAttrs systems (system: f system);
      packagesFor = system: import nixpkgs {
        inherit system;
        overlays = [ (import rust-overlay) ];
      };
    in {
      devShells = eachSystem (system:
        let
          pkgs = packagesFor system;
        in {
          default = pkgs.mkShell {
            packages = [ pkgs.rust-bin.stable.latest.default pkgs.pkg-config pkgs.openssl ];
          };
        });

      checks = eachSystem (system:
        let
          pkgs = packagesFor system;
          toolchain = pkgs.rust-bin.stable.latest.default;
          rustPlatform = pkgs.makeRustPlatform { cargo = toolchain; rustc = toolchain; };
          nativeBuildInputs = [ pkgs.pkg-config ];
          buildInputs = [ pkgs.openssl ];
        in {
          cargo-test = rustPlatform.buildRustPackage {
            pname = "onix-radicle-cob-git-store-tests";
            version = "0.2.0";
            src = self;
            cargoLock.lockFile = ./Cargo.lock;
            inherit nativeBuildInputs buildInputs;
            cargoTestFlags = [ "--all-targets" ];
            installPhase = ''touch "$out"'';
          };
          cargo-clippy = rustPlatform.buildRustPackage {
            pname = "onix-radicle-cob-git-store-clippy";
            version = "0.2.0";
            src = self;
            cargoLock.lockFile = ./Cargo.lock;
            inherit nativeBuildInputs buildInputs;
            buildPhase = ''cargo clippy --all-targets --offline -- -D warnings'';
            doCheck = false;
            installPhase = ''touch "$out"'';
          };
          cargo-format = pkgs.runCommand "onix-radicle-cob-git-store-format" {
            nativeBuildInputs = [ toolchain ];
            src = self;
          } ''
            cd "$src"
            cargo fmt --all -- --check
            touch "$out"
          '';
        });
    };
}
