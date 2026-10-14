# onix-radicle-cob-git-store

Product-neutral local Git storage for signed Radicle collaborative objects (COBs). `GitCobStore` implements the direct `radicle-cob` `Store`, `change::Storage`, and `object::Storage` contracts over `git2`, and exposes ref inspection, rollback, local commit-identity validation, and the underlying repository. `load_signer` loads an explicitly supplied keystore and rejects a symlink at the keystore path.

Version 0.1.1 adds `RefLayout::RadLegacy` for Valence while retaining `GitCobStore::open` and the default namespaced behavior from 0.1.0 for Cairn. Existing `refs/rad/<actor>/cobs/<type>/<object>` refs require explicit `GitCobStore::open_with_layout(path, RefLayout::RadLegacy)`; reads, updates and deletions stay within that layout, and switching layouts does not migrate old refs. Both layouts validate ref identity, signed change author, manifest type and signature when reading COB refs. `store.ref_name(...)` returns the selected ref spelling for consumer plans.

## Boundary and consumer

Cairn consumes the default namespaced layout; Valence opts into its established `refs/rad` layout. Their crates retain domain reducers, types, locks where applicable, actor authorization, claims, and high-level orchestration. This repository's maintenance owner is the OnixResearch Radicle COB Git store maintainers. The target outcome is reuse of local signed COB/ref storage without importing consumer policy. No behavior here authorizes an actor, validates product semantics, supplies transport, discovers keys, protects ancestor paths against symlinks, establishes a filesystem snapshot, or makes a distributed consistency or release-readiness claim.

Cairn's existing adoption uses a commit-pinned in-repository vendor archive. Valence adopts its own verified commit-pinned vendor archive. Consumers record the archive digest and source identity beside the import and run their own checks. A workspace-relative path is not a durable dependency. No remote, Radicle RID, GitHub endpoint, or network transport is declared here.

Earlier source snapshot used by Cairn's vendor adoption:

- Git commit: `af38dae7e0454b1206512794420a3076ea5a8d1f`
- BLAKE3 digest of `git archive --format=tar af38dae7e0454b1206512794420a3076ea5a8d1f`: `ff1392cab83cb76123c56b0a70ab50fa0893788f5a876e4daf614003905a38e0`

The archive digest identifies this exact tar byte stream (including Git archive metadata), not an independently published release or a remote source.

`LICENSE-MIT` and `LICENSE-APACHE` retain the original Cairn contributor license text for the extracted source.

## Verification

```sh
cargo fmt --all -- --check
cargo test
cargo clippy --all-targets -- -D warnings
nix flake check -L
```

The tests exercise a signed dummy COB roundtrip and Git reference inspection, reject malformed refs and signed-author mismatches, detect stale ref updates and rollback attempts, and reject symlinked signer paths. Those tests establish only their local scenarios, not arbitrary Git concurrency or trust.
