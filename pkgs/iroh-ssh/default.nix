{
  lib,
  rustPlatform,
  fetchFromGitHub,
}:

rustPlatform.buildRustPackage rec {
  pname = "iroh-ssh";
  version = "0.2.12";

  src = fetchFromGitHub {
    owner = "rustonbsd";
    repo = "iroh-ssh";
    rev = version;
    hash = "sha256-zt5Adq3U+sp0w5+X1xf/vEgQsxQ9G5tZL4+SOCHo5ws=";
  };

  cargoHash = "sha256-NFiOsBYJ1nJCH8E7F7WuL2Xj0/djdnvrJ/0S+9SItpo=";

  # `iroh-ssh connect` prints IROH_SSH_CONNECTION_TYPE=direct|relay|mixed|none
  # to stderr, so a session records how the peer was reached.
  patches = [ ./iroh-ssh-connection-type-evidence.patch ];

  cargoTestFlags = [ "--all-targets" ];

  meta = {
    description = "SSH to any machine without an IP address";
    homepage = "https://github.com/rustonbsd/iroh-ssh";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
    mainProgram = "iroh-ssh";
  };
}
