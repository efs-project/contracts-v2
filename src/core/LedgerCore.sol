// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {LedgerStorage} from "./storage/LedgerStorage.sol";
import {Layout} from "./layout/Layout.sol";
import {Keys} from "../lib/Keys.sol";
import {Action, ActionKind, Native, Intent} from "../interfaces/Actions.sol";
import {Phase} from "../interfaces/Results.sol";
import {ClosureConstants, Limits} from "../interfaces/Limits.sol";
import {ILedger} from "../interfaces/ILedger.sol";
import {ILedgerHot} from "../interfaces/ILedgerHot.sol";
import {ILedgerControl, RealmInit, ActivationSet} from "../interfaces/ILedgerControl.sol";
import {ILedgerCommitments} from "../interfaces/ILedgerCommitments.sol";
import {ITypeRegistry} from "../interfaces/ITypeRegistry.sol";
import {ILedgerIngress, LeafVerdict, Prepared} from "../interfaces/internal/ILedgerIngress.sol";
import {ILedgerApply} from "../interfaces/internal/ILedgerApply.sol";
import {
    AlreadyAdmitted,
    E_BATCH_SHAPE,
    E_CHAIN,
    E_COUNTER_SATURATED,
    E_EXECUTION_DRIFT,
    E_FROZEN,
    E_HELPER_CODE,
    E_INDEX_GAS,
    E_INGRESS,
    E_NATIVE_AMBIGUOUS,
    E_NONCE,
    E_NOT_CONTROLLER,
    E_NO_INDEX,
    E_PUBLICATION_ACTIVE,
    E_REGISTRY_DRIFT,
    E_RESERVED,
    E_TRANSITION
} from "../interfaces/Errors.sol";

interface IControlPins {
    function INGRESS() external view returns (address);
    function APPLY() external view returns (address);
}

/// @title LedgerCore — the Realm kernel (design §3.1 row 1, §6, §8)
/// @notice The proxied implementation that owns every canonical row and runs the ordered single-pass
///         admission under a transient lock. Its writes are split across three codehash-pinned delegates it
///         alone can reach: `LedgerApply` (the per-action writers), `LedgerIngress` (zero-write preparation,
///         acceptor validation, index dispatch) and `LedgerControl` (genesis, activation, freeze and
///         transition). The kernel keeps the lock, the retry law, the evidence writer and the Etched reads.
contract LedgerCore is ILedger, ILedgerHot, ILedgerControl, Initializable, LedgerStorage {
    address public immutable INGRESS;
    bytes32 public immutable INGRESS_CODEHASH;
    address public immutable APPLY;
    bytes32 public immutable APPLY_CODEHASH;
    address public immutable CONTROL;
    bytes32 public immutable CONTROL_CODEHASH;
    bytes32 public immutable HOT_ABI_ID;
    bytes32 public constant LAYOUT_ID = Layout.LAYOUT_ID;

    bytes32 private constant IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    uint256 private constant ERROR_COPY_BOUND = 4_164;
    uint256 private constant PREPARED_SIZE = 21 * 32;
    uint256 private constant LEAF_BLOB_SIZE = 33 * 32;
    uint256 private constant EFFECT_SIZE = 24 * 32;
    uint8 private constant FLAG_GUARDED = 1 << 1;

    constructor(address ingress_, address apply_, address control_, bytes32 hotAbiId_) {
        INGRESS = ingress_;
        INGRESS_CODEHASH = ingress_.codehash;
        APPLY = apply_;
        APPLY_CODEHASH = apply_.codehash;
        CONTROL = control_;
        CONTROL_CODEHASH = control_.codehash;
        HOT_ABI_ID = hotAbiId_;
        if (
            IControlPins(control_).INGRESS() != ingress_ || IControlPins(control_).APPLY() != apply_
        ) {
            revert E_HELPER_CODE(control_);
        }
        _disableInitializers();
    }

    modifier onlyController() {
        if (msg.sender != _realm().controller) revert E_NOT_CONTROLLER(msg.sender);
        _;
    }

    modifier idle() {
        (uint8 p,,,) = _unpackLock(_lockWord());
        if (p != Phase.IDLE) revert E_PUBLICATION_ACTIVE();
        _;
    }

    modifier notFrozen() {
        if (_realm().frozen != 0) revert E_FROZEN();
        _;
    }

    // =============================================================================================
    // Control (design §5.4): the gates live here, the bodies in the pinned control delegate
    // =============================================================================================

    /// @inheritdoc ILedgerControl
    function initialize(RealmInit calldata) external initializer {
        _control();
    }

    /// @inheritdoc ILedgerControl
    function activate(ActivationSet calldata set)
        external
        onlyController
        idle
        notFrozen
        reinitializer(uint64(set.revision) + 1)
    {
        _control();
    }

    /// @inheritdoc ILedgerControl
    function freeze(ActivationSet calldata set)
        external
        onlyController
        idle
        notFrozen
        reinitializer(uint64(set.revision) + 1)
    {
        _control();
    }

    /// @inheritdoc ILedgerControl
    function beginTransition(uint32, uint48) external onlyController idle notFrozen {
        _control();
    }

    /// @inheritdoc ILedgerControl
    function abortTransition() external {
        _control();
    }

    function _control() private {
        if (CONTROL.codehash != CONTROL_CODEHASH) revert E_HELPER_CODE(CONTROL);
        _delegate(CONTROL, msg.data);
    }

    // =============================================================================================
    // Write lanes (design §5.2)
    // =============================================================================================

    /// @inheritdoc ILedger
    function execute(
        Action[] calldata actions,
        bytes[] calldata bodies,
        Native calldata ctx,
        bytes calldata guard
    ) external returns (uint64 publication, uint64 firstAdmission) {
        RealmStorage storage $ = _realm();
        if (msg.sender.code.length == 0 && msg.sender != tx.origin) revert E_NATIVE_AMBIGUOUS(); // under construction
        bytes32 principalId = Keys.principalFor(msg.sender, $.realmOrigin);
        bytes32 digest = ILedgerCommitments(INGRESS)
            .nativeIntentDigest(
                $.realmId, principalId, ctx, keccak256(abi.encode(actions)), keccak256(guard)
            );
        return _run(principalId, digest, ctx.nonce, actions, bodies, guard);
    }

    /// @inheritdoc ILedger
    function executeSigned(
        Intent calldata intent,
        Action[] calldata actions,
        bytes[] calldata bodies,
        bytes calldata guard,
        bytes calldata
    ) external returns (uint64 publication, uint64 firstAdmission) {
        bytes32 digest = ILedgerCommitments(INGRESS)
            .intentDigest(intent, keccak256(abi.encode(actions)));
        return _run(intent.principalId, digest, intent.nonce, actions, bodies, guard);
    }

    /// @inheritdoc ILedger
    function importPublication(bytes calldata packet, bytes calldata)
        external
        pure
        returns (uint64, uint64)
    {
        if (packet.length < 32) revert E_RESERVED(5, 0);
        revert E_RESERVED(5, uint8(packet[0]));
    }

    // =============================================================================================
    // The pipeline (design §6)
    // =============================================================================================

    struct Run {
        uint64 publication;
        uint64 firstAdmission;
        uint64 admission;
        uint32 remainingPrefixFloor;
        uint32 finalReserve;
        uint32 kernelTail;
        uint48 mutationsSnapshot;
        uint256 refCount;
    }

    function _run(
        bytes32 principalId,
        bytes32 intentDigest,
        uint64 nonce,
        Action[] calldata actions,
        bytes[] calldata bodies,
        bytes calldata guard
    ) private returns (uint64, uint64) {
        RealmStorage storage $ = _realm();
        CountersStorage storage c = _counters();
        // 1. lock
        (uint8 ph,,,) = _unpackLock(_lockWord());
        if (ph != Phase.IDLE) revert E_PUBLICATION_ACTIVE();
        _setLockWord(_packLock(Phase.PREPARING, c.publications + 1, c.admissions, 0));
        // 3. retry compare, before anything that depends on time or Realm state
        _retryCompare(principalId, nonce, intentDigest);
        // 4–7. chain, transition, index, live-set tripwires
        if (block.chainid != $.acceptedChainId) {
            revert E_CHAIN($.acceptedChainId, uint64(block.chainid));
        }
        if ($.transitionDeadline >= block.number && $.revision < $.transitionTarget) {
            revert E_TRANSITION($.transitionTarget, $.transitionDeadline);
        }
        if ($.index == address(0)) revert E_NO_INDEX();
        _tripwires($);
        // 8. bounds
        _bounds(actions, bodies, $.limits);
        // 9–10. snapshot and prepare (the lane calldata is forwarded under the ingress's selector)
        Run memory r;
        r.mutationsSnapshot = uint48(ITypeRegistry($.registry).mutations());
        _setLockWord(
            _packLock(Phase.PREPARING, c.publications + 1, c.admissions, r.mutationsSnapshot)
        );
        bytes4 sel = msg.sig == ILedger.execute.selector
            ? ILedgerIngress.prepareNative.selector
            : ILedgerIngress.prepareSigned.selector;
        bytes memory ret = _delegate(INGRESS, abi.encodePacked(sel, msg.data[4:]));
        if (ret.length != PREPARED_SIZE) revert E_INGRESS(ret.length);
        Prepared memory p = abi.decode(ret, (Prepared));
        // 11. begin
        r.publication = c.publications + 1;
        r.admission = c.admissions;
        r.firstAdmission = r.admission + 1;
        if (
            r.publication > ClosureConstants.SATURATION
                || r.admission + actions.length > ClosureConstants.SATURATION
        ) {
            revert E_COUNTER_SATURATED(0);
        }
        _begin(p, r, actions, guard);
        r.remainingPrefixFloor = p.prefixFloor;
        r.finalReserve = p.finalReserve;
        r.kernelTail = $.limits.kernelTail;
        // 12. leaves: effects kept as the apply delegate's raw words, never decoded here
        bytes memory effects = new bytes(actions.length * EFFECT_SIZE);
        bytes32[] memory refs = new bytes32[](actions.length * $.limits.maxRefs);
        for (uint256 i; i < actions.length; ++i) {
            _applyOne(uint8(i), actions[i], bodies[i], p, r, effects, refs);
        }
        // 13. final
        _final(p, r, effects, refs);
        return (r.publication, r.firstAdmission);
    }

    function _retryCompare(bytes32 principalId, uint64 nonce, bytes32 intentDigest) private view {
        PublicationsStorage storage pub = _publications();
        uint48 ordinal = pub.publicationAt[principalId][nonce];
        if (ordinal != 0) {
            if (pub.evidence[ordinal].intentDigest == intentDigest) {
                revert AlreadyAdmitted(ordinal);
            }
            revert E_NONCE(principalId, nonce, ordinal);
        }
        if (nonce != _principals().rows[principalId].nonce) revert E_NONCE(principalId, nonce, 0);
    }

    function _tripwires(RealmStorage storage $) private view {
        _checkImplementation($);
        if (INGRESS.codehash != INGRESS_CODEHASH) revert E_HELPER_CODE(INGRESS);
        if (APPLY.codehash != APPLY_CODEHASH) revert E_HELPER_CODE(APPLY);
        uint32 rev = ITypeRegistry($.registry).activeRevision();
        if (rev != $.revision) revert E_REGISTRY_DRIFT($.revision, rev);
    }

    function _checkImplementation(RealmStorage storage $) private view {
        address live;
        assembly ("memory-safe") {
            live := sload(IMPLEMENTATION_SLOT)
        }
        address activated = _revisions().rows[$.revision].ledgerImpl;
        if (live != activated) revert E_EXECUTION_DRIFT(live, activated);
    }

    function _bounds(Action[] calldata actions, bytes[] calldata bodies, Limits storage limits)
        private
        view
    {
        uint256 n = actions.length;
        if (n == 0 || n > limits.maxActions || bodies.length != n) {
            revert E_BATCH_SHAPE(uint16(n), uint16(bodies.length));
        }
        uint256 binds;
        uint256 bodyBytes;
        for (uint256 i; i < n; ++i) {
            uint8 kind = actions[i].kind;
            if (kind == ActionKind.BIND || kind == ActionKind.UNBIND || kind == ActionKind.RELEASE) ++binds;
            bodyBytes += bodies[i].length;
        }
        if (binds > limits.maxBindsPerPublication || bodyBytes > limits.maxBodyBytesPerPublication)
        {
            revert E_BATCH_SHAPE(uint16(n), uint16(bodies.length));
        }
    }

    function _begin(
        Prepared memory p,
        Run memory r,
        Action[] calldata actions,
        bytes calldata guard
    ) private {
        bool hasBind;
        for (uint256 i; i < actions.length; ++i) {
            uint8 k = actions[i].kind;
            if (k == ActionKind.BIND || k == ActionKind.UNBIND || k == ActionKind.RELEASE) {
                hasBind = true;
                break;
            }
        }
        PrincipalRow storage pr = _principals().rows[p.principalId];
        pr.nonce = uint48(p.nonce) + 1;
        if (hasBind) pr.viewMutationVersion += 1;
        PublicationsStorage storage pub = _publications();
        pub.publicationAt[p.principalId][p.nonce] = uint48(r.publication);
        EvidenceCell storage e = pub.evidence[r.publication];
        e.author = p.author;
        e.proofKind = p.proofKind;
        e.principalKind = p.principalKind;
        e.v = p.v;
        e.leafCount = p.leafCount;
        e.firstAdmission = uint48(r.firstAdmission);
        e.flags = p.flags;
        e.nonce = uint48(p.nonce);
        e.deadline = p.deadline;
        e.basisBlock = uint48(block.number);
        e.revision = _realm().revision;
        e.verifierProfile = p.verifierProfile;
        e.principalId = p.principalId;
        e.intentDigest = p.intentDigest;
        e.actionsHash = p.actionsHash;
        if (p.proofKind != 1) {
            e.acceptanceProfile = p.acceptanceProfile;
            e.indexObligations = p.indexObligations;
            e.witness0 = p.witness0;
            e.witness1 = p.witness1;
            e.submitter = msg.sender;
        }
        if (p.flags & FLAG_GUARDED != 0) {
            e.readSetHash = p.readSetHash;
            emit ReadSetChecked(r.publication, p.readSetHash, guard);
        }
        _setLockWord(
            _packLock(
                Phase.APPLYING, uint48(r.publication), uint48(r.admission), r.mutationsSnapshot
            )
        );
    }

    function _applyOne(
        uint8 leaf,
        Action calldata a,
        bytes calldata body,
        Prepared memory p,
        Run memory r,
        bytes memory effects,
        bytes32[] memory refs
    ) private {
        uint64 admission = ++r.admission;
        bytes memory ret = _delegate(
            INGRESS,
            abi.encodeCall(ILedgerIngress.validateLeaf, (leaf, a, body, admission, p.principalId))
        );
        LeafVerdict memory v = abi.decode(ret, (LeafVerdict));
        ret = _delegate(
            APPLY,
            abi.encodeCall(
                ILedgerApply.applyLeaf,
                (
                    leaf,
                    admission,
                    a,
                    body,
                    v.refCount,
                    p.principalId,
                    p.principalKind,
                    v.policyRow,
                    v.roleRow
                )
            )
        );
        if (ret.length != LEAF_BLOB_SIZE) revert E_INGRESS(ret.length);
        // copy the 24 Effect words into the publication's effect buffer and the refs into the refs buffer
        uint256 refCount;
        assembly ("memory-safe") {
            let src := add(ret, 32)
            mcopy(add(add(effects, 32), mul(leaf, EFFECT_SIZE)), src, EFFECT_SIZE)
            refCount := mload(add(src, mul(24, 32)))
        }
        uint256 base = r.refCount;
        for (uint256 i; i < refCount; ++i) {
            bytes32 w;
            assembly ("memory-safe") {
                w := mload(add(add(ret, 32), mul(add(25, i), 32)))
            }
            refs[base + i] = w;
        }
        r.refCount = base + refCount;
        _emitAdmitted(admission, a, ret, p.principalId);
        _counters().admissions = uint48(admission); // checkpoint: the staged frontier is visible through counts()
        _notifyIndex(r, ret);
        _recheck(r);
    }

    /// Topic 3 and the id come from the apply delegate's words (typeId 5, recordId 6, subjectId 7, position 9).
    function _emitAdmitted(
        uint64 admission,
        Action calldata a,
        bytes memory blob,
        bytes32 principalId
    ) private {
        uint8 kind = a.kind;
        bytes32 typeId;
        bytes32 recordId;
        bytes32 subjectId;
        bytes32 position;
        assembly ("memory-safe") {
            let b := add(blob, 32)
            typeId := mload(add(b, 160))
            recordId := mload(add(b, 192))
            subjectId := mload(add(b, 224))
            position := mload(add(b, 288))
        }
        if (kind == ActionKind.CREATE) {
            emit Admitted(admission, kind, subjectId, subjectId, principalId);
        } else if (
            kind == ActionKind.BIND || kind == ActionKind.UNBIND || kind == ActionKind.RELEASE
        ) {
            emit Admitted(
                admission,
                kind,
                Keys.scope(principalId, a.purpose, a.subject),
                position,
                principalId
            );
        } else if (kind == ActionKind.WITHDRAW) {
            emit Admitted(admission, kind, typeId, a.target, principalId);
        } else {
            emit Admitted(admission, kind, a.typeId, recordId, principalId);
        }
    }

    function _notifyIndex(Run memory r, bytes memory leafBlob) private {
        uint256 reserve = uint256(r.finalReserve) + r.kernelTail;
        uint256 g = gasleft();
        if (g <= reserve) revert E_INDEX_GAS(r.remainingPrefixFloor, 0);
        uint256 available = (g - reserve) * 63 / 64;
        (bool ok, bytes memory ret) = INGRESS.delegatecall{gas: available}(
            abi.encodeCall(
                ILedgerIngress.dispatchIndex, (r.publication, leafBlob, r.remainingPrefixFloor)
            )
        );
        if (!ok) _bubble(ret);
        uint32 spent = abi.decode(ret, (uint32));
        r.remainingPrefixFloor =
            spent >= r.remainingPrefixFloor ? 0 : r.remainingPrefixFloor - spent;
    }

    function _recheck(Run memory r) private view {
        RealmStorage storage $ = _realm();
        uint64 m = ITypeRegistry($.registry).mutations();
        if (m != r.mutationsSnapshot) revert E_REGISTRY_DRIFT(r.mutationsSnapshot, m);
        _checkImplementation($);
    }

    function _final(Prepared memory p, Run memory r, bytes memory effects, bytes32[] memory refs)
        private
    {
        _setLockWord(
            _packLock(Phase.FINAL, uint48(r.publication), uint48(r.admission), r.mutationsSnapshot)
        );
        assembly ("memory-safe") {
            mstore(refs, mload(add(r, 0xe0))) // trim the refs buffer to what was appended
        }
        uint256 g = gasleft();
        uint256 available = g > r.kernelTail ? (g - r.kernelTail) * 63 / 64 : 0;
        if (available < r.finalReserve) revert E_INDEX_GAS(r.finalReserve, uint32(available));
        _delegate(
            INGRESS, abi.encodeCall(ILedgerIngress.dispatchFinal, (r.publication, effects, refs))
        );
        _recheck(r);
        _counters().publications = uint48(r.publication);
        _setLockWord(0);
        emit Published(
            r.publication,
            Keys.publicationId(p.principalId, p.intentDigest),
            p.principalId,
            p.proofKind,
            r.firstAdmission,
            p.leafCount,
            keccak256(abi.encodePacked(uint256(32), uint256(p.leafCount), effects)),
            _realm().revision
        );
    }

    /// DELEGATECALL into a pinned helper; a typed revert is bubbled with a bounded copy.
    function _delegate(address target, bytes memory data) private returns (bytes memory ret) {
        bool ok;
        (ok, ret) = target.delegatecall(data);
        if (!ok) _bubble(ret);
    }

    function _bubble(bytes memory ret) private pure {
        uint256 size = ret.length;
        if (size > ERROR_COPY_BOUND) revert E_INGRESS(size);
        assembly ("memory-safe") {
            revert(add(ret, 32), size)
        }
    }

    // =============================================================================================
    // Etched hot reads (design §5.3)
    // =============================================================================================

    function counts() external view returns (uint64, uint64, uint64, uint64) {
        CountersStorage storage c = _counters();
        return (c.admissions, c.records, c.bindings, c.publications);
    }

    function phase() external view returns (uint8, uint64, uint64, uint32) {
        (uint8 p_, uint48 s, uint48 a,) = _unpackLock(_lockWord());
        return (p_, s, a, _realm().revision);
    }

    function executionSet() external view returns (bytes32) {
        return _realm().executionSet;
    }

    function revision() external view returns (uint32) {
        return _realm().revision;
    }

    function control() external view returns (uint64, uint64, uint32, bool) {
        RealmStorage storage $ = _realm();
        return ($.genesisChainId, $.acceptedChainId, $.revision, $.frozen != 0);
    }

    function realmId() external view returns (bytes32) {
        return _realm().realmId;
    }

    function realmOrigin() external view returns (bytes32) {
        return _realm().realmOrigin;
    }

    function layoutId() external view returns (bytes32) {
        return _realm().layoutId;
    }

    function hotAbiId() external view returns (bytes32) {
        return HOT_ABI_ID;
    }

    function supportedHotAbiIds() external view returns (bytes32[] memory ids) {
        ids = new bytes32[](1);
        ids[0] = HOT_ABI_ID;
    }

    function registry() external view returns (address) {
        return _realm().registry;
    }

    function index() external view returns (address) {
        return _realm().index;
    }

    function indexGeneration() external view returns (uint32) {
        return _realm().indexGeneration;
    }

    function ingress() external view returns (address) {
        return INGRESS;
    }

    function applyDelegate() external view returns (address) {
        return APPLY;
    }

    function controller() external view returns (address) {
        return _realm().controller;
    }

    function noticePrincipal() external view returns (bytes32) {
        return _realm().noticePrincipal;
    }

    function readerDirectory() external view returns (address) {
        return _realm().readerDirectory;
    }

    function nonceOf(bytes32 principalId) external view returns (uint64, uint64) {
        PrincipalRow storage pr = _principals().rows[principalId];
        return (pr.nonce, pr.viewMutationVersion);
    }

    function subjectCreatedAt(bytes32 subjectId) external view returns (uint64) {
        return _subjects().cells[subjectId].createAdmission;
    }

    function head(bytes32 bindingKey)
        external
        view
        returns (uint8, uint64, uint64, uint8, uint64, uint64, bytes32)
    {
        HeadRow storage h = _bindings().heads[bindingKey];
        uint8 state = h.state;
        return (
            state,
            h.revision,
            h.admission,
            h.targetKind,
            h.prevAdmission,
            h.bindingOrdinal,
            state == 1 ? h.target : bytes32(0)
        );
    }

    function recordHeader(bytes32 recordId)
        external
        view
        returns (bytes32, uint64, uint32, uint64, uint8)
    {
        RecordCell storage cell = _records().cells[recordId];
        return (cell.typeId, cell.firstAdmission, cell.length, cell.occurrences, cell.carrierKind);
    }

    function publicationAt(bytes32 principalId, uint64 nonce)
        external
        view
        returns (uint64 publication, bytes32 intentDigest)
    {
        PublicationsStorage storage pub = _publications();
        publication = pub.publicationAt[principalId][nonce];
        if (publication != 0) intentDigest = pub.evidence[publication].intentDigest;
    }

    function extsload(bytes32 slot) external view returns (bytes32 w) {
        assembly ("memory-safe") {
            w := sload(slot)
        }
    }

    function extsloadBatch(bytes32[] calldata slots) external view returns (bytes32[] memory out) {
        if (slots.length > 256) revert E_RESERVED(30, slots.length);
        out = new bytes32[](slots.length);
        for (uint256 i; i < slots.length; ++i) {
            bytes32 s = slots[i];
            bytes32 w;
            assembly ("memory-safe") {
                w := sload(s)
            }
            out[i] = w;
        }
    }

    function exttload(bytes32 slot) external view returns (bytes32 w) {
        assembly ("memory-safe") {
            w := tload(slot)
        }
    }
}
