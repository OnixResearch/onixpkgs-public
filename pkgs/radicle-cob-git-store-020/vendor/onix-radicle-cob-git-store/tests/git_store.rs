use std::{error::Error, path::Path, str::FromStr};

use nonempty::{nonempty, NonEmpty};
use onix_radicle_cob_git_store::{
    load_signer, GitCobStore, GitCobStoreError, LoadSignerError, RefLayout,
};
use radicle_cob::{change, object, Create, Entry, ObjectId, TypeName, Update, Version};
use radicle_crypto::{signature::Keypair as _, ssh::Keystore, KeyPair, PublicKey, Seed};
use radicle_oid::Oid;
use tempfile::TempDir;

const TYPE: &str = "example.test.note";

struct Fixture {
    temp: TempDir,
    namespace: PublicKey,
}

impl Fixture {
    fn new() -> Result<Self, Box<dyn Error>> {
        let temp = tempfile::tempdir()?;
        let repository = git2::Repository::init(temp.path().join("repository"))?;
        let mut config = repository.config()?.open_level(git2::ConfigLevel::Local)?;
        config.set_str("user.name", "COB test")?;
        config.set_str("user.email", "cob@example.invalid")?;
        let tree_id = repository.treebuilder(None)?.write()?;
        let tree = repository.find_tree(tree_id)?;
        let signature = git2::Signature::now("COB test", "cob@example.invalid")?;
        repository.commit(Some("HEAD"), &signature, &signature, "base", &tree, &[])?;
        let keystore = temp.path().join("keystore");
        let namespace = Keystore::new(&keystore).store(
            KeyPair::from_seed(Seed::new([7; 32])),
            "COB test",
            None,
        )?;
        Ok(Self { temp, namespace })
    }

    fn repository_path(&self) -> std::path::PathBuf {
        self.temp.path().join("repository")
    }

    fn keystore_path(&self) -> std::path::PathBuf {
        self.temp.path().join("keystore")
    }

    fn store(&self) -> Result<GitCobStore, GitCobStoreError> {
        GitCobStore::open(&self.repository_path())
    }
    fn legacy_store(&self) -> Result<GitCobStore, GitCobStoreError> {
        GitCobStore::open_with_layout(&self.repository_path(), RefLayout::RadLegacy)
    }

    fn create(
        &self,
        store: &GitCobStore,
        type_name: &TypeName,
    ) -> Result<ObjectId, Box<dyn Error>> {
        let signer = load_signer(&self.keystore_path())?;
        let created = radicle_cob::create::<NonEmpty<Entry>, _, _>(
            store,
            &signer,
            None,
            vec![],
            &self.namespace,
            Create {
                contents: nonempty!(b"initial".to_vec()),
                type_name: type_name.clone(),
                message: "create test note".into(),
                embeds: vec![],
                version: Version::default(),
            },
        )?;
        Ok(created.id)
    }
}

fn ref_name(namespace: &PublicKey, type_name: &TypeName, id: &ObjectId) -> String {
    format!("refs/namespaces/{namespace}/refs/cobs/{type_name}/{id}")
}

#[test]
fn signed_dummy_roundtrip_and_ref_transitions() -> Result<(), Box<dyn Error>> {
    let fixture = Fixture::new()?;
    let store = fixture.store()?;
    let type_name = TypeName::from_str(TYPE)?;
    store.validate_local_commit_identity()?;
    let head = store.head_oid()?;
    let id = fixture.create(&store, &type_name)?;
    assert_eq!(store.head_oid()?, head);
    assert_eq!(store.object_ids(&type_name)?, vec![id]);
    assert_eq!(
        <GitCobStore as object::Storage>::types(&store, &type_name)?.len(),
        1
    );
    assert_eq!(
        <GitCobStore as object::Storage>::objects(&store, &type_name, &id)?
            .iter()
            .count(),
        1
    );
    let first = store
        .namespace_ref_target(&fixture.namespace, &type_name, &id)?
        .ok_or("missing ref")?;
    let change = <GitCobStore as change::Storage>::load(&store, first)?;
    assert!(change.valid_signatures());
    assert_eq!(change.contents().head, b"initial");
    let readback = radicle_cob::get::<NonEmpty<Entry>, _>(&store, &type_name, &id)?;
    assert!(readback.is_some());

    let signer = load_signer(&fixture.keystore_path())?;
    let updated = radicle_cob::update::<NonEmpty<Entry>, _, _>(
        &store,
        &signer,
        None,
        vec![],
        &fixture.namespace,
        Update {
            changes: nonempty!(b"updated".to_vec()),
            object_id: id,
            type_name: type_name.clone(),
            message: "update test note".into(),
            embeds: vec![],
        },
    )?;
    let second = store
        .namespace_ref_target(&fixture.namespace, &type_name, &id)?
        .ok_or("missing ref")?;
    assert_eq!(second, updated.head);
    assert_ne!(second, first);
    assert_eq!(store.object_ids(&type_name)?, vec![id]);
    assert!(matches!(
        store.restore_namespace_ref(&fixture.namespace, &type_name, &id, first, None),
        Err(GitCobStoreError::ReferenceDrift { .. })
    ));
    assert_eq!(
        store.namespace_ref_target(&fixture.namespace, &type_name, &id)?,
        Some(second)
    );
    store.restore_namespace_ref(&fixture.namespace, &type_name, &id, second, Some(first))?;
    assert_eq!(
        store.namespace_ref_target(&fixture.namespace, &type_name, &id)?,
        Some(first)
    );
    store.restore_namespace_ref(&fixture.namespace, &type_name, &id, first, None)?;
    assert_eq!(
        store.namespace_ref_target(&fixture.namespace, &type_name, &id)?,
        None
    );
    assert!(store.object_ids(&type_name)?.is_empty());
    Ok(())
}

#[test]
fn legacy_refs_survive_reopen_and_update_without_namespaced_migration() -> Result<(), Box<dyn Error>>
{
    let fixture = Fixture::new()?;
    let store = fixture.legacy_store()?;
    let type_name = TypeName::from_str(TYPE)?;
    let id = fixture.create(&store, &type_name)?;
    let legacy_name = store.ref_name(&fixture.namespace, &type_name, &id)?;
    assert!(legacy_name.starts_with("refs/rad/"));
    let first = store
        .namespace_ref_target(&fixture.namespace, &type_name, &id)?
        .ok_or("missing legacy ref")?;
    assert!(fixture.store()?.object_ids(&type_name)?.is_empty());
    let reopened = fixture.legacy_store()?;
    assert_eq!(reopened.object_ids(&type_name)?, vec![id]);
    assert!(radicle_cob::get::<NonEmpty<Entry>, _>(&reopened, &type_name, &id)?.is_some());
    let signer = load_signer(&fixture.keystore_path())?;
    let updated = radicle_cob::update::<NonEmpty<Entry>, _, _>(
        &reopened,
        &signer,
        None,
        vec![],
        &fixture.namespace,
        Update {
            changes: nonempty!(b"later".to_vec()),
            object_id: id,
            type_name: type_name.clone(),
            message: "update legacy note".into(),
            embeds: vec![],
        },
    )?;
    assert_ne!(first, updated.head);
    assert_eq!(
        reopened.namespace_ref_target(&fixture.namespace, &type_name, &id)?,
        Some(updated.head)
    );
    assert!(reopened.raw().find_reference(&legacy_name).is_ok());
    assert!(fixture.store()?.object_ids(&type_name)?.is_empty());
    Ok(())
}

#[test]
fn legacy_refs_reject_malformed_names_and_tampered_signed_changes() -> Result<(), Box<dyn Error>> {
    let fixture = Fixture::new()?;
    let store = fixture.legacy_store()?;
    let type_name = TypeName::from_str(TYPE)?;
    let id = fixture.create(&store, &type_name)?;
    let first = store
        .namespace_ref_target(&fixture.namespace, &type_name, &id)?
        .ok_or("missing legacy ref")?;
    let other = fixture.temp.path().join("other-keystore");
    let other_key =
        Keystore::new(&other).store(KeyPair::from_seed(Seed::new([8; 32])), "COB test", None)?;
    let wrong_actor = store.ref_name(&other_key, &type_name, &id)?;
    store
        .raw()
        .reference(&wrong_actor, first.into(), false, "test")?;
    assert!(matches!(
        store.object_ids(&type_name),
        Err(GitCobStoreError::InvalidCobChange { .. })
    ));
    store.raw().find_reference(&wrong_actor)?.delete()?;
    let bad_name = format!("refs/rad/not-a-key/cobs/{type_name}/{id}");
    store
        .raw()
        .reference(&bad_name, first.into(), false, "test")?;
    assert!(matches!(
        store.object_ids(&type_name),
        Err(GitCobStoreError::InvalidCobReference { .. })
    ));
    store.raw().find_reference(&bad_name)?.delete()?;
    let original = store.raw().find_commit(first.into())?;
    let mut tree = store.raw().treebuilder(Some(&original.tree()?))?;
    tree.insert("extra.txt", store.raw().blob(b"tampered")?, 0o100644)?;
    let odb = store.raw().odb()?;
    let raw = odb.read(first.into())?;
    let signed_commit = std::str::from_utf8(raw.data())?;
    let tampered = signed_commit.replacen(
        &format!("tree {}", original.tree_id()),
        &format!("tree {}", tree.write()?),
        1,
    );
    let invalid = odb.write(git2::ObjectType::Commit, tampered.as_bytes())?;
    store.raw().reference(
        &store.ref_name(&fixture.namespace, &type_name, &id)?,
        invalid,
        true,
        "test",
    )?;
    assert!(matches!(
        store.object_ids(&type_name),
        Err(GitCobStoreError::InvalidCobChange { .. })
    ));
    assert!(matches!(
        <GitCobStore as object::Storage>::objects(&store, &type_name, &id),
        Err(GitCobStoreError::InvalidCobChange { .. })
    ));
    Ok(())
}

#[test]
fn stale_update_and_bad_references_are_rejected() -> Result<(), Box<dyn Error>> {
    let fixture = Fixture::new()?;
    let store = fixture.store()?;
    let type_name = TypeName::from_str(TYPE)?;
    let id = fixture.create(&store, &type_name)?;
    let first = store
        .namespace_ref_target(&fixture.namespace, &type_name, &id)?
        .ok_or("missing ref")?;
    let other = fixture.temp.path().join("other-keystore");
    let other_key =
        Keystore::new(&other).store(KeyPair::from_seed(Seed::new([8; 32])), "COB test", None)?;
    assert!(matches!(
        <GitCobStore as object::Storage>::update(
            &store,
            &fixture.namespace,
            &type_name,
            &id,
            &store.head_oid()?
        ),
        Err(GitCobStoreError::ReferenceDrift { .. })
    ));
    let bad_author_ref = ref_name(&other_key, &type_name, &id);
    store
        .raw()
        .reference(&bad_author_ref, first.into(), false, "test")?;
    assert!(matches!(
        store.object_ids(&type_name),
        Err(GitCobStoreError::InvalidCobChange { .. })
    ));
    store.raw().find_reference(&bad_author_ref)?.delete()?;

    let malformed = format!("refs/namespaces/not-a-key/refs/cobs/{type_name}/{id}");
    store
        .raw()
        .reference(&malformed, first.into(), false, "test")?;
    assert!(store.object_ids(&type_name).is_err());
    store.raw().find_reference(&malformed)?.delete()?;

    let symbolic = format!("refs/namespaces/{other_key}/refs/cobs/{type_name}/{id}");
    store.raw().reference_symbolic(
        &symbolic,
        &ref_name(&fixture.namespace, &type_name, &id),
        false,
        "test",
    )?;
    assert!(matches!(
        store.object_ids(&type_name),
        Err(GitCobStoreError::InvalidCobReference { .. })
    ));
    store.raw().find_reference(&symbolic)?.delete()?;

    // Keep the original signature but change the signed tree to another valid COB tree.
    let commit = store.raw().find_commit(first.into())?;
    let original_tree = commit.tree()?;
    let mut builder = store.raw().treebuilder(Some(&original_tree))?;
    let marker = store.raw().blob(b"unsigned addition")?;
    builder.insert("extra.txt", marker, 0o100644)?;
    let different_tree = builder.write()?;
    let odb = store.raw().odb()?;
    let raw = odb.read(first.into())?;
    let raw_commit = std::str::from_utf8(raw.data())?;
    let tampered = raw_commit.replacen(
        &format!("tree {}", original_tree.id()),
        &format!("tree {different_tree}"),
        1,
    );
    assert_ne!(tampered, raw_commit);
    let tampered_oid = odb.write(git2::ObjectType::Commit, tampered.as_bytes())?;
    store.raw().reference(
        &ref_name(&fixture.namespace, &type_name, &id),
        tampered_oid,
        true,
        "test",
    )?;
    let loaded = <GitCobStore as change::Storage>::load(&store, Oid::from(tampered_oid))?;
    assert!(!loaded.valid_signatures());
    assert!(matches!(
        store.object_ids(&type_name),
        Err(GitCobStoreError::InvalidCobChange { .. })
    ));
    Ok(())
}

#[test]
fn explicit_signer_and_repository_paths_reject_symlinks() -> Result<(), Box<dyn Error>> {
    let fixture = Fixture::new()?;
    let signer = load_signer(&fixture.keystore_path())?;
    assert_eq!(signer.verifying_key(), fixture.namespace);
    let store = fixture.store()?;
    let mut local = store.raw().config()?.open_level(git2::ConfigLevel::Local)?;
    local.remove("user.email")?;
    assert!(matches!(
        store.validate_local_commit_identity(),
        Err(GitCobStoreError::MissingLocalCommitIdentity {
            field: "user.email"
        })
    ));
    local.set_str("user.email", "cob@example.invalid")?;
    store.validate_local_commit_identity()?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::symlink;
        let linked_keys = fixture.temp.path().join("keys-link");
        symlink(fixture.keystore_path(), &linked_keys)?;
        assert!(matches!(
            load_signer(&linked_keys),
            Err(LoadSignerError::SymlinkKeystore { .. })
        ));
        let linked_repo = fixture.temp.path().join("repository-link");
        symlink(fixture.repository_path(), &linked_repo)?;
        assert!(matches!(
            GitCobStore::open(&linked_repo),
            Err(GitCobStoreError::SymlinkRepository { .. })
        ));
    }
    assert!(matches!(
        load_signer(Path::new("/no/such/keystore")),
        Err(LoadSignerError::KeystoreIo(_))
    ));
    Ok(())
}
