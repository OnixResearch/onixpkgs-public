## Context

onix-core exposed `pkgs/<name>` packages three ways. Flake `packages` came from `flake-outputs/tools.nix` over plain nixpkgs. NixOS modules and Home Manager profiles called `pkgs.callPackage ../../pkgs/<name> { }` against the machine package set. An internal overlay in `inventory/tags/common/shared-nix.nix` injected nine flake packages into machine package sets. Some packages also took flake inputs as arguments: herdr took the `llm-agents` Herdr and the `wrappers` library, and horizon took its `horizon` source input.

The migration base is onix-core `c5001ff2` with its uncommitted working tree of 2026-09-27, which includes in-flight packages such as laya, arxiv-corpus, mesh-research, and underclass-mesh-gateway.

## Decisions

### Decision: One overlay with directory discovery

**Choice:** `overlay.nix` maps every directory under `pkgs/` to `final.callPackage ./pkgs/<name> (callArgs.<name> or { })`. `callers` selects a scoped callPackage, which only claude-md needs: it uses `python3Packages.callPackage`. `herdr-unwrapped` exposes the upstream Herdr as an attribute of its own.

**Rationale:** A new package cannot be forgotten in a registry. Dependencies between onixpkgs packages resolve through `final`, so a later overlay that replaces collie-herdr or herdr-unwrapped reaches the wrapper. This follows the nixpkgs overlay guidance: use `prev` only to override existing symbols, reference packages through `final`, avoid `rec`, and publish shared choices as attributes instead of overlay parameters.

### Decision: Flake inputs are wired in the overlay and followable

**Choice:** onixpkgs declares `nixpkgs`; `llm-agents`, `wrappers`, and `horizon`, which `overlay.nix` passes to herdr and horizon; and `treefmt-nix` for the formatting check. The initial lock pins the same revisions that onix-core locked at the migration base.

**Rationale:** Package functions stay ordinary callPackage functions. A consumer that follows `nixpkgs`, `llm-agents`, and `wrappers` gets the derivations it built before the move.

### Decision: Byte-identical package contents

**Choice:** Copy only the files onix-core's flake saw (`git ls-files`, including intent-to-add files, with working-tree contents and modes). Keep directory names, except that `lemonade` becomes `lemonade-server`, its attribute name. Move the lemonade and mesh-llm patches from onix-core's `patches/` into their package directories. Change the updater's description to name onixpkgs. Apply the formatter only where the in-flight laya-cpp files failed it: a trailing newline in `model-manifest.json` and an `inherit` that statix requires.

**Rationale:** Packages with `src = ./.` or `lib.cleanSource ./.` hash their whole directory, and path sources hash by name and content. Identical contents and names give identical derivations, which makes the move checkable. The updater change rebuilds only the updater, which is in no machine closure. The laya-cpp bundle copies `model-manifest.json`, so its newline changes that bundle and the Laya unit on aspen1. onix-core's own treefmt gate would have required the same edit before the file could be committed.

### Decision: Keep onix-core's formatting gates

**Choice:** `treefmt.nix` runs deadnix, statix, nixfmt, shellcheck, shfmt, ruff check and format, rustfmt, and prettier with onix-core's includes and excludes. `ruff.toml` copies onix-core's Python lint settings. `checks.<system>.formatting` is the treefmt check, and `formatter` is its wrapper.

**Rationale:** In onix-core these gates covered the moved Nix, Python, shell, Rust, and TypeScript sources. Dropping them would let the sources drift without notice. onix-core's mypy step had no directories configured, so it is omitted.

### Decision: Consumer-bound packages stay with the consumer

**Choice:** dgx-machine, tenstorrent-compat, nix-grpc-store, and aspen-uma-helper stay in onix-core. The Collie Home Manager integration check stays in onix-core too, because it inspects onix-core's evaluated machine configuration.

**Rationale:** dgx-machine bakes onix-core's DGX inventory into its build. tenstorrent-compat patches the private tenstorrent.nix flake. nix-grpc-store is built against onix-core's Nix fork and its nixpkgs snapshot. aspen-uma-helper is a separate flake project, not a callPackage function. Moving them would give every consumer of onixpkgs private or fork inputs, or a package that cannot build without consumer data.

### Decision: Export only what evaluates

**Choice:** `packages` covers x86_64-linux, aarch64-linux, and aarch64-darwin. `exportSystems` carries onix-core's former export gates. The three ROCm llama.cpp packages move to x86_64-linux only, and `meta.platforms` excludes the rest, including prime-agent on everything but x86_64-linux.

**Rationale:** The pinned nixpkgs throws for x86_64-darwin. onix-core exported the ROCm packages on aarch64-linux and prime-agent on every system, where their evaluation fails. The export table now only removes packages that could not evaluate.

## Risks / Trade-offs

- Consumers fetch onixpkgs over SSH from `github.com/OnixResearch/onixpkgs`, as onix-core does for its other OnixResearch inputs. A host without SSH access to the OnixResearch organization cannot evaluate a consumer.
- onixpkgs has no CI of its own yet. onix-core CI still builds every migrated package that a machine closure or the dev shell contains. Packages outside those closures, such as hx-oil and updater, are built only by `nix flake check` here.
- `checks` build every exported package, including the ROCm llama.cpp builds and the DeepSeek draft conversion. A full check run is expensive without a warm cache.
- A package set without the overlay silently resolves `dumbpipe`, `herdr`, `iroh-ssh`, `sendme`, `sone`, and `tuicr` from nixpkgs, which defines the same names.
- `horizon` did not build at first, as it did not in onix-core. Its `cargoHash` was stale at the migration-base source revision `138c5571`, and `138c5571` also needs Git LFS font assets that the GitHub tarball lacks. The follow-up keeps the pin, fetches the source with `git+https://github.com/peters/horizon?lfs=1`, and sets `cargoHash` to the vendor hash of that revision. The package then builds.

## Measured Verification

All derivation comparisons use the onix-core migration base: a worktree at `c5001ff2` with the base's uncommitted changes applied. Its tracked file contents and executable bits match the working tree, and it produced the working tree's `aspen1` toplevel derivation.

- `packages.x86_64-linux` exports 42 packages. 40 have the same derivation as onix-core's `packages.x86_64-linux`. laya-cpp and updater differ, as described above.
- `packages.aarch64-linux` exports 33 packages. 31 are identical and laya-cpp and updater differ. onix-core also exported the three ROCm llama.cpp packages and prime-agent there; those could not be evaluated.
- `packages.aarch64-darwin` exports 15 packages. 14 are identical and updater differs. onix-core also exported prime-agent there; it could not be evaluated.
- `checks.x86_64-linux` evaluates. The formatting check, `collie-managed-controller`, and `collie-remote-sessions` build. The last two have the same derivations as the onix-core checks they replace. The remote-session suite reports 12 passing tests.
- 31 of the 42 x86_64-linux outputs were already in the local store, because their derivations are unchanged. buildbot-pr-check, hx-oil, laya-cpp, merge-when-green, open-notebook, underclass-mesh-gateway, and updater were built. horizon fails as described above. deepseek-v4-dspark-draft, llamacpp-rocm-dspark, and llamacpp-rocm-qwen4exp were not built; their derivations are unchanged.
- A later overlay that replaces `collie-herdr` and `herdr-unwrapped` changes `pkgs.herdr`'s plugin roots, base package, and derivation.
- The updater run from this repository lists iroh-ssh and tuicr as its nix-update packages.
