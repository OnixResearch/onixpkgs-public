# Formatters and linters for everything under pkgs/, matching the gates these
# sources had in onix-core.
{ pkgs, ... }:
{
  projectRootFile = "flake.nix";

  programs = {
    # deadnix removes unused code, statix catches anti-patterns, nixfmt formats.
    deadnix = {
      enable = true;
      priority = 1;
    };
    statix = {
      enable = true;
      priority = 2;
    };
    nixfmt = {
      enable = true;
      priority = 3;
    };

    shellcheck.enable = true;
    shfmt.enable = true;

    ruff = {
      check = true;
      format = true;
    };

    rustfmt.enable = true;

    prettier = {
      enable = true;
      package = pkgs.prettier;
      includes = [
        "*.cjs"
        "*.css"
        "*.html"
        "*.js"
        "*.json"
        "*.json5"
        "*.jsx"
        "*.mjs"
        "*.scss"
        "*.ts"
        "*.tsx"
        "*.yaml"
        "*.yml"
      ];
    };
  };

  settings = {
    global.excludes = [
      "*.lock"
      "*.md"
      "*.toml"
      ".envrc"
      "package-lock.json"

      # Vendored sources mirror their origin repositories byte for byte; the
      # origin toolchain owns their formatting.
      "pkgs/herdr/vendor/**"
      "pkgs/radicle-cob-git-store/vendor/**"
      "pkgs/radicle-cob-git-store-020/vendor/**"
      "pkgs/collie-herdr/dist/**"
    ];

    formatter.shellcheck.options = [
      "--external-sources"
      "--source-path=SCRIPTDIR"
    ];
  };
}
