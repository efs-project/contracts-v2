// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Coordinate, ScopeKey} from "./Actions.sol";
import {BasisCommit, Coverage, Qualified, Status} from "./Results.sol";
import {RecordHeader} from "./Views.sol";

// Readers — the Lens and Files page readers and the reader directory (design §5.13, §11). Readers resolve the
// live index per call (`ILedgerHot(ledger).index()`), serve any generation whose callbackProfile/physicalProfile
// they list in `supportedProfiles()` and return UNSUPPORTED otherwise; they pin layoutId through
// `BasisCommit.executionSet` and return BASIS_STALE/UNSUPPORTED as data. Listing-coverage law: a paged reader's
// coverage is the listing's, COMPLETE only when `completeFromOrigin`; a page produced from a continuation is at
// most PARTIAL. `scanStatus` (both page structs, and `TopicPageInfo`): 1 EXHAUSTED (the scope list ended) 2 LIMIT (row
// limit reached; for the topic views, entry limit) 3 GAS (gasReserve early stop) 4 ROWS (the topic views' `maxRows`
// reached); 0 and 5..255 reserved.

/// A Lens listing continuation. lensHash = keccak(abi.encode(principals)); never msg.sender.
struct Cursor {
    BasisCommit basis;
    ScopeKey scope;
    bytes32 lensHash;
    uint64 lensIndex;
    uint64 rawIndex;
    uint64 selectedSoFar;
    bytes32 queryHash;
}

/// One resolved coordinate under a lens. `strength` is the selected head's (with `status`, its signed number:
/// `BindingNumber.numberOf`); 0 when nothing is selected.
struct Selection {
    Status status;
    bytes32 target;
    uint8 targetKind;
    uint64 revision;
    bytes32 principalId;
    uint64 admission;
    uint8 selectedIndex;
    uint16 strength;
}

/// One listed position.
struct Entry {
    bytes32 position;
    bytes32 role;
    Selection selection;
}

/// One page of a Lens listing.
struct Page {
    Qualified q;
    Entry[] rows;
    Cursor next;
    uint64 scanned;
    uint64 rawTotal;
    uint64 observedCurrent;
    uint64 selectedSoFar;
    bytes32 inventoryPin;
    uint8 scanStatus;
    bool startsAtOrigin;
    bool completeFromOrigin;
    Coverage listingCoverage;
}

/// @title IReader — the surface every reader listed in the directory implements (design §5.13)
interface IReader {
    function ledger() external view returns (address);

    function layoutId() external view returns (bytes32);

    function supportedProfiles()
        external
        view
        returns (bytes32[] memory callbackProfiles, bytes32[] memory physicalProfiles);
}

/// @title ILensReader — ordered-principal resolution and listing (design §5.13, §11)
/// @notice `fallThroughPolicy`: 1 MASK_BEATS_FALLTHROUGH (FOLDER, HEAD) or 2 SILENCE_FALLS_THROUGH (tag stances),
///         a reader parameter per purpose, not a kernel law.
interface ILensReader is IReader {
    function resolve(
        bytes32[] calldata principals,
        Coordinate calldata c,
        BasisCommit calldata expected
    ) external view returns (Qualified memory, Selection memory);

    /// One call: resolve + header + body.
    function resolveRecord(
        bytes32[] calldata principals,
        Coordinate calldata c,
        uint32 maxBytes,
        BasisCommit calldata expected
    )
        external
        view
        returns (Qualified memory, Selection memory, RecordHeader memory, bytes memory body);

    function resolveNoTiebreak(
        bytes32[] calldata principals,
        Coordinate calldata c,
        BasisCommit calldata expected
    ) external view returns (Qualified memory, Selection[] memory candidates);

    function resolveAt(
        bytes32[] calldata principals,
        Coordinate calldata c,
        uint64 asOf,
        BasisCommit calldata expected
    ) external view returns (Qualified memory, Selection memory);

    function resolveManyAt(
        bytes32[] calldata principals,
        Coordinate[] calldata coords,
        uint64 asOf,
        BasisCommit calldata expected
    ) external view returns (Qualified memory, Selection[] memory);

    function list(
        bytes32[] calldata principals,
        bytes32 purpose,
        bytes32 subject,
        Cursor calldata cursor,
        uint32 budget,
        uint8 fallThroughPolicy,
        BasisCommit calldata expected
    ) external view returns (Page memory);
}

/// @title IFilesPageReader — Files directory pages and name lookup (design §5.13, §12)
/// @notice Continuations are bound to (queryHash, basis) and refused otherwise.
interface IFilesPageReader is IReader {
    /// fields: F_NAME 1, F_HEADER 2, F_KIND 4, F_TAGS 8.
    struct Query {
        uint32 fields;
        bytes32 tagConcept;
        uint8 kinds;
    }

    /// headRecord/headRevision/headerWord0: the resolved HEAD record of a file row under F_HEADER (so a file
    /// read after a page is one `record()` call); rowKind: 1 ENTRY 2 ALIAS 3 WHITEOUT.
    struct Row {
        bytes32 position;
        bytes name;
        uint8 targetKind;
        bytes32 target;
        bytes32 headRecord;
        uint64 headRevision;
        uint64 admission;
        bytes32 headerWord0;
        uint8 rowKind;
    }

    /// One directory page; see the listing-coverage law above.
    struct DirectoryPage {
        Qualified q;
        Row[] rows;
        Coverage listingCoverage;
        uint64 frontier;
        bytes next;
        uint64 scanned;
        uint64 rawTotal;
        uint64 observedCurrent;
        uint64 selectedSoFar;
        bytes32 inventoryPin;
        uint8 scanStatus;
        bool startsAtOrigin;
        bool completeFromOrigin;
    }

    function listDirectory(
        bytes32 folderSubject,
        bytes32[] calldata principals,
        Query calldata q,
        BasisCommit calldata expected,
        bytes calldata continuation,
        uint32 limit,
        uint256 gasReserve
    ) external view returns (DirectoryPage memory);

    function lookupName(
        bytes32 folderSubject,
        bytes32 nameRole,
        bytes32[] calldata principals,
        BasisCommit calldata expected
    ) external view returns (Qualified memory, Row memory);
}

/// @title IReaderDirectory — the permissionless, append-only, advisory reader directory (design §5.13)
interface IReaderDirectory {
    /// Requires real code and IReader(reader).ledger() == ledger; records codehash, layoutId, physicalProfile.
    function list(address ledger, bytes32 kind, address reader) external;

    /// physicalProfiles[i] = the reader's first listed physical profile at listing time.
    function readers(address ledger, bytes32 kind, uint16 from, uint16 count)
        external
        view
        returns (
            address[] memory,
            bytes32[] memory codehashes,
            bytes32[] memory layoutIds,
            bytes32[] memory physicalProfiles,
            uint16 next
        );
}

// =============================================================================================
// Topic readers (design §5.13, §11; docs/TAG-DESIGN.md §6). A place is a topic or a home; "below" is the place
// and everything filed under its descendant topics. Every list they page is append-only and is read newest first,
// which means most recently first-stated (design §10.2): an entry is written at an author's first statement on a
// position, and the state and the number always come from the head.
// =============================================================================================

/// The page laws of every topic view: `q.status` PRESENT for a served page, UNKNOWN when a list the view needs has
/// coverage UNKNOWN (no rows: an UNKNOWN is never empty), BASIS_STALE / UNSUPPORTED / LIMIT_EXCEEDED / INVALID as
/// refusals with no rows. A page's work is bounded by the list entries it reads (`limit`, 0 = only the gas reserve);
/// the paged views `mine` and `everyone` also take `maxRows` (0 = no cap), and stop at whichever bound comes first.
/// Repeats, hidden and unaffirmed entries return nothing, so a page may hold fewer rows than `limit`, or none, while
/// entries remain. The list is finished only when `scanStatus` is 1 EXHAUSTED (and `next` is empty); 2 LIMIT (`limit`
/// entries read), 3 GAS (`gasReserve` stop) and 4 ROWS (`maxRows` rows returned) always carry `next`, the place to
/// resume. A page that is not refused reads at least one entry whatever its bounds and reserve, so a caller always
/// makes progress. `next` holds one resume index per merged list, counted from the START of that list (entries
/// `[0, index)` are still unread): a list only grows at its end, so entries appended between pages never shift it,
/// and a later page continues exactly where the previous one stopped (the appended entries are newer than the
/// listing's origin and are not part of it).
/// `listingCoverage` COMPLETE only when `completeFromOrigin` (origin-started, exhausted, every list COMPLETE); a page
/// from a continuation is at most PARTIAL. `scanned`: list entries read on this page; `rawTotal`: the entries
/// (filings) of every list at this page's read; `positionsEver`: for the place-list views (`everyone`, `about`), the
/// lists' `live` counts, the distinct positions ever stated (an "about" figure, never a row count; 0 for other views);
/// `selectedSoFar`: rows returned so far in the listing. `next` is bound to the query hash, the basis and the origin.
/// `frontier`: the entry the continuation's next page reads first, i.e. the newest entry of the listing not yet
/// processed (an entry fetched into a window but not processed when the page stopped counts as unread), in the number
/// space of the view's row entry field: binding ordinals (`bindingOrdinal`) in `mine`, `everyone` and `about`,
/// admission ordinals in `byName` (`firstAdmission`), `wordPage` and `children` (`admission`). For a merged view it is
/// the largest, over the merged lists, of each list's next unread entry. Entries are never 0 (both ordinals start at
/// 1), so on a PRESENT page `frontier` is 0 exactly when `scanStatus` is 1 EXHAUSTED; it is 0 on every refusal. The
/// guarantee: every row any later page of this listing returns has an entry <= `frontier`, every row of this page and
/// of earlier pages has an entry > `frontier` (strictly), and `frontier` falls strictly from page to page (each page
/// reads at least one entry, rows or not). Two exceptions: the root row of `wordPage`'s first page is not a list entry
/// (its `admission` is the word page's own, older than every entry), and in `mine` a lens that names one principal
/// twice reads that author's lists twice, so a row's entry can equal `frontier` and `frontier` can repeat. Frontiers
/// of different views, or of listings started at different origins, are not promised to be comparable.
/// `repeatsSkipped`: entries this page left out because a row for the same thing was already on it.
/// `dedupWithinPageOnly`: true for every view whose lists can name one thing more than once (a place list's later
/// first yeses, a thing filed under two topics of a roll-up, a lens row that moved between pages): repeats are
/// removed within this page only (by thing; at one place, a thing is a position), since a reader keeps no state
/// between calls, so a consumer removes repeats across pages.
struct TopicPageInfo {
    Qualified q;
    Coverage listingCoverage;
    uint8 scanStatus;
    bool startsAtOrigin;
    bool completeFromOrigin;
    bool dedupWithinPageOnly;
    uint64 scanned;
    uint64 frontier;
    uint64 rawTotal;
    uint64 positionsEver;
    uint64 selectedSoFar;
    uint64 repeatsSkipped;
    bytes next;
}

/// One row of `mine`: the thing (`thing`, the position's role) filed under `topic` (the position's subject), with
/// the deciding lens author (`decider` its lens index, `principalId`) and that author's head: the number, the
/// target kind, the revision and the admission. `bindingOrdinal` is the list entry (the decider's binding).
struct MineRow {
    bytes32 position;
    bytes32 topic;
    bytes32 thing;
    uint8 targetKind;
    uint8 decider;
    bytes32 principalId;
    int32 number;
    uint64 revision;
    uint64 admission;
    uint64 bindingOrdinal;
}

/// One row of `everyone` (or `raw`) and of `about`: a position (`thing` filed under `topic`), the list entry
/// (`bindingOrdinal`), who decided the row (`decider`: the lens index of the first lens author with a stance at the
/// position, and `number` that author's signed number; 255 and 0 when no lens author has one and the public tier,
/// someone's yes, decided; always 255 in `raw` and `about`, which read no lens), its statements (`statements`:
/// authors who ever stated anything there) and how many say yes now (`yes`), both exact from one head read; then a
/// sample of the newest `sampled` authors: `sampleYes` say >= 0, `sampleNo` say < 0, and `incomplete` when the sample
/// did not cover every author. The sample is detail, never the basis for showing a row.
struct PlaceRow {
    bytes32 position;
    bytes32 topic;
    bytes32 thing;
    uint64 bindingOrdinal;
    uint8 decider;
    int32 number;
    uint64 statements;
    uint64 yes;
    uint16 sampled;
    uint16 sampleYes;
    uint16 sampleNo;
    bool incomplete;
}

/// One author at one position (`byName`): the author's first statement there (`firstAdmission`, the list entry),
/// the head's status (PRESENT, MASKED or RELEASED), number (0 when RELEASED), target and target kind (0 unless
/// PRESENT), revision and admission.
struct AuthorRow {
    bytes32 principalId;
    uint64 firstAdmission;
    Status status;
    int32 number;
    bytes32 target;
    uint8 targetKind;
    uint64 revision;
    uint64 admission;
}

/// One place of a word page or of a topic's children: the place, the admission of its first registration, and
/// two "about" figures at TAG: `positionsEver`, the distinct positions that ever received a statement at the place
/// (the place list's `live`), and `positionsEverBelow`, the same below it (the roll-up's `live`), both including
/// positions nobody says yes to now, so neither is the number of rows a public view returns; then the filings
/// behind each (`filings`, `filingsBelow`: the lists' `count`, first statements plus later first yeses).
struct PlaceCount {
    bytes32 place;
    uint64 admission;
    uint64 positionsEver;
    uint64 positionsEverBelow;
    uint64 filings;
    uint64 filingsBelow;
}

/// @title ITopicMineReader — the lens view of a place (design §5.13, §11; docs/TAG-DESIGN.md §6)
interface ITopicMineReader is IReader {
    /// The lens's own entries at `place` (exact), or with `below` the place and everything below it, newest first;
    /// `limit` list entries read and `maxRows` rows returned (0 = no bound), whichever comes first.
    function mine(
        bytes32[] calldata lens,
        bytes32 place,
        bool below,
        BasisCommit calldata expected,
        bytes calldata continuation,
        uint32 limit,
        uint32 maxRows,
        uint256 gasReserve
    ) external view returns (TopicPageInfo memory, MineRow[] memory);
}

/// @title ITopicEveryoneReader — the public views of a place (design §5.13, §11; docs/TAG-DESIGN.md §6)
interface ITopicEveryoneReader is IReader {
    /// `everyone` / `raw` query: the place list at `purpose` (TAG or FOLDER), or with `below` (TAG only) the
    /// roll-up; `raw` skips the lens; `sample` newest authors are sampled per row (0: none).
    struct PlaceQuery {
        bytes32 purpose;
        bytes32 place;
        bool below;
        bool raw;
        uint16 sample;
    }

    /// Every author's positions at a place (and below it), newest first: rows someone says yes to, minus what the
    /// lens hides; with `raw`, every row. `limit` list entries read and `maxRows` rows returned (0 = no bound).
    function everyone(
        PlaceQuery calldata query,
        bytes32[] calldata lens,
        BasisCommit calldata expected,
        bytes calldata continuation,
        uint32 limit,
        uint32 maxRows,
        uint256 gasReserve
    ) external view returns (TopicPageInfo memory, PlaceRow[] memory);
}

/// @title ITopicLookupReader — one position's authors, a thing's places, counts, word pages and children (design §5.13,
///        §11)
interface ITopicLookupReader is IReader {
    /// The authors of one position, newest first-stated first; at most 64 rows per page.
    function byName(
        bytes32 position,
        BasisCommit calldata expected,
        bytes calldata continuation,
        uint16 limit
    ) external view returns (TopicPageInfo memory, AuthorRow[] memory);

    /// Every place anyone filed `thing` under at TAG, either sign, newest first (`Keys.rolePlacesList`, one entry
    /// per position), each with the row of `everyone` (rows nobody says yes to included); no lens; at most 64 rows.
    function about(
        bytes32 thing,
        uint16 sample,
        BasisCommit calldata expected,
        bytes calldata continuation,
        uint16 limit
    ) external view returns (TopicPageInfo memory, PlaceRow[] memory);

    /// An "about" count of a place at `purpose`, or below it (TAG): `positionsEver`, the distinct positions that ever
    /// received a statement (the list's `live`, including positions nobody says yes to now: never the number of rows
    /// a public view returns, and never a loop bound), and `filings` (the list's `count`).
    function placeCount(bytes32 purpose, bytes32 place, bool below, BasisCommit calldata expected)
        external
        view
        returns (Qualified memory, Coverage, uint64 positionsEver, uint64 filings);

    /// A position's authors: `statements` who ever stated anything there, `yes` who say yes now.
    function authorCount(bytes32 position, BasisCommit calldata expected)
        external
        view
        returns (Qualified memory, Coverage, uint64 statements, uint64 yes);

    /// One author's entries at a place: exact (`count`, and `live` the entries whose head is BOUND), or below it
    /// (TAG; `live` is not kept there and is returned 0).
    function entryCount(
        bytes32 principalId,
        bytes32 purpose,
        bytes32 place,
        bool below,
        BasisCommit calldata expected
    ) external view returns (Qualified memory, Coverage, uint64 count, uint64 live);

    /// The places whose own word is `wordPage`'s word: the root place `wordPage` itself (the first row of the first
    /// page), then every registered path whose last word it is, newest first.
    function wordPage(
        bytes32 wordPage,
        BasisCommit calldata expected,
        bytes calldata continuation,
        uint16 limit
    ) external view returns (TopicPageInfo memory, PlaceCount[] memory);

    /// A topic's child topics, newest first.
    function children(
        bytes32 topic,
        BasisCommit calldata expected,
        bytes calldata continuation,
        uint16 limit
    ) external view returns (TopicPageInfo memory, PlaceCount[] memory);
}
