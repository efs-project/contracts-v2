// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ScopeKey} from "./Actions.sol";
import {Effect, Readiness} from "./Index.sol";

/// @title IRealmIndex — the index generation's callback and build surface (design §5.11, §10)
/// @notice The three idle-gated build entry points each DELEGATECALL the pinned IndexBuild (BUILD, with
///         BUILD_CODEHASH re-verified per call) in the generation's own context.
interface IRealmIndex {
    /// Prefix; CALL from ledger context; msg.sender == ledger.
    function onAdmission(uint64 publication, Effect[] calldata effects, bytes32[] calldata refs)
        external
        returns (bytes4);

    /// Final; STATICCALL; exact selector ack.
    function afterPublication(
        uint64 publication,
        Effect[] calldata effects,
        bytes32[] calldata refs
    ) external view returns (bytes4);

    function replayReadiness() external view returns (Readiness memory);

    /// Permissionless; fresh stores only (INITIAL_WRITER == this, !attached); refused once live.
    function replayNextPublication(uint16 maxFacts) external returns (uint64 processed);

    /// Ascending from admission 1 into this generation's fresh store for a later APPEND_ORDERED family, before
    /// attachment.
    function build(bytes32 familyId, uint16 maxFacts) external returns (uint64 through);

    /// BITMAP families; pre-declaration scopes only; this generation must be ledger.index().
    function backfill(bytes32 familyId, ScopeKey scope, uint64 expectedThrough, uint16 maxEntries)
        external
        returns (uint64 through);
}
