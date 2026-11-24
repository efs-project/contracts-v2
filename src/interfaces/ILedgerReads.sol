// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {BasisCommit, Status} from "./Results.sol";
import {AdmissionRow, Description, Evidence, Head, RecordHeader, Revision} from "./Views.sol";

/// @title ILedgerReads — the exact-row ledger facet (design §5.7)
/// @notice An immutable facet at its own address; every function takes `address ledger`; statuses, never zero
///         sentinels; basis echoed. Every facet checks `ILedgerHot(ledger).layoutId()` against the layouts it
///         was generated for and returns UNSUPPORTED otherwise (the facet-layout rule).
interface ILedgerReads {
    /// The realm namespace, current revision row, implementation slot and counters through one extsloadBatch.
    function describe(address ledger) external view returns (Description memory);

    function revisionAt(address ledger, uint32 n) external view returns (Status, Revision memory);

    function basis(address ledger) external view returns (BasisCommit memory);

    function record(address ledger, bytes32 id)
        external
        view
        returns (Status, RecordHeader memory, bytes memory body, BasisCommit memory);

    function recordHeader(address ledger, bytes32 id)
        external
        view
        returns (Status, RecordHeader memory);

    /// count ≤ limits.maxReadCount.
    function bodyWords(address ledger, bytes32 id, uint32 fromWord, uint16 count)
        external
        view
        returns (Status, bytes32[] memory);

    /// length ≤ limits.maxBody.
    function bodySlice(address ledger, bytes32 id, uint32 offset, uint32 length)
        external
        view
        returns (Status, bytes memory);

    function subjectInfo(address ledger, bytes32 subjectId)
        external
        view
        returns (Status, uint64 createdAt, bytes32 creatorPrincipal);

    function head(address ledger, bytes32 bindingKey) external view returns (Status, Head memory);

    function positionCell(address ledger, bytes32 position)
        external
        view
        returns (Status, bytes32 purpose, bytes32 subject, bytes32 role);

    function bindingPosition(address ledger, uint64 bindingOrdinal)
        external
        view
        returns (Status, bytes32 position);

    function admission(address ledger, uint64 ordinal)
        external
        view
        returns (Status, AdmissionRow memory);

    /// count ≤ maxReadCount.
    function admissions(address ledger, uint64 from, uint16 count)
        external
        view
        returns (AdmissionRow[] memory, uint64 next, BasisCommit memory);

    function evidence(address ledger, uint64 publication)
        external
        view
        returns (Status, Evidence memory);

    function publicationAt(address ledger, bytes32 principalId, uint64 nonce)
        external
        view
        returns (Status, uint64 publication, bytes32 intentDigest);

    /// At most maxReadIds accounts.
    function principalsOf(address ledger, address[] calldata accounts)
        external
        view
        returns (bytes32[] memory);
}
