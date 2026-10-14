#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 4 ]]; then
  printf 'usage: %s PACKAGE_NAME SOURCE_GIT_CHECKOUT REVISION EXPECTED_ARCHIVE_BLAKE3\n' "$0" >&2
  exit 2
fi

case $1 in
radicle-cob-git-store | radicle-cob-git-store-020) ;;
*)
  printf 'unsupported package directory: %s\n' "$1" >&2
  exit 2
  ;;
esac
revision=$3
archive_blake3=$4
if [[ ! $revision =~ ^[0-9a-f]{40}$ || ! $archive_blake3 =~ ^[0-9a-f]{64}$ ]]; then
  printf 'expected a full lowercase Git commit and a lowercase BLAKE3 digest\n' >&2
  exit 2
fi
packages_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
package_dir="$packages_root/$1"
if [[ ! -d $package_dir || -L $package_dir || -L $package_dir/vendor ]]; then
  printf 'target package or its vendor directory is not a real directory: %s\n' "$package_dir" >&2
  exit 1
fi
destination="$package_dir/vendor/onix-radicle-cob-git-store"

[[ $(git -C "$2" cat-file -t "$revision") == commit ]] || {
  printf 'source revision is not a commit: %s\n' "$revision" >&2
  exit 1
}
mkdir -p -- "$package_dir/vendor"
work=$(mktemp -d "$package_dir/.import-source.XXXXXXXX")
receipt="$package_dir/VENDORED.md"
had_existing=false
new_install_started=false
committed=false
cleanup() {
  local status=$? recovered=true
  trap - EXIT
  if [[ $committed == false ]]; then
    if [[ -d $work/previous ]]; then
      if [[ -e $destination || -L $destination ]]; then
        mv -- "$destination" "$work/failed-import" || recovered=false
      fi
      if [[ ! -e $destination && ! -L $destination ]]; then
        mv -- "$work/previous" "$destination" || recovered=false
      else
        recovered=false
      fi
      mv -- "$work/previous-receipt" "$receipt" || recovered=false
    elif [[ $new_install_started == true && $had_existing == false ]]; then
      if [[ -e $destination || -L $destination ]]; then
        mv -- "$destination" "$work/failed-import" || recovered=false
      fi
      if [[ -e $receipt || -L $receipt ]]; then
        mv -- "$receipt" "$work/failed-receipt" || recovered=false
      fi
    fi
  fi
  if [[ $recovered == false || ($committed == false && -d $work/previous) ]]; then
    printf 'import recovery needs attention; preserving %s\n' "$work" >&2
    exit 1
  fi
  rm -rf -- "$work"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
snapshot_matches() {
  local expected=$1 observed=$2 rel prior current prior_mode current_mode

  (cd -- "$expected" && find . -mindepth 1 -printf '%P\0' | LC_ALL=C sort -z) >"$work/prior-paths" || return 1
  (cd -- "$observed" && find . -mindepth 1 -printf '%P\0' | LC_ALL=C sort -z) >"$work/vendor-paths" || return 1
  cmp -s -- "$work/prior-paths" "$work/vendor-paths" || return 1

  while IFS= read -r -d '' rel; do
    prior="$expected/$rel"
    current="$observed/$rel"
    if [[ -L $prior ]]; then
      [[ -L $current ]] && cmp -s -- <(readlink -n -- "$prior") <(readlink -n -- "$current") || return 1
    elif [[ -f $prior ]]; then
      [[ -f $current && ! -L $current ]] && cmp -s -- "$prior" "$current" || return 1
    elif [[ -d $prior ]]; then
      [[ -d $current && ! -L $current ]] || return 1
    else
      return 1
    fi
    prior_mode=$(stat -c %a -- "$prior") || return 1
    current_mode=$(stat -c %a -- "$current") || return 1
    [[ $prior_mode == "$current_mode" ]] || return 1
  done <"$work/prior-paths"
}

git -C "$2" archive --format=tar --output="$work/source.tar" "$revision"
read -r actual_blake3 _ < <(b3sum "$work/source.tar")
if [[ $actual_blake3 != "$archive_blake3" ]]; then
  printf 'source archive BLAKE3 mismatch: expected %s, got %s\n' "$archive_blake3" "$actual_blake3" >&2
  exit 1
fi

mkdir -- "$work/extracted"
tar -xf "$work/source.tar" -C "$work/extracted"
for required in Cargo.toml Cargo.lock src/lib.rs tests/git_store.rs LICENSE-MIT LICENSE-APACHE; do
  [[ -f "$work/extracted/$required" ]] || {
    printf 'source archive lacks %s\n' "$required" >&2
    exit 1
  }
done
if [[ -e $destination || -L $destination ]]; then
  [[ -d $destination && ! -L $destination && -f $receipt && ! -L $receipt ]] || {
    printf 'existing vendor requires a real directory and a regular source receipt\n' >&2
    exit 1
  }

  prior_revision=
  prior_digest_revision=
  prior_blake3=
  commit_pattern="^Git commit: \`([0-9a-f]{40})\`$"
  digest_pattern="^BLAKE3 of \`git archive --format=tar ([0-9a-f]{40})\`: \`([0-9a-f]{64})\`$"
  while IFS= read -r line; do
    if [[ $line == "Git commit: "* ]]; then
      [[ $line =~ $commit_pattern && -z $prior_revision ]] || {
        printf 'invalid or duplicate prior Git commit in %s\n' "$receipt" >&2
        exit 1
      }
      prior_revision=${BASH_REMATCH[1]}
    elif [[ $line == "BLAKE3 of "* ]]; then
      [[ $line =~ $digest_pattern && -z $prior_blake3 ]] || {
        printf 'invalid or duplicate prior archive digest in %s\n' "$receipt" >&2
        exit 1
      }
      prior_digest_revision=${BASH_REMATCH[1]}
      prior_blake3=${BASH_REMATCH[2]}
    fi
  done <"$receipt"
  [[ -n $prior_revision && $prior_revision == "$prior_digest_revision" && -n $prior_blake3 ]] || {
    printf 'missing or inconsistent prior source identity in %s\n' "$receipt" >&2
    exit 1
  }
  [[ $(git -C "$2" cat-file -t "$prior_revision" 2>/dev/null) == commit ]] || {
    printf 'prior source commit is unavailable: %s\n' "$prior_revision" >&2
    exit 1
  }

  git -C "$2" archive --format=tar --output="$work/prior.tar" "$prior_revision"
  read -r actual_prior_blake3 _ < <(b3sum "$work/prior.tar")
  [[ $actual_prior_blake3 == "$prior_blake3" ]] || {
    printf 'prior source archive BLAKE3 mismatch: %s\n' "$prior_revision" >&2
    exit 1
  }
  mkdir -- "$work/prior"
  tar -xf "$work/prior.tar" -C "$work/prior"
  snapshot_matches "$work/prior" "$destination" || {
    printf 'vendor tree differs from recorded prior archive; refusing replacement: %s\n' "$destination" >&2
    exit 1
  }

  if [[ $prior_revision == "$revision" && $prior_blake3 == "$archive_blake3" ]]; then
    printf 'Already imported %s (git archive BLAKE3 %s)\n' "$revision" "$archive_blake3"
    exit 0
  fi
elif [[ -e $receipt || -L $receipt ]]; then
  printf 'source receipt exists without its vendor tree: %s\n' "$receipt" >&2
  exit 1
fi
cat >"$work/VENDORED.md" <<EOF
# Vendored onix-radicle-cob-git-store

Source repository: independent local-only \`radicle-cob-git-store/\`.
Git commit: \`$revision\`
BLAKE3 of \`git archive --format=tar $revision\`: \`$archive_blake3\`

The digest identifies the exact Git archive byte stream, not a published source
or a Nix source hash. There is no declared upstream remote. All archive files
are imported into \`vendor/onix-radicle-cob-git-store/\` without modification.

To update, obtain a reviewed source commit and its independently recorded
archive BLAKE3. Run the importer from onixpkgs with four arguments:
\`./pkgs/radicle-cob-git-store/import-source.sh $1 SOURCE_GIT_CHECKOUT REVISION EXPECTED_ARCHIVE_BLAKE3\`.
The importer checks the requested archive and independently replays the
previously recorded commit and archive digest from the supplied checkout.
Before an update it compares every existing vendor path, file byte, mode, and
symlink against that prior snapshot; extra files or any drift stop the import
without replacing the vendor tree or receipt. A matching import is a no-op.
Preserve local edits separately before updating; the importer never discards
unrecorded vendor contents. Review the vendor diff, build the package and run
the formatting check. Consumers must explicitly choose when to adopt a new
onixpkgs revision; this import does not change or validate their policy.
EOF

if [[ -e $destination || -L $destination ]]; then
  had_existing=true
  cp -p -- "$receipt" "$work/previous-receipt"
  mv -- "$destination" "$work/previous"
  snapshot_matches "$work/prior" "$work/previous" || {
    printf 'vendor tree changed during import; refusing replacement: %s\n' "$destination" >&2
    exit 1
  }
fi
new_install_started=true
mv -- "$work/extracted" "$destination"
mv -- "$work/VENDORED.md" "$receipt"
committed=true
printf 'Imported %s (git archive BLAKE3 %s)\n' "$revision" "$actual_blake3"
