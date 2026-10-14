{
  lib,
  rustPlatform,
  pkg-config,
  openssl,
  crateSource ? lib.cleanSource ./vendor/onix-radicle-cob-git-store,
  crateLock ? ./vendor/onix-radicle-cob-git-store/Cargo.lock,
  crateVersion ? "0.2.0",
}:

rustPlatform.buildRustPackage {
  pname = "onix-radicle-cob-git-store";
  version = crateVersion;

  src = crateSource;
  cargoLock.lockFile = crateLock;

  nativeBuildInputs = [ pkg-config ];
  buildInputs = [ openssl ];

  cargoBuildFlags = [ "--lib" ];
  cargoTestFlags = [ "--all-targets" ];

  # This crate has no executable: consumers compile its source against their
  # own Cargo workspace rather than reuse a toolchain-specific rlib.
  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp Cargo.toml Cargo.lock LICENSE-MIT LICENSE-APACHE "$out/"
    cp -R src "$out/"
    runHook postInstall
  '';

  meta = {
    description = "Signed Radicle COB local Git storage Cargo crate source";
    license = with lib.licenses; [
      mit
      asl20
    ];
    platforms = lib.platforms.linux;
  };
}
