# onixpkgs

onixpkgs publishes Onix's custom packages as one overlay over nixpkgs. A repository in the stack applies the overlay and uses `pkgs.<name>` instead of carrying its own copy of the package.

## Use

Add the flake input and let it follow your nixpkgs:

```nix
inputs.onixpkgs = {
  url = "git+https://github.com/OnixResearch/onixpkgs-public.git";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

Apply the overlay wherever you instantiate nixpkgs:

```nix
# NixOS, nix-darwin, or Home Manager without useGlobalPkgs
nixpkgs.overlays = [ inputs.onixpkgs.overlays.default ];

# Flake code
pkgs = import nixpkgs {
  inherit system;
  overlays = [ inputs.onixpkgs.overlays.default ];
  config = { };
};
```

Flake code that does not instantiate nixpkgs can use `inputs.onixpkgs.packages.${system}.<name>`. These packages are built from the overlay over plain nixpkgs. They do not see the consumer's nixpkgs config or other overlays.

`lib.kacheNixRust` builds rustc wrappers that route compilation through kache. Call it with the package set and kache package to use:

```nix
kacheLib = inputs.onixpkgs.lib.kacheNixRust {
  inherit (pkgs) lib;
  inherit pkgs;
  kachePackage = pkgs.kache;
};
wrappedRust = kacheLib.mkWrappedRustPackage {
  rust = pkgs.rustc;
  cacheDir = "/var/cache/kache-nix";
};
```

## Layout

- `overlay.nix` is `overlays.default`. Each directory `pkgs/<name>/` becomes `pkgs.<name>`, built with `final.callPackage`. `callArgs` holds arguments that do not come from the package set, such as flake inputs. `callers` holds packages built by a scoped callPackage.
- `pkgs/<name>/default.nix` is a callPackage function. Patches, local sources, and package tests live beside it.
- `herdr-unwrapped` is the upstream Herdr from `llm-agents.nix`. `pkgs.herdr` wraps it. A later overlay can replace the base.
- `flake.nix` exports `overlays.default`, `lib`, `packages`, `checks`, and `formatter`. `exportSystems` limits where a package is exported. An unlisted package is exported on every system its `meta.platforms` allows.
- `lib/kache-nix-rust.nix` is `lib.kacheNixRust`. `lib/kache-nix-rust-contract.nix` tests it with a fake kache.
- `mesh-llm-headless` is the headless Mesh LLM 0.72.1 build that onixos runs. Its `backend` argument selects `cpu`, the default, or `vulkan`: `pkgs.mesh-llm-headless.override { backend = "vulkan"; }`. It writes provenance and license-inventory JSON under `share/mesh-llm`. `mesh-llm` is a separate 0.72.2 build with plugins, which onix-core's services run.
- `radicle-cob-git-store` and `radicle-cob-git-store-020` publish the two supported Radicle COB dependency cohorts as Cargo crate source.

## Radicle COB Git store source

`pkgs.radicle-cob-git-store` supplies crate 0.2.0 for Radicle COB 0.21;
`pkgs.radicle-cob-git-store-020` supplies crate 0.1.1 for Radicle COB 0.20.
Both export on x86_64-linux and aarch64-linux. The older cohort overrides the
same package function with its own immutable source, lock, and version. Cairn's
migration branch vendors crate 0.1.0 at `af38dae7e0454b1206512794420a3076ea5a8d1f`
in its own repository; Valence vendors 0.1.1 at
`f78168ea4560ce3a3167b5850bc0c1568e1a1abe` in its own repository.
Kiln will likewise pin crate 0.2.0 in its own vendor tree. None currently uses
an onixpkgs attribute as a direct build input: these packages make the
compatible COB dependency cohorts available for future Nix adoption; cohort
compatibility does not assert byte identity with every consumer's own vendor.
Each consumer retains its COB policy, reducers, locks, authorization, and
high-level operations.

These packages compile the library and run `cargo test --all-targets` before
installing `Cargo.toml`, `Cargo.lock`, `src/`, and both licenses. Their output is
usable Cargo **crate source**, not an executable or portable compiled rlib.
Consumers compile it in their own Rust workspace/toolchain; selecting an
onixpkgs package does not automatically add it to a Cargo dependency graph.

The independent source repository has no published remote. Each package's
`VENDORED.md` records its exact Git commit and Git-archive BLAKE3. The
`pkgs/radicle-cob-git-store/import-source.sh` command takes a target package
name, explicit source checkout, full commit, and independently recorded digest;
it verifies the requested archive and replays the prior commit and archive
digest from that checkout. Existing vendor paths, modes, symlinks, and bytes
must exactly match the prior archive, including the absence of extra files or
directories; drift or a missing/invalid prior identity stops the import
without replacing the snapshot or receipt. Importing the same pin is a no-op.
Preserve local vendor edits separately before requesting an update. Builds
depend only on source committed in onixpkgs, not on an ambient sibling
checkout. The archive digest identifies tar bytes, not a Nix source hash.
Builds and local tests do not establish host behavior, distributed consistency,
actor authority, or upstream correctness. A new producer revision requires a
verified import and a separate consumer adoption decision.

## Add a package

1. Create `pkgs/<name>/default.nix`. The directory name is the attribute name.
2. Take dependencies as callPackage arguments. Refer to other onixpkgs packages by attribute name, not by path, so a later overlay can replace them.
3. Put arguments that the package set cannot supply in `callArgs` in `overlay.nix`.
4. Restrict export systems with `meta.platforms` or `exportSystems`.
5. Run `nix build .#<name>` and `nix build .#checks.<system>.formatting`.

`nix run .#updater -- --list` lists packages that have a `nix-update-args` file. `nix run .#updater -- --package <name>` runs nix-update for one of them.

## Checks

`nix flake check -L` builds every exported package and the vulkan variant of `mesh-llm-headless`. It runs the Collie controller and remote-session tests, the iroh-ssh child-status test, the kache wrapper contract on x86_64-linux, and the treefmt check (nixfmt, deadnix, statix, ruff, shellcheck, shfmt, rustfmt, prettier). The ROCm llama.cpp builds and the DeepSeek draft conversion are large; the conversion downloads three checkpoint shards. `nix fmt` applies the same formatters. `ruff.toml` carries onix-core's Python lint settings.

## Consumers

- onix-core applies the overlay to its NixOS and nix-darwin machines, whose Home Manager profiles share that package set. It also applies the overlay to its DGX machines through `modules/dgx-machine` and to its check harnesses. Its dev shell uses `packages`. dgx-machine, tenstorrent-compat, nix-grpc-store, and aspen-uma-helper stay in onix-core, because they depend on onix-core's machine inventory, the private tenstorrent.nix flake, or its Nix fork.
- site takes `celld` from the overlay and trellis takes `tracey`.
- aspen takes `kache` from the overlay and builds its kache rustc wrappers with `lib.kacheNixRust`.
- onixos takes `iroh-ssh` and `mesh-llm-headless` from an overlaid package set and wraps Mesh LLM with its own guard and bundle.

site, trellis, aspen, and onixos pin onixpkgs by revision or through their locks, so a package change reaches them when they relock.

Maintainer: brittonr.

## Claim boundary

onixpkgs owns package definitions, their source pins, and package-local patches and tests. A successful build shows only that the derivation realizes on that system. It does not show that the package works on a host, that a consumer's service configuration is valid, or that the upstream software is correct. Service modules, machine policy, secrets, and deployment evidence stay with the consumers.

## References

- [Mastering Nixpkgs Overlays](https://nixcademy.com/posts/mastering-nixpkgs-overlays-techniques-and-best-practice/), the [NixOS wiki overlay page](https://wiki.nixos.org/wiki/Overlays), and [NixOS & Flakes: Overlays](https://nixos-and-flakes.thiscute.world/nixpkgs/overlays) — overlay conventions followed by `overlay.nix`: `final`/`prev` roles, no `rec`, dependencies through `final`, and shared choices exposed as attributes rather than overlay parameters.
- [numtide/llm-agents.nix](https://github.com/numtide/llm-agents.nix) — upstream Herdr binary (`herdr-unwrapped`) wrapped by `pkgs/herdr`.
- [brittonr/wrappers](https://github.com/brittonr/wrappers) — wrapper library used by `pkgs/herdr`.
- [peters/horizon](https://github.com/peters/horizon) — source input of `pkgs/horizon`. It is fetched through git with LFS, because its bundled fonts are LFS objects.
- [domenkozar/agentaps](https://github.com/domenkozar/agentaps) — upstream of `pkgs/agentaps`. The package pins a `main` commit after the v0.2.1 release, because that release has no SSH projects or Web Connect.
- [rustonbsd/iroh-ssh](https://github.com/rustonbsd/iroh-ssh) — upstream of `pkgs/iroh-ssh`. `iroh-ssh-connection-type-evidence.patch` makes `iroh-ssh connect` print the connection type.
- [smarzban/herdr-file-viewer](https://github.com/smarzban/herdr-file-viewer), [persiyanov/herdr-reviewr](https://github.com/persiyanov/herdr-reviewr), [paulbkim-dev/vim-herdr-navigation](https://github.com/paulbkim-dev/vim-herdr-navigation), [nikok6/herdr-mirror](https://github.com/nikok6/herdr-mirror), and [NathanFlurry/herdr-plugin-jj-workspace](https://github.com/NathanFlurry/herdr-plugin-jj-workspace) — pinned Herdr plugins in the `pkgs/herdr` static registry.
- `pkgs/herdr/vendor/herdr-plugin-pueue` — local Herdr Pueue dashboard source, vendored until that repository has a remote.
- [osolmaz/ghzinga](https://github.com/osolmaz/ghzinga) — pinned Rust CLI and Herdr link handler for GitHub issue and pull request views.
- [umakers/collie-herdr](https://github.com/umakers/collie-herdr) — phone PWA for Herdr over Tailscale. `pkgs/collie-herdr/UPSTREAM.md` describes the package and trust boundaries.
- [Noelo-Lab/kuna](https://github.com/Noelo-Lab/kuna) — binaries and SLEIGH specs for the Kuna decompiler package.
- [PrimeIntellect-ai/prime-agent](https://github.com/PrimeIntellect-ai/prime-agent) — upstream coding and research agent.
- [OpenBubbles/openbubbles-app](https://github.com/OpenBubbles/openbubbles-app) — pinned Linux release bundle wrapped as `pkgs/openbubbles`.
- [denoland/celld](https://github.com/denoland/celld), [kunobi-ninja/kache](https://github.com/kunobi-ninja/kache), [murerkinn/bookshelf](https://github.com/murerkinn/bookshelf), and [Mesh-LLM/mesh-llm](https://github.com/Mesh-LLM/mesh-llm) — upstream sources of the packages behind onix-core's Celld, Kache, Bookshelf, and Mesh-LLM services.
