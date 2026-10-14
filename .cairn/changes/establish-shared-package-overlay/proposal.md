## Why

Custom packages in the Onix stack live in each consuming repository. onix-core carries 46 tracked package directories under `pkgs/` and exposes them only as its own flake `packages` and through an internal NixOS overlay in `inventory/tags/common/shared-nix.nix`. Other repositories copy or reach into these definitions: `site/nix/celld.nix` has the same content as onix-core's `pkgs/celld`; trellis builds tracey 1.3.0 again from a `releases/latest` URL; aspen imports `pkgs/kache` from a pinned onix-core source input; and onixos pins its own, divergent iroh-ssh and mesh-llm packages. Every copy needs its own pin updates and drifts from the others.

## What Changes

- Add onixpkgs, a flake whose `overlays.default` exposes each `pkgs/<name>` directory as `pkgs.<name>`, built with the consumer's package set.
- Move onix-core's 42 portable packages here with their patches and package tests. Package contents stay byte-identical, apart from patch paths, the `lemonade` directory name (now `lemonade-server`, its attribute name), and the updater description.
- Export `packages` for x86_64-linux, aarch64-linux, and aarch64-darwin. A package is exported only on systems where it evaluates.
- Run package builds, the Collie controller and remote-session tests, and Nix formatting as `checks`.
- Keep dgx-machine, tenstorrent-compat, nix-grpc-store, and aspen-uma-helper in onix-core. They depend on onix-core's machine inventory, the private tenstorrent.nix flake, or onix-core's Nix fork.

Immediate outcome: onix-core consumes its packages from the overlay instead of `pkgs/`. Durable capability: one maintained package set for the stack. Current consumer: onix-core. Adoption path: site, trellis, aspen, and onixos can switch their copies to the overlay published at `github.com/OnixResearch/onixpkgs`. Maintenance owner: brittonr.

## Impact

- **Files**: `flake.nix`, `flake.lock`, `overlay.nix`, `pkgs/`, `README.md`, `AGENTS.md`, and this change. onix-core's adoption is tracked by its own change `adopt-onixpkgs-overlay`.
- **Testing**: evaluate `packages` and `checks` on every exported system. Compare each migrated package's derivation with onix-core's derivation at the migration base. Build the Collie tests, the formatting check, and a sample of packages. Validate this Cairn change.
