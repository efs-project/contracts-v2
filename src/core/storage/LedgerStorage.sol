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
    // efs.ledger.realm — identity, component pins, cached commitments, limits, transition, flags
    // ---------------------------------------------------------------------------------------------

    /// @custom:storage-location erc7201:efs.ledger.realm
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
        0x282113142e9b03b41f73f795c71a689c6393962a323022d5ac5450977a98b200;

    function _realm() internal pure returns (RealmStorage storage $) {
        assembly ("memory-safe") {
            $.slot := REALM_ROOT
        }
    }

    // ---------------------------------------------------------------------------------------------
    // efs.ledger.counters — one packed word
    // ---------------------------------------------------------------------------------------------

    /// @custom:storage-location erc7201:efs.ledger.counters
    struct CountersStorage {
        uint48 admissions;
        uint48 records;
        uint48 bindings;
        uint48 publications;
    }

    bytes32 internal constant COUNTERS_ROOT =
        0x2965fd57160ca86ec032f96eac3be480be385a49dbc724794da83198a2b1fb00;

    function _counters() internal pure returns (CountersStorage storage $) {
        assembly ("memory-safe") {
            $.slot := COUNTERS_ROOT
        }
    }

    // ---------------------------------------------------------------------------------------------
    // efs.ledger.records — record cells and inline body words
    // ---------------------------------------------------------------------------------------------

    /// Two slots per fresh record plus body words. `carrierKind`: 0 INLINE_WORDS; 1 CODE_BLOB reserved.
    struct RecordCell {
        bytes32 typeId;
        uint48 firstAdmission;
        uint32 length; // byte length; words beyond it are never written
        uint48 occurrences;
        uint8 carrierKind;
    }

    /// @custom:storage-location erc7201:efs.ledger.records
    struct RecordsStorage {
        mapping(bytes32 recordId => RecordCell) cells;
        mapping(bytes32 recordId => mapping(uint256 index => bytes32)) bodyWords;
    }

    bytes32 internal constant RECORDS_ROOT =
        0x95ea68df03033e4e485691c801b399ada592d1857a089601df38c503c05de100;

    function _records() internal pure returns (RecordsStorage storage $) {
        assembly ("memory-safe") {
            $.slot := RECORDS_ROOT
        }
    }

    // ---------------------------------------------------------------------------------------------
    // efs.ledger.subjects
    // ---------------------------------------------------------------------------------------------

    /// `creatorKind`: the principalKind of the creating principal (1 KEY 2 CONTRACT).
    struct SubjectCell {
        uint48 createAdmission;
        uint8 creatorKind;
    }

    /// @custom:storage-location erc7201:efs.ledger.subjects
    struct SubjectsStorage {
        mapping(bytes32 subjectId => SubjectCell) cells;
    }

    bytes32 internal constant SUBJECTS_ROOT =
        0x34a8b688ba7a9f244b30e5d5c3e6a84c66b5c53c194d1ad88e53060ce8ff7100;

    function _subjects() internal pure returns (SubjectsStorage storage $) {
        assembly ("memory-safe") {
            $.slot := SUBJECTS_ROOT
        }
    }

    // ---------------------------------------------------------------------------------------------
    // efs.ledger.admissions — one row per leaf (two slots; UNBIND/RELEASE write the meta word only)
    // ---------------------------------------------------------------------------------------------

    /// `a`: PUBLISH/REUSE = recordId; BIND = target; CREATE = salt; WITHDRAW = bytes32(targetAdmission).
    struct AdmissionRow {
        uint8 kind; // 1 PUBLISH 2 REUSE 3 BIND 4 UNBIND 5 CREATE 6 WITHDRAW 7 RELEASE; 8/9 reserved
        uint8 leaf;
        uint48 publication;
        uint48 bindingOrdinal;
        uint48 expectedRevision;
        uint48 prevAdmission;
        uint8 withdrawn; // 0 or 1 (PUBLISH/REUSE rows)
        // PUBLISH/REUSE rows: the policy row. SPIKE (T-4 number, 16 bits): BIND/UNBIND/RELEASE rows carry the action's
        // strength (its `salt`, 0..65535; RELEASE 0) here: the kernel passes policyRow 0 for every bind kind, so the
        // field is dead in bind rows
        uint16 policyRow;
        uint16 roleRow;
        uint8 targetKind; // BIND rows: 1 RECORD 2 SUBJECT 3 ADDRESS (SPIKE), so the decoder rebuilds oldTarget without shadow heads
        bytes32 a;
    }

    /// @custom:storage-location erc7201:efs.ledger.admissions
    struct AdmissionsStorage {
        mapping(uint256 ordinal => AdmissionRow) rows;
    }

    bytes32 internal constant ADMISSIONS_ROOT =
        0xf936524673093aaa638ecef8cea1b1fcb0a86f97670c7ca482a4fea6b1488e00;

    function _admissions() internal pure returns (AdmissionsStorage storage $) {
        assembly ("memory-safe") {
            $.slot := ADMISSIONS_ROOT
        }
    }

    // ---------------------------------------------------------------------------------------------
    // efs.ledger.publications — sparse evidence cells and the retry map
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

    /// @custom:storage-location erc7201:efs.ledger.publications
    struct PublicationsStorage {
        mapping(uint256 publication => EvidenceCell) evidence;
        mapping(bytes32 principalId => mapping(uint256 nonce => uint48)) publicationAt;
    }

    bytes32 internal constant PUBLICATIONS_ROOT =
        0xef587c61258bfad7cfa2d61a999b8bebef5caa2271ed63df641e1f934e8f4f00;

    function _publications() internal pure returns (PublicationsStorage storage $) {
        assembly ("memory-safe") {
            $.slot := PUBLICATIONS_ROOT
        }
    }

    // ---------------------------------------------------------------------------------------------
    // efs.ledger.bindings — heads, binding ordinals, write-once position cells
    // ---------------------------------------------------------------------------------------------

    /// The target word is KEPT on MASK and RELEASE; the canonical target is 0 unless state == BOUND.
    struct HeadRow {
        uint8 state; // 0 UNSET 1 BOUND 2 MASKED 3 RELEASED
        uint48 revision;
        uint48 admission;
        uint8 targetKind; // 0 NONE 1 RECORD 2 SUBJECT 3 ADDRESS (SPIKE, tags/topics Part C)
        uint48 prevAdmission;
        uint48 bindingOrdinal;
        // reserved zero; the "stale not dead" seam. SPIKE (T-4 number, 16 bits): narrowed from u40 to u32 (still
        // 136 years of unix seconds, or 2^32 blocks) to give the strength 16 bits
        uint32 notAfter;
        // SPIKE (T-4 number): the head's strength (0..65535; RELEASE writes 0); number = strength when BOUND,
        // -1 - strength when MASKED (-1..-65536), none otherwise
        uint16 strength;
        bytes32 target;
    }

    /// Write-once, shared by all authors; role == 0 is a zero write, not a slot.
    struct PositionCell {
        bytes32 purpose;
        bytes32 subject;
        bytes32 role;
    }

    /// @custom:storage-location erc7201:efs.ledger.bindings
    struct BindingsStorage {
        mapping(bytes32 bindingKey => HeadRow) heads;
        mapping(uint256 bindingOrdinal => bytes32) bindingPosition;
        mapping(bytes32 positionKey => PositionCell) positions;
    }

    bytes32 internal constant BINDINGS_ROOT =
        0x47b6d5a9531485da5c6460648366d4b22fa902f89c0d4efccabbd7b6f0738f00;

    function _bindings() internal pure returns (BindingsStorage storage $) {
        assembly ("memory-safe") {
            $.slot := BINDINGS_ROOT
        }
    }

    // ---------------------------------------------------------------------------------------------
    // efs.ledger.principals
    // ---------------------------------------------------------------------------------------------

    struct PrincipalRow {
        uint48 nonce;
        uint48 viewMutationVersion; // increments with the nonce when the publication contains a bind kind
    }

    /// @custom:storage-location erc7201:efs.ledger.principals
    struct PrincipalsStorage {
        mapping(bytes32 principalId => PrincipalRow) rows;
    }

    bytes32 internal constant PRINCIPALS_ROOT =
        0x502ecb3517614eabd6915919aa7adca45b70b54c7b691fd5ee3825f222b63b00;

    function _principals() internal pure returns (PrincipalsStorage storage $) {
        assembly ("memory-safe") {
            $.slot := PRINCIPALS_ROOT
        }
    }

    // ---------------------------------------------------------------------------------------------
    // efs.ledger.revisions — append-only, write-once, one row per activation
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

    /// @custom:storage-location erc7201:efs.ledger.revisions
    struct RevisionsStorage {
        mapping(uint256 revision => RevisionRow) rows;
    }

    bytes32 internal constant REVISIONS_ROOT =
        0xc201c190a1412d71d30fef1177b33b57bf8640364aaafa2bd05597a067d7b700;

    function _revisions() internal pure returns (RevisionsStorage storage $) {
        assembly ("memory-safe") {
            $.slot := REVISIONS_ROOT
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Reserved namespaces: never written before the stage that defines them (design §4.1)
    // ---------------------------------------------------------------------------------------------

    /// efs.ledger.source — SourceEvidence (S4 import lane).
    bytes32 internal constant SOURCE_ROOT =
        0x6abfaf7133487a77383fac82c37b59ba29355e6aabba6843abd6ada22ca0c000;
    /// efs.ledger.staging — stage-then-commit (action kinds 8/9, capability b9).
    bytes32 internal constant STAGING_ROOT =
        0xc8f8104a8aeeb64ca2e69ce6149d38108a5874c5323ed475213f98156ae60100;

    // ---------------------------------------------------------------------------------------------
    // efs.ledger.lock — the transient publication lock (one word; EIP-1153)
    //   phase u8@0 | stagedPublication u48@8 | admissionFrontier u48@56 | mutationsSnapshot u48@104
    // ---------------------------------------------------------------------------------------------

    bytes32 internal constant LOCK_SLOT =
        0x4c4f67d80a37938dcd47d00dc4f183f159d48fe29a94186c0984897509322c00;

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
