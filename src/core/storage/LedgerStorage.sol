// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Limits} from "../../interfaces/Limits.sol";

/// @title LedgerStorage — the kernel's ERC-7201 namespaces (design §4.1–§4.4)
/// @notice Every canonical row of a Realm. One namespaced struct per table, declared here so the
///         upgrade validator sees them in the implementation's inheritance chain. Fields are typed
///         with byte-aligned widths so the compiler packs each word exactly; the committed storage
///         layout snapshot is the source of truth and `Layout` is generated from it. Widths: 48-bit
///         ordinals and counters, 32-bit revisions, 48-bit block numbers in the transition word,
///         64-bit deadlines and chain ids (design §4.1).
/// @dev Roots: keccak256(abi.encode(uint256(keccak256(id)) - 1)) & ~bytes32(uint256(0xff)); each is
///      asserted against the formula in test/unit/StorageRoots.t.sol.
abstract contract LedgerStorage {
    // ---------------------------------------------------------------------------------------------
    // efs.ledger.v2.realm — identity, component pins, cached commitments, limits, transition, flags
    // ---------------------------------------------------------------------------------------------

    /// @custom:storage-location erc7201:efs.ledger.v2.realm
    struct RealmStorage {
        bytes32 realmId; // keccak(DOM_REALM, realmOrigin, genesisExecutionProfileId)
        bytes32 realmOrigin; // keccak(DOM_REALM_ORIGIN, genesisChainId, coreAddress, realmSalt)
        bytes32 realmSalt; // genesis input, recorded in the deployment manifest
        // control word
        uint64 genesisChainId;
        uint64 acceptedChainId;
        uint32 revision;
        uint8 frozen; // 0 or 1; set only by freeze
        // authority word
        address controller;
        uint16 executionProfileId;
        uint16 capabilities;
        uint16 genesisExecutionProfileId;
        // pins
        address registry;
        address index;
        uint32 indexGeneration;
        bytes32 executionSet; // cached at activation
        bytes32 layoutId; // := set.layoutId at every activation
        bytes32 domainSeparator; // EIP-712, chain-bound; recomputed on a chain-acceptance change
        bytes32 indexObligations; // keccak(index, indexCodehash, indexManifestHash)
        address steward; // zero at S1; freeze posture B seam
        bytes32 limitsProfileId; // keccak(abi.encode(limits))
        Limits limits;
        // transition word
        uint32 transitionTarget;
        uint48 transitionDeadline;
        uint32 transitionLastTarget;
        uint48 transitionCooldownUntil;
        address readerDirectory; // genesis constant; advisory discovery only
        bytes32 noticePrincipal; // the only principal allowed to author realm-notice/1 {kind: successor}
    }

    bytes32 internal constant REALM_ROOT =
        0xd1d82880908abd64876dc5abdb3d21a6118aa67f635eb0d222f8ae0c6374eb00;

    function _realm() internal pure returns (RealmStorage storage $) {
        assembly ("memory-safe") {
            $.slot := REALM_ROOT
        }
    }

    // ---------------------------------------------------------------------------------------------
    // efs.ledger.v2.counters — one packed word
    // ---------------------------------------------------------------------------------------------

    /// @custom:storage-location erc7201:efs.ledger.v2.counters
    struct CountersStorage {
        uint48 admissions;
        uint48 records;
        uint48 bindings;
        uint48 publications;
    }

    bytes32 internal constant COUNTERS_ROOT =
        0x63eac95c642a8299ccca6df135b3f61f7cfd222a0712997d1cd9fcdcfa9e5500;

    function _counters() internal pure returns (CountersStorage storage $) {
        assembly ("memory-safe") {
            $.slot := COUNTERS_ROOT
        }
    }

    // ---------------------------------------------------------------------------------------------
    // efs.ledger.v2.records — record cells and inline body words
    // ---------------------------------------------------------------------------------------------

    /// Two slots per fresh record plus body words. `carrierKind`: 0 INLINE_WORDS; 1 CODE_BLOB reserved.
    struct RecordCell {
        bytes32 typeId;
        uint48 firstAdmission;
        uint32 length; // byte length; words beyond it are never written
        uint48 occurrences;
        uint8 carrierKind;
    }

    /// @custom:storage-location erc7201:efs.ledger.v2.records
    struct RecordsStorage {
        mapping(bytes32 recordId => RecordCell) cells;
        mapping(bytes32 recordId => mapping(uint256 index => bytes32)) bodyWords;
    }

    bytes32 internal constant RECORDS_ROOT =
        0x7524f85143c406ba14d3b73dea3182e972b4d4504f1b783a38f0858767c1de00;

    function _records() internal pure returns (RecordsStorage storage $) {
        assembly ("memory-safe") {
            $.slot := RECORDS_ROOT
        }
    }

    // ---------------------------------------------------------------------------------------------
    // efs.ledger.v2.subjects
    // ---------------------------------------------------------------------------------------------

    /// `creatorKind`: the principalKind of the creating principal (1 KEY 2 CONTRACT).
    struct SubjectCell {
        uint48 createAdmission;
        uint8 creatorKind;
    }

    /// @custom:storage-location erc7201:efs.ledger.v2.subjects
    struct SubjectsStorage {
        mapping(bytes32 subjectId => SubjectCell) cells;
    }

    bytes32 internal constant SUBJECTS_ROOT =
        0xe593fc8637d8cc4bf73cbb933a15ce289f597399c2da2882777592cc3ee4c000;

    function _subjects() internal pure returns (SubjectsStorage storage $) {
        assembly ("memory-safe") {
            $.slot := SUBJECTS_ROOT
        }
    }

    // ---------------------------------------------------------------------------------------------
    // efs.ledger.v2.admissions — one row per leaf (two slots; UNBIND/RELEASE write the meta word only)
    // ---------------------------------------------------------------------------------------------

    /// `a`: PUBLISH/REUSE = recordId; BIND = target; CREATE = salt; WITHDRAW = bytes32(targetAdmission).
    struct AdmissionRow {
        uint8 kind; // 1 PUBLISH 2 REUSE 3 BIND 4 UNBIND 5 CREATE 6 WITHDRAW 7 RELEASE; 8/9 reserved
        uint8 leaf;
        uint48 publication;
        uint48 bindingOrdinal;
        uint48 expectedRevision;
        uint48 prevAdmission;
        uint8 withdrawn; // 0 or 1
        uint16 policyRow;
        uint16 roleRow;
        uint8 targetKind; // BIND rows: 1 RECORD 2 SUBJECT, so the decoder rebuilds oldTarget without shadow heads
        bytes32 a;
    }

    /// @custom:storage-location erc7201:efs.ledger.v2.admissions
    struct AdmissionsStorage {
        mapping(uint256 ordinal => AdmissionRow) rows;
    }

    bytes32 internal constant ADMISSIONS_ROOT =
        0x33042cebcd07e2f265085d626def780948525aefc12f3aa3822ae3531c63eb00;

    function _admissions() internal pure returns (AdmissionsStorage storage $) {
        assembly ("memory-safe") {
            $.slot := ADMISSIONS_ROOT
        }
    }

    // ---------------------------------------------------------------------------------------------
    // efs.ledger.v2.publications — sparse evidence cells and the retry map
    // ---------------------------------------------------------------------------------------------

    /// Sparse: a native publication writes w0–w4; signed lanes add w5–w10. `flags`: b0 imported,
    /// b1 guarded, b2 externalEvidence, b3 executionBound, b4 acceptanceBound, b5 witnessInState.
    struct EvidenceCell {
        // w0
        address author;
        uint8 proofKind; // 1 NATIVE 2 SECP256K1_EIP712 3 ERC1271 4 P256_WEBAUTHN (reserved)
        uint8 principalKind; // 1 KEY 2 CONTRACT
        uint8 v;
        uint8 leafCount;
        uint48 firstAdmission;
        uint8 flags;
        // w1
        uint48 nonce;
        uint64 deadline; // unix seconds; 0 = none; full width
        uint48 basisBlock;
        uint32 revision;
        uint16 verifierProfile;
        // w2..w9
        bytes32 principalId;
        bytes32 intentDigest; // every lane; plan-intrinsic; the retry key
        bytes32 actionsHash;
        bytes32 acceptanceProfile; // signed lanes only
        bytes32 indexObligations; // signed lanes only
        bytes32 readSetHash; // only when guarded
        bytes32 witness0; // secp256k1 r | ERC-1271 evidenceHash
        bytes32 witness1; // secp256k1 s | ERC-1271 store u160@0 | sigLength u16@160
        // w10
        address submitter; // signed lanes: msg.sender of executeSigned
        // w11..w12 reserved (KEL)
        bytes32 authorityId;
        uint64 authEpoch;
    }

    /// @custom:storage-location erc7201:efs.ledger.v2.publications
    struct PublicationsStorage {
        mapping(uint256 publication => EvidenceCell) evidence;
        mapping(bytes32 principalId => mapping(uint256 nonce => uint48)) publicationAt;
    }

    bytes32 internal constant PUBLICATIONS_ROOT =
        0xe9165e74d7cf63baf9a84b176011c878a390e3e9f989a60de35575a350940a00;

    function _publications() internal pure returns (PublicationsStorage storage $) {
        assembly ("memory-safe") {
            $.slot := PUBLICATIONS_ROOT
        }
    }

    // ---------------------------------------------------------------------------------------------
    // efs.ledger.v2.bindings — heads, binding ordinals, write-once position cells
    // ---------------------------------------------------------------------------------------------

    /// The target word is KEPT on MASK and RELEASE; the canonical target is 0 unless state == BOUND.
    struct HeadRow {
        uint8 state; // 0 UNSET 1 BOUND 2 MASKED 3 RELEASED
        uint48 revision;
        uint48 admission;
        uint8 targetKind; // 0 NONE 1 RECORD 2 SUBJECT
        uint48 prevAdmission;
        uint48 bindingOrdinal;
        uint40 notAfter; // reserved zero; the "stale not dead" seam
        bytes32 target;
    }

    /// Write-once, shared by all authors; role == 0 is a zero write, not a slot.
    struct PositionCell {
        bytes32 purpose;
        bytes32 subject;
        bytes32 role;
    }

    /// @custom:storage-location erc7201:efs.ledger.v2.bindings
    struct BindingsStorage {
        mapping(bytes32 bindingKey => HeadRow) heads;
        mapping(uint256 bindingOrdinal => bytes32) bindingPosition;
        mapping(bytes32 positionKey => PositionCell) positions;
    }

    bytes32 internal constant BINDINGS_ROOT =
        0xceda1ceb7d6e35dde16546393af20354114f252f7fbb4c227d63f743c35ffb00;

    function _bindings() internal pure returns (BindingsStorage storage $) {
        assembly ("memory-safe") {
            $.slot := BINDINGS_ROOT
        }
    }

    // ---------------------------------------------------------------------------------------------
    // efs.ledger.v2.principals
    // ---------------------------------------------------------------------------------------------

    struct PrincipalRow {
        uint48 nonce;
        uint48 viewMutationVersion; // increments with the nonce when the publication contains a bind kind
    }

    /// @custom:storage-location erc7201:efs.ledger.v2.principals
    struct PrincipalsStorage {
        mapping(bytes32 principalId => PrincipalRow) rows;
    }

    bytes32 internal constant PRINCIPALS_ROOT =
        0xf6114a07ac14eb57f9dac3ac5f41fd2824feddb467129b9fa50d96bc2daac900;

    function _principals() internal pure returns (PrincipalsStorage storage $) {
        assembly ("memory-safe") {
            $.slot := PRINCIPALS_ROOT
        }
    }

    // ---------------------------------------------------------------------------------------------
    // efs.ledger.v2.revisions — append-only, write-once, one row per activation
    // ---------------------------------------------------------------------------------------------

    /// `flags`: b0 frozenTerminal, b1 sameCodeReactivation, b2 chainAcceptanceChange, b3 controllerMigrated,
    /// b4 ownerChanged, b5 indexChanged, b6 layoutChanged, b7 limitsChanged, b8 migrationRan.
    struct RevisionRow {
        uint48 activationBlock;
        uint48 admissionHigh;
        uint48 publicationHigh;
        uint40 activationTimestamp;
        uint16 flags;
        uint16 executionProfileId;
        uint16 capabilities;
        bytes32 executionSet;
        address ledgerImpl;
        uint64 acceptedChainId;
        bytes32 ledgerImplCodehash;
        address registryImpl;
        bytes32 registryImplCodehash;
        address index;
        uint32 indexGeneration;
        bytes32 indexCodehash;
        bytes32 indexManifestHash;
        address ingress; // the activated implementation's INGRESS immutable
        bytes32 ingressCodehash;
        address applyDelegate; // the activated implementation's APPLY immutable
        bytes32 applyCodehash;
        address controller;
        bytes32 controllerCodehash;
        address controllerOwner;
        address steward;
        bytes32 layoutId;
        bytes32 verifierProfilesRoot;
        bytes32 migrationHash;
        bytes32 dependencyRoot;
        bytes32 limitsProfileId;
        Limits limits;
        bytes32 noticePrincipal;
    }

    /// @custom:storage-location erc7201:efs.ledger.v2.revisions
    struct RevisionsStorage {
        mapping(uint256 revision => RevisionRow) rows;
    }

    bytes32 internal constant REVISIONS_ROOT =
        0xd9645fc105a27a63ec9effce4033ff09babd0e322d92c50976c833cd02e4eb00;

    function _revisions() internal pure returns (RevisionsStorage storage $) {
        assembly ("memory-safe") {
            $.slot := REVISIONS_ROOT
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Reserved namespaces: never written before the stage that defines them (design §4.1)
    // ---------------------------------------------------------------------------------------------

    /// efs.ledger.v2.source — SourceEvidence (S4 import lane).
    bytes32 internal constant SOURCE_ROOT =
        0x2fca977fd3a2c6b167fb728d5b0bcfec6fb20471b834ea01ad3f693a92a9ca00;
    /// efs.ledger.v2.staging — stage-then-commit (action kinds 8/9, capability b9).
    bytes32 internal constant STAGING_ROOT =
        0x5dd7299b00a7c05d3490b804591aa32f13000f9f1e77b236afb15ef1dcd26900;

    // ---------------------------------------------------------------------------------------------
    // efs.ledger.v2.lock — the transient publication lock (one word; EIP-1153)
    //   phase u8@0 | stagedPublication u48@8 | admissionFrontier u48@56 | mutationsSnapshot u48@104
    // ---------------------------------------------------------------------------------------------

    bytes32 internal constant LOCK_SLOT =
        0x6c6eb23cf3b383a5fb365ecd153e56a97a2ae1f01e555420253212131c40d200;

    function _lockWord() internal view returns (uint256 word) {
        assembly ("memory-safe") {
            word := tload(LOCK_SLOT)
        }
    }

    function _setLockWord(uint256 word) internal {
        assembly ("memory-safe") {
            tstore(LOCK_SLOT, word)
        }
    }

    function _packLock(
        uint8 phase,
        uint48 stagedPublication,
        uint48 admissionFrontier,
        uint48 mutationsSnapshot
    ) internal pure returns (uint256) {
        return uint256(phase) | (uint256(stagedPublication) << 8)
            | (uint256(admissionFrontier) << 56) | (uint256(mutationsSnapshot) << 104);
    }

    // forge-lint: disable-start(unsafe-typecast)
    function _unpackLock(uint256 word)
        internal
        pure
        returns (
            uint8 phase,
            uint48 stagedPublication,
            uint48 admissionFrontier,
            uint48 mutationsSnapshot
        )
    {
        phase = uint8(word);
        stagedPublication = uint48(word >> 8);
        admissionFrontier = uint48(word >> 56);
        mutationsSnapshot = uint48(word >> 104);
    }
    // forge-lint: disable-end(unsafe-typecast)
}
