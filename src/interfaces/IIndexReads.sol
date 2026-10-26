// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {FamilyId, ScopeKey, TypeId} from "./Actions.sol";
import {Coverage} from "./Results.sol";
import {DigestSpec, FamilyEntry, Unit, WorkModel} from "./Index.sol";

/// @title IIndexReads — coverage and family reads of an index generation (design §5.11, §10.5)
/// @notice Acceptors may read coverage and postings here (prefix-COMPLETE inside the publication).
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

    function workModel() external view returns (WorkModel memory);

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
}
