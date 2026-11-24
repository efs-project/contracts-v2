// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

// Kernel-internal (design §5.15, §10.6): outside the consumer closure; declared so the ABI union is complete.

import {Effect} from "../Index.sol";

/// @title IIndexReplayDecoder — rebuilds one publication's Effect/3 stream from the ledger's rows (design §10.6)
/// @notice Immutable per `layoutId`; pinned by the generation that replays through it. Reads the ledger only
///         through `ILedgerHot.extsloadBatch` under `Layout` and the registry's `typeInfo` for the reference
///         count; validates the evidence cell's revision against the revision row's `layoutId`.
interface IIndexReplayDecoder {
    function LAYOUT_ID() external view returns (bytes32);

    /// `abi.encode(publication, effects, refs)`: exactly the arguments of `RealmIndex.replayFold`, so a
    /// generation forwards it with a selector and decodes nothing.
    function payload(address ledger, uint64 publication) external view returns (bytes memory);

    function decode(address ledger, uint64 publication)
        external
        view
        returns (Effect[] memory effects, bytes32[] memory refs);
}
