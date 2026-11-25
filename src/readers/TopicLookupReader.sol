// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {
    ActionKind,
    BindingNumber,
    Coordinate,
    FamilyId,
    Purpose,
    ScopeKey
} from "../interfaces/Actions.sol";
import {IBitmapStore} from "../interfaces/IBitmapStore.sol";
import {IIndexReads} from "../interfaces/IIndexReads.sol";
import {ILedgerReads} from "../interfaces/ILedgerReads.sol";
import {
    AuthorRow,
    ITopicLookupReader,
    PlaceCount,
    PlaceRow,
    TopicPageInfo
} from "../interfaces/Readers.sol";
import {BasisCommit, Coverage, Qualified, Status} from "../interfaces/Results.sol";
import {AdmissionRow, Head, RecordHeader} from "../interfaces/Views.sol";
import {Keys} from "../lib/Keys.sol";
import {E_TOPIC_INCONSISTENT, E_TOPIC_STATUS, TopicReaderBase} from "./TopicReaderBase.sol";

// Narrowing casts are page sizes (≤ 64); the paged reads make a bounded set of calls per row, bounded by `limit`.
// forge-lint: disable-start(unsafe-typecast)
// forge-lint: disable-start(calls-loop)
// forge-lint: disable-start(require-revert-in-loop)

/// @title TopicLookupReader/1 — one position's authors, a thing's places, counts, word pages and children
///        (design §5.13, §11)
/// @notice Reads whose cost does not depend on how many authors, positions or places exist:
///
///         `about(thing)`: every place anyone filed `thing` under at TAG, either sign (`Keys.rolePlacesList(TAG,
///         thing)`, family 21: one entry per position), newest first, each with the row of
///         `TopicEveryoneReader.everyone` (`statements`, `yes`, the optional sample); rows nobody says yes to are
///         returned, so a lone negative is found from its thing. No lens: every row's `decider` is 255. Calls per
///         page: one slice, one `bindingCells`, then one author-list head per row (and the sample's slice and
///         `authorHeads`).
///
///         `byName(position)`: the authors of ONE position (TAG or FOLDER: "anyone's `pet.jpg` at this address" is
///         `byName(Keys.position(FOLDER, home, keccak256("pet.jpg")))`), newest first-stated first. One head read of
///         `Keys.positionAuthorsList(position)` (family 20), one slice from the end, one `LedgerViews.authorHeads`
///         (admission → author → head) for the page: three calls for up to 64 rows.
///
///         `placeCount`, `authorCount`, `entryCount`: one list head each (families 6/7, 20, and the author's scope
///         head or roll-up), with the list's coverage; UNKNOWN (count 0) when the list is not maintained (a roll-up
///         on an index without topic lists). `placeCount`'s `positionsEver` is an "about" count: positions that
///         ever received a statement, including those nobody says yes to now.
///
///         `wordPage(page)`: the places whose own word is the word of the `topic-word/1` record `page`: the root
///         place `page` itself (first row of the first page), then every `topic/1` record whose second reference
///         is `page` (`Keys.referenceList(topic/1, 1, page)`, family 11), newest first. `children(topic)`: every
///         `topic/1` record whose first reference (its parent) is `topic` (`Keys.referenceList(topic/1, 0, topic)`).
///         Each row carries the place's two "about" counts at TAG (`place` and `place-below` live counts) and their
///         filings; calls per row: one `LedgerReads.admission` (the registration's record id) and two list heads.
///         The reader does not fold words: the SDK folds every listed word again and skips one that is not its own
///         fold (docs/TAG-DESIGN.md §2.1); a place that lies under another group of the same word is the client's to
///         merge (spec §3.4). ABSENT_PROVEN when `page`/`topic` is no record, INVALID when it is a record of another
///         Type; UNKNOWN when the index keeps no topic roll-ups (the below counts are then unknown).
contract TopicLookupReader is TopicReaderBase, ITopicLookupReader {
    bytes32 internal constant DOM_QUERY = keccak256("efs/topic-lookup/query/1");
    /// The most rows of one `byName`, `wordPage` or `children` page (the facets' batch bound).
    uint256 internal constant BY_NAME_MAX = 64;
    uint8 internal constant VIEW_BY_NAME = 1;
    uint8 internal constant VIEW_WORD = 2;
    uint8 internal constant VIEW_CHILDREN = 3;
    uint8 internal constant VIEW_ABOUT = 4;

    bytes32 public immutable TOPIC_TYPE;
    bytes32 public immutable WORD_TYPE;

    /// @param topicType_ the `topic/1` Type id; @param wordType_ `topic-word/1`
    constructor(
        address ledger_,
        address views_,
        address reads_,
        bytes32 topicType_,
        bytes32 wordType_
    ) TopicReaderBase(ledger_, views_, reads_) {
        TOPIC_TYPE = topicType_;
        WORD_TYPE = wordType_;
    }

    // =============================================================================================
    // byName
    // =============================================================================================

    /// @inheritdoc ITopicLookupReader
    function byName(
        bytes32 position,
        BasisCommit calldata expected,
        bytes calldata continuation,
        uint16 limit
    ) external view returns (TopicPageInfo memory info, AuthorRow[] memory rows) {
        Run memory r;
        r.queryHash = keccak256(abi.encode(DOM_QUERY, LEDGER, VIEW_BY_NAME, position));
        List memory l = List(F_POSITION_AUTHORS, 0, 0, position, 0, 0, 0, 0);
        Coverage cov;
        Status st;
        (st, cov) = _openList(r, expected, continuation, l, info);
        if (st != Status.PRESENT) {
            info.q.status = st;
            return (info, rows);
        }
        uint64 n = limit == 0 || limit > BY_NAME_MAX ? uint64(BY_NAME_MAX) : limit;
        if (n > l.hi) n = l.hi;
        rows = new AuthorRow[](n);
        if (n != 0) {
            uint64[] memory adm = _below(r, l, l.hi, n);
            (Status[] memory s, bytes32[] memory who, Head[] memory hs) = _authors(r, position, adm);
            for (uint256 i; i < n; ++i) {
                uint256 k = n - 1 - i; // newest first
                Head memory h = hs[k];
                (, int32 number) = BindingNumber.numberOf(h.state, h.strength);
                rows[i] = AuthorRow(
                    who[k], adm[k], s[k], number, h.target, h.targetKind, h.revision, h.admission
                );
            }
            l.hi -= n;
        }
        info.scanned = n;
        r.selected += n;
        _end(r, info, l, cov);
    }

    // =============================================================================================
    // about
    // =============================================================================================

    /// @inheritdoc ITopicLookupReader
    function about(
        bytes32 thing,
        uint16 sample,
        BasisCommit calldata expected,
        bytes calldata continuation,
        uint16 limit
    ) external view returns (TopicPageInfo memory info, PlaceRow[] memory rows) {
        Run memory r;
        r.queryHash = keccak256(abi.encode(DOM_QUERY, LEDGER, VIEW_ABOUT, thing, sample));
        List memory l = List(F_ROLE_PLACES, Purpose.TAG, 0, thing, 0, 0, 0, 0);
        (Status st, Coverage cov) = _openList(r, expected, continuation, l, info);
        info.positionsEver = l.live;
        if (st != Status.PRESENT) {
            info.q.status = st;
            return (info, rows);
        }
        uint64 n = limit == 0 || limit > BY_NAME_MAX ? uint64(BY_NAME_MAX) : limit;
        if (n > l.hi) n = l.hi;
        rows = new PlaceRow[](n);
        if (n != 0) {
            uint64[] memory e = _below(r, l, l.hi, n);
            (bytes32[] memory positions, Coordinate[] memory cells) = _cells(r, e);
            for (uint256 i; i < n; ++i) {
                uint256 k = n - 1 - i; // newest first
                Coordinate memory c = cells[k];
                if (c.purpose != Purpose.TAG || c.role != thing) revert E_TOPIC_INCONSISTENT(3);
                List memory a = List(F_POSITION_AUTHORS, 0, 0, positions[k], 0, 0, 0, 0);
                cov = _join(cov, _listHead(r, a));
                if (a.count == 0) revert E_TOPIC_INCONSISTENT(3); // a listed position has a statement
                PlaceRow memory row = rows[i];
                row.position = positions[k];
                row.topic = c.subject;
                row.thing = thing;
                row.bindingOrdinal = e[k];
                row.decider = uint8(SELECTED_NONE); // no lens
                row.statements = a.count;
                row.yes = a.live;
                if (sample != 0 && cov != Coverage.UNKNOWN) {
                    _sample(r, sample, a, positions[k], row);
                }
            }
            l.hi -= n;
        }
        if (cov == Coverage.UNKNOWN) {
            info.q.status = Status.UNKNOWN;
            return (info, new PlaceRow[](0));
        }
        info.scanned = n;
        r.selected += n;
        _end(r, info, l, cov);
    }

    // =============================================================================================
    // counts
    // =============================================================================================

    /// @inheritdoc ITopicLookupReader
    function placeCount(bytes32 purpose, bytes32 place, bool below, BasisCommit calldata expected)
        external
        view
        returns (Qualified memory q, Coverage c, uint64 positionsEver, uint64 filings)
    {
        List memory
            l = below
                ? List(F_PLACE_BELOW, purpose, 0, place, 0, 0, 0, 0)
                : List(F_PLACE, purpose, 0, place, 0, 0, 0, 0);
        Run memory r;
        (q, c) = _count(r, expected, l);
        if (below && purpose != Purpose.TAG && q.status == Status.PRESENT) {
            q.status = Status.INVALID;
        }
        if (q.status == Status.PRESENT) (positionsEver, filings) = (l.live, l.count);
    }

    /// @inheritdoc ITopicLookupReader
    function authorCount(bytes32 position, BasisCommit calldata expected)
        external
        view
        returns (Qualified memory q, Coverage c, uint64 statements, uint64 yes)
    {
        List memory l = List(F_POSITION_AUTHORS, 0, 0, position, 0, 0, 0, 0);
        Run memory r;
        (q, c) = _count(r, expected, l);
        if (q.status == Status.PRESENT) (statements, yes) = (l.count, l.live);
    }

    /// @inheritdoc ITopicLookupReader
    function entryCount(
        bytes32 principalId,
        bytes32 purpose,
        bytes32 place,
        bool below,
        BasisCommit calldata expected
    ) external view returns (Qualified memory q, Coverage c, uint64 count, uint64 live) {
        Run memory r;
        if (below) {
            List memory l =
                List(F_SCOPE_BELOW, 0, 0, Keys.scopeBelow(principalId, purpose, place), 0, 0, 0, 0);
            (q, c) = _count(r, expected, l);
            if (purpose != Purpose.TAG && q.status == Status.PRESENT) q.status = Status.INVALID;
            if (q.status == Status.PRESENT) count = l.count;
            return (q, c, count, 0);
        }
        TopicPageInfo memory info;
        (q.status,) = _open(r, expected, 0, false, msg.data[0:0], 0, info);
        q.observed = r.observed;
        if (q.status != Status.PRESENT) return (q, Coverage.UNKNOWN, 0, 0);
        bytes32 key = Keys.scope(principalId, purpose, place);
        address store =
            abi.decode(_sc(r.index, abi.encodeCall(IIndexReads.bitmapStore, ()), 32), (address));
        uint64 lastMutation;
        (count, live, lastMutation,,,) = abi.decode(
            _sc(store, abi.encodeCall(IBitmapStore.scopeHead, (ScopeKey.wrap(key))), 192),
            (uint64, uint64, uint64, uint48, uint16, uint64)
        );
        if (live > count || lastMutation > r.observed.admissionHighWater) {
            revert E_TOPIC_INCONSISTENT(7);
        }
        (c,,,) = abi.decode(
            _sc(
                r.index,
                abi.encodeCall(
                    IIndexReads.coverage, (FamilyId.wrap(F_LIVE_SCOPE), ScopeKey.wrap(key))
                ),
                128
            ),
            (Coverage, uint64, uint64, uint8)
        );
        if (c == Coverage.UNSET) revert E_TOPIC_INCONSISTENT(6);
        if (c == Coverage.UNKNOWN) return (Qualified(Status.UNKNOWN, r.observed), c, 0, 0);
    }

    /// One list head as a count: UNKNOWN (and no count) when the list's coverage is.
    function _count(Run memory r, BasisCommit calldata expected, List memory l)
        private
        view
        returns (Qualified memory q, Coverage c)
    {
        TopicPageInfo memory info;
        (q.status,) = _open(r, expected, 0, false, msg.data[0:0], 0, info);
        q.observed = r.observed;
        if (q.status != Status.PRESENT) return (q, Coverage.UNKNOWN);
        c = _listHead(r, l);
        if (c == Coverage.UNKNOWN) q.status = Status.UNKNOWN;
    }

    // =============================================================================================
    // wordPage, children
    // =============================================================================================

    /// @inheritdoc ITopicLookupReader
    function wordPage(
        bytes32 page,
        BasisCommit calldata expected,
        bytes calldata continuation,
        uint16 limit
    ) external view returns (TopicPageInfo memory info, PlaceCount[] memory rows) {
        return _directory(VIEW_WORD, page, expected, continuation, limit);
    }

    /// @inheritdoc ITopicLookupReader
    function children(
        bytes32 topic,
        BasisCommit calldata expected,
        bytes calldata continuation,
        uint16 limit
    ) external view returns (TopicPageInfo memory info, PlaceCount[] memory rows) {
        return _directory(VIEW_CHILDREN, topic, expected, continuation, limit);
    }

    function _directory(
        uint8 view_,
        bytes32 id,
        BasisCommit calldata expected,
        bytes calldata continuation,
        uint16 limit
    ) private view returns (TopicPageInfo memory info, PlaceCount[] memory rows) {
        Run memory r;
        r.queryHash = keccak256(abi.encode(DOM_QUERY, LEDGER, view_, id));
        List memory l = List(F_REFERENCE, TOPIC_TYPE, view_ == VIEW_WORD ? 1 : 0, id, 0, 0, 0, 0);
        (Status st, Coverage cov) = _openList(r, expected, continuation, l, info);
        uint64 firstAdmission;
        if (st == Status.PRESENT) (st, firstAdmission) = _place(r, view_, id);
        if (st != Status.PRESENT) {
            info.q.status = st;
            return (info, rows);
        }
        bool root = view_ == VIEW_WORD && info.startsAtOrigin;
        uint64 n = limit == 0 || limit > BY_NAME_MAX ? uint64(BY_NAME_MAX) : limit;
        uint64 entries = n;
        if (root) --entries;
        if (entries > l.hi) entries = l.hi;
        rows = new PlaceCount[](entries + (root ? 1 : 0));
        uint256 k;
        if (root) {
            cov = _join(cov, _counts(r, id, firstAdmission, rows[k++]));
        }
        if (entries != 0) {
            uint64[] memory adm = _below(r, l, l.hi, entries);
            for (uint256 i; i < entries; ++i) {
                uint64 a = adm[entries - 1 - i];
                cov = _join(cov, _counts(r, _registered(a), a, rows[k++]));
            }
            l.hi -= entries;
        }
        if (cov == Coverage.UNKNOWN) {
            info.q.status = Status.UNKNOWN;
            return (info, new PlaceCount[](0));
        }
        info.scanned = entries;
        r.selected += uint64(rows.length);
        _end(r, info, l, cov);
    }

    /// The directory's own record: a `topic-word/1` record for a word page; a `topic/1` or `topic-word/1` record
    /// for children.
    function _place(Run memory r, uint8 view_, bytes32 id)
        private
        view
        returns (Status, uint64 firstAdmission)
    {
        (Status st, RecordHeader memory h) = abi.decode(
            _sc(READS, abi.encodeCall(ILedgerReads.recordHeader, (LEDGER, id)), 224),
            (Status, RecordHeader)
        );
        if (st == Status.ABSENT_PROVEN) return (st, 0);
        if (st != Status.PRESENT) revert E_TOPIC_STATUS(uint8(st));
        if (h.firstAdmission == 0 || h.firstAdmission > r.observed.admissionHighWater) {
            revert E_TOPIC_INCONSISTENT(8);
        }
        bool ok = h.typeId == WORD_TYPE || (view_ == VIEW_CHILDREN && h.typeId == TOPIC_TYPE);
        return (ok ? Status.PRESENT : Status.INVALID, h.firstAdmission);
    }

    /// The record a registration entry (an admission ordinal of family 11) first published.
    function _registered(uint64 a) private view returns (bytes32) {
        (Status st, AdmissionRow memory row) = abi.decode(
            _sc(READS, abi.encodeCall(ILedgerReads.admission, (LEDGER, a)), 416),
            (Status, AdmissionRow)
        );
        if (st != Status.PRESENT) revert E_TOPIC_STATUS(uint8(st));
        if (row.kind != ActionKind.PUBLISH || row.a == 0) revert E_TOPIC_INCONSISTENT(8);
        return row.a;
    }

    /// A place's two "about" counts and their filings at TAG; their joined coverage.
    function _counts(Run memory r, bytes32 place, uint64 admission, PlaceCount memory row)
        private
        view
        returns (Coverage c)
    {
        List memory e = List(F_PLACE, Purpose.TAG, 0, place, 0, 0, 0, 0);
        List memory b = List(F_PLACE_BELOW, Purpose.TAG, 0, place, 0, 0, 0, 0);
        c = _join(_listHead(r, e), _listHead(r, b));
        row.place = place;
        row.admission = admission;
        row.positionsEver = e.live;
        row.positionsEverBelow = b.live;
        row.filings = e.count;
        row.filingsBelow = b.count;
    }

    // ---- one list, paged from its end --------------------------------------------------------------------------

    function _openList(
        Run memory r,
        BasisCommit calldata expected,
        bytes calldata continuation,
        List memory l,
        TopicPageInfo memory info
    ) private view returns (Status st, Coverage cov) {
        uint64[] memory cursor;
        (st, cursor) = _open(r, expected, 0, false, continuation, 1, info);
        if (st != Status.PRESENT) return (st, cov);
        cov = _listHead(r, l);
        info.rawTotal = l.count;
        if (r.resumed) {
            if (cursor[0] > l.count) return (Status.INVALID, cov);
            l.hi = cursor[0];
        }
        if (cov == Coverage.UNKNOWN) return (Status.UNKNOWN, cov);
    }

    function _end(Run memory r, TopicPageInfo memory info, List memory l, Coverage cov)
        private
        pure
    {
        uint64[] memory cursor = new uint64[](1);
        cursor[0] = l.hi;
        _finish(r, info, l.hi == 0 ? SCAN_EXHAUSTED : SCAN_LIMIT, cov, cursor);
    }
}

// forge-lint: disable-end(require-revert-in-loop)
// forge-lint: disable-end(calls-loop)
// forge-lint: disable-end(unsafe-typecast)
