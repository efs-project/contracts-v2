// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Coordinate, FamilyId, Purpose, TypeId} from "../interfaces/Actions.sol";
import {IIndexReads} from "../interfaces/IIndexReads.sol";
import {ILedgerHot} from "../interfaces/ILedgerHot.sol";
import {ILedgerReads} from "../interfaces/ILedgerReads.sol";
import {ILedgerViews} from "../interfaces/ILedgerViews.sol";
import {IReader, PlaceRow, TopicPageInfo} from "../interfaces/Readers.sol";
import {BasisCommit, Coverage, Status} from "../interfaces/Results.sol";
import {Head} from "../interfaces/Views.sol";
import {Keys} from "../lib/Keys.sol";

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

/// @title TopicReaderBase — what the three topic readers share (design §5.13, §11)
/// @notice Immutable and stateless. The ledger and its two read facets are constructor immutables; the live index
///         is resolved per call from `ILedgerHot(ledger).index()` and never cached. Every list is read through the
///         index's own reads (`IIndexReads.postingHeadOf`/`postingSliceOf`, which carry the list's coverage) or the
///         bitmap store's scope reads, every ledger fact through a facet (`LedgerViews.bindingCells`, `lensRule`,
///         `authorHeads`, `headStates`; `LedgerReads.basis`, `admission`, `recordHeader`); the readers never read
///         raw slots. Principal-id APIs only, never `msg.sender`.
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
    uint8 internal constant SCAN_ROWS = 4;
    uint256 internal constant MAX_PRINCIPALS = 64;
    /// The facets' batch bound (`limits.maxReadIds` of the release profile is 64): windows never exceed it.
    uint256 internal constant WINDOW = 16;
    /// The keys of one `LedgerViews.heads` call (the release profile's `limits.maxReadIds`).
    uint256 internal constant MAX_KEYS = 64;
    uint256 internal constant SELECTED_NONE = 255;
    /// Shortcut A of `_maskedAt` is read only for a candidate with at least this many lens authors left to ask: its
    /// one list-head read (about 8k cold) costs more than the state words it can save (about 2.4k each) below it.
    uint256 internal constant NOBODY_MIN_ASK = 4;
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
        /// Bit a: lens[a] is proven to hold no MASKED head at the viewed place (`_maskedAt` shortcut B; 0 unless the
        /// view sets it).
        uint256 quiet;
        /// The place a lens view reads (`TopicMineReader`; unused elsewhere).
        bytes32 place;
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
        uint64 last;
    }

    /// A checked `LedgerViews.lensRule` reply.
    struct Lensed {
        bytes32[] positions;
        Coordinate[] cells;
        uint8[] decider;
        uint8[] decided;
        uint16[] strength;
        Head[] own;
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

    /// Fills the page laws once the scan ran: the status, the coverage, the continuation. A served page's lists are
    /// all COMPLETE (`_served`), so its `listingCoverage` is about paging alone: COMPLETE when it started at the
    /// origin and finished, PARTIAL otherwise.
    function _finish(Run memory r, TopicPageInfo memory info, uint8 scan, uint64[] memory cursor)
        internal
        pure
    {
        info.q.status = Status.PRESENT;
        info.scanStatus = scan;
        info.selectedSoFar = r.selected;
        info.completeFromOrigin = info.startsAtOrigin && scan == SCAN_EXHAUSTED;
        info.listingCoverage = info.completeFromOrigin ? Coverage.COMPLETE : Coverage.PARTIAL;
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

    /// A refused page (any status but PRESENT): no rows (the caller returns none), coverage UNKNOWN, no counts, no
    /// frontier and no continuation, whatever lists were read before the refusal.
    function _refuse(TopicPageInfo memory info, Status st) internal pure {
        info.q.status = st;
        info.listingCoverage = Coverage.UNKNOWN;
        info.scanned = 0;
        info.frontier = 0;
        info.rawTotal = 0;
        info.positionsEver = 0;
        info.repeatsSkipped = 0;
    }

    /// The rule of list coverage (the page laws of `TopicPageInfo`): a list is answered from only when the index
    /// reports it COMPLETE; PARTIAL is treated exactly as UNKNOWN. Every list coverage a topic reader reads passes
    /// here (`_listHead`, the live-scope coverage of `TopicMineReader` and `TopicLookupReader.entryCount`), so the
    /// readers' coverages are COMPLETE or UNKNOWN and nothing downstream sees PARTIAL.
    function _served(Coverage c) internal pure returns (Coverage) {
        return c == Coverage.COMPLETE ? Coverage.COMPLETE : Coverage.UNKNOWN;
    }

    /// Two served coverages joined: COMPLETE only when both are.
    function _join(Coverage a, Coverage b) internal pure returns (Coverage) {
        return
            a == Coverage.COMPLETE && b == Coverage.COMPLETE ? Coverage.COMPLETE : Coverage.UNKNOWN;
    }

    /// The rows a page can hold: the entries left, `limit` and `maxRows` (0 = no bound) and what the call can pay
    /// for, but at least one while entries remain, so the first entry read can always be a row.
    function _capacity(uint256 limit, uint256 maxRows, uint256 left)
        internal
        view
        returns (uint256 n)
    {
        n = left;
        if (limit != 0 && limit < n) n = limit;
        if (maxRows != 0 && maxRows < n) n = maxRows;
        uint256 g = gasleft() / ROW_GAS_FLOOR;
        if (g < n) n = g == 0 ? 1 : g;
        if (left == 0) n = 0;
    }

    /// The stop before the next entry or batch, given that `scanned` entries were read on this page (0: none, and
    /// then nothing stops, so every page that is not refused reads at least one entry): 2 LIMIT (`limit` entries
    /// read), 4 ROWS (`maxRows` rows returned), 3 GAS (the reserve, or the row array full); 0 to go on.
    function _stop(
        uint256 scanned,
        uint256 got,
        uint256 room,
        uint32 limit,
        uint32 maxRows,
        uint256 gasReserve
    ) internal view returns (uint8) {
        if (scanned == 0) return 0;
        if (limit != 0 && scanned >= limit) return SCAN_LIMIT;
        if (maxRows != 0 && got >= maxRows) return SCAN_ROWS;
        if (got == room || gasleft() < gasReserve) return SCAN_GAS;
        return 0;
    }

    // =============================================================================================
    // Lists
    // =============================================================================================

    /// Reads a list's head into `l` (count, live) and returns its served coverage (`_served`: COMPLETE, or UNKNOWN for
    /// an index's UNKNOWN or PARTIAL); `l.hi` is set to the count.
    function _listHead(Run memory r, List memory l) internal view returns (Coverage c) {
        bytes memory ret = _sc(
            r.index,
            abi.encodeCall(
                IIndexReads.postingHeadOf,
                (FamilyId.wrap(l.family), TypeId.wrap(l.typeId), l.ordinal, l.value)
            ),
            160
        );
        (c, l.count, l.live, l.last,) = abi.decode(ret, (Coverage, uint64, uint64, uint64, bool));
        uint64 last = l.last;
        if (c == Coverage.UNSET) revert E_TOPIC_REPLY(IIndexReads.postingHeadOf.selector, 0);
        uint64 hw = r.observed.admissionHighWater;
        if (l.live > l.count || l.count > hw || last > hw || (l.count == 0) != (last == 0)) {
            revert E_TOPIC_INCONSISTENT(1);
        }
        l.hi = l.count;
        c = _served(c);
    }

    /// The `n` entries of `l` just below `hi`, ascending: `[hi - n, hi)`. The slice's coverage is checked only for
    /// UNSET: a list's coverage is its head's (`_listHead`), read first on every page.
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

    /// Binding ordinal → position and cell (`LedgerViews.bindingCells`), every entry PRESENT.
    function _cells(Run memory r, uint64[] memory ordinals)
        internal
        view
        returns (bytes32[] memory positions, Coordinate[] memory cells)
    {
        Status[] memory st;
        BasisCommit memory b;
        (st, positions, cells, b) = abi.decode(
            _sc(VIEWS, abi.encodeCall(ILedgerViews.bindingCells, (LEDGER, ordinals)), 288),
            (Status[], bytes32[], Coordinate[], BasisCommit)
        );
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

    /// A row's sample: the newest `sample` authors (at most 64) of `position` (`a` its author list, head read),
    /// who says >= 0 and who says < 0, and whether they are not every author.
    function _sample(
        Run memory r,
        uint16 sample,
        List memory a,
        bytes32 position,
        PlaceRow memory row
    ) internal view {
        uint64 n = sample > 64 ? 64 : sample;
        if (n > a.count) n = a.count;
        uint64[] memory adm = _below(r, a, a.count, n);
        (Status[] memory st,,) = _authors(r, position, adm);
        for (uint256 i; i < n; ++i) {
            if (st[i] == Status.PRESENT) ++row.sampleYes;
            else if (st[i] == Status.MASKED) ++row.sampleNo;
        }
        row.sampled = uint16(n);
        row.incomplete = a.count > n;
    }

    /// The lens rule over list entries (`LedgerViews.lensRule`), checked: every entry PRESENT, a decider at or
    /// before its author with a stance (or none), and the author's own head in a state that agrees with it.
    function _lensRule(
        Run memory r,
        bytes32[] memory lens,
        uint64[] memory ordinals,
        uint8[] memory authors
    ) internal view returns (Lensed memory x) {
        bytes memory ret = _sc(
            VIEWS, abi.encodeCall(ILedgerViews.lensRule, (LEDGER, lens, ordinals, authors)), 416
        );
        Status[] memory st;
        BasisCommit memory b;
        (st, x.positions, x.cells, x.decider, x.decided, x.strength, x.own, b) = abi.decode(
            ret,
            (Status[], bytes32[], Coordinate[], uint8[], uint8[], uint16[], Head[], BasisCommit)
        );
        _echo(r, b);
        uint256 n = ordinals.length;
        if (
            st.length != n || x.positions.length != n || x.cells.length != n
                || x.decider.length != n || x.decided.length != n || x.strength.length != n
                || x.own.length != n
        ) revert E_TOPIC_INCONSISTENT(3);
        for (uint256 i; i < n; ++i) {
            _rowStatus(st[i], Status.ABSENT_PROVEN, 3);
            if (st[i] != Status.PRESENT) revert E_TOPIC_STATUS(uint8(st[i]));
            Head memory h = x.own[i];
            uint8 d = x.decider[i];
            uint8 ds = x.decided[i];
            bool stance = h.state == 1 || h.state == 2;
            bool none = d == SELECTED_NONE;
            if (
                h.state > 3 || (h.state != 1 && h.target != 0)
                    || (h.state == 0) != (h.admission == 0)
                    || h.admission > r.observed.admissionHighWater || (!none && d > authors[i])
                    || none != (ds == 0) || (!none && ds != 1 && ds != 2) || (none && stance)
                    || (none && x.strength[i] != 0)
                    || (d == authors[i] && (ds != h.state || x.strength[i] != h.strength))
            ) revert E_TOPIC_INCONSISTENT(4);
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

    /// The states of at most `MAX_KEYS` heads (`LedgerViews.headStates`, one word per head): each a defined state (a
    /// reserved state is UNSUPPORTED), one per key, under the page's basis.
    function _states(Run memory r, bytes32[] memory keys)
        internal
        view
        returns (uint8[] memory st)
    {
        BasisCommit memory b;
        (st, b) = abi.decode(
            _sc(VIEWS, abi.encodeCall(ILedgerViews.headStates, (LEDGER, keys)), 256),
            (uint8[], BasisCommit)
        );
        _echo(r, b);
        if (st.length != keys.length) revert E_TOPIC_INCONSISTENT(4);
        for (uint256 i; i < st.length; ++i) {
            if (st[i] > 3) revert E_TOPIC_STATUS(uint8(Status.UNSUPPORTED));
        }
    }

    /// The viewed-place half of the combined lens walk (design §11): for each candidate i, the index of the first
    /// of `lens[0 .. ask[i])` whose head at the viewed position `(TAG, place, things[i])` is MASKED (a "not this" at
    /// the place being viewed), or SELECTED_NONE; `ask[i] == 0` asks nobody. Two shortcuts leave out heads that
    /// cannot be MASKED, so neither changes an answer:
    ///   - B: a lens author whose bit is set in `r.quiet` is never asked (`TopicMineReader` sets it from the author's
    ///     exact scope list at `place`, whose head it holds already; see there why such an author holds no MASKED
    ///     head at the place). 0 in the other views.
    ///   - A: before anyone is asked about candidate i (when at least NOBODY_MIN_ASK lens authors are left to ask),
    ///     the head of the viewed position's `position-authors` list (family 20, key = the position) is read. The
    ///     index appends to it at every author's first statement at the position, of either sign (FIRST_BIND or
    ///     FIRST_MASK, design §10.2; `count` never falls), and a head leaves UNSET only by a first statement (an
    ///     UNBIND of an UNSET head is a FIRST_MASK; a RELEASE of one is refused by the kernel), so with every
    ///     admission folded (coverage COMPLETE) a count of 0 means every head at the position is UNSET: nobody is
    ///     asked. Any other coverage (UNKNOWN or PARTIAL) asks as before: the
    ///     heads are the ledger's own and need no index, so a list the index cannot vouch for is never read as
    ///     "nobody".
    /// What is left is read as head states only (`_states`), in rounds of at most MAX_KEYS keys.
    function _maskedAt(
        Run memory r,
        bytes32[] memory lens,
        bytes32 place,
        bytes32[] memory things,
        uint256[] memory ask
    ) internal view returns (uint256[] memory kv) {
        uint256 n = things.length;
        kv = new uint256[](n);
        uint256[] memory upto = new uint256[](n);
        bytes32[] memory viewed = new bytes32[](n);
        uint256 total;
        for (uint256 i; i < n; ++i) {
            kv[i] = SELECTED_NONE;
            uint256 asked = ask[i] - _popcount(r.quiet & ((1 << ask[i]) - 1)); // B: the authors left to ask
            if (asked == 0) continue;
            viewed[i] = Keys.position(Purpose.TAG, place, things[i]);
            // A: nobody ever stated anything there (asked only where it can pay for itself)
            if (asked >= NOBODY_MIN_ASK && _nobodyAt(r, viewed[i])) continue;
            upto[i] = ask[i];
            total += asked;
        }
        if (total == 0) return kv;
        bytes32[] memory keys = new bytes32[](total);
        uint256 t;
        for (uint256 i; i < n; ++i) {
            for (uint256 a; a < upto[i]; ++a) {
                if ((r.quiet >> a) & 1 == 0) keys[t++] = Keys.binding(lens[a], viewed[i]);
            }
        }
        uint8[] memory st = _statesInRounds(r, keys);
        t = 0;
        for (uint256 i; i < n; ++i) {
            for (uint256 a; a < upto[i]; ++a) {
                if ((r.quiet >> a) & 1 != 0) continue;
                if (kv[i] == SELECTED_NONE && st[t] == 2) kv[i] = a;
                ++t;
            }
        }
    }

    /// Shortcut A of `_maskedAt`: the viewed position's `position-authors` head is empty under COMPLETE coverage.
    ///      The head is checked as `_listHead` checks it (UNSET coverage a reply fault, its counts in range).
    function _nobodyAt(Run memory r, bytes32 position) private view returns (bool) {
        bytes memory ret = _sc(
            r.index,
            abi.encodeCall(
                IIndexReads.postingHeadOf,
                (FamilyId.wrap(F_POSITION_AUTHORS), TypeId.wrap(0), 0, position)
            ),
            160
        );
        (Coverage c, uint64 count, uint64 live, uint64 last) =
            abi.decode(ret, (Coverage, uint64, uint64, uint64));
        if (c == Coverage.UNSET) revert E_TOPIC_REPLY(IIndexReads.postingHeadOf.selector, 0);
        uint64 hw = r.observed.admissionHighWater;
        if (live > count || count > hw || last > hw || (count == 0) != (last == 0)) {
            revert E_TOPIC_INCONSISTENT(1);
        }
        return c == Coverage.COMPLETE && count == 0;
    }

    /// `_states` over any number of keys, in rounds of at most MAX_KEYS.
    function _statesInRounds(Run memory r, bytes32[] memory keys)
        private
        view
        returns (uint8[] memory st)
    {
        uint256 total = keys.length;
        st = new uint8[](total);
        for (uint256 from; from < total; from += MAX_KEYS) {
            uint256 m = total - from < MAX_KEYS ? total - from : MAX_KEYS;
            bytes32[] memory chunk = new bytes32[](m);
            for (uint256 a; a < m; ++a) {
                chunk[a] = keys[from + a];
            }
            uint8[] memory got = _states(r, chunk);
            for (uint256 a; a < m; ++a) {
                st[from + a] = got[a];
            }
        }
    }

    /// The set bits of a word of at most 64 bits.
    function _popcount(uint256 x) internal pure returns (uint256 c) {
        for (; x != 0; x &= x - 1) {
            ++c;
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
