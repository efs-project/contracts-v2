// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Purpose, ScopeKey} from "../interfaces/Actions.sol";
import {IBitmapStore} from "../interfaces/IBitmapStore.sol";
import {IIndexReads} from "../interfaces/IIndexReads.sol";
import {ILedgerHot} from "../interfaces/ILedgerHot.sol";
import {ILedgerReads} from "../interfaces/ILedgerReads.sol";
import {ILedgerViews} from "../interfaces/ILedgerViews.sol";
import {IFilesPageReader, IReader} from "../interfaces/Readers.sol";
import {BasisCommit, Coverage, Qualified, Status} from "../interfaces/Results.sol";
import {Keys} from "../lib/Keys.sol";

/// A dependency (the ledger, a facet, the index or its bitmap store) reverted, ran out of gas or has no code.
error E_FILES_READ(address source, bytes4 selector);
/// A dependency's reply is shorter than its ABI shape, or a word does not fit its declared width.
error E_FILES_REPLY(uint256 word, uint256 length);
/// A dependency's reply contradicts another reply or the kernel's own laws; codes on `FilesPageReader`.
error E_FILES_INCONSISTENT(uint8 code);
/// A facet answered a per-row read with a status the page cannot carry (LIMIT_EXCEEDED, UNSUPPORTED, UNKNOWN).
error E_FILES_STATUS(uint8 status);

// Reading the ABI replies word by word is the point of this reader: every reply is length-checked and every
// narrow field range-checked before use, so a short, padded or out-of-range reply is a named revert instead of
// a decoder revert or a silently truncated value. Calls (and the fault reverts) in loops are bounded by `limit`
// and `gasReserve`; `e / 256 * 256` is the bitmap word's first entry, a truncation by intent.
// forge-lint: disable-start(unsafe-typecast)
// forge-lint: disable-start(calls-loop)
// forge-lint: disable-start(require-revert-in-loop)
// forge-lint: disable-start(divide-before-multiply)

/// @title FilesPageReader/1 — Files directory pages and name lookup (design §5.13, §11, §12)
/// @notice Immutable and stateless. The ledger, the two read facets (`LedgerViews` for `headsAt`, `LedgerReads` for
///         `basis`, `bindingPosition`, `positionCell`, `bodySlice`, `bodyWords`, `recordHeader`) and the three Files
///         Type ids it interprets (`files-name/2`, `files-root/1`, `files-child/1`) are constructor immutables; the
///         live index is resolved per call from `ILedgerHot(ledger).index()` and never cached, its bitmap store
///         from `IIndexReads.bitmapStore()`. The reader never reads raw slots.
///
///         A directory listing walks, for each principal of the lens in order, that principal's FOLDER scope list
///         `Keys.scope(principal, FOLDER, folderSubject)` (`folderSubject` is the FOLDER bind's subject: the
///         `files-directory/1` record id) in append order, skipping entries whose live-scope bit is clear
///         (`IBitmapStore.liveWords`). Each live candidate's position is resolved with one `headsAt` over the
///         whole lens (ordered first touch; MASK_BEATS_FALLTHROUGH): selected at the candidate's own principal →
///         an ENTRY row; a higher principal BOUND → skipped here (that principal's own walk lists it once); a
///         higher principal MASKED → one WHITEOUT row (emitted by the first lower principal that has it BOUND).
///         Row fields are only those of `Query.fields` (F_NAME the name bytes via `bodySlice` of
///         `recordFromHash(nameType, role)`; F_HEADER, for a file row, the lens-selected HEAD's record id,
///         revision and body word 0, so reading the file after a page is one `LedgerReads.record` call; F_KIND
///         the target kind); `position`, `target`, `admission` and `rowKind` are always filled.
///
///         Row kinds: 1 ENTRY, 2 ALIAS (never produced in generation 1: `FilesFinalValidator` admits only file
///         subjects and directory records as FOLDER targets), 3 WHITEOUT, and 4 INVALID — a row that fails a
///         reader-side §12.1 law: a FOLDER target kind that is neither record nor subject, an absent name record
///         (F_NAME), or a HEAD whose target is not a `files-root/1`/`files-child/1` record whose file word is the
///         file (F_HEADER). INVALID rows are returned, never dropped. `Query.kinds` filters by bit: 1 directory
///         rows, 2 file rows, 4 whiteouts; 0 means all. Tags (F_TAGS, `tagConcept`) are S3: UNSUPPORTED.
///
///         Page laws (design §5.13): `q.status` PRESENT for a served page, BASIS_STALE when the expected basis
///         (`executionSet`, `indexGeneration`; a zero `executionSet` is unbound) or a continuation's basis differs
///         from the live one or a selected scope mutated after the continuation's origin (checked over every
///         scope of the lens, consumed or not), UNSUPPORTED on a foreign layout, an unlisted index profile or a
///         tag query, LIMIT_EXCEEDED past 64 principals, INVALID for an empty lens or a malformed continuation.
///         A refused page carries no rows, `listingCoverage` UNKNOWN and `scanStatus` 0 (no scan ran).
///         `scanStatus` 1 EXHAUSTED, 2 LIMIT (`limit` rows; 0 = no row limit), 3 GAS (`gasleft() < gasReserve`
///         before the next candidate; `gasReserve` must cover one row and the return encoding). `listingCoverage`
///         is the listing's: COMPLETE only when `completeFromOrigin` (origin-started, exhausted, every scope's
///         live-scope coverage COMPLETE); a page from a continuation is at most PARTIAL; UNKNOWN when any scope's
///         coverage is. `frontier` is the least coverage `through` of the scopes; `scanned` the scope-list
///         entries the cursor advanced over on this page (so the pages of an exhausted listing sum to
///         `rawTotal`); `selectedSoFar` the rows returned so far in the listing; `inventoryPin` commits to the
///         query, the origin and every scope's `(count, lastMutation)`. The continuation (`next`, empty when
///         exhausted) binds the query hash, the basis and the origin; it is not a MAC (paid completeness is
///         `QueryAccumulator`).
/// @dev Faults are named reverts, never fabricated rows: `E_FILES_READ` (a dependency failed), `E_FILES_REPLY` (a
///      short or out-of-range reply), `E_FILES_STATUS` (a per-row status the page cannot carry) and
///      `E_FILES_INCONSISTENT(code)`: 1 a scope's live bits disagree with its live count, 2 a scope head out of
///      range (live > count, lastMutation past the observed admissions), 3 scope entries not strictly increasing
///      or out of range, 4 a binding ordinal without a FOLDER position of this folder, 5 `headsAt` contradicts
///      itself or the live bit (status vs state, selected index, lens length), 6 a reply's echoed basis differs
///      from the page's, 7 a name body whose hash is not its role, 8 a coverage frontier past the observed
///      admissions or a COMPLETE coverage whose frontier is not the observed admissions, 9 a bound HEAD whose
///      record target is absent, 10 a head admission past the observed admissions.
contract FilesPageReader is IFilesPageReader {
    uint32 internal constant F_NAME = 1;
    uint32 internal constant F_HEADER = 2;
    uint32 internal constant F_KIND = 4;
    uint32 internal constant F_TAGS = 8;
    uint8 internal constant ROW_ENTRY = 1;
    uint8 internal constant ROW_WHITEOUT = 3;
    uint8 internal constant ROW_INVALID = 4;
    uint8 internal constant KIND_DIRECTORY = 1;
    uint8 internal constant KIND_FILE = 2;
    uint8 internal constant KIND_WHITEOUT = 4;
    uint8 internal constant SCAN_EXHAUSTED = 1;
    uint8 internal constant SCAN_LIMIT = 2;
    uint8 internal constant SCAN_GAS = 3;
    uint8 internal constant TARGET_RECORD = 1;
    uint8 internal constant TARGET_SUBJECT = 2;
    uint256 internal constant MAX_PRINCIPALS = 64;
    uint256 internal constant NAME_MAX = 255;
    /// A lower bound on the gas one returned row costs (it is ≈ 150k measured), so the row pointer array is sized
    /// by what the call can still pay for and never by the scope list's size.
    uint256 internal constant ROW_GAS_FLOOR = 20_000;
    uint256 internal constant SELECTED_NONE = 255;
    uint256 internal constant CONTINUATION_VERSION = 1;
    uint256 internal constant CONTINUATION_BYTES = 9 * 32;
    bytes32 internal constant FAMILY_LIVE_SCOPE = keccak256("efs2/family/live-scope/1");
    bytes32 internal constant DOM_QUERY = keccak256("efs2/files-page/query/1");
    bytes32 internal constant DOM_PIN = keccak256("efs2/files-page/inventory/1");
    /// The one physical and callback profile served (generation 1, `RealmIndex`).
    bytes32 internal constant PHYSICAL_PROFILE =
        keccak256("efs2/index-layout/1:stores:inline-singleton:five-u48:live-bits-in-head");
    bytes32 internal constant CALLBACK_PROFILE =
        keccak256("efs2/index-callback/3:ordered-prefix:static-final:effect-24:refs");

    address public immutable LEDGER;
    address public immutable VIEWS;
    address public immutable READS;
    bytes32 public immutable LAYOUT;
    bytes32 public immutable NAME_TYPE;
    bytes32 public immutable ROOT_TYPE;
    bytes32 public immutable CHILD_TYPE;

    /// The working state of one call.
    struct Run {
        bytes32 folder;
        uint32 fields;
        uint8 kinds;
        address index;
        address store;
        BasisCommit observed;
        bytes32 queryHash;
        uint64 origin;
        uint256 lensIndex;
        uint256 entryIndex;
        uint256 liveSeen;
        uint256 selected;
        uint256 rows;
        uint256 scanned;
        uint256 liveLeft;
    }

    /// One principal's FOLDER scope list.
    struct Scope {
        bytes32 key;
        uint256 count;
        uint256 live;
    }

    /// A decoded `headsAt` reply: the selected head and the raw reply (for the `all` heads).
    struct Sel {
        uint8 status;
        uint8 state;
        uint64 revision;
        uint64 admission;
        uint8 targetKind;
        bytes32 target;
        uint256 index;
        bytes ret;
    }

    /// @param ledger_ the ledger proxy this reader serves (its layout is pinned here: `layoutId()`)
    /// @param views_ the `LedgerViews` facet the reader calls for `headsAt`
    /// @param reads_ the `LedgerReads` facet the reader calls for rows, bodies and the basis
    /// @param nameType_ the `files-name/2` Type id; @param rootType_ `files-root/1`; @param childType_ `files-child/1`
    constructor(
        address ledger_,
        address views_,
        address reads_,
        bytes32 nameType_,
        bytes32 rootType_,
        bytes32 childType_
    ) {
        if (ledger_ == address(0) || views_ == address(0) || reads_ == address(0)) {
            revert E_FILES_READ(address(0), 0);
        }
        LEDGER = ledger_;
        VIEWS = views_;
        READS = reads_;
        LAYOUT = ILedgerHot(ledger_).layoutId();
        NAME_TYPE = nameType_;
        ROOT_TYPE = rootType_;
        CHILD_TYPE = childType_;
    }

    // =============================================================================================
    // IReader
    // =============================================================================================

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
    // listDirectory
    // =============================================================================================

    /// @inheritdoc IFilesPageReader
    function listDirectory(
        bytes32 folderSubject,
        bytes32[] calldata principals,
        Query calldata q,
        BasisCommit calldata expected,
        bytes calldata continuation,
        uint32 limit,
        uint256 gasReserve
    ) external view returns (DirectoryPage memory page) {
        Run memory r;
        Status st;
        (st, r.observed, r.index, r.store) = _open(expected, principals.length);
        page.q.observed = r.observed;
        page.listingCoverage = Coverage.UNKNOWN;
        page.observedCurrent = r.observed.admissionHighWater;
        if (st == Status.PRESENT && (q.fields & F_TAGS != 0 || q.tagConcept != 0)) {
            st = Status.UNSUPPORTED;
        }
        r.folder = folderSubject;
        r.fields = q.fields;
        r.kinds = q.kinds == 0 ? KIND_DIRECTORY | KIND_FILE | KIND_WHITEOUT : q.kinds;
        r.queryHash =
            keccak256(abi.encode(DOM_QUERY, LEDGER, folderSubject, principals, q.fields, q.kinds));
        r.origin = r.observed.admissionHighWater;
        page.startsAtOrigin = continuation.length == 0;
        if (st == Status.PRESENT && !page.startsAtOrigin) {
            st = _resume(r, continuation, principals.length);
        }
        if (st != Status.PRESENT) {
            page.q.status = st;
            return page;
        }
        // every scope of the lens: inventory, coverage, the relaxed-continuation law and the row capacity
        Scope[] memory scopes = new Scope[](principals.length);
        bytes32 pin = keccak256(abi.encode(DOM_PIN, r.queryHash, r.origin));
        Coverage cov = Coverage.COMPLETE;
        uint64 frontier = type(uint64).max;
        uint256 capacity = 0;
        for (uint256 i; i < principals.length; ++i) {
            Scope memory s = scopes[i];
            s.key = Keys.scope(principals[i], Purpose.FOLDER, folderSubject);
            (uint256 count, uint256 live, uint256 lastMutation) = _scopeHead(r, s.key);
            s.count = count;
            s.live = live;
            if (!page.startsAtOrigin && lastMutation > r.origin) {
                page.q.status = Status.BASIS_STALE;
                return page;
            }
            pin = keccak256(abi.encode(pin, s.count, lastMutation));
            page.rawTotal += uint64(s.count);
            (Coverage c, uint64 through) = _coverage(r, s.key);
            if (through < frontier) frontier = through;
            if (c == Coverage.UNKNOWN) cov = Coverage.UNKNOWN;
            else if (c == Coverage.PARTIAL && cov == Coverage.COMPLETE) cov = Coverage.PARTIAL;
            if (i > r.lensIndex) {
                capacity += s.live;
            } else if (i == r.lensIndex) {
                capacity += s.live - (r.liveSeen > s.live ? s.live : r.liveSeen);
            }
        }
        r.liveLeft = capacity;
        if (limit != 0 && limit < capacity) capacity = limit;
        if (gasleft() / ROW_GAS_FLOOR < capacity) capacity = gasleft() / ROW_GAS_FLOOR;
        // a pointer array only: a row is allocated when it is produced
        Row[] memory slots;
        assembly ("memory-safe") {
            slots := mload(0x40)
            mstore(slots, capacity)
            mstore(0x40, add(slots, mul(add(capacity, 1), 32)))
        }
        page.rows = slots;
        uint8 scan = _scan(r, scopes, principals, slots, limit, gasReserve);
        Row[] memory rows = page.rows;
        uint256 n = r.rows;
        assembly ("memory-safe") {
            mstore(rows, n)
        }
        page.q.status = Status.PRESENT;
        page.scanStatus = scan;
        page.scanned = uint64(r.scanned);
        page.selectedSoFar = uint64(r.selected);
        page.inventoryPin = pin;
        page.frontier = frontier;
        page.completeFromOrigin =
            page.startsAtOrigin && scan == SCAN_EXHAUSTED && cov == Coverage.COMPLETE;
        page.listingCoverage = page.completeFromOrigin
            ? Coverage.COMPLETE
            : cov == Coverage.UNKNOWN ? Coverage.UNKNOWN : Coverage.PARTIAL;
        if (scan != SCAN_EXHAUSTED) {
            page.next = abi.encode(
                CONTINUATION_VERSION,
                r.queryHash,
                r.observed.executionSet,
                r.observed.indexGeneration,
                r.origin,
                r.lensIndex,
                r.entryIndex,
                r.liveSeen,
                r.selected
            );
        }
    }

    /// The basis, the layout, the lens bound, the expected basis and the live index's profile, in that order.
    function _open(BasisCommit calldata expected, uint256 lens)
        private
        view
        returns (Status, BasisCommit memory b, address index, address store)
    {
        bytes memory ret = _sc(READS, abi.encodeCall(ILedgerReads.basis, (LEDGER)));
        b.executionSet = bytes32(_w(ret, 0));
        b.revision = uint32(_n(ret, 1, 32));
        b.indexGeneration = uint32(_n(ret, 2, 32));
        b.registryMutations = uint64(_n(ret, 3, 64));
        b.admissionHighWater = uint64(_n(ret, 4, 64));
        b.phase = uint8(_n(ret, 5, 8));
        if (bytes32(_w(_sc(LEDGER, abi.encodeCall(ILedgerHot.layoutId, ())), 0)) != LAYOUT) {
            return (Status.UNSUPPORTED, b, index, store);
        }
        if (lens == 0) return (Status.INVALID, b, index, store);
        if (lens > MAX_PRINCIPALS) return (Status.LIMIT_EXCEEDED, b, index, store);
        if (
            expected.executionSet != 0
                && (expected.executionSet != b.executionSet
                    || expected.indexGeneration != b.indexGeneration)
        ) return (Status.BASIS_STALE, b, index, store);
        index = address(uint160(_n(_sc(LEDGER, abi.encodeCall(ILedgerHot.index, ())), 0, 160)));
        // the generation's profile constants; a generation that does not expose them is not served
        if (
            _profile(index, bytes4(keccak256("PHYSICAL_PROFILE()"))) != PHYSICAL_PROFILE
                || _profile(index, bytes4(keccak256("CALLBACK_PROFILE()"))) != CALLBACK_PROFILE
        ) return (Status.UNSUPPORTED, b, index, store);
        store =
            address(uint160(_n(_sc(index, abi.encodeCall(IIndexReads.bitmapStore, ())), 0, 160)));
        return (Status.PRESENT, b, index, store);
    }

    function _profile(address index, bytes4 selector) private view returns (bytes32 p) {
        (bool ok, bytes memory ret) = index.staticcall(abi.encodeWithSelector(selector));
        if (ok && ret.length >= 32) p = bytes32(_w(ret, 0));
    }

    /// Decodes and binds a continuation: INVALID when malformed or for another query, BASIS_STALE when the
    /// basis it was minted under is not the live one.
    function _resume(Run memory r, bytes calldata c, uint256 lens) private pure returns (Status) {
        if (c.length != CONTINUATION_BYTES) return Status.INVALID;
        (
            uint256 version,
            bytes32 queryHash,
            bytes32 executionSet,
            uint256 indexGeneration,
            uint256 origin,
            uint256 lensIndex,
            uint256 entryIndex,
            uint256 liveSeen,
            uint256 selected
        ) = abi.decode(
            c, (uint256, bytes32, bytes32, uint256, uint256, uint256, uint256, uint256, uint256)
        );
        if (
            version != CONTINUATION_VERSION || queryHash != r.queryHash || lensIndex >= lens
                || origin > r.observed.admissionHighWater || entryIndex >= 1 << 48
                || liveSeen > entryIndex || selected >= 1 << 64
        ) return Status.INVALID;
        if (
            executionSet != r.observed.executionSet || indexGeneration != r.observed.indexGeneration
        ) {
            return Status.BASIS_STALE;
        }
        r.origin = uint64(origin);
        r.lensIndex = lensIndex;
        r.entryIndex = entryIndex;
        r.liveSeen = liveSeen;
        r.selected = selected;
        return Status.PRESENT;
    }

    // =============================================================================================
    // The scan
    // =============================================================================================

    /// Walks the scopes from the cursor; leaves the cursor at the first unexamined candidate.
    function _scan(
        Run memory r,
        Scope[] memory scopes,
        bytes32[] calldata principals,
        Row[] memory rows,
        uint32 limit,
        uint256 gasReserve
    ) private view returns (uint8) {
        Row memory slot = _fresh(); // reused by candidates that produce no row
        for (uint256 i = r.lensIndex; i < scopes.length; ++i) {
            Scope memory s = scopes[i];
            uint256 e = i == r.lensIndex ? r.entryIndex : 0;
            uint256 seen = i == r.lensIndex ? r.liveSeen : 0;
            uint256 start = e;
            uint256 last = 0; // the last ordinal examined in this scope (strictly increasing)
            while (e < s.count) {
                uint256 wordIndex = e / 256;
                uint256 end = (wordIndex + 1) * 256;
                if (end > s.count) end = s.count;
                uint256 word = _liveWord(r.store, s.key, wordIndex);
                // the bits of this word at or after e and before end
                uint256 bits = (word >> (e % 256)) << (e % 256);
                if (end % 256 != 0) bits &= (uint256(1) << (end % 256)) - 1;
                if (bits == 0) {
                    e = end;
                    continue;
                }
                uint64[] memory ordinals = new uint64[](0);
                uint256 lo = e;
                for (uint256 b = e % 256; b < 256 && bits >> b != 0; ++b) {
                    if ((bits >> b) & 1 == 0) continue;
                    uint256 idx = wordIndex * 256 + b;
                    // every live entry left already produced a row: one more set bit is past the count
                    if (r.rows == r.liveLeft) revert E_FILES_INCONSISTENT(1);
                    if (
                        (limit != 0 && r.rows == limit) || r.rows == rows.length
                            || gasleft() < gasReserve
                    ) {
                        r.lensIndex = i;
                        r.entryIndex = idx;
                        r.liveSeen = seen;
                        r.scanned += idx - start;
                        return limit != 0 && r.rows == limit ? SCAN_LIMIT : SCAN_GAS;
                    }
                    if (++seen > s.live) revert E_FILES_INCONSISTENT(1);
                    if (idx - lo >= ordinals.length) {
                        ordinals = _ordinals(r, s.key, idx, end, bits, limit);
                        lo = idx;
                    }
                    uint256 ordinal = ordinals[idx - lo];
                    if (ordinal <= last || ordinal > r.observed.admissionHighWater) {
                        revert E_FILES_INCONSISTENT(3);
                    }
                    last = ordinal;
                    if (_candidate(r, principals, i, uint64(ordinal), slot)) {
                        rows[r.rows] = slot;
                        ++r.rows;
                        ++r.selected;
                        slot = _fresh();
                    }
                }
                e = end;
            }
            if (seen != s.live) revert E_FILES_INCONSISTENT(1);
            r.scanned += s.count - start;
        }
        r.lensIndex = scopes.length;
        r.entryIndex = 0;
        r.liveSeen = 0;
        return SCAN_EXHAUSTED;
    }

    /// The binding ordinals of entries `[e, hi]`: `e` is a candidate and `hi` the last candidate of this word the
    /// page can still reach under `limit` (a filtered candidate yields no row, so a later batch may follow).
    function _ordinals(
        Run memory r,
        bytes32 key,
        uint256 e,
        uint256 end,
        uint256 bits,
        uint32 limit
    ) private view returns (uint64[] memory out) {
        uint256 hi = e;
        uint256 room = limit == 0 ? type(uint256).max : limit - r.rows;
        for (uint256 b = e % 256; b < 256 && bits >> b != 0 && room != 0; ++b) {
            if ((bits >> b) & 1 == 1) {
                hi = (e / 256) * 256 + b;
                --room;
            }
        }
        if (hi >= end) hi = end - 1;
        uint256 n = hi - e + 1;
        bytes memory ret = _sc(
            r.store,
            abi.encodeCall(IBitmapStore.scopeSlice, (ScopeKey.wrap(key), uint64(e), uint16(n)))
        );
        (uint256 base, uint256 len) = _array(ret, 0);
        if (len != n) revert E_FILES_INCONSISTENT(3);
        out = new uint64[](n);
        for (uint256 k; k < n; ++k) {
            out[k] = uint64(_n(ret, base + k, 48));
        }
    }

    /// A newly allocated zero row.
    function _fresh() private pure returns (Row memory row) {}

    /// One live candidate of principal `i`; true when it produced a row (`row` is untouched otherwise).
    function _candidate(
        Run memory r,
        bytes32[] calldata principals,
        uint256 i,
        uint64 ordinal,
        Row memory row
    ) private view returns (bool) {
        bytes memory ret = _sc(
            READS, abi.encodeCall(ILedgerReads.bindingPosition, (LEDGER, ordinal))
        );
        if (_status(ret, 0) != uint8(Status.PRESENT)) revert E_FILES_INCONSISTENT(4);
        bytes32 position = bytes32(_w(ret, 1));
        ret = _sc(READS, abi.encodeCall(ILedgerReads.positionCell, (LEDGER, position)));
        bytes32 role = bytes32(_w(ret, 3));
        if (
            _status(ret, 0) != uint8(Status.PRESENT)
                || Keys.position(Purpose.FOLDER, r.folder, role) != position
        ) revert E_FILES_INCONSISTENT(4);
        Sel memory s = _headsAt(r, principals, position);
        // the candidate's own head is BOUND (its live bit is set), so the first touch is at or above it
        if (s.index > i || _allState(s, i) != 1) revert E_FILES_INCONSISTENT(5);
        uint8 rowKind = ROW_ENTRY;
        if (s.index < i) {
            if (s.status == uint8(Status.PRESENT)) return false; // listed by the higher principal's walk
            for (uint256 k = s.index + 1; k < i; ++k) {
                if (_allState(s, k) == 1) return false; // the whiteout was reported by principal k
            }
            rowKind = ROW_WHITEOUT;
        }
        uint8 tk = s.targetKind;
        uint8 kindBit = rowKind == ROW_WHITEOUT
            ? KIND_WHITEOUT
            : tk == TARGET_RECORD ? KIND_DIRECTORY : tk == TARGET_SUBJECT ? KIND_FILE : 0;
        if (kindBit == 0) {
            rowKind = ROW_INVALID; // a target kind §12.1 does not place; returned under any filter
        } else if (r.kinds & kindBit == 0) {
            return false;
        }
        _row(r, principals, s, position, role, rowKind, row);
        return true;
    }

    /// Fills `row` from the selected head and, per `r.fields`, the name and the file's HEAD.
    function _row(
        Run memory r,
        bytes32[] calldata principals,
        Sel memory s,
        bytes32 position,
        bytes32 role,
        uint8 rowKind,
        Row memory row
    ) private view {
        row.position = position;
        row.target = s.target;
        row.admission = s.admission;
        if (r.fields & F_KIND != 0) row.targetKind = s.targetKind;
        if (r.fields & F_NAME != 0 && !_name(role, row)) rowKind = ROW_INVALID;
        if (
            r.fields & F_HEADER != 0 && rowKind == ROW_ENTRY && s.targetKind == TARGET_SUBJECT
                && !_header(r, principals, s.target, row)
        ) rowKind = ROW_INVALID;
        row.rowKind = rowKind;
    }

    /// The name bytes of `role`; false when no `files-name/2` record carries it.
    function _name(bytes32 role, Row memory row) private view returns (bool) {
        bytes memory ret = _sc(
            READS,
            abi.encodeCall(
                ILedgerReads.bodySlice,
                (LEDGER, Keys.recordFromHash(NAME_TYPE, role), 0, uint32(NAME_MAX))
            )
        );
        uint8 st = _status(ret, 0);
        if (st == uint8(Status.ABSENT_PROVEN)) return false;
        if (st != uint8(Status.PRESENT)) revert E_FILES_STATUS(st);
        bytes memory name = _bytes(ret, 1);
        if (keccak256(name) != role) revert E_FILES_INCONSISTENT(7);
        row.name = name;
        return true;
    }

    /// The lens-selected HEAD of `file`; false when the bound HEAD breaks the §12.1 HEAD law.
    function _header(Run memory r, bytes32[] calldata principals, bytes32 file, Row memory row)
        private
        view
        returns (bool)
    {
        Sel memory h = _headsAt(r, principals, Keys.position(Purpose.HEAD, file, 0));
        row.headRevision = h.revision;
        if (h.status != uint8(Status.PRESENT)) return true; // no bound HEAD: no record to read
        row.headRecord = h.target;
        if (h.targetKind != TARGET_RECORD) return false; // a HEAD on a subject is not a revision
        bytes memory ret = _sc(READS, abi.encodeCall(ILedgerReads.recordHeader, (LEDGER, h.target)));
        uint8 st = _status(ret, 0);
        if (st == uint8(Status.ABSENT_PROVEN)) revert E_FILES_INCONSISTENT(9);
        if (st != uint8(Status.PRESENT)) revert E_FILES_STATUS(st);
        bytes32 typeId = bytes32(_w(ret, 1));
        uint256 length = _n(ret, 3, 32);
        bytes32 word0 = bytes32(_w(ret, 6));
        row.headerWord0 = word0;
        if (typeId == ROOT_TYPE) return length >= 32 && word0 == file;
        if (typeId != CHILD_TYPE || length < 64) return false;
        ret = _sc(READS, abi.encodeCall(ILedgerReads.bodyWords, (LEDGER, h.target, 1, 1)));
        st = _status(ret, 0);
        if (st != uint8(Status.PRESENT)) revert E_FILES_STATUS(st);
        (uint256 base, uint256 len) = _array(ret, 1);
        if (len != 1) revert E_FILES_REPLY(base, len);
        return bytes32(_w(ret, base)) == file;
    }

    // =============================================================================================
    // lookupName
    // =============================================================================================

    /// @inheritdoc IFilesPageReader
    /// @dev Every field is filled (F_NAME | F_HEADER | F_KIND). PRESENT with an ENTRY row, MASKED with a WHITEOUT
    ///      row, ABSENT_PROVEN (the kernel's heads are exact; no index coverage is involved) with only `position`,
    ///      INVALID with an INVALID row; the refusals of `listDirectory` otherwise.
    function lookupName(
        bytes32 folderSubject,
        bytes32 nameRole,
        bytes32[] calldata principals,
        BasisCommit calldata expected
    ) external view returns (Qualified memory q, Row memory row) {
        Run memory r;
        Status st;
        (st, r.observed,,) = _open(expected, principals.length);
        q.observed = r.observed;
        bytes32 position = Keys.position(Purpose.FOLDER, folderSubject, nameRole);
        row.position = position;
        if (st != Status.PRESENT) {
            q.status = st;
            return (q, row);
        }
        r.folder = folderSubject;
        r.fields = F_NAME | F_HEADER | F_KIND;
        Sel memory s = _headsAt(r, principals, position);
        if (s.status == uint8(Status.ABSENT_PROVEN)) {
            q.status = Status.ABSENT_PROVEN;
            return (q, row);
        }
        uint8 rowKind = s.status == uint8(Status.PRESENT) ? ROW_ENTRY : ROW_WHITEOUT;
        if (rowKind == ROW_ENTRY && s.targetKind != TARGET_RECORD && s.targetKind != TARGET_SUBJECT)
        {
            rowKind = ROW_INVALID;
        }
        _row(r, principals, s, position, nameRole, rowKind, row);
        q.status = row.rowKind == ROW_INVALID
            ? Status.INVALID
            : row.rowKind == ROW_WHITEOUT ? Status.MASKED : Status.PRESENT;
    }

    // =============================================================================================
    // Dependency reads (each reply length- and range-checked)
    // =============================================================================================

    /// One `headsAt` over the lens; only PRESENT, MASKED and ABSENT_PROVEN are carried.
    function _headsAt(Run memory r, bytes32[] calldata principals, bytes32 position)
        private
        view
        returns (Sel memory s)
    {
        s.ret = _sc(VIEWS, abi.encodeCall(ILedgerViews.headsAt, (LEDGER, principals, position)));
        bytes memory ret = s.ret;
        s.status = _status(ret, 0);
        s.state = uint8(_n(ret, 1, 8));
        s.revision = uint64(_n(ret, 2, 64));
        s.admission = uint64(_n(ret, 3, 64));
        s.targetKind = uint8(_n(ret, 4, 8));
        s.target = bytes32(_w(ret, 8));
        s.index = _n(ret, 9, 8);
        if (
            bytes32(_w(ret, 11)) != r.observed.executionSet
                || _w(ret, 15) != r.observed.admissionHighWater
        ) revert E_FILES_INCONSISTENT(6);
        if (
            s.status != uint8(Status.PRESENT) && s.status != uint8(Status.MASKED)
                && s.status != uint8(Status.ABSENT_PROVEN)
        ) revert E_FILES_STATUS(s.status);
        (, uint256 len) = _array(ret, 10);
        bool none = s.index == SELECTED_NONE;
        if (
            len != principals.length || (none != (s.status == uint8(Status.ABSENT_PROVEN)))
                || (!none && (s.index >= len || _allState(s, s.index) != s.state))
                || (s.status == uint8(Status.PRESENT)) != (s.state == 1)
                || (s.status == uint8(Status.MASKED)) != (s.state == 2)
                || (s.state != 1 && s.target != 0)
        ) revert E_FILES_INCONSISTENT(5);
        if (s.admission > r.observed.admissionHighWater) revert E_FILES_INCONSISTENT(10);
    }

    /// The state of head `k` of a `headsAt` reply's `all` array.
    function _allState(Sel memory s, uint256 k) private pure returns (uint256) {
        (uint256 base, uint256 len) = _array(s.ret, 10);
        if (k >= len) revert E_FILES_INCONSISTENT(5);
        return _n(s.ret, base + k * 8, 8);
    }

    function _scopeHead(Run memory r, bytes32 key)
        private
        view
        returns (uint256 count, uint256 live, uint256 lastMutation)
    {
        bytes memory ret =
            _sc(r.store, abi.encodeCall(IBitmapStore.scopeHead, (ScopeKey.wrap(key))));
        count = _n(ret, 0, 48);
        live = _n(ret, 1, 48);
        lastMutation = _n(ret, 2, 64);
        if (live > count || lastMutation > r.observed.admissionHighWater) {
            revert E_FILES_INCONSISTENT(2);
        }
    }

    function _coverage(Run memory r, bytes32 key)
        private
        view
        returns (Coverage c, uint64 through)
    {
        bytes memory ret = _sc(
            r.index, abi.encodeWithSelector(IIndexReads.coverage.selector, FAMILY_LIVE_SCOPE, key)
        );
        uint256 v = _n(ret, 0, 8);
        if (v == 0 || v > uint8(Coverage.COMPLETE)) revert E_FILES_REPLY(0, v);
        c = Coverage(v);
        through = uint64(_n(ret, 2, 64));
        // COMPLETE means `through == admissions` (design §10.5); a frontier past the admissions is never served
        if (
            through > r.observed.admissionHighWater
                || (c == Coverage.COMPLETE && through != r.observed.admissionHighWater)
        ) revert E_FILES_INCONSISTENT(8);
    }

    function _liveWord(address store, bytes32 key, uint256 wordIndex)
        private
        view
        returns (uint256)
    {
        bytes memory ret = _sc(
            store,
            abi.encodeWithSelector(
                IBitmapStore.liveWords.selector, key, FAMILY_LIVE_SCOPE, wordIndex, uint16(1)
            )
        );
        (uint256 base, uint256 len) = _array(ret, 0);
        if (len != 1) revert E_FILES_REPLY(base, len);
        return _w(ret, base);
    }

    // ---- raw reply access -----------------------------------------------------------------------------------

    /// A staticcall that names the dependency and selector when it fails.
    function _sc(address target, bytes memory data) private view returns (bytes memory ret) {
        bool ok;
        (ok, ret) = target.staticcall(data);
        if (!ok) {
            bytes4 selector;
            assembly ("memory-safe") {
                selector := mload(add(data, 32))
            }
            revert E_FILES_READ(target, selector);
        }
    }

    /// Word `i` of a reply.
    function _w(bytes memory ret, uint256 i) private pure returns (uint256 x) {
        if (ret.length < (i + 1) * 32) revert E_FILES_REPLY(i, ret.length);
        assembly ("memory-safe") {
            x := mload(add(ret, mul(add(i, 1), 32)))
        }
    }

    /// Word `i` as an unsigned integer of `bits` bits.
    function _n(bytes memory ret, uint256 i, uint256 bits) private pure returns (uint256 x) {
        x = _w(ret, i);
        if (x >> bits != 0) revert E_FILES_REPLY(i, x);
    }

    /// A `Status` word: 1..12 (UNSET is a transport fault).
    function _status(bytes memory ret, uint256 i) private pure returns (uint8) {
        uint256 v = _w(ret, i);
        if (v == 0 || v > uint8(Status.LIMIT_EXCEEDED)) revert E_FILES_REPLY(i, v);
        return uint8(v);
    }

    /// The dynamic array whose offset is word `i`: the word index of its first element and its length.
    function _array(bytes memory ret, uint256 i) private pure returns (uint256 base, uint256 len) {
        uint256 off = _w(ret, i);
        if (off % 32 != 0 || off >= ret.length) revert E_FILES_REPLY(i, off);
        len = _w(ret, off / 32);
        base = off / 32 + 1;
        if (len > ret.length / 32 || (base + len) * 32 > ret.length) revert E_FILES_REPLY(i, len);
    }

    /// The dynamic `bytes` whose offset is word `i`.
    function _bytes(bytes memory ret, uint256 i) private pure returns (bytes memory out) {
        uint256 off = _w(ret, i);
        if (off % 32 != 0 || off >= ret.length) revert E_FILES_REPLY(i, off);
        uint256 len = _w(ret, off / 32);
        if (len > NAME_MAX || off + 32 + len > ret.length) revert E_FILES_REPLY(i, len);
        out = new bytes(len);
        assembly ("memory-safe") {
            mcopy(add(out, 32), add(add(ret, 64), off), len)
        }
    }
}

// forge-lint: disable-end(divide-before-multiply)
// forge-lint: disable-end(require-revert-in-loop)
// forge-lint: disable-end(calls-loop)
// forge-lint: disable-end(unsafe-typecast)
