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
/// @notice A place is a topic or a home; "below" is the place and everything filed under its descendant topics.
///         Two views, every list newest first (most recently first-stated); `about` is on `TopicLookupReader`.
///
///         `mine(lens, place, below)`: lens = ordered principals (1..64). Merges, newest first by binding ordinal,
///         each lens author's exact scope list `Keys.scope(author, TAG, place)` (family 10, in the bitmap store; an
///         entry whose live bit is clear is never shown and costs no head read) and, with `below`, the author's
///         roll-up `Keys.scopeBelowList(author, TAG, place)` (family 19). The lens rule decides each candidate: the
///         first lens author with a stance at the position decides; a number >= 0 shows the row with that number,
///         a negative hides it. A candidate of lens author j needs only the heads of lens[0..j]: candidates are
///         resolved in batches of up to 16 by one `LedgerViews.lensRule` call, which reads the state word of each
///         earlier author's head and the whole head of the candidate's author. A row is produced only by the
///         deciding author's own entry, so each (topic filed under, thing) appears once in a listing read at one
///         block; with `below`, a thing filed under two topics is shown once per page, through its newest filing that
///         the lens shows (`repeatsSkipped` counts the rest). Heads are read at each page's own block, so a stance
///         changed between pages can move a row, and a caller removes repeats across pages (`dedupWithinPageOnly`).
///
///         `everyone(query, lens)`: the place list `Keys.placeList(purpose, place)` (family 6; TAG or FOLDER) and,
///         with `below` (TAG), the roll-up `Keys.placeBelowList(TAG, place)` (family 7), merged newest first. A
///         position can be listed more than once (the first statement at a fresh position and every later author's
///         first yes), and below one thing can be filed under two child topics: a page shows each thing once, through
///         its newest filing that shows, and skips later filings of a thing already shown (`repeatsSkipped`; at one
///         place a thing is a position). A filing nobody says yes to, or one the lens hides there, does not mark its
///         thing as seen, so an older filing of the same thing that someone affirms still shows. A caller removes
///         repeats across pages (`dedupWithinPageOnly`). Per row one head read of the position's
///         authors (`Keys.positionAuthorsList`, family 20): `statements` = its count, `yes` = its live count (the
///         authors who say yes now). A row nobody says yes to (`yes == 0`) is left out; `raw` returns it. A row is
///         hidden only by a lens author: when the lens rule (the first lens author with a stance, from the window's
///         `lensRule` call) decides a negative at the position the entry was filed under or, below, at the same
///         thing in the viewed place (`(TAG, place, thing)`, one `heads` round per window); a denial does not travel
///         down to child topics, and a denial of a child topic says nothing about the place. A stranger's statements
///         never hide a row, and no row is hidden or dropped because a scan stopped early: no scan decides a row.
///         `raw` skips the lens. With `sample` > 0 the newest `sample` authors (at most 64) are read through
///         `LedgerViews.authorHeads` as detail: how many say >= 0, how many < 0, and `incomplete` when they are not
///         every author.
///
///         Page laws as `TopicPageInfo` states them: a Realm whose index keeps no topic roll-ups (families 7 and 19
///         `NOT_MAINTAINED`) answers a below view UNKNOWN with no rows, never empty; any list or author head of
///         UNKNOWN coverage makes the page UNKNOWN. `limit` bounds the list entries a page reads (0: only the gas
///         reserve), never the rows it returns: a page can hold fewer rows than `limit`, or none, while entries remain,
///         and only scan status 1 EXHAUSTED ends the listing. `gasReserve` is checked before each batch (`mine`) or
///         list entry (`everyone`) and must cover one batch of 16 rows and the return encoding (scan status 3 GAS,
///         with a continuation).
contract TopicPageReader is TopicReaderBase, ITopicPageReader {
    bytes32 internal constant DOM_QUERY = keccak256("efs/topic-page/query/1");
    uint8 internal constant VIEW_MINE = 1;
    uint8 internal constant VIEW_EVERYONE = 2;

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
        bool below;
        bool raw;
        uint16 sample;
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
        address store =
            abi.decode(_sc(r.index, abi.encodeCall(IIndexReads.bitmapStore, ()), 32), (address));
        // live-scope is a genesis family of the served physical profile: its coverage is the family's, the same for
        // every scope (design §10.5), so it is read once
        cov = _scopeCoverage(r, Keys.scope(lens[0], Purpose.TAG, place));
        for (uint256 i; i < s.length; ++i) {
            Src memory x = s[i];
            bytes32 author = lens[i % len];
            Coverage c;
            if (i < len) {
                x.exact = true;
                x.key = Keys.scope(author, Purpose.TAG, place);
                _scope(r, store, x);
                c = Coverage.COMPLETE;
            } else {
                x.l = List(
                    F_SCOPE_BELOW, 0, 0, Keys.scopeBelow(author, Purpose.TAG, place), 0, 0, 0, 0
                );
                c = _listHead(r, x.l);
            }
            cov = _join(cov, c);
            info.rawTotal += x.l.count;
            if (r.resumed) {
                if (cursor[i] > x.l.count) return (Status.INVALID, s, cov, 0);
                x.l.hi = cursor[i];
            }
            x.lo = x.l.hi; // no window yet
            if (!x.exact && x.l.hi != 0 && x.l.hi == x.l.count) {
                // a roll-up's newest entry is its head's `last`: the first window costs no slice
                x.win = new uint64[](1);
                x.win[0] = x.l.last;
                x.lo = x.l.hi - 1;
            }
            left += x.l.hi;
        }
        if (cov == Coverage.UNKNOWN) return (Status.UNKNOWN, s, cov, 0);
        return (Status.PRESENT, s, cov, left);
    }

    /// An exact scope list's head.
    function _scope(Run memory r, address store, Src memory x) private view {
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
    }

    /// The live-scope coverage at `key`.
    function _scopeCoverage(Run memory r, bytes32 key) private view returns (Coverage c) {
        bytes memory ret = _sc(
            r.index,
            abi.encodeCall(IIndexReads.coverage, (FamilyId.wrap(F_LIVE_SCOPE), ScopeKey.wrap(key))),
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

    /// The newest-first merge of every lens list, resolved in batches of up to WINDOW candidates (one
    /// `bindingCells` and one `heads` round per batch); leaves each list's `hi` at its first unexamined entry.
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
        uint64[] memory ord = new uint64[](WINDOW);
        uint256[] memory src = new uint256[](WINDOW);
        for (;;) {
            (uint256 best,) = _front(r, s, limit);
            if (best == type(uint256).max) return (SCAN_EXHAUSTED, got);
            // a stop leaves the cursor at this candidate (a refill reads, it never consumes)
            // the page's work is bounded by list entries read (`limit`), never by rows returned
            if (limit != 0 && info.scanned == limit) return (SCAN_LIMIT, got);
            if (got == rows.length || gasleft() < gasReserve) return (SCAN_GAS, got);
            uint256 room = rows.length - got;
            if (room > WINDOW) room = WINDOW;
            uint256 n;
            while (n < room && (limit == 0 || info.scanned < limit)) {
                uint64 o;
                (best, o) = _front(r, s, limit);
                if (best == type(uint256).max) break;
                Src memory b = s[best];
                uint64 idx = --b.l.hi;
                ++info.scanned;
                // a masked or released own entry is never shown and costs no head read
                if (b.exact && (b.bits >> (idx % 256)) & 1 == 0) continue;
                ord[n] = o;
                src[n] = best;
                ++n;
            }
            if (n != 0) got = _resolve(r, s, lens, place, ord, src, n, rows, got, info);
        }
        return (SCAN_EXHAUSTED, got); // unreachable: the loop returns
    }

    /// The list whose front entry is the newest (binding ordinals are unique), refilling empty windows.
    function _front(Run memory r, Src[] memory s, uint32 limit)
        private
        view
        returns (uint256 best, uint64 bestOrd)
    {
        best = type(uint256).max;
        for (uint256 i; i < s.length; ++i) {
            Src memory x = s[i];
            if (x.l.hi == 0) continue;
            if (x.l.hi == x.lo) _refill(r, x, limit);
            uint64 o = x.win[x.l.hi - 1 - x.lo];
            if (o > bestOrd) {
                bestOrd = o;
                best = i;
            }
        }
    }

    /// One batch of candidates through `LedgerViews.lensRule` (cells, the first of lens[0..j] with a stance, the
    /// author's own head): a row only where the candidate's own author decides with a yes.
    function _resolve(
        Run memory r,
        Src[] memory s,
        bytes32[] calldata lens,
        bytes32 place,
        uint64[] memory ord,
        uint256[] memory src,
        uint256 n,
        MineRow[] memory rows,
        uint256 got,
        TopicPageInfo memory info
    ) private view returns (uint256) {
        uint64[] memory o = new uint64[](n);
        uint8[] memory who = new uint8[](n);
        for (uint256 i; i < n; ++i) {
            o[i] = ord[i];
            who[i] = uint8(src[i] % lens.length);
        }
        Lensed memory x = _lensRule(r, lens, o, who);
        for (uint256 i; i < n; ++i) {
            uint256 j = who[i];
            bool exact = s[src[i]].exact;
            Coordinate memory c = x.cells[i];
            // an exact entry is filed at the place; a roll-up entry under a proper descendant of it
            if (c.purpose != Purpose.TAG || (c.subject == place) != exact) {
                revert E_TOPIC_INCONSISTENT(3);
            }
            Head memory h = x.own[i];
            if (h.state == 0 || h.bindingOrdinal != o[i] || (exact && h.state != 1)) {
                revert E_TOPIC_INCONSISTENT(4); // the entry is the author's binding; a live bit means BOUND
            }
            if (x.decider[i] != j || h.state != 1) continue; // decided by a higher author, hidden, or released
            if (_mineShown(rows, got, c.role)) {
                ++info.repeatsSkipped; // the same thing filed under another topic: once per page
                continue;
            }
            (, int32 number) = BindingNumber.numberOf(h.state, h.strength);
            rows[got++] = MineRow({
                position: x.positions[i],
                topic: c.subject,
                thing: c.role,
                targetKind: h.targetKind,
                decider: uint8(j),
                principalId: lens[j],
                number: number,
                revision: h.revision,
                admission: h.admission,
                bindingOrdinal: o[i]
            });
            ++r.selected;
        }
        return got;
    }

    function _freshPlace() private pure returns (PlaceRow memory row) {}

    /// The window just below `hi`: up to WINDOW entries (an exact list's window stays inside one bitmap word, whose
    /// live bits are read with it). Entries must strictly decrease from the previous window.
    function _refill(Run memory r, Src memory x, uint32 limit) private view {
        uint64 hi = x.l.hi;
        uint64 w = limit != 0 && limit < WINDOW ? limit : uint64(WINDOW);
        uint64 lo = hi > w ? hi - w : 0;
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
        Place memory p =
            Place(VIEW_EVERYONE, query.purpose, query.place, query.below, query.raw, query.sample);
        // below = the place itself (family 6) and every topic under it (family 7), merged newest first
        List[] memory ls = new List[](query.below ? 2 : 1);
        ls[0] = List(F_PLACE, query.purpose, 0, query.place, 0, 0, 0, 0);
        if (query.below) ls[1] = List(F_PLACE_BELOW, Purpose.TAG, 0, query.place, 0, 0, 0, 0);
        bool ok = query.purpose == Purpose.TAG || (query.purpose == Purpose.FOLDER && !query.below);
        return _placePage(r, p, ls, lens, expected, continuation, limit, gasReserve, ok);
    }

    function _placePage(
        Run memory r,
        Place memory p,
        List[] memory ls,
        bytes32[] calldata lens,
        BasisCommit calldata expected,
        bytes calldata continuation,
        uint32 limit,
        uint256 gasReserve,
        bool ok
    ) private view returns (TopicPageInfo memory info, PlaceRow[] memory rows) {
        (Status st, uint64[] memory cursor) =
            _open(r, expected, lens.length, false, continuation, ls.length, info);
        info.dedupWithinPageOnly = true;
        if (st == Status.PRESENT && !ok) st = Status.INVALID;
        Coverage cov = Coverage.COMPLETE;
        uint256 left;
        for (uint256 i; i < ls.length && st == Status.PRESENT; ++i) {
            List memory l = ls[i];
            cov = _join(cov, _listHead(r, l));
            info.rawTotal += l.count;
            info.positionsEver += l.live;
            if (r.resumed) {
                if (cursor[i] > l.count) st = Status.INVALID;
                else l.hi = cursor[i];
            }
            left += l.hi;
        }
        if (st == Status.PRESENT && cov == Coverage.UNKNOWN) st = Status.UNKNOWN;
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
        uint8 scan;
        uint256 got;
        (scan, got, cov) = _scanPlace(r, p, ls, lens, rows, limit, gasReserve, info, cov);
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
        cursor = new uint64[](ls.length);
        for (uint256 i; i < ls.length; ++i) {
            cursor[i] = ls[i].hi;
        }
        _finish(r, info, scan, cov, cursor);
    }

    /// Reads windows of the lists merged newest first until a stop; leaves each list's `hi` at its first
    /// unexamined entry. Per window: one slice per list, one `lensRule` (the cells, and the lens's decision at each
    /// entry's own position) and, below, one `heads` round over the lens at the same thing in the viewed place.
    function _scanPlace(
        Run memory r,
        Place memory p,
        List[] memory ls,
        bytes32[] calldata lens,
        PlaceRow[] memory rows,
        uint32 limit,
        uint256 gasReserve,
        TopicPageInfo memory info,
        Coverage cov
    ) private view returns (uint8, uint256 got, Coverage) {
        PlaceRow memory row; // reused by entries that produce no row
        bool deny = !p.raw && lens.length != 0;
        // the lens decides at each entry's own position; without one the facet is asked about nobody
        bytes32[] memory pr = deny ? lens : new bytes32[](1);
        for (;;) {
            // the page's work is bounded by list entries read (`limit`), never by rows returned
            uint256 m = limit == 0 || limit - info.scanned > WINDOW ? WINDOW : limit - info.scanned;
            // a below window's viewed-place heads are one `heads` call: at most MAX_KEYS of them
            if (deny && p.below && m * lens.length > MAX_KEYS) m = MAX_KEYS / lens.length;
            (uint64[] memory e, uint8[] memory src) = _window(r, ls, m == 0 ? 1 : m);
            if (e.length == 0) return (SCAN_EXHAUSTED, got, cov);
            if (limit != 0 && info.scanned == limit) return (SCAN_LIMIT, got, cov);
            if (got == rows.length || gasleft() < gasReserve) return (SCAN_GAS, got, cov);
            uint8[] memory au = new uint8[](e.length);
            for (uint256 k; k < e.length; ++k) {
                au[k] = uint8(pr.length - 1);
            }
            Lensed memory x = _lensRule(r, pr, e, au);
            Head[] memory hs;
            if (deny && p.below) hs = _viewedHeads(r, p, lens, x.cells);
            for (uint256 k; k < e.length; ++k) {
                if (got == rows.length || gasleft() < gasReserve) return (SCAN_GAS, got, cov);
                --ls[src[k]].hi;
                ++info.scanned;
                Coordinate memory c = x.cells[k];
                _checkCell(p, c, src[k] == 0);
                // repeats by thing: a thing already shown on this page (exactly: the same position)
                if (_shown(rows, got, c.role)) {
                    ++info.repeatsSkipped;
                    continue;
                }
                // hidden or unaffirmed filings are not marked seen: an older filing of the thing may still show
                if (deny && x.decided[k] == 2) continue; // a lens author's no at the filed position
                if (hs.length != 0 && c.subject != p.place) {
                    // below: a lens author's no for the same thing at the viewed place hides it here too
                    uint256 o = k * lens.length;
                    uint256 sel = _decide(hs, o, lens.length);
                    if (sel != SELECTED_NONE && hs[o + sel].state == 2) continue;
                }
                Coverage rc;
                bool shown;
                (shown, rc) = _placeRow(r, p, x.positions[k], c, e[k], row);
                cov = _join(cov, rc);
                if (shown) {
                    rows[got] = row;
                    ++got;
                    ++r.selected;
                    row = _freshPlace();
                }
            }
        }
        return (SCAN_EXHAUSTED, got, cov); // unreachable: the loop returns
    }

    /// The next entries of the lists (one or two), newest first, at most `m` (1..WINDOW): one slice per list below
    /// its `hi`, merged by ordinal (unique across the lists); `src[k]` names the list of entry k.
    function _window(Run memory r, List[] memory ls, uint256 m)
        private
        view
        returns (uint64[] memory e, uint8[] memory src)
    {
        List memory a = ls[0];
        uint64 na = a.hi < m ? a.hi : uint64(m);
        uint64[] memory wa = na == 0 ? new uint64[](0) : _below(r, a, a.hi, na);
        uint64 nb;
        uint64[] memory wb;
        if (ls.length > 1) {
            List memory b = ls[1];
            nb = b.hi < m ? b.hi : uint64(m);
            if (nb != 0) wb = _below(r, b, b.hi, nb);
        }
        uint256 n = na + nb < m ? na + nb : m;
        e = new uint64[](n);
        src = new uint8[](n);
        for (uint256 k; k < n; ++k) {
            if (nb == 0 || (na != 0 && wa[na - 1] > wb[nb - 1])) {
                e[k] = wa[--na];
            } else {
                e[k] = wb[--nb];
                src[k] = 1;
            }
        }
    }

    /// The lens heads at the viewed place's position `(TAG, place, thing)` of each entry of a below window.
    function _viewedHeads(
        Run memory r,
        Place memory p,
        bytes32[] calldata lens,
        Coordinate[] memory cells
    ) private view returns (Head[] memory) {
        uint256 len = lens.length;
        bytes32[] memory keys = new bytes32[](cells.length * len);
        for (uint256 k; k < cells.length; ++k) {
            bytes32 viewed = Keys.position(Purpose.TAG, p.place, cells[k].role);
            for (uint256 a; a < len; ++a) {
                keys[k * len + a] = Keys.binding(lens[a], viewed);
            }
        }
        return _heads(r, keys);
    }

    /// An entry of a list is a statement at the list's own purpose and place: `exact` entries (the place list) at
    /// the place, roll-up entries under a proper descendant of it.
    function _checkCell(Place memory p, Coordinate memory c, bool exact) private pure {
        if (c.purpose != p.purpose || (c.subject == p.place) != exact) {
            revert E_TOPIC_INCONSISTENT(3);
        }
    }

    /// True when one of the first `got` rows of `mine` is about `thing`.
    function _mineShown(MineRow[] memory rows, uint256 got, bytes32 thing)
        private
        pure
        returns (bool)
    {
        for (uint256 i; i < got; ++i) {
            if (rows[i].thing == thing) return true;
        }
        return false;
    }

    /// True when one of the first `got` rows is about `thing`.
    function _shown(PlaceRow[] memory rows, uint256 got, bytes32 thing)
        private
        pure
        returns (bool)
    {
        for (uint256 i; i < got; ++i) {
            if (rows[i].thing == thing) return true;
        }
        return false;
    }

    /// The row of one position: the author head (statements and yes), the yes rule (`everyone` only), the sample.
    function _placeRow(
        Run memory r,
        Place memory p,
        bytes32 position,
        Coordinate memory c,
        uint64 entry,
        PlaceRow memory row
    ) private view returns (bool, Coverage cov) {
        List memory a = List(F_POSITION_AUTHORS, 0, 0, position, 0, 0, 0, 0);
        cov = _listHead(r, a);
        if (cov == Coverage.UNKNOWN) return (false, cov);
        if (a.count == 0) revert E_TOPIC_INCONSISTENT(3); // a listed position has a first statement
        if (!p.raw && a.live == 0) return (false, cov); // nobody says yes
        row.position = position;
        row.topic = c.subject;
        row.thing = c.role;
        row.bindingOrdinal = entry;
        row.statements = a.count;
        row.yes = a.live;
        if (p.sample != 0) _sample(r, p.sample, a, position, row);
        return (true, cov);
    }
}

// forge-lint: disable-end(divide-before-multiply)
// forge-lint: disable-end(require-revert-in-loop)
// forge-lint: disable-end(calls-loop)
// forge-lint: disable-end(unsafe-typecast)
