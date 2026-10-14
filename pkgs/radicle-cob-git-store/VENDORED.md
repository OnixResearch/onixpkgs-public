# Vendored onix-radicle-cob-git-store

Source repository: independent local-only `radicle-cob-git-store/`.
Git commit: `a87ca01412fb62e69171925d79d2d6b0a23a7e72`
BLAKE3 of `git archive --format=tar a87ca01412fb62e69171925d79d2d6b0a23a7e72`: `7c2902aee85ebcc923b1e7f9004d6235b550ddf18053194dd6c9286ef05859e6`

The digest identifies the exact Git archive byte stream, not a published source
or a Nix source hash. There is no declared upstream remote. All archive files
are imported into `vendor/onix-radicle-cob-git-store/` without modification.

To update, obtain a reviewed source commit and its independently recorded
archive BLAKE3. Run the importer from onixpkgs with four arguments:
`./pkgs/radicle-cob-git-store/import-source.sh radicle-cob-git-store SOURCE_GIT_CHECKOUT REVISION EXPECTED_ARCHIVE_BLAKE3`.
The importer checks the requested archive and independently replays the
previously recorded commit and archive digest from the supplied checkout.
Before an update it compares every existing vendor path, file byte, mode, and
symlink against that prior snapshot; extra files or any drift stop the import
without replacing the vendor tree or receipt. A matching import is a no-op.
Preserve local edits separately before updating; the importer never discards
unrecorded vendor contents. Review the vendor diff, build the package and run
the formatting check. Consumers must explicitly choose when to adopt a new
onixpkgs revision; this import does not change or validate their policy.
