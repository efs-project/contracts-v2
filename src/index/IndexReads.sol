// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IndexProfiles} from "./IndexProfiles.sol";
import {Layout} from "../core/layout/Layout.sol";
import {Keys} from "../lib/Keys.sol";
import {FamilyId, PostingKey, ScopeKey, TypeId} from "../interfaces/Actions.sol";
import {Coverage, Phase} from "../interfaces/Results.sol";
import {ILedgerHot} from "../interfaces/ILedgerHot.sol";
import {ITypeRegistry} from "../interfaces/ITypeRegistry.sol";
import {IIndexReads} from "../interfaces/IIndexReads.sol";
import {IPostingStore} from "../interfaces/IPostingStore.sol";
import {IRealmIndex} from "../interfaces/IRealmIndex.sol";
import {DigestSpec, FamilyEntry, Readiness, Unit, WorkModel} from "../interfaces/Index.sol";

/// @title IndexReads — the read side of a generation-1 index: its manifest and every coverage and family read
///        (design §5.11, §10.5)
/// @notice One per generation, deployed before it. It holds the manifest (families, units, digest specs, work
///         model) the generation is built from: the generation copies its units, specs and work model from here at
///         construction, so the two cannot disagree. Callers never call this contract: they call the generation,
///         whose fallback forwards every read it does not answer itself by `STATICCALL` with the calldata
///         unchanged, so the read runs here with `msg.sender` = the generation and no state can change.
///
///         The only generation state a read needs is its progress word and its manifest hash; this contract asks
///         `msg.sender` for both (`IIndexReads.progress()`, `IIndexReads.manifestHash()`, answered by the
///         generation itself). A direct call therefore answers from the caller's own claims and cannot mislead
///         anyone else; from an account without code it reverts. It holds no generation address, so there is no
///         address cycle, and it writes nothing after construction.
contract IndexReads {
    address public immutable LEDGER;
    bytes32 public immutable HOT_ABI_ID;
    address public immutable POSTING;
    address public immutable BITMAP;
    bytes32 private immutable F_BY_RECORD;
    bytes32 private immutable F_DIGEST;
    /// The Topics Type ids the topic lists walk (`topic/1`, `topic-word/1`), both zero when the generation keeps no
    /// topic lists; checked against the unit list at construction (`IndexProfiles.requireTopicUnit`).
    bytes32 public immutable TOPIC_TYPE;
    bytes32 public immutable TOPIC_WORD_TYPE;

    uint8 private constant SHAPE_APPEND = 1;
    uint8 private constant SHAPE_BITMAP = 2;
    uint8 private constant KIND_BY_RECORD = 12;

    FamilyEntry[] private _families;
    /// familyId → its index in `_families` + 1 (0 = undeclared), so a read finds its family in one SLOAD.
    mapping(bytes32 familyId => uint256) private _familyAt;
    Unit[] private _units;
    DigestSpec[] private _specs;
    WorkModel private _work;

    constructor(
        address ledger_,
        bytes32 hotAbiId,
        address posting,
        address bitmap,
        Unit[] memory units,
        DigestSpec[] memory specs,
        WorkModel memory work,
        bytes32 topicTypeId,
        bytes32 topicWordTypeId
    ) {
        IndexProfiles.requireTopicUnit(units, topicTypeId, topicWordTypeId);
        TOPIC_TYPE = topicTypeId;
        TOPIC_WORD_TYPE = topicWordTypeId;
        LEDGER = ledger_;
        HOT_ABI_ID = hotAbiId;
        POSTING = posting;
        BITMAP = bitmap;
        F_BY_RECORD = Keys.familyId("by-record");
        F_DIGEST = Keys.familyId("digest");
        uint64 live = 1;
        uint64 off = IndexProfiles.NOT_MAINTAINED;
        _declare("by-type", 1, 1, SHAPE_APPEND, 2, posting, live);
        _declare("by-author", 4, 2, SHAPE_APPEND, 2, posting, live);
        _declare("backlink", 5, 4, SHAPE_APPEND, 3, posting, live);
        _declare("history", 8, 3, SHAPE_APPEND, 1, posting, live);
        _declare("scope", 10, 3, SHAPE_APPEND, 1, bitmap, live);
        _declare("reference-position", 11, 1, SHAPE_APPEND, 1, posting, live);
        _declare("by-record", 12, 5, SHAPE_APPEND, 2, posting, live);
        _declare("unique-by-type", 13, 1, SHAPE_APPEND, 1, posting, live);
        _declare("scalar", 14, 1, SHAPE_APPEND, 1, posting, live);
        _declare("digest", 15, 5, SHAPE_APPEND, 1, posting, live);
        _declare("role-scope", 16, 3, SHAPE_APPEND, 1, posting, live);
        _declare("roster", 17, 3, SHAPE_BITMAP, 2, bitmap, off);
        _declare("live-scope", 18, 3, SHAPE_BITMAP, 2, bitmap, live);
        // the first-statement lists (design §10.2): the two topic roll-ups only with the topic Types
        uint64 topics = topicTypeId != 0 ? live : off;
        // DISTINCT: live = the distinct positions filed (a later author's first yes is appended uncounted)
        _declare("place", 6, 3, SHAPE_APPEND, 4, posting, live);
        _declare("place-below", 7, 3, SHAPE_APPEND, 4, posting, topics);
        _declare("scope-below", 19, 3, SHAPE_APPEND, 1, posting, topics);
        _declare("position-authors", 20, 3, SHAPE_APPEND, 3, posting, live); // HEADS: live = the yes-count
        _declare("role-places", 21, 4, SHAPE_APPEND, 1, posting, live);
        for (uint256 i; i < units.length; ++i) {
            _units.push(units[i]);
        }
        for (uint256 i; i < specs.length; ++i) {
            _specs.push(specs[i]);
        }
        _work = work;
    }

    function _declare(
        string memory name,
        uint8 kind,
        uint8 universe,
        uint8 shape,
        uint8 liveSemantics,
        address store,
        uint64 from
    ) private {
        bytes32 id = Keys.familyId(name);
        _families.push(
            FamilyEntry({
                familyId: id,
                kind: kind,
                universe: universe,
                shape: shape,
                mandatory: from == 1,
                liveSemantics: liveSemantics,
                recipe: keccak256(abi.encodePacked("efs/family-recipe/", kind)),
                fromAdmission: from,
                store: store,
                storeCodehash: store.codehash
            })
        );
        _familyAt[id] = _families.length;
    }

    // =============================================================================================
    // The manifest (design §5.11, §10.1)
    // =============================================================================================

    /// @dev The generation's `manifestHash()` is `keccak256(abi.encode(` these seven values `, reads, readsCodehash))`.
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
            IndexProfiles.MANIFEST_HEADER,
            _families,
            _units,
            _specs,
            _work,
            IndexProfiles.PHYSICAL,
            IndexProfiles.CALLBACK
        );
    }

    function workModel() external view returns (WorkModel memory) {
        return _work;
    }

    function digestSpecCount(bytes32 typeId) external view returns (uint256 n) {
        for (uint256 i; i < _specs.length; ++i) {
            if (_specs[i].typeId == typeId) ++n;
        }
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

    /// The topic Type ids the generation's topic lists walk; both zero when it keeps none (design §10.2).
    function topicTypes() external view returns (bytes32 topicTypeId, bytes32 topicWordTypeId) {
        return (TOPIC_TYPE, TOPIC_WORD_TYPE);
    }

    function buildDelegate() external pure returns (address) {
        return address(0);
    }

    function provenFrom() external pure returns (uint64) {
        return 1;
    }

    // =============================================================================================
    // Readiness and coverage (design §10.5)
    // =============================================================================================

    /// The progress of the calling generation.
    function _progress()
        private
        view
        returns (uint64 lastProcessed, uint64 lastPublication, bool gapped)
    {
        return IIndexReads(msg.sender).progress();
    }

    /// The carried check of the calling generation (docs INDEX-BUILD §3.5). A store is fresh for the generation when
    /// it names the generation as `INITIAL_WRITER` and is not attached, and carried otherwise. The generation did not
    /// fold a carried store's history; the live index did. So every family it maintains in a carried store must be
    /// declared by the live index (`ledger.index()`), with the same family id, in the same store, from admission 1,
    /// as the live index's own `replayReadiness().families` say. The live index folds every admission
    /// synchronously, so while this holds and the ledger is idle those families are complete through `counts()`.
    /// With no admissions there is no history to miss, so the check is the base case of the invariant "every store
    /// of the live index holds only what pinned generation code wrote": both of the generation's stores (each holds
    /// maintained families) must have an empty writers list, whoever their INITIAL_WRITER is. Every build-mode
    /// write records a range on its first call (`StoreBase._authorizeWriter`) and an empty Realm gives an honest
    /// build or replay nothing to fold, so a written store there was written by code nobody pinned. Genesis passes:
    /// its stores are new. With admissions: true when the caller is the live index (it folds them itself) and when
    /// the caller carries nothing; false when the live index has no code or its readiness read reverts. Asked by the
    /// generation's `build` and by `replayReadiness`.
    function carriedCheck() external view returns (bool) {
        return _carriedCheck(msg.sender);
    }

    function _carriedCheck(address gen) private view returns (bool) {
        (uint64 admissions,,,) = ILedgerHot(LEDGER).counts();
        if (admissions == 0) return _unwritten(POSTING) && _unwritten(BITMAP);
        address live = ILedgerHot(LEDGER).index();
        if (live == gen) return true;
        bool postingCarried = !_isFresh(POSTING, gen);
        bool bitmapCarried = !_isFresh(BITMAP, gen);
        if (!postingCarried && !bitmapCarried) return true;
        if (live.code.length == 0) return false;
        FamilyEntry[] memory theirs;
        try IRealmIndex(live).replayReadiness() returns (Readiness memory lr) {
            theirs = lr.families;
        } catch {
            return false;
        }
        for (uint256 i; i < _families.length; ++i) {
            FamilyEntry storage f = _families[i];
            if (f.fromAdmission == IndexProfiles.NOT_MAINTAINED) continue;
            if (!(f.store == POSTING ? postingCarried : bitmapCarried)) continue;
            if (!_declaresFromOne(theirs, f.familyId, f.store)) return false;
        }
        return true;
    }

    function _unwritten(address store) private view returns (bool) {
        (address[] memory gens,,) = IPostingStore(store).writers();
        return gens.length == 0;
    }

    function _isFresh(address store, address gen) private view returns (bool) {
        return IPostingStore(store).initialWriter() == gen && !IPostingStore(store).attached();
    }

    function _declaresFromOne(FamilyEntry[] memory list, bytes32 id, address store)
        private
        pure
        returns (bool)
    {
        for (uint256 i; i < list.length; ++i) {
            if (list[i].familyId == id && list[i].store == store && list[i].fromAdmission == 1) {
                return true;
            }
        }
        return false;
    }

    /// The `IRealmIndex.replayReadiness()` tuple of the calling generation. When the carried check fails, the
    /// generation claims nothing: `completedAdmission` and `completedPublication` are 0 (complete from 1 through
    /// 0) and `ready` is false, whatever its progress word says; otherwise they are its progress frontier. On an
    /// empty Realm a failed check reports 0, which equals the counts, so the tuple alone would pass the kernel's
    /// catch-up check (8): the kernel's own check 12 (`LedgerControl._checkIndex`, empty writers on an empty Realm)
    /// is what refuses that candidate; `ready` is false here for every other reader.
    function replayReadiness() external view returns (Readiness memory r) {
        (uint64 lastProcessed, uint64 lastPublication, bool gapped) = _progress();
        bool carried = _carriedCheck(msg.sender);
        if (!carried) (lastProcessed, lastPublication) = (0, 0);
        (uint8 phase,,,) = ILedgerHot(LEDGER).phase();
        (uint64 admissions,,, uint64 publications) = ILedgerHot(LEDGER).counts();
        r.version = 1;
        r.ledger = LEDGER;
        r.layoutId = Layout.LAYOUT_ID;
        r.hotAbiId = HOT_ABI_ID;
        r.physicalProfile = IndexProfiles.PHYSICAL;
        r.callbackProfile = IndexProfiles.CALLBACK;
        r.manifestHash = IIndexReads(msg.sender).manifestHash();
        r.provenFrom = 1;
        r.completedAdmission = lastProcessed;
        r.completedPublication = lastPublication;
        r.phase = phase;
        r.ready = carried && phase == Phase.IDLE && lastProcessed == admissions
            && lastPublication == publications && !gapped;
        r.units = _units;
        r.families = _families;
        r.build = address(0);
        r.buildCodehash = bytes32(0);
    }

    function _coverage(bytes32 id) private view returns (Coverage, uint64, uint64, uint8) {
        uint256 pos = _familyAt[id];
        (uint8 phase,,,) = ILedgerHot(LEDGER).phase();
        if (pos == 0 || _families[pos - 1].fromAdmission == IndexProfiles.NOT_MAINTAINED) {
            return (Coverage.UNKNOWN, 0, 0, phase);
        }
        (uint64 through,, bool gapped) = _progress();
        (uint64 admissions,,,) = ILedgerHot(LEDGER).counts();
        bool complete = !gapped && through == admissions;
        return (complete ? Coverage.COMPLETE : Coverage.PARTIAL, 1, through, phase);
    }

    function _unknown() private view returns (Coverage, uint64, uint64, uint8) {
        (uint8 phase,,,) = ILedgerHot(LEDGER).phase();
        return (Coverage.UNKNOWN, 0, 0, phase);
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
        ) return _unknown();
        return _coverage(FamilyId.unwrap(family));
    }

    function coverageOfSpec(FamilyId family, TypeId typeId, uint8 specIndex)
        external
        view
        returns (Coverage, uint64, uint64, uint8)
    {
        if (specIndex >= _specs.length || _specs[specIndex].typeId != TypeId.unwrap(typeId)) {
            return _unknown();
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
        return _unknown();
    }

    // =============================================================================================
    // Family reads (design §5.11, §10.2)
    // =============================================================================================

    function _pk(bytes32 typeId, uint8 kind, uint8 ordinal, bytes32 value)
        private
        pure
        returns (PostingKey)
    {
        return PostingKey.wrap(Keys.posting(typeId, kind, ordinal, value));
    }

    function postingHeadOf(FamilyId family, TypeId typeId, uint8 ordinal, bytes32 value)
        external
        view
        returns (Coverage c, uint64 count, uint64 live, uint64 last, bool synthesized)
    {
        uint256 pos = _familyAt[FamilyId.unwrap(family)];
        if (pos == 0) return (Coverage.UNKNOWN, 0, 0, 0, false);
        (c,,,) = _coverage(FamilyId.unwrap(family));
        uint8 kind = _families[pos - 1].kind;
        (count, live, last,) =
            IPostingStore(POSTING).postingHead(_pk(TypeId.unwrap(typeId), kind, ordinal, value));
        if (count == 0 && kind == KIND_BY_RECORD) {
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
        uint256 pos = _familyAt[FamilyId.unwrap(family)];
        if (pos == 0) return (Coverage.UNKNOWN, entries, false);
        (c,,,) = _coverage(FamilyId.unwrap(family));
        uint8 kind = _families[pos - 1].kind;
        PostingKey key = _pk(TypeId.unwrap(typeId), kind, ordinal, value);
        (uint64 count,,,) = IPostingStore(POSTING).postingHead(key);
        if (count == 0 && kind == KIND_BY_RECORD) {
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
        PostingKey key = _pk(0, KIND_BY_RECORD, 0, recordId);
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
}
