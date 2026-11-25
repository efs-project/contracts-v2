// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Coordinate} from "./Actions.sol";
import {BasisCommit, History, Status} from "./Results.sol";
import {AcceptanceBasis, Head, PublicationView, RecordHeader} from "./Views.sol";

/// @title ILedgerViews — the composite ledger facet (design §5.7)
/// @notice An immutable facet at its own address; every function takes `address ledger`; statuses, never zero
///         sentinels; basis echoed. `publication()` is keyed by `(principalId, nonce)` because that is the only
///         retained id→ordinal map.
interface ILedgerViews {
    /// effectsHash recomputed through Effect/3 reconstruction.
    function publication(address ledger, bytes32 principalId, uint64 nonce)
        external
        view
        returns (Status, PublicationView memory);

    /// At most maxReadIds ids.
    function records(address ledger, bytes32[] calldata ids)
        external
        view
        returns (Status[] memory, RecordHeader[] memory, BasisCommit memory);

    function heads(address ledger, bytes32[] calldata keys)
        external
        view
        returns (Head[] memory, BasisCommit memory);

    /// Ordered first-touch: BOUND or MASKED wins; UNSET/RELEASED fall through.
    function headsAt(address ledger, bytes32[] calldata principals, bytes32 position)
        external
        view
        returns (
            Status,
            Head memory selected,
            uint8 selectedIndex,
            Head[] memory all,
            BasisCommit memory
        );

    /// n·m, position-major; the read-set preflight.
    function headSnapshots(
        address ledger,
        bytes32[] calldata principals,
        bytes32[] calldata positions
    ) external view returns (bytes32[] memory);

    /// Binding ordinal → its position and the position's cell, at most maxReadIds ordinals (the entries of the
    /// first-statement lists, design §10.2).
    function bindingCells(address ledger, uint64[] calldata ordinals)
        external
        view
        returns (
            Status[] memory,
            bytes32[] memory positions,
            Coordinate[] memory cells,
            BasisCommit memory
        );

    /// The lens rule over list entries (binding ordinals): each entry's position and cell, the first of
    /// `principals[0..authors[i]]` with a stance there (`decider`, 255 when none; `decided`, its head state;
    /// `strength`, its strength) and the entry author's own head.
    function lensRule(
        address ledger,
        bytes32[] calldata principals,
        uint64[] calldata ordinals,
        uint8[] calldata authors
    )
        external
        view
        returns (
            Status[] memory,
            bytes32[] memory positions,
            Coordinate[] memory cells,
            uint8[] memory decider,
            uint8[] memory decided,
            uint16[] memory strength,
            Head[] memory own,
            BasisCommit memory
        );

    /// Admission ordinal of a first statement at `position` → its author's principal and that author's head
    /// there, at most maxReadIds admissions (the entries of `position-authors`, design §10.2).
    function authorHeads(address ledger, bytes32 position, uint64[] calldata admissions)
        external
        view
        returns (
            Status[] memory,
            bytes32[] memory principals,
            Head[] memory heads,
            BasisCommit memory
        );

    function acceptanceBasis(address ledger, uint64 ordinal)
        external
        view
        returns (Status, AcceptanceBasis memory);

    /// Prev-chain walk; UNKNOWN beyond maxHops.
    function historyAt(address ledger, bytes32 bindingKey, uint64 asOf, uint16 maxHops)
        external
        view
        returns (History, Head memory);
}
