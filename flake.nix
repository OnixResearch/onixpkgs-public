{
  description = "Onix packages as an overlay over nixpkgs";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    # Upstream Herdr binary wrapped by pkgs/herdr.
    llm-agents = {
      url = "github:numtide/llm-agents.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Wrapper library used by pkgs/herdr.
    wrappers = {
      url = "github:brittonr/wrappers";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Source of pkgs/horizon. Its bundled fonts are Git LFS objects, which a
    # GitHub tarball leaves as pointers, so fetch through git with LFS.
    horizon = {
      url = "git+https://github.com/peters/horizon?lfs=1";
      flake = false;
    };

    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { self, nixpkgs, ... }@inputs:
    let
      inherit (nixpkgs) lib;

      # The pinned nixpkgs no longer evaluates for x86_64-darwin.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = lib.genAttrs systems;

      pkgsFor =
        system:
        import nixpkgs {
          inherit system;
          overlays = [ self.overlays.default ];
          config = { };
        };

      # overlay.nix turns each of these directories into the attribute of the same name.
      packageNames = builtins.attrNames (
        lib.filterAttrs (_: type: type == "directory") (builtins.readDir ./pkgs)
      );

      linux = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      x86_64Linux = [ "x86_64-linux" ];

      # Systems that export each package. An unlisted package is exported on
      # every system its meta.platforms allows.
      exportSystems = {
        arxiv-corpus = linux;
        bookshelf = linux;
        branchfs = linux;
        celld = linux;
        collie-herdr = linux;
        deepseek-v4-dspark-draft = linux;
        herdr = linux;
        horizon = linux;
        iroh-ssh = linux;
        laya = linux;
        laya-cpp = linux;
        lemonade-server = linux;
        # ROCm builds for gfx1151; nixpkgs ships ROCm for x86_64-linux only.
        llamacpp-rocm-dspark = x86_64Linux;
        llamacpp-rocm-qwen4exp = x86_64Linux;
        llamacpp-rocm-rpc = x86_64Linux;
        mesh-llm = linux;
        mesh-llm-headless = linux;
        mesh-research = linux;
        open-notebook = x86_64Linux;
        openbubbles = x86_64Linux;
        opendeck = x86_64Linux;
        ptyzzz = linux;
        radicle-cob-git-store-020 = linux;
        radicle-cob-git-store = linux;
        radicle-ci-runner = linux;
        rbw-pinentry = linux;
        sone = x86_64Linux;
        ssh-clipboard = linux;
        underclass-mesh-gateway = linux;
      };

      exported =
        pkgs: name:
        builtins.elem pkgs.stdenv.hostPlatform.system (exportSystems.${name} or systems)
        && lib.meta.availableOn pkgs.stdenv.hostPlatform pkgs.${name};

      collieChecks = pkgs: {
        collie-managed-controller = import ./pkgs/collie-herdr/tests.nix {
          inherit pkgs lib;
          collie = pkgs.collie-herdr;
        };
        collie-remote-sessions = pkgs.runCommand "collie-remote-sessions" { } ''
          export HOME="$TMPDIR/home"
          mkdir -p "$HOME"
          ${pkgs.bun}/bin/bun test ${pkgs.collie-herdr}/bridge/remote-sessions.test.ts
          touch "$out"
        '';
      };

      treefmtFor =
        system: inputs.treefmt-nix.lib.evalModule nixpkgs.legacyPackages.${system} ./treefmt.nix;
    in
    {
      overlays.default = import ./overlay.nix { inherit inputs; };

      # Library functions shared by consumers; call with { lib, pkgs, kachePackage }.
      lib.kacheNixRust = import ./lib/kache-nix-rust.nix;

      packages = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        lib.genAttrs (builtins.filter (exported pkgs) packageNames) (name: pkgs.${name})
      );

      checks = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          packages = self.packages.${system};
        in
        lib.mapAttrs' (name: lib.nameValuePair "package-${name}") packages
        // lib.optionalAttrs (packages ? collie-herdr) (collieChecks pkgs)
        // lib.optionalAttrs (packages ? iroh-ssh) {
          # `iroh-ssh connect` must exit with the child ssh's exact status.
          iroh-ssh-child-status = import ./pkgs/iroh-ssh/child-status-check.nix {
            inherit pkgs;
            irohSsh = pkgs.iroh-ssh;
          };
        }
        // lib.optionalAttrs (packages ? mesh-llm-headless) {
          # The vulkan backend is an override of the exported cpu build.
          package-mesh-llm-headless-vulkan = pkgs.mesh-llm-headless.override { backend = "vulkan"; };
        }
        // lib.optionalAttrs (system == "x86_64-linux") {
          kache-nix-rust-wrapper-contract = import ./lib/kache-nix-rust-contract.nix {
            inherit pkgs lib;
            kacheNixRust = self.lib.kacheNixRust;
          };
        }
        // {
          formatting = (treefmtFor system).config.build.check self;
        }
      );

      formatter = forAllSystems (system: (treefmtFor system).config.build.wrapper);
    };
}
