# Positive and negative contract for lib/kache-nix-rust.nix, driven by a fake kache.
{
  pkgs,
  lib,
  kacheNixRust ? import ./kache-nix-rust.nix,
}:
let
  expectedCacheDir = "/var/cache/kache-nix";
  pilotKeySalt = "changebot-crane-pilot-v1";
  missingCacheDiagnostic = "cache directory is not writable";

  fakeKache = pkgs.writeShellApplication {
    name = "kache";
    text = ''
      if [ -n "''${KACHE_NIX_TRACE:-}" ]; then
        {
          printf 'fake_kache_invoked=true\n'
          printf 'argv=%s\n' "$*"
          printf 'KACHE_KEY_SALT=%s\n' "''${KACHE_KEY_SALT:-}"
          printf 'KACHE_CACHE_DIR=%s\n' "''${KACHE_CACHE_DIR:-}"
        } >> "$KACHE_NIX_TRACE"
      fi
      exec "$@"
    '';
  };

  kacheLib = kacheNixRust {
    inherit lib pkgs;
    kachePackage = fakeKache;
  };

  cargoWrapper = kacheLib.mkCargoRustcWrapper {
    name = "checked-kache-cargo-rustc-wrapper";
    cacheDir = expectedCacheDir;
    keySalt = pilotKeySalt;
  };

  wrappedRust = kacheLib.mkWrappedRustPackage {
    name = "checked-kache-rust";
    rust = pkgs.rustc;
    cacheDir = expectedCacheDir;
    keySalt = pilotKeySalt;
  };
in
pkgs.runCommand "kache-nix-rust-wrapper-contract" { } ''
  set -eu

  wrapper=${lib.getExe cargoWrapper}
  rustc=${pkgs.rustc}/bin/rustc
  cache_dir="$PWD/cache"
  trace="$PWD/kache.trace"

  KACHE_NIX_DISABLED=1 KACHE_NIX_TRACE="$PWD/disabled.trace" "$wrapper" "$rustc" -vV > "$PWD/disabled-rustc-version.txt"
  if [ -s "$PWD/disabled.trace" ]; then
    echo "negative: disabled mode should not invoke kache" >&2
    exit 1
  fi

  # Builders that use kache expose the default cache directory in the sandbox,
  # so point the wrapper at a directory that cannot exist.
  missing_cache_dir="$PWD/missing-cache"
  if KACHE_NIX_CACHE_DIR="$missing_cache_dir" "$wrapper" "$rustc" -vV > "$PWD/missing-cache.stdout" 2> "$PWD/missing-cache.stderr"; then
    echo "negative: missing cache directory unexpectedly succeeded" >&2
    exit 1
  fi
  if ! ${pkgs.gnugrep}/bin/grep -Fq ${lib.escapeShellArg missingCacheDiagnostic} "$PWD/missing-cache.stderr"; then
    echo "negative: missing cache directory did not produce the expected diagnostic" >&2
    cat "$PWD/missing-cache.stderr" >&2
    exit 1
  fi
  if ! ${pkgs.gnugrep}/bin/grep -Fq "cache_dir=$missing_cache_dir" "$PWD/missing-cache.stderr"; then
    echo "negative: missing cache directory diagnostic did not name the directory" >&2
    cat "$PWD/missing-cache.stderr" >&2
    exit 1
  fi

  mkdir -p "$cache_dir"
  KACHE_NIX_CACHE_DIR="$cache_dir" KACHE_NIX_TRACE="$trace" "$wrapper" "$rustc" -vV > "$PWD/wrapped-rustc-version.txt"
  if ! ${pkgs.gnugrep}/bin/grep -Fq 'fake_kache_invoked=true' "$trace"; then
    echo "positive: wrapper did not invoke kache" >&2
    cat "$trace" >&2
    exit 1
  fi
  if ! ${pkgs.gnugrep}/bin/grep -Fq "argv=$rustc -vV" "$trace"; then
    echo "positive: wrapper did not pass the real rustc path and original argv to kache" >&2
    cat "$trace" >&2
    exit 1
  fi
  if ! ${pkgs.gnugrep}/bin/grep -Fq 'operator=${pilotKeySalt}' "$trace"; then
    echo "positive: wrapper did not include the operator key salt" >&2
    cat "$trace" >&2
    exit 1
  fi
  if ! ${pkgs.gnugrep}/bin/grep -Fq "KACHE_CACHE_DIR=$cache_dir" "$trace"; then
    echo "positive: wrapper did not export the runtime cache directory" >&2
    cat "$trace" >&2
    exit 1
  fi

  wrapped_rust_trace="$PWD/wrapped-rust.trace"
  KACHE_NIX_CACHE_DIR="$cache_dir" KACHE_NIX_TRACE="$wrapped_rust_trace" ${wrappedRust}/bin/rustc -vV > "$PWD/wrapped-package-rustc-version.txt"
  if ! ${pkgs.gnugrep}/bin/grep -Fq 'fake_kache_invoked=true' "$wrapped_rust_trace"; then
    echo "positive: wrapped rust package did not invoke kache" >&2
    cat "$wrapped_rust_trace" >&2
    exit 1
  fi
  if [ ! -x ${wrappedRust}/bin/rustdoc ]; then
    echo "positive: wrapped rust package must preserve rustdoc compatibility" >&2
    exit 1
  fi

  touch "$out"
''
