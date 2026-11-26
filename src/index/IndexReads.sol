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
import {DigestSpec, FamilyEntry, Readiness, Unit, WorkModel} from "../interfaces/Index.sol";
import {E_PIN} from "../interfaces/Errors.sol";

/// The calling generation's progress word with its live flag: what `_coverage` asks the generation (one call, as
/// `IIndexReads.progress()` was before), so a generation that has folded live answers with no ledger read for the
/// carried check. Answered by `RealmIndex.generationProgress`; not part of a consumer interface.
interface IGenerationProgress {
    function generationProgress()
        external
        view
        returns (uint64 lastProcessed, uint64 lastPublication, bool gapped, bool liveStarted);
}

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

    /// The copy of the live index's manifest preimage this generation was deployed with (`liveManifestCopy`), held
    /// as the code of a data contract this constructor created (one STOP byte, then the copy, as a descriptor blob
    /// is held), bound by address and codehash; both zero when the copy is empty (genesis, an empty Realm).
    address public immutable LIVE_COPY;
    bytes32 public immutable LIVE_COPY_CODEHASH;

    uint8 private constant SHAPE_APPEND = 1;
    uint8 private constant SHAPE_BITMAP = 2;
    uint8 private constant KIND_BY_RECORD = 12;
    /// `indexManifestHash` is word 8 of a revision row (`LedgerStorage.RevisionRow`; `LedgerReads` reads it there).
    uint256 private constant REVISION_MANIFEST_WORD = 8;
    /// The largest copy a data contract can hold: EIP-170's 24,576 B runtime less the leading STOP byte.
    uint256 private constant MAX_COPY = 24_575;

    FamilyEntry[] internal _families;
    /// familyId → its index in `_families` + 1 (0 = undeclared), so a read finds its family in one SLOAD.
    mapping(bytes32 familyId => uint256) internal _familyAt;
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
        bytes32 topicWordTypeId,
        bytes memory liveManifest
    ) {
        IndexProfiles.requireTopicUnit(units, topicTypeId, topicWordTypeId);
        (LIVE_COPY, LIVE_COPY_CODEHASH) = _holdCopy(liveManifest);
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

    /// Creates the data contract that holds `copy` as code after one STOP byte (so it can never run): initcode
    /// `PUSH2 len DUP1 PUSH1 12 PUSH1 0 CODECOPY PUSH1 0 RETURN` then the runtime. Nothing for an empty copy. The
    /// runtime is bounded by EIP-170 (24,576 B): a copy of up to 24,575 B, refused above it (`E_PIN(this, 12)`).
    function _holdCopy(bytes memory copy) private returns (address data, bytes32 codehash) {
        if (copy.length == 0) return (address(0), 0);
        if (copy.length > MAX_COPY) revert E_PIN(address(this), 12);
        bytes memory init = abi.encodePacked(
            hex"61", uint16(copy.length + 1), hex"80600c6000396000f3", hex"00", copy
        );
        assembly ("memory-safe") {
            data := create(0, add(init, 32), mload(init))
        }
        if (data == address(0)) revert E_PIN(address(this), 12);
        codehash = data.codehash;
    }

    function _declare(
        string memory name,
        uint8 kind,
        uint8 universe,
        uint8 shape,
        uint8 liveSemantics,
        address store,
        uint64 from
    ) internal {
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

    function liveManifestCopy() external view returns (bytes memory) {
        return _liveCopy();
    }

    /// The copy, read back from its data contract; empty when there is none, or when the contract at `LIVE_COPY`
    /// is not the one this constructor created (its code can never change: it starts with STOP).
    function _liveCopy() internal view returns (bytes memory copy) {
        address data = LIVE_COPY;
        if (data == address(0) || data.codehash != LIVE_COPY_CODEHASH) return copy;
        uint256 n = data.code.length - 1;
        copy = new bytes(n);
        assembly ("memory-safe") {
            extcodecopy(data, add(copy, 32), 1, n)
        }
    }

    /// The live index's families and units, from this generation's copy of its manifest: `ok` only when the copy
    /// hashes to the manifest hash the kernel recorded in the current revision row, the row that activated the live
    /// index (or kept it). No call reaches the live index. A copy taken before the live index was replaced is stale
    /// and fails here, as an empty one does on a Realm with history. The copy is the canonical encoding (it hashes
    /// to what the index computed with `abi.encode`), so decoding its leading three values is exact.
    function _liveManifest()
        internal
        view
        returns (bool ok, FamilyEntry[] memory families, Unit[] memory units)
    {
        bytes memory copy = _liveCopy();
        uint32 rev = ILedgerHot(LEDGER).revision();
        bytes32 recorded = ILedgerHot(LEDGER)
            .extsload(bytes32(Layout.revisionsRowsSlot(rev) + REVISION_MANIFEST_WORD));
        if (keccak256(copy) != recorded) return (false, families, units);
        (, families, units) = abi.decode(copy, (bytes32, FamilyEntry[], Unit[]));
        ok = true;
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
    /// as the live index's manifest says. That manifest is read from this generation's copy of it (`_liveManifest`),
    /// checked against the hash the kernel recorded when it activated the live index, never from the live index, so
    /// the check does not depend on the live index answering (docs INDEX-BUILD §3.5, §10). The live index folds every
    /// admission synchronously, so while this holds and the ledger is idle those families are complete through
    /// `counts()`.
    /// With no admissions there is no history to miss, so the check is the base case of the invariant "every store
    /// of the live index holds only what pinned generation code wrote": both of the generation's stores (each holds
    /// maintained families) must have an empty writers list, and an INITIAL_WRITER that is 0 or the generation itself.
    /// Every build-mode write records a range on its first call (`StoreBase._authorizeWriter`) and an empty Realm
    /// gives an honest build or replay nothing to fold, so a written store there was written by code nobody pinned;
    /// and a store's INITIAL_WRITER may write it in build mode until a live write attaches it, so on an empty Realm
    /// it must be nobody or this generation's own pinned code. Genesis passes: its stores are new, INITIAL_WRITER 0.
    /// With admissions: true when the caller is the live index (it folds them itself) and when the caller carries
    /// nothing; false when the copy is not the manifest the kernel recorded (empty, altered, of another index, or
    /// stale: taken before the live index was replaced; kernel reason 14 refuses the same), and false when a store
    /// names the caller as INITIAL_WRITER but is attached (only a live write attaches, so some live
    /// index wrote a store the caller never vouched for; kernel reason 13 refuses the same). Asked by the
    /// generation's `build`, by `replayReadiness` and by the coverage of a carried family of a generation that is
    /// not the live index.
    function carriedCheck() external view returns (bool) {
        return _carriedCheck(msg.sender);
    }

    /// Virtual so that a later generation with more stores (docs INDEX-BUILD step 3) can check them all.
    function _carriedCheck(address gen) internal view virtual returns (bool) {
        (uint64 admissions,,,) = ILedgerHot(LEDGER).counts();
        if (admissions == 0) return _unwritten(POSTING, gen) && _unwritten(BITMAP, gen);
        address live = ILedgerHot(LEDGER).index();
        if (live == gen) return true;
        (bool postingCarried, bool postingSpoiled) = _storeOf(POSTING, gen);
        (bool bitmapCarried, bool bitmapSpoiled) = _storeOf(BITMAP, gen);
        if (postingSpoiled || bitmapSpoiled) return false;
        if (!postingCarried && !bitmapCarried) return true;
        (bool ok, FamilyEntry[] memory theirs, Unit[] memory theirUnits) = _liveManifest();
        if (!ok) return false;
        for (uint256 i; i < _families.length; ++i) {
            FamilyEntry storage f = _families[i];
            if (f.fromAdmission == IndexProfiles.NOT_MAINTAINED) continue;
            if (!(f.store == POSTING ? postingCarried : bitmapCarried)) continue;
            if (!_declaresFromOne(theirs, f.familyId, f.store)) return false;
        }
        return _unitsCarried(theirUnits, !postingCarried || !bitmapCarried);
    }

    /// Option A (docs INDEX-BUILD §3.6), the half of the carried check for fold hooks, asked only when the generation
    /// carries a store (a build that carries a store calls no hook of a unit unless `_builtHooks` names it; an
    /// all-fresh build calls every hook from history). Every unit with a fold hook must be CARRIED: the live index
    /// (`theirs`, from the verified copy) declares a unit with the same fold hook, the same fold codehash and the same
    /// `purposeFilter`, the three fields that decide which effects `RealmIndex._foldHooks` gives the hook, so the live
    /// index has called it with exactly these effects for every admission. A wider filter would leave effects the hook
    /// never saw, a narrower one folds the hook would no longer be given; neither is what the hook would hold had it
    /// run from genesis under this unit, so both are NEW. `familyIds`, the final hook and its codehash, `hotAbiId` and
    /// `identity` decide no fold call and are not compared. A NEW unit passes only when `_builtHooks` names it AND the
    /// generation walks history (`walks`: it has a fresh store, so `build` folds every publication from 1 and calls the
    /// hook on each); a generation that carries every store walks nothing, so no claim to build a hook can be true for
    /// it and none is accepted. Otherwise the check fails (`build` 7, readiness claims nothing, so activation refuses
    /// 8). Final-hook-only units are never judged here.
    function _unitsCarried(Unit[] memory theirs, bool walks) internal view returns (bool) {
        uint256 built = walks ? _builtHooks() : 0;
        for (uint256 i; i < _units.length; ++i) {
            Unit storage u = _units[i];
            address hook = u.foldHook;
            if (hook == address(0) || (built >> i) & 1 != 0) continue;
            bool found;
            for (uint256 j; j < theirs.length && !found; ++j) {
                found = theirs[j].foldHook == hook && theirs[j].foldCodehash == u.foldCodehash
                    && theirs[j].purposeFilter == u.purposeFilter;
            }
            if (!found) return false;
        }
        return true;
    }

    /// The opt-out of Option A (docs INDEX-BUILD §3.6): bit i set says unit i's fold hook is built from history by this
    /// generation's own code, so a build that carries stores calls it on every effect it walks and the carried check
    /// does not require the live index to have called it (only when the generation walks: `_unitsCarried`). The
    /// generation reads this mask once, at construction (`RealmIndex.BUILT_HOOKS`), and its `_hookRuns` follows it,
    /// so the claim the check accepts and the calls the build makes are one value and cannot drift. Generation 1 builds
    /// no hook: 0. A bit for a hook the code does not really build from history is the author's lie in pinned code
    /// (the manifest hash covers this code), not a gap the kernel could close.
    function _builtHooks() internal view virtual returns (uint256) {
        return 0;
    }

    function builtHooks() external view returns (uint256) {
        return _builtHooks();
    }

    /// Unwritten, and writable in build mode by nobody but `gen` until a live write attaches it: its INITIAL_WRITER
    /// is 0 or `gen` (kernel reason 12 on an empty Realm asks the same).
    function _unwritten(address store, address gen) internal view returns (bool) {
        (address[] memory gens,,) = IPostingStore(store).writers();
        address iw = IPostingStore(store).initialWriter();
        return gens.length == 0 && (iw == address(0) || iw == gen);
    }

    /// `carried`: the store is not fresh for `gen` (fresh = names `gen` as INITIAL_WRITER and not attached);
    /// `spoiled`: it names `gen` as INITIAL_WRITER and is attached (so it is carried too, and no carried check passes).
    function _storeOf(address store, address gen)
        internal
        view
        returns (bool carried, bool spoiled)
    {
        bool mine = IPostingStore(store).initialWriter() == gen;
        bool attached = IPostingStore(store).attached();
        return (!mine || attached, mine && attached);
    }

    function _declaresFromOne(FamilyEntry[] memory list, bytes32 id, address store)
        internal
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

    /// A maintained family of the calling generation is covered from 1 through its progress frontier: COMPLETE when
    /// that is the ledger's admission count and the progress is not gapped, PARTIAL otherwise (a generation that is
    /// building, or behind). A generation that is not the live index vouches for a family in a carried store only
    /// through its carried check (docs INDEX-BUILD §3.5): when the check fails, such a family is PARTIAL from 1
    /// through 0 (it claims nothing, as `replayReadiness` does), whatever the frontier. A family in a fresh store
    /// was folded by the generation itself, so the check does not touch it. A generation that has folded live
    /// (`liveStarted`, from its own progress word in the same call that reads the frontier) answers exactly as before
    /// the check existed, with no further read: the live index folds every admission into its own stores, and a
    /// replaced generation reports its stale frontier as it always did. Only a generation that has never folded live
    /// takes the check, including one activated whose first live admission has not come yet (the check passes for
    /// the live index).
    function _coverage(bytes32 id) private view returns (Coverage, uint64, uint64, uint8) {
        uint256 pos = _familyAt[id];
        (uint8 phase,,,) = ILedgerHot(LEDGER).phase();
        if (pos == 0 || _families[pos - 1].fromAdmission == IndexProfiles.NOT_MAINTAINED) {
            return (Coverage.UNKNOWN, 0, 0, phase);
        }
        (uint64 through,, bool gapped, bool liveStarted) =
            IGenerationProgress(msg.sender).generationProgress();
        if (!liveStarted) {
            (bool carried,) = _storeOf(_families[pos - 1].store, msg.sender);
            if (carried && !_carriedCheck(msg.sender)) return (Coverage.PARTIAL, 1, 0, phase);
        }
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
        (count, live, last,) = IPostingStore(_postingOf(pos))
            .postingHead(_pk(TypeId.unwrap(typeId), kind, ordinal, value));
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
        IPostingStore ps = IPostingStore(_postingOf(pos));
        (uint64 count,,,) = ps.postingHead(key);
        if (count == 0 && kind == KIND_BY_RECORD) {
            (, uint64 firstAdmission,,,) = ILedgerHot(LEDGER).recordHeader(value);
            if (firstAdmission != 0 && from == 0 && n != 0) {
                entries = new uint64[](1);
                entries[0] = firstAdmission;
                return (c, entries, true);
            }
            return (c, entries, firstAdmission != 0);
        }
        entries = ps.postingSlice(key, from, n);
    }

    /// The posting store that holds the family at `pos` (its index in `_families` + 1). Generation 1 keeps every
    /// posting family in its one posting store; virtual so that a later generation with more posting stores (docs
    /// INDEX-BUILD step 3) routes each read to the family's own store.
    function _postingOf(uint256) internal view virtual returns (address) {
        return POSTING;
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
