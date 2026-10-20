// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {LedgerStorage} from "./storage/LedgerStorage.sol";
import {Keys} from "../lib/Keys.sol";
import {Action, ActionKind} from "../interfaces/Actions.sol";
import {ClosureConstants} from "../interfaces/Limits.sol";
import {Effect} from "../interfaces/Index.sol";
import {ILedgerApply} from "../interfaces/internal/ILedgerApply.sol";
import {
    E_CAS,
    E_COUNTER_SATURATED,
    E_DELEGATE_ONLY,
    E_KIND,
    E_NOT_LIVE,
    E_SALT,
    E_SUBJECT_EXISTS,
    E_TARGET_MISSING,
    E_WITHDRAW
} from "../interfaces/Errors.sol";

/// @title LedgerApply — the per-leaf writing delegate (design §3.1 row 2, §6.4)
/// @notice Runs only by DELEGATECALL in the kernel's context, under its transient lock, and writes only
///         `efs.ledger.v2.{records,subjects,admissions,bindings}` plus the record and binding counters.
///         Makes no external call. The kernel has already run the shape law, loaded `info`, checked the
///         body and run the acceptors (through `LedgerIngress.validateLeaf`) before calling it. Its codehash
///         is an immutable of the kernel implementation, re-verified on every publication.
contract LedgerApply is ILedgerApply, LedgerStorage {
    address private immutable SELF = address(this);

    uint8 private constant STATE_UNSET = 0;
    uint8 private constant STATE_BOUND = 1;
    uint8 private constant STATE_MASKED = 2;
    uint8 private constant STATE_RELEASED = 3;
    uint8 private constant TARGET_RECORD = 1;
    uint8 private constant TARGET_SUBJECT = 2;
    uint8 private constant T_FIRST_BIND = 1;
    uint8 private constant T_REBIND = 2;
    uint8 private constant T_MASK = 3;
    uint8 private constant T_RELEASE = 4;
    uint8 private constant T_RESTORE = 5;

    modifier delegateOnly() {
        if (address(this) == SELF) revert E_DELEGATE_ONLY();
        _;
    }

    /// @inheritdoc ILedgerApply
    function applyLeaf(
        uint8 leaf,
        uint64 admission,
        Action calldata action,
        bytes calldata body,
        uint8 refCount,
        bytes32 principalId,
        uint8 principalKind,
        uint16 policyRow,
        uint16 roleRow
    )
        external
        delegateOnly
        returns (Effect memory effect, uint256 refCountOut, bytes32[8] memory refs)
    {
        effect.kind = action.kind;
        effect.leaf = leaf;
        effect.admission = admission;
        effect.publication = uint64(_counters().publications) + 1;
        effect.principalId = principalId;

        AdmissionRow memory row;
        row.kind = action.kind;
        row.leaf = leaf;
        row.publication = uint48(effect.publication);
        row.policyRow = policyRow;
        row.roleRow = roleRow;

        uint8 kind = action.kind;
        if (kind == ActionKind.PUBLISH || kind == ActionKind.REUSE) {
            row.a = _applyRecord(kind, action, body, refCount, admission, effect, refs);
            refCountOut = refCount;
        } else if (kind == ActionKind.BIND) {
            row.a = action.target;
            (row.prevAdmission, row.targetKind) = _applyBind(action, principalId, admission, effect);
            row.bindingOrdinal = uint48(effect.bindingOrdinal);
            row.expectedRevision = uint48(action.expectedRevision);
        } else if (kind == ActionKind.UNBIND || kind == ActionKind.RELEASE) {
            row.prevAdmission = _applyMaskOrRelease(kind, action, principalId, admission, effect);
            row.bindingOrdinal = uint48(effect.bindingOrdinal); // names the position through bindingPosition[ordinal]
            row.expectedRevision = uint48(action.expectedRevision);
        } else if (kind == ActionKind.CREATE) {
            row.a = action.salt;
            _applyCreate(action, principalId, principalKind, admission, effect);
        } else if (kind == ActionKind.WITHDRAW) {
            row.a = action.target;
            _applyWithdraw(action, principalId, admission, effect);
        } else {
            revert E_KIND(leaf, kind);
        }
        _admissions().rows[admission] = row;
    }

    // ---- PUBLISH / REUSE --------------------------------------------------------------------------------------

    function _applyRecord(
        uint8 kind,
        Action calldata action,
        bytes calldata body,
        uint8 refCount,
        uint64 admission,
        Effect memory effect,
        bytes32[8] memory refs
    ) private returns (bytes32 recordId) {
        recordId = kind == ActionKind.PUBLISH
            ? Keys.recordFromHash(action.typeId, action.bodyHashOrRecordId)
            : action.bodyHashOrRecordId;
        RecordCell storage cell = _records().cells[recordId];
        effect.typeId = action.typeId;
        effect.recordId = recordId;
        effect.refCount = refCount;
        if (cell.typeId == 0) {
            // PUBLISH of a fresh record: the ingress guaranteed keccak(body) == bodyHash and the length bound.
            cell.typeId = action.typeId;
            cell.firstAdmission = uint48(admission);
            cell.length = uint32(body.length);
            cell.occurrences = 1;
            _storeBody(recordId, body);
            CountersStorage storage c = _counters();
            uint48 n = c.records + 1;
            if (n > ClosureConstants.SATURATION) revert E_COUNTER_SATURATED(1);
            c.records = n;
            effect.freshRecord = true;
            _leadingWords(body, refCount, refs);
        } else {
            uint48 occ = cell.occurrences + 1;
            if (occ > ClosureConstants.SATURATION) revert E_COUNTER_SATURATED(1);
            cell.occurrences = occ;
            if (kind == ActionKind.PUBLISH) _leadingWords(body, refCount, refs);
            else _leadingStoredWords(recordId, refCount, refs);
        }
    }

    function _storeBody(bytes32 recordId, bytes calldata body) private {
        mapping(uint256 => bytes32) storage words = _records().bodyWords[recordId];
        uint256 full = body.length / 32;
        uint256 i;
        for (; i < full; ++i) {
            words[i] = bytes32(body[i * 32:i * 32 + 32]);
        }
        uint256 tail = body.length - full * 32;
        if (tail != 0) {
            bytes32 last;
            assembly ("memory-safe") {
                last := calldataload(add(body.offset, mul(i, 32)))
            }
            // mask the bytes beyond the length so the tail word is canonical
            last &= bytes32(~uint256(0) << ((32 - tail) * 8));
            words[i] = last;
        }
    }

    function _leadingWords(bytes calldata body, uint8 count, bytes32[8] memory refs) private pure {
        for (uint256 i; i < count; ++i) {
            refs[i] = bytes32(body[i * 32:i * 32 + 32]);
        }
    }

    function _leadingStoredWords(bytes32 recordId, uint8 count, bytes32[8] memory refs)
        private
        view
    {
        mapping(uint256 => bytes32) storage words = _records().bodyWords[recordId];
        for (uint256 i; i < count; ++i) {
            refs[i] = words[i];
        }
    }

    // ---- BIND ----------------------------------------------------------------------------------------------------

    function _applyBind(
        Action calldata action,
        bytes32 principalId,
        uint64 admission,
        Effect memory effect
    ) private returns (uint48 prevAdmission, uint8 targetKind) {
        bytes32 position = Keys.position(action.purpose, action.subject, action.role);
        bytes32 key = Keys.binding(principalId, position);
        BindingsStorage storage b = _bindings();
        HeadRow storage head = b.heads[key];
        uint8 state = head.state;
        if (state > STATE_RELEASED) revert E_NOT_LIVE(effect.leaf, key, state);
        if (head.revision != action.expectedRevision) {
            revert E_CAS(key, action.expectedRevision, head.revision);
        }

        bytes32 target = action.target;
        if (_records().cells[target].typeId != 0) targetKind = TARGET_RECORD;
        else if (_subjects().cells[target].createAdmission != 0) targetKind = TARGET_SUBJECT;
        else revert E_TARGET_MISSING(effect.leaf, target);

        prevAdmission = head.admission;
        uint48 ordinal = head.bindingOrdinal;
        if (state == STATE_UNSET) {
            CountersStorage storage c = _counters();
            ordinal = c.bindings + 1;
            if (ordinal > ClosureConstants.SATURATION) revert E_COUNTER_SATURATED(2);
            c.bindings = ordinal;
            b.bindingPosition[ordinal] = position;
            PositionCell storage p = b.positions[position];
            if (p.purpose == 0) {
                p.purpose = action.purpose;
                p.subject = action.subject;
                if (action.role != 0) p.role = action.role;
            }
            head.bindingOrdinal = ordinal;
            effect.transitionKind = T_FIRST_BIND;
        } else if (state == STATE_BOUND) {
            effect.oldTarget = head.target;
            effect.oldTargetKind = head.targetKind;
            effect.transitionKind = T_REBIND;
        } else {
            effect.transitionKind = T_RESTORE;
        }
        uint48 newRevision = head.revision + 1;
        head.state = STATE_BOUND;
        head.revision = newRevision;
        head.admission = uint48(admission);
        head.targetKind = targetKind;
        head.prevAdmission = prevAdmission;
        if (head.target != target) head.target = target;

        effect.bindingOrdinal = ordinal;
        effect.position = position;
        effect.purpose = action.purpose;
        effect.subject = action.subject;
        effect.role = action.role;
        effect.revision = newRevision;
        effect.prevAdmission = prevAdmission;
        effect.targetKind = targetKind;
        effect.target = target;
    }

    // ---- UNBIND (mask) / RELEASE ---------------------------------------------------------------------------------

    function _applyMaskOrRelease(
        uint8 kind,
        Action calldata action,
        bytes32 principalId,
        uint64 admission,
        Effect memory effect
    ) private returns (uint48 prevAdmission) {
        bytes32 position = Keys.position(action.purpose, action.subject, action.role);
        bytes32 key = Keys.binding(principalId, position);
        HeadRow storage head = _bindings().heads[key];
        uint8 state = head.state;
        bool live = state == STATE_BOUND || (kind == ActionKind.RELEASE && state == STATE_MASKED);
        if (!live) revert E_NOT_LIVE(effect.leaf, key, state);
        if (head.revision != action.expectedRevision) {
            revert E_CAS(key, action.expectedRevision, head.revision);
        }

        prevAdmission = head.admission;
        if (state == STATE_BOUND) {
            effect.oldTarget = head.target; // the canonical target before the transition
            effect.oldTargetKind = head.targetKind;
        }
        uint48 newRevision = head.revision + 1;
        head.state = kind == ActionKind.UNBIND ? STATE_MASKED : STATE_RELEASED;
        head.revision = newRevision;
        head.admission = uint48(admission);
        head.prevAdmission = prevAdmission; // the target word is KEPT (design §4.3)

        effect.bindingOrdinal = head.bindingOrdinal;
        effect.position = position;
        effect.purpose = action.purpose;
        effect.subject = action.subject;
        effect.role = action.role;
        effect.revision = newRevision;
        effect.prevAdmission = prevAdmission;
        effect.transitionKind = kind == ActionKind.UNBIND ? T_MASK : T_RELEASE;
    }

    // ---- CREATE --------------------------------------------------------------------------------------------------

    function _applyCreate(
        Action calldata action,
        bytes32 principalId,
        uint8 principalKind,
        uint64 admission,
        Effect memory effect
    ) private {
        if (action.salt == 0) revert E_SALT(effect.leaf);
        bytes32 subjectId = Keys.subject(principalId, action.salt);
        SubjectCell storage s = _subjects().cells[subjectId];
        if (s.createAdmission != 0) revert E_SUBJECT_EXISTS(effect.leaf, subjectId);
        s.createAdmission = uint48(admission);
        s.creatorKind = principalKind;
        effect.subjectId = subjectId;
    }

    // ---- WITHDRAW ------------------------------------------------------------------------------------------------

    function _applyWithdraw(
        Action calldata action,
        bytes32 principalId,
        uint64 admission,
        Effect memory effect
    ) private {
        uint256 target = uint256(action.target);
        if (target == 0 || target >= admission) revert E_WITHDRAW(effect.leaf, 0);
        AdmissionRow storage row = _admissions().rows[target];
        if (row.kind != ActionKind.PUBLISH && row.kind != ActionKind.REUSE) {
            revert E_WITHDRAW(effect.leaf, 1);
        }
        if (row.withdrawn != 0) revert E_WITHDRAW(effect.leaf, 2);
        bytes32 retained = _publications().evidence[row.publication].principalId;
        if (retained != principalId) revert E_WITHDRAW(effect.leaf, 3);
        row.withdrawn = 1;
        RecordCell storage cell = _records().cells[row.a];
        cell.occurrences = cell.occurrences - 1; // checked subtraction; bytes are never erased
        effect.recordId = row.a;
        effect.typeId = cell.typeId;
        effect.withdrawnAdmission = uint64(target);
        effect.withdrawnPrincipal = retained;
    }
}
