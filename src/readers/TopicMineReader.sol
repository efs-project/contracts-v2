// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {BindingNumber, Coordinate, FamilyId, Purpose, ScopeKey} from "../interfaces/Actions.sol";
import {IBitmapStore} from "../interfaces/IBitmapStore.sol";
import {IIndexReads} from "../interfaces/IIndexReads.sol";
import {ITopicMineReader, MineRow, TopicPageInfo} from "../interfaces/Readers.sol";
import {BasisCommit, Coverage, Status} from "../interfaces/Results.sol";
import {Head} from "../interfaces/Views.sol";
import {Keys} from "../lib/Keys.sol";
import {E_TOPIC_INCONSISTENT, TopicReaderBase} from "./TopicReaderBase.sol";

// Narrowing casts are list indices, lens indices (< 64) and window sizes (≤ 16); the view makes a bounded set of
// calls per batch of list entries, stopped by `limit`, `maxRows` and `gasReserve`; `e / 256 * 256` is a bitmap word's
// first entry.
// forge-lint: disable-start(unsafe-typecast)
// forge-lint: disable-start(calls-loop)
// forge-lint: disable-start(require-revert-in-loop)
// forge-lint: disable-start(divide-before-multiply)

/// @title TopicMineReader/1 — the lens view of a place (design §5.13, §11; docs/TAG-DESIGN.md §6)
/// @notice A place is a topic or a home; "below" is the place and everything filed under its descendant topics.
///         The public views are `TopicEveryoneReader`; `about` is on `TopicLookupReader`.
///
///         `mine(lens, place, below)`: lens = ordered principals (1..64). Merges, newest first by binding ordinal,
///         each lens author's exact scope list `Keys.scope(author, TAG, place)` (family 10, in the bitmap store; an
///         entry whose live bit is clear is never shown and costs no head read) and, with `below`, the author's
///         roll-up `Keys.scopeBelowList(author, TAG, place)` (family 19). Each candidate is decided by the combined
///         lens walk of design §11, over the lens alone (no public tier): walking the lens in order, each author is
///         asked first whether its head for the thing at the VIEWED place is MASKED ("not this" here) and then what
///         it says where the entry was FILED; the first answer decides. Let iT be the first lens author with a stance
///         at the filed position and kV the first whose head at the viewed place is MASKED: the row is hidden when
///         kV <= iT or iT says no, and shown with iT's number when iT says yes (an exact view's viewed place is the
///         filed position, so kV adds nothing there). A candidate of lens author j is a row only when iT = j (a row
///         comes from the deciding author's own entry, so each (topic filed under, thing) appears once in a listing
///         read at one block), so it needs only the heads of lens[0..j]: candidates are resolved in batches of up to
///         16 by one `LedgerViews.lensRule` call (the state word of each earlier author's head and the candidate
///         author's whole head at the filed position), and the roll-up candidates that would show then read the
///         heads of lens[0..j] at the viewed place in `heads` rounds of at most 64 keys. What `mine` shows for a
///         lens and place, `TopicEveryoneReader.everyone` shows too. With `below`, a thing filed under two topics is
///         shown once per page, through its newest filing that the lens shows (`repeatsSkipped` counts the rest).
///         Heads are read at each page's own block, so a stance changed between pages can move a row, and a caller
///         removes repeats across pages (`dedupWithinPageOnly`).
///
///         Page laws as `TopicPageInfo` states them: a Realm whose index keeps no topic roll-ups (family 19
///         `NOT_MAINTAINED`) answers a below view UNKNOWN with no rows, never empty; any list of UNKNOWN coverage makes
///         the page UNKNOWN. Two bounds, whichever comes first: `limit` list entries read (scan status 2 LIMIT) and
///         `maxRows` rows returned (4 ROWS), 0 = no bound; `gasReserve` is checked before each batch and must cover
///         one batch of 16 rows and the return encoding (3 GAS). Each carries a continuation; only 1 EXHAUSTED ends
///         the listing, and a page that is not refused reads at least one entry. The continuation's cursor is one
///         index per list counted from the list's start, so appends between pages never shift it.
contract TopicMineReader is TopicReaderBase, ITopicMineReader {
    bytes32 internal constant DOM_QUERY = keccak256("efs/topic-mine/query/1");

    /// One lens author's list: its exact scope list (bitmap store) or its roll-up (posting list), and a window of
    /// entries `[lo, lo + win.length)` read ascending; entries below `l.hi` are unread.
    struct Src {
        bool exact;
        bytes32 key;
        uint64 lo;
        uint64[] win;
        uint256 bits;
        List l;
    }

    /// The bounds of one page.
    struct Bounds {
        uint32 limit;
        uint32 maxRows;
        uint256 gasReserve;
    }

    /// @param ledger_ the ledger proxy this reader serves (its layout is pinned here: `layoutId()`)
    /// @param views_ the `LedgerViews` facet (`lensRule`, `heads`)
    /// @param reads_ the `LedgerReads` facet (`basis`)
    constructor(address ledger_, address views_, address reads_)
        TopicReaderBase(ledger_, views_, reads_)
    {}

    /// @inheritdoc ITopicMineReader
    function mine(
        bytes32[] calldata lens,
        bytes32 place,
        bool below,
        BasisCommit calldata expected,
        bytes calldata continuation,
        uint32 limit,
        uint32 maxRows,
        uint256 gasReserve
    ) external view returns (TopicPageInfo memory info, MineRow[] memory rows) {
        Run memory r;
        r.queryHash = keccak256(abi.encode(DOM_QUERY, LEDGER, lens, place, below));
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
        uint256 cap = _capacity(limit, maxRows, left);
        assembly ("memory-safe") {
            rows := mload(0x40)
            mstore(rows, cap)
            mstore(0x40, add(rows, mul(add(cap, 1), 32)))
        }
        (uint8 scan, uint256 got) =
            _merge(r, s, lens, place, rows, Bounds(limit, maxRows, gasReserve), info);
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
        if (c == Coverage.UNSET) revert E_TOPIC_INCONSISTENT(6);
        if (
            through > r.observed.admissionHighWater
                || (c == Coverage.COMPLETE && through != r.observed.admissionHighWater)
        ) revert E_TOPIC_INCONSISTENT(6);
    }

    /// The newest-first merge of every lens list, resolved in batches of up to WINDOW candidates; leaves each
    /// list's `hi` at its first unexamined entry. A batch holds at most the rows still allowed (`maxRows`), so a
    /// page never returns more than `maxRows` rows.
    function _merge(
        Run memory r,
        Src[] memory s,
        bytes32[] calldata lens,
        bytes32 place,
        MineRow[] memory rows,
        Bounds memory b,
        TopicPageInfo memory info
    ) private view returns (uint8, uint256 got) {
        uint64[] memory ord = new uint64[](WINDOW);
        uint256[] memory src = new uint256[](WINDOW);
        for (;;) {
            (uint256 best,) = _front(r, s, b.limit);
            if (best == type(uint256).max) return (SCAN_EXHAUSTED, got);
            // a stop leaves the cursor at this candidate (a refill reads, it never consumes)
            uint8 stop = _stop(info.scanned, got, rows.length, b.limit, b.maxRows, b.gasReserve);
            if (stop != 0) return (stop, got);
            uint256 room = rows.length - got;
            if (b.maxRows != 0 && b.maxRows - got < room) room = b.maxRows - got;
            if (room > WINDOW) room = WINDOW;
            uint256 n;
            while (n < room && (b.limit == 0 || info.scanned < b.limit)) {
                uint64 o;
                (best, o) = _front(r, s, b.limit);
                if (best == type(uint256).max) break;
                Src memory x = s[best];
                uint64 idx = --x.l.hi;
                ++info.scanned;
                // a masked or released own entry is never shown and costs no head read
                if (x.exact && (x.bits >> (idx % 256)) & 1 == 0) continue;
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

    /// One batch of candidates: `LedgerViews.lensRule` at the filed positions (the first of lens[0..j] with a
    /// stance, the author's own head), then, for the roll-up candidates the filed position would show, the heads of
    /// lens[0..j] at the viewed place; a row only where the candidate's own author decides with a yes and no lens
    /// author up to it says "not this" at the viewed place.
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
        bytes32[] memory th = new bytes32[](n);
        uint256[] memory ask = new uint256[](n);
        for (uint256 i; i < n; ++i) {
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
            th[i] = c.role;
            // the filed position shows it (iT = j says yes): below, ask lens[0..j] at the viewed place
            if (!exact && x.decider[i] == who[i] && h.state == 1) ask[i] = uint256(who[i]) + 1;
        }
        uint256[] memory kv = _maskedAt(r, lens, place, th, ask);
        for (uint256 i; i < n; ++i) {
            uint256 j = who[i];
            Head memory h = x.own[i];
            // decided by a higher author, hidden, released, or "not this" at the viewed place by lens[0..j]
            if (x.decider[i] != j || h.state != 1 || kv[i] != SELECTED_NONE) continue;
            if (_mineShown(rows, got, th[i])) {
                ++info.repeatsSkipped; // the same thing filed under another topic: once per page
                continue;
            }
            (, int32 number) = BindingNumber.numberOf(h.state, h.strength);
            rows[got++] = MineRow({
                position: x.positions[i],
                topic: x.cells[i].subject,
                thing: th[i],
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
            uint256[] memory bits = abi.decode(ret, (uint256[]));
            if (bits.length != 1) revert E_TOPIC_INCONSISTENT(7);
            x.bits = bits[0];
        } else {
            x.win = _below(r, x.l, hi, hi - lo);
        }
        if (x.win[x.win.length - 1] >= prev) revert E_TOPIC_INCONSISTENT(2);
        x.lo = lo;
    }

    /// True when one of the first `got` rows is about `thing`.
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
}

// forge-lint: disable-end(divide-before-multiply)
// forge-lint: disable-end(require-revert-in-loop)
// forge-lint: disable-end(calls-loop)
// forge-lint: disable-end(unsafe-typecast)
