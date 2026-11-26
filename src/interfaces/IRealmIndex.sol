// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ScopeKey} from "./Actions.sol";
import {Effect, Readiness} from "./Index.sol";

/// @title IRealmIndex — the index generation's callback and build surface (design §5.11, §10)
/// @notice The three idle-gated entry points run in the generation's own code. The delegate shape of `IndexBuild`
///         (a codehash-pinned DELEGATECALL target) is withdrawn (design §10.6, 2026-11-25): activation's plain-runtime
///         scan refuses any DELEGATECALL in an index. Generation 1 replays into fresh stores itself; its `build`
///         moves the frontier of a generation that carries every store it names (a re-pin) and walks history into the
///         fresh stores of one that does not; `backfill` refuses. A later generation builds its own later families
///         from history before attachment (docs INDEX-BUILD).
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

    /// Permissionless and idle-gated; `familyId` must be 0. Moves the build frontier and returns it: with no fresh
    /// store, straight to `counts()` once every carried family is the live index's; with a fresh store, by walking
    /// history into the fresh stores only, whole publications in order from the frontier, while the leaves folded
    /// in this call stay within the budget `maxFacts` (at least one publication; `E_BUILD(6)` when the first alone
    /// exceeds it).
    function build(bytes32 familyId, uint16 maxFacts) external returns (uint64 through);

    /// BITMAP families; pre-declaration scopes only; this generation must be ledger.index().
    function backfill(bytes32 familyId, ScopeKey scope, uint64 expectedThrough, uint16 maxEntries)
        external
        returns (uint64 through);
}
