// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {GenerationStorage} from "./storage/GenerationStorage.sol";
import {IndexProfiles} from "./IndexProfiles.sol";
import {IndexReads} from "./IndexReads.sol";
import {Layout} from "../core/layout/Layout.sol";
import {Keys} from "../lib/Keys.sol";
import {ActionKind, FamilyId, PostingKey, Purpose, ScopeKey} from "../interfaces/Actions.sol";
import {Phase} from "../interfaces/Results.sol";
import {ILedgerHot} from "../interfaces/ILedgerHot.sol";
import {IRealmIndex} from "../interfaces/IRealmIndex.sol";
import {IIndexReads} from "../interfaces/IIndexReads.sol";
import {IIndexHook} from "../interfaces/IIndexHook.sol";
import {IPostingStore} from "../interfaces/IPostingStore.sol";
import {IBitmapStore} from "../interfaces/IBitmapStore.sol";
import {IIndexReplayDecoder} from "../interfaces/internal/IIndexReplayDecoder.sol";
import {DigestSpec, Effect, FamilyEntry, Readiness, Unit, WorkModel} from "../interfaces/Index.sol";
import {
    E_BACKFILL,
    E_BUILD,
    E_INDEX_FINAL,
    E_LEDGER,
    E_ORDER,
    E_PIN,
    E_REPLAY,
    E_STAGED,
    E_WRITER
} from "../interfaces/Errors.sol";

/// @title RealmIndex — generation 1: an immutable dispatcher over the per-Realm family stores (design §10)
/// @notice Holds no posting storage: it folds every Effect/3 into `PostingStore`/`BitmapStore` under the
///         stores' writer rule and keeps only its progress word. Its manifest (families, units, digest specs, work
///         model, profiles) is held by its `IndexReads` contract, deployed first: the constructor copies the
///         units, digest specs and work model the fold needs from there, and folds the manifest with the reads
///         contract's address and codehash into `MANIFEST_HASH`. Every read this contract does not answer itself
///         is forwarded to that contract by `STATICCALL` from the fallback (design §10.1), so the manifest,
///         readiness and coverage reads keep their selectors at this address and no forwarded call can change
///         state. Of the entry points of §10.6, replay into fresh stores and `build` run in this contract's own
///         code: `build` moves the frontier of a generation that carries both stores (docs INDEX-BUILD §3.5) and
///         walks history into the fresh stores of one that does not, folding only the families those stores hold
///         (§3.2–3.4, §4.3); `backfill` reverts, because generation 1 has no later family to build (the `IndexBuild`
///         delegate is withdrawn: an index may not DELEGATECALL; design §10.6).
contract RealmIndex is IRealmIndex, GenerationStorage {
    address public immutable LEDGER;
    address public immutable DECODER;
    address public immutable POSTING;
    address public immutable BITMAP;
    /// The reads contract and its codehash at construction (design §10.1); both are folded into `MANIFEST_HASH`.
    address public immutable READS;
    bytes32 public immutable READS_CODEHASH;
    bytes32 public immutable MANIFEST_HASH;
    bytes32 public constant PHYSICAL_PROFILE = IndexProfiles.PHYSICAL;
    bytes32 public constant CALLBACK_PROFILE = IndexProfiles.CALLBACK;
    bytes32 public constant MANIFEST_HEADER = IndexProfiles.MANIFEST_HEADER;
    uint8 private constant T_FIRST_BIND = 1;
    uint8 private constant T_REBIND = 2;
    uint8 private constant T_MASK = 3;
    uint8 private constant T_RELEASE = 4;
    uint8 private constant T_RESTORE = 5;
    uint8 private constant T_FIRST_MASK = 6;
    /// The store's UNCOUNTED tag (`IPostingStore.append`): an entry appended without raising `live`.
    uint64 private constant UNCOUNTED = uint64(1) << 63;
    /// The carried-store mask a fold runs under (docs INDEX-BUILD §4.3): a set bit names a store the fold must not
    /// write, because this generation carries it (the live index folds it). 0 on the live path, in a replay and in
    /// a build into two fresh stores; one bit in a build that heals one store; both bits when nothing is fresh.
    uint256 internal constant CARRIED_POSTING = 1;
    uint256 internal constant CARRIED_BITMAP = 2;

    bytes32 private immutable F_BY_TYPE;
    bytes32 private immutable F_BY_AUTHOR;
    bytes32 private immutable F_BACKLINK;
    bytes32 private immutable F_HISTORY;
    bytes32 private immutable F_SCOPE;
    bytes32 private immutable F_REFERENCE_POSITION;
    bytes32 private immutable F_BY_RECORD;
    bytes32 private immutable F_UNIQUE_BY_TYPE;
    bytes32 private immutable F_DIGEST;
    bytes32 private immutable F_ROLE_SCOPE;
    bytes32 private immutable F_LIVE_SCOPE;
    bytes32 private immutable F_PLACE;
    bytes32 private immutable F_PLACE_BELOW;
    bytes32 private immutable F_SCOPE_BELOW;
    bytes32 private immutable F_POSITION_AUTHORS;
    bytes32 private immutable F_ROLE_PLACES;
    /// The Topics Type ids the ancestor walk follows (`topic/1`: parent = body word 0; `topic-word/1`: a root),
    /// copied from READS; both zero when the generation keeps no topic lists (no walk happens).
    bytes32 private immutable TOPIC_T;
    bytes32 private immutable WORD_T;

    Unit[] private _units;
    DigestSpec[] private _specs;
    WorkModel private _work;

    /// @param reads the generation's `IndexReads`, built for `ledger_` over the manifest of this generation; its
    ///        units, digest specs and work model are copied here, and its manifest must name this build's header
    ///        and profiles (`E_PIN(reads, 10)` otherwise).
    constructor(address ledger_, address decoder, address reads) {
        LEDGER = ledger_;
        DECODER = decoder;
        READS = reads;
        READS_CODEHASH = reads.codehash;
        IIndexReads r = IIndexReads(reads);
        (
            bytes32 header,
            FamilyEntry[] memory families,
            Unit[] memory units,
            DigestSpec[] memory specs,
            WorkModel memory work,
            bytes32 physical,
            bytes32 callback
        ) = r.manifest();
        if (
            header != IndexProfiles.MANIFEST_HEADER || physical != IndexProfiles.PHYSICAL
                || callback != IndexProfiles.CALLBACK || r.ledger() != ledger_
        ) revert E_PIN(reads, 10);
        POSTING = r.postingStore();
        BITMAP = r.bitmapStore();
        F_BY_TYPE = Keys.familyId("by-type");
        F_BY_AUTHOR = Keys.familyId("by-author");
        F_BACKLINK = Keys.familyId("backlink");
        F_HISTORY = Keys.familyId("history");
        F_SCOPE = Keys.familyId("scope");
        F_REFERENCE_POSITION = Keys.familyId("reference-position");
        F_BY_RECORD = Keys.familyId("by-record");
        F_UNIQUE_BY_TYPE = Keys.familyId("unique-by-type");
        F_DIGEST = Keys.familyId("digest");
        F_ROLE_SCOPE = Keys.familyId("role-scope");
        F_LIVE_SCOPE = Keys.familyId("live-scope");
        F_PLACE = Keys.familyId("place");
        F_PLACE_BELOW = Keys.familyId("place-below");
        F_SCOPE_BELOW = Keys.familyId("scope-below");
        F_POSITION_AUTHORS = Keys.familyId("position-authors");
        F_ROLE_PLACES = Keys.familyId("role-places");
        // the topic lists only beside the final hook that guarantees a tagged topic was registered strictly before
        // the tag; re-checked here over the units this generation copies, so no reads contract can switch it on
        (bytes32 topic, bytes32 word) = r.topicTypes();
        IndexProfiles.requireTopicUnit(units, topic, word);
        TOPIC_T = topic;
        WORD_T = word;
        for (uint256 i; i < units.length; ++i) {
            _units.push(units[i]);
        }
        for (uint256 i; i < specs.length; ++i) {
            _specs.push(specs[i]);
        }
        _work = work;
        MANIFEST_HASH = keccak256(
            abi.encode(
                header, families, units, specs, work, physical, callback, reads, reads.codehash
            )
        );
        _gen().progress.replayStage = 1; // FRESH
    }

    // =============================================================================================
    // Callbacks (design §10.3)
    // =============================================================================================

    function _requireLedger() private view {
        if (msg.sender != LEDGER) revert E_LEDGER();
    }

    /// @inheritdoc IRealmIndex
    function onAdmission(uint64 publication, Effect[] calldata effects, bytes32[] calldata refs)
        external
        returns (bytes4)
    {
        _requireLedger();
        (uint8 phase, uint64 staged,,) = ILedgerHot(LEDGER).phase();
        if (phase != Phase.APPLYING || publication != staged) revert E_STAGED(staged, publication);
        _gen().progress.liveStarted = 1; // read by nothing the fold or its hooks reach before the hooks run
        _foldPublication(publication, effects, refs, 0);
        return IRealmIndex.onAdmission.selector;
    }

    /// One publication's effects folded in order, live (from `onAdmission`) or from history (from `replayFold`):
    /// the effects must continue the progress word exactly, and the word moves to the publication's last admission.
    /// `carried` names the stores this fold must not write (`CARRIED_POSTING`, `CARRIED_BITMAP`); the fold hooks run
    /// only when it is 0 (docs INDEX-BUILD §3.6: a unit folded live and its companion store is not rebuilt in a build
    /// that heals one store; this generation cannot tell a carried unit from a new one, so it calls none there).
    function _foldPublication(
        uint64 publication,
        Effect[] calldata effects,
        bytes32[] calldata refs,
        uint256 carried
    ) private {
        Progress storage p = _gen().progress;
        uint64 expected = p.lastProcessed + 1;
        uint256 refIndex;
        for (uint256 i; i < effects.length; ++i) {
            Effect calldata e = effects[i];
            if (e.admission != expected) revert E_ORDER(expected, e.admission);
            if (e.publication != publication) revert E_STAGED(publication, e.publication);
            _fold(e, refs[refIndex:refIndex + e.refCount], carried);
            refIndex += e.refCount;
            ++expected;
        }
        p.lastProcessed = uint48(expected - 1);
        p.lastPublication = uint48(publication);
        if (carried == 0) _foldHooks(effects, refs, publication);
    }

    /// @inheritdoc IRealmIndex
    function afterPublication(
        uint64 publication,
        Effect[] calldata effects,
        bytes32[] calldata refs
    ) external view returns (bytes4) {
        _requireLedger();
        (uint8 phase, uint64 staged,,) = ILedgerHot(LEDGER).phase();
        if (phase != Phase.FINAL || publication != staged) revert E_STAGED(staged, publication);
        if (
            effects.length != 0
                && effects[effects.length - 1].admission != _gen().progress.lastProcessed
        ) {
            revert E_ORDER(_gen().progress.lastProcessed, effects[effects.length - 1].admission);
        }
        for (uint256 i; i < _units.length; ++i) {
            Unit storage u = _units[i];
            if (u.finalHook == address(0)) continue;
            bytes4 ack = IIndexHook(u.finalHook).validate(publication, effects, refs);
            if (ack != IIndexHook.validate.selector) revert E_INDEX_FINAL();
        }
        return IRealmIndex.afterPublication.selector;
    }

    function _foldHooks(Effect[] calldata effects, bytes32[] calldata refs, uint64 publication)
        private
    {
        for (uint256 i; i < _units.length; ++i) {
            Unit storage u = _units[i];
            if (u.foldHook == address(0)) continue;
            uint256 refIndex;
            for (uint256 j; j < effects.length; ++j) {
                Effect calldata e = effects[j];
                if (u.purposeFilter == 0 || u.purposeFilter == e.purpose) {
                    bytes4 ack = IIndexHook(u.foldHook)
                        .fold(e, refs[refIndex:refIndex + e.refCount], publication);
                    if (ack != IIndexHook.fold.selector) revert E_INDEX_FINAL();
                }
                refIndex += e.refCount;
            }
        }
    }

    // ---- the generic fold (design §10.2) -------------------------------------------------------------

    /// The fold of one effect. A record or a withdrawal writes only the posting store; a bind writes both stores, each
    /// part only from the effect, write-once ledger facts and the state of its own store (docs INDEX-BUILD §4.3), so
    /// skipping a carried store's part changes nothing the other part writes.
    function _fold(Effect calldata e, bytes32[] calldata refs, uint256 carried) private {
        uint8 kind = e.kind;
        bool posting = carried & CARRIED_POSTING == 0;
        if (kind == ActionKind.PUBLISH || kind == ActionKind.REUSE) {
            if (posting) _foldRecord(e, refs);
        } else if (
            kind == ActionKind.BIND || kind == ActionKind.UNBIND || kind == ActionKind.RELEASE
        ) {
            _foldBind(e, posting, carried & CARRIED_BITMAP == 0);
        } else if (kind == ActionKind.WITHDRAW) {
            if (posting) _foldWithdraw(e);
        }
        // CREATE touches no family
        _foldMore(e, refs, carried);
    }

    /// Extension point for a later generation's families in further stores (docs INDEX-BUILD step 3): called after
    /// every effect's fold, live and from history, with the same carried mask. Empty here, so it costs no code.
    function _foldMore(Effect calldata, bytes32[] calldata, uint256) internal virtual {}

    // ---- the posting appends of one effect, written by one appendBatch (design §4.6) --------------------------

    /// The posting appends of one effect, in fold order, written by one `appendBatch` CALL at the end of the
    /// effect instead of one `append` CALL each. The store checks every entry's family and order law exactly as
    /// `append` does and asks the writer rule once (its inputs cannot change within the call), so the stored
    /// result is the per-append result. Reordering against the effect's other store calls is safe because none
    /// of them touches a buffered key before the flush: the bitmap calls are another store; the by-record read
    /// precedes every append of its key; the digest de-duplication reads the buffer itself (a key appended
    /// earlier in this effect is exactly a key whose last entry is this admission); a bind's `release` of the
    /// old target precedes the new target's append in both orders. A WITHDRAW, which releases a key it may
    /// first append, does not buffer.
    struct Appends {
        FamilyId[] families;
        PostingKey[] keys;
        uint64[] ordinals;
        uint256 n;
    }

    function _appends(uint256 capacity) private pure returns (Appends memory b) {
        b.families = new FamilyId[](capacity);
        b.keys = new PostingKey[](capacity);
        b.ordinals = new uint64[](capacity);
    }

    function _add(Appends memory b, bytes32 family, PostingKey key, uint64 ordinal) private pure {
        uint256 n = b.n;
        if (n == b.keys.length) {
            // a topic's ancestor walk has no depth cap: double the buffer
            Appends memory g = _appends(2 * n);
            for (uint256 i; i < n; ++i) {
                g.families[i] = b.families[i];
                g.keys[i] = b.keys[i];
                g.ordinals[i] = b.ordinals[i];
            }
            (b.families, b.keys, b.ordinals) = (g.families, g.keys, g.ordinals);
        }
        b.families[n] = FamilyId.wrap(family);
        b.keys[n] = key;
        b.ordinals[n] = ordinal;
        b.n = n + 1;
    }

    function _buffered(Appends memory b, PostingKey key) private pure returns (bool) {
        for (uint256 i; i < b.n; ++i) {
            if (PostingKey.unwrap(b.keys[i]) == PostingKey.unwrap(key)) return true;
        }
        return false;
    }

    function _flush(Appends memory b) private {
        uint256 n = b.n;
        if (n == 0) return;
        FamilyId[] memory f = b.families;
        PostingKey[] memory k = b.keys;
        uint64[] memory o = b.ordinals;
        assembly ("memory-safe") {
            mstore(f, n)
            mstore(k, n)
            mstore(o, n)
        }
        IPostingStore(POSTING).appendBatch(f, k, o);
    }

    function _foldRecord(Effect calldata e, bytes32[] calldata refs) private {
        IPostingStore ps = IPostingStore(POSTING);
        uint64 admission = e.admission;
        bytes32 t = e.typeId;
        Appends memory b = _appends(4 + refs.length + _specs.length);
        _add(b, F_BY_TYPE, _pk(t, 1, 0, 0), admission);
        _add(b, F_BY_AUTHOR, _pk(0, 4, 0, e.principalId), admission);
        if (e.freshRecord) {
            _add(b, F_UNIQUE_BY_TYPE, _pk(t, 13, 0, 0), admission);
            for (uint256 i; i < refs.length; ++i) {
                _add(b, F_REFERENCE_POSITION, _pk(t, 11, uint8(i), refs[i]), admission);
            }
            for (uint256 i; i < _specs.length; ++i) {
                DigestSpec storage spec = _specs[i];
                if (spec.typeId != t) continue;
                bytes32 word = ILedgerHot(LEDGER)
                    .extsload(bytes32(Layout.recordsBodyWordsSlot(e.recordId, spec.wordIndex)));
                PostingKey dk =
                    PostingKey.wrap(Keys.digestList(bytes32(uint256(spec.algorithm)), word));
                if (_buffered(b, dk)) continue; // two specs resolving to one key fold once
                _add(b, F_DIGEST, dk, admission);
            }
        } else {
            // by-record is virtual until the second occurrence: materialize the first entry then
            PostingKey key = _pk(0, 12, 0, e.recordId);
            (uint64 count,,,) = ps.postingHead(key);
            if (count == 0) {
                (, uint64 firstAdmission,,,) = ILedgerHot(LEDGER).recordHeader(e.recordId);
                _add(b, F_BY_RECORD, key, firstAdmission);
            }
            _add(b, F_BY_RECORD, key, admission);
        }
        _flush(b);
    }

    /// A bind's fold. The bitmap part (`_foldScope`) and the posting part read nothing of each other's store: the
    /// scope entry index the bitmap part takes from its own store feeds only its own `setBit`, and the posting part
    /// reads only its own heads (`_firstStatementLists`). So a build that heals one store runs one part alone, and
    /// the order of the two parts, which touch different stores, changes neither store.
    function _foldBind(Effect calldata e, bool posting, bool bitmap) private {
        uint8 tk = e.transitionKind;
        if (bitmap) _foldScope(e, tk);
        if (!posting) return;
        IPostingStore ps = IPostingStore(POSTING);
        uint64 admission = e.admission;
        Appends memory b = _appends(8);
        _add(b, F_HISTORY, _pk(0, 8, 0, Keys.binding(e.principalId, e.position)), admission);
        // a BIND that keeps its asserted target (a number-only re-bind) leaves the backlink list alone: releasing
        // and re-appending the same key would change no live count and only grow the list
        bool sameTarget = e.kind == ActionKind.BIND && e.oldTarget != 0 && e.oldTarget == e.target;
        if (e.oldTarget != 0 && !sameTarget) {
            ps.release(FamilyId.wrap(F_BACKLINK), _pk(e.purpose, 5, 0, e.oldTarget), 1);
        }
        if (tk == T_FIRST_BIND || tk == T_FIRST_MASK) {
            // a first statement of either sign appends the role-scope entry and the first-statement lists
            _add(
                b,
                F_ROLE_SCOPE,
                _pk(0, 16, 0, Keys.roleScope(e.principalId, e.purpose, e.role)),
                e.bindingOrdinal
            );
            _firstStatementLists(e, b);
        } else if (tk == T_RESTORE) {
            // a head returns to BOUND: one more author says yes at the position
            if (_authorsKept(e.purpose)) {
                ps.retain(FamilyId.wrap(F_POSITION_AUTHORS), _pk(0, 20, 0, e.position), 1);
            }
        } else if (tk != T_REBIND) {
            // MASK (from BOUND, MASKED or RELEASED) or RELEASE: a head leaves BOUND (the kernel sets `oldTarget` only
            // from a BOUND head, and a BIND's target is never zero): one fewer author says yes at the position; a
            // mask or release of a masked or released head changes nothing
            if (e.oldTarget != 0 && _authorsKept(e.purpose)) {
                ps.release(FamilyId.wrap(F_POSITION_AUTHORS), _pk(0, 20, 0, e.position), 1);
            }
        }
        if (e.kind == ActionKind.BIND && !sameTarget) {
            _add(b, F_BACKLINK, _pk(e.purpose, 5, 0, e.target), admission);
        }
        _flush(b);
    }

    /// A bind's bitmap part: the scope list (family 10) and its live bits (family 18), from the effect and the scope
    /// list in this generation's own bitmap store.
    function _foldScope(Effect calldata e, uint8 tk) private {
        IBitmapStore bs = IBitmapStore(BITMAP);
        uint64 admission = e.admission;
        ScopeKey scope = ScopeKey.wrap(Keys.scope(e.principalId, e.purpose, e.subject));
        if (tk == T_FIRST_BIND || tk == T_FIRST_MASK) {
            // a first statement of either sign appends the scope entry; the store appends live entries, so a first
            // mask clears the entry's live bit at once
            uint64 entry =
                bs.appendScopeEntry(FamilyId.wrap(F_SCOPE), scope, e.bindingOrdinal, admission);
            if (tk == T_FIRST_MASK) {
                bs.setBit(FamilyId.wrap(F_LIVE_SCOPE), scope, entry, false, admission);
            }
        } else if (tk == T_REBIND) {
            bs.stamp(scope, admission);
        } else {
            // RESTORE sets the entry's live bit; MASK (from BOUND, MASKED or RELEASED) or RELEASE clears it, and
            // clearing a clear bit changes no count
            bs.setBit(
                FamilyId.wrap(F_LIVE_SCOPE),
                scope,
                _entryIndex(bs, scope, e.bindingOrdinal),
                tk == T_RESTORE,
                admission
            );
        }
    }

    /// Whether the purpose keeps the first-statement lists (TAG and FOLDER).
    function _authorsKept(bytes32 purpose) private pure returns (bool) {
        return purpose == Purpose.TAG || purpose == Purpose.FOLDER;
    }

    /// The five first-statement lists (design §10.2 kinds 6, 7, 19, 20, 21), appended only at an author's FIRST
    /// statement on a position (FIRST_BIND or FIRST_MASK). A binding's ordinal is allocated once and a head never
    /// returns to UNSET, so no later re-bind, mask, release or restore of the author's appends to them, and no author
    /// adds more than one entry per position to any of them. Readers take the state and the number from the head.
    ///   - `position-authors` (TAG, FOLDER): key = the position; entry = this admission ordinal, for either sign.
    ///     Its head, read before the append, says whether the position is fresh (no author has stated anything
    ///     there). `count` = the authors who ever made a statement there; `live` = the authors whose head there is
    ///     BOUND now: a first yes raises it, a first no is appended UNCOUNTED, and `_foldBind` lowers it when a BOUND
    ///     head is masked or released and raises it on a restore (a counter, never an entry).
    ///   - `place` (TAG, FOLDER): key = (purpose, subject); entry = this binding ordinal, when the position is fresh
    ///     (either sign) or the statement is a first yes. In order of filing, so a position may appear more than once
    ///     (readers remove duplicates by position); `count` = filings, `live` = distinct positions ever stated at the
    ///     place (an "about" count: raised only by the fresh append, so it includes positions nobody says yes to now).
    ///   - `role-places` (TAG; fresh positions with a nonzero role): key = (TAG, role); entry = this binding
    ///     ordinal. The role of a tag is the thing tagged, so every statement of either sign is reachable from its
    ///     thing (`role-places` → position → `position-authors`), a lone negative included.
    ///   - `scope-below` (TAG, topic lists kept): key = (author, TAG, ancestor) for every PROPER ancestor of the
    ///     subject (the subject itself is the exact scope list, family 10); entry = this binding ordinal.
    ///   - `place-below` (TAG, topic lists kept): key = (TAG, ancestor) per proper ancestor; entry = this binding
    ///     ordinal, under the rule of `place`, with the same `count` and `live`.
    /// A publication has one principal, who makes at most one first statement per position, and every earlier effect
    /// of the publication is flushed before this one folds, so the head read sees every earlier statement.
    function _firstStatementLists(Effect calldata e, Appends memory b) private {
        bytes32 purpose = e.purpose;
        bool tag = purpose == Purpose.TAG;
        if (!tag && purpose != Purpose.FOLDER) return;
        PostingKey authors = _pk(0, 20, 0, e.position);
        (uint64 count,,,) = IPostingStore(POSTING).postingHead(authors);
        bool fresh = count == 0;
        bool yes = e.transitionKind == T_FIRST_BIND;
        _add(b, F_POSITION_AUTHORS, authors, yes ? e.admission : e.admission | UNCOUNTED);
        // a filing: the position's first statement (counted: a new distinct position) or a later author's first yes
        uint64 filing = fresh ? e.bindingOrdinal : e.bindingOrdinal | UNCOUNTED;
        if (fresh || yes) _add(b, F_PLACE, _pk(purpose, 6, 0, e.subject), filing);
        if (fresh && tag && e.role != 0) {
            _add(b, F_ROLE_PLACES, _pk(purpose, 21, 0, e.role), e.bindingOrdinal);
        }
        if (tag && TOPIC_T != 0) _walk(e, b, fresh || yes ? filing : 0);
    }

    /// Walks the proper ancestors of a tag's subject: a `topic/1` record's parent is its body word 0, a `topic-word/1`
    /// record is a root and ends the walk, anything else (an address-shaped home) has no ancestors. No depth cap: the
    /// walk is bounded by gas alone. One batched ledger read per level (the record's Type word and its body word 0).
    /// Nothing checks that the subject was registered before this statement: the unit list holds the final hook that
    /// refuses any other first tag (`FilesFinalValidator` code 9, strictly before), which the constructor requires
    /// (`IndexProfiles.requireTopicUnit`); every record read is write-once, so a replay walks what the live fold did.
    /// `filing` is the `place-below` entry (the binding ordinal, tagged UNCOUNTED unless the position is fresh), or 0
    /// when the statement files nothing there (a later author's first no).
    function _walk(Effect calldata e, Appends memory b, uint64 filing) private {
        ILedgerHot hot = ILedgerHot(LEDGER);
        bytes32[] memory slots = new bytes32[](2);
        bytes32 cur = e.subject;
        while (true) {
            slots[0] = bytes32(Layout.recordsCellsSlot(cur));
            slots[1] = bytes32(Layout.recordsBodyWordsSlot(cur, 0));
            bytes32[] memory w = hot.extsloadBatch(slots);
            if (cur != e.subject) {
                // `cur` is a proper ancestor: a topic/1 or topic-word/1 record by the topic Type's reference law
                if (w[0] != TOPIC_T && w[0] != WORD_T) return; // unreachable for a sound topic/1 record
                _add(
                    b,
                    F_SCOPE_BELOW,
                    _pk(0, 19, 0, Keys.scopeBelow(e.principalId, Purpose.TAG, cur)),
                    e.bindingOrdinal
                );
                if (filing != 0) _add(b, F_PLACE_BELOW, _pk(Purpose.TAG, 7, 0, cur), filing);
            }
            if (w[0] != TOPIC_T) return; // a root word, a home, or (unreachable) anything else
            cur = w[1];
        }
    }

    function _foldWithdraw(Effect calldata e) private {
        IPostingStore ps = IPostingStore(POSTING);
        ps.release(FamilyId.wrap(F_BY_TYPE), _pk(e.typeId, 1, 0, 0), 1);
        ps.release(FamilyId.wrap(F_BY_AUTHOR), _pk(0, 4, 0, e.withdrawnPrincipal), 1);
        PostingKey key = _pk(0, 12, 0, e.recordId);
        (uint64 count,,,) = ps.postingHead(key);
        // a withdrawn virtual first occurrence is materialized as a dead entry, so the list and the
        // ledger's occurrence count never drift and replay folds the same stream (review finding)
        if (count == 0) ps.append(FamilyId.wrap(F_BY_RECORD), key, e.withdrawnAdmission, 0);
        ps.release(FamilyId.wrap(F_BY_RECORD), key, 1);
    }

    /// Bisection over the scope list (strictly increasing binding ordinals).
    function _entryIndex(IBitmapStore bs, ScopeKey scope, uint64 bindingOrdinal)
        private
        view
        returns (uint64)
    {
        (uint64 count,,,,,) = bs.scopeHead(scope);
        uint64 lo;
        uint64 hi = count;
        while (lo < hi) {
            uint64 mid = (lo + hi) / 2;
            uint64 v = bs.scopeEntry(scope, mid);
            if (v == bindingOrdinal) return mid;
            if (v < bindingOrdinal) lo = mid + 1;
            else hi = mid;
        }
        revert E_ORDER(count, bindingOrdinal);
    }

    function _pk(bytes32 typeId, uint8 kind, uint8 ordinal, bytes32 value)
        private
        pure
        returns (PostingKey)
    {
        return PostingKey.wrap(Keys.posting(typeId, kind, ordinal, value));
    }

    // =============================================================================================
    // Readiness, replay, build, backfill (design §10.5, §10.6)
    // =============================================================================================

    /// @inheritdoc IRealmIndex
    /// @dev Fresh stores only: both stores name this generation as INITIAL_WRITER and are unattached, this
    ///      generation has never folded live, the ledger is idle. One publication per call, decoded by the
    ///      pinned decoder (STATICCALL) and folded through `replayFold` on this contract, so the live fold
    ///      code is the replay fold code; `maxFacts` bounds the leaves of that publication (≤ 64). `build(0, n)`
    ///      walks the same way with a budget (docs INDEX-BUILD §3.3).
    function replayNextPublication(uint16 maxFacts) external returns (uint64 processed) {
        if (maxFacts == 0 || maxFacts > 64) revert E_REPLAY(6);
        if (DECODER == address(0)) revert E_REPLAY(5);
        Progress storage p = _gen().progress;
        if (p.liveStarted != 0 || _carried() != 0) revert E_REPLAY(1);
        (uint8 phase,,,) = ILedgerHot(LEDGER).phase();
        if (phase != Phase.IDLE) revert E_REPLAY(3);
        if (p.replayStage == 4) revert E_REPLAY(3); // a fold hook re-entering the replay in flight
        (,,, uint64 publications) = ILedgerHot(LEDGER).counts();
        uint64 n = p.lastPublication + 1;
        if (n > publications) return 0;
        p.replayStage = 4; // IN_FLIGHT
        processed = _replayOne(n, 0);
        if (processed > maxFacts) revert E_REPLAY(6);
        p.replayStage = n == publications ? 3 : 2; // CAUGHT_UP : REPLAYING
    }

    /// Publication `n` from history: decoded by the pinned decoder (STATICCALL), then folded by this contract calling
    /// its own `replayFold`, so the effects are in calldata as the live fold expects. The carried mask rides as one
    /// word after the ABI payload (the ABI decoder ignores trailing calldata), so it is chosen here, by this code, and
    /// never by a caller. Returns the leaves folded.
    function _replayOne(uint64 n, uint256 carried) private returns (uint64) {
        (bool ok, bytes memory ret) =
            DECODER.staticcall(abi.encodeCall(IIndexReplayDecoder.payload, (LEDGER, n)));
        if (!ok) _bubble(ret);
        bytes memory encoded = abi.decode(ret, (bytes));
        (ok, ret) =
            address(this).call(bytes.concat(this.replayFold.selector, encoded, bytes32(carried)));
        if (!ok) _bubble(ret);
        return abi.decode(ret, (uint64));
    }

    /// The replay and build fold: the decoder's payload, applied exactly as a live `onAdmission` would be, by this
    /// contract calling itself (the stores see the generation as INITIAL_WRITER before attachment), with the carried
    /// mask `_replayOne` appended after the payload.
    function replayFold(uint64 publication, Effect[] calldata effects, bytes32[] calldata refs)
        external
        returns (uint64)
    {
        if (msg.sender != address(this)) revert E_WRITER(msg.sender);
        _foldPublication(
            publication, effects, refs, uint256(bytes32(msg.data[msg.data.length - 32:]))
        );
        return uint64(effects.length);
    }

    /// The carried mask of this generation's stores (`CARRIED_POSTING`, `CARRIED_BITMAP`). A store is fresh for this
    /// generation when it names this generation as `INITIAL_WRITER` and no live write has attached it; every other
    /// store this generation names is carried (re-pinned: the live index folded its history). Virtual so that a
    /// later generation with more stores (docs INDEX-BUILD step 3) can add its own bits.
    function _carried() internal view virtual returns (uint256 mask) {
        if (!_isFresh(POSTING)) mask |= CARRIED_POSTING;
        if (!_isFresh(BITMAP)) mask |= CARRIED_BITMAP;
    }

    /// The mask with every store of this generation carried: nothing to walk.
    function _allCarried() internal pure virtual returns (uint256) {
        return CARRIED_POSTING | CARRIED_BITMAP;
    }

    /// Whether a store that names this generation as `INITIAL_WRITER` has been attached by a live write: it is
    /// neither fresh (a build may not write it) nor carried (the live index did not fold it for this generation).
    /// Only a live write attaches, so an attached store of this generation's own means some live index wrote it
    /// (kernel reason 13 refuses the same).
    function _spoiled() internal view virtual returns (bool) {
        return _isSpoiled(POSTING) || _isSpoiled(BITMAP);
    }

    /// The posting and bitmap stores answer the same two getters.
    function _isFresh(address store) internal view returns (bool) {
        return
            IPostingStore(store).initialWriter() == address(this)
                && !IPostingStore(store).attached();
    }

    function _isSpoiled(address store) internal view returns (bool) {
        return
            IPostingStore(store).initialWriter() == address(this) && IPostingStore(store).attached();
    }

    function _bubble(bytes memory ret) private pure {
        assembly ("memory-safe") {
            revert(add(ret, 32), mload(ret))
        }
    }

    function decoder() external view returns (address) {
        return DECODER;
    }

    /// @inheritdoc IRealmIndex
    /// @dev Docs INDEX-BUILD §3.2–3.5. Permissionless and idle-gated; `familyId` must be 0 (one walk builds every
    ///      built family). Refused: a nonzero `familyId` (8); once this generation is the live index or has folded
    ///      live (1); inside a publication, or while a replay or build call of this generation is in flight (3); when
    ///      a store names this generation as INITIAL_WRITER but is attached (2); when the carried check fails (7).
    ///
    ///      With no fresh store (a re-pin) nothing is folded: the live index keeps every carried family in the very
    ///      store this generation names and folds every admission synchronously, so the frontier moves straight to
    ///      `counts()` and moves again on the next call after more publications; `maxFacts` bounds nothing.
    ///
    ///      With a fresh store (both fresh: the full replay; one fresh: a build that heals that store), the call
    ///      walks history from the frontier, one whole publication at a time, while the leaves folded in this call
    ///      plus the next publication's leaf count stay within `maxFacts`, and folds only the families of the fresh
    ///      stores (the carried mask; §4.3: no family's fold reads the other store). The next publication's leaf
    ///      count is read from its evidence cell before it is decoded (one ledger read, which the decoder then reads
    ///      warm). It folds at least one publication when one is pending and reverts `E_BUILD(6)` when the first
    ///      pending one alone exceeds `maxFacts` (so `maxFacts >= 64` always makes progress); with nothing pending it
    ///      returns the frontier. No decoder pinned: `E_BUILD(5)`. Returns the last admission folded (the frontier).
    function build(bytes32 familyId, uint16 maxFacts) external returns (uint64 through) {
        if (familyId != 0) revert E_BUILD(8);
        Progress storage p = _gen().progress;
        ILedgerHot hot = ILedgerHot(LEDGER);
        if (p.liveStarted != 0 || hot.index() == address(this)) revert E_BUILD(1);
        (uint8 phase,,,) = hot.phase();
        if (phase != Phase.IDLE || p.replayStage == 4) revert E_BUILD(3);
        if (_spoiled()) revert E_BUILD(2);
        if (!IndexReads(READS).carriedCheck()) revert E_BUILD(7);
        (uint64 admissions,,, uint64 publications) = hot.counts();
        uint256 carried = _carried();
        if (carried == _allCarried()) {
            p.lastProcessed = uint48(admissions);
            p.lastPublication = uint48(publications);
            p.replayStage = 3; // CAUGHT_UP
            return admissions;
        }
        if (DECODER == address(0)) revert E_BUILD(5);
        uint64 n = p.lastPublication + 1;
        uint256 used;
        p.replayStage = 4; // IN_FLIGHT
        for (; n <= publications; ++n) {
            (,,,, uint8 leaves,,) = Layout.unpackEvidenceCellWord0(
                hot.extsload(bytes32(Layout.publicationsEvidenceSlot(n)))
            );
            if (used + leaves > maxFacts) {
                if (used == 0) revert E_BUILD(6);
                break;
            }
            used += _replayOne(n, carried);
        }
        p.replayStage = n > publications ? 3 : 2; // CAUGHT_UP : BUILDING
        return p.lastProcessed;
    }

    /// @inheritdoc IRealmIndex
    function backfill(bytes32, ScopeKey, uint64, uint16) external pure returns (uint64) {
        revert E_BACKFILL(0);
    }

    // =============================================================================================
    // Reads answered here (design §5.11); every other read is forwarded to READS
    // =============================================================================================

    function manifestHash() external view returns (bytes32) {
        return MANIFEST_HASH;
    }

    /// Read by the ingress on every publication's quote, so it is answered here (no forwarding hop on a write).
    function workModel() external view returns (WorkModel memory) {
        return _work;
    }

    /// Read by the ingress per fresh record of a Type, so it is answered here.
    function digestSpecCount(bytes32 typeId) external view returns (uint256 n) {
        for (uint256 i; i < _specs.length; ++i) {
            if (_specs[i].typeId == typeId) ++n;
        }
    }

    /// Also the reads contract's source for coverage and readiness (it asks its caller).
    function progress()
        external
        view
        returns (uint64 lastProcessed, uint64 lastPublication, bool gapped)
    {
        Progress storage p = _gen().progress;
        return (p.lastProcessed, p.lastPublication, p.gapped != 0);
    }

    /// Read by final hooks during a publication (`FilesFinalValidator`), so it is answered here.
    function ledger() external view returns (address) {
        return LEDGER;
    }

    function postingStore() external view returns (address) {
        return POSTING;
    }

    function bitmapStore() external view returns (address) {
        return BITMAP;
    }

    function readsContract() external view returns (address, bytes32) {
        return (READS, READS_CODEHASH);
    }

    /// @inheritdoc IRealmIndex
    /// @dev Answered by READS (it encodes the unit and family tables), returned unchanged.
    function replayReadiness() external view returns (Readiness memory) {
        _forward();
    }

    /// Forwards the reads this contract does not answer (manifest, coverage, postings) to READS.
    fallback() external {
        _forward();
    }

    /// `STATICCALL`s READS with the calldata unchanged and returns or reverts with its returndata: no state can
    /// change through it, and an unknown selector reverts in READS. It never returns to Solidity, so it may use
    /// memory from offset 0.
    function _forward() private view {
        address reads = READS;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := staticcall(gas(), reads, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            if iszero(ok) { revert(0, returndatasize()) }
            return(0, returndatasize())
        }
    }
}
