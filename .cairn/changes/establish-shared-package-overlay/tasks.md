## Phase 1: Implementation

- [x] [serial] Copy onix-core's portable packages, their patches, and their package tests from the migration base. r[onixpkgs.overlay.packages] r[onixpkgs.boundary]
- [x] [serial] Add `overlay.nix` with directory discovery, input wiring, and `herdr-unwrapped`. r[onixpkgs.overlay.packages] r[onixpkgs.overlay.inputs]
- [x] [serial] Add `packages`, `checks`, and `formatter` outputs, and lock the inputs to onix-core's revisions at the migration base. r[onixpkgs.exports] r[onixpkgs.checks]

## Phase 2: Verification

- [x] [serial] Evaluate `packages` and `checks` on every exported system. r[onixpkgs.exports] r[onixpkgs.checks]
- [x] [serial] Compare every migrated package's derivation with onix-core's derivation at the migration base. r[onixpkgs.overlay.packages] r[onixpkgs.overlay.inputs]
- [x] [serial] Build the formatting check, the Collie checks, and a sample of packages, and show that a replaced dependency reaches the Herdr wrapper. r[onixpkgs.checks] r[onixpkgs.overlay.packages]
- [x] [serial] Validate this change with Cairn. r[onixpkgs.overlay.packages]

## Phase 3: Follow-up

- [x] [serial] Repair `horizon`: fetch its Git LFS font assets and refresh `cargoHash`, or pin a buildable revision. r[onixpkgs.checks]
