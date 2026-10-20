// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {BitmapStoreStorage, WriterRange} from "./storage/StoreStorage.sol";
import {StoreBase} from "./StoreBase.sol";
import {Keys} from "../lib/Keys.sol";
import {FamilyId, ScopeKey} from "../interfaces/Actions.sol";
import {IBitmapStore} from "../interfaces/IBitmapStore.sol";
import {E_BACKFILL, E_COVERAGE, E_ORDER, E_WRITER} from "../interfaces/Errors.sol";

/// @title BitmapStore — scope lists, live bits and per-scope coverage that outlive generations (design §4.6)
/// @notice One per Realm. The kind-10 scope list (binding ordinals in append order; entry 0 inline in the head)
///         lives beside its bitmaps, so one call per FIRST_BIND appends, sets the live bit and stamps
///         `lastMutation`. The live-scope family (18) keeps its first 48 bits in the head word; every further
///         bit, and every other BITMAP family's bits, live in `bits[scope][family][word]` at bit index `entry`.
contract BitmapStore is IBitmapStore, BitmapStoreStorage, StoreBase {
    bytes32 public constant STORE_ABI_ID = keccak256("efs2/bitmap-store/1");
    uint256 private constant MASK48 = (1 << 48) - 1;
    uint8 private constant COVERAGE_OPEN = 1;
    uint8 private constant COVERAGE_COMPLETE = 2;
    uint8 private constant COVERAGE_RETIRED = 3;

    bytes32 private immutable FAMILY_LIVE_SCOPE;

    constructor(address ledger_, address initialWriter_, bytes32[] memory families)
        StoreBase(ledger_, initialWriter_)
    {
        BitmapStorage storage $ = _bitmap();
        for (uint256 i; i < families.length; ++i) {
            $.familyIds.push(families[i]);
        }
        FAMILY_LIVE_SCOPE = Keys.familyId("live-scope");
    }

    // ---- StoreBase hooks ---------------------------------------------------------------------------------

    function _familyIds() internal view override returns (bytes32[] storage) {
        return _bitmap().familyIds;
    }

    function _writers() internal view override returns (WriterRange[] storage) {
        return _bitmap().writers;
    }

    function _attached() internal view override returns (bool) {
        return _bitmap().attached != 0;
    }

    function _setAttached() internal override {
        _bitmap().attached = 1;
    }

    // ---- writes ------------------------------------------------------------------------------------------

    /// @inheritdoc IBitmapStore
    function appendScopeEntry(FamilyId family, ScopeKey scope, uint64 bindingOrdinal)
        external
        returns (uint64 entryIndex)
    {
        (uint8 mode, uint48 admission) = _authorize(FamilyId.unwrap(family));
        if (mode == MODE_BACKFILL) revert E_WRITER(msg.sender);
        BitmapStorage storage $ = _bitmap();
        bytes32 s = ScopeKey.unwrap(scope);
        ScopeHead storage h = $.scopeHeads[s];
        uint48 c = h.count;
        if (c != 0 && bindingOrdinal <= _entry(s, c - 1)) {
            revert E_ORDER(_entry(s, c - 1), bindingOrdinal);
        }
        if (c == 0) {
            h.entry0 = uint48(bindingOrdinal);
        } else {
            uint256 e = c - 1; // entries >= 1 live in words, five per word
            $.scopeEntries[s][e / 5] |= uint256(bindingOrdinal) << ((e % 5) * 48);
        }
        entryIndex = c;
        h.count = c + 1;
        h.live += 1;
        h.lastMutation = admission;
        _setLiveBit($, s, entryIndex, true);
    }

    /// @inheritdoc IBitmapStore
    function setBit(FamilyId family, ScopeKey scope, uint64 entryIndex, bool value) external {
        (uint8 mode, uint48 admission) = _authorize(FamilyId.unwrap(family));
        if (mode == MODE_BACKFILL) revert E_WRITER(msg.sender);
        BitmapStorage storage $ = _bitmap();
        bytes32 s = ScopeKey.unwrap(scope);
        ScopeHead storage h = $.scopeHeads[s];
        if (entryIndex >= h.count) revert E_ORDER(h.count, entryIndex);
        if (FamilyId.unwrap(family) == FAMILY_LIVE_SCOPE) {
            bool was = _liveBit($, s, entryIndex);
            if (was != value) {
                _setLiveBit($, s, entryIndex, value);
                h.live = value ? h.live + 1 : h.live - 1;
            }
        } else {
            _setFamilyBit($, s, FamilyId.unwrap(family), entryIndex, value);
        }
        h.lastMutation = admission;
    }

    /// @inheritdoc IBitmapStore
    function stamp(ScopeKey scope) external {
        (uint8 mode, uint48 admission) = _authorize(FAMILY_LIVE_SCOPE);
        if (mode == MODE_BACKFILL) revert E_WRITER(msg.sender);
        _bitmap().scopeHeads[ScopeKey.unwrap(scope)].lastMutation = admission;
    }

    /// @inheritdoc IBitmapStore
    function openCoverage(FamilyId family, ScopeKey scope, uint64 liveFrom) external {
        (uint8 mode,) = _authorize(FamilyId.unwrap(family));
        if (mode == MODE_BACKFILL) revert E_WRITER(msg.sender);
        CoverageSlot storage c = _bitmap().coverage[FamilyId.unwrap(family)][ScopeKey.unwrap(scope)];
        if (c.state != 0) revert E_COVERAGE(1);
        c.liveFrom = uint48(liveFrom);
        c.through = 0;
        c.state = COVERAGE_OPEN;
    }

    /// @inheritdoc IBitmapStore
    function backfillOr(
        FamilyId family,
        ScopeKey scope,
        uint64 wordIndex,
        uint256 orMask,
        uint64 through
    ) external {
        (uint8 mode,) = _authorize(FamilyId.unwrap(family));
        if (mode != MODE_BACKFILL) revert E_WRITER(msg.sender);
        BitmapStorage storage $ = _bitmap();
        CoverageSlot storage c = $.coverage[FamilyId.unwrap(family)][ScopeKey.unwrap(scope)];
        if (c.state != COVERAGE_OPEN) revert E_BACKFILL(1);
        if (through < c.through || through > c.liveFrom) revert E_BACKFILL(2);
        $.bits[ScopeKey.unwrap(scope)][FamilyId.unwrap(family)][wordIndex] |= orMask;
        c.through = uint48(through);
        if (through == c.liveFrom) c.state = COVERAGE_COMPLETE;
    }

    /// @inheritdoc IBitmapStore
    function backfillSet(
        FamilyId family,
        ScopeKey scope,
        uint64 entryIndex,
        bool value,
        uint64 through
    ) external {
        (uint8 mode,) = _authorize(FamilyId.unwrap(family));
        if (mode != MODE_BACKFILL) revert E_WRITER(msg.sender);
        BitmapStorage storage $ = _bitmap();
        bytes32 s = ScopeKey.unwrap(scope);
        CoverageSlot storage c = $.coverage[FamilyId.unwrap(family)][s];
        if (c.state != COVERAGE_OPEN) revert E_BACKFILL(1);
        if (through < c.through || through > c.liveFrom) revert E_BACKFILL(2);
        if (FamilyId.unwrap(family) == FAMILY_LIVE_SCOPE) {
            bool was = _liveBit($, s, entryIndex);
            if (was != value) {
                _setLiveBit($, s, entryIndex, value);
                ScopeHead storage h = $.scopeHeads[s];
                h.live = value ? h.live + 1 : h.live - 1;
            }
        } else {
            _setFamilyBit($, s, FamilyId.unwrap(family), entryIndex, value);
        }
        c.through = uint48(through);
        if (through == c.liveFrom) c.state = COVERAGE_COMPLETE;
    }

    /// @inheritdoc IBitmapStore
    function retireCoverage(FamilyId family, ScopeKey scope) external {
        (uint8 mode, uint48 admission) = _authorize(FamilyId.unwrap(family));
        if (mode == MODE_LIVE) revert E_WRITER(msg.sender);
        CoverageSlot storage c = _bitmap().coverage[FamilyId.unwrap(family)][ScopeKey.unwrap(scope)];
        if (c.state == 0) revert E_COVERAGE(2);
        c.retiredAt = admission;
        c.state = COVERAGE_RETIRED;
    }

    // ---- bit helpers ---------------------------------------------------------------------------------------

    function _liveBit(BitmapStorage storage $, bytes32 s, uint256 e) private view returns (bool) {
        if (e < 48) return ($.scopeHeads[s].liveBits0 >> e) & 1 == 1;
        return ($.bits[s][FAMILY_LIVE_SCOPE][e / 256] >> (e % 256)) & 1 == 1;
    }

    function _setLiveBit(BitmapStorage storage $, bytes32 s, uint256 e, bool value) private {
        if (e < 48) {
            ScopeHead storage h = $.scopeHeads[s];
            h.liveBits0 = value ? h.liveBits0 | uint48(1 << e) : h.liveBits0 & ~uint48(1 << e);
        } else {
            _setFamilyBit($, s, FAMILY_LIVE_SCOPE, e, value);
        }
    }

    function _setFamilyBit(
        BitmapStorage storage $,
        bytes32 s,
        bytes32 family,
        uint256 e,
        bool value
    ) private {
        uint256 w = $.bits[s][family][e / 256];
        uint256 m = uint256(1) << (e % 256);
        $.bits[s][family][e / 256] = value ? w | m : w & ~m;
    }

    function _entry(bytes32 s, uint256 e) private view returns (uint64) {
        BitmapStorage storage $ = _bitmap();
        if (e == 0) return $.scopeHeads[s].entry0;
        uint256 i = e - 1;
        return uint64(($.scopeEntries[s][i / 5] >> ((i % 5) * 48)) & MASK48);
    }

    // ---- reads -------------------------------------------------------------------------------------------

    /// @inheritdoc IBitmapStore
    function scopeHead(ScopeKey scope)
        external
        view
        returns (
            uint64 count,
            uint64 live,
            uint64 lastMutation_,
            uint48 liveBits0,
            uint16 flags,
            uint64 entry0
        )
    {
        ScopeHead storage h = _bitmap().scopeHeads[ScopeKey.unwrap(scope)];
        return (h.count, h.live, h.lastMutation, h.liveBits0, h.flags, h.entry0);
    }

    /// @inheritdoc IBitmapStore
    function scopeEntry(ScopeKey scope, uint64 i) public view returns (uint64) {
        bytes32 s = ScopeKey.unwrap(scope);
        uint48 c = _bitmap().scopeHeads[s].count;
        if (i >= c) revert E_ORDER(c, i);
        return _entry(s, i);
    }

    /// @inheritdoc IBitmapStore
    function scopeSlice(ScopeKey scope, uint64 from, uint16 n)
        external
        view
        returns (uint64[] memory out)
    {
        uint64 count = _bitmap().scopeHeads[ScopeKey.unwrap(scope)].count;
        uint64 end = from + n > count ? count : from + n;
        out = new uint64[](end > from ? end - from : 0);
        for (uint64 i = from; i < end; ++i) {
            out[i - from] = scopeEntry(scope, i);
        }
    }

    /// @inheritdoc IBitmapStore
    function liveCount(ScopeKey scope) external view returns (uint64) {
        return _bitmap().scopeHeads[ScopeKey.unwrap(scope)].live;
    }

    /// @inheritdoc IBitmapStore
    function liveWords(ScopeKey scope, FamilyId family, uint64 fromWord, uint16 n)
        external
        view
        returns (uint256[] memory out)
    {
        BitmapStorage storage $ = _bitmap();
        bytes32 s = ScopeKey.unwrap(scope);
        bytes32 f = FamilyId.unwrap(family);
        out = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            uint256 w = fromWord + i;
            uint256 word = $.bits[s][f][w];
            if (w == 0 && f == FAMILY_LIVE_SCOPE) {
                word = (word & ~MASK48) | $.scopeHeads[s].liveBits0;
            }
            out[i] = word;
        }
    }

    /// @inheritdoc IBitmapStore
    function liveAt(ScopeKey scope, uint64 i) external view returns (uint64 bindingOrdinal) {
        BitmapStorage storage $ = _bitmap();
        bytes32 s = ScopeKey.unwrap(scope);
        uint48 c = $.scopeHeads[s].count;
        uint64 seen;
        for (uint256 e; e < c; ++e) {
            if (_liveBit($, s, e)) {
                if (seen == i) return _entry(s, e);
                ++seen;
            }
        }
        revert E_ORDER(seen, i);
    }

    /// @inheritdoc IBitmapStore
    function lastMutation(ScopeKey scope) external view returns (uint64) {
        return _bitmap().scopeHeads[ScopeKey.unwrap(scope)].lastMutation;
    }

    /// @inheritdoc IBitmapStore
    function scopeCoverage(FamilyId family, ScopeKey scope)
        external
        view
        returns (uint64 through, uint64 liveFrom, uint64 retiredAt, uint8 state)
    {
        CoverageSlot storage c = _bitmap().coverage[FamilyId.unwrap(family)][ScopeKey.unwrap(scope)];
        return (c.through, c.liveFrom, c.retiredAt, c.state);
    }

    // ---- common getters ---------------------------------------------------------------------------------

    function writers()
        external
        view
        returns (address[] memory generations, uint64[] memory from, uint64[] memory to)
    {
        return _writersView();
    }

    function familyIds() external view returns (bytes32[] memory) {
        return _familyIds();
    }

    function initialWriter() external view returns (address) {
        return INITIAL_WRITER;
    }

    function attached() external view returns (bool) {
        return _attached();
    }

    function ledger() external view returns (address) {
        return LEDGER;
    }

    function storeAbiId() external pure returns (bytes32) {
        return STORE_ABI_ID;
    }
}
