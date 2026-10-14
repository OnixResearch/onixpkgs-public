## ADDED Requirements

### Requirement: Directory packages in the overlay

r[onixpkgs.overlay.packages] `overlays.default` MUST expose every directory `pkgs/<name>` as the attribute `<name>`, built by callPackage from the package set the overlay is applied to. A package that depends on another onixpkgs package MUST receive it from that package set, so a later overlay that replaces the dependency changes every dependent package.

#### Scenario: Consumer package set

- GIVEN a consumer that applies `overlays.default` to its nixpkgs
- WHEN it evaluates `pkgs.<name>` for a directory `pkgs/<name>`
- THEN the package MUST be built with that consumer's `callPackage` and nixpkgs configuration

#### Scenario: Replaced dependency

- GIVEN a later overlay that replaces `collie-herdr` or `herdr-unwrapped`
- WHEN the consumer evaluates `pkgs.herdr`
- THEN the Herdr wrapper MUST use the replacement

### Requirement: Flake inputs stay in the overlay wiring

r[onixpkgs.overlay.inputs] A package function MUST NOT read flake inputs itself. Arguments that come from flake inputs MUST be passed in `overlay.nix`. Every flake input that a package uses MUST be declared by onixpkgs, so a consumer can make it follow the consumer's own lock.

#### Scenario: Consumer follows inputs

- GIVEN a consumer that sets `nixpkgs`, `llm-agents`, and `wrappers` of onixpkgs to follow its own inputs
- WHEN it evaluates `pkgs.herdr`
- THEN the wrapped base and the wrapper library MUST come from the consumer's locked revisions

### Requirement: Exported packages evaluate

r[onixpkgs.exports] `packages.<system>` MUST contain a package only on a system where the package's `exportSystems` entry and its `meta.platforms` both admit the system. Every exported package MUST evaluate on its system. Systems that the pinned nixpkgs cannot evaluate MUST NOT be exported.

#### Scenario: Linux-only package on Darwin

- GIVEN a package limited to Linux
- WHEN `packages.aarch64-darwin` is evaluated
- THEN the package MUST be absent and evaluation MUST succeed

#### Scenario: Evaluation of every export

- GIVEN any exported system
- WHEN every derivation in `packages.<system>` is instantiated
- THEN instantiation MUST succeed

### Requirement: Checks cover exports and package tests

r[onixpkgs.checks] `checks.<system>` MUST build every package exported for that system. It MUST also run the package-level tests kept beside those packages and check that every Nix file is formatted with nixfmt.

#### Scenario: Collie tests

- GIVEN a system that exports `collie-herdr`
- WHEN its checks run
- THEN the managed-controller and remote-session tests MUST run against that system's `collie-herdr`

#### Scenario: Unformatted Nix file

- GIVEN a Nix file that nixfmt would change
- WHEN the `formatting` check runs
- THEN the check MUST fail

### Requirement: Consumer data stays with consumers

r[onixpkgs.boundary] onixpkgs MUST NOT hold packages that embed consumer machine inventories, secrets, or runtime state, and MUST NOT hold service modules. A consumer that needs such a package MUST keep it in its own repository.

#### Scenario: Inventory-bound package

- GIVEN a package whose build reads a consumer's machine inventory
- WHEN deciding where it lives
- THEN it MUST stay in the consumer repository
