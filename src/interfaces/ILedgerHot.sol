// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @title ILedgerHot — the Etched kernel reads (design §5.3)
/// @notice One SLOAD each, no stipends, no struct encoders. `HOT_ABI_ID = keccak("efs2/ledger-hot/1" ‖ sorted
///         selectors ‖ return layouts)` is an implementation immutable exposed by `hotAbiId()` and snapshot-tested
///         across releases. A kernel upgrade may add selectors (a new `HOT_ABI_ID`) and never changes or removes
///         one; acceptors and units may call these getters on `ctx.ledger`/`LEDGER` forever. `extsload*` are the
///         proof-able raw floor for the facets, the index, the replay decoder, the SDK and the oracle; they are
///         forbidden in `profiles/` and in readers other than the two facets. Struct views and composites are on
///         the facets (`ILedgerReads`, `ILedgerViews`).
interface ILedgerHot {
    /// The admission, record, binding and publication counters.
    function counts()
        external
        view
        returns (uint64 admissions, uint64 records, uint64 bindings, uint64 publications);

    /// Publication phase: 0 IDLE 1 PREPARING 2 APPLYING 3 FINAL.
    function phase()
        external
        view
        returns (uint8 phase, uint64 stagedPublication, uint64 admissionFrontier, uint32 revision);

    /// The live execution-set commitment (design §8.1).
    function executionSet() external view returns (bytes32);

    /// The current activation revision.
    function revision() external view returns (uint32);

    /// The genesis and accepted chain ids, the revision and the freeze flag.
    function control()
        external
        view
        returns (uint64 genesisChainId, uint64 acceptedChainId, uint32 revision, bool frozen);

    function realmId() external view returns (bytes32);

    function realmOrigin() external view returns (bytes32);

    function layoutId() external view returns (bytes32);

    /// This implementation's `HOT_ABI_ID`.
    function hotAbiId() external view returns (bytes32);

    /// The constant list: this implementation's id plus every predecessor id it still serves; no SLOAD.
    function supportedHotAbiIds() external view returns (bytes32[] memory);

    function registry() external view returns (address);

    function index() external view returns (address);

    function indexGeneration() external view returns (uint32);

    /// The implementation immutable.
    function ingress() external view returns (address);

    /// The implementation immutable.
    function applyDelegate() external view returns (address);

    function controller() external view returns (address);

    /// Realm +17; read by RealmNoticeRule (design §12.1).
    function noticePrincipal() external view returns (bytes32);

    /// Advisory.
    function readerDirectory() external view returns (address);

    function nonceOf(bytes32 principalId)
        external
        view
        returns (uint64 nonce, uint64 viewMutationVersion);

    function subjectCreatedAt(bytes32 subjectId) external view returns (uint64);

    /// `target` is the canonical target: loaded only when BOUND, else 0.
    function head(bytes32 bindingKey)
        external
        view
        returns (
            uint8 state,
            uint64 revision,
            uint64 admission,
            uint8 targetKind,
            uint64 prevAdmission,
            uint64 bindingOrdinal,
            bytes32 target
        );

    function recordHeader(bytes32 recordId)
        external
        view
        returns (
            bytes32 typeId,
            uint64 firstAdmission,
            uint32 length,
            uint64 occurrences,
            uint8 carrierKind
        );

    /// (0, 0) when none; two SLOADs (the ordinal map, then evidence w3); the only two-SLOAD read here.
    function publicationAt(bytes32 principalId, uint64 nonce)
        external
        view
        returns (uint64 publication, bytes32 intentDigest);

    function extsload(bytes32 slot) external view returns (bytes32);

    /// At most 256 slots.
    function extsloadBatch(bytes32[] calldata slots) external view returns (bytes32[] memory);

    function exttload(bytes32 slot) external view returns (bytes32);
}
