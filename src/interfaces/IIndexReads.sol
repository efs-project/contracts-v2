// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {FamilyId, ScopeKey, TypeId} from "./Actions.sol";
import {Coverage} from "./Results.sol";
import {DigestSpec, FamilyEntry, Unit, WorkModel} from "./Index.sol";

/// @title IIndexReads — coverage and family reads of an index generation (design §5.11, §10.5)
/// @notice Acceptors may read coverage and postings here (prefix-COMPLETE inside the publication). Every function is
///         answered at the generation's address: `manifestHash`, `workModel`, `digestSpecCount`, `progress`,
///         `ledger`, the two store getters and `readsContract` by the generation itself, the rest by its reads
///         contract through the generation's fallback (`STATICCALL`, calldata unchanged; design §10.1).
interface IIndexReads {
    function manifestHash() external view returns (bytes32);

    function manifest()
        external
        view
        returns (
            bytes32 header,
            FamilyEntry[] memory families,
            Unit[] memory units,
            DigestSpec[] memory specs,
            WorkModel memory work,
            bytes32 physicalProfile,
            bytes32 callbackProfile
        );

    /// The copy of the LIVE index's manifest preimage this generation was deployed with: the bytes
    /// `abi.encode(header, families, units, specs, work, physicalProfile, callbackProfile, reads, readsCodehash)`
    /// whose keccak is the manifest hash the kernel recorded in the revision row when it activated that index; empty
    /// for a generation deployed with no live index (genesis). The kernel's carried check (`E_INDEX_NOT_READY` 12,
    /// 14) and the generation's own read the live index's families and units from it, never from the live index, so
    /// replacing an index never depends on the live index answering. A copy of an index that has since been replaced
    /// no longer hashes to the record: the generation is then refused and must be redeployed with a fresh copy.
    function liveManifestCopy() external view returns (bytes memory);

    function workModel() external view returns (WorkModel memory);

    /// The `topic/1` and `topic-word/1` Type ids whose ancestors the topic lists (`scope-below`, `place-below`) walk;
    /// both zero when the generation keeps no topic lists (their families are then `NOT_MAINTAINED`).
    function topicTypes() external view returns (bytes32 topicTypeId, bytes32 topicWordTypeId);

    /// How many of the manifest's digest specs name `typeId`: the ingress charges `freshPerDigestSpec` for each
    /// when it quotes a fresh record of that Type (design §10.4).
    function digestSpecCount(bytes32 typeId) external view returns (uint256);

    function coverage(FamilyId family, ScopeKey scope)
        external
        view
        returns (Coverage, uint64 fromAdmission, uint64 throughAdmission, uint8 phase);

    function coverageOfType(FamilyId family, TypeId typeId)
        external
        view
        returns (Coverage, uint64 fromAdmission, uint64 throughAdmission, uint8 phase);

    /// UNKNOWN for an undeclared spec.
    function coverageOfSpec(FamilyId family, TypeId typeId, uint8 specIndex)
        external
        view
        returns (Coverage, uint64, uint64, uint8);

    /// UNKNOWN for an undeclared algorithm.
    function coverageOfDigest(uint8 algorithm)
        external
        view
        returns (Coverage, uint64, uint64, uint8);

    function provenFrom() external view returns (uint64);

    function progress()
        external
        view
        returns (uint64 lastProcessed, uint64 lastPublication, bool gapped);

    function postingHeadOf(FamilyId family, TypeId typeId, uint8 ordinal, bytes32 value)
        external
        view
        returns (Coverage, uint64 count, uint64 live, uint64 last, bool synthesized);

    /// n ≤ maxReadCount.
    function postingSliceOf(
        FamilyId family,
        TypeId typeId,
        uint8 ordinal,
        bytes32 value,
        uint64 from,
        uint16 n
    ) external view returns (Coverage, uint64[] memory, bool synthesized);

    /// The by-record read; synthesizes the virtual first entry.
    function occurrencesOf(bytes32 recordId)
        external
        view
        returns (Coverage, uint64 count, uint64 live, uint64[] memory entries);

    function ledger() external view returns (address);

    function postingStore() external view returns (address);

    function bitmapStore() external view returns (address);

    function buildDelegate() external view returns (address);
    /// The contract that answers this generation's forwarded reads and holds its manifest, and that contract's
    /// codehash as the generation recorded it at construction; the manifest hash folds both.
    function readsContract() external view returns (address reads, bytes32 codehash);
}
