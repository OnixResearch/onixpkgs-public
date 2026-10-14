{
  lib,
  rustPlatform,
  fetchFromGitHub,
  pkg-config,
  copyDesktopItems,
  makeDesktopItem,
  fontconfig,
  freetype,
  libxkbcommon,
  wayland,
  libxcb,
  vulkan-loader,
  libGL,
  git,
}:

rustPlatform.buildRustPackage {
  pname = "agentaps";
  version = "0.2.1-unstable-2026-09-28";

  src = fetchFromGitHub {
    owner = "domenkozar";
    repo = "agentaps";
    rev = "9d526af183dde411397dd690ae20b72be639402f";
    hash = "sha256-fMMu7U2ANKOpOyjolUpf3Dk8QyG3VuomQvli1JyR9ik=";
  };

  cargoHash = "sha256-KnUNs+97EtHuaTxXPKgu8LacSYNGgWUQ3ZvWbbOASdk=";

  nativeBuildInputs = [
    pkg-config
    copyDesktopItems
  ];

  buildInputs = [
    fontconfig
    freetype
    libxkbcommon
    wayland
    libxcb
  ];

  # The git_sync and git_diff tests drive the git CLI in temporary repositories.
  nativeCheckInputs = [ git ];

  desktopItems = [
    (makeDesktopItem {
      name = "agentaps";
      desktopName = "Agentaps";
      comment = "Desktop client for agents that speak the Agent Client Protocol";
      exec = "agentaps";
      icon = "agentaps";
      categories = [ "Development" ];
    })
  ];

  postInstall = ''
    install -Dm644 assets/packaging/icon.png $out/share/icons/hicolor/512x512/apps/agentaps.png
  '';

  # wgpu loads libvulkan and libEGL, and GPUI loads the Wayland client
  # libraries, with dlopen. RUNPATH keeps them out of the environment that
  # spawned agents, git, and ssh inherit.
  postFixup = ''
    patchelf --add-rpath ${
      lib.makeLibraryPath [
        vulkan-loader
        libGL
        wayland
      ]
    } $out/bin/agentaps
  '';

  meta = {
    description = "GPUI desktop client for Agent Client Protocol coding agents";
    homepage = "https://github.com/domenkozar/agentaps";
    license = lib.licenses.asl20;
    mainProgram = "agentaps";
    platforms = lib.platforms.linux;
  };
}
