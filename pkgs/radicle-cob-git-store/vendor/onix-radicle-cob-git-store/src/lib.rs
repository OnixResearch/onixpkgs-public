#![deny(clippy::unwrap_used)]

use std::{
    collections::{BTreeMap, BTreeSet},
    str::FromStr,
};

use git2::Repository;
use radicle_cob::{
    change,
    object::{self, Reference},
    ObjectId, Store, TypeName,
};
use radicle_crypto::PublicKey;
use radicle_git_ref_format::{RefStr, RefString};
use radicle_oid::Oid;
use thiserror::Error;

const COB_REF_PREFIX: &str = "refs/namespaces";
const COB_REF_MIDDLE: &str = "refs/cobs";
const REF_LOG_MESSAGE: &str = "Update collaborative object";

#[derive(Debug, Error)]
pub enum GitCobStoreError {
    #[error("failed to access Git COB storage: {0}")]
    Git(#[from] git2::Error),
    #[error("invalid COB reference format: {0}")]
    RefFormat(#[from] radicle_git_ref_format::Error),
    #[error("invalid COB reference target: {0}")]
    Reference(#[from] radicle_cob::object::storage::convert::Error),
    #[error("COB reference is not UTF-8")]
    NonUtf8Reference,
    #[error("reference does not identify a COB: {reference}")]
    InvalidCobReference { reference: String },
    #[error("reference contains an invalid signed COB change: {reference}: {reason}")]
    InvalidCobChange { reference: String, reason: String },
    #[error("COB reference changed outside the expected operation: {reference}")]
    ReferenceDrift { reference: String },
    #[error("COB object scan bound must be positive")]
    ZeroObjectScanBound,
    #[error("COB object discovery exceeded its bound of {max_objects} distinct objects")]
    ObjectScanBoundExceeded { max_objects: usize },
}

/// Product-neutral local Git storage for signed, namespaced Radicle COB refs.
///
/// The repository is borrowed for the entire operation: consumers retain its
/// configuration and lifetime, including any ephemeral commit identity.
pub struct GitCobStore<'a> {
    raw: &'a Repository,
    expected_ref_target: Option<Oid>,
}

impl std::fmt::Debug for GitCobStore<'_> {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("GitCobStore")
            .field("expected_ref_target", &self.expected_ref_target)
            .finish_non_exhaustive()
    }
}

impl<'a> GitCobStore<'a> {
    pub const fn new(raw: &'a Repository) -> Self {
        Self {
            raw,
            expected_ref_target: None,
        }
    }

    /// Bind the exact target admitted before an update. The Git ref write is CAS.
    pub const fn with_expected_ref(raw: &'a Repository, expected: Oid) -> Self {
        Self {
            raw,
            expected_ref_target: Some(expected),
        }
    }

    pub const fn raw(&self) -> &'a Repository {
        self.raw
    }

    pub fn ref_name(
        &self,
        namespace: &PublicKey,
        type_name: &TypeName,
        object_id: &ObjectId,
    ) -> Result<String, GitCobStoreError> {
        Ok(RefString::try_from(format!(
            "{COB_REF_PREFIX}/{namespace}/{COB_REF_MIDDLE}/{type_name}/{object_id}"
        ))?
        .to_string())
    }

    fn parse_ref(
        &self,
        name: &str,
        expected_type: &TypeName,
    ) -> Result<ObjectId, GitCobStoreError> {
        let invalid = || GitCobStoreError::InvalidCobReference {
            reference: name.to_string(),
        };
        let suffix = name
            .strip_prefix(COB_REF_PREFIX)
            .and_then(|rest| rest.strip_prefix('/'))
            .ok_or_else(invalid)?;
        let (namespace, rest) = suffix.split_once('/').ok_or_else(invalid)?;
        PublicKey::from_str(namespace).map_err(|_| invalid())?;
        let rest = rest
            .strip_prefix(COB_REF_MIDDLE)
            .and_then(|rest| rest.strip_prefix('/'))
            .ok_or_else(invalid)?;
        let (type_part, object_part) = rest.split_once('/').ok_or_else(invalid)?;
        let observed_type = TypeName::from_str(type_part).map_err(|_| invalid())?;
        let object_id = ObjectId::from_str(object_part).map_err(|_| invalid())?;
        if observed_type != *expected_type || RefStr::try_from_str(name).is_err() {
            return Err(invalid());
        }
        Ok(object_id)
    }

    /// Stream refs and stop as soon as the number of distinct object IDs exceeds
    /// `max_objects`. Different namespaces for one ID consume only one slot.
    pub fn object_ids_bounded(
        &self,
        type_name: &TypeName,
        max_objects: usize,
    ) -> Result<Vec<ObjectId>, GitCobStoreError> {
        if max_objects == 0 {
            return Err(GitCobStoreError::ZeroObjectScanBound);
        }
        let glob = format!("{COB_REF_PREFIX}/*/{COB_REF_MIDDLE}/{type_name}/*");
        let mut ids = BTreeSet::new();
        for reference in self.raw.references_glob(&glob)? {
            let reference = reference?;
            let name = reference
                .name()
                .map_err(|_| GitCobStoreError::NonUtf8Reference)?;
            let id = self.parse_ref(name, type_name)?;
            if !ids.contains(&id) && ids.len() == max_objects {
                return Err(GitCobStoreError::ObjectScanBoundExceeded { max_objects });
            }
            self.validate_reference_change(&reference, type_name)?;
            ids.insert(id);
        }
        Ok(ids.into_iter().collect())
    }

    fn validate_reference_change(
        &self,
        reference: &git2::Reference<'_>,
        type_name: &TypeName,
    ) -> Result<(), GitCobStoreError> {
        let name = reference
            .name()
            .map_err(|_| GitCobStoreError::NonUtf8Reference)?
            .to_string();
        let target = reference
            .target()
            .ok_or_else(|| GitCobStoreError::InvalidCobReference {
                reference: name.clone(),
            })?;
        let entry =
            <Repository as change::Storage>::load(self.raw, target.into()).map_err(|error| {
                GitCobStoreError::InvalidCobChange {
                    reference: name.clone(),
                    reason: error.to_string(),
                }
            })?;
        let manifest = <Repository as change::Storage>::manifest_of(self.raw, &target.into())
            .map_err(|error| GitCobStoreError::InvalidCobChange {
                reference: name.clone(),
                reason: error.to_string(),
            })?;
        let namespace = name
            .split('/')
            .nth(2)
            .and_then(|component| PublicKey::from_str(component).ok())
            .ok_or_else(|| GitCobStoreError::InvalidCobReference {
                reference: name.clone(),
            })?;
        if !entry.valid_signatures() {
            return Err(GitCobStoreError::InvalidCobChange {
                reference: name,
                reason: "invalid signed COB change signature".to_string(),
            });
        }
        if manifest.type_name != *type_name || entry.author() != &namespace {
            return Err(GitCobStoreError::InvalidCobChange {
                reference: name,
                reason: "manifest type or signed author does not match the reference namespace"
                    .to_string(),
            });
        }
        Ok(())
    }
}

impl Store for GitCobStore<'_> {}

impl change::Storage for GitCobStore<'_> {
    type StoreError = <Repository as change::Storage>::StoreError;
    type LoadError = <Repository as change::Storage>::LoadError;
    type ObjectId = Oid;
    type Parent = Oid;
    type PublicKey = PublicKey;
    type Signature = <Repository as change::Storage>::Signature;

    fn store(
        &self,
        resource: Option<Self::Parent>,
        related: Vec<Self::Parent>,
        signer: &impl radicle_crypto::Signer,
        template: change::Template<Self::ObjectId>,
    ) -> Result<change::Entry, Self::StoreError> {
        self.raw.store(resource, related, signer, template)
    }

    fn load(&self, id: Self::ObjectId) -> Result<change::Entry, Self::LoadError> {
        self.raw.load(id)
    }

    fn parents_of(&self, id: &Oid) -> Result<Vec<Oid>, Self::LoadError> {
        self.raw.parents_of(id)
    }

    fn manifest_of(&self, id: &Oid) -> Result<radicle_cob::Manifest, Self::LoadError> {
        self.raw.manifest_of(id)
    }
}

impl object::Storage for GitCobStore<'_> {
    type ObjectsError = GitCobStoreError;
    type TypesError = GitCobStoreError;
    type UpdateError = GitCobStoreError;
    type RemoveError = GitCobStoreError;
    type Namespace = PublicKey;

    fn objects(
        &self,
        type_name: &TypeName,
        object_id: &ObjectId,
    ) -> Result<object::Objects, Self::ObjectsError> {
        let glob = format!("{COB_REF_PREFIX}/*/{COB_REF_MIDDLE}/{type_name}/{object_id}");
        let mut references = Vec::new();
        for reference in self.raw.references_glob(&glob)? {
            let reference = reference?;
            let name = reference
                .name()
                .map_err(|_| GitCobStoreError::NonUtf8Reference)?;
            if self.parse_ref(name, type_name)? != *object_id {
                return Err(GitCobStoreError::InvalidCobReference {
                    reference: name.to_string(),
                });
            }
            self.validate_reference_change(&reference, type_name)?;
            references.push(Reference::try_from(reference)?);
        }
        Ok(references.into())
    }

    fn types(
        &self,
        type_name: &TypeName,
    ) -> Result<BTreeMap<ObjectId, object::Objects>, Self::TypesError> {
        let glob = format!("{COB_REF_PREFIX}/*/{COB_REF_MIDDLE}/{type_name}/*");
        let mut objects: BTreeMap<ObjectId, object::Objects> = BTreeMap::new();
        for reference in self.raw.references_glob(&glob)? {
            let reference = reference?;
            let name = reference
                .name()
                .map_err(|_| GitCobStoreError::NonUtf8Reference)?;
            let object_id = self.parse_ref(name, type_name)?;
            self.validate_reference_change(&reference, type_name)?;
            let converted = Reference::try_from(reference)?;
            match objects.entry(object_id) {
                std::collections::btree_map::Entry::Occupied(mut entry) => {
                    entry.get_mut().push(converted)
                }
                std::collections::btree_map::Entry::Vacant(entry) => {
                    entry.insert(object::Objects::new(converted));
                }
            }
        }
        Ok(objects)
    }

    fn update(
        &self,
        namespace: &Self::Namespace,
        type_name: &TypeName,
        object_id: &ObjectId,
        entry: &change::EntryId,
    ) -> Result<(), Self::UpdateError> {
        let name = self.ref_name(namespace, type_name, object_id)?;
        let new_target: git2::Oid = (*entry).into();
        match (self.expected_ref_target, self.raw.find_reference(&name)) {
            (Some(expected), Ok(reference)) => {
                if reference.target() != Some(expected.into()) {
                    return Err(GitCobStoreError::ReferenceDrift { reference: name });
                }
                let operation = self.raw.find_commit(new_target)?;
                if !operation
                    .parent_ids()
                    .any(|parent| parent == expected.into())
                {
                    return Err(GitCobStoreError::ReferenceDrift { reference: name });
                }
                self.raw.reference_matching(
                    &name,
                    new_target,
                    true,
                    expected.into(),
                    REF_LOG_MESSAGE,
                )?;
            }
            (Some(_), Err(error)) if error.code() == git2::ErrorCode::NotFound => {
                return Err(GitCobStoreError::ReferenceDrift { reference: name });
            }
            (None, Ok(_)) => {
                return Err(GitCobStoreError::ReferenceDrift { reference: name });
            }
            (None, Err(error)) if error.code() == git2::ErrorCode::NotFound => {
                self.raw
                    .reference(&name, new_target, false, REF_LOG_MESSAGE)?;
            }
            (_, Err(error)) => return Err(error.into()),
        }
        Ok(())
    }

    fn remove(
        &self,
        namespace: &Self::Namespace,
        type_name: &TypeName,
        object_id: &ObjectId,
    ) -> Result<(), Self::RemoveError> {
        let name = self.ref_name(namespace, type_name, object_id)?;
        self.raw.find_reference(&name)?.delete()?;
        Ok(())
    }
}
