## Context

onixos defines iroh-ssh 0.2.12 in `nix/iroh-ssh-package.nix`, built from a `flake = false` input pinned to `c799cfd1`, the commit behind upstream tag `0.2.12`. It adds `nix/patches/iroh-ssh-connection-type-evidence.patch`, runs `cargo test --all-targets`, and tests exit-status propagation in `nix/iroh-ssh-child-status-check.nix`. onixos's `nix/mesh-llm-package.nix` builds Mesh LLM 0.72.1 headless, with a statically linked llama.cpp and a `backend` argument of `cpu` or `vulkan`. onix-core's `lib/kache-nix-rust.nix` builds kache rustc wrappers. aspen imports it, together with `pkgs/kache`, from a pinned onix-core source.

## Decisions

### Decision: iroh-ssh keeps the fetchFromGitHub pin

**Choice:** `pkgs/iroh-ssh` fetches tag `0.2.12` with `fetchFromGitHub`, using the NAR hash of onixos's input, and keeps its `nix-update-args`. The patch and the child-status test move beside the package.

**Rationale:** The tag and onixos's pinned commit have the same tree, so the source store path is the same. nix-update keeps working. The derivation differs from onixos's only because the source comes from a fixed-output derivation instead of an input path.

### Decision: iroh-ssh platforms follow nixpkgs, exports stay on Linux

**Choice:** `meta.platforms` is `lib.platforms.unix`, which is what onixos inherited from nixpkgs. `exportSystems` keeps `iroh-ssh` on Linux.

**Rationale:** onixos exports iroh-ssh on Darwin, so the overlay must not mark it unavailable there. onixpkgs has no Darwin builder, so it does not claim a Darwin build in `packages` or `checks`.

### Decision: The headless build is a separate package

**Choice:** `pkgs/mesh-llm-headless` is onixos's `nix/mesh-llm-package.nix` with only the patch path changed. It stays at Mesh LLM 0.72.1. The vulkan backend is `pkgs.mesh-llm-headless.override { backend = "vulkan"; }`, built by the `package-mesh-llm-headless-vulkan` check.

**Rationale:** An unchanged file gives onixos the same derivations it builds today, so the move can be checked by derivation path. `pkgs.mesh-llm` is a different build: it has plugins, targets release platforms, and is what onix-core's services run. Folding the two together or moving the headless build to 0.72.2 would change a running service, so it is left for a later change. A check covers the vulkan variant without adding an attribute that has no directory.

### Decision: The kache library is a system-independent flake output

**Choice:** `lib.kacheNixRust` is the function in `lib/kache-nix-rust.nix`. Callers supply `lib`, `pkgs`, and `kachePackage`. The contract check from onix-core's `_kache-nix-rust-checks.nix` lives in `lib/kache-nix-rust-contract.nix`. Its missing-cache case now sets `KACHE_NIX_CACHE_DIR` to a directory inside the build that does not exist. It also checks that the diagnostic names that directory.

**Rationale:** The library builds wrappers for whatever package set and kache package the caller passes, so it has no system of its own. Checks in onix-core that read its machine configuration stay in onix-core. The onix-core copy relied on `/var/cache/kache-nix` being absent from the build sandbox. Builders that use kache expose that directory through `sandbox-paths`, so on them the negative case failed even though the wrapper was correct. britton-desktop is one such builder.

## Risks / Trade-offs

- onix-core machines that use `pkgs.iroh-ssh` move from 0.2.9 to 0.2.12 when onix-core relocks onixpkgs. Both versions use iroh 0.94. Hosts running either version during a rollout share one protocol version.
- `iroh-ssh connect` writes an extra stderr line. A script that parses iroh-ssh stderr must ignore lines that start with `IROH_SSH_CONNECTION_TYPE=`.
- onixpkgs carries two Mesh LLM versions: `mesh-llm` 0.72.2 and `mesh-llm-headless` 0.72.1.
- iroh-ssh and mesh-llm-headless are not built on Darwin here.

## Measured Verification

- `iroh-ssh` 0.2.12 builds on x86_64-linux. Its test run passes 4 tests, including `connection_type_labels_describe_usable_routes` and `connection_type_label_preserves_no_route`. `iroh-ssh-child-status` passes with child exit statuses 0 and 23.
- With the overlay applied to onixos's nixpkgs, `mesh-llm-headless` has the same derivations as onixos's own package for cpu and vulkan on x86_64-linux and for cpu on aarch64-linux. `backend = "cuda"` fails evaluation with `mesh-llm: supported backend profiles are cpu and vulkan`.
- In the same setting, `iroh-ssh` uses the same source store path as onixos's input. nix-diff shows that its derivation and the vendor derivation differ only because the source comes from a fixed-output derivation instead of an input path.
- The kache contract built from onix-core's copy failed on britton-desktop with `negative: missing cache directory unexpectedly succeeded`. After the change the contract passes. A wrapper built with `requireCacheDir = false` fails it with the same message.
- `mesh-llm-headless` and `package-mesh-llm-headless-vulkan` build on x86_64-linux with onixpkgs' own nixpkgs. Both binaries report `mesh-llm 0.72.1+gc14e458d38e2`. Their provenance records the `cpu` and `vulkan` backends and llama.cpp `e3546c79`, and only the vulkan binary's runtime library path contains the Vulkan loader.
