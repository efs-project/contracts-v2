// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Coordinate, FamilyId, Purpose, ScopeKey} from "../interfaces/Actions.sol";
import {BindingNumber} from "../interfaces/Actions.sol";
import {IBitmapStore} from "../interfaces/IBitmapStore.sol";
import {IIndexReads} from "../interfaces/IIndexReads.sol";
import {ITopicPageReader, MineRow, PlaceRow, TopicPageInfo} from "../interfaces/Readers.sol";
import {BasisCommit, Coverage, Status} from "../interfaces/Results.sol";
import {Head} from "../interfaces/Views.sol";
import {Keys} from "../lib/Keys.sol";
import {E_TOPIC_INCONSISTENT, TopicReaderBase} from "./TopicReaderBase.sol";

// Narrowing casts are list indices, lens indices (< 64) and sample sizes (≤ 64); the views make a bounded set of
// calls per list entry, stopped by `limit` and `gasReserve`; `e / 256 * 256` is a bitmap word's first entry.
// forge-lint: disable-start(unsafe-typecast)
// forge-lint: disable-start(calls-loop)
// forge-lint: disable-start(require-revert-in-loop)
// forge-lint: disable-start(divide-before-multiply)

/// @title TopicPageReader/1 — the lens and public views of a place (design §5.13, §11; docs/TAG-DESIGN.md §6)
/// @notice A place is a topic or a home. Three views, every list newest first (most recently first-stated):
///
///         `mine(lens, place, below)`: lens = ordered principals (1..64). Merges, newest first by binding ordinal,
///         each lens author's exact scope list `Keys.scope(author, TAG, place)` (family 10, in the bitmap store; an
///         entry whose live bit is clear is never shown and costs no head read) and, with `below`, the author's
///         roll-up `Keys.scopeBelowList(author, TAG, place)` (family 19). The lens rule decides each candidate: the
///         first lens author with a stance at the position decides; a number >= 0 shows the row with that number,
///         a negative hides it. A candidate from author j reads only the heads of lens[0..j] (one `headsAt`): a
///         row is produced only by the deciding author's own entry, so each (topic filed under, thing) appears once
///         in a listing read at one block, and none is shown twice within a page. Heads are read at each page's
///         own block, so a stance changed between pages can move a row: a caller removes repeats across pages by
///         `position` (`dedupWithinPageOnly`). Calls per row: one `bindingCells`, one `headsAt` of j + 1 heads.
///
///         `everyone(query, lens)`: the place list `Keys.placeList(purpose, place)` (family 6; TAG or FOLDER) or,
///         with `below` (TAG), the roll-up `Keys.placeBelowList(TAG, place)` (family 7). A position can be listed
///         more than once (the first statement at a fresh position and every later author's first yes): the newest
///         occurrence is kept and later ones on the page are skipped (`repeatsSkipped`); a caller removes repeats
///         across pages (`dedupWithinPageOnly`). Per row one head read of the position's authors
///         (`Keys.positionAuthorsList`, family 20): `statements` = its count, `yes` = its live count (the authors
///         who say yes now). A row nobody says yes to (`yes == 0`) is left out; `raw` returns it. A row is hidden
///         only by a lens author: when the lens rule (`headsAt`, the first lens author with a stance) decides a
///         negative at the position the entry was filed under or, below, at the same thing in the viewed place
///         (`(TAG, place, thing)`); a denial does not travel down to child topics, and a denial of a child topic
///         says nothing about the place. A stranger's statements never hide a row, and no row is hidden or dropped
///         because a scan stopped early: no scan decides a row. `raw` skips the lens. With `sample` > 0 the newest
///         `sample` authors (at most 64) are read through `LedgerViews.authorHeads` as detail: how many say >= 0,
///         how many < 0, and `incomplete` when they are not every author.
///
///         `about(thing, lens)`: every place anyone filed `thing` under at TAG, either sign (`Keys.rolePlacesList`,
///         family 21), newest first, with the row of `everyone`; rows nobody says yes to are returned; the lens
///         hides at the filed position (nothing with `raw`).
///
///         Page laws as `TopicPageInfo` states them: a Realm whose index keeps no topic roll-ups (families 7 and 19
///         `NOT_MAINTAINED`) answers a below view UNKNOWN with no rows, never empty; any list or author head of
///         UNKNOWN coverage makes the page UNKNOWN. `limit` 0 means no row limit; `gasReserve` is checked before
///         each list entry and must cover one row and the return encoding (scan status 3 GAS, with a continuation).
contract TopicPageReader is TopicReaderBase, ITopicPageReader {
    bytes32 internal constant DOM_QUERY = keccak256("efs/topic-page/query/1");
    uint8 internal constant VIEW_MINE = 1;
    uint8 internal constant VIEW_EVERYONE = 2;
    uint8 internal constant VIEW_ABOUT = 3;

    /// One lens author's list in `mine`: its exact scope list (bitmap store) or its roll-up (posting list), and a
    /// window of entries `[lo, lo + win.length)` read ascending; entries below `l.hi` are unread.
    struct Src {
        bool exact;
        bytes32 key;
        uint64 lo;
        uint64[] win;
        uint256 bits;
        List l;
    }

    /// The working state of one `everyone`/`about` page.
    struct Place {
        uint8 view_;
        bytes32 purpose;
        bytes32 place;
        bool raw;
        uint16 sample;
        bytes32[] seen;
        uint256 seenCount;
    }

    /// @param ledger_ the ledger proxy this reader serves (its layout is pinned here: `layoutId()`)
    /// @param views_ the `LedgerViews` facet (`bindingCells`, `authorHeads`, `headsAt`)
    /// @param reads_ the `LedgerReads` facet (`basis`)
    constructor(address ledger_, address views_, address reads_)
        TopicReaderBase(ledger_, views_, reads_)
    {}

    // =============================================================================================
    // mine
    // =============================================================================================

    /// @inheritdoc ITopicPageReader
    function mine(
        bytes32[] calldata lens,
        bytes32 place,
        bool below,
        BasisCommit calldata expected,
        bytes calldata continuation,
        uint32 limit,
        uint256 gasReserve
    ) external view returns (TopicPageInfo memory info, MineRow[] memory rows) {
        Run memory r;
        r.queryHash = keccak256(abi.encode(DOM_QUERY, LEDGER, VIEW_MINE, lens, place, below));
        uint256 n = below ? 2 * lens.length : lens.length;
        (Status st, uint64[] memory cursor) =
            _open(r, expected, lens.length, true, continuation, n, info);
        info.dedupWithinPageOnly = true;
        Src[] memory s;
        Coverage cov;
        uint256 left;
        if (st == Status.PRESENT) {
            (st, s, cov, left) = _sources(r, lens, place, below, cursor, info);
        }
        if (st != Status.PRESENT) {
            info.q.status = st;
            return (info, rows);
        }
        uint256 cap = _capacity(limit, left);
        assembly ("memory-safe") {
            rows := mload(0x40)
            mstore(rows, cap)
            mstore(0x40, add(rows, mul(add(cap, 1), 32)))
        }
        (uint8 scan, uint256 got) = _merge(r, s, lens, place, rows, limit, gasReserve, info);
        assembly ("memory-safe") {
            mstore(rows, got)
        }
        cursor = new uint64[](n);
        for (uint256 i; i < n; ++i) {
            cursor[i] = s[i].l.hi;
        }
        _finish(r, info, scan, cov, cursor);
    }

    /// Every lens author's lists: their heads, coverage and the cursor's resume points.
    function _sources(
        Run memory r,
        bytes32[] calldata lens,
        bytes32 place,
        bool below,
        uint64[] memory cursor,
        TopicPageInfo memory info
    ) private view returns (Status, Src[] memory s, Coverage cov, uint256 left) {
        uint256 len = lens.length;
        s = new Src[](below ? 2 * len : len);
        cov = Coverage.COMPLETE;
        address store =
            abi.decode(_sc(r.index, abi.encodeCall(IIndexReads.bitmapStore, ()), 32), (address));
        for (uint256 i; i < s.length; ++i) {
            Src memory x = s[i];
            bytes32 author = lens[i % len];
            Coverage c;
            if (i < len) {
                x.exact = true;
                x.key = Keys.scope(author, Purpose.TAG, place);
                c = _scope(r, store, x);
            } else {
                x.l =
                    List(F_SCOPE_BELOW, 0, 0, Keys.scopeBelow(author, Purpose.TAG, place), 0, 0, 0);
                c = _listHead(r, x.l);
            }
            cov = _join(cov, c);
            info.rawTotal += x.l.count;
            if (r.resumed) {
                if (cursor[i] > x.l.count) return (Status.INVALID, s, cov, 0);
                x.l.hi = cursor[i];
            }
            x.lo = x.l.hi; // no window yet
            left += x.l.hi;
        }
        if (cov == Coverage.UNKNOWN) return (Status.UNKNOWN, s, cov, 0);
        return (Status.PRESENT, s, cov, left);
    }

    /// An exact scope list's head and its live-scope coverage.
    function _scope(Run memory r, address store, Src memory x) private view returns (Coverage c) {
        bytes memory ret =
            _sc(store, abi.encodeCall(IBitmapStore.scopeHead, (ScopeKey.wrap(x.key))), 192);
        (uint64 count, uint64 live, uint64 lastMutation,,,) =
            abi.decode(ret, (uint64, uint64, uint64, uint48, uint16, uint64));
        if (live > count || lastMutation > r.observed.admissionHighWater) {
            revert E_TOPIC_INCONSISTENT(7);
        }
        x.l.family = F_LIVE_SCOPE;
        x.l.value = bytes32(uint256(uint160(store))); // the store, for refills
        x.l.count = count;
        x.l.live = live;
        x.l.hi = count;
        ret = _sc(
            r.index,
            abi.encodeCall(
                IIndexReads.coverage, (FamilyId.wrap(F_LIVE_SCOPE), ScopeKey.wrap(x.key))
            ),
            128
        );
        uint64 through;
        (c,, through,) = abi.decode(ret, (Coverage, uint64, uint64, uint8));
        _coverageCheck(r, c, through);
    }

    function _coverageCheck(Run memory r, Coverage c, uint64 through) private pure {
        if (c == Coverage.UNSET) revert E_TOPIC_INCONSISTENT(6);
        if (
            through > r.observed.admissionHighWater
                || (c == Coverage.COMPLETE && through != r.observed.admissionHighWater)
        ) revert E_TOPIC_INCONSISTENT(6);
    }

    /// The newest-first merge of every lens list; leaves each list's `hi` at its first unexamined entry.
    function _merge(
        Run memory r,
        Src[] memory s,
        bytes32[] calldata lens,
        bytes32 place,
        MineRow[] memory rows,
        uint32 limit,
        uint256 gasReserve,
        TopicPageInfo memory info
    ) private view returns (uint8, uint256 got) {
        MineRow memory row; // reused by candidates that produce no row
        for (;;) {
            uint256 best = type(uint256).max;
            uint64 bestOrd;
            for (uint256 i; i < s.length; ++i) {
                Src memory x = s[i];
                if (x.l.hi == 0) continue;
                if (x.l.hi == x.lo) _refill(r, x);
                uint64 o = x.win[x.l.hi - 1 - x.lo];
                if (o > bestOrd) {
                    bestOrd = o;
                    best = i;
                }
            }
            if (best == type(uint256).max) return (SCAN_EXHAUSTED, got);
            // a stop leaves the cursor at this candidate (a refill reads, it never consumes)
            if (limit != 0 && got == limit) return (SCAN_LIMIT, got);
            if (got == rows.length || gasleft() < gasReserve) return (SCAN_GAS, got);
            Src memory b = s[best];
            uint64 idx = --b.l.hi;
            ++info.scanned;
            bool live = !b.exact || (b.bits >> (idx % 256)) & 1 == 1;
            if (!live) continue; // a masked or released own entry is never shown
            if (_candidate(r, lens, best % lens.length, b.exact, place, bestOrd, row)) {
                rows[got] = row;
                ++got;
                ++r.selected;
                row = _freshMine();
            }
        }
        return (SCAN_EXHAUSTED, got); // unreachable: the loop returns
    }

    function _freshMine() private pure returns (MineRow memory row) {}

    function _freshPlace() private pure returns (PlaceRow memory row) {}

    /// The window just below `hi`: up to WINDOW entries (an exact list's window stays inside one bitmap word, whose
    /// live bits are read with it). Entries must strictly decrease from the previous window.
    function _refill(Run memory r, Src memory x) private view {
        uint64 hi = x.l.hi;
        uint64 lo = hi > WINDOW ? hi - uint64(WINDOW) : 0;
        uint64 prev = x.win.length != 0 ? x.win[0] : type(uint64).max;
        if (x.exact) {
            uint64 word = (hi - 1) / 256;
            if (lo < word * 256) lo = word * 256;
            address store = address(uint160(uint256(x.l.value)));
            bytes memory ret = _sc(
                store,
                abi.encodeCall(
                    IBitmapStore.scopeSlice, (ScopeKey.wrap(x.key), lo, uint16(hi - lo))
                ),
                64
            );
            x.win = abi.decode(ret, (uint64[]));
            _ascending(r, x.win, hi - lo);
            ret = _sc(
                store,
                abi.encodeCall(
                    IBitmapStore.liveWords,
                    (ScopeKey.wrap(x.key), FamilyId.wrap(F_LIVE_SCOPE), word, uint16(1))
                ),
                96
            );
            uint256[] memory w = abi.decode(ret, (uint256[]));
            if (w.length != 1) revert E_TOPIC_INCONSISTENT(7);
            x.bits = w[0];
        } else {
            x.win = _below(r, x.l, hi, hi - lo);
        }
        if (x.win[x.win.length - 1] >= prev) revert E_TOPIC_INCONSISTENT(2);
        x.lo = lo;
    }

    /// One candidate of lens author `j` (entry `ordinal`): its cell, then the lens rule over lens[0..j].
    function _candidate(
        Run memory r,
        bytes32[] calldata lens,
        uint256 j,
        bool exact,
        bytes32 place,
        uint64 ordinal,
        MineRow memory row
    ) private view returns (bool) {
        uint64[] memory one = new uint64[](1);
        one[0] = ordinal;
        (bytes32[] memory positions, Coordinate[] memory cells) = _cells(r, one);
        Coordinate memory c = cells[0];
        // an exact entry is filed at the place; a roll-up entry under a proper descendant of it
        if (c.purpose != Purpose.TAG || (c.subject == place) != exact) {
            revert E_TOPIC_INCONSISTENT(3);
        }
        (Status st, uint256 sel, Head[] memory all) = _headsAt(r, lens[:j + 1], positions[0]);
        Head memory own = all[j];
        if (own.state == 0 || own.bindingOrdinal != ordinal || (exact && own.state != 1)) {
            revert E_TOPIC_INCONSISTENT(4); // the entry is the author's binding; a live bit means BOUND
        }
        if (st != Status.PRESENT || sel != j) return false; // decided by a higher author, hidden, or released
        (, int32 number) = BindingNumber.numberOf(own.state, own.strength);
        row.position = positions[0];
        row.topic = c.subject;
        row.thing = c.role;
        row.targetKind = own.targetKind;
        row.decider = uint8(j);
        row.principalId = lens[j];
        row.number = number;
        row.revision = own.revision;
        row.admission = own.admission;
        row.bindingOrdinal = ordinal;
        return true;
    }

    // =============================================================================================
    // everyone, raw, about
    // =============================================================================================

    /// @inheritdoc ITopicPageReader
    function everyone(
        PlaceQuery calldata query,
        bytes32[] calldata lens,
        BasisCommit calldata expected,
        bytes calldata continuation,
        uint32 limit,
        uint256 gasReserve
    ) external view returns (TopicPageInfo memory info, PlaceRow[] memory rows) {
        Run memory r;
        r.queryHash = keccak256(abi.encode(DOM_QUERY, LEDGER, VIEW_EVERYONE, query, lens));
        Place memory p = Place(
            VIEW_EVERYONE, query.purpose, query.place, query.raw, query.sample, new bytes32[](0), 0
        );
        List memory l = query.below
            ? List(F_PLACE_BELOW, Purpose.TAG, 0, query.place, 0, 0, 0)
            : List(F_PLACE, query.purpose, 0, query.place, 0, 0, 0);
        bool ok = query.purpose == Purpose.TAG || (query.purpose == Purpose.FOLDER && !query.below);
        return _placePage(r, p, l, lens, expected, continuation, limit, gasReserve, ok);
    }

    /// @inheritdoc ITopicPageReader
    function about(
        bytes32 thing,
        bytes32[] calldata lens,
        bool raw,
        uint16 sample,
        BasisCommit calldata expected,
        bytes calldata continuation,
        uint32 limit,
        uint256 gasReserve
    ) external view returns (TopicPageInfo memory info, PlaceRow[] memory rows) {
        Run memory r;
        r.queryHash = keccak256(abi.encode(DOM_QUERY, LEDGER, VIEW_ABOUT, thing, lens, raw, sample));
        Place memory p = Place(VIEW_ABOUT, Purpose.TAG, thing, raw, sample, new bytes32[](0), 0);
        List memory l = List(F_ROLE_PLACES, Purpose.TAG, 0, thing, 0, 0, 0);
        return _placePage(r, p, l, lens, expected, continuation, limit, gasReserve, true);
    }

    function _placePage(
        Run memory r,
        Place memory p,
        List memory l,
        bytes32[] calldata lens,
        BasisCommit calldata expected,
        bytes calldata continuation,
        uint32 limit,
        uint256 gasReserve,
        bool ok
    ) private view returns (TopicPageInfo memory info, PlaceRow[] memory rows) {
        (Status st, uint64[] memory cursor) =
            _open(r, expected, lens.length, false, continuation, 1, info);
        info.dedupWithinPageOnly = true;
        if (st == Status.PRESENT && !ok) st = Status.INVALID;
        Coverage cov;
        if (st == Status.PRESENT) {
            cov = _listHead(r, l);
            info.rawTotal = l.count;
            if (r.resumed) {
                if (cursor[0] > l.count) st = Status.INVALID;
                else l.hi = cursor[0];
            }
            if (cov == Coverage.UNKNOWN) st = Status.UNKNOWN;
        }
        if (st != Status.PRESENT) {
            info.q.status = st;
            return (info, rows);
        }
        uint256 cap = _capacity(limit, l.hi);
        assembly ("memory-safe") {
            rows := mload(0x40)
            mstore(rows, cap)
            mstore(0x40, add(rows, mul(add(cap, 1), 32)))
        }
        // the positions met on this page (kept or not), bounded by what the page can read
        uint256 seenCap = l.hi;
        if (gasleft() / 5_000 < seenCap) seenCap = gasleft() / 5_000;
        p.seen = new bytes32[](seenCap);
        uint8 scan;
        uint256 got;
        (scan, got, cov) = _scanPlace(r, p, l, lens, rows, limit, gasReserve, info, cov);
        if (cov == Coverage.UNKNOWN) {
            info.q.status = Status.UNKNOWN;
            info.listingCoverage = Coverage.UNKNOWN;
            info.scanned = 0;
            info.repeatsSkipped = 0;
            assembly ("memory-safe") {
                mstore(rows, 0)
            }
            return (info, rows);
        }
        assembly ("memory-safe") {
            mstore(rows, got)
        }
        cursor = new uint64[](1);
        cursor[0] = l.hi;
        _finish(r, info, scan, cov, cursor);
    }

    /// Reads windows of the list newest first until a stop; leaves `l.hi` at the first unexamined entry.
    function _scanPlace(
        Run memory r,
        Place memory p,
        List memory l,
        bytes32[] calldata lens,
        PlaceRow[] memory rows,
        uint32 limit,
        uint256 gasReserve,
        TopicPageInfo memory info,
        Coverage cov
    ) private view returns (uint8, uint256 got, Coverage) {
        PlaceRow memory row; // reused by entries that produce no row
        while (l.hi != 0) {
            uint64 m = l.hi > WINDOW ? uint64(WINDOW) : l.hi;
            uint64[] memory e = _below(r, l, l.hi, m);
            (bytes32[] memory positions, Coordinate[] memory cells) = _cells(r, e);
            for (uint256 k = m; k != 0; --k) {
                if (limit != 0 && got == limit) return (SCAN_LIMIT, got, cov);
                if (got == rows.length || p.seenCount == p.seen.length || gasleft() < gasReserve) {
                    return (SCAN_GAS, got, cov);
                }
                --l.hi;
                ++info.scanned;
                bytes32 position = positions[k - 1];
                Coordinate memory c = cells[k - 1];
                _checkCell(p, c);
                if (_seen(p, position)) {
                    ++info.repeatsSkipped;
                    continue;
                }
                Coverage rc;
                bool shown;
                (shown, rc) = _placeRow(r, p, lens, position, c, e[k - 1], row);
                cov = _join(cov, rc);
                if (shown) {
                    rows[got] = row;
                    ++got;
                    ++r.selected;
                    row = _freshPlace();
                }
            }
        }
        return (SCAN_EXHAUSTED, got, cov);
    }

    /// An entry of the list is a statement at the list's own purpose and place (or thing, for `about`).
    function _checkCell(Place memory p, Coordinate memory c) private pure {
        bool bad = c.purpose != p.purpose;
        if (p.view_ == VIEW_ABOUT) bad = bad || c.role != p.place;
        else if (p.purpose == Purpose.FOLDER) bad = bad || c.subject != p.place;
        if (bad) revert E_TOPIC_INCONSISTENT(3);
    }

    /// True when `position` was already met on this page; records it otherwise.
    function _seen(Place memory p, bytes32 position) private pure returns (bool) {
        for (uint256 i; i < p.seenCount; ++i) {
            if (p.seen[i] == position) return true;
        }
        p.seen[p.seenCount++] = position;
        return false;
    }

    /// The row of one position: the author head, the yes rule (`everyone` only), the lens denial, the sample.
    function _placeRow(
        Run memory r,
        Place memory p,
        bytes32[] calldata lens,
        bytes32 position,
        Coordinate memory c,
        uint64 entry,
        PlaceRow memory row
    ) private view returns (bool, Coverage cov) {
        List memory a = List(F_POSITION_AUTHORS, 0, 0, position, 0, 0, 0);
        cov = _listHead(r, a);
        if (cov == Coverage.UNKNOWN) return (false, cov);
        if (a.count == 0) revert E_TOPIC_INCONSISTENT(3); // a listed position has a first statement
        if (p.view_ == VIEW_EVERYONE && !p.raw && a.live == 0) return (false, cov); // nobody says yes
        if (!p.raw && lens.length != 0) {
            if (_denied(r, lens, position)) return (false, cov);
            if (p.view_ == VIEW_EVERYONE && c.subject != p.place) {
                // below: a lens denial of the same thing at the viewed place hides it here too
                if (_denied(r, lens, Keys.position(Purpose.TAG, p.place, c.role))) {
                    return (false, cov);
                }
            }
        }
        row.position = position;
        row.topic = c.subject;
        row.thing = c.role;
        row.bindingOrdinal = entry;
        row.statements = a.count;
        row.yes = a.live;
        if (p.sample != 0) _sample(r, p, a, position, row);
        return (true, cov);
    }

    /// The lens rule at `position` decides a negative.
    function _denied(Run memory r, bytes32[] calldata lens, bytes32 position)
        private
        view
        returns (bool)
    {
        (Status st,,) = _headsAt(r, lens, position);
        return st == Status.MASKED;
    }

    /// The newest `p.sample` authors (at most 64) of the position: who says >= 0, who says < 0.
    function _sample(
        Run memory r,
        Place memory p,
        List memory a,
        bytes32 position,
        PlaceRow memory row
    ) private view {
        uint64 n = p.sample > 64 ? 64 : p.sample;
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
}

// forge-lint: disable-end(divide-before-multiply)
// forge-lint: disable-end(require-revert-in-loop)
// forge-lint: disable-end(calls-loop)
// forge-lint: disable-end(unsafe-typecast)
