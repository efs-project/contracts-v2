// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {GenerationStorage} from "./storage/GenerationStorage.sol";
import {IndexProfiles} from "./IndexProfiles.sol";
import {Layout} from "../core/layout/Layout.sol";
import {Keys} from "../lib/Keys.sol";
import {ActionKind, FamilyId, PostingKey, ScopeKey, TypeId} from "../interfaces/Actions.sol";
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
///         state. The replay, build and backfill entry points of §10.6 run through the pinned `IndexBuild`
///         delegate, which generation 1 does not carry yet: they revert until that build lands.
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
        Progress storage p = _gen().progress;
        uint64 expected = p.lastProcessed + 1;
        uint256 refIndex;
        for (uint256 i; i < effects.length; ++i) {
            Effect calldata e = effects[i];
            if (e.admission != expected) revert E_ORDER(expected, e.admission);
            if (e.publication != publication) revert E_STAGED(publication, e.publication);
            _fold(e, refs[refIndex:refIndex + e.refCount]);
            refIndex += e.refCount;
            ++expected;
        }
        p.lastProcessed = uint48(expected - 1);
        p.lastPublication = uint48(publication);
        p.liveStarted = 1;
        _foldHooks(effects, refs, publication);
        return IRealmIndex.onAdmission.selector;
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

    function _fold(Effect calldata e, bytes32[] calldata refs) private {
        uint8 kind = e.kind;
        if (kind == ActionKind.PUBLISH || kind == ActionKind.REUSE) {
            _foldRecord(e, refs);
        } else if (
            kind == ActionKind.BIND || kind == ActionKind.UNBIND || kind == ActionKind.RELEASE
        ) {
            _foldBind(e);
        } else if (kind == ActionKind.WITHDRAW) {
            _foldWithdraw(e);
        }
        // CREATE touches no family
    }

    function _foldRecord(Effect calldata e, bytes32[] calldata refs) private {
        IPostingStore ps = IPostingStore(POSTING);
        uint64 admission = e.admission;
        bytes32 t = e.typeId;
        ps.append(FamilyId.wrap(F_BY_TYPE), _pk(t, 1, 0, 0), admission, 0);
        ps.append(FamilyId.wrap(F_BY_AUTHOR), _pk(0, 4, 0, e.principalId), admission, 0);
        if (e.freshRecord) {
            ps.append(FamilyId.wrap(F_UNIQUE_BY_TYPE), _pk(t, 13, 0, 0), admission, 0);
            for (uint256 i; i < refs.length; ++i) {
                ps.append(
                    FamilyId.wrap(F_REFERENCE_POSITION), _pk(t, 11, uint8(i), refs[i]), admission, 0
                );
            }
            for (uint256 i; i < _specs.length; ++i) {
                DigestSpec storage spec = _specs[i];
                if (spec.typeId != t) continue;
                bytes32 word = ILedgerHot(LEDGER)
                    .extsload(bytes32(Layout.recordsBodyWordsSlot(e.recordId, spec.wordIndex)));
                PostingKey dk =
                    PostingKey.wrap(Keys.digestList(bytes32(uint256(spec.algorithm)), word));
                (,, uint64 dlast,) = ps.postingHead(dk);
                if (dlast == admission) continue; // two specs resolving to one key fold once
                ps.append(FamilyId.wrap(F_DIGEST), dk, admission, 0);
            }
        } else {
            // by-record is virtual until the second occurrence: materialize the first entry then
            PostingKey key = _pk(0, 12, 0, e.recordId);
            (uint64 count,,,) = ps.postingHead(key);
            if (count == 0) {
                (, uint64 firstAdmission,,,) = ILedgerHot(LEDGER).recordHeader(e.recordId);
                ps.append(FamilyId.wrap(F_BY_RECORD), key, firstAdmission, 0);
            }
            ps.append(FamilyId.wrap(F_BY_RECORD), key, admission, 0);
        }
    }

    function _foldBind(Effect calldata e) private {
        IPostingStore ps = IPostingStore(POSTING);
        IBitmapStore bs = IBitmapStore(BITMAP);
        uint64 admission = e.admission;
        bytes32 scope = Keys.scope(e.principalId, e.purpose, e.subject);
        bytes32 bindingKey = Keys.binding(e.principalId, e.position);
        ps.append(FamilyId.wrap(F_HISTORY), _pk(0, 8, 0, bindingKey), admission, 0);
        if (e.oldTarget != 0) ps.release(FamilyId.wrap(F_BACKLINK), _pk(0, 5, 0, e.oldTarget), 1);
        uint8 tk = e.transitionKind;
        if (tk == T_FIRST_BIND || tk == T_FIRST_MASK) {
            // a first statement of either sign appends the scope entry and the role-scope entry; the store
            // appends live entries, so a first mask clears the entry's live bit at once
            uint64 entry = bs.appendScopeEntry(
                FamilyId.wrap(F_SCOPE), ScopeKey.wrap(scope), e.bindingOrdinal, admission
            );
            if (tk == T_FIRST_MASK) {
                bs.setBit(
                    FamilyId.wrap(F_LIVE_SCOPE), ScopeKey.wrap(scope), entry, false, admission
                );
            }
            ps.append(
                FamilyId.wrap(F_ROLE_SCOPE),
                _pk(0, 16, 0, Keys.roleScope(e.principalId, e.purpose, e.role)),
                e.bindingOrdinal,
                0
            );
        } else if (tk == T_REBIND) {
            bs.stamp(ScopeKey.wrap(scope), admission);
        } else if (tk == T_RESTORE) {
            bs.setBit(
                FamilyId.wrap(F_LIVE_SCOPE),
                ScopeKey.wrap(scope),
                _entryIndex(bs, scope, e.bindingOrdinal),
                true,
                admission
            );
        } else {
            // MASK (from BOUND, MASKED or RELEASED) or RELEASE; clearing a clear bit changes no count
            bs.setBit(
                FamilyId.wrap(F_LIVE_SCOPE),
                ScopeKey.wrap(scope),
                _entryIndex(bs, scope, e.bindingOrdinal),
                false,
                admission
            );
        }
        if (e.kind == ActionKind.BIND) {
            ps.append(FamilyId.wrap(F_BACKLINK), _pk(0, 5, 0, e.target), admission, 0);
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
    function _entryIndex(IBitmapStore bs, bytes32 scope, uint64 bindingOrdinal)
        private
        view
        returns (uint64)
    {
        (uint64 count,,,,,) = bs.scopeHead(ScopeKey.wrap(scope));
        uint64 lo;
        uint64 hi = count;
        while (lo < hi) {
            uint64 mid = (lo + hi) / 2;
            uint64 v = bs.scopeEntry(ScopeKey.wrap(scope), mid);
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
    ///      code is the replay fold code; `maxFacts` bounds the leaves of that publication (≤ 64).
    function replayNextPublication(uint16 maxFacts) external returns (uint64 processed) {
        if (maxFacts == 0 || maxFacts > 64) revert E_REPLAY(6);
        if (DECODER == address(0)) revert E_REPLAY(5);
        Progress storage p = _gen().progress;
        if (p.liveStarted != 0 || !_fresh()) revert E_REPLAY(1);
        (uint8 phase,,,) = ILedgerHot(LEDGER).phase();
        if (phase != Phase.IDLE) revert E_REPLAY(3);
        if (p.replayStage == 4) revert E_REPLAY(3); // a fold hook re-entering the replay in flight
        (,,, uint64 publications) = ILedgerHot(LEDGER).counts();
        uint64 n = p.lastPublication + 1;
        if (n > publications) return 0;
        p.replayStage = 4; // IN_FLIGHT
        (bool ok, bytes memory ret) =
            DECODER.staticcall(abi.encodeCall(IIndexReplayDecoder.payload, (LEDGER, n)));
        if (!ok) _bubble(ret);
        bytes memory encoded = abi.decode(ret, (bytes));
        (ok, ret) = address(this).call(bytes.concat(this.replayFold.selector, encoded));
        if (!ok) _bubble(ret);
        processed = abi.decode(ret, (uint64));
        if (processed > maxFacts) revert E_REPLAY(6);
        p.replayStage = n == publications ? 3 : 2; // CAUGHT_UP : REPLAYING
    }

    /// The replay fold: the decoder's payload, applied exactly as a live `onAdmission` would be, by this
    /// contract calling itself (the stores see the generation as INITIAL_WRITER before attachment).
    function replayFold(uint64 publication, Effect[] calldata effects, bytes32[] calldata refs)
        external
        returns (uint64)
    {
        if (msg.sender != address(this)) revert E_WRITER(msg.sender);
        Progress storage p = _gen().progress;
        uint64 expected = p.lastProcessed + 1;
        uint256 refIndex;
        for (uint256 i; i < effects.length; ++i) {
            Effect calldata e = effects[i];
            if (e.admission != expected) revert E_ORDER(expected, e.admission);
            if (e.publication != publication) revert E_STAGED(publication, e.publication);
            _fold(e, refs[refIndex:refIndex + e.refCount]);
            refIndex += e.refCount;
            ++expected;
        }
        p.lastProcessed = uint48(expected - 1);
        p.lastPublication = uint48(publication);
        _foldHooks(effects, refs, publication);
        return uint64(effects.length);
    }

    function _fresh() private view returns (bool) {
        return IPostingStore(POSTING).initialWriter() == address(this)
            && !IPostingStore(POSTING).attached()
            && IBitmapStore(BITMAP).initialWriter() == address(this)
            && !IBitmapStore(BITMAP).attached();
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
    function build(bytes32, uint16) external pure returns (uint64) {
        revert E_BUILD(0);
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
