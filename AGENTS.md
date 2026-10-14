# Agent Notes

## Scope

onixpkgs holds package definitions: derivations, source pins, and package-local patches and tests. Service modules, machine configuration, inventories, and secrets belong to consumers such as onix-core.

## Package rules

- Name each directory under `pkgs/` after its attribute. `overlay.nix` calls every `pkgs/<name>/default.nix` with `final.callPackage`.
- Refer to another onixpkgs package through a callPackage argument, never by path. `callArgs` in `overlay.nix` maps renamed arguments, such as herdr's `collie`.
- Do not give a package function a default that reaches into a flake input. Pass inputs through `callArgs`.
- Do not bake consumer data, such as machine inventories or secrets, into a package here. Such packages stay with their consumer.
- Keep patches inside the package directory they apply to.
- A package with `src = ./.` or `lib.cleanSource ./.` hashes its whole directory, including `default.nix`. Any edit there rebuilds the package and every closure that contains it.
- `pkgs/lemonade-server/default.nix` must accept either `lemond` or `lemonade-router` as the daemon binary name. Upstream changed names across releases, so install both aliases.
- nix-update bumps only `version` when a package pins a literal `rev = "<commit>"`. Template tag revisions (`rev = "v${version}"`) or refresh the source and dependency hashes by hand.
- `pkgs/iroh-ssh` carries `iroh-ssh-connection-type-evidence.patch`. After a version bump, confirm the patch still applies and that `checks.<system>.iroh-ssh-child-status` passes.
- `pkgs/mesh-llm-headless` is onixos's headless Mesh LLM build, and onixos's guard reads its `share/mesh-llm` provenance. Coordinate any change to it with onixos. It is a different build from `pkgs/mesh-llm`.
- `lib/` holds functions exported under `lib`. They take the package set from the caller and must not import nixpkgs themselves.

## Checks

- Build a changed package with `nix build .#<name>`. Run `nix build .#checks.<system>.formatting` for the treefmt formatting and lint check.
- `nix flake check -L` builds every exported package, including the ROCm llama.cpp builds and the DeepSeek draft conversion. Run it before claiming the whole set builds.
- Run `nix fmt` to apply the formatters. Formatting a file inside a `src = ./.` package changes that package's derivation.
- After changing `lib/kache-nix-rust.nix`, build `checks.x86_64-linux.kache-nix-rust-wrapper-contract`.

## Consumers

- onix-core follows this flake's `nixpkgs`, `llm-agents`, `wrappers`, and `treefmt-nix` inputs from its own lock. Before merging a package change, evaluate the onix-core machines that use the package.
- site (`celld`), trellis (`tracey`), aspen (`kache` and `lib.kacheNixRust`), and onixos (`iroh-ssh` and `mesh-llm-headless`) also use this flake. A package change reaches them when they relock `onixpkgs`. aspen and onixos pin a revision in the input URL, so they need a URL edit.
- Do not push or publish unless explicitly requested. When a push of `main` is requested, push it to both remotes: `origin` on GitHub, which consumers fetch, and the private Radicle remote `rad` (`rad:z4HzpZp4taChnHMVL3gtMjF1iesp1`), for example `jj git push --remote rad --bookmark main`.

## Lifecycle

Use native Cairn under `.cairn/`.
