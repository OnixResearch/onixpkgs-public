## ADDED Requirements

### Requirement: Verified portable local source import

r[onixpkgs.radicle_cob_git_store.source] `pkgs/radicle-cob-git-store` and `pkgs/radicle-cob-git-store-020` MUST each use a tracked snapshot of an exact Git commit from the independent `onix-radicle-cob-git-store` repository. Their shared importer MUST require an allowed target package directory, explicit source checkout, full revision, and expected BLAKE3 of the full Git archive. Before replacing an existing snapshot it MUST parse its prior receipt, require and verify that commit's exact Git archive from the supplied checkout, and compare every vendor path, file byte, mode, and symlink with the prior archive, including extra files and empty directories. It MUST reject a mismatched new digest, invalid or unavailable prior identity, or vendor drift without replacing the snapshot or receipt. The same pin against a pristine snapshot MUST leave both unchanged. It MUST record an accepted new revision and digest beside the selected package and MUST NOT rely on a workspace sibling path or invent a fetchable remote in the derivations.

#### Scenario: Wrong expected archive digest

- GIVEN an existing imported snapshot and an incorrect expected BLAKE3
- WHEN the importer archives a supplied Git commit
- THEN it fails without replacing the snapshot or provenance

#### Scenario: Edited vendor tree or invalid receipt

- GIVEN an existing imported snapshot with a locally edited source file, an extra directory, or a missing prior commit
- WHEN the importer receives an otherwise valid next source pin
- THEN it fails without removing the local content or changing the receipt

#### Scenario: Identical import

- GIVEN a pristine snapshot and its recorded source pin
- WHEN the importer receives that same commit and archive digest
- THEN it succeeds without replacing the vendor tree or receipt

#### Scenario: Recorded archive

- GIVEN an explicit checkout with the recorded commit and archive digest for a selected cohort
- WHEN the importer runs
- THEN it installs the exact source, Cargo.lock, tests, and licenses from that Git archive into only that cohort and records its commit and digest

### Requirement: Test real crate and publish usable source

r[onixpkgs.radicle_cob_git_store.package] `pkgs.radicle-cob-git-store` (0.2.0, Radicle COB 0.21) and `pkgs.radicle-cob-git-store-020` (0.1.1, Radicle COB 0.20) MUST both be exported on x86_64-linux and aarch64-linux and not on Darwin. The older cohort MUST override the shared package function with its own source, Cargo.lock, and version. Each build MUST compile its own `onix-radicle-cob-git-store` library and run its all-target Cargo tests. Both outputs MUST supply Cargo.toml, Cargo.lock, src/lib.rs, LICENSE-MIT, and LICENSE-APACHE for a consumer's own Cargo toolchain. Neither package MUST claim to install a standalone executable or portable compiled rlib.

#### Scenario: Package build

- GIVEN the overlaid package set on a supported Linux system
- WHEN `nix build .#radicle-cob-git-store` and `nix build .#radicle-cob-git-store-020` run
- THEN each crate's signed-COB and negative-case tests execute and each output contains its matching usable crate source

#### Scenario: Unsupported Darwin export

- GIVEN the onixpkgs flake on aarch64-darwin
- WHEN its package set is evaluated
- THEN neither `packages.aarch64-darwin.radicle-cob-git-store` nor `packages.aarch64-darwin.radicle-cob-git-store-020` is exported
