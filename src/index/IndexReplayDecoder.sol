// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Layout} from "../core/layout/Layout.sol";
import {Keys} from "../lib/Keys.sol";
import {ActionKind} from "../interfaces/Actions.sol";
import {Effect} from "../interfaces/Index.sol";
import {ILedgerHot} from "../interfaces/ILedgerHot.sol";
import {ITypeRegistry, TypeInfo} from "../interfaces/ITypeRegistry.sol";
import {IIndexReplayDecoder} from "../interfaces/internal/IIndexReplayDecoder.sol";
import {E_REPLAY} from "../interfaces/Errors.sol";

/// @title IndexReplayDecoder — Effect/3 from admission rows, per layout (design §10.6)
/// @notice For publication n: the evidence cell gives the principal, the first admission and the leaf count;
///         each admission row (two words) gives the kind, the leaf, the position ordinal, the CAS value, the
///         previous admission and `a`; `oldTarget`/`oldTargetKind` come from the previous bind row,
///         `freshRecord` from `cell.firstAdmission == admission`, withdrawals from the target row and its
///         publication's principal, refs from the leading body words of the Type's `refCount`. The revision row
///         in force at the publication must carry this decoder's `LAYOUT_ID` (E_REPLAY(2)).
/// @dev Stateless, immutable; the same reconstruction `LedgerViews.publication()` proves against the
///      `Published` event's effectsHash, pinned here per layout so replay never depends on a replaceable facet.
contract IndexReplayDecoder is IIndexReplayDecoder {
    bytes32 public immutable LAYOUT_ID;
    uint8 private constant T_FIRST_BIND = 1;
    uint8 private constant T_REBIND = 2;
    uint8 private constant T_MASK = 3;
    uint8 private constant T_RELEASE = 4;
    uint8 private constant T_RESTORE = 5;
    uint256 private constant REVISION_LAYOUT_WORD = 17;

    constructor() {
        LAYOUT_ID = Layout.LAYOUT_ID;
    }

    /// @inheritdoc IIndexReplayDecoder
    function payload(address ledger, uint64 publication) external view returns (bytes memory) {
        (Effect[] memory effects, bytes32[] memory refs) = _decode(ledger, publication);
        return abi.encode(publication, effects, refs);
    }

    /// @inheritdoc IIndexReplayDecoder
    function decode(address ledger, uint64 publication)
        external
        view
        returns (Effect[] memory effects, bytes32[] memory refs)
    {
        return _decode(ledger, publication);
    }

    function _decode(address ledger, uint64 publication)
        private
        view
        returns (Effect[] memory effects, bytes32[] memory refs)
    {
        ILedgerHot hot = ILedgerHot(ledger);
        bytes32[] memory ev =
            hot.extsloadBatch(_run(Layout.publicationsEvidenceSlot(publication), 3));
        if (ev[0] == 0) revert E_REPLAY(7);
        (,,,, uint8 leafCount, uint48 first,) = Layout.unpackEvidenceCellWord0(ev[0]);
        (,,, uint32 revision,) = Layout.unpackEvidenceCellWord1(ev[1]);
        bytes32 principalId = ev[2];
        if (
            hot.extsload(bytes32(Layout.revisionsRowsSlot(revision) + REVISION_LAYOUT_WORD))
                != LAYOUT_ID
        ) {
            revert E_REPLAY(2);
        }
        bytes32[] memory slots = new bytes32[](2 * uint256(leafCount));
        for (uint256 i; i < leafCount; ++i) {
            uint256 slot = Layout.admissionsRowsSlot(uint256(first) + i); // rows are mapping entries, not contiguous
            slots[2 * i] = bytes32(slot);
            slots[2 * i + 1] = bytes32(slot + 1);
        }
        bytes32[] memory rows = hot.extsloadBatch(slots);
        effects = new Effect[](leafCount);
        address registry = hot.registry();
        uint256 refTotal;
        for (uint256 i; i < leafCount; ++i) {
            Effect memory f = effects[i];
            f.admission = uint64(first) + uint64(i);
            f.publication = publication;
            f.principalId = principalId;
            _effect(hot, registry, rows[2 * i], rows[2 * i + 1], f);
            refTotal += f.refCount;
        }
        refs = new bytes32[](refTotal);
        uint256 at;
        for (uint256 i; i < leafCount; ++i) {
            Effect memory f = effects[i];
            if (f.refCount == 0) continue;
            bytes32[] memory s = new bytes32[](f.refCount);
            for (uint256 j; j < f.refCount; ++j) {
                s[j] = bytes32(Layout.recordsBodyWordsSlot(f.recordId, j));
            }
            bytes32[] memory w = hot.extsloadBatch(s);
            for (uint256 j; j < f.refCount; ++j) {
                refs[at++] = w[j];
            }
        }
    }

    function _effect(ILedgerHot hot, address registry, bytes32 meta, bytes32 a, Effect memory f)
        private
        view
    {
        (
            uint8 kind,
            uint8 leaf,,
            uint48 bindingOrdinal,
            uint48 expectedRevision,
            uint48 prevAdmission,,,,
            uint8 targetKind
        ) = Layout.unpackAdmissionRowWord0(meta);
        if (kind == 0 || kind > ActionKind.RELEASE) revert E_REPLAY(8);
        f.kind = kind;
        f.leaf = leaf;
        if (kind == ActionKind.PUBLISH || kind == ActionKind.REUSE) {
            f.recordId = a;
            bytes32[] memory w = hot.extsloadBatch(_run(Layout.recordsCellsSlot(a), 2));
            f.typeId = w[0];
            (uint48 firstAdmission,,,) = Layout.unpackRecordCellWord1(w[1]);
            f.freshRecord = firstAdmission == f.admission;
            f.refCount = ITypeRegistry(registry).typeInfo(f.typeId).refCount;
        } else if (kind == ActionKind.CREATE) {
            f.subjectId = Keys.subject(f.principalId, a);
        } else if (kind == ActionKind.WITHDRAW) {
            uint256 target = uint256(a);
            bytes32[] memory w = hot.extsloadBatch(_run(Layout.admissionsRowsSlot(target), 2));
            (,, uint48 targetPublication,,,,,,,) = Layout.unpackAdmissionRowWord0(w[0]);
            f.recordId = w[1];
            bytes32[] memory s = new bytes32[](2);
            s[0] = bytes32(Layout.recordsCellsSlot(w[1]));
            s[1] = bytes32(Layout.publicationsEvidenceSlot(targetPublication) + 2);
            w = hot.extsloadBatch(s);
            f.typeId = w[0];
            f.withdrawnAdmission = uint64(target);
            f.withdrawnPrincipal = w[1];
        } else {
            if (bindingOrdinal == 0) revert E_REPLAY(9);
            f.bindingOrdinal = bindingOrdinal;
            f.revision = uint64(expectedRevision) + 1;
            f.prevAdmission = prevAdmission;
            bytes32[] memory s = new bytes32[](3);
            uint256 prev = Layout.admissionsRowsSlot(prevAdmission);
            s[0] = bytes32(Layout.bindingsBindingPositionSlot(bindingOrdinal));
            s[1] = bytes32(prev);
            s[2] = bytes32(prev + 1);
            bytes32[] memory w = hot.extsloadBatch(s);
            f.position = w[0];
            (uint8 prevKind,,,,,,,,, uint8 prevTargetKind) = Layout.unpackAdmissionRowWord0(w[1]);
            bytes32[] memory p =
                hot.extsloadBatch(_run(Layout.bindingsPositionsSlot(f.position), 3));
            f.purpose = p[0];
            f.subject = p[1];
            f.role = p[2];
            if (kind == ActionKind.BIND) {
                f.targetKind = targetKind;
                f.target = a;
                f.transitionKind = prevKind == 0
                    ? T_FIRST_BIND
                    : prevKind == ActionKind.BIND ? T_REBIND : T_RESTORE;
            } else {
                f.transitionKind = kind == ActionKind.UNBIND ? T_MASK : T_RELEASE;
            }
            if (prevKind == ActionKind.BIND) {
                f.oldTarget = w[2];
                f.oldTargetKind = prevTargetKind;
            }
        }
    }

    function _run(uint256 base, uint256 count) private pure returns (bytes32[] memory s) {
        s = new bytes32[](count);
        for (uint256 i; i < count; ++i) {
            s[i] = bytes32(base + i);
        }
    }
}
