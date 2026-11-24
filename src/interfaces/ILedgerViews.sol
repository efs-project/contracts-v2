// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

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
