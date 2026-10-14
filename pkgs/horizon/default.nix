{
  lib,
  rustPlatform,
  pkg-config,
  cmake,
  makeWrapper,
  openssl,
  libxkbcommon,
  wayland,
  vulkan-loader,
  libGL,
  libxcb,
  libX11,
  libxcursor,
  libxrandr,
  libxi,
  horizon-src,
}:

rustPlatform.buildRustPackage {
  pname = "horizon";
  version = "0.1.0";

  src = horizon-src;

  cargoHash = "sha256-w+j923HIslP5RFDPjc4GtcoIsT7cS53EG1S1rsm1K74=";

  nativeBuildInputs = [
    pkg-config
    cmake
    makeWrapper
  ];

  buildInputs = [
    openssl
    libxkbcommon
    wayland
    vulkan-loader
    libGL
    libxcb
    libX11
    libxcursor
    libxrandr
    libxi
  ];

  postFixup = ''
    wrapProgram $out/bin/horizon \
      --prefix LD_LIBRARY_PATH : ${
        lib.makeLibraryPath [
          vulkan-loader
          libGL
          libxkbcommon
          wayland
        ]
      }
  '';

  # GPU rendering and PTY tests don't work in the sandbox
  doCheck = false;

  meta = {
    description = "GPU-accelerated spatial terminal observatory on an infinite canvas";
    homepage = "https://github.com/peters/horizon";
    license = lib.licenses.mit;
    mainProgram = "horizon";
    platforms = lib.platforms.linux;
  };
}
