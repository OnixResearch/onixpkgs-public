## Phase 1: Implementation

- [x] [serial] Add shared overridable tested source derivation and digest-checking cohort importer. r[onixpkgs.radicle_cob_git_store.source] r[onixpkgs.radicle_cob_git_store.package]
- [x] [serial] Import exact 0.20-cohort source commit with package-local provenance. r[onixpkgs.radicle_cob_git_store.source]
- [x] [serial] Import exact 0.21-cohort source commit with package-local provenance and version. r[onixpkgs.radicle_cob_git_store.source]
- [x] [serial] Export both Linux source packages and document their output and claim boundaries. r[onixpkgs.radicle_cob_git_store.package]

## Phase 2: Verification

- [x] [serial] Reject wrong new digests, unavailable prior commits, modified vendor files, symlink substitutions, and extra empty directories without losing local content; verify pristine update, failed-publication rollback, and idempotent pins with throwaway fixtures. r[onixpkgs.radicle_cob_git_store.source]
- [x] [serial] Build both packages, confirm cohort-specific crate behavior tests run, and inspect both installed sources. r[onixpkgs.radicle_cob_git_store.package]
- [x] [serial] Build the formatting check and validate the final two-cohort change with Cairn. r[onixpkgs.radicle_cob_git_store.package]
