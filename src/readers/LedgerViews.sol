// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Layout} from "../core/layout/Layout.sol";
import {Keys} from "../lib/Keys.sol";
import {LedgerRows} from "./LedgerReads.sol";
import {ILedgerHot} from "../interfaces/ILedgerHot.sol";
import {ILedgerViews} from "../interfaces/ILedgerViews.sol";
import {ITypeRegistry} from "../interfaces/ITypeRegistry.sol";
import {ActionKind} from "../interfaces/Actions.sol";
import {Effect} from "../interfaces/Index.sol";
import {BasisCommit, History, Status} from "../interfaces/Results.sol";
import {
    AcceptanceBasis,
    AdmissionRow,
    Head,
    PublicationView,
    RecordHeader
} from "../interfaces/Views.sol";
import {E_READSET_SHAPE, E_RESERVED} from "../interfaces/Errors.sol";

// Every narrowing cast below unpacks a field `Layout` declares at that width or narrows a registry reply word
// to the field width the registry ABI declares; every ignored tuple component is a field the caller does not
// need. The facets read the ledger row by row, so calls in loops are their purpose, bounded by the read limits.
// forge-lint: disable-start(unsafe-typecast)
// forge-lint: disable-start(unused-return)
// forge-lint: disable-start(calls-loop)

/// @title LedgerViews — the composite ledger facet (design §5.7)
/// @notice Immutable and stateless; every function takes `address ledger`, decodes rows through `LedgerRows`
///         (the codec shared with `LedgerReads`) and echoes the basis it observed. Statuses as in `LedgerReads`:
///         UNSET is never returned, UNKNOWN only when the facet cannot know (a registry that cannot answer, a
///         publication still being applied, or a binding row that does not name its coordinate), UNSUPPORTED on
///         a layout this facet was not generated for. Views whose return carries no `Status` (`heads`,
///         `headSnapshots`) revert `E_LAYOUT` instead.
contract LedgerViews is ILedgerViews {
    uint8 private constant T_FIRST_BIND = 1;
    uint8 private constant T_REBIND = 2;
    uint8 private constant T_MASK = 3;
    uint8 private constant T_RELEASE = 4;
    uint8 private constant T_RESTORE = 5;

    /// The facet ABI revision.
    function facetVersion() external pure returns (uint16) {
        return LedgerRows.FACET_VERSION;
    }

    // =============================================================================================
    // publication(): the evidence, the admission rows and the recomputed effectsHash
    // =============================================================================================

    /// @inheritdoc ILedgerViews
    /// @dev Rebuilds each leaf's `Effect/3` exactly as `LedgerApply` filled it (design §10.3, §10.6) from the
    ///      admission row, the record and position cells and the `prevAdmission` chain: `freshRecord` from
    ///      `cell.firstAdmission == admission`, `refCount` from the Type's registry row, the transition kind and
    ///      `oldTarget`/`oldTargetKind` from the previous row of the binding (its kind, `a` and `targetKind`),
    ///      the withdrawn coordinates from the target row and its publication's principal. `effectsHash` is
    ///      `keccak256(abi.encode(Effect[]))`, the hash the kernel emitted in `Published`. UNKNOWN (with
    ///      `effectsHash` 0, the evidence and the rows filled) when the registry cannot answer, when a leaf is
    ///      not yet applied, or when a bind-kind row carries no binding ordinal (its coordinate is then not in
    ///      state).
    function publication(address ledger, bytes32 principalId, uint64 nonce)
        external
        view
        returns (Status st, PublicationView memory v)
    {
        v.observed = LedgerRows.basis(ledger);
        if (!LedgerRows.layoutOk(ledger)) return (Status.UNSUPPORTED, v);
        v.ordinal = uint48(
            uint256(
                LedgerRows.load(ledger, Layout.publicationsPublicationAtSlot(principalId, nonce))
            )
        );
        if (v.ordinal == 0) return (Status.ABSENT_PROVEN, v);
        (, v.evidence) = LedgerRows.evidence(ledger, v.ordinal);
        v.admissionBlock = v.evidence.basisBlock;
        uint256 n = v.evidence.leafCount;
        uint256 first = v.evidence.firstAdmission;
        bytes32[] memory s = new bytes32[](2 * n);
        for (uint256 i; i < n; ++i) {
            uint256 slot = Layout.admissionsRowsSlot(first + i);
            s[2 * i] = bytes32(slot);
            s[2 * i + 1] = bytes32(slot + 1);
        }
        bytes32[] memory w = LedgerRows.loadAll(ledger, s);
        v.admissions = new AdmissionRow[](n);
        Effect[] memory fx = new Effect[](n);
        address registry = ILedgerHot(ledger).registry();
        st = Status.PRESENT;
        for (uint256 i; i < n; ++i) {
            AdmissionRow memory r = LedgerRows.admission(w[2 * i], w[2 * i + 1]);
            v.admissions[i] = r;
            if (st != Status.PRESENT) continue;
            Effect memory f = fx[i];
            f.kind = r.kind;
            f.leaf = r.leaf;
            f.admission = uint64(first + i);
            f.publication = v.ordinal;
            f.principalId = v.evidence.principalId;
            st = _effect(ledger, registry, r, f);
        }
        if (st == Status.PRESENT) v.effectsHash = keccak256(abi.encode(fx));
    }

    function _effect(address ledger, address registry, AdmissionRow memory r, Effect memory f)
        private
        view
        returns (Status)
    {
        uint8 kind = r.kind;
        if (kind == 0) return Status.UNKNOWN; // a leaf of a publication that is still being applied
        if (kind > ActionKind.RELEASE) return Status.UNSUPPORTED;
        if (kind == ActionKind.PUBLISH || kind == ActionKind.REUSE) {
            f.recordId = r.a;
            bytes32[] memory w =
                ILedgerHot(ledger).extsloadBatch(LedgerRows.run(Layout.recordsCellsSlot(r.a), 2));
            f.typeId = w[0];
            (uint48 firstAdmission,,,) = Layout.unpackRecordCellWord1(w[1]);
            f.freshRecord = firstAdmission == f.admission;
            (bool ok, bytes memory info) = LedgerRows.viewCall(
                registry, abi.encodeCall(ITypeRegistry.typeInfo, (f.typeId)), 17 * 32
            );
            if (!ok) return Status.UNKNOWN;
            f.refCount = uint8(uint256(_at(info, 1)));
        } else if (kind == ActionKind.CREATE) {
            f.subjectId = Keys.subject(f.principalId, r.a);
        } else if (kind == ActionKind.WITHDRAW) {
            uint256 target = uint256(r.a);
            bytes32[] memory w = ILedgerHot(ledger)
                .extsloadBatch(LedgerRows.run(Layout.admissionsRowsSlot(target), 2));
            (,, uint48 targetPublication,,,,,,,) = Layout.unpackAdmissionRowWord0(w[0]);
            f.recordId = w[1];
            bytes32[] memory s = new bytes32[](2);
            s[0] = bytes32(Layout.recordsCellsSlot(w[1]));
            s[1] = bytes32(Layout.publicationsEvidenceSlot(targetPublication) + 2);
            w = ILedgerHot(ledger).extsloadBatch(s);
            f.typeId = w[0];
            f.withdrawnAdmission = uint64(target);
            f.withdrawnPrincipal = w[1];
        } else {
            return _bindEffect(ledger, r, f);
        }
        return Status.PRESENT;
    }

    /// BIND / UNBIND / RELEASE. The previous state of the binding is the kind of the row at `prevAdmission`
    /// (BIND → BOUND, UNBIND → MASKED, RELEASE → RELEASED; row 0 is never written → UNSET).
    function _bindEffect(address ledger, AdmissionRow memory r, Effect memory f)
        private
        view
        returns (Status)
    {
        if (r.bindingOrdinal == 0) return Status.UNKNOWN;
        f.bindingOrdinal = r.bindingOrdinal;
        f.revision = r.expectedRevision + 1; // the CAS held: the head moved from expectedRevision by one
        f.prevAdmission = r.prevAdmission;
        bytes32[] memory s = new bytes32[](3);
        uint256 prev = Layout.admissionsRowsSlot(r.prevAdmission);
        s[0] = bytes32(Layout.bindingsBindingPositionSlot(r.bindingOrdinal));
        s[1] = bytes32(prev);
        s[2] = bytes32(prev + 1);
        bytes32[] memory w = ILedgerHot(ledger).extsloadBatch(s);
        f.position = w[0];
        (uint8 prevKind,,,,,,,,, uint8 prevTargetKind) = Layout.unpackAdmissionRowWord0(w[1]);
        bytes32[] memory p = ILedgerHot(ledger)
            .extsloadBatch(LedgerRows.run(Layout.bindingsPositionsSlot(f.position), 3));
        f.purpose = p[0];
        f.subject = p[1];
        f.role = p[2];
        if (r.kind == ActionKind.BIND) {
            f.targetKind = r.targetKind;
            f.target = r.a;
            f.transitionKind =
                prevKind == 0 ? T_FIRST_BIND : prevKind == ActionKind.BIND ? T_REBIND : T_RESTORE;
        } else {
            f.transitionKind = r.kind == ActionKind.UNBIND ? T_MASK : T_RELEASE;
        }
        if (prevKind == ActionKind.BIND) {
            f.oldTarget = w[2];
            f.oldTargetKind = prevTargetKind;
        }
        return Status.PRESENT;
    }

    // =============================================================================================
    // Batched rows
    // =============================================================================================

    /// @inheritdoc ILedgerViews
    /// @dev One status per id: PRESENT / ABSENT_PROVEN; every id LIMIT_EXCEEDED past `limits.maxReadIds`,
    ///      every id UNSUPPORTED on a foreign layout.
    function records(address ledger, bytes32[] calldata ids)
        external
        view
        returns (Status[] memory st, RecordHeader[] memory hs, BasisCommit memory b)
    {
        b = LedgerRows.basis(ledger);
        uint256 n = ids.length;
        st = new Status[](n);
        hs = new RecordHeader[](n);
        Status all = Status.UNSET; // never returned: the marker of "no blanket status"
        if (!LedgerRows.layoutOk(ledger)) {
            all = Status.UNSUPPORTED;
        } else {
            (uint16 maxReadIds,,) = LedgerRows.readBounds(ledger);
            if (n > maxReadIds) all = Status.LIMIT_EXCEEDED;
        }
        if (all != Status.UNSET) {
            for (uint256 i; i < n; ++i) {
                st[i] = all;
            }
            return (st, hs, b);
        }
        bytes32[] memory s = new bytes32[](3 * n);
        for (uint256 i; i < n; ++i) {
            uint256 cell = Layout.recordsCellsSlot(ids[i]);
            s[3 * i] = bytes32(cell);
            s[3 * i + 1] = bytes32(cell + 1);
            s[3 * i + 2] = bytes32(Layout.recordsBodyWordsSlot(ids[i], 0));
        }
        bytes32[] memory w = LedgerRows.loadAll(ledger, s);
        for (uint256 i; i < n; ++i) {
            if (w[3 * i] == 0) {
                st[i] = Status.ABSENT_PROVEN;
                continue;
            }
            RecordHeader memory h = hs[i];
            h.typeId = w[3 * i];
            (h.firstAdmission, h.length, h.occurrences, h.carrierKind) =
                Layout.unpackRecordCellWord1(w[3 * i + 1]);
            h.word0 = w[3 * i + 2];
            st[i] = Status.PRESENT;
        }
    }

    /// @inheritdoc ILedgerViews
    /// @dev Raw head rows (canonical targets; a reserved state is returned as stored). More than
    ///      `limits.maxReadIds` keys revert `E_RESERVED(31, length)`.
    function heads(address ledger, bytes32[] calldata keys)
        external
        view
        returns (Head[] memory, BasisCommit memory b)
    {
        LedgerRows.requireLayout(ledger);
        (uint16 maxReadIds,,) = LedgerRows.readBounds(ledger);
        if (keys.length > maxReadIds) revert E_RESERVED(LedgerRows.READ_IDS, keys.length);
        b = LedgerRows.basis(ledger);
        return (_heads(ledger, keys), b);
    }

    /// @inheritdoc ILedgerViews
    /// @dev Ordered first touch over `principals` at `position` (design §11): the first head that is BOUND
    ///      (PRESENT) or MASKED (MASKED) wins; UNSET and RELEASED fall through; ABSENT_PROVEN with
    ///      `selectedIndex == 255` when nothing wins; UNSUPPORTED when a reserved head state is met before a
    ///      winner. `all` holds every head in order. LIMIT_EXCEEDED past `limits.maxReadIds` (or 255).
    function headsAt(address ledger, bytes32[] calldata principals, bytes32 position)
        external
        view
        returns (
            Status st,
            Head memory selected,
            uint8 selectedIndex,
            Head[] memory all,
            BasisCommit memory b
        )
    {
        b = LedgerRows.basis(ledger);
        selectedIndex = LedgerRows.SELECTED_NONE;
        if (!LedgerRows.layoutOk(ledger)) {
            return (Status.UNSUPPORTED, selected, selectedIndex, all, b);
        }
        uint256 n = principals.length;
        (uint16 maxReadIds,,) = LedgerRows.readBounds(ledger);
        if (n > maxReadIds || n > LedgerRows.SELECTED_NONE) {
            return (Status.LIMIT_EXCEEDED, selected, selectedIndex, all, b);
        }
        bytes32[] memory keys = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            keys[i] = Keys.binding(principals[i], position);
        }
        all = _heads(ledger, keys);
        st = Status.ABSENT_PROVEN;
        for (uint256 i; i < n; ++i) {
            uint8 state = all[i].state;
            if (state == 1 || state == 2 || state > 3) {
                selected = all[i];
                selectedIndex = uint8(i);
                st = LedgerRows.headStatus(state);
                break;
            }
        }
    }

    /// @inheritdoc ILedgerViews
    /// @dev `headSnapshotHash(state, revision, admission, canonicalTarget) = keccak256(abi.encode(...))`
    ///      (`ILedgerCommitments.headSnapshotHash`) of `binding(principals[i], positions[j])` at index
    ///      `j * n + i`. Bounded by the read-set shape the ingress accepts: more than
    ///      `limits.maxReadSetPrincipals` principals revert `E_READSET_SHAPE(1)`, more than
    ///      `limits.maxReadSetPositions` positions `E_READSET_SHAPE(2)`.
    function headSnapshots(
        address ledger,
        bytes32[] calldata principals,
        bytes32[] calldata positions
    ) external view returns (bytes32[] memory out) {
        LedgerRows.requireLayout(ledger);
        (,,, uint16 maxPrincipals, uint8 maxPositions,,,,,,,,) =
            Layout.unpackRealmStorageWord13(LedgerRows.load(ledger, LedgerRows.REALM + 13));
        uint256 n = principals.length;
        uint256 m = positions.length;
        if (n > maxPrincipals) revert E_READSET_SHAPE(1);
        if (m > maxPositions) revert E_READSET_SHAPE(2);
        bytes32[] memory keys = new bytes32[](n * m);
        for (uint256 j; j < m; ++j) {
            for (uint256 i; i < n; ++i) {
                keys[j * n + i] = Keys.binding(principals[i], positions[j]);
            }
        }
        Head[] memory hs = _heads(ledger, keys);
        out = new bytes32[](hs.length);
        for (uint256 k; k < hs.length; ++k) {
            Head memory h = hs[k];
            out[k] = keccak256(abi.encode(h.state, h.revision, h.admission, h.target));
        }
    }

    function _heads(address ledger, bytes32[] memory keys) private view returns (Head[] memory hs) {
        uint256 n = keys.length;
        bytes32[] memory s = new bytes32[](2 * n);
        for (uint256 i; i < n; ++i) {
            uint256 slot = Layout.bindingsHeadsSlot(keys[i]);
            s[2 * i] = bytes32(slot);
            s[2 * i + 1] = bytes32(slot + 1);
        }
        bytes32[] memory w = LedgerRows.loadAll(ledger, s);
        hs = new Head[](n);
        for (uint256 i; i < n; ++i) {
            hs[i] = LedgerRows.head(w[2 * i], w[2 * i + 1]);
        }
    }

    // =============================================================================================
    // acceptanceBasis(), historyAt()
    // =============================================================================================

    /// @inheritdoc ILedgerViews
    /// @dev PUBLISH / REUSE: the record's Type, the admission row's `policyRow`, the Type's registry row
    ///      (`mandatory`, `ruleId`, the declared `validationGas`; the floor demanded was `ACCEPTOR_GAS_DEFAULT`
    ///      when it is 0) and policy row `policyRow` (`acceptor`, `codehash`, `activatedAt`). BIND: the
    ///      admission row's `roleRow` and that role row (`typeId` = its expected Type, `activatedAt`); PRESENT
    ///      with zeros when no role row applied. `revision` is the revision the admission ran under. Other kinds
    ///      are NOT_APPLICABLE; UNKNOWN when the registry cannot answer.
    function acceptanceBasis(address ledger, uint64 ordinal)
        external
        view
        returns (Status, AcceptanceBasis memory ab)
    {
        if (!LedgerRows.layoutOk(ledger)) return (Status.UNSUPPORTED, ab);
        bytes32[] memory w =
            ILedgerHot(ledger).extsloadBatch(LedgerRows.run(Layout.admissionsRowsSlot(ordinal), 2));
        AdmissionRow memory r = LedgerRows.admission(w[0], w[1]);
        Status st = LedgerRows.admissionStatus(r.kind);
        if (st != Status.PRESENT) return (st, ab);
        (,,, ab.revision,) = Layout.unpackEvidenceCellWord1(
            LedgerRows.load(ledger, Layout.publicationsEvidenceSlot(r.publication) + 1)
        );
        ab.policyRow = r.policyRow;
        ab.roleRow = r.roleRow;
        address registry = ILedgerHot(ledger).registry();
        bool ok;
        bytes memory ret;
        if (r.kind == ActionKind.PUBLISH || r.kind == ActionKind.REUSE) {
            ab.typeId = LedgerRows.load(ledger, Layout.recordsCellsSlot(r.a));
            (ok, ret) = LedgerRows.viewCall(
                registry, abi.encodeCall(ITypeRegistry.typeInfo, (ab.typeId)), 17 * 32
            );
            if (!ok) return (Status.UNKNOWN, ab);
            ab.validationGas = uint32(uint256(_at(ret, 6)));
            ab.mandatory = address(uint160(uint256(_at(ret, 8))));
            ab.ruleId = _at(ret, 9);
            (ok, ret) = LedgerRows.viewCall(
                registry, abi.encodeCall(ITypeRegistry.policy, (ab.typeId, r.policyRow)), 4 * 32
            );
            if (!ok) return (Status.UNKNOWN, ab);
            ab.policy = address(uint160(uint256(_at(ret, 0))));
            ab.policyCodehash = _at(ret, 1);
            ab.activatedAt = uint64(uint256(_at(ret, 2)));
            return (Status.PRESENT, ab);
        }
        if (r.kind != ActionKind.BIND) return (Status.NOT_APPLICABLE, ab);
        if (r.roleRow == 0) return (Status.PRESENT, ab);
        if (r.bindingOrdinal == 0) return (Status.UNKNOWN, ab);
        bytes32 position =
            LedgerRows.load(ledger, Layout.bindingsBindingPositionSlot(r.bindingOrdinal));
        bytes32[] memory p = ILedgerHot(ledger)
            .extsloadBatch(LedgerRows.run(Layout.bindingsPositionsSlot(position), 3));
        (ok, ret) = LedgerRows.viewCall(
            registry, abi.encodeCall(ITypeRegistry.roleRow, (p[0], p[2], r.roleRow)), 2 * 32
        );
        if (!ok) return (Status.UNKNOWN, ab);
        ab.typeId = _at(ret, 0);
        ab.activatedAt = uint64(uint256(_at(ret, 1)));
        return (Status.PRESENT, ab);
    }

    /// @inheritdoc ILedgerViews
    /// @dev Walks the `prevAdmission` chain from the live head: FOUND with the head as it stood after the
    ///      last transition at or before `asOf` (state from that row's kind, revision counted back from the
    ///      live revision, the target kind a masked or released head kept from its last BIND, canonical
    ///      target), NONE when the binding did not exist yet at `asOf` (or never), UNKNOWN when more than
    ///      `maxHops` admission rows would be read, on a foreign layout or on a reserved head state.
    function historyAt(address ledger, bytes32 bindingKey, uint64 asOf, uint16 maxHops)
        external
        view
        returns (History, Head memory h)
    {
        if (!LedgerRows.layoutOk(ledger)) return (History.UNKNOWN, h);
        bytes32[] memory w = ILedgerHot(ledger)
            .extsloadBatch(LedgerRows.run(Layout.bindingsHeadsSlot(bindingKey), 2));
        Head memory live = LedgerRows.head(w[0], w[1]);
        Head memory none;
        if (live.state == 0) return (History.NONE, h);
        if (live.state > 3) return (History.UNKNOWN, h);
        if (live.admission <= asOf) return (History.FOUND, live);
        uint256 hops = 0;
        uint64 revision = live.revision;
        uint64 cursor = live.prevAdmission;
        AdmissionRow memory r;
        while (true) {
            if (cursor == 0) return (History.NONE, h);
            if (hops == maxHops) return (History.UNKNOWN, h);
            ++hops;
            --revision;
            r = _row(ledger, cursor);
            if (cursor <= asOf) break;
            cursor = r.prevAdmission;
        }
        if (
            r.kind != ActionKind.BIND && r.kind != ActionKind.UNBIND && r.kind != ActionKind.RELEASE
        ) {
            return (History.UNKNOWN, none); // a chain row that is not a bind kind is not interpretable
        }
        h.state = r.kind == ActionKind.BIND ? 1 : r.kind == ActionKind.UNBIND ? 2 : 3;
        h.revision = revision;
        h.admission = cursor;
        h.prevAdmission = r.prevAdmission;
        h.bindingOrdinal = live.bindingOrdinal;
        if (h.state == 1) {
            h.targetKind = r.targetKind;
            h.target = r.a;
            return (History.FOUND, h);
        }
        // a masked or released head keeps the target kind of its last BIND (design §4.3)
        for (uint64 p = r.prevAdmission; p != 0; p = r.prevAdmission) {
            if (hops == maxHops) return (History.UNKNOWN, none);
            ++hops;
            r = _row(ledger, p);
            if (r.kind == ActionKind.BIND) {
                h.targetKind = r.targetKind;
                break;
            }
        }
        return (History.FOUND, h);
    }

    function _row(address ledger, uint256 ordinal) private view returns (AdmissionRow memory) {
        bytes32[] memory w =
            ILedgerHot(ledger).extsloadBatch(LedgerRows.run(Layout.admissionsRowsSlot(ordinal), 2));
        return LedgerRows.admission(w[0], w[1]);
    }

    /// Word `i` of an ABI reply.
    function _at(bytes memory ret, uint256 i) private pure returns (bytes32 x) {
        assembly ("memory-safe") {
            x := mload(add(add(ret, 32), mul(i, 32)))
        }
    }
}
// forge-lint: disable-end(calls-loop)
// forge-lint: disable-end(unused-return)
// forge-lint: disable-end(unsafe-typecast)
