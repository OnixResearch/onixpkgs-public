## Phase 1: Implementation

- [x] [serial] Update `pkgs/iroh-ssh` to 0.2.12 with onixos's connection-type evidence patch and all-target tests, and add the child-status test as a check. r[onixpkgs.iroh_ssh.evidence]
- [x] [serial] Add `pkgs/mesh-llm-headless` from onixos with its join-file patch, export it on Linux, and build the vulkan override as a check. r[onixpkgs.mesh_llm_headless.backends]
- [x] [serial] Export `lib.kacheNixRust`, move onix-core's wrapper contract check, and make its missing-cache case independent of the builder's sandbox paths. r[onixpkgs.lib.kache_nix_rust]

## Phase 2: Verification

- [x] [serial] Build `iroh-ssh` and `iroh-ssh-child-status` on x86_64-linux. r[onixpkgs.iroh_ssh.evidence]
- [x] [serial] With the overlay applied to onixos's nixpkgs, compare the cpu, vulkan, and aarch64-linux `mesh-llm-headless` derivations with onixos's own, and show that an unsupported backend fails evaluation. r[onixpkgs.mesh_llm_headless.backends]
- [x] [serial] Build `mesh-llm-headless` and `package-mesh-llm-headless-vulkan` on x86_64-linux and read their provenance. r[onixpkgs.mesh_llm_headless.backends]
- [x] [serial] Build the kache wrapper contract, and show that a wrapper built without the cache-directory requirement fails it. r[onixpkgs.lib.kache_nix_rust]
- [x] [serial] Validate this change with Cairn and run the formatting check. r[onixpkgs.iroh_ssh.evidence] r[onixpkgs.mesh_llm_headless.backends] r[onixpkgs.lib.kache_nix_rust]
