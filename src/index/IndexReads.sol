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
        WorkModel memory work
    ) {
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

    /// The `IRealmIndex.replayReadiness()` tuple of the calling generation.
    function replayReadiness() external view returns (Readiness memory r) {
        (uint64 lastProcessed, uint64 lastPublication, bool gapped) = _progress();
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
        r.ready = phase == Phase.IDLE && lastProcessed == admissions
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
