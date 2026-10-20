// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {LedgerStorage} from "./storage/LedgerStorage.sol";
import {Layout} from "./layout/Layout.sol";
import {Keys} from "../lib/Keys.sol";
import {CodePins} from "../lib/CodePins.sol";
import {
    Action,
    ActionKind,
    Capability,
    FamilyId,
    Intent,
    Native,
    PostingKey,
    ReadSet,
    TypeId
} from "../interfaces/Actions.sol";
import {Phase} from "../interfaces/Results.sol";
import {ClosureConstants, Limits} from "../interfaces/Limits.sol";
import {ILedgerHot} from "../interfaces/ILedgerHot.sol";
import {ILedgerCommitments} from "../interfaces/ILedgerCommitments.sol";
import {ITypeRegistry, TypeInfo} from "../interfaces/ITypeRegistry.sol";
import {IAcceptor, AcceptContext, RefHeader, EXHAUSTED} from "../interfaces/IAcceptor.sol";
import {IRealmIndex} from "../interfaces/IRealmIndex.sol";
import {IIndexReads} from "../interfaces/IIndexReads.sol";
import {WorkModel} from "../interfaces/Index.sol";
import {ILedgerIngress, LeafVerdict, Prepared} from "../interfaces/internal/ILedgerIngress.sol";
import {
    E_ACCEPTOR_CODE,
    E_BODY,
    E_MISSING_RECORD,
    E_TYPE_MISMATCH,
    E_INDEX_FINAL,
    E_ACCEPTOR_GAS,
    E_ACCEPTANCE_PROFILE,
    E_DELEGATE_ONLY,
    E_EXECUTION_SET,
    E_EXPIRED,
    E_GAS,
    E_INDEX_ACK,
    E_INDEX_CALL,
    E_INDEX_GAS,
    E_INDEX_RETURNDATA,
    E_INTENT,
    E_POLICY_REJECTED,
    E_READSET_SHAPE,
    E_READSET_STALE,
    E_REF,
    E_REJECTED,
    E_RESERVED,
    E_SIGNATURE,
    E_UNKNOWN_TYPE,
    E_UNSUPPORTED_GUARD,
    E_VERIFIER_PROFILE
} from "../interfaces/Errors.sol";

/// @title LedgerIngress — the zero-write preparation, validation and dispatch delegate (design §3.1 row 3)
/// @notice Runs by DELEGATECALL in the kernel's context for `prepare`, `validateLeaf`, `dispatchIndex` and
///         `checkActivation` (every one reverts E_DELEGATE_ONLY when called directly), and serves the
///         `ILedgerCommitments` views on its own address. It never writes ledger storage (invariant I3, proven
///         by the opcode lint and the state-diff test); it reads it through `Layout` so the same code serves
///         the in-context path (sload) and the commitment views (`extsload` on a named ledger).
contract LedgerIngress is ILedgerIngress, ILedgerCommitments, LedgerStorage {
    address private immutable SELF = address(this);
    /// The pinned witness store of the STATE retention profile; 0 until the S2b build.
    address public immutable SIGNATURE_STORE;

    uint8 private constant FLAG_GUARDED = 1 << 1;
    uint8 private constant FLAG_EXECUTION_BOUND = 1 << 3;
    uint8 private constant FLAG_ACCEPTANCE_BOUND = 1 << 4;
    uint256 private constant RETURNDATA_BOUND = 4_096;
    uint256 private constant SECP256K1N_HALF =
        0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;
    bytes32 private constant ADMIN_SLOT =
        0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    bytes32 private constant INTENT_TYPEHASH = keccak256(
        "Intent(bytes32 realmId,bytes32 realmOrigin,bytes32 executionSet,bytes32 principalId,address author,uint64 nonce,uint64 deadline,bytes32 acceptanceProfile,bytes32 indexObligations,bytes32 readSetHash,uint16 verifierProfile,bytes32 authorityId,uint64 authEpoch)"
    );
    bytes32 private constant INTENT_WITH_ACTIONS_TYPEHASH = keccak256(
        "IntentWithActions(Intent intent,bytes32 actionsHash)Intent(bytes32 realmId,bytes32 realmOrigin,bytes32 executionSet,bytes32 principalId,address author,uint64 nonce,uint64 deadline,bytes32 acceptanceProfile,bytes32 indexObligations,bytes32 readSetHash,uint16 verifierProfile,bytes32 authorityId,uint64 authEpoch)"
    );

    constructor(address signatureStore_) {
        SIGNATURE_STORE = signatureStore_;
    }

    modifier delegateOnly() {
        if (address(this) == SELF) revert E_DELEGATE_ONLY();
        _;
    }

    function signatureStore() external view returns (address) {
        return SIGNATURE_STORE;
    }

    // =============================================================================================
    // Storage access that serves both the delegate path (sload) and the views (extsload on `ledger`)
    // =============================================================================================

    function _load(address ledger, uint256 slot) private view returns (bytes32 w) {
        if (ledger == address(this)) {
            assembly ("memory-safe") {
                w := sload(slot)
            }
        } else {
            w = ILedgerHot(ledger).extsload(bytes32(slot));
        }
    }

    function _realmWord(address ledger, uint256 offset) private view returns (bytes32) {
        return _load(ledger, uint256(Layout.LEDGER_REALM_ROOT) + offset);
    }

    function _registryOf(address ledger) private view returns (address) {
        return Layout.unpackRealmStorageWord5(_realmWord(ledger, 5));
    }

    function _indexOf(address ledger) private view returns (address index) {
        (index,) = Layout.unpackRealmStorageWord6(_realmWord(ledger, 6));
    }

    function _floorConstants(address ledger)
        private
        view
        returns (uint32 floorFresh, uint32 floorRewrite, uint32 kernelTail)
    {
        (, floorFresh, floorRewrite, kernelTail) =
            Layout.unpackRealmStorageWord14(_realmWord(ledger, 14));
    }

    function _recordExists(address ledger, bytes32 id) private view returns (bool) {
        return _load(ledger, Layout.recordsCellsSlot(id)) != 0;
    }

    function _headState(address ledger, bytes32 key)
        private
        view
        returns (uint8 state, uint48 revision, uint48 admission, bytes32 target)
    {
        uint256 s = Layout.bindingsHeadsSlot(key);
        (state, revision, admission,,,,) = Layout.unpackHeadRowWord0(_load(ledger, s));
        if (state == 1) target = _load(ledger, s + 1);
    }

    // =============================================================================================
    // prepare (design §6.2)
    // =============================================================================================

    /// @inheritdoc ILedgerIngress
    function prepareNative(
        Action[] calldata actions,
        bytes[] calldata,
        Native calldata ctx,
        bytes calldata guard
    ) external delegateOnly returns (Prepared memory p) {
        RealmStorage storage $ = _realm();
        p.actionsHash = keccak256(abi.encode(actions));
        p.leafCount = uint8(actions.length);
        bytes32 guardHash = keccak256(guard);
        p.proofKind = 1;
        p.author = msg.sender;
        (p.principalId, p.principalKind) = _nativePrincipal(msg.sender, $.realmOrigin);
        p.nonce = ctx.nonce;
        p.deadline = ctx.deadline;
        p.intentDigest = nativeIntentDigest($.realmId, p.principalId, ctx, p.actionsHash, guardHash);
        if (ctx.deadline != 0 && block.timestamp > ctx.deadline) {
            revert E_EXPIRED(ctx.deadline, uint64(block.timestamp));
        }
        if (ctx.expectedExecutionSet != 0) {
            if (ctx.expectedExecutionSet != $.executionSet) {
                revert E_EXECUTION_SET(ctx.expectedExecutionSet, $.executionSet);
            }
            p.flags |= FLAG_EXECUTION_BOUND;
        }
        bool bound = ctx.expectedAcceptanceProfile != 0;
        (bytes32 profile, uint32 prefixFloor, uint32 finalReserve, uint32 fresh, uint32 rw) =
            _foldAndQuote(address(this), actions, p.principalId, bound);
        if (bound) {
            if (ctx.expectedAcceptanceProfile != profile) {
                revert E_ACCEPTANCE_PROFILE(ctx.expectedAcceptanceProfile, profile);
            }
            p.flags |= FLAG_ACCEPTANCE_BOUND;
        }
        (p.prefixFloor, p.finalReserve, p.freshSlots, p.rewrites) =
        (prefixFloor, finalReserve, fresh, rw);
        if (guard.length != 0) {
            p.readSetHash = _checkGuard($, guard);
            p.flags |= FLAG_GUARDED;
        }
    }

    /// @inheritdoc ILedgerIngress
    function prepareSigned(
        Intent calldata it,
        Action[] calldata actions,
        bytes[] calldata,
        bytes calldata guard,
        bytes calldata witness
    ) external delegateOnly returns (Prepared memory p) {
        RealmStorage storage $ = _realm();
        p.actionsHash = keccak256(abi.encode(actions));
        p.leafCount = uint8(actions.length);
        p.verifierProfile = it.verifierProfile;
        p.principalId = it.principalId;
        p.nonce = it.nonce;
        p.deadline = it.deadline;
        p.intentDigest = intentDigest(it, p.actionsHash);
        _checkCapabilityForProfile($.capabilities, it.verifierProfile);
        if (it.deadline == 0 || block.timestamp > it.deadline) {
            revert E_EXPIRED(it.deadline, uint64(block.timestamp));
        }
        if (it.realmId != $.realmId || it.realmOrigin != $.realmOrigin) revert E_INTENT(1);
        if (it.executionSet != $.executionSet) revert E_INTENT(2);
        (bytes32 profile, uint32 prefixFloor, uint32 finalReserve, uint32 fresh, uint32 rw) =
            _foldAndQuote(address(this), actions, it.principalId, it.verifierProfile != 0);
        if (it.acceptanceProfile != profile) revert E_INTENT(3);
        if (it.indexObligations != $.indexObligations) revert E_INTENT(4);
        if (it.readSetHash != keccak256(guard)) revert E_INTENT(5);
        if (
            (it.authorityId != 0 || it.authEpoch != 0)
                && $.capabilities & Capability.KEL_AUTHORITY == 0
        ) {
            revert E_RESERVED(11, uint256(it.authorityId) | it.authEpoch);
        }
        (p.prefixFloor, p.finalReserve, p.freshSlots, p.rewrites) =
        (prefixFloor, finalReserve, fresh, rw);
        p.acceptanceProfile = it.acceptanceProfile;
        p.indexObligations = it.indexObligations;
        if (guard.length != 0) {
            p.readSetHash = _checkGuard($, guard);
            p.flags |= FLAG_GUARDED;
        }
        _verifyWitness($, it, p, witness);
    }

    function _nativePrincipal(address author, bytes32 origin)
        private
        view
        returns (bytes32 principalId, uint8 principalKind)
    {
        principalId = Keys.principalFor(author, origin);
        principalKind = principalId == Keys.principal(author) ? 1 : 2;
    }

    function _checkCapabilityForProfile(uint16 capabilities, uint16 profile) private pure {
        uint16 bit;
        if (profile == 1) bit = Capability.SIGNED_SECP256K1;
        else if (profile == 2) bit = Capability.ERC1271;
        else revert E_VERIFIER_PROFILE(profile);
        if (capabilities & bit == 0) revert E_VERIFIER_PROFILE(profile);
    }

    /// Decodes and checks a non-empty guard; returns its hash (= the canonical read-set hash).
    function _checkGuard(RealmStorage storage $, bytes calldata guard)
        private
        view
        returns (bytes32)
    {
        if ($.capabilities & Capability.NATIVE_GUARD == 0) revert E_UNSUPPORTED_GUARD();
        ReadSet memory rs = abi.decode(guard, (ReadSet));
        uint256 n = rs.principals.length;
        uint256 m = rs.positions.length;
        if (n == 0 || n > $.limits.maxReadSetPrincipals) revert E_READSET_SHAPE(1);
        if (m == 0 || m > $.limits.maxReadSetPositions) revert E_READSET_SHAPE(2);
        if (rs.expectedHeads.length != n * m) revert E_READSET_SHAPE(3);
        if (keccak256(abi.encode(rs)) != keccak256(guard)) revert E_READSET_SHAPE(4); // canonical encoding only
        for (uint256 j; j < m; ++j) {
            for (uint256 i; i < n; ++i) {
                bytes32 key = Keys.binding(rs.principals[i], rs.positions[j]);
                (uint8 state, uint48 revision, uint48 admission, bytes32 target) =
                    _headState(address(this), key);
                if (
                    headSnapshotHash(state, revision, admission, target)
                        != rs.expectedHeads[j * n + i]
                ) {
                    revert E_READSET_STALE(rs.positions[j], rs.principals[i]);
                }
            }
        }
        return keccak256(guard);
    }

    function _verifyWitness(
        RealmStorage storage $,
        Intent calldata it,
        Prepared memory p,
        bytes calldata witness
    ) private view {
        bytes32 digest = signingDigest($.domainSeparator, it, p.actionsHash);
        if (it.verifierProfile == 1) {
            if (witness.length != 65) revert E_SIGNATURE(1);
            bytes32 r = bytes32(witness[0:32]);
            bytes32 s = bytes32(witness[32:64]);
            uint8 v = uint8(witness[64]);
            if (uint256(s) > SECP256K1N_HALF) revert E_SIGNATURE(2);
            if (v != 27 && v != 28) revert E_SIGNATURE(2);
            address recovered = ecrecover(digest, v, r, s);
            if (recovered == address(0) || Keys.principal(recovered) != it.principalId) {
                revert E_SIGNATURE(3);
            }
            if (it.author != address(0) && it.author != recovered) revert E_SIGNATURE(6);
            p.proofKind = 2;
            p.author = recovered;
            p.principalKind = 1;
            p.witness0 = r;
            p.witness1 = s;
            p.v = v;
        } else {
            // ERC-1271 (profile 2): the pre-call binding checks of design §6.2, then the S2b wallet call.
            if (it.author.code.length == 0 || CodePins.isDesignator(it.author)) {
                revert E_SIGNATURE(5);
            }
            if (Keys.contractPrincipal($.realmOrigin, it.author) != it.principalId) {
                revert E_SIGNATURE(6);
            }
            if (witness.length > $.limits.maxWitness) revert E_SIGNATURE(1);
            revert E_VERIFIER_PROFILE(2); // S2b: the bounded isValidSignature STATICCALL with the 300k floor
        }
    }

    // =============================================================================================
    // Acceptance-profile fold and index-floor quote (design §6.2, §10.4)
    // =============================================================================================

    struct Quote {
        bytes32 h;
        uint256 fresh10;
        uint256 rw10;
        uint256 compute;
        uint256 binds;
        uint32 floorFresh;
        uint32 floorRewrite;
    }

    /// One pass over the actions: the acceptance profile (when wanted) and the index floor quote.
    function _foldAndQuote(
        address ledger,
        Action[] calldata actions,
        bytes32 principalId,
        bool wantProfile
    )
        private
        view
        returns (
            bytes32 profile,
            uint32 prefixFloor,
            uint32 finalReserve,
            uint32 freshSlots,
            uint32 rewrites
        )
    {
        ITypeRegistry registry = ITypeRegistry(_registryOf(ledger));
        WorkModel memory wm = IIndexReads(_indexOf(ledger)).workModel();
        Quote memory q;
        (q.floorFresh, q.floorRewrite,) = _floorConstants(ledger);
        if (wantProfile) q.h = keccak256(abi.encode(Keys.DOM_PROFILE, _realmWord(ledger, 7)));
        // slot counts are stored x10 in the work model
        q.fresh10 = wm.freshPerPublication;
        q.rw10 = wm.rwPerPublication;
        q.compute = wm.computeBase + uint256(wm.computePerAction) * actions.length;
        for (uint256 i; i < actions.length; ++i) {
            _foldOne(ledger, registry, wm, q, actions[i], uint8(i), principalId, wantProfile);
        }
        profile = q.h;
        freshSlots = uint32((q.fresh10 + 9) / 10);
        rewrites = uint32((q.rw10 + 9) / 10);
        prefixFloor = uint32(
            q.compute + uint256(freshSlots) * q.floorFresh + uint256(rewrites) * q.floorRewrite
        );
        finalReserve = uint32(wm.finalComputeBase + uint256(wm.finalComputePerBind) * q.binds);
    }

    function _foldOne(
        address ledger,
        ITypeRegistry registry,
        WorkModel memory wm,
        Quote memory q,
        Action calldata a,
        uint8 leaf,
        bytes32 principalId,
        bool wantProfile
    ) private view {
        uint8 kind = a.kind;
        if (kind == ActionKind.PUBLISH || kind == ActionKind.REUSE) {
            TypeInfo memory info = registry.typeInfo(a.typeId);
            if (info.mandatory == address(0)) revert E_UNKNOWN_TYPE(leaf, a.typeId);
            if (wantProfile) {
                q.h = keccak256(
                    abi.encode(
                        q.h,
                        a.typeId,
                        info.mandatory,
                        info.ruleId,
                        info.policyRow,
                        info.policyCodehash,
                        _effectiveGas(info.validationGas)
                    )
                );
            }
            bytes32 rid = kind == ActionKind.PUBLISH
                ? Keys.recordFromHash(a.typeId, a.bodyHashOrRecordId)
                : a.bodyHashOrRecordId;
            if (!_recordExists(ledger, rid)) q.fresh10 += wm.freshPerPublishFresh;
            q.rw10 += wm.rwPerPublish;
            q.fresh10 += uint256(wm.freshPerRef) * info.refCount;
        } else if (kind == ActionKind.BIND) {
            ++q.binds;
            (bytes32 expectedType, uint16 row) = registry.roleExpectation(a.purpose, a.role);
            if (wantProfile) {
                q.h = keccak256(abi.encode(q.h, a.purpose, a.role, row, expectedType));
            }
            (uint8 state,,,) = _headState(
                ledger, Keys.binding(principalId, Keys.position(a.purpose, a.subject, a.role))
            );
            if (state == 0) q.fresh10 += wm.freshPerBindFresh;
            q.rw10 += wm.rwPerBind;
            q.compute += wm.computePerHookEffect;
        } else if (kind == ActionKind.UNBIND || kind == ActionKind.RELEASE) {
            ++q.binds;
            q.rw10 += wm.rwPerBind;
            q.compute += wm.computePerHookEffect;
        }
    }

    function _effectiveGas(uint32 declared) private pure returns (uint32) {
        return declared == 0 ? ClosureConstants.ACCEPTOR_GAS_DEFAULT : declared;
    }

    // =============================================================================================
    // validateLeaf (design §6.4)
    // =============================================================================================

    /// @inheritdoc ILedgerIngress
    function validateLeaf(
        uint8 leaf,
        Action calldata a,
        bytes calldata body,
        uint64 admission,
        bytes32 principalId
    ) external view delegateOnly returns (LeafVerdict memory v) {
        RealmStorage storage $ = _realm();
        TypeInfo memory info = ITypeRegistry($.registry).typeInfo(a.typeId);
        if (info.mandatory == address(0)) revert E_UNKNOWN_TYPE(leaf, a.typeId);
        bytes memory bodyMem;
        if (a.kind == ActionKind.PUBLISH) {
            if (body.length > $.limits.maxBody) revert E_BODY(leaf, 1);
            if (keccak256(body) != a.bodyHashOrRecordId) revert E_BODY(leaf, 2);
            bodyMem = body;
        } else {
            bytes32 rid = a.bodyHashOrRecordId;
            bytes32 have = _records().cells[rid].typeId;
            if (have == 0) revert E_MISSING_RECORD(leaf, rid);
            if (have != a.typeId) revert E_TYPE_MISMATCH(leaf, a.typeId, have);
            bodyMem = _loadBody(rid);
        }
        v.refCount = info.refCount;
        v.policyRow = info.policyRow;
        _validateRecord(leaf, a.typeId, info, bodyMem, admission, principalId, $);
    }

    function _validateRecord(
        uint8 leaf,
        bytes32 typeId,
        TypeInfo memory info,
        bytes memory bodyMem,
        uint64 admission,
        bytes32 principalId,
        RealmStorage storage $
    ) private view {
        RefHeader[] memory headers;
        bytes32[] memory refs;
        (refs, headers) = _resolveRefs(leaf, typeId, info, bodyMem);
        AcceptContext memory ctx = AcceptContext({
            typeId: typeId,
            realmId: $.realmId,
            principalId: principalId,
            admission: admission,
            revision: $.revision,
            grade: info.grade,
            leaf: leaf,
            ledger: address(this),
            index: $.index,
            registry: $.registry,
            descriptorBlob: info.descriptorBlob,
            customPredicate: info.custom,
            bindingId: info.bindingId
        });
        if (info.mandatory.codehash != info.ruleId) revert E_ACCEPTOR_CODE(leaf, info.mandatory);
        uint32 need = _effectiveGas(info.validationGas);
        _accept(
            leaf,
            ctx,
            bodyMem,
            refs,
            headers,
            info.mandatory,
            need,
            $.limits.kernelTail,
            0,
            info.policyRow
        );
        if (info.policy != address(0)) {
            if (info.policy.codehash != info.policyCodehash) {
                revert E_ACCEPTOR_CODE(leaf, info.policy);
            }
            _accept(
                leaf,
                ctx,
                bodyMem,
                refs,
                headers,
                info.policy,
                need,
                $.limits.kernelTail,
                1,
                info.policyRow
            );
        }
    }

    function _loadBody(bytes32 rid) private view returns (bytes memory out) {
        RecordCell storage cell = _records().cells[rid];
        uint256 len = cell.length;
        out = new bytes(len);
        mapping(uint256 => bytes32) storage words = _records().bodyWords[rid];
        for (uint256 i; i * 32 < len; ++i) {
            bytes32 w = words[i];
            assembly ("memory-safe") {
                mstore(add(add(out, 32), mul(i, 32)), w)
            }
        }
    }

    function _resolveRefs(uint8 leaf, bytes32 typeId, TypeInfo memory info, bytes memory body)
        private
        view
        returns (bytes32[] memory refs, RefHeader[] memory headers)
    {
        uint256 count = info.refCount;
        refs = new bytes32[](count);
        headers = new RefHeader[](count);
        if (count == 0) return (refs, headers);
        bytes32[] memory expected = ITypeRegistry(_realm().registry).refTypes(typeId);
        for (uint256 i; i < count; ++i) {
            if (body.length < (i + 1) * 32) revert E_REF(leaf, uint8(i), 1);
            bytes32 r;
            assembly ("memory-safe") {
                r := mload(add(add(body, 32), mul(i, 32)))
            }
            if (uint256(r) < 1 << 16) revert E_REF(leaf, uint8(i), 3); // sentinel values never appear as body words
            RecordCell storage cell = _records().cells[r];
            if (cell.typeId == 0) revert E_REF(leaf, uint8(i), 1);
            bytes32 want = i < expected.length ? expected[i] : bytes32(0);
            if (want == bytes32(uint256(1))) want = typeId; // SELF
            else if (uint256(want) != 0 && uint256(want) < 1 << 16) revert E_REF(leaf, uint8(i), 4); // reserved sentinels
            if (want != 0 && cell.typeId != want) revert E_REF(leaf, uint8(i), 2);
            refs[i] = r;
            mapping(uint256 => bytes32) storage words = _records().bodyWords[r];
            headers[i] = RefHeader({
                typeId: cell.typeId,
                firstAdmission: cell.firstAdmission,
                length: cell.length,
                word0: words[0],
                word1: info.refHeaderWords >= 2 ? words[1] : bytes32(0),
                word2: info.refHeaderWords >= 3 ? words[2] : bytes32(0)
            });
        }
    }

    function _accept(
        uint8 leaf,
        AcceptContext memory ctx,
        bytes memory body,
        bytes32[] memory refs,
        RefHeader[] memory headers,
        address acceptor,
        uint32 need,
        uint32 kernelTail,
        uint8 which,
        uint16 policyRow
    ) private view {
        uint256 available = (gasleft() - kernelTail) * 63 / 64;
        if (available < need) revert E_GAS(leaf, need, uint32(available));
        bytes memory data = abi.encodeCall(IAcceptor.accept, (ctx, body, refs, headers));
        bool ok;
        uint256 size;
        bytes32 word;
        uint256 before = gasleft();
        assembly ("memory-safe") {
            let out := mload(0x40)
            ok := staticcall(available, acceptor, add(data, 32), mload(data), out, 32)
            size := returndatasize()
            word := mload(out)
        }
        uint256 used = before - gasleft();
        if (ok && size == 32 && word == bytes32(IAcceptor.accept.selector)) return;
        if (
            (!ok && size == 0 && used + 2_000 >= available)
                || (ok && size == 32 && word == EXHAUSTED)
        ) {
            revert E_ACCEPTOR_GAS(leaf, ctx.typeId, uint32(available));
        }
        if (which == 0) revert E_REJECTED(leaf, ctx.typeId);
        revert E_POLICY_REJECTED(leaf, ctx.typeId, policyRow);
    }

    // =============================================================================================
    // dispatchIndex / dispatchFinal (design §6.4, §6.5, §10.3): the callbacks under the availability floor
    // =============================================================================================

    /// @inheritdoc ILedgerIngress
    function dispatchIndex(uint64 publication, bytes calldata leafBlob, uint32 remainingPrefixFloor)
        external
        delegateOnly
        returns (uint32 spent)
    {
        address index = _realm().index;
        uint256 g = gasleft();
        uint256 available = g * 63 / 64;
        if (available < remainingPrefixFloor) {
            revert E_INDEX_GAS(remainingPrefixFloor, uint32(available));
        }
        // onAdmission(uint64, Effect[1], bytes32[refCount]) assembled from the blob: head = 3 words,
        // effects at 0x60 (length 1 + 24 words = 800 B), refs at 0x380 (length + words)
        uint256 refCount = uint256(bytes32(leafBlob[24 * 32:25 * 32]));
        bytes memory data = abi.encodePacked(
            IRealmIndex.onAdmission.selector,
            uint256(publication),
            uint256(0x60),
            uint256(0x380),
            uint256(1),
            leafBlob[0:24 * 32],
            refCount,
            leafBlob[25 * 32:(25 + refCount) * 32]
        );
        bool ok;
        uint256 size;
        bytes32 word;
        assembly ("memory-safe") {
            let out := mload(0x40)
            ok := call(gas(), index, 0, add(data, 32), mload(data), out, 32)
            size := returndatasize()
            word := mload(out)
        }
        spent = uint32(g - gasleft());
        _ack(
            ok,
            size,
            word,
            IRealmIndex.onAdmission.selector,
            remainingPrefixFloor,
            uint32(available),
            Phase.APPLYING
        );
    }

    /// @inheritdoc ILedgerIngress
    function dispatchFinal(uint64 publication, bytes calldata effects, bytes32[] calldata refs)
        external
        view
        delegateOnly
    {
        address index = _realm().index;
        uint256 n = effects.length / (24 * 32);
        bytes memory data = abi.encodePacked(
            IRealmIndex.afterPublication.selector,
            uint256(publication),
            uint256(0x60),
            uint256(0x60 + 32 + effects.length),
            n,
            effects,
            uint256(refs.length),
            abi.encodePacked(refs)
        );
        bool ok;
        uint256 size;
        bytes32 word;
        assembly ("memory-safe") {
            let out := mload(0x40)
            ok := staticcall(gas(), index, add(data, 32), mload(data), out, 32)
            size := returndatasize()
            word := mload(out)
        }
        _ack(ok, size, word, IRealmIndex.afterPublication.selector, 0, 0, Phase.FINAL);
    }

    function _ack(
        bool ok,
        uint256 size,
        bytes32 word,
        bytes4 selector,
        uint32 quoted,
        uint32 available,
        uint8 phase
    ) private pure {
        if (!ok) {
            if (size == 0) revert E_INDEX_GAS(quoted, available);
            if (size > RETURNDATA_BOUND) revert E_INDEX_RETURNDATA(size);
            bytes memory inner = new bytes(size);
            assembly ("memory-safe") {
                returndatacopy(add(inner, 32), 0, size)
            }
            revert E_INDEX_CALL(inner);
        }
        if (size != 32) revert E_INDEX_RETURNDATA(size);
        if (word != bytes32(selector)) revert E_INDEX_ACK(phase);
    }

    // =============================================================================================
    // ILedgerCommitments (callable directly on the ingress address)
    // =============================================================================================

    function actionsHash(Action[] calldata actions) external pure returns (bytes32) {
        return keccak256(abi.encode(actions));
    }

    function intentDigest(Intent calldata it, bytes32 actionsHash_) public pure returns (bytes32) {
        return keccak256(abi.encode(Keys.DOM_SIGNED_INTENT, _hashIntent(it), actionsHash_));
    }

    function signingDigest(bytes32 domainSeparator, Intent calldata it, bytes32 actionsHash_)
        public
        pure
        returns (bytes32)
    {
        bytes32 structHash = keccak256(
            abi.encode(INTENT_WITH_ACTIONS_TYPEHASH, _hashIntent(it), actionsHash_)
        );
        return keccak256(abi.encodePacked(hex"1901", domainSeparator, structHash));
    }

    function _hashIntent(Intent calldata it) private pure returns (bytes32) {
        return keccak256(
            abi.encode(
                INTENT_TYPEHASH,
                it.realmId,
                it.realmOrigin,
                it.executionSet,
                it.principalId,
                it.author,
                it.nonce,
                it.deadline,
                it.acceptanceProfile,
                it.indexObligations,
                it.readSetHash,
                it.verifierProfile,
                it.authorityId,
                it.authEpoch
            )
        );
    }

    function nativeIntentDigest(
        bytes32 realmId,
        bytes32 principalId,
        Native calldata ctx,
        bytes32 actionsHash_,
        bytes32 guardHash
    ) public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                Keys.DOM_NATIVE_INTENT,
                realmId,
                principalId,
                ctx.nonce,
                ctx.deadline,
                ctx.expectedExecutionSet,
                ctx.expectedAcceptanceProfile,
                guardHash,
                actionsHash_
            )
        );
    }

    function publicationIdOf(bytes32 principalId, bytes32 intentDigest_)
        external
        pure
        returns (bytes32)
    {
        return Keys.publicationId(principalId, intentDigest_);
    }

    function readSetHash(ReadSet calldata rs) external pure returns (bytes32) {
        return keccak256(abi.encode(rs));
    }

    function headSnapshotHash(
        uint8 state,
        uint64 revision,
        uint64 admission,
        bytes32 canonicalTarget
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(state, revision, admission, canonicalTarget));
    }

    function acceptanceProfileOf(address ledger, Action[] calldata actions)
        external
        view
        returns (bytes32 profile)
    {
        (profile,,,,) = _foldAndQuote(
            ledger, actions, bytes32(0), msg.sig == this.acceptanceProfileOf.selector
        );
    }

    function indexObligationsOf(address ledger) external view returns (bytes32) {
        return _realmWord(ledger, 10);
    }

    function indexFloor(address ledger, Action[] calldata actions)
        external
        view
        returns (uint32 prefixFloor, uint32 finalReserve, uint32 freshSlots, uint32 rewrites)
    {
        (, prefixFloor, finalReserve, freshSlots, rewrites) =
            _foldAndQuote(ledger, actions, bytes32(0), false);
    }

    function recordId(bytes32 typeId, bytes32 bodyHash) external pure returns (bytes32) {
        return Keys.recordFromHash(typeId, bodyHash);
    }

    function subjectId(bytes32 principalId, bytes32 salt) external pure returns (bytes32) {
        return Keys.subject(principalId, salt);
    }

    function positionKey(bytes32 purpose, bytes32 subject, bytes32 role)
        external
        pure
        returns (bytes32)
    {
        return Keys.position(purpose, subject, role);
    }

    function bindingKey(bytes32 principalId, bytes32 position) external pure returns (bytes32) {
        return Keys.binding(principalId, position);
    }

    function scopeKey(bytes32 principalId, bytes32 purpose, bytes32 subject)
        external
        pure
        returns (bytes32)
    {
        return Keys.scope(principalId, purpose, subject);
    }

    function roleScopeKey(bytes32 principalId, bytes32 purpose, bytes32 role)
        external
        pure
        returns (bytes32)
    {
        return Keys.roleScope(principalId, purpose, role);
    }

    function postingKey(FamilyId family, TypeId typeId, uint8 ordinal, bytes32 value)
        external
        pure
        returns (PostingKey)
    {
        return PostingKey.wrap(Keys.posting(TypeId.unwrap(typeId), _kindOf(family), ordinal, value));
    }

    function typeIdOf(bytes32 shape, bytes32[] calldata refTypes, bytes32 ruleId)
        external
        pure
        returns (bytes32)
    {
        return Keys.typeId(shape, refTypes, ruleId);
    }

    /// The §10.2 kind number of a family id: the first eight bytes of each id (test/vectors/ids.json), packed
    /// in declaration order, and the matching kinds; reverts for an unknown family.
    bytes private constant FAMILY_PREFIXES =
        hex"e4f7cc7ff76622e1d674025fa1091f86f564f360d1f5b65ade538e29eab736631fd035d41e55e58529d3bea0a01e3e2603b682942778e8b977b478e9ae9182faef3758cffd687b169f7b888d291c8c4ce84f1b109238a09c04369382b4c38d708433e20c283016a6";
    bytes private constant FAMILY_KINDS = hex"010405080a0b0c0d0e0f101112";

    function _kindOf(FamilyId family) private pure returns (uint8) {
        bytes8 head = bytes8(FamilyId.unwrap(family));
        bytes memory prefixes = FAMILY_PREFIXES;
        for (uint256 i; i < 13; ++i) {
            bytes8 candidate;
            assembly ("memory-safe") {
                candidate := mload(add(add(prefixes, 32), mul(i, 8)))
            }
            if (candidate == head) return uint8(FAMILY_KINDS[i]);
        }
        revert E_RESERVED(20, uint256(FamilyId.unwrap(family)));
    }
}
