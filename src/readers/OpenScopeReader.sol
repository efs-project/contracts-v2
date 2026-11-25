// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {PostingKey} from "../interfaces/Actions.sol";
import {IIndexReads} from "../interfaces/IIndexReads.sol";
import {ILedgerHot} from "../interfaces/ILedgerHot.sol";
import {IPostingStore} from "../interfaces/IPostingStore.sol";
import {Layout} from "../core/layout/Layout.sol";
import {Keys} from "../lib/Keys.sol";

/// @title OpenScopeReader — SPIKE (tags-index): a page over the all-authors lists, measurement only
/// @notice SPIKE. Not a production reader: no `IReader` surface, no basis commit, no coverage, no ABI promise; it
///         reads raw ledger slots through `extsloadBatch` (the facets' privilege, design §5.3 decision 30), which
///         a proper version must route through a facet. One `page` over the list of family 6 (the exact
///         `(purpose, subject)`), 7 (every TAG statement on a descendant of `key`) or 9 (every TAG statement on a
///         path holding the word `key`); `directory` over family 2.
/// @dev Per scan window: one posting-store call for the entry words, then three ledger `extsloadBatch` rounds:
///      (1) admission row word 0 per entry, (2) the publication's evidence word 2 (principal id) and
///      `bindingPosition[ordinal]`, (3) the position cell's role (and subject for kinds 7 and 9) and the head row
///      of `binding(principal, position)`. `from` counts list entries already consumed in scan order (from the
///      start, or from the end when `newestFirst`); `count` bounds the rows returned; the scan continues window
///      by window until `count` rows pass the filter or the list ends; `next` is the consumed count after it.
///      The number of a row: `strength` (head meta byte at bit 248) when BOUND, `-1 - strength` when MASKED;
///      `minNumber` filters BOUND and MASKED rows by it; `includeDead = false` keeps BOUND rows only, and with
///      `includeDead = true` UNSET or RELEASED rows are returned without the number filter.
contract OpenScopeReader {
    struct Row {
        uint64 admission;
        bytes32 principalId;
        bytes32 role;
        bytes32 subject; // the position's subject for kinds 7 and 9 (0 for kind 6)
        uint8 state;
        uint8 strength;
        int16 number;
        bytes32 target;
    }

    struct Query {
        uint8 kind;
        bytes32 purpose;
        bytes32 key;
        uint64 from;
        uint16 count;
        bool newestFirst;
        int16 minNumber;
        bool includeDead;
    }

    function page(address ledger, Query calldata q)
        external
        view
        returns (uint64 length, uint64 next, Row[] memory rows)
    {
        require(q.kind == 6 || q.kind == 7 || q.kind == 9, "kind");
        IPostingStore store = IPostingStore(IIndexReads(ILedgerHot(ledger).index()).postingStore());
        PostingKey pk =
            PostingKey.wrap(Keys.posting(0, q.kind, 0, Keys.openScope(q.purpose, q.key)));
        uint64 last;
        (length,, last,) = store.postingHead(pk);
        rows = new Row[](q.count);
        uint256 got;
        next = q.from;
        while (got < q.count && next < length) {
            uint64 want = q.count - uint64(got);
            if (want > length - next) want = length - next;
            uint64[] memory adm = _window(store, pk, length, last, next, want, q.newestFirst);
            got = _fill(ledger, q, adm, rows, got);
            next += want;
        }
        assembly ("memory-safe") {
            mstore(rows, got)
        }
    }

    /// Family 2: the topic records listed under `word` (entries are the topics' first admissions; the record id is
    /// the admission row's `a` word). One store call and one ledger round.
    function directory(
        address ledger,
        bytes32 topicTypeId,
        bytes32 word,
        uint64 from,
        uint16 count,
        bool newestFirst
    ) external view returns (uint64 length, bytes32[] memory topics, uint64[] memory admissions) {
        IPostingStore store = IPostingStore(IIndexReads(ILedgerHot(ledger).index()).postingStore());
        PostingKey pk = PostingKey.wrap(Keys.posting(topicTypeId, 2, 0, word));
        uint64 last;
        (length,, last,) = store.postingHead(pk);
        uint64 n = from >= length ? 0 : (count > length - from ? length - from : count);
        admissions = _window(store, pk, length, last, from, n, newestFirst);
        bytes32[] memory slots = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            slots[i] = bytes32(Layout.admissionsRowsSlot(admissions[i]) + 1);
        }
        topics = ILedgerHot(ledger).extsloadBatch(slots);
    }

    /// The admissions at scan positions [from, from + n), oldest first or newest first.
    function _window(
        IPostingStore store,
        PostingKey pk,
        uint64 length,
        uint64 last,
        uint64 from,
        uint64 n,
        bool newestFirst
    ) private view returns (uint64[] memory adm) {
        adm = new uint64[](n);
        if (n == 0) return adm;
        if (length == 1) {
            adm[0] = last;
            return adm;
        }
        uint64 lo = newestFirst ? length - from - n : from; // lowest list index in the window
        uint64 w0 = lo / 5;
        uint64 w1 = (lo + n - 1) / 5;
        uint256[] memory words = store.postingWords(pk, w0, uint16(w1 - w0 + 1));
        for (uint64 i; i < n; ++i) {
            uint64 idx = newestFirst ? length - from - 1 - i : from + i;
            adm[i] = uint64((words[idx / 5 - w0] >> ((idx % 5) * 48)) & ((1 << 48) - 1));
        }
    }

    function _fill(
        address ledger,
        Query calldata q,
        uint64[] memory adm,
        Row[] memory rows,
        uint256 got
    ) private view returns (uint256) {
        ILedgerHot hot = ILedgerHot(ledger);
        uint256 n = adm.length;
        bytes32[] memory s = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            s[i] = bytes32(Layout.admissionsRowsSlot(adm[i]));
        }
        bytes32[] memory meta = hot.extsloadBatch(s);
        s = new bytes32[](2 * n);
        for (uint256 i; i < n; ++i) {
            uint256 m = uint256(meta[i]);
            s[2 * i] = bytes32(Layout.publicationsEvidenceSlot(uint48(m >> 16)) + 2);
            s[2 * i + 1] = bytes32(Layout.bindingsBindingPositionSlot(uint48(m >> 64)));
        }
        bytes32[] memory pp = hot.extsloadBatch(s);
        uint256 per = q.kind == 6 ? 3 : 4;
        s = new bytes32[](per * n);
        for (uint256 i; i < n; ++i) {
            bytes32 position = pp[2 * i + 1];
            uint256 cell = Layout.bindingsPositionsSlot(position);
            uint256 head = Layout.bindingsHeadsSlot(Keys.binding(pp[2 * i], position));
            s[per * i] = bytes32(cell + 2);
            s[per * i + 1] = bytes32(head);
            s[per * i + 2] = bytes32(head + 1);
            if (per == 4) s[per * i + 3] = bytes32(cell + 1);
        }
        bytes32[] memory h = hot.extsloadBatch(s);
        for (uint256 i; i < n && got < rows.length; ++i) {
            uint256 w = uint256(h[per * i + 1]);
            uint8 state = uint8(w);
            uint8 strength = uint8(w >> 248);
            int16 number;
            if (state == 1) number = int16(uint16(strength));
            else if (state == 2) number = -1 - int16(uint16(strength));
            if (state != 1 && !q.includeDead) continue;
            if ((state == 1 || state == 2) && number < q.minNumber) continue;
            rows[got++] = Row({
                admission: adm[i],
                principalId: pp[2 * i],
                role: h[per * i],
                subject: per == 4 ? h[per * i + 3] : bytes32(0),
                state: state,
                strength: strength,
                number: number,
                target: bytes32(h[per * i + 2])
            });
        }
        return got;
    }
}
