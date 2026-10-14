# Agent Notes

This is an independent Git repository. It owns only product-neutral local Git storage for signed Radicle COBs. Keep reducers, domain types, signer resolution, authorization, locks, and high-level CRUD in consumers.

Cairn and Valence retain immutable 0.20-cohort source pins (Valence uses the v0.1.1 legacy ref layout). Kiln consumes the separate 0.21-cohort v0.2.0 namespaced store through a commit-pinned vendored archive. These cohorts are not interchangeable. This repository does not promise transport or a remote. Do not add sibling-path dependencies, `cairn-core`, umbrella `radicle`, or node dependencies. Do not push without an independently supplied remote and authorization.

Run from this repository: `cargo fmt --all -- --check`, `cargo test`, `cargo clippy --all-targets -- -D warnings`, and `nix flake check -L` when Nix is available. Include positive and negative behavior tests for Git refs, signatures, CAS and bounded scans. Local Git observations are not a filesystem capability or concurrency guarantee.
