# Agent Notes

This is an independent Git repository. It owns only product-neutral local Git storage for signed Radicle COBs and explicit signer loading. Keep reducers, domain types, authorization, locks, and high-level CRUD in consumers.

Cairn is the current consumer. Adoption vendors an archive from a pinned source commit into Cairn after this repository's source commit; this repository does not promise transport or a remote. Do not add sibling-path dependencies, `cairn-core`, umbrella `radicle`, or node dependencies. Do not push without an independently supplied remote and authorization.

Run from this repository: `cargo fmt --all -- --check`, `cargo test`, `cargo clippy --all-targets -- -D warnings`, and `nix flake check -L` when Nix is available. Include positive and negative behavior tests for Git refs, signatures, and signer paths. Local Git observations are not a filesystem capability or concurrency guarantee.
