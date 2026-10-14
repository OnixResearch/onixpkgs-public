use std::{error::Error, str::FromStr};

use nonempty::NonEmpty;
use onix_radicle_cob_git_store::{GitCobStore, GitCobStoreError};
use radicle_cob::{
    change::{self, Storage as _},
    object::Storage as _,
    Create, Entry, ObjectId, TypeName, Update, Version,
};
use radicle_crypto::{signature::Keypair as _, PublicKey, Seed, SigningKey};
use radicle_oid::Oid;
use tempfile::TempDir;

const TYPE: &str = "example.test.note";

struct Fixture {
    _temp: TempDir,
    repository: git2::Repository,
    signer: SigningKey,
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
        drop(tree);
        drop(config);
        let signer = SigningKey::from_seed(Seed::new([7; 32]));
        let namespace = *signer.verifying_key().public_key();
        Ok(Self {
            _temp: temp,
            repository,
            signer,
            namespace,
        })
    }

    fn store(&self) -> GitCobStore<'_> {
        GitCobStore::new(&self.repository)
    }

    fn create(&self, message: &str) -> Result<ObjectId, Box<dyn Error>> {
        let store = self.store();
        let created = radicle_cob::create::<NonEmpty<Entry>, _>(
            &store,
            &self.signer,
            None,
            Vec::new(),
            &self.namespace,
            Create {
                contents: NonEmpty::new(message.as_bytes().to_vec()),
                type_name: TypeName::from_str(TYPE)?,
                message: message.to_string(),
                embeds: Vec::new(),
                version: Version::default(),
            },
        )?;
        Ok(*created.id())
    }
}

fn ref_name(namespace: &PublicKey, type_name: &TypeName, id: &ObjectId) -> String {
    format!("refs/namespaces/{namespace}/refs/cobs/{type_name}/{id}")
}

#[test]
fn signed_cob_roundtrip_with_borrowed_repository_and_exact_update() -> Result<(), Box<dyn Error>> {
    let fixture = Fixture::new()?;
    let store = fixture.store();
    let type_name = TypeName::from_str(TYPE)?;
    let head = fixture.repository.head()?.target().ok_or("missing HEAD")?;
    let id = fixture.create("initial")?;
    assert_eq!(fixture.repository.head()?.target(), Some(head));
    assert_eq!(store.object_ids_bounded(&type_name, 1)?, vec![id]);
    let first = store
        .objects(&type_name, &id)?
        .iter()
        .next()
        .ok_or("missing COB ref")?
        .target
        .id;
    let entry = store.load(first)?;
    assert!(entry.valid_signatures());
    assert_eq!(entry.contents().head, b"initial");
    assert!(radicle_cob::get::<NonEmpty<Entry>, _>(&store, &type_name, &id)?.is_some());

    let writer = GitCobStore::with_expected_ref(&fixture.repository, first);
    let updated = radicle_cob::update::<NonEmpty<Entry>, _>(
        &writer,
        &fixture.signer,
        None,
        Vec::new(),
        &fixture.namespace,
        Update {
            changes: NonEmpty::new(b"updated".to_vec()),
            object_id: id,
            type_name: type_name.clone(),
            message: "update note".to_string(),
            embeds: Vec::new(),
        },
    )?;
    assert_ne!(first, updated.head);
    let refs = store.objects(&type_name, &id)?;
    assert_eq!(
        refs.iter().next().ok_or("missing update ref")?.target.id,
        updated.head
    );
    assert_eq!(store.object_ids_bounded(&type_name, 1)?, vec![id]);
    assert_eq!(fixture.repository.head()?.target(), Some(head));
    Ok(())
}

#[test]
fn stale_exact_head_is_rejected_even_when_operation_ancestry_matches_current(
) -> Result<(), Box<dyn Error>> {
    let fixture = Fixture::new()?;
    let store = fixture.store();
    let type_name = TypeName::from_str(TYPE)?;
    let id = fixture.create("initial")?;
    let first = store
        .objects(&type_name, &id)?
        .iter()
        .next()
        .ok_or("missing COB ref")?
        .target
        .id;
    let writer = GitCobStore::with_expected_ref(&fixture.repository, first);
    let updated = radicle_cob::update::<NonEmpty<Entry>, _>(
        &writer,
        &fixture.signer,
        None,
        Vec::new(),
        &fixture.namespace,
        Update {
            changes: NonEmpty::new(b"second".to_vec()),
            object_id: id,
            type_name: type_name.clone(),
            message: "second".to_string(),
            embeds: Vec::new(),
        },
    )?;
    let third = store.store(
        None,
        Vec::new(),
        &fixture.signer,
        change::Template {
            tips: vec![updated.head],
            type_name: type_name.clone(),
            message: "third".to_string(),
            embeds: Vec::new(),
            contents: NonEmpty::new(b"third".to_vec()),
        },
    )?;
    // The third change directly descends from the current ref, but the caller
    // admitted the *first* ref. Parent-only drift checks would accept it.
    assert!(matches!(
        writer.update(&fixture.namespace, &type_name, &id, &third.id),
        Err(GitCobStoreError::ReferenceDrift { .. })
    ));
    assert_eq!(
        store
            .objects(&type_name, &id)?
            .iter()
            .next()
            .ok_or("missing ref")?
            .target
            .id,
        updated.head,
    );
    Ok(())
}

#[test]
fn bounded_scan_counts_distinct_ids_not_valid_namespace_refs() -> Result<(), Box<dyn Error>> {
    let fixture = Fixture::new()?;
    let store = fixture.store();
    let type_name = TypeName::from_str(TYPE)?;
    assert!(matches!(
        store.object_ids_bounded(&type_name, 0),
        Err(GitCobStoreError::ZeroObjectScanBound)
    ));
    let first = fixture.create("first")?;
    let original_head = store
        .objects(&type_name, &first)?
        .iter()
        .next()
        .ok_or("missing first ref")?
        .target
        .id;
    let second_signer = SigningKey::from_seed(Seed::new([8; 32]));
    let second_namespace = *second_signer.verifying_key().public_key();
    let second_entry = store.store(
        None,
        Vec::new(),
        &second_signer,
        change::Template {
            tips: vec![original_head],
            type_name: type_name.clone(),
            message: "same object other namespace".to_string(),
            embeds: Vec::new(),
            contents: NonEmpty::new(b"other".to_vec()),
        },
    )?;
    fixture.repository.reference(
        &ref_name(&second_namespace, &type_name, &first),
        second_entry.id.into(),
        false,
        "fixture second namespace",
    )?;
    assert_eq!(store.object_ids_bounded(&type_name, 1)?, vec![first]);
    assert_eq!(store.objects(&type_name, &first)?.iter().count(), 2);

    let second = fixture.create("another independent root")?;
    assert_ne!(first, second);
    assert!(matches!(
        store.object_ids_bounded(&type_name, 1),
        Err(GitCobStoreError::ObjectScanBoundExceeded { max_objects: 1 })
    ));
    let ids = store.object_ids_bounded(&type_name, 2)?;
    assert_eq!(ids, vec![first.min(second), first.max(second)]);
    Ok(())
}

#[test]
fn malformed_symbolic_foreign_author_and_tampered_signatures_fail_closed(
) -> Result<(), Box<dyn Error>> {
    let fixture = Fixture::new()?;
    let store = fixture.store();
    let type_name = TypeName::from_str(TYPE)?;
    let id = fixture.create("signed")?;
    let first: git2::Oid = store
        .objects(&type_name, &id)?
        .iter()
        .next()
        .ok_or("missing ref")?
        .target
        .id
        .into();
    let other = SigningKey::from_seed(Seed::new([9; 32]));
    let other_namespace = *other.verifying_key().public_key();
    let foreign_name = ref_name(&other_namespace, &type_name, &id);
    fixture
        .repository
        .reference(&foreign_name, first, false, "forged author")?;
    assert!(matches!(
        store.object_ids_bounded(&type_name, 2),
        Err(GitCobStoreError::InvalidCobChange { .. })
    ));
    fixture.repository.find_reference(&foreign_name)?.delete()?;

    let malformed = format!("refs/namespaces/not-a-key/refs/cobs/{type_name}/{id}");
    fixture
        .repository
        .reference(&malformed, first, false, "invalid namespace")?;
    assert!(matches!(
        store.object_ids_bounded(&type_name, 2),
        Err(GitCobStoreError::InvalidCobReference { .. })
    ));
    fixture.repository.find_reference(&malformed)?.delete()?;

    fixture.repository.reference_symbolic(
        &foreign_name,
        &ref_name(&fixture.namespace, &type_name, &id),
        false,
        "symbolic",
    )?;
    assert!(matches!(
        store.object_ids_bounded(&type_name, 2),
        Err(GitCobStoreError::InvalidCobReference { .. })
    ));
    fixture.repository.find_reference(&foreign_name)?.delete()?;

    let commit = fixture.repository.find_commit(first)?;
    let original_tree = commit.tree()?;
    let mut builder = fixture.repository.treebuilder(Some(&original_tree))?;
    let marker = fixture.repository.blob(b"unsigned addition")?;
    builder.insert("extra.txt", marker, 0o100644)?;
    let different_tree = builder.write()?;
    let odb = fixture.repository.odb()?;
    let raw = odb.read(first)?;
    let raw_commit = std::str::from_utf8(raw.data())?;
    let tampered = raw_commit.replacen(
        &format!("tree {}", original_tree.id()),
        &format!("tree {different_tree}"),
        1,
    );
    assert_ne!(tampered, raw_commit);
    let tampered_oid = odb.write(git2::ObjectType::Commit, tampered.as_bytes())?;
    fixture.repository.reference(
        &ref_name(&fixture.namespace, &type_name, &id),
        tampered_oid,
        true,
        "invalid signature",
    )?;
    assert!(!store.load(Oid::from(tampered_oid))?.valid_signatures());
    assert!(matches!(
        store.object_ids_bounded(&type_name, 2),
        Err(GitCobStoreError::InvalidCobChange { .. })
    ));
    assert!(matches!(
        store.objects(&type_name, &id),
        Err(GitCobStoreError::InvalidCobChange { .. })
    ));
    Ok(())
}
