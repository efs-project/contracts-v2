// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

// Kernel-internal: a delegate interface (declared in design §5.11; delegates are outside the consumer closure per
// §5.15); declared so the ABI union is complete.

import {ScopeKey} from "../Actions.sol";

/// @title IIndexBuild — the build delegate behind IRealmIndex's three idle-gated entry points (design §5.11)
/// @notice WITHDRAWN (design §10.1, §10.6, 2026-11-25): an index generation may not DELEGATECALL (activation's
///         plain-runtime scan refuses it), so no `IndexBuild` delegate exists or is pinned; the interface is kept only
///         so the committed ABI union stays complete until the build step that replaces it is designed.
interface IIndexBuild {
    function replayNextPublication(uint16 maxFacts) external returns (uint64 processed);

    function build(bytes32 familyId, uint16 maxFacts) external returns (uint64 through);

    function backfill(bytes32 familyId, ScopeKey scope, uint64 expectedThrough, uint16 maxEntries)
        external
        returns (uint64 through);
}
