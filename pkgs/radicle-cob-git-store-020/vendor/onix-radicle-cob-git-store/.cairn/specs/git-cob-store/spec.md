# Local signed COB Git storage

## Ownership

The repository owns local Git ref enumeration and update for signed Radicle COB changes, explicit keystore signer loading, and a direct implementation of Radicle COB storage traits. Cairn is the current consumer; it retains reducers, policy, locks, actor authorization, and high-level CRUD. Maintenance owner: OnixResearch Radicle COB Git store maintainers.

## Behavior

- An explicitly supplied Git repository path or keystore path that is itself a symlink is rejected.
- A local commit identity requires nonempty repository-local `user.name` and `user.email`.
- COB refs are addressed under `refs/namespaces/<signer>/refs/cobs/<type>/<object>`. Discovery validates ref structure, manifest type, signed author matching the namespace, and the change signature before returning objects.
- An existing namespace ref updates only to a change with its current target among the new commit's parents and uses Git's expected-old-target matching. Rollback to a previous target uses expected-old-target matching; rollback deletion requires the expected target observed at lookup.
- This mechanism neither authenticates an actor's authority nor proves concurrent rollback deletion atomic under independent writers. Callers own policy, coordination, and claims.

## Verification

Focused tests cover signed dummy COB creation/update/readback; malformed refs, signatures, and namespaces; stale-ref rejection; local identity; and keystore symlink rejection. Reproduce with `cargo test` from this independent repository.
