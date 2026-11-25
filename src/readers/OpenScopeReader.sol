// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {PostingKey, Purpose, ScopeKey} from "../interfaces/Actions.sol";
import {IIndexReads} from "../interfaces/IIndexReads.sol";
import {ILedgerHot} from "../interfaces/ILedgerHot.sol";
import {IPostingStore} from "../interfaces/IPostingStore.sol";
import {IBitmapStore} from "../interfaces/IBitmapStore.sol";
import {Layout} from "../core/layout/Layout.sol";
import {Keys} from "../lib/Keys.sol";

/// @title OpenScopeReader — SPIKE (tags-index2): the three topic views, measurement only
/// @notice SPIKE. Not a production reader: no `IReader` surface, no basis commit, no coverage, no ABI promise. It
///         reads raw ledger slots through `extsloadBatch` (the facets' privilege, design §5.3 decision 30); a proper
///         version must route every ledger read below through a facet. Head words are decoded through the generated
///         `Layout` helpers only (`unpackHeadRowWord0`, `unpackAdmissionRowWord0`), never by bit offset.
///         Every list is read NEWEST FIRST, which means most recently first-stated: entries are appended only at an
///         author's first statement on a position, so no later action moves or duplicates an entry, and liveness
///         and the number always come from the head.
///         - `mine`: a lens of up to 64 principals; for a topic, exact (family 10 `scope`) or exact plus below
///           (family 19 `scope-below`), merged newest first by binding ordinal; the lens rule decides each candidate
///           (the first lens author with a stance at the position: number >= 0 shows it with that number, negative
///           hides it); a thing already shown in the page is not shown again.
///         - `everyone`: the place list (family 6) or the all-authors roll-up (family 7) newest first; per position
///           the thing, the topic it was filed under, the author count (one family-20 head), the newest author and
///           that author's state and number; hidden when any lens author has a negative stance there (`raw` skips).
///         - `byName`: the newest page of the authors of ONE position (family 20), each with state and number.
contract OpenScopeReader {
    uint256 private constant MASK48 = (1 << 48) - 1;
    uint8 private constant BOUND = 1;
    uint8 private constant MASKED = 2;

    struct MineRow {
        bytes32 topic; // the topic the candidate was filed under
        bytes32 thing; // the position's role
        int256 number;
        uint64 bindingOrdinal;
        uint8 decider; // the lens index whose stance decided
    }

    struct PlaceRow {
        bytes32 topic;
        bytes32 thing;
        bytes32 position;
        uint64 authors;
        bytes32 newestAuthor;
        uint8 state;
        int256 number;
        uint64 bindingOrdinal;
    }

    struct AuthorRow {
        bytes32 principalId;
        uint64 admission;
        uint8 state;
        int256 number;
        bytes32 target;
    }

    // =============================================================================================
    // counts
    // =============================================================================================

    /// One head read each: the distinct positions of a place, and the authors of one position.
    function places(address ledger, bytes32 purpose, bytes32 topic)
        external
        view
        returns (uint64 n)
    {
        (n,,,) = _posting(ledger).postingHead(_pk(6, Keys.openScope(purpose, topic)));
    }

    function authors(address ledger, bytes32 position) external view returns (uint64 n) {
        (n,,,) = _posting(ledger).postingHead(_pk(20, position));
    }

    // =============================================================================================
    // byName
    // =============================================================================================

    /// The authors of `position`, newest first: `from` entries already consumed from the end, `count` at most.
    function byName(address ledger, bytes32 position, uint64 from, uint16 count)
        external
        view
        returns (uint64 length, AuthorRow[] memory rows)
    {
        IPostingStore store = _posting(ledger);
        PostingKey pk = _pk(20, position);
        uint64 last;
        (length,, last,) = store.postingHead(pk);
        uint64 n = from >= length ? 0 : (count > length - from ? length - from : count);
        uint64[] memory adm = _tail(store, pk, length, last, from, n);
        ILedgerHot hot = ILedgerHot(ledger);
        bytes32[] memory s = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            s[i] = bytes32(Layout.admissionsRowsSlot(adm[i]));
        }
        bytes32[] memory meta = hot.extsloadBatch(s);
        for (uint256 i; i < n; ++i) {
            (,, uint48 pub,,,,,,,) = Layout.unpackAdmissionRowWord0(meta[i]);
            s[i] = bytes32(Layout.publicationsEvidenceSlot(pub) + 2);
        }
        bytes32[] memory who = hot.extsloadBatch(s);
        s = new bytes32[](2 * n);
        for (uint256 i; i < n; ++i) {
            uint256 head = Layout.bindingsHeadsSlot(Keys.binding(who[i], position));
            s[2 * i] = bytes32(head);
            s[2 * i + 1] = bytes32(head + 1);
        }
        bytes32[] memory h = hot.extsloadBatch(s);
        rows = new AuthorRow[](n);
        for (uint256 i; i < n; ++i) {
            (uint8 state, int256 number,) = _stance(h[2 * i]);
            rows[i] = AuthorRow(who[i], adm[i], state, number, h[2 * i + 1]);
        }
    }

    // =============================================================================================
    // everyone
    // =============================================================================================

    struct EveryoneQuery {
        bytes32 purpose;
        bytes32 topic;
        bool below; // family 7 (TAG) instead of family 6
        uint64 from; // entries consumed from the end
        uint16 count;
        bytes32[] lens;
        bool raw;
    }

    function everyone(address ledger, EveryoneQuery calldata q)
        external
        view
        returns (uint64 length, uint64 next, PlaceRow[] memory rows)
    {
        IPostingStore store = _posting(ledger);
        PostingKey pk = q.below
            ? _pk(7, Keys.openScope(Purpose.TAG, q.topic))
            : _pk(6, Keys.openScope(q.purpose, q.topic));
        uint64 last;
        (length,, last,) = store.postingHead(pk);
        rows = new PlaceRow[](q.count);
        uint256 got;
        next = q.from;
        while (got < q.count && next < length) {
            uint64 want = q.count - uint64(got);
            if (want > length - next) want = length - next;
            uint64[] memory ord = _tail(store, pk, length, last, next, want);
            got = _everyoneWindow(ledger, store, q, ord, rows, got);
            next += want;
        }
        assembly ("memory-safe") {
            mstore(rows, got)
        }
    }

    function _everyoneWindow(
        address ledger,
        IPostingStore store,
        EveryoneQuery calldata q,
        uint64[] memory ord,
        PlaceRow[] memory rows,
        uint256 got
    ) private view returns (uint256) {
        ILedgerHot hot = ILedgerHot(ledger);
        uint256 n = ord.length;
        uint256 lens = q.raw ? 0 : q.lens.length;
        bytes32[] memory pos = _positions(hot, ord);
        // the position cell (subject, role) and the lens heads, one round
        uint256 per = 2 + lens;
        bytes32[] memory s = new bytes32[](n * per);
        for (uint256 i; i < n; ++i) {
            uint256 cell = Layout.bindingsPositionsSlot(pos[i]);
            s[i * per] = bytes32(cell + 1);
            s[i * per + 1] = bytes32(cell + 2);
            for (uint256 j; j < lens; ++j) {
                s[i * per + 2 + j] =
                    bytes32(Layout.bindingsHeadsSlot(Keys.binding(q.lens[j], pos[i])));
            }
        }
        bytes32[] memory c = hot.extsloadBatch(s);
        // the author count and the newest author's admission: one family-20 head per position
        uint64[] memory cnt = new uint64[](n);
        bytes32[] memory a = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            uint64 lastAdm;
            (cnt[i],, lastAdm,) = store.postingHead(_pk(20, pos[i]));
            a[i] = bytes32(Layout.admissionsRowsSlot(lastAdm));
        }
        a = hot.extsloadBatch(a);
        for (uint256 i; i < n; ++i) {
            (,, uint48 pub,,,,,,,) = Layout.unpackAdmissionRowWord0(a[i]);
            a[i] = bytes32(Layout.publicationsEvidenceSlot(pub) + 2);
        }
        bytes32[] memory who = hot.extsloadBatch(a);
        for (uint256 i; i < n; ++i) {
            a[i] = bytes32(Layout.bindingsHeadsSlot(Keys.binding(who[i], pos[i])));
        }
        a = hot.extsloadBatch(a);
        for (uint256 i; i < n && got < rows.length; ++i) {
            bool hidden;
            for (uint256 j; j < lens; ++j) {
                (, int256 ln, bool has) = _stance(c[i * per + 2 + j]);
                if (has && ln < 0) hidden = true;
            }
            if (hidden) continue;
            (uint8 state, int256 number,) = _stance(a[i]);
            rows[got++] = PlaceRow({
                topic: c[i * per],
                thing: c[i * per + 1],
                position: pos[i],
                authors: cnt[i],
                newestAuthor: who[i],
                state: state,
                number: number,
                bindingOrdinal: ord[i]
            });
        }
        return got;
    }

    // =============================================================================================
    // mine
    // =============================================================================================

    struct MineQuery {
        bytes32[] lens; // ordered principals, at most 64
        bytes32 topic;
        bool below; // exact plus below (family 19) instead of exact only
        uint16 count;
        uint64[] cursor; // per list, entries consumed from the end (empty = from the newest); lists: exact of
        // lens[0..L), then below of lens[0..L)
    }

    /// One list being merged: its remaining entries (from the end) and a refillable window.
    struct Cursor {
        bool scope; // family 10 in the bitmap store (else a posting list)
        bytes32 key;
        uint64 length;
        uint64 last;
        uint64 used; // consumed from the end, including the window's taken entries
        uint64[] win; // window entries, newest first
        uint256 at; // next untaken window index
    }

    function mine(address ledger, MineQuery calldata q)
        external
        view
        returns (MineRow[] memory rows, uint64[] memory next)
    {
        uint256 l = q.lens.length;
        require(l != 0 && l <= 64, "lens");
        uint256 lists = q.below ? 2 * l : l;
        Cursor[] memory cur = _cursors(ledger, q, lists);
        rows = new MineRow[](q.count);
        uint256 got;
        IPostingStore ps = _posting(ledger);
        IBitmapStore bs = _bitmap(ledger);
        uint16 w = q.count < 8 ? 8 : q.count;
        while (got < q.count) {
            // the newest candidate among the list fronts (binding ordinals are unique and increasing)
            uint256 best = type(uint256).max;
            uint64 bestOrd;
            for (uint256 j; j < lists; ++j) {
                Cursor memory c = cur[j];
                if (c.at == c.win.length) {
                    if (c.used >= c.length) continue;
                    _refill(ps, bs, c, w);
                }
                uint64 o = c.win[c.at];
                if (o > bestOrd) {
                    bestOrd = o;
                    best = j;
                }
            }
            if (best == type(uint256).max) break;
            ++cur[best].at;
            got = _candidate(ledger, q.lens, best % l, bestOrd, rows, got);
        }
        assembly ("memory-safe") {
            mstore(rows, got)
        }
        next = new uint64[](lists);
        for (uint256 j; j < lists; ++j) {
            Cursor memory c = cur[j];
            next[j] = c.used - uint64(c.win.length - c.at);
        }
    }

    function _cursors(address ledger, MineQuery calldata q, uint256 lists)
        private
        view
        returns (Cursor[] memory cur)
    {
        uint256 l = q.lens.length;
        require(q.cursor.length == 0 || q.cursor.length == lists, "cursor");
        cur = new Cursor[](lists);
        IPostingStore ps = _posting(ledger);
        IBitmapStore bs = _bitmap(ledger);
        for (uint256 j; j < lists; ++j) {
            Cursor memory c = cur[j];
            if (j < l) {
                c.scope = true;
                c.key = Keys.scope(q.lens[j], Purpose.TAG, q.topic);
                (c.length,,,,,) = bs.scopeHead(ScopeKey.wrap(c.key));
            } else {
                c.key = Keys.posting(0, 19, 0, Keys.scopeBelow(q.lens[j - l], Purpose.TAG, q.topic));
                (c.length,, c.last,) = ps.postingHead(PostingKey.wrap(c.key));
            }
            c.used = q.cursor.length == 0 ? 0 : q.cursor[j];
        }
    }

    function _refill(IPostingStore ps, IBitmapStore bs, Cursor memory c, uint16 w) private view {
        uint64 n = c.length - c.used;
        if (n > w) n = w;
        if (c.scope) {
            uint64[] memory asc =
                bs.scopeSlice(ScopeKey.wrap(c.key), c.length - c.used - n, uint16(n));
            c.win = new uint64[](n);
            for (uint256 i; i < n; ++i) {
                c.win[i] = asc[n - 1 - i];
            }
        } else {
            c.win = _tail(ps, PostingKey.wrap(c.key), c.length, c.last, c.used, n);
        }
        c.at = 0;
        c.used += n;
    }

    /// The lens rule on one candidate: position, its cell, and the heads of lens[0..owner] in one round; the rest of
    /// the lens only when none of those has a stance (the owner's own entry may be RELEASED).
    function _candidate(
        address ledger,
        bytes32[] calldata lens,
        uint256 owner,
        uint64 ordinal,
        MineRow[] memory rows,
        uint256 got
    ) private view returns (uint256) {
        ILedgerHot hot = ILedgerHot(ledger);
        bytes32 position = hot.extsload(bytes32(Layout.bindingsBindingPositionSlot(ordinal)));
        uint256 cell = Layout.bindingsPositionsSlot(position);
        bytes32[] memory s = new bytes32[](owner + 3);
        s[0] = bytes32(cell + 1);
        s[1] = bytes32(cell + 2);
        for (uint256 j; j <= owner; ++j) {
            s[2 + j] = bytes32(Layout.bindingsHeadsSlot(Keys.binding(lens[j], position)));
        }
        bytes32[] memory h = hot.extsloadBatch(s);
        bytes32 thing = h[1];
        for (uint256 i; i < got; ++i) {
            if (rows[i].thing == thing) return got; // shown already in this page
        }
        for (uint256 j; j <= owner; ++j) {
            (, int256 number, bool has) = _stance(h[2 + j]);
            if (has) return _decide(rows, got, h[0], thing, number, ordinal, j);
        }
        uint256 rest = lens.length - owner - 1;
        if (rest == 0) return got;
        s = new bytes32[](rest);
        for (uint256 j; j < rest; ++j) {
            s[j] = bytes32(Layout.bindingsHeadsSlot(Keys.binding(lens[owner + 1 + j], position)));
        }
        bytes32[] memory r = hot.extsloadBatch(s);
        for (uint256 j; j < rest; ++j) {
            (, int256 number, bool has) = _stance(r[j]);
            if (has) return _decide(rows, got, h[0], thing, number, ordinal, owner + 1 + j);
        }
        return got;
    }

    function _decide(
        MineRow[] memory rows,
        uint256 got,
        bytes32 topic,
        bytes32 thing,
        int256 number,
        uint64 ordinal,
        uint256 decider
    ) private pure returns (uint256) {
        if (number < 0) return got;
        rows[got] = MineRow(topic, thing, number, ordinal, uint8(decider));
        return got + 1;
    }

    // =============================================================================================
    // helpers
    // =============================================================================================

    /// The head's state and number through the generated Layout decoder: number = strength when BOUND,
    /// -1 - strength when MASKED; `has` (a stance) is BOUND or MASKED.
    function _stance(bytes32 w0) private pure returns (uint8 state, int256 number, bool has) {
        uint8 strength;
        (state,,,,,,, strength) = Layout.unpackHeadRowWord0(w0);
        if (state == BOUND) return (state, int256(uint256(strength)), true);
        if (state == MASKED) return (state, -1 - int256(uint256(strength)), true);
    }

    function _positions(ILedgerHot hot, uint64[] memory ord)
        private
        view
        returns (bytes32[] memory)
    {
        bytes32[] memory s = new bytes32[](ord.length);
        for (uint256 i; i < ord.length; ++i) {
            s[i] = bytes32(Layout.bindingsBindingPositionSlot(ord[i]));
        }
        return hot.extsloadBatch(s);
    }

    /// Entries at list indices length-1-from down to length-from-n (newest first).
    function _tail(
        IPostingStore store,
        PostingKey pk,
        uint64 length,
        uint64 last,
        uint64 from,
        uint64 n
    ) private view returns (uint64[] memory out) {
        out = new uint64[](n);
        if (n == 0) return out;
        if (length == 1) {
            out[0] = last;
            return out;
        }
        uint64 lo = length - from - n;
        uint64 w0 = lo / 5;
        uint64 w1 = (lo + n - 1) / 5;
        uint256[] memory words = store.postingWords(pk, w0, uint16(w1 - w0 + 1));
        for (uint64 i; i < n; ++i) {
            uint64 idx = length - from - 1 - i;
            out[i] = uint64((words[idx / 5 - w0] >> ((idx % 5) * 48)) & MASK48);
        }
    }

    function _pk(uint8 kind, bytes32 value) private pure returns (PostingKey) {
        return PostingKey.wrap(Keys.posting(0, kind, 0, value));
    }

    function _posting(address ledger) private view returns (IPostingStore) {
        return IPostingStore(IIndexReads(ILedgerHot(ledger).index()).postingStore());
    }

    function _bitmap(address ledger) private view returns (IBitmapStore) {
        return IBitmapStore(IIndexReads(ILedgerHot(ledger).index()).bitmapStore());
    }
}
