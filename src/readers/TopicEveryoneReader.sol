// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {BindingNumber, Coordinate, Purpose} from "../interfaces/Actions.sol";
import {ITopicEveryoneReader, PlaceRow, TopicPageInfo} from "../interfaces/Readers.sol";
import {BasisCommit, Coverage, Status} from "../interfaces/Results.sol";
import {E_TOPIC_INCONSISTENT, TopicReaderBase} from "./TopicReaderBase.sol";

// Narrowing casts are list indices, lens indices (< 64) and window sizes (≤ 16); the view makes a bounded set of
// calls per window of list entries, stopped by `limit`, `maxRows` and `gasReserve`.
// forge-lint: disable-start(unsafe-typecast)
// forge-lint: disable-start(calls-loop)
// forge-lint: disable-start(require-revert-in-loop)

/// @title TopicEveryoneReader/1 — the public views of a place (design §5.13, §11; docs/TAG-DESIGN.md §6)
/// @notice A place is a topic or a home; "below" is the place and everything filed under its descendant topics.
///         The lens view is `TopicMineReader`; `about` is on `TopicLookupReader`.
///
///         `everyone(query, lens)`: the place list `Keys.placeList(purpose, place)` (family 6; TAG or FOLDER) and,
///         with `below` (TAG), the roll-up `Keys.placeBelowList(TAG, place)` (family 7), merged newest first. A
///         position can be listed more than once (the first statement at a fresh position and every later author's
///         first yes), and below one thing can be filed under two child topics: a page shows each thing once, through
///         its newest filing that shows, and skips later filings of a thing already shown (`repeatsSkipped`; at one
///         place a thing is a position). A filing that does not show does not mark its thing as seen, so an older
///         filing of the same thing that shows still does. A caller removes repeats across pages
///         (`dedupWithinPageOnly`).
///
///         Reads per window of up to 16 entries, in this order: one slice per list; one `LedgerViews.bindingCells`
///         (each entry's position and cell); one head read of each entry's `Keys.positionAuthorsList` (family 20):
///         `statements` = its count, `yes` = its live count (the authors who say yes now). An entry nobody says yes
///         to (`yes == 0`) is skipped there, before any lens read: no author says yes, lens authors included, so it
///         cannot show whatever the lens says (`raw` keeps it). Then, only for the entries left, the combined lens
///         walk of design §11: one `LedgerViews.lensRule` over the whole lens at the filed positions and, below, the
///         viewed-place check: one head read of the viewed position's `position-authors` list (an empty list of
///         COMPLETE coverage: nobody stated anything there, nobody is asked) and otherwise the asked lens authors'
///         head states (`LedgerViews.headStates`, one word per head) in rounds of at most 64 keys
///         (`TopicReaderBase._maskedAt`). Walking the lens in order, each author is asked
///         first whether its head for the thing at the VIEWED place `(TAG, place, thing)` is MASKED ("not this"
///         here) and then what it says where the entry was FILED; the first answer decides. Let iT be the first lens
///         author with a stance at the filed position and kV the first whose head at the viewed place is MASKED
///         (none: after the last): the row is hidden when kV <= iT, or when iT exists and says no; it is shown when
///         iT says yes, and when no lens author has a stance at the filed position the public tier decides (shown,
///         since someone says yes). An exact view's viewed place is the filed position, so kV adds nothing there; a
///         denial does not travel down to child topics, and a denial of a child topic says nothing about the place.
///         Only lens authors hide: a stranger's statements never do, and no row is hidden or dropped because a scan
///         stopped early. Every row names its decider (`decider`, `number`; 255 for the public tier). `raw` skips the
///         lens and the yes rule. With `sample` > 0 the newest `sample` authors (at most 64) are read through
///         `LedgerViews.authorHeads` as detail: how many say >= 0, how many < 0, and `incomplete` when they are not
///         every author.
///
///         Page laws as `TopicPageInfo` states them: a Realm whose index keeps no topic roll-ups (family 7
///         `NOT_MAINTAINED`) answers a below view UNKNOWN with no rows, never empty; any list or author head of
///         UNKNOWN coverage makes the page UNKNOWN. Two bounds, whichever comes first: `limit` list entries read
///         (scan status 2 LIMIT) and `maxRows` rows returned (4 ROWS), 0 = no bound; `gasReserve` is checked before
///         each entry and must cover one window of 16 entries and the return encoding (3 GAS). Each carries a
///         continuation; only 1 EXHAUSTED ends the listing, and a page that is not refused reads at least one entry.
///         The continuation's cursor is one index per list counted from the list's start, so appends between pages
///         never shift it. `frontier` is the first entry of the window not consumed at the stop (the window holds the
///         newest unread entries of both lists, so it is the larger of the two lists' next unread binding ordinals),
///         held already: no further read.
contract TopicEveryoneReader is TopicReaderBase, ITopicEveryoneReader {
    bytes32 internal constant DOM_QUERY = keccak256("efs/topic-everyone/query/1");

    /// The working state of one page.
    struct Place {
        bytes32 purpose;
        bytes32 place;
        bool below;
        bool raw;
        uint16 sample;
        uint32 limit;
        uint32 maxRows;
        uint256 gasReserve;
    }

    /// One window's facts per entry, read before any entry is consumed.
    struct Win {
        uint64[] e;
        uint8[] src;
        bytes32[] positions;
        Coordinate[] cells;
        uint64[] statements;
        uint64[] yes;
        bool[] live;
        uint256[] decider;
        int32[] number;
    }

    /// @param ledger_ the ledger proxy this reader serves (its layout is pinned here: `layoutId()`)
    /// @param views_ the `LedgerViews` facet (`bindingCells`, `lensRule`, `headStates`, `authorHeads`)
    /// @param reads_ the `LedgerReads` facet (`basis`)
    constructor(address ledger_, address views_, address reads_)
        TopicReaderBase(ledger_, views_, reads_)
    {}

    /// @inheritdoc ITopicEveryoneReader
    function everyone(
        PlaceQuery calldata query,
        bytes32[] calldata lens,
        BasisCommit calldata expected,
        bytes calldata continuation,
        uint32 limit,
        uint32 maxRows,
        uint256 gasReserve
    ) external view returns (TopicPageInfo memory, PlaceRow[] memory) {
        Run memory r;
        r.queryHash = keccak256(abi.encode(DOM_QUERY, LEDGER, query, lens));
        Place memory p = Place(
            query.purpose,
            query.place,
            query.below,
            query.raw,
            query.sample,
            limit,
            maxRows,
            gasReserve
        );
        return _page(r, p, lens, expected, continuation);
    }

    function _page(
        Run memory r,
        Place memory p,
        bytes32[] calldata lens,
        BasisCommit calldata expected,
        bytes calldata continuation
    ) private view returns (TopicPageInfo memory info, PlaceRow[] memory rows) {
        PlaceQuery memory query = PlaceQuery(p.purpose, p.place, p.below, p.raw, p.sample);
        // below = the place itself (family 6) and every topic under it (family 7), merged newest first
        List[] memory ls = new List[](query.below ? 2 : 1);
        ls[0] = List(F_PLACE, query.purpose, 0, query.place, 0, 0, 0, 0);
        if (query.below) ls[1] = List(F_PLACE_BELOW, Purpose.TAG, 0, query.place, 0, 0, 0, 0);
        (Status st, uint64[] memory cursor) =
            _open(r, expected, lens.length, false, continuation, ls.length, info);
        info.dedupWithinPageOnly = true;
        if (
            st == Status.PRESENT && query.purpose != Purpose.TAG
                && (query.purpose != Purpose.FOLDER || query.below)
        ) st = Status.INVALID;
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
        uint256 cap = _capacity(p.limit, p.maxRows, left);
        assembly ("memory-safe") {
            rows := mload(0x40)
            mstore(rows, cap)
            mstore(0x40, add(rows, mul(add(cap, 1), 32)))
        }
        uint8 scan;
        uint256 got;
        (scan, got, cov) = _scan(r, p, ls, lens, rows, info, cov);
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
    /// unexamined entry (a window is read whole, then consumed entry by entry, so a stop inside it resumes at the
    /// first entry not consumed).
    function _scan(
        Run memory r,
        Place memory p,
        List[] memory ls,
        bytes32[] calldata lens,
        PlaceRow[] memory rows,
        TopicPageInfo memory info,
        Coverage cov
    ) private view returns (uint8, uint256 got, Coverage) {
        for (;;) {
            uint256 m = p.limit == 0 || p.limit - info.scanned > WINDOW
                ? WINDOW
                : p.limit - info.scanned;
            Win memory w;
            (w.e, w.src) = _window(r, ls, m == 0 ? 1 : m);
            if (w.e.length == 0) return (SCAN_EXHAUSTED, got, cov);
            // a stop's frontier is the window's first unconsumed entry: the window holds the newest unread entries
            uint8 stop = _stop(info.scanned, got, rows.length, p.limit, p.maxRows, p.gasReserve);
            if (stop != 0) {
                info.frontier = w.e[0];
                return (stop, got, cov);
            }
            cov = _join(cov, _facts(r, p, lens, w, rows, got));
            if (cov == Coverage.UNKNOWN) return (SCAN_EXHAUSTED, got, cov);
            for (uint256 k; k < w.e.length; ++k) {
                stop = _stop(info.scanned, got, rows.length, 0, p.maxRows, p.gasReserve);
                if (stop != 0) {
                    info.frontier = w.e[k];
                    return (stop, got, cov);
                }
                --ls[w.src[k]].hi;
                ++info.scanned;
                bytes32 thing = w.cells[k].role;
                // repeats by thing: a thing already shown on this page (exactly: the same position)
                if (_shown(rows, got, thing)) {
                    ++info.repeatsSkipped;
                    continue;
                }
                // a filing that does not show is not marked seen: an older filing of the thing may still show
                if (!w.live[k]) continue;
                PlaceRow memory row;
                row.position = w.positions[k];
                row.topic = w.cells[k].subject;
                row.thing = thing;
                row.bindingOrdinal = w.e[k];
                row.decider = uint8(w.decider[k]);
                row.number = w.number[k];
                row.statements = w.statements[k];
                row.yes = w.yes[k];
                if (p.sample != 0) {
                    List memory a =
                        List(F_POSITION_AUTHORS, 0, 0, w.positions[k], w.statements[k], 0, 0, 0);
                    _sample(r, p.sample, a, w.positions[k], row);
                }
                rows[got++] = row;
                ++r.selected;
            }
        }
        return (SCAN_EXHAUSTED, got, cov); // unreachable: the loop returns
    }

    /// One window's facts: the cells, each entry's author-list head (skipping entries whose thing is already shown),
    /// then the combined lens walk over the entries someone says yes to. `w.live[k]` is whether entry k shows.
    function _facts(
        Run memory r,
        Place memory p,
        bytes32[] calldata lens,
        Win memory w,
        PlaceRow[] memory rows,
        uint256 got
    ) private view returns (Coverage cov) {
        uint256 n = w.e.length;
        (w.positions, w.cells) = _cells(r, w.e);
        w.statements = new uint64[](n);
        w.yes = new uint64[](n);
        w.live = new bool[](n);
        w.decider = new uint256[](n);
        w.number = new int32[](n);
        cov = Coverage.COMPLETE;
        uint256 left; // entries that need the lens
        for (uint256 k; k < n; ++k) {
            Coordinate memory c = w.cells[k];
            // an entry is a statement at the list's own purpose and place: the place list's at the place, the
            // roll-up's under a proper descendant of it
            if (c.purpose != p.purpose || (c.subject == p.place) != (w.src[k] == 0)) {
                revert E_TOPIC_INCONSISTENT(3);
            }
            w.decider[k] = SELECTED_NONE;
            if (_shown(rows, got, c.role)) continue; // a repeat of an earlier window: no read
            List memory a = List(F_POSITION_AUTHORS, 0, 0, w.positions[k], 0, 0, 0, 0);
            cov = _join(cov, _listHead(r, a));
            if (cov == Coverage.UNKNOWN) return cov;
            if (a.count == 0) revert E_TOPIC_INCONSISTENT(3); // a listed position has a first statement
            w.statements[k] = a.count;
            w.yes[k] = a.live;
            // nobody says yes, lens authors included: it cannot show (raw keeps it)
            w.live[k] = p.raw || a.live != 0;
            if (w.live[k] && !p.raw && lens.length != 0) ++left;
        }
        if (left != 0) _lensWalk(r, p, lens, w, left);
    }

    /// The combined lens walk over the live entries of a window (design §11): iT from one `lensRule` over the whole
    /// lens at the filed positions, kV from the viewed-place heads of lens[0..iT] (every lens author when iT is
    /// none) for the roll-up entries iT does not hide; clears `w.live[k]` for what the lens hides and names the
    /// decider of what it shows.
    function _lensWalk(
        Run memory r,
        Place memory p,
        bytes32[] calldata lens,
        Win memory w,
        uint256 left
    ) private view {
        uint256 n = w.e.length;
        uint256[] memory idx = new uint256[](left);
        uint64[] memory o = new uint64[](left);
        uint8[] memory au = new uint8[](left);
        uint256 j;
        for (uint256 k; k < n; ++k) {
            if (!w.live[k]) continue;
            idx[j] = k;
            o[j] = w.e[k];
            au[j++] = uint8(lens.length - 1);
        }
        Lensed memory x = _lensRule(r, lens, o, au);
        bytes32[] memory th = new bytes32[](left);
        uint256[] memory ask = new uint256[](left);
        for (j = 0; j < left; ++j) {
            uint256 k = idx[j];
            if (x.positions[j] != w.positions[k]) revert E_TOPIC_INCONSISTENT(3);
            th[j] = w.cells[k].role;
            uint256 d = x.decider[j];
            if (d != SELECTED_NONE && x.decided[j] == 2) {
                w.live[k] = false; // iT says no where it was filed
                continue;
            }
            w.decider[k] = d;
            if (d != SELECTED_NONE) {
                (, w.number[k]) = BindingNumber.numberOf(x.decided[j], x.strength[j]);
            }
            // below: ask lens[0..iT] (all of it when iT is none) whether "not this" at the viewed place
            if (w.cells[k].subject != p.place) ask[j] = d == SELECTED_NONE ? lens.length : d + 1;
        }
        uint256[] memory kv = _maskedAt(r, lens, p.place, th, ask);
        for (j = 0; j < left; ++j) {
            if (kv[j] != SELECTED_NONE) w.live[idx[j]] = false; // kV <= iT: hidden at the viewed place
        }
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
}

// forge-lint: disable-end(require-revert-in-loop)
// forge-lint: disable-end(calls-loop)
// forge-lint: disable-end(unsafe-typecast)
