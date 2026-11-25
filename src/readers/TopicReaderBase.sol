// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Coordinate, FamilyId, TypeId} from "../interfaces/Actions.sol";
import {IIndexReads} from "../interfaces/IIndexReads.sol";
import {ILedgerHot} from "../interfaces/ILedgerHot.sol";
import {ILedgerReads} from "../interfaces/ILedgerReads.sol";
import {ILedgerViews} from "../interfaces/ILedgerViews.sol";
import {IReader, TopicPageInfo} from "../interfaces/Readers.sol";
import {BasisCommit, Coverage, Status} from "../interfaces/Results.sol";
import {Head} from "../interfaces/Views.sol";

/// A dependency (the ledger, a facet, the index or a store) reverted, ran out of gas or has no code.
error E_TOPIC_READ(address source, bytes4 selector); // none
/// A dependency's reply is shorter than its ABI shape, or a word does not fit its declared width.
error E_TOPIC_REPLY(bytes4 selector, uint256 length); // none
/// A dependency's reply contradicts another reply or the kernel's own laws; codes on `TopicReaderBase`.
error E_TOPIC_INCONSISTENT(uint8 code); // none
/// A facet answered a per-row read with a status the page cannot carry (UNKNOWN, UNSUPPORTED, LIMIT_EXCEEDED).
error E_TOPIC_STATUS(uint8 status); // none

// The readers' loops make one bounded set of facet and index calls per list entry, stopped by `limit` and
// `gasReserve`; narrowing casts are list indices and counts bounded by the 64-bit admission counter.
// forge-lint: disable-start(unsafe-typecast)
// forge-lint: disable-start(calls-loop)
// forge-lint: disable-start(require-revert-in-loop)

/// @title TopicReaderBase — what the two topic readers share (design §5.13, §11)
/// @notice Immutable and stateless. The ledger and its two read facets are constructor immutables; the live index
///         is resolved per call from `ILedgerHot(ledger).index()` and never cached. Every list is read through the
///         index's own reads (`IIndexReads.postingHeadOf`/`postingSliceOf`, which carry the list's coverage) or the
///         bitmap store's scope reads, every ledger fact through a facet (`LedgerViews.bindingCells`,
///         `authorHeads`, `headsAt`; `LedgerReads.basis`, `admission`, `recordHeader`); the readers never read raw
///         slots. Principal-id APIs only, never `msg.sender`.
/// @dev Faults are named reverts, never fabricated rows: `E_TOPIC_READ` (a dependency failed), `E_TOPIC_REPLY` (a
///      short reply or a zero enum), `E_TOPIC_STATUS` (a per-row status the page cannot carry) and
///      `E_TOPIC_INCONSISTENT(code)`: 1 a list head out of range (live > count, an entry past the admissions, a
///      count without a last entry or the reverse), 2 list entries not strictly increasing, out of range or a slice
///      of the wrong length, 3 a list entry whose binding or cell is not of the list (absent, another purpose,
///      subject or role), 4 a head reply that contradicts itself or the list entry (status against state, the
///      first touch, the lens length, the binding ordinal, an author row of another binding), 5 a reply's echoed
///      basis differs from the page's, 6 a coverage reply out of range (a frontier past the admissions, COMPLETE
///      short of them), 7 a scope head out of range (live > count, a mutation in the future, live bits against
///      the live count), 8 a registration entry that is not the first publication of a record of the list's Type.
///      A reply the ABI decoder refuses (a malformed dynamic part) reverts without data; no fault is read as an
///      empty list or as a yes.
abstract contract TopicReaderBase is IReader {
    uint8 internal constant SCAN_EXHAUSTED = 1;
    uint8 internal constant SCAN_LIMIT = 2;
    uint8 internal constant SCAN_GAS = 3;
    uint256 internal constant MAX_PRINCIPALS = 64;
    /// The facets' batch bound (`limits.maxReadIds` of the release profile is 64): windows never exceed it.
    uint256 internal constant WINDOW = 16;
    uint256 internal constant SELECTED_NONE = 255;
    /// A lower bound on one returned row's gas, so a row array is sized by what the call can pay for.
    uint256 internal constant ROW_GAS_FLOOR = 15_000;
    uint256 internal constant CONTINUATION_VERSION = 1;
    bytes32 internal constant PHYSICAL_PROFILE =
        keccak256("efs/index-layout/1:stores:inline-singleton:five-u48:live-bits-in-head");
    bytes32 internal constant CALLBACK_PROFILE =
        keccak256("efs/index-callback/4:ordered-prefix:static-final:effect-24:refs");
    bytes32 internal constant F_PLACE = keccak256("efs/family/place/1");
    bytes32 internal constant F_PLACE_BELOW = keccak256("efs/family/place-below/1");
    bytes32 internal constant F_SCOPE_BELOW = keccak256("efs/family/scope-below/1");
    bytes32 internal constant F_POSITION_AUTHORS = keccak256("efs/family/position-authors/1");
    bytes32 internal constant F_ROLE_PLACES = keccak256("efs/family/role-places/1");
    bytes32 internal constant F_REFERENCE = keccak256("efs/family/reference-position/1");
    bytes32 internal constant F_LIVE_SCOPE = keccak256("efs/family/live-scope/1");

    address public immutable LEDGER;
    address public immutable VIEWS;
    address public immutable READS;
    bytes32 public immutable LAYOUT;

    /// One call's basis and index.
    struct Run {
        BasisCommit observed;
        address index;
        bytes32 queryHash;
        uint64 origin;
        uint64 selected;
        bool resumed;
    }

    /// One append-only list read newest first: entries below `hi` are unread.
    struct List {
        bytes32 family;
        bytes32 typeId;
        uint8 ordinal;
        bytes32 value;
        uint64 count;
        uint64 live;
        uint64 hi;
    }

    constructor(address ledger_, address views_, address reads_) {
        if (ledger_ == address(0) || views_ == address(0) || reads_ == address(0)) {
            revert E_TOPIC_READ(address(0), 0);
        }
        LEDGER = ledger_;
        VIEWS = views_;
        READS = reads_;
        LAYOUT = ILedgerHot(ledger_).layoutId();
    }

    /// @inheritdoc IReader
    function ledger() external view returns (address) {
        return LEDGER;
    }

    /// @inheritdoc IReader
    function layoutId() external view returns (bytes32) {
        return LAYOUT;
    }

    /// @inheritdoc IReader
    function supportedProfiles()
        external
        pure
        returns (bytes32[] memory callbackProfiles, bytes32[] memory physicalProfiles)
    {
        callbackProfiles = new bytes32[](1);
        callbackProfiles[0] = CALLBACK_PROFILE;
        physicalProfiles = new bytes32[](1);
        physicalProfiles[0] = PHYSICAL_PROFILE;
    }

    // =============================================================================================
    // Opening a call: the basis, the layout, the lens bound, the expected basis, the index profile, the cursor
    // =============================================================================================

    /// `lens` is the lens length and `needLens` whether an empty lens is INVALID; `cursorLength` the continuation's
    /// cursor words (its lists). The cursor is returned as decoded (empty when the page starts at the origin).
    function _open(
        Run memory r,
        BasisCommit calldata expected,
        uint256 lens,
        bool needLens,
        bytes calldata continuation,
        uint256 cursorLength,
        TopicPageInfo memory info
    ) internal view returns (Status st, uint64[] memory cursor) {
        r.observed = _basis();
        info.q.observed = r.observed;
        info.listingCoverage = Coverage.UNKNOWN;
        info.startsAtOrigin = continuation.length == 0;
        r.origin = r.observed.admissionHighWater;
        st = _gate(r, expected, lens, needLens);
        if (st == Status.PRESENT && continuation.length != 0) {
            (st, cursor) = _resume(r, continuation, cursorLength);
        }
    }

    function _basis() internal view returns (BasisCommit memory b) {
        bytes memory ret = _sc(READS, abi.encodeCall(ILedgerReads.basis, (LEDGER)), 192);
        b = abi.decode(ret, (BasisCommit));
    }

    function _gate(Run memory r, BasisCommit calldata expected, uint256 lens, bool needLens)
        internal
        view
        returns (Status)
    {
        (bool ok, bytes memory ret) = LEDGER.staticcall(abi.encodeCall(ILedgerHot.layoutId, ()));
        if (!ok || ret.length < 32 || abi.decode(ret, (bytes32)) != LAYOUT) {
            return Status.UNSUPPORTED;
        }
        if (needLens && lens == 0) return Status.INVALID;
        if (lens > MAX_PRINCIPALS) return Status.LIMIT_EXCEEDED;
        if (
            expected.executionSet != 0
                && (expected.executionSet != r.observed.executionSet
                    || expected.indexGeneration != r.observed.indexGeneration)
        ) return Status.BASIS_STALE;
        r.index = abi.decode(_sc(LEDGER, abi.encodeCall(ILedgerHot.index, ()), 32), (address));
        if (
            _profile(r.index, bytes4(keccak256("PHYSICAL_PROFILE()"))) != PHYSICAL_PROFILE
                || _profile(r.index, bytes4(keccak256("CALLBACK_PROFILE()"))) != CALLBACK_PROFILE
        ) return Status.UNSUPPORTED;
        return Status.PRESENT;
    }

    function _profile(address index, bytes4 selector) private view returns (bytes32 p) {
        (bool ok, bytes memory ret) = index.staticcall(abi.encodeWithSelector(selector));
        if (ok && ret.length >= 32) p = abi.decode(ret, (bytes32));
    }

    /// A continuation is `abi.encode(version, queryHash, executionSet, indexGeneration, origin, selectedSoFar,
    /// uint64[] cursor)`: INVALID when malformed or for another query, BASIS_STALE when minted under another basis.
    function _resume(Run memory r, bytes calldata c, uint256 cursorLength)
        private
        pure
        returns (Status, uint64[] memory cursor)
    {
        if (c.length != 32 * (8 + cursorLength)) return (Status.INVALID, cursor);
        (
            uint256 version,
            bytes32 queryHash,
            bytes32 executionSet,
            uint256 indexGeneration,
            uint256 origin,
            uint256 selected,
            uint256 offset,
            uint256 length
        ) = abi.decode(
            c[:256], (uint256, bytes32, bytes32, uint256, uint256, uint256, uint256, uint256)
        );
        if (
            version != CONTINUATION_VERSION || queryHash != r.queryHash || offset != 224
                || length != cursorLength || origin > r.observed.admissionHighWater
                || selected >= 1 << 64
        ) return (Status.INVALID, cursor);
        if (
            executionSet != r.observed.executionSet || indexGeneration != r.observed.indexGeneration
        ) return (Status.BASIS_STALE, cursor);
        cursor = new uint64[](cursorLength);
        for (uint256 i; i < cursorLength; ++i) {
            uint256 v = uint256(bytes32(c[256 + 32 * i:288 + 32 * i]));
            if (v >= 1 << 64) return (Status.INVALID, cursor);
            cursor[i] = uint64(v);
        }
        r.origin = uint64(origin);
        r.selected = uint64(selected);
        r.resumed = true;
        return (Status.PRESENT, cursor);
    }

    /// Fills the page laws once the scan ran: the status, the coverage, the continuation.
    function _finish(
        Run memory r,
        TopicPageInfo memory info,
        uint8 scan,
        Coverage cov,
        uint64[] memory cursor
    ) internal pure {
        info.q.status = Status.PRESENT;
        info.scanStatus = scan;
        info.selectedSoFar = r.selected;
        info.completeFromOrigin =
            info.startsAtOrigin && scan == SCAN_EXHAUSTED && cov == Coverage.COMPLETE;
        info.listingCoverage = info.completeFromOrigin
            ? Coverage.COMPLETE
            : cov == Coverage.UNKNOWN ? Coverage.UNKNOWN : Coverage.PARTIAL;
        if (scan != SCAN_EXHAUSTED) {
            info.next = abi.encode(
                CONTINUATION_VERSION,
                r.queryHash,
                r.observed.executionSet,
                r.observed.indexGeneration,
                r.origin,
                r.selected,
                cursor
            );
        }
    }

    function _join(Coverage a, Coverage b) internal pure returns (Coverage) {
        if (a == Coverage.UNKNOWN || b == Coverage.UNKNOWN) return Coverage.UNKNOWN;
        if (a == Coverage.PARTIAL || b == Coverage.PARTIAL) return Coverage.PARTIAL;
        return Coverage.COMPLETE;
    }

    /// The rows a page can hold: `limit` (0 = no row limit), the entries left and what the call can pay for.
    function _capacity(uint256 limit, uint256 left) internal view returns (uint256 n) {
        n = left;
        if (limit != 0 && limit < n) n = limit;
        uint256 g = gasleft() / ROW_GAS_FLOOR;
        if (g < n) n = g;
    }

    // =============================================================================================
    // Lists
    // =============================================================================================

    /// Reads a list's head into `l` (count, live) and returns its coverage; `l.hi` is set to the count.
    function _listHead(Run memory r, List memory l) internal view returns (Coverage c) {
        bytes memory ret = _sc(
            r.index,
            abi.encodeCall(
                IIndexReads.postingHeadOf,
                (FamilyId.wrap(l.family), TypeId.wrap(l.typeId), l.ordinal, l.value)
            ),
            160
        );
        uint64 last;
        (c, l.count, l.live, last,) = abi.decode(ret, (Coverage, uint64, uint64, uint64, bool));
        if (c == Coverage.UNSET) revert E_TOPIC_REPLY(IIndexReads.postingHeadOf.selector, 0);
        uint64 hw = r.observed.admissionHighWater;
        if (l.live > l.count || l.count > hw || last > hw || (l.count == 0) != (last == 0)) {
            revert E_TOPIC_INCONSISTENT(1);
        }
        l.hi = l.count;
    }

    /// The `n` entries of `l` just below `hi`, ascending: `[hi - n, hi)`.
    function _below(Run memory r, List memory l, uint64 hi, uint64 n)
        internal
        view
        returns (uint64[] memory e)
    {
        bytes memory ret = _sc(
            r.index,
            abi.encodeCall(
                IIndexReads.postingSliceOf,
                (
                    FamilyId.wrap(l.family),
                    TypeId.wrap(l.typeId),
                    l.ordinal,
                    l.value,
                    hi - n,
                    uint16(n)
                )
            ),
            128
        );
        Coverage c;
        (c, e,) = abi.decode(ret, (Coverage, uint64[], bool));
        if (c == Coverage.UNSET) revert E_TOPIC_REPLY(IIndexReads.postingSliceOf.selector, 0);
        _ascending(r, e, n);
    }

    /// `e` has `n` entries, strictly increasing, nonzero and at most the admission high water.
    function _ascending(Run memory r, uint64[] memory e, uint256 n) internal pure {
        if (e.length != n) revert E_TOPIC_INCONSISTENT(2);
        uint64 prev = 0;
        for (uint256 i; i < n; ++i) {
            if (e[i] <= prev) revert E_TOPIC_INCONSISTENT(2);
            prev = e[i];
        }
        if (prev > r.observed.admissionHighWater) revert E_TOPIC_INCONSISTENT(2);
    }

    // =============================================================================================
    // Facet reads
    // =============================================================================================

    /// Binding ordinal → position and cell, every entry PRESENT.
    function _cells(Run memory r, uint64[] memory ordinals)
        internal
        view
        returns (bytes32[] memory positions, Coordinate[] memory cells)
    {
        bytes memory ret =
            _sc(VIEWS, abi.encodeCall(ILedgerViews.bindingCells, (LEDGER, ordinals)), 288);
        Status[] memory st;
        BasisCommit memory b;
        (st, positions, cells, b) =
            abi.decode(ret, (Status[], bytes32[], Coordinate[], BasisCommit));
        _echo(r, b);
        uint256 n = ordinals.length;
        if (st.length != n || positions.length != n || cells.length != n) {
            revert E_TOPIC_INCONSISTENT(3);
        }
        for (uint256 i; i < n; ++i) {
            _rowStatus(st[i], Status.ABSENT_PROVEN, 3);
            if (st[i] != Status.PRESENT) revert E_TOPIC_STATUS(uint8(st[i]));
        }
    }

    /// Admission ordinal → author and head at `position`: every entry PRESENT, MASKED or RELEASED, and its head
    /// in the matching state.
    function _authors(Run memory r, bytes32 position, uint64[] memory admissions)
        internal
        view
        returns (Status[] memory st, bytes32[] memory principals, Head[] memory hs)
    {
        bytes memory ret = _sc(
            VIEWS, abi.encodeCall(ILedgerViews.authorHeads, (LEDGER, position, admissions)), 288
        );
        BasisCommit memory b;
        (st, principals, hs, b) = abi.decode(ret, (Status[], bytes32[], Head[], BasisCommit));
        _echo(r, b);
        uint256 n = admissions.length;
        if (st.length != n || principals.length != n || hs.length != n) {
            revert E_TOPIC_INCONSISTENT(4);
        }
        for (uint256 i; i < n; ++i) {
            Status s = st[i];
            _rowStatus(s, Status.ABSENT_PROVEN, 4);
            _rowStatus(s, Status.INVALID, 4);
            if (s != Status.PRESENT && s != Status.MASKED && s != Status.RELEASED) {
                revert E_TOPIC_STATUS(uint8(s));
            }
            _headState(r, s, hs[i]);
        }
    }

    /// The ordered first touch over `lens` at `position` (`LedgerViews.headsAt`), checked against itself: the
    /// status, the selected index (255 when nobody has a stance) and every head of the lens.
    function _headsAt(Run memory r, bytes32[] calldata lens, bytes32 position)
        internal
        view
        returns (Status st, uint256 selected, Head[] memory all)
    {
        bytes memory ret =
            _sc(VIEWS, abi.encodeCall(ILedgerViews.headsAt, (LEDGER, lens, position)), 576);
        Head memory sel;
        BasisCommit memory b;
        uint8 index;
        (st, sel, index, all, b) = abi.decode(ret, (Status, Head, uint8, Head[], BasisCommit));
        _echo(r, b);
        _rowStatus(st, Status.UNSET, 4);
        if (st != Status.PRESENT && st != Status.MASKED && st != Status.ABSENT_PROVEN) {
            revert E_TOPIC_STATUS(uint8(st));
        }
        selected = index;
        bool none = selected == SELECTED_NONE;
        if (all.length != lens.length || none != (st == Status.ABSENT_PROVEN)) {
            revert E_TOPIC_INCONSISTENT(4);
        }
        uint256 end = none ? all.length : selected;
        for (uint256 k; k < end; ++k) {
            uint8 s = all[k].state;
            if (s == 1 || s == 2 || s > 3) revert E_TOPIC_INCONSISTENT(4); // not the first touch
        }
        if (!none) {
            if (
                selected >= all.length
                    || keccak256(abi.encode(all[selected])) != keccak256(abi.encode(sel))
            ) {
                revert E_TOPIC_INCONSISTENT(4);
            }
            _headState(r, st, sel);
        }
    }

    /// A head in the state its status names (PRESENT 1, MASKED 2, RELEASED 3), a canonical target and an
    /// admission the page has observed.
    function _headState(Run memory r, Status s, Head memory h) internal pure {
        uint8 want = s == Status.PRESENT ? 1 : s == Status.MASKED ? 2 : 3;
        if (
            h.state != want || (want != 1 && h.target != 0) || h.admission == 0
                || h.admission > r.observed.admissionHighWater
        ) revert E_TOPIC_INCONSISTENT(4);
    }

    /// UNSET is a transport fault; `bad` is the inconsistency `code`.
    function _rowStatus(Status s, Status bad, uint8 code) internal pure {
        if (s == Status.UNSET) revert E_TOPIC_REPLY(0, 0);
        if (s == bad) revert E_TOPIC_INCONSISTENT(code);
    }

    /// A facet reply's echoed basis is the page's (the execution set and the admission high water).
    function _echo(Run memory r, BasisCommit memory b) internal pure {
        if (
            b.executionSet != r.observed.executionSet
                || b.admissionHighWater != r.observed.admissionHighWater
        ) revert E_TOPIC_INCONSISTENT(5);
    }

    // ---- raw calls ------------------------------------------------------------------------------------------

    /// A staticcall that names the dependency and selector when it fails, and the selector when the reply is
    /// shorter than `min` bytes.
    function _sc(address target, bytes memory data, uint256 min)
        internal
        view
        returns (bytes memory ret)
    {
        bool ok;
        (ok, ret) = target.staticcall(data);
        bytes4 selector;
        assembly ("memory-safe") {
            selector := mload(add(data, 32))
        }
        if (!ok) revert E_TOPIC_READ(target, selector);
        if (ret.length < min) revert E_TOPIC_REPLY(selector, ret.length);
    }
}

// forge-lint: disable-end(require-revert-in-loop)
// forge-lint: disable-end(calls-loop)
// forge-lint: disable-end(unsafe-typecast)
