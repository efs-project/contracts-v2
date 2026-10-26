// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Keys} from "../lib/Keys.sol";
import {Coordinate, FamilyId, Purpose, ScopeKey} from "../interfaces/Actions.sol";
import {ILedgerHot} from "../interfaces/ILedgerHot.sol";
import {ILedgerReads} from "../interfaces/ILedgerReads.sol";
import {ILedgerViews} from "../interfaces/ILedgerViews.sol";
import {IIndexReads} from "../interfaces/IIndexReads.sol";
import {IBitmapStore} from "../interfaces/IBitmapStore.sol";
import {Cursor, Entry, ILensReader, Page, Selection} from "../interfaces/Readers.sol";
import {BasisCommit, Coverage, History, Qualified, Status} from "../interfaces/Results.sol";
import {Head, RecordHeader} from "../interfaces/Views.sol";

// Every narrowing cast below reads one ABI word of a facet, hot-getter or store reply at the width that ABI
// declares; each such decode is re-encoded and compared with the raw words, so a reply word with dirty high bits
// is refused instead of truncated. The reader reads row by row through the facets, so calls in loops are its
// purpose, bounded by MAX_PRINCIPALS, MAX_COORDINATES and MAX_BUDGET.
// Tuples returning a literal `false` are the refusal paths of `_entry`; the constructor's three addresses are
// immutable bindings a deployer pins from `release.json` (a zero ledger cannot answer `layoutId()`).
// forge-lint: disable-start(unsafe-typecast)
// forge-lint: disable-start(calls-loop)
// forge-lint: disable-start(boolean-cst)
// forge-lint: disable-start(missing-zero-check)

/// @title LensReader/1 — ordered-principal resolution and listing over the ledger facets (design §11, §5.13)
/// @notice Immutable and stateless; bound at construction to one ledger and the two read facets it uses
///         (`LedgerViews` for `headsAt`/`historyAt`, `LedgerReads` for the basis, records and position cells),
///         which are immutable code at their own addresses and cannot be discovered from the ledger. It never
///         reads raw slots: besides the facets it calls only the Etched hot getters (`head`, `recordHeader`,
///         `index`) and, for `list`, the live index generation (`ILedgerHot(ledger).index()`, resolved per call)
///         and that generation's `BitmapStore`.
///
///         The flat-ordered law (M1): the first principal, in the given order, whose head is BOUND wins; a
///         MASKED head at an earlier principal beats every later principal (mask beats fall-through); RELEASED
///         and UNSET heads fall through; a head this reader cannot interpret (a reserved state, an unreadable or
///         inconsistent reply) is UNKNOWN and never falls through. `resolveNoTiebreak` returns every live
///         candidate: PRESENT for exactly one live candidate and no mask, CONFLICT for more than one live
///         candidate or a live candidate beside a mask, MASKED for masks only, ABSENT_PROVEN for none.
///
///         Statuses travel as data, never as zero sentinels: every reply this reader consumes is shape-checked
///         (exact length, canonical offsets, field widths) and cross-checked (the basis each facet echoes equals
///         the basis observed through `LedgerReads.basis`; `headsAt`'s selection equals the reader's own
///         recomputation over the returned heads; every head a result rests on equals the Etched
///         `ILedgerHot.head` row; a returned record body hashes to its record id). Any failed check yields
///         UNKNOWN. `expected`: an all-zero `executionSet` is an unpinned read; otherwise `executionSet` and
///         `indexGeneration` must equal the observed basis and `admissionHighWater` must not exceed it, else
///         BASIS_STALE.
contract LensReader is ILensReader {
    uint16 public constant FACET_VERSION = 1;
    /// Principals per call (design §11: one `headsAt` for up to 64 principals).
    uint256 public constant MAX_PRINCIPALS = 64;
    /// Coordinates per `resolveManyAt`.
    uint256 public constant MAX_COORDINATES = 64;
    /// `historyAt` hops per principal in the as-of reads.
    uint16 public constant MAX_HOPS = 64;
    /// Scope entries scanned per `list` page; a larger budget is clamped.
    uint256 public constant MAX_BUDGET = 256;
    /// `fallThroughPolicy` (low 7 bits): 1 a MASKED head at an earlier principal hides the position.
    uint8 public constant MASK_BEATS_FALLTHROUGH = 1;
    /// `fallThroughPolicy` (low 7 bits): 2 only a BOUND head decides; MASKED, RELEASED and UNSET fall through.
    uint8 public constant SILENCE_FALLS_THROUGH = 2;
    /// `fallThroughPolicy` bit 7: the strict continuation law (`observedCurrent == origin`).
    uint8 public constant STRICT_CONTINUATION = 0x80;
    /// The generation-1 index profiles this reader serves (`RealmIndex.CALLBACK_PROFILE`/`PHYSICAL_PROFILE`).
    bytes32 public constant CALLBACK_PROFILE =
        keccak256("efs2/index-callback/3:ordered-prefix:static-final:effect-24:refs");
    bytes32 public constant PHYSICAL_PROFILE =
        keccak256("efs2/index-layout/1:stores:inline-singleton:five-u48:live-bits-in-head");
    bytes32 public constant QUERY_DOMAIN = keccak256("efs2/lens/list-query/1");

    uint8 private constant NONE = type(uint8).max;
    uint8 private constant TARGET_RECORD = 1;
    uint8 private constant TARGET_SUBJECT = 2;
    uint8 private constant SCAN_EXHAUSTED = 1;
    uint8 private constant SCAN_LIMIT = 2;

    address private immutable LEDGER;
    address public immutable VIEWS;
    address public immutable READS;
    bytes32 private immutable LAYOUT;
    bytes32 private immutable F_SCOPE;

    /// The inventory of one `list` call: the observed basis, the query and, per principal, its scope key, entry
    /// count and `lastMutation` stamp from the live `BitmapStore`.
    struct Scan {
        BasisCommit obs;
        bytes32 purpose;
        bytes32 subject;
        uint8 policy;
        bool complete;
        address store;
        ScopeKey[] scopes;
        uint64[] counts;
        uint64[] marks;
    }

    constructor(address ledger_, address views_, address reads_) {
        LEDGER = ledger_;
        VIEWS = views_;
        READS = reads_;
        LAYOUT = ILedgerHot(ledger_).layoutId();
        F_SCOPE = Keys.familyId("scope");
    }

    // =============================================================================================
    // IReader
    // =============================================================================================

    function facetVersion() external pure returns (uint16) {
        return FACET_VERSION;
    }

    function ledger() external view returns (address) {
        return LEDGER;
    }

    /// The layout the bound facets decode (read from the ledger at construction); the facets refuse any other
    /// layout and this reader returns their UNSUPPORTED as data.
    function layoutId() external view returns (bytes32) {
        return LAYOUT;
    }

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

    /// The `queryHash` a `list` cursor is bound to: the ledger, the ordered principals, the scope coordinate
    /// and the fall-through policy (the strict bit is a per-call choice and is not part of the query).
    function queryHash(
        bytes32[] calldata principals,
        bytes32 purpose,
        bytes32 subject,
        uint8 fallThroughPolicy
    ) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                QUERY_DOMAIN,
                LEDGER,
                keccak256(abi.encode(principals)),
                purpose,
                subject,
                fallThroughPolicy & ~STRICT_CONTINUATION
            )
        );
    }

    // =============================================================================================
    // Point reads
    // =============================================================================================

    /// @inheritdoc ILensReader
    /// @dev The flat-ordered law under MASK_BEATS_FALLTHROUGH (the M1 law; this ABI takes no policy). The
    ///      returned `q.status` equals `Selection.status`: PRESENT, MASKED, ABSENT_PROVEN (`selectedIndex` 255),
    ///      UNKNOWN (with the index of the uninterpretable head when one was met), or a refusal (INVALID for no
    ///      principals, LIMIT_EXCEEDED past 64, BASIS_STALE, UNSUPPORTED).
    function resolve(
        bytes32[] calldata principals,
        Coordinate calldata c,
        BasisCommit calldata expected
    ) external view returns (Qualified memory q, Selection memory s) {
        return _resolve(principals, Keys.position(c.purpose, c.subject, c.role), expected);
    }

    /// @inheritdoc ILensReader
    /// @dev `resolve`, then for a PRESENT selection the target record through the Etched header and
    ///      `LedgerReads.record`, verified: the header equals the hot getter's, `firstAdmission` precedes the
    ///      selected bind, and `recordFromHash(typeId, keccak256(body))` is the target. `q.status`: the
    ///      selection's status when it is not PRESENT; INVALID when the target is not a record, or when the
    ///      position's purpose is HEAD and neither body word 0 (`files-root/1` shape) nor word 1 (`files-child/1`
    ///      shape) is the coordinate's subject (the reader-side HEAD rule of design §12.1 without the Type
    ///      check, which needs the Files Type ids and is `FilesPageReader`'s); LIMIT_EXCEEDED with the header and
    ///      no body when the body is longer than `maxBytes` (or than `limits.maxBody`); UNSUPPORTED for a
    ///      carrier body; UNKNOWN (with an empty header and body) on any inconsistent reply; PRESENT with the whole verified body otherwise.
    function resolveRecord(
        bytes32[] calldata principals,
        Coordinate calldata c,
        uint32 maxBytes,
        BasisCommit calldata expected
    )
        external
        view
        returns (Qualified memory q, Selection memory s, RecordHeader memory h, bytes memory body)
    {
        (q, s) = _resolve(principals, Keys.position(c.purpose, c.subject, c.role), expected);
        if (q.status != Status.PRESENT) return (q, s, h, body);
        if (s.targetKind != TARGET_RECORD) {
            q.status = Status.INVALID;
            return (q, s, h, body);
        }
        (q.status, h, body) = _record(s, maxBytes, q.observed);
        if (q.status == Status.UNKNOWN) {
            delete h;
            delete body;
        } else if (
            q.status == Status.PRESENT && c.purpose == Purpose.HEAD && !_fileWord(body, c.subject)
        ) {
            q.status = Status.INVALID;
        }
    }

    /// @inheritdoc ILensReader
    /// @dev Every live candidate in principal order, each confirmed against `ILedgerHot.head`; every
    ///      non-UNSET head is confirmed, since each one decides the status. A reserved state anywhere is
    ///      UNKNOWN with no candidates.
    function resolveNoTiebreak(
        bytes32[] calldata principals,
        Coordinate calldata c,
        BasisCommit calldata expected
    ) external view returns (Qualified memory q, Selection[] memory candidates) {
        bytes32 position = Keys.position(c.purpose, c.subject, c.role);
        Head[] memory all;
        (q, all) = _start(principals, position, expected);
        if (q.status != Status.UNSET) return (q, candidates);
        uint256 n = principals.length;
        candidates = new Selection[](n);
        uint256 live = 0;
        bool removed = false;
        for (uint256 i; i < n; ++i) {
            Head memory h = all[i];
            if (h.state == 0) continue;
            if (h.state > 3 || !_confirm(principals[i], position, h)) {
                q.status = Status.UNKNOWN;
                return (q, new Selection[](0));
            }
            if (h.state == 2) removed = true;
            if (h.state == 1) candidates[live++] = _sel(h, principals[i], i);
        }
        assembly ("memory-safe") {
            mstore(candidates, live)
        }
        q.status = live == 0
            ? (removed ? Status.MASKED : Status.ABSENT_PROVEN)
            : (live == 1 && !removed ? Status.PRESENT : Status.CONFLICT);
    }

    /// @inheritdoc ILensReader
    /// @dev The flat-ordered law over each principal's head as it stood after admission `asOf`: the live head
    ///      when it was last written at or before `asOf`, else `LedgerViews.historyAt` (at most 64 hops); a
    ///      history the facet cannot walk is UNKNOWN and never falls through. BASIS_STALE when `asOf` is past
    ///      the observed admission high water.
    function resolveAt(
        bytes32[] calldata principals,
        Coordinate calldata c,
        uint64 asOf,
        BasisCommit calldata expected
    ) external view returns (Qualified memory q, Selection memory s) {
        bytes32 position = Keys.position(c.purpose, c.subject, c.role);
        Head[] memory all;
        (q, all) = _start(principals, position, expected);
        if (q.status == Status.UNSET && asOf > q.observed.admissionHighWater) {
            q.status = Status.BASIS_STALE;
        }
        if (q.status != Status.UNSET) return (q, _none(q.status));
        s = _firstAt(principals, position, all, asOf, q.observed.admissionHighWater);
        q.status = s.status;
    }

    /// @inheritdoc ILensReader
    /// @dev `resolveAt` per coordinate under one observed basis (one `headsAt` per coordinate). `q.status`:
    ///      PRESENT when every coordinate was served (each selection carries its own status), UNKNOWN when any
    ///      selection is UNKNOWN, or a blanket refusal carried by every selection (INVALID for no coordinates,
    ///      LIMIT_EXCEEDED past 64 coordinates or principals, BASIS_STALE).
    function resolveManyAt(
        bytes32[] calldata principals,
        Coordinate[] calldata coords,
        uint64 asOf,
        BasisCommit calldata expected
    ) external view returns (Qualified memory q, Selection[] memory out) {
        uint256 m = coords.length;
        q = _open(principals.length, expected);
        if (q.status == Status.UNSET) {
            if (m == 0) q.status = Status.INVALID;
            else if (m > MAX_COORDINATES) q.status = Status.LIMIT_EXCEEDED;
            else if (asOf > q.observed.admissionHighWater) q.status = Status.BASIS_STALE;
        }
        out = new Selection[](m);
        Status blanket = q.status;
        if (blanket == Status.UNSET) q.status = Status.PRESENT;
        for (uint256 i; i < m; ++i) {
            if (blanket != Status.UNSET) {
                out[i] = _none(blanket);
                continue;
            }
            Coordinate calldata c = coords[i];
            bytes32 position = Keys.position(c.purpose, c.subject, c.role);
            (Status bad, Head[] memory all) = _heads(principals, position, q.observed);
            out[i] = bad != Status.UNSET
                ? _none(bad)
                : _firstAt(principals, position, all, asOf, q.observed.admissionHighWater);
            if (out[i].status == Status.UNKNOWN) q.status = Status.UNKNOWN;
        }
    }

    // =============================================================================================
    // list(): the budgeted listing of one (purpose, subject) over the principals' scope lists
    // =============================================================================================

    /// @inheritdoc ILensReader
    /// @dev Candidates are the kind-10 scope entries of `scope(principal, purpose, subject)` for each principal
    ///      in order, read from the live generation's `BitmapStore`; an entry of principal k is a row iff the
    ///      policy selects principal k at its position (MASK_BEATS_FALLTHROUGH: the first BOUND or MASKED head
    ///      is k's BOUND head; SILENCE_FALLS_THROUGH: the first BOUND head is k's), so a position appears once,
    ///      under its winner. `budget` (≥ 1, clamped to 256) bounds the entries scanned. The cursor is data bound
    ///      to `queryHash` and to its origin basis: a fresh cursor is all zero; a continuation must carry this
    ///      query's `lensHash`/`queryHash` and a consistent position (else INVALID) and the observed
    ///      `(executionSet, indexGeneration)` (else BASIS_STALE). With `STRICT_CONTINUATION` the origin must be
    ///      the observed admission high water; without it, every principal's scope (consumed, empty and terminal
    ///      ones included, CQ-9) must have `lastMutation ≤ origin`, which REBIND and RESTORE also move; else
    ///      BASIS_STALE. `listingCoverage` is COMPLETE only for an origin-started, exhausted page over scopes the
    ///      index reports COMPLETE from admission 1 through the high water; any other page is PARTIAL; a scope
    ///      whose coverage is UNKNOWN makes the page UNKNOWN with no rows. `inventoryPin` is 0 (the
    ///      current-inventory profile). UNSUPPORTED when the ledger has no index or the live generation's
    ///      profiles are not the ones `supportedProfiles()` lists.
    function list(
        bytes32[] calldata principals,
        bytes32 purpose,
        bytes32 subject,
        Cursor calldata cursor,
        uint32 budget,
        uint8 fallThroughPolicy,
        BasisCommit calldata expected
    ) external view returns (Page memory p) {
        p.q = _open(principals.length, expected);
        p.listingCoverage = Coverage.UNKNOWN;
        if (p.q.status != Status.UNSET) return p;
        Scan memory sc;
        sc.obs = p.q.observed;
        sc.purpose = purpose;
        sc.subject = subject;
        sc.policy = fallThroughPolicy & ~STRICT_CONTINUATION;
        if (
            (sc.policy != MASK_BEATS_FALLTHROUGH && sc.policy != SILENCE_FALLS_THROUGH)
                || budget == 0
        ) {
            p.q.status = Status.INVALID;
            return p;
        }
        p.q.status = _inventory(sc, principals);
        if (p.q.status != Status.UNSET) return p;
        p.q.status = _admit(
            cursor,
            sc,
            principals.length,
            keccak256(abi.encode(principals)),
            queryHash(principals, purpose, subject, fallThroughPolicy),
            fallThroughPolicy & STRICT_CONTINUATION != 0
        );
        if (p.q.status != Status.UNSET) return p;
        p.startsAtOrigin = cursor.basis.executionSet == 0;
        p.next = cursor;
        if (p.startsAtOrigin) {
            p.next.basis = sc.obs;
            p.next.lensHash = keccak256(abi.encode(principals));
            p.next.queryHash = queryHash(principals, purpose, subject, fallThroughPolicy);
        }
        p.observedCurrent = sc.obs.admissionHighWater;
        for (uint256 i; i < principals.length; ++i) {
            p.rawTotal += sc.counts[i];
        }
        p.q.status = _scan(p, sc, principals, budget > MAX_BUDGET ? MAX_BUDGET : budget);
        if (p.q.status != Status.PRESENT) {
            delete p.rows;
            delete p.next;
            return p;
        }
        p.completeFromOrigin = p.startsAtOrigin && p.scanStatus == SCAN_EXHAUSTED && sc.complete;
        p.listingCoverage = p.completeFromOrigin ? Coverage.COMPLETE : Coverage.PARTIAL;
    }

    /// The live index (resolved per call), its profiles, its `BitmapStore`, and per principal the scope head
    /// and the scope family's coverage.
    function _inventory(Scan memory sc, bytes32[] calldata principals)
        private
        view
        returns (Status)
    {
        (bool ok, address index) = _addr(LEDGER, ILedgerHot.index.selector);
        if (!ok) return Status.UNKNOWN;
        if (index == address(0)) return Status.UNSUPPORTED;
        bytes memory r;
        (ok, r) = index.staticcall(abi.encodeCall(IIndexReads.manifest, ()));
        if (!ok || r.length < 640) return Status.UNKNOWN;
        if (bytes32(_w(r, 18)) != PHYSICAL_PROFILE || bytes32(_w(r, 19)) != CALLBACK_PROFILE) {
            return Status.UNSUPPORTED;
        }
        (ok, sc.store) = _addr(index, IIndexReads.bitmapStore.selector);
        if (!ok || sc.store == address(0)) return Status.UNKNOWN;
        uint256 n = principals.length;
        sc.scopes = new ScopeKey[](n);
        sc.counts = new uint64[](n);
        sc.marks = new uint64[](n);
        sc.complete = true;
        uint64 high = sc.obs.admissionHighWater;
        for (uint256 i; i < n; ++i) {
            ScopeKey scope = ScopeKey.wrap(Keys.scope(principals[i], sc.purpose, sc.subject));
            sc.scopes[i] = scope;
            (ok, r) = _static(sc.store, abi.encodeCall(IBitmapStore.scopeHead, (scope)), 6);
            if (!ok) return Status.UNKNOWN;
            (uint64 count, uint64 live, uint64 mark) =
                (uint64(_w(r, 0)), uint64(_w(r, 1)), uint64(_w(r, 2)));
            bytes memory again =
                abi.encode(count, live, mark, uint48(_w(r, 3)), uint16(_w(r, 4)), uint64(_w(r, 5)));
            if (keccak256(again) != keccak256(r) || live > count || mark > high) {
                return Status.UNKNOWN;
            }
            sc.counts[i] = count;
            sc.marks[i] = mark;
            (ok, r) = _static(
                index, abi.encodeCall(IIndexReads.coverage, (FamilyId.wrap(F_SCOPE), scope)), 4
            );
            uint256 cov = ok ? _w(r, 0) : 0;
            if (cov != uint256(Coverage.PARTIAL) && cov != uint256(Coverage.COMPLETE)) {
                return Status.UNKNOWN;
            }
            if (cov != uint256(Coverage.COMPLETE) || _w(r, 1) != 1 || _w(r, 2) != high) {
                sc.complete = false;
            }
        }
        return Status.UNSET;
    }

    /// The cursor law (design §11, §5.13); UNSET admits the cursor.
    function _admit(
        Cursor calldata c,
        Scan memory sc,
        uint256 n,
        bytes32 lensHash,
        bytes32 qh,
        bool strict
    ) private pure returns (Status) {
        if (c.basis.executionSet == 0) {
            Cursor memory zero;
            return
                keccak256(abi.encode(c)) == keccak256(abi.encode(zero))
                    ? Status.UNSET
                    : Status.INVALID;
        }
        if (c.lensHash != lensHash || c.queryHash != qh) return Status.INVALID;
        if (
            c.basis.executionSet != sc.obs.executionSet
                || c.basis.indexGeneration != sc.obs.indexGeneration
        ) return Status.BASIS_STALE;
        uint64 origin = c.basis.admissionHighWater;
        if (origin > sc.obs.admissionHighWater) return Status.BASIS_STALE;
        if (strict) {
            if (origin != sc.obs.admissionHighWater) return Status.BASIS_STALE;
        } else {
            for (uint256 i; i < n; ++i) {
                if (sc.marks[i] > origin) return Status.BASIS_STALE;
            }
        }
        uint256 k = c.lensIndex;
        if (k > n) return Status.INVALID;
        bool placed = k < n
            ? ScopeKey.unwrap(c.scope) == ScopeKey.unwrap(sc.scopes[k])
                && c.rawIndex <= sc.counts[k]
            : ScopeKey.unwrap(c.scope) == 0 && c.rawIndex == 0;
        return placed ? Status.UNSET : Status.INVALID;
    }

    /// Scans from the cursor position; fills `p.rows`, `p.scanned`, `p.selectedSoFar`, `p.scanStatus` and the
    /// position fields of `p.next`. Returns PRESENT, or the status that refuses the page.
    function _scan(Page memory p, Scan memory sc, bytes32[] calldata principals, uint256 cap)
        private
        view
        returns (Status st)
    {
        uint256 n = principals.length;
        uint256 k = p.next.lensIndex;
        uint64 j = p.next.rawIndex;
        Entry[] memory rows = new Entry[](cap);
        uint256 filled = 0;
        while (k < n && p.scanned < cap) {
            uint64 count = sc.counts[k];
            if (j >= count) {
                ++k;
                j = 0;
                continue;
            }
            uint64 take = count - j;
            if (take > cap - p.scanned) take = uint64(cap - p.scanned);
            (bool ok, bytes memory r) = sc.store
                .staticcall(
                    abi.encodeCall(IBitmapStore.scopeSlice, (sc.scopes[k], j, uint16(take)))
                );
            if (!ok || r.length != 64 + 32 * uint256(take) || _w(r, 0) != 32 || _w(r, 1) != take) {
                return Status.UNKNOWN;
            }
            uint256 prev = 0;
            for (uint256 t; t < take; ++t) {
                uint256 ordinal = _w(r, 2 + t);
                if (ordinal <= prev || ordinal >> 64 != 0) return Status.UNKNOWN;
                prev = ordinal;
                Entry memory e;
                bool taken;
                (st, taken, e) = _entry(sc, principals, k, uint64(ordinal));
                if (st != Status.UNSET) return st;
                if (taken) rows[filled++] = e;
            }
            j += take;
            p.scanned += take;
        }
        while (k < n && j >= sc.counts[k]) {
            ++k;
            j = 0;
        }
        assembly ("memory-safe") {
            mstore(rows, filled)
        }
        p.rows = rows;
        p.selectedSoFar = p.next.selectedSoFar + uint64(filled);
        p.next.selectedSoFar = p.selectedSoFar;
        p.next.lensIndex = uint64(k);
        p.next.rawIndex = j;
        p.next.scope = k < n ? sc.scopes[k] : ScopeKey.wrap(0);
        p.scanStatus = k == n ? SCAN_EXHAUSTED : SCAN_LIMIT;
        return Status.PRESENT;
    }

    /// One scope entry of principal `k`: its position (`LedgerReads.bindingPosition`), the heads there, and
    /// whether the policy selects principal k. The entry must be k's binding at that position (the head's
    /// `bindingOrdinal` is the entry), so a wrong position cannot silently drop or invent a row.
    function _entry(Scan memory sc, bytes32[] calldata principals, uint256 k, uint64 ordinal)
        private
        view
        returns (Status, bool, Entry memory e)
    {
        (bool ok, bytes memory r) =
            _static(READS, abi.encodeCall(ILedgerReads.bindingPosition, (LEDGER, ordinal)), 2);
        if (!ok || _w(r, 0) != uint256(Status.PRESENT) || _w(r, 1) == 0) {
            return (Status.UNKNOWN, false, e);
        }
        e.position = bytes32(_w(r, 1));
        (Status bad, Head[] memory all) = _heads(principals, e.position, sc.obs);
        if (bad != Status.UNSET) return (bad, false, e);
        Head memory hk = all[k];
        if (hk.bindingOrdinal != ordinal || hk.state == 0) return (Status.UNKNOWN, false, e);
        uint256 n = principals.length;
        uint256 winner = n;
        for (uint256 i; i < n; ++i) {
            uint8 state = all[i].state;
            if (state > 3) return (Status.UNKNOWN, false, e);
            if (state == 1 || (state == 2 && sc.policy == MASK_BEATS_FALLTHROUGH)) {
                winner = i;
                break;
            }
        }
        if (winner != k || hk.state != 1) return (Status.UNSET, false, e);
        if (!_confirm(principals[k], e.position, hk)) return (Status.UNKNOWN, false, e);
        (ok, r) = _static(READS, abi.encodeCall(ILedgerReads.positionCell, (LEDGER, e.position)), 4);
        if (
            !ok || _w(r, 0) != uint256(Status.PRESENT) || bytes32(_w(r, 1)) != sc.purpose
                || bytes32(_w(r, 2)) != sc.subject
        ) return (Status.UNKNOWN, false, e);
        e.role = bytes32(_w(r, 3));
        e.selection = _sel(hk, principals[k], k);
        return (Status.UNSET, true, e);
    }

    // =============================================================================================
    // Resolution core
    // =============================================================================================

    function _resolve(
        bytes32[] calldata principals,
        bytes32 position,
        BasisCommit calldata expected
    ) private view returns (Qualified memory q, Selection memory s) {
        Head[] memory all;
        (q, all) = _start(principals, position, expected);
        if (q.status != Status.UNSET) return (q, _none(q.status));
        s = _first(principals, position, all);
        q.status = s.status;
    }

    /// The basis, the request bounds, `expected`, then one `headsAt`. UNSET in `q.status` means proceed.
    function _start(bytes32[] calldata principals, bytes32 position, BasisCommit calldata expected)
        private
        view
        returns (Qualified memory q, Head[] memory all)
    {
        q = _open(principals.length, expected);
        if (q.status == Status.UNSET) (q.status, all) = _heads(principals, position, q.observed);
    }

    /// Observes the basis through `LedgerReads.basis` and checks the request bounds and `expected`.
    function _open(uint256 n, BasisCommit calldata expected)
        private
        view
        returns (Qualified memory q)
    {
        (bool ok, bytes memory r) = _static(READS, abi.encodeCall(ILedgerReads.basis, (LEDGER)), 6);
        if (ok) (ok, q.observed) = _basisAt(r, 0);
        BasisCommit memory b = q.observed;
        if (!ok || b.executionSet == 0 || b.revision == 0) {
            q.status = Status.UNKNOWN;
        } else if (n == 0) {
            q.status = Status.INVALID;
        } else if (n > MAX_PRINCIPALS) {
            q.status = Status.LIMIT_EXCEEDED;
        } else if (
            expected.executionSet != 0
                && (expected.executionSet != b.executionSet
                    || expected.indexGeneration != b.indexGeneration
                    || expected.admissionHighWater > b.admissionHighWater)
        ) {
            q.status = Status.BASIS_STALE;
        }
    }

    /// One `LedgerViews.headsAt`, shape-checked, every head decoded at its declared widths and checked for the
    /// head-row invariants, the echoed basis equal to `obs`, and the facet's own selection equal to the
    /// recomputed first touch. Returns UNSET and the heads, or the refusal (the facet's blanket UNSUPPORTED /
    /// LIMIT_EXCEEDED, else UNKNOWN).
    function _heads(bytes32[] calldata principals, bytes32 position, BasisCommit memory obs)
        private
        view
        returns (Status, Head[] memory all)
    {
        (bool ok, bytes memory r) = VIEWS.staticcall(
            abi.encodeCall(ILedgerViews.headsAt, (LEDGER, principals, position))
        );
        if (!ok || r.length < 576 || _w(r, 10) != 544) return (Status.UNKNOWN, all);
        uint256 len = _w(r, 17);
        if (len > NONE || r.length != 576 + (len << 8)) return (Status.UNKNOWN, all);
        BasisCommit memory echo;
        (ok, echo) = _basisAt(r, 11);
        if (!ok || keccak256(abi.encode(echo)) != keccak256(abi.encode(obs))) {
            return (Status.UNKNOWN, all);
        }
        uint256 st = _w(r, 0);
        uint256 idx = _w(r, 9);
        if (len == 0) {
            bool blanket = st == uint256(Status.UNSUPPORTED) || st == uint256(Status.LIMIT_EXCEEDED);
            return (blanket && idx == NONE ? Status(st) : Status.UNKNOWN, all);
        }
        uint256 n = principals.length;
        if (len != n) return (Status.UNKNOWN, all);
        all = new Head[](n);
        uint256 first = NONE;
        uint256 firstStatus = uint256(Status.ABSENT_PROVEN);
        for (uint256 i; i < n; ++i) {
            Head memory h;
            (ok, h) = _headAt(r, 18 + (i << 3));
            if (!ok || !_sane(h, obs.admissionHighWater)) return (Status.UNKNOWN, all);
            all[i] = h;
            if (first == NONE && h.state != 0 && h.state != 3) {
                first = i;
                firstStatus = uint256(
                    h.state == 1
                        ? Status.PRESENT
                        : h.state == 2 ? Status.MASKED : Status.UNSUPPORTED
                );
            }
        }
        bytes32 selected = _hash(r, 1, 8);
        bool same = first == NONE
            ? selected == keccak256(new bytes(256))
            : selected == _hash(r, 18 + (first << 3), 8);
        if (st != firstStatus || idx != first || !same) return (Status.UNKNOWN, all);
        return (Status.UNSET, all);
    }

    /// The flat-ordered first touch over current heads; the winner is confirmed against `ILedgerHot.head`.
    function _first(bytes32[] calldata principals, bytes32 position, Head[] memory all)
        private
        view
        returns (Selection memory s)
    {
        for (uint256 i; i < all.length; ++i) {
            Head memory h = all[i];
            if (h.state == 0 || h.state == 3) continue;
            if (h.state > 3 || !_confirm(principals[i], position, h)) return _unknownAt(i);
            return _sel(h, principals[i], i);
        }
        return _none(Status.ABSENT_PROVEN);
    }

    /// The flat-ordered first touch over the heads as they stood after admission `asOf`.
    function _firstAt(
        bytes32[] calldata principals,
        bytes32 position,
        Head[] memory all,
        uint64 asOf,
        uint64 high
    ) private view returns (Selection memory) {
        for (uint256 i; i < all.length; ++i) {
            Head memory h = all[i];
            if (h.state > 3) return _unknownAt(i);
            bool current = h.admission <= asOf;
            if (!current) {
                bool ok;
                (ok, h) = _history(Keys.binding(principals[i], position), asOf, all[i], high);
                if (!ok) return _unknownAt(i);
            }
            if (h.state == 0 || h.state == 3) continue;
            if (current && !_confirm(principals[i], position, h)) return _unknownAt(i);
            return _sel(h, principals[i], i);
        }
        return _none(Status.ABSENT_PROVEN);
    }

    /// `LedgerViews.historyAt`, checked against the live head: FOUND must be an earlier transition of the
    /// same binding at or before `asOf`; NONE must carry an all-zero head; anything else is not interpretable.
    function _history(bytes32 key, uint64 asOf, Head memory live, uint64 high)
        private
        view
        returns (bool ok, Head memory h)
    {
        bytes memory r;
        (ok, r) = _static(
            VIEWS, abi.encodeCall(ILedgerViews.historyAt, (LEDGER, key, asOf, MAX_HOPS)), 9
        );
        if (!ok) return (false, h);
        uint256 found = _w(r, 0);
        (ok, h) = _headAt(r, 1);
        if (!ok) return (false, h);
        if (found == uint256(History.NONE)) return (h.state == 0 && _sane(h, high), h);
        ok = found == uint256(History.FOUND) && h.state != 0 && h.state <= 3 && h.admission <= asOf
            && h.admission < live.admission && h.revision < live.revision
            && h.bindingOrdinal == live.bindingOrdinal && _sane(h, high);
    }

    /// Whether `h` equals the Etched `ILedgerHot.head` row of `binding(principal, position)` (every field but
    /// `notAfter`, which the hot getter does not serve).
    function _confirm(bytes32 principal, bytes32 position, Head memory h)
        private
        view
        returns (bool)
    {
        (bool ok, bytes memory r) = _static(
            LEDGER, abi.encodeCall(ILedgerHot.head, (Keys.binding(principal, position))), 7
        );
        return ok
            && keccak256(r)
                == keccak256(
                abi.encode(
                h.state,
                h.revision,
                h.admission,
                h.targetKind,
                h.prevAdmission,
                h.bindingOrdinal,
                h.target
            )
            );
    }

    // =============================================================================================
    // Records
    // =============================================================================================

    /// The verified record of a PRESENT record selection: the Etched header first (cheap, and the second source
    /// for the facet's header), then the whole body through `LedgerReads.record` when it fits `maxBytes`.
    function _record(Selection memory s, uint32 maxBytes, BasisCommit memory obs)
        private
        view
        returns (Status, RecordHeader memory h, bytes memory body)
    {
        bytes32 id = s.target;
        (bool ok, bytes memory r) =
            _static(LEDGER, abi.encodeCall(ILedgerHot.recordHeader, (id)), 5);
        if (!ok) return (Status.UNKNOWN, h, body);
        h.typeId = bytes32(_w(r, 0));
        h.firstAdmission = uint64(_w(r, 1));
        h.length = uint32(_w(r, 2));
        h.occurrences = uint64(_w(r, 3));
        h.carrierKind = uint8(_w(r, 4));
        bytes32 hot = _hot(h);
        if (
            hot != keccak256(r) || h.typeId == 0 || h.firstAdmission == 0
                || h.firstAdmission >= s.admission
        ) return (Status.UNKNOWN, h, body);
        if (h.carrierKind != 0) return (Status.UNSUPPORTED, h, body);
        if (h.length > maxBytes) {
            (ok, r) = _static(READS, abi.encodeCall(ILedgerReads.recordHeader, (LEDGER, id)), 7);
            if (!ok || _w(r, 0) != uint256(Status.PRESENT) || _hash(r, 1, 5) != hot) {
                return (Status.UNKNOWN, h, body);
            }
            h.word0 = bytes32(_w(r, 6));
            return (Status.LIMIT_EXCEEDED, h, body);
        }
        (ok, r) = READS.staticcall(abi.encodeCall(ILedgerReads.record, (LEDGER, id)));
        if (!ok || r.length < 480 || _w(r, 7) != 448) return (Status.UNKNOWN, h, body);
        uint256 len = _w(r, 14);
        if (len >> 32 != 0 || r.length != 480 + ((len + 31) & ~uint256(31))) {
            return (Status.UNKNOWN, h, body);
        }
        BasisCommit memory echo;
        (ok, echo) = _basisAt(r, 8);
        if (!ok || keccak256(abi.encode(echo)) != keccak256(abi.encode(obs))) {
            return (Status.UNKNOWN, h, body);
        }
        uint256 st = _w(r, 0);
        bool limited = st == uint256(Status.LIMIT_EXCEEDED) && len == 0;
        if (
            (st != uint256(Status.PRESENT) && !limited) || _hash(r, 1, 5) != hot
                || (!limited && len != h.length)
        ) return (Status.UNKNOWN, h, body);
        h.word0 = bytes32(_w(r, 6));
        if (limited) return (Status.LIMIT_EXCEEDED, h, body);
        body = new bytes(len);
        bytes32 first;
        assembly ("memory-safe") {
            mcopy(add(body, 0x20), add(r, 512), len)
            first := mload(add(r, 512))
        }
        if (len < 32) first &= bytes32(~(type(uint256).max >> (len << 3)));
        if (Keys.recordFromHash(h.typeId, keccak256(body)) != id || first != h.word0) {
            return (Status.UNKNOWN, h, new bytes(0));
        }
        return (Status.PRESENT, h, body);
    }

    /// The HEAD rule's subject check (design §12.1): body word 0 (`files-root/1`) or word 1 (`files-child/1`).
    function _fileWord(bytes memory body, bytes32 subject) private pure returns (bool) {
        bytes32 w0;
        bytes32 w1;
        uint256 len = body.length;
        assembly ("memory-safe") {
            w0 := mload(add(body, 0x20))
            w1 := mload(add(body, 0x40))
        }
        return (len >= 32 && w0 == subject) || (len >= 64 && w1 == subject);
    }

    function _hot(RecordHeader memory h) private pure returns (bytes32) {
        return
            keccak256(
                abi.encode(h.typeId, h.firstAdmission, h.length, h.occurrences, h.carrierKind)
            );
    }

    // =============================================================================================
    // Reply decoding
    // =============================================================================================

    /// The head-row invariants of design §4.3 under admission high water `high`: an UNSET head is all zero; a
    /// written head names an admission in `[1, high]` after its `prevAdmission`, a binding ordinal and a
    /// RECORD/SUBJECT target kind; a BOUND head has a target and a revision, a MASKED/RELEASED head the canonical
    /// zero target, a revision ≥ 2 and a previous admission. Reserved states pass (callers make them UNKNOWN).
    function _sane(Head memory h, uint64 high) private pure returns (bool) {
        uint8 s = h.state;
        if (s > 3) return true;
        if (s == 0) {
            return h.revision == 0 && h.admission == 0 && h.targetKind == 0 && h.prevAdmission == 0
                && h.bindingOrdinal == 0 && h.notAfter == 0 && h.target == 0;
        }
        if (
            h.admission == 0 || h.admission > high || h.prevAdmission >= h.admission
                || h.bindingOrdinal == 0
                || (h.targetKind != TARGET_RECORD && h.targetKind != TARGET_SUBJECT)
        ) return false;
        return s == 1
            ? h.target != 0 && h.revision != 0
            : h.target == 0 && h.revision > 1 && h.prevAdmission != 0;
    }

    function _headAt(bytes memory r, uint256 o) private pure returns (bool, Head memory h) {
        h.state = uint8(_w(r, o));
        h.revision = uint64(_w(r, o + 1));
        h.admission = uint64(_w(r, o + 2));
        h.targetKind = uint8(_w(r, o + 3));
        h.prevAdmission = uint64(_w(r, o + 4));
        h.bindingOrdinal = uint64(_w(r, o + 5));
        h.notAfter = uint40(_w(r, o + 6));
        h.target = bytes32(_w(r, o + 7));
        return (keccak256(abi.encode(h)) == _hash(r, o, 8), h);
    }

    function _basisAt(bytes memory r, uint256 o) private pure returns (bool, BasisCommit memory b) {
        b.executionSet = bytes32(_w(r, o));
        b.revision = uint32(_w(r, o + 1));
        b.indexGeneration = uint32(_w(r, o + 2));
        b.registryMutations = uint64(_w(r, o + 3));
        b.admissionHighWater = uint64(_w(r, o + 4));
        b.phase = uint8(_w(r, o + 5));
        return (keccak256(abi.encode(b)) == _hash(r, o, 6), b);
    }

    function _sel(Head memory h, bytes32 principal, uint256 i)
        private
        pure
        returns (Selection memory s)
    {
        s.status = h.state == 1 ? Status.PRESENT : Status.MASKED;
        s.target = h.target;
        s.targetKind = h.targetKind;
        s.revision = h.revision;
        s.principalId = principal;
        s.admission = h.admission;
        s.selectedIndex = uint8(i);
    }

    function _none(Status st) private pure returns (Selection memory s) {
        s.status = st;
        s.selectedIndex = NONE;
    }

    function _unknownAt(uint256 i) private pure returns (Selection memory s) {
        s.status = Status.UNKNOWN;
        s.selectedIndex = uint8(i);
    }

    /// A static reply of exactly `words` words.
    function _static(address to, bytes memory data, uint256 words)
        private
        view
        returns (bool ok, bytes memory r)
    {
        (ok, r) = to.staticcall(data);
        ok = ok && r.length == words << 5;
    }

    /// A zero-argument getter replying one address word.
    function _addr(address to, bytes4 selector) private view returns (bool ok, address a) {
        bytes memory r;
        (ok, r) = _static(to, abi.encodePacked(selector), 1);
        ok = ok && _w(r, 0) >> 160 == 0;
        if (ok) a = address(uint160(_w(r, 0)));
    }

    /// Word `i` of a reply (the caller has checked the length).
    function _w(bytes memory r, uint256 i) private pure returns (uint256 x) {
        assembly ("memory-safe") {
            x := mload(add(add(r, 0x20), shl(5, i)))
        }
    }

    function _hash(bytes memory r, uint256 i, uint256 n) private pure returns (bytes32 h) {
        assembly ("memory-safe") {
            h := keccak256(add(add(r, 0x20), shl(5, i)), shl(5, n))
        }
    }
}
// forge-lint: disable-end(missing-zero-check)
// forge-lint: disable-end(boolean-cst)
// forge-lint: disable-end(calls-loop)
// forge-lint: disable-end(unsafe-typecast)
