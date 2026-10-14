# Onix packages laid over nixpkgs.
#
# Every directory under ./pkgs becomes the attribute of the same name, built
# with `final.callPackage`. `callArgs` and `callers` hold the wiring that
# callPackage cannot infer from the package set.
{ inputs }:
final: prev:
let
  inherit (prev) lib;
  inherit (final.stdenv.hostPlatform) system;

  packageDirectories = lib.filterAttrs (_: type: type == "directory") (builtins.readDir ./pkgs);

  # Arguments that do not come from the package set under the same name.
  callArgs = {
    herdr = {
      herdr = final.herdr-unwrapped;
      collie = final.collie-herdr;
      wrapperLib = inputs.wrappers.lib;
    };
    horizon.horizon-src = inputs.horizon;
  };

  # Packages built by a scoped callPackage instead of the top-level one.
  callers.claude-md = final.python3Packages.callPackage;

  callPackageDirectory =
    name: _type: (callers.${name} or final.callPackage) (./pkgs + "/${name}") (callArgs.${name} or { });
in
lib.mapAttrs callPackageDirectory packageDirectories
// {
  # Upstream Herdr from llm-agents.nix. pkgs/herdr wraps it with the static
  # plugin registry; a later overlay can replace this base binary.
  herdr-unwrapped = inputs.llm-agents.packages.${system}.herdr;
}
