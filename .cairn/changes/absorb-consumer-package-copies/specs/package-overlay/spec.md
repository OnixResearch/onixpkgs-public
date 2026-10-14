## ADDED Requirements

### Requirement: iroh-ssh reports its route and the ssh exit status

r[onixpkgs.iroh_ssh.evidence] `pkgs.iroh-ssh` MUST build iroh-ssh with the connection-type evidence patch, so that `iroh-ssh connect` prints `IROH_SSH_CONNECTION_TYPE=` followed by `direct`, `relay`, `mixed`, or `none` to stderr. `iroh-ssh connect` MUST exit with the exit status of its ssh child. `checks.<system>.iroh-ssh-child-status` MUST test both a zero and a nonzero child status on every system that exports `iroh-ssh`.

#### Scenario: Failing ssh child

- GIVEN a fake `ssh` on `PATH` that exits with status 23
- WHEN `iroh-ssh connect` runs it
- THEN `iroh-ssh` MUST exit with status 23

#### Scenario: Successful ssh child

- GIVEN a fake `ssh` on `PATH` that exits with status 0
- WHEN `iroh-ssh connect` runs it
- THEN `iroh-ssh` MUST exit with status 0

### Requirement: Headless Mesh LLM backends

r[onixpkgs.mesh_llm_headless.backends] `pkgs.mesh-llm-headless` MUST build the headless Mesh LLM binary with the cpu backend by default, and with the vulkan backend when overridden with `backend = "vulkan"`. Any other backend MUST fail evaluation. Each build MUST install `share/mesh-llm/source-envelope.json`, `license-inventory.json`, and `provenance.json`, which name the backend and the pinned Mesh LLM and llama.cpp revisions. The package MUST NOT replace `pkgs.mesh-llm`.

#### Scenario: Vulkan override

- GIVEN a consumer that evaluates `pkgs.mesh-llm-headless.override { backend = "vulkan"; }`
- WHEN the package builds
- THEN its provenance MUST record the vulkan backend, and the binary's runtime library path MUST include the Vulkan loader

#### Scenario: Unsupported backend

- GIVEN a consumer that overrides `backend = "cuda"`
- WHEN it evaluates the package
- THEN evaluation MUST fail with a message that names the supported backends

### Requirement: Shared kache wrapper library

r[onixpkgs.lib.kache_nix_rust] `lib.kacheNixRust` MUST be a function of `{ lib, pkgs, kachePackage }` that returns `mkCargoRustcWrapper`, `mkRustcWrapper`, `mkWrappedRustPackage`, `defaultCacheDir`, and `missingCacheExitCode`. `checks.x86_64-linux.kache-nix-rust-wrapper-contract` MUST exercise the library with a fake kache. The check MUST fail when a wrapper skips kache, drops the real rustc path or its arguments, invokes kache while `KACHE_NIX_DISABLED=1` is set, or succeeds without a writable cache directory.

#### Scenario: Consumer builds a wrapped toolchain

- GIVEN a consumer that calls `lib.kacheNixRust` with its own `kachePackage`
- WHEN it builds `mkWrappedRustPackage`
- THEN rustc invocations MUST pass through that kache package

#### Scenario: Missing cache directory

- GIVEN a wrapper built with a required cache directory
- WHEN the directory is not writable
- THEN the wrapper MUST exit nonzero, report that the cache directory is not writable, and print the directory it tried
