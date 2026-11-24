// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {FamilyId, ScopeKey} from "./Actions.sol";

/// @title IBitmapStore — the per-Realm kind-10 scope lists and BITMAP family store (design §5.11, §4.6)
/// @notice Same discipline as IPostingStore: STORE_ABI_ID = keccak("efs2/bitmap-store/1" ‖ …) exposed by
///         storeAbiId(); this ABI is Etched.
interface IBitmapStore {
    /// The kind-10 list: head (count, live, lastMutation, liveBits0, entry0) and entry word in one call on
    /// FIRST_BIND.
    /// `admission` is the mutating admission: equal to the ledger's frontier for a live write, at most the
    /// frontier for a build or replay write (so a replayed store stamps what the live one stamped).
    function appendScopeEntry(
        FamilyId family,
        ScopeKey scope,
        uint64 bindingOrdinal,
        uint64 admission
    ) external returns (uint64 entryIndex);

    /// A BITMAP family's live hook; stamps lastMutation in the same SSTORE.
    function setBit(
        FamilyId family,
        ScopeKey scope,
        uint64 entryIndex,
        bool value,
        uint64 admission
    ) external;

    /// REBIND/RESTORE without a bit change: lastMutation only.
    function stamp(ScopeKey scope, uint64 admission) external;

    /// A later BITMAP family's first live touch of a pre-declaration scope.
    function openCoverage(FamilyId family, ScopeKey scope, uint64 liveFrom) external;

    /// IDLE only; MONOTONE families; within [through, liveFrom).
    function backfillOr(
        FamilyId family,
        ScopeKey scope,
        uint64 wordIndex,
        uint256 orMask,
        uint64 through
    ) external;

    /// IDLE only; CURRENT_STATE families; value read from the current head.
    function backfillSet(
        FamilyId family,
        ScopeKey scope,
        uint64 entryIndex,
        bool value,
        uint64 through
    ) external;

    function retireCoverage(FamilyId family, ScopeKey scope) external;

    function scopeHead(ScopeKey scope)
        external
        view
        returns (
            uint64 count,
            uint64 live,
            uint64 lastMutation,
            uint48 liveBits0,
            uint16 flags,
            uint64 entry0
        );

    function scopeEntry(ScopeKey scope, uint64 i) external view returns (uint64 bindingOrdinal);

    function scopeSlice(ScopeKey scope, uint64 from, uint16 n)
        external
        view
        returns (uint64[] memory);

    function liveCount(ScopeKey scope) external view returns (uint64);

    function liveWords(ScopeKey scope, FamilyId family, uint64 fromWord, uint16 n)
        external
        view
        returns (uint256[] memory);

    function liveAt(ScopeKey scope, uint64 i) external view returns (uint64 bindingOrdinal);

    function lastMutation(ScopeKey scope) external view returns (uint64);

    function scopeCoverage(FamilyId family, ScopeKey scope)
        external
        view
        returns (uint64 through, uint64 liveFrom, uint64 retiredAt, uint8 state);

    function writers()
        external
        view
        returns (address[] memory generations, uint64[] memory from, uint64[] memory to);

    function familyIds() external view returns (bytes32[] memory);

    function initialWriter() external view returns (address);

    function attached() external view returns (bool);

    function storeAbiId() external view returns (bytes32);

    function ledger() external view returns (address);
}
