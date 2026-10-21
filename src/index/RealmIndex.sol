// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {GenerationStorage} from "./storage/GenerationStorage.sol";
import {Layout} from "../core/layout/Layout.sol";
import {Keys} from "../lib/Keys.sol";
import {ActionKind, FamilyId, PostingKey, ScopeKey, TypeId} from "../interfaces/Actions.sol";
import {Coverage, Phase} from "../interfaces/Results.sol";
import {ILedgerHot} from "../interfaces/ILedgerHot.sol";
import {ITypeRegistry} from "../interfaces/ITypeRegistry.sol";
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
    E_REPLAY,
    E_STAGED,
    E_WRITER
} from "../interfaces/Errors.sol";

/// @title RealmIndex — generation 1: an immutable dispatcher over the per-Realm family stores (design §10)
/// @notice Holds no posting storage: it folds every Effect/3 into `PostingStore`/`BitmapStore` under the
///         stores' writer rule and keeps only its progress word. The manifest (families, units, digest
///         specs, work model, profiles) is fixed at construction and folded into `MANIFEST_HASH`. The
///         replay, build and backfill entry points of §10.6 run through the pinned `IndexBuild` delegate,
///         which generation 1 does not carry yet: they revert until that build lands.
contract RealmIndex is IRealmIndex, IIndexReads, GenerationStorage {
    address public immutable LEDGER;
    bytes32 public immutable LAYOUT_ID;
    bytes32 public immutable HOT_ABI_ID;
    address public immutable DECODER;
    address public immutable POSTING;
    address public immutable BITMAP;
    bytes32 public immutable MANIFEST_HASH;
    bytes32 public constant PHYSICAL_PROFILE =
        keccak256("efs2/index-layout/1:stores:inline-singleton:five-u48:live-bits-in-head");
    bytes32 public constant CALLBACK_PROFILE =
        keccak256("efs2/index-callback/3:ordered-prefix:static-final:effect-24:refs");
    bytes32 public constant MANIFEST_HEADER = keccak256("efs2/index-manifest/1");
    uint64 private constant NOT_MAINTAINED = type(uint64).max;
    uint8 private constant SHAPE_APPEND = 1;
    uint8 private constant SHAPE_BITMAP = 2;
    uint8 private constant T_FIRST_BIND = 1;
    uint8 private constant T_REBIND = 2;
    uint8 private constant T_MASK = 3;
    uint8 private constant T_RELEASE = 4;
    uint8 private constant T_RESTORE = 5;

    bytes32 private immutable F_BY_TYPE;
    bytes32 private immutable F_BY_AUTHOR;
    bytes32 private immutable F_BACKLINK;
    bytes32 private immutable F_HISTORY;
    bytes32 private immutable F_SCOPE;
    bytes32 private immutable F_REFERENCE_POSITION;
    bytes32 private immutable F_BY_RECORD;
    bytes32 private immutable F_UNIQUE_BY_TYPE;
    bytes32 private immutable F_SCALAR;
    bytes32 private immutable F_DIGEST;
    bytes32 private immutable F_ROLE_SCOPE;
    bytes32 private immutable F_ROSTER;
    bytes32 private immutable F_LIVE_SCOPE;

    FamilyEntry[] private _families;
    Unit[] private _units;
    DigestSpec[] private _specs;
    WorkModel private _work;

    constructor(
        address ledger_,
        bytes32 hotAbiId,
        address decoder,
        address posting,
        address bitmap,
        Unit[] memory units,
        DigestSpec[] memory specs,
        WorkModel memory work
    ) {
        LEDGER = ledger_;
        LAYOUT_ID = Layout.LAYOUT_ID;
        HOT_ABI_ID = hotAbiId;
        DECODER = decoder;
        POSTING = posting;
        BITMAP = bitmap;
        F_BY_TYPE = Keys.familyId("by-type");
        F_BY_AUTHOR = Keys.familyId("by-author");
        F_BACKLINK = Keys.familyId("backlink");
        F_HISTORY = Keys.familyId("history");
        F_SCOPE = Keys.familyId("scope");
        F_REFERENCE_POSITION = Keys.familyId("reference-position");
        F_BY_RECORD = Keys.familyId("by-record");
        F_UNIQUE_BY_TYPE = Keys.familyId("unique-by-type");
        F_SCALAR = Keys.familyId("scalar");
        F_DIGEST = Keys.familyId("digest");
        F_ROLE_SCOPE = Keys.familyId("role-scope");
        F_ROSTER = Keys.familyId("roster");
        F_LIVE_SCOPE = Keys.familyId("live-scope");
        _declare(F_BY_TYPE, 1, 1, SHAPE_APPEND, 2, posting, 1);
        _declare(F_BY_AUTHOR, 4, 2, SHAPE_APPEND, 2, posting, 1);
        _declare(F_BACKLINK, 5, 4, SHAPE_APPEND, 3, posting, 1);
        _declare(F_HISTORY, 8, 3, SHAPE_APPEND, 1, posting, 1);
        _declare(F_SCOPE, 10, 3, SHAPE_APPEND, 1, bitmap, 1);
        _declare(F_REFERENCE_POSITION, 11, 1, SHAPE_APPEND, 1, posting, 1);
        _declare(F_BY_RECORD, 12, 5, SHAPE_APPEND, 2, posting, 1);
        _declare(F_UNIQUE_BY_TYPE, 13, 1, SHAPE_APPEND, 1, posting, 1);
        _declare(F_SCALAR, 14, 1, SHAPE_APPEND, 1, posting, 1);
        _declare(F_DIGEST, 15, 5, SHAPE_APPEND, 1, posting, 1);
        _declare(F_ROLE_SCOPE, 16, 3, SHAPE_APPEND, 1, posting, 1);
        _declare(F_ROSTER, 17, 3, SHAPE_BITMAP, 2, bitmap, NOT_MAINTAINED);
        _declare(F_LIVE_SCOPE, 18, 3, SHAPE_BITMAP, 2, bitmap, 1);
        for (uint256 i; i < units.length; ++i) {
            _units.push(units[i]);
        }
        for (uint256 i; i < specs.length; ++i) {
            _specs.push(specs[i]);
        }
        _work = work;
        MANIFEST_HASH = keccak256(
            abi.encode(
                MANIFEST_HEADER, _families, units, specs, work, PHYSICAL_PROFILE, CALLBACK_PROFILE
            )
        );
        _gen().progress.replayStage = 1; // FRESH
    }

    function _declare(
        bytes32 id,
        uint8 kind,
        uint8 universe,
        uint8 shape,
        uint8 liveSemantics,
        address store,
        uint64 from
    ) private {
        _families.push(
            FamilyEntry({
                familyId: id,
                kind: kind,
                universe: universe,
                shape: shape,
                mandatory: from == 1,
                liveSemantics: liveSemantics,
                recipe: keccak256(abi.encodePacked("efs2/family-recipe/", kind)),
                fromAdmission: from,
                store: store,
                storeCodehash: store.codehash
            })
        );
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
        if (tk == T_FIRST_BIND) {
            bs.appendScopeEntry(
                FamilyId.wrap(F_SCOPE), ScopeKey.wrap(scope), e.bindingOrdinal, admission
            );
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
            // MASK or RELEASE
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
    function replayReadiness() external view returns (Readiness memory r) {
        Progress storage p = _gen().progress;
        (uint8 phase,,,) = ILedgerHot(LEDGER).phase();
        (uint64 admissions,,, uint64 publications) = ILedgerHot(LEDGER).counts();
        r.version = 1;
        r.ledger = LEDGER;
        r.layoutId = LAYOUT_ID;
        r.hotAbiId = HOT_ABI_ID;
        r.physicalProfile = PHYSICAL_PROFILE;
        r.callbackProfile = CALLBACK_PROFILE;
        r.manifestHash = MANIFEST_HASH;
        r.provenFrom = 1;
        r.completedAdmission = p.lastProcessed;
        r.completedPublication = p.lastPublication;
        r.phase = phase;
        r.ready = phase == Phase.IDLE && p.lastProcessed == admissions
            && p.lastPublication == publications && p.gapped == 0;
        r.units = _units;
        r.families = _families;
        r.build = address(0);
        r.buildCodehash = bytes32(0);
    }

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
    // Reads (design §5.11, §10.5)
    // =============================================================================================

    function manifestHash() external view returns (bytes32) {
        return MANIFEST_HASH;
    }

    function manifest()
        external
        view
        returns (
            bytes32 header,
            FamilyEntry[] memory families,
            Unit[] memory units,
            DigestSpec[] memory specs,
            WorkModel memory work,
            bytes32 physicalProfile,
            bytes32 callbackProfile
        )
    {
        return (
            MANIFEST_HEADER, _families, _units, _specs, _work, PHYSICAL_PROFILE, CALLBACK_PROFILE
        );
    }

    function workModel() external view returns (WorkModel memory) {
        return _work;
    }

    function _familyEntry(bytes32 id) private view returns (bool found, FamilyEntry storage f) {
        for (uint256 i; i < _families.length; ++i) {
            if (_families[i].familyId == id) return (true, _families[i]);
        }
        return (false, _families[0]);
    }

    function _coverage(bytes32 id) private view returns (Coverage, uint64, uint64, uint8) {
        (bool found, FamilyEntry storage f) = _familyEntry(id);
        (uint8 phase,,,) = ILedgerHot(LEDGER).phase();
        if (!found || f.fromAdmission == NOT_MAINTAINED) return (Coverage.UNKNOWN, 0, 0, phase);
        Progress storage p = _gen().progress;
        (uint64 admissions,,,) = ILedgerHot(LEDGER).counts();
        uint64 through = p.lastProcessed;
        bool complete = p.gapped == 0 && through == admissions;
        return (complete ? Coverage.COMPLETE : Coverage.PARTIAL, 1, through, phase);
    }

    function coverage(FamilyId family, ScopeKey)
        external
        view
        returns (Coverage, uint64, uint64, uint8)
    {
        return _coverage(FamilyId.unwrap(family));
    }

    function coverageOfType(FamilyId family, TypeId typeId)
        external
        view
        returns (Coverage, uint64, uint64, uint8)
    {
        if (
            ITypeRegistry(ILedgerHot(LEDGER).registry()).typeInfo(TypeId.unwrap(typeId)).mandatory
                == address(0)
        ) {
            (uint8 phase,,,) = ILedgerHot(LEDGER).phase();
            return (Coverage.UNKNOWN, 0, 0, phase);
        }
        return _coverage(FamilyId.unwrap(family));
    }

    function coverageOfSpec(FamilyId family, TypeId typeId, uint8 specIndex)
        external
        view
        returns (Coverage, uint64, uint64, uint8)
    {
        if (specIndex >= _specs.length || _specs[specIndex].typeId != TypeId.unwrap(typeId)) {
            (uint8 phase,,,) = ILedgerHot(LEDGER).phase();
            return (Coverage.UNKNOWN, 0, 0, phase);
        }
        return _coverage(FamilyId.unwrap(family));
    }

    function coverageOfDigest(uint8 algorithm)
        external
        view
        returns (Coverage, uint64, uint64, uint8)
    {
        for (uint256 i; i < _specs.length; ++i) {
            if (_specs[i].algorithm == algorithm) return _coverage(F_DIGEST);
        }
        (uint8 phase,,,) = ILedgerHot(LEDGER).phase();
        return (Coverage.UNKNOWN, 0, 0, phase);
    }

    function provenFrom() external pure returns (uint64) {
        return 1;
    }

    function progress()
        external
        view
        returns (uint64 lastProcessed, uint64 lastPublication, bool gapped)
    {
        Progress storage p = _gen().progress;
        return (p.lastProcessed, p.lastPublication, p.gapped != 0);
    }

    function postingHeadOf(FamilyId family, TypeId typeId, uint8 ordinal, bytes32 value)
        external
        view
        returns (Coverage c, uint64 count, uint64 live, uint64 last, bool synthesized)
    {
        (bool found, FamilyEntry storage f) = _familyEntry(FamilyId.unwrap(family));
        (c,,,) = _coverage(FamilyId.unwrap(family));
        if (!found) return (Coverage.UNKNOWN, 0, 0, 0, false);
        (count, live, last,) =
            IPostingStore(POSTING).postingHead(_pk(TypeId.unwrap(typeId), f.kind, ordinal, value));
        if (count == 0 && f.kind == 12) {
            (, uint64 firstAdmission,, uint64 occurrences,) = ILedgerHot(LEDGER).recordHeader(value);
            if (firstAdmission != 0) return (c, 1, occurrences, firstAdmission, true);
        }
    }

    function postingSliceOf(
        FamilyId family,
        TypeId typeId,
        uint8 ordinal,
        bytes32 value,
        uint64 from,
        uint16 n
    ) external view returns (Coverage c, uint64[] memory entries, bool synthesized) {
        (bool found, FamilyEntry storage f) = _familyEntry(FamilyId.unwrap(family));
        (c,,,) = _coverage(FamilyId.unwrap(family));
        if (!found) return (Coverage.UNKNOWN, entries, false);
        PostingKey key = _pk(TypeId.unwrap(typeId), f.kind, ordinal, value);
        (uint64 count,,,) = IPostingStore(POSTING).postingHead(key);
        if (count == 0 && f.kind == 12) {
            (, uint64 firstAdmission,,,) = ILedgerHot(LEDGER).recordHeader(value);
            if (firstAdmission != 0 && from == 0 && n != 0) {
                entries = new uint64[](1);
                entries[0] = firstAdmission;
                return (c, entries, true);
            }
            return (c, entries, firstAdmission != 0);
        }
        entries = IPostingStore(POSTING).postingSlice(key, from, n);
    }

    function occurrencesOf(bytes32 recordId)
        external
        view
        returns (Coverage c, uint64 count, uint64 live, uint64[] memory entries)
    {
        (c,,,) = _coverage(F_BY_RECORD);
        PostingKey key = _pk(0, 12, 0, recordId);
        (count, live,,) = IPostingStore(POSTING).postingHead(key);
        if (count == 0) {
            (, uint64 firstAdmission,, uint64 occurrences,) =
                ILedgerHot(LEDGER).recordHeader(recordId);
            if (firstAdmission == 0) return (c, 0, 0, entries);
            entries = new uint64[](1);
            entries[0] = firstAdmission;
            return (c, 1, occurrences, entries);
        }
        entries = IPostingStore(POSTING)
            .postingSlice(key, 0, count > type(uint16).max ? type(uint16).max : uint16(count));
    }

    function ledger() external view returns (address) {
        return LEDGER;
    }

    function postingStore() external view returns (address) {
        return POSTING;
    }

    function bitmapStore() external view returns (address) {
        return BITMAP;
    }

    function buildDelegate() external pure returns (address) {
        return address(0);
    }
}
