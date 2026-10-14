## Why

The independent `onix-radicle-cob-git-store` Rust library is a reusable local signed-COB Git storage mechanism, while each consumer retains its COB policy and operations. Cairn and Valence require the Radicle COB 0.20 dependency cohort; Kiln requires 0.21. Its source repository currently has no published remote. Shared packages must therefore have portable source inputs and preserve the independent producer's identities rather than reading an ambient sibling checkout at build time.

## What Changes

- Export `pkgs.radicle-cob-git-store` (crate 0.2.0, COB 0.21) and `pkgs.radicle-cob-git-store-020` (crate 0.1.1, COB 0.20) on x86_64-linux and aarch64-linux as tested Cargo crate source artifacts, not executables or portable rlibs. Reuse the same overridable package function without duplicating store logic.
- Import each exact producer Git archive at its own recorded commit and BLAKE3 using one package-local verifier, preserving Cargo.lock, tests, licenses, and source files without edits. Record revision and digest next to each package; require fresh explicit inputs for every future import.
- Keep both immutable vendor snapshots outside treefmt and document their cohort and build claims.

Immediate outcome: shared source packages compatible with both COB dependency cohorts, available for future Nix adoption. Durable capability: reproducible, reviewable onixpkgs source artifacts and a source-refresh path without an invented remote. Current producer consumers independently vendor source: Cairn's migration branch pins 0.1.0 at `af38dae7e0454b1206512794420a3076ea5a8d1f`, Valence pins 0.1.1 at `f78168ea4560ce3a3167b5850bc0c1568e1a1abe`, and Kiln will pin 0.2.0 in its own repository. None currently imports these onixpkgs attributes as a direct build input. Adoption path: consumers select a pinned onixpkgs revision and explicitly integrate compatible crate source into their Cargo builds. Maintenance owner: onixpkgs maintainers for the derivations/import, independent producer maintainers for the library.

## Impact

- **Files**: `pkgs/radicle-cob-git-store/`, `pkgs/radicle-cob-git-store-020/`, `flake.nix`, `treefmt.nix`, `README.md`, and this change.
- **Behavior**: builds the library and runs `cargo test --all-targets` before installing its Cargo source; does not supply a binary, service module, actor authorization, or transport.
- **Verification**: both importer digest acceptance/rejection, both package builds and installed-source inspection, treefmt formatting check, and scoped Cairn validation where available. A whole `nix flake check -L` additionally builds all unrelated exports and is required only for an all-package claim.
