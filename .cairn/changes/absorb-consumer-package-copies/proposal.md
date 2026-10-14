## Why

After onixpkgs took over onix-core's packages, three consumers still carried their own package definitions. onixos pinned iroh-ssh 0.2.12 with a connection-type evidence patch and a child-status test, while onixpkgs shipped 0.2.9 without either. onixos also built a headless Mesh LLM with cpu and vulkan backends that onixpkgs lacked. aspen imported onix-core's `lib/kache-nix-rust.nix` wrapper library, together with `pkgs/kache`, from a pinned onix-core source input.

## What Changes

- Update `iroh-ssh` from 0.2.9 to onixos's 0.2.12. Add onixos's connection-type evidence patch, run the crate's tests for all targets, and add onixos's child-status test as the `iroh-ssh-child-status` check. Correct the license to MIT, matching upstream. `meta.platforms` becomes unix, matching nixpkgs, so the overlay provides the package on Darwin. `exportSystems` still exports it on Linux only.
- Add `mesh-llm-headless`, onixos's headless source build of Mesh LLM 0.72.1. It selects the cpu or vulkan backend through its `backend` argument and writes provenance and license-inventory JSON under `share/mesh-llm`. The default `mesh-llm` package, onix-core's 0.72.2 build, does not change.
- Export `lib.kacheNixRust`, onix-core's kache wrapper library, and run its wrapper contract as the `kache-nix-rust-wrapper-contract` check on x86_64-linux.

Immediate outcome: onixos and aspen can drop their copies and take these from onixpkgs. Durable capability: one definition of each package and of the kache wrapper library for the stack. Current consumers: onixos (iroh-ssh, mesh-llm-headless), aspen and onix-core (kache library), and onix-core machines that run iroh-ssh. Maintenance owner: brittonr.

## Impact

- **Files**: `pkgs/iroh-ssh/`, `pkgs/mesh-llm-headless/`, `lib/`, `flake.nix`, `README.md`, and this change.
- **Behavior**: onix-core machines that use `pkgs.iroh-ssh` move from 0.2.9 to 0.2.12. Both versions depend on iroh 0.94. `iroh-ssh connect` now prints an `IROH_SSH_CONNECTION_TYPE=` line to stderr and exits with the status of the ssh child.
- **Testing**: build `iroh-ssh` and the child-status check. Compare the `mesh-llm-headless` derivations with onixos's own derivations when the overlay is applied to onixos's nixpkgs. Compare the kache contract derivation with onix-core's. Build `mesh-llm-headless`, and run the formatting check. Validate this change with Cairn.
