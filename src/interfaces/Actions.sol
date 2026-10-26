// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

// @title Actions — the write-side types of the EFS v2 consumer closure (design §5.1)
// @notice File-level declarations so every interface and library shares one definition. The
//         `Action` tuple is the nine-field shape the kernel admits; its per-kind zero-shape law is
//         enforced by the kernel (`E_SHAPE`), never by the encoder.

// Exact Type id (design §9.1). A distinct value type so a Type id is never passed as a key.
type TypeId is bytes32;
/// Per-principal scope key: keccak(DOM_SCOPE, principalId, purpose, subject) (design §5.11).
type ScopeKey is bytes32;
/// Posting-list key from `Keys.posting` (design §5.8); never a coverage scope.
type PostingKey is bytes32;
/// Index family id: keccak("efs2/family/<name>/1") (design §10.2).
type FamilyId is bytes32;

/// One admission leaf. `bodyHashOrRecordId` is the body hash for PUBLISH and the record id for
/// REUSE/WITHDRAW-less kinds; `target` is the bound target for BIND, zero otherwise; `salt` is
/// nonzero only for CREATE; `expectedRevision` is the CAS value for bind kinds.
struct Action {
    uint8 kind;
    bytes32 typeId;
    bytes32 bodyHashOrRecordId;
    bytes32 purpose;
    bytes32 subject;
    bytes32 role;
    bytes32 target;
    uint64 expectedRevision;
    bytes32 salt;
}

/// Native-lane context (design §5.1). `deadline` 0 = none (unix seconds). A zero expectation is
/// unbound; the SDK and `EfsNative` bind both expectations by default (design Q22).
struct Native {
    uint64 nonce;
    uint64 deadline;
    bytes32 expectedExecutionSet;
    bytes32 expectedAcceptanceProfile;
}

/// Signed-lane intent (design §5.1, §7). `author` is 0 or the recovered key for verifier profile 1
/// and the ERC-1271 wallet (required, bound to `principalId`) for profile 2. `authorityId` and
/// `authEpoch` are zero-enforced until capability b8.
struct Intent {
    bytes32 realmId;
    bytes32 realmOrigin;
    bytes32 executionSet;
    bytes32 principalId;
    address author;
    uint64 nonce;
    uint64 deadline;
    bytes32 acceptanceProfile;
    bytes32 indexObligations;
    bytes32 readSetHash;
    uint16 verifierProfile;
    bytes32 authorityId;
    uint64 authEpoch;
}

/// The guard a lane may carry (design §5.1): n principals × m positions, `expectedHeads` position-major
/// (n·m head snapshot hashes). Decoded only by `LedgerIngress`; n ≤ limits.maxReadSetPrincipals,
/// m ≤ limits.maxReadSetPositions.
struct ReadSet {
    bytes32[] principals;
    bytes32[] positions;
    bytes32[] expectedHeads;
}

/// A binding coordinate (design §5.7): the position preimage without the principal.
struct Coordinate {
    bytes32 purpose;
    bytes32 subject;
    bytes32 role;
}

/// Action kinds (design §4.3). 8 STAGE and 9 COMMIT are reserved behind capability b9; 10..15 reserved.
library ActionKind {
    uint8 internal constant PUBLISH = 1;
    uint8 internal constant REUSE = 2;
    uint8 internal constant BIND = 3;
    uint8 internal constant UNBIND = 4;
    uint8 internal constant CREATE = 5;
    uint8 internal constant WITHDRAW = 6;
    uint8 internal constant RELEASE = 7;
    uint8 internal constant STAGE_RESERVED = 8;
    uint8 internal constant COMMIT_RESERVED = 9;
}

/// Realm capability bits (design §4.2). A clear bit means the corresponding input is refused with a
/// typed error even if the build could serve it.
library Capability {
    uint16 internal constant NATIVE_GUARD = 1 << 0;
    uint16 internal constant SIGNED_SECP256K1 = 1 << 1;
    uint16 internal constant ERC1271 = 1 << 2;
    uint16 internal constant P256_WEBAUTHN = 1 << 3;
    uint16 internal constant STATEFUL_RULES = 1 << 4;
    uint16 internal constant IMPORT = 1 << 5;
    uint16 internal constant CODE_BLOB_BODIES = 1 << 6;
    uint16 internal constant ROUTED_CONSENT = 1 << 7;
    uint16 internal constant KEL_AUTHORITY = 1 << 8;
    uint16 internal constant STAGED_PUBLICATION = 1 << 9;
}

/// The three closure purposes (design §12.1): a file's HEAD, a directory's FOLDER entries, TAG (reserved to S3).
library Purpose {
    bytes32 internal constant HEAD = keccak256("efs2/purpose/head/1");
    bytes32 internal constant FOLDER = keccak256("efs2/purpose/folder/1");
    bytes32 internal constant TAG = keccak256("efs2/purpose/tag/1");
}
