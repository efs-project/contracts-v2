// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test, Vm} from "forge-std/Test.sol";
import {KernelDeploy} from "./KernelDeploy.sol";
import {ExecutionSets} from "./ExecutionSets.sol";
import {StateDigest} from "./StateDigest.sol";
import {MockRegistry} from "./doubles/MockRegistry.sol";
import {IndexDoubleCore} from "./doubles/IndexDoubles.sol";
import {RecordingIndex} from "./doubles/RecordingIndex.sol";
import {AcceptAll, RejectAll} from "./doubles/Acceptors.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {Layout} from "../../src/core/layout/Layout.sol";
import {Action, ActionKind, Native} from "../../src/interfaces/Actions.sol";
import {Limits} from "../../src/interfaces/Limits.sol";
import {Phase} from "../../src/interfaces/Results.sol";
import {ILedger} from "../../src/interfaces/ILedger.sol";
import {ILedgerHot} from "../../src/interfaces/ILedgerHot.sol";
import {ILedgerCommitments} from "../../src/interfaces/ILedgerCommitments.sol";
import {ILedgerControl, ActivationSet} from "../../src/interfaces/ILedgerControl.sol";
import {TypeInfo} from "../../src/interfaces/ITypeRegistry.sol";
import {Effect, FamilyEntry, Readiness, Unit} from "../../src/interfaces/Index.sol";

/// @notice The shared write-path fixture (design §16 preamble): the kernel vertical deployed through
///         `KernelDeploy` with this contract as controller, a registry double and an index double from two
///         virtual factories, the genesis activation, three NATIVE-grade Types, action builders for every kind,
///         the native context, a `digest()` over `StateDigest` with every key the fixture has seen, and
///         `_expectNoChange` around a refused call (design §6.6: a refused call changes no raw slot).
/// @dev Keys are tracked from every action list the helpers submit (records, subjects, binding keys,
///      positions, principals) before the before-digest is taken, so a refused call's would-be rows are inside
///      the digest. The index double's prefix record (`prefixCalls`, `prefixDigest`, progress) is folded in.
abstract contract KernelFixture is Test {
    bytes32 internal constant TYPE_OK = keccak256("efs2/test/fixture/type/ok");
    bytes32 internal constant TYPE_OK2 = keccak256("efs2/test/fixture/type/ok2");
    bytes32 internal constant TYPE_REJECT = keccak256("efs2/test/fixture/type/reject");
    bytes32 internal constant FOLDER = keccak256("efs2/purpose/folder/1");
    bytes32 internal constant ROLE = keccak256("efs2/test/fixture/role/name");

    KernelDeploy.Kernel internal k;
    MockRegistry internal registry;
    address internal index;
    ILedger internal ledger;
    ILedgerHot internal hot;
    ILedgerCommitments internal commitments;
    AcceptAll internal acceptAll;
    RejectAll internal rejectAll;
    /// The test contract's principal (a contract principal: it has code).
    bytes32 internal principal;

    bytes32[] internal trackedRecords;
    bytes32[] internal trackedSubjects;
    bytes32[] internal trackedBindingKeys;
    bytes32[] internal trackedPositions;
    bytes32[] internal trackedPrincipals;
    mapping(bytes32 => bool) internal _seen;

    // ---- set-up and factories ----------------------------------------------------------------------------

    function setUp() public virtual {
        registry = _newRegistry();
        k = KernelDeploy.deploy(address(this), address(registry), keccak256("efs2/test/fixture"));
        ledger = ILedger(k.proxy);
        hot = ILedgerHot(k.proxy);
        commitments = ILedgerCommitments(address(k.ingress));
        registry.setLedger(k.proxy);
        registry.setImplementation(address(registry));
        index = _newIndex(k.proxy);
        IndexDoubleCore(index).setReadiness(_readiness(index, 0, 0));
        _activateNext(index, KernelDeploy.s1Limits());
        acceptAll = new AcceptAll();
        rejectAll = new RejectAll();
        _registerType(TYPE_OK, address(acceptAll));
        _registerType(TYPE_OK2, address(acceptAll));
        _registerType(TYPE_REJECT, address(rejectAll));
        principal = Keys.principalFor(address(this), hot.realmOrigin());
        _trackPrincipal(principal);
    }

    /// The registry double; owned by this contract.
    function _newRegistry() internal virtual returns (MockRegistry) {
        return new MockRegistry();
    }

    /// The genesis index double for `ledger_`; owned by this contract. Default: the recording honest index.
    function _newIndex(address ledger_) internal virtual returns (address) {
        return address(new RecordingIndex(ledger_));
    }

    function _readiness(address idx, uint64 admissions, uint64 publications)
        internal
        view
        returns (Readiness memory r)
    {
        r.version = 1;
        r.ledger = k.proxy;
        r.layoutId = Layout.LAYOUT_ID;
        r.hotAbiId = KernelDeploy.HOT_ABI_ID;
        r.manifestHash = IndexDoubleCore(idx).manifestHash();
        r.provenFrom = 1;
        r.completedAdmission = admissions;
        r.completedPublication = publications;
        r.ready = true;
        r.units = new Unit[](0);
        r.families = new FamilyEntry[](0);
    }

    /// Activates revision + 1 naming `idx` under `limits` (the registry's activeRevision follows first).
    function _activateNext(address idx, Limits memory limits)
        internal
        returns (ActivationSet memory set)
    {
        uint32 rev = hot.revision() + 1;
        registry.setActiveRevision(rev);
        set = KernelDeploy.genesisSet(
            k, address(this), address(registry), idx, IndexDoubleCore(idx).manifestHash()
        );
        set.revision = rev;
        set.limits = limits;
        set.expectedExecutionSet = ExecutionSets.executionSet(set, k.proxy);
        ILedgerControl(k.proxy).activate(set);
    }

    /// Replaces the index by an activation: the double's progress and readiness are set to the live counts.
    function _useIndex(address idx) internal {
        (uint64 admissions,,, uint64 publications) = hot.counts();
        IndexDoubleCore(idx).setProgress(admissions, publications);
        IndexDoubleCore(idx).setReadiness(_readiness(idx, admissions, publications));
        _activateNext(idx, KernelDeploy.s1Limits());
        index = idx;
    }

    // ---- Types ---------------------------------------------------------------------------------------------

    function _nativeType(address rule) internal view returns (TypeInfo memory info) {
        info.grade = 3;
        info.refHeaderWords = 1;
        info.mandatory = rule;
        info.ruleId = rule.codehash;
        info.policyRows = 1;
        info.policyRow = 1;
    }

    function _registerType(bytes32 typeId, address rule) internal {
        registry.setType(typeId, _nativeType(rule), new bytes32[](0));
    }

    function _registerType(bytes32 typeId, TypeInfo memory info, bytes32[] memory refTypes)
        internal
    {
        registry.setType(typeId, info, refTypes);
    }

    // ---- action builders ----------------------------------------------------------------------------------

    function _publish(bytes32 typeId, bytes memory body) internal pure returns (Action memory a) {
        a.kind = ActionKind.PUBLISH;
        a.typeId = typeId;
        a.bodyHashOrRecordId = keccak256(body);
    }

    function _reuse(bytes32 typeId, bytes32 recordId) internal pure returns (Action memory a) {
        a.kind = ActionKind.REUSE;
        a.typeId = typeId;
        a.bodyHashOrRecordId = recordId;
    }

    function _bind(bytes32 purpose, bytes32 subject, bytes32 role, bytes32 target, uint64 rev)
        internal
        pure
        returns (Action memory a)
    {
        a.kind = ActionKind.BIND;
        a.purpose = purpose;
        a.subject = subject;
        a.role = role;
        a.target = target;
        a.expectedRevision = rev;
    }

    function _unbind(bytes32 purpose, bytes32 subject, bytes32 role, uint64 rev)
        internal
        pure
        returns (Action memory a)
    {
        a = _bind(purpose, subject, role, 0, rev);
        a.kind = ActionKind.UNBIND;
    }

    function _release(bytes32 purpose, bytes32 subject, bytes32 role, uint64 rev)
        internal
        pure
        returns (Action memory a)
    {
        a = _bind(purpose, subject, role, 0, rev);
        a.kind = ActionKind.RELEASE;
    }

    function _create(bytes32 salt) internal pure returns (Action memory a) {
        a.kind = ActionKind.CREATE;
        a.salt = salt;
    }

    function _withdraw(uint64 admission) internal pure returns (Action memory a) {
        a.kind = ActionKind.WITHDRAW;
        a.target = bytes32(uint256(admission));
    }

    function _acts(Action memory a) internal pure returns (Action[] memory l) {
        l = new Action[](1);
        l[0] = a;
    }

    function _acts(Action memory a, Action memory b) internal pure returns (Action[] memory l) {
        l = new Action[](2);
        (l[0], l[1]) = (a, b);
    }

    function _acts(Action memory a, Action memory b, Action memory c)
        internal
        pure
        returns (Action[] memory l)
    {
        l = new Action[](3);
        (l[0], l[1], l[2]) = (a, b, c);
    }

    /// `n` CREATE leaves with salts derived from `seed`, then `tail` as the last leaf.
    function _afterCreates(uint256 n, bytes32 seed, Action memory tail)
        internal
        pure
        returns (Action[] memory l)
    {
        l = new Action[](n + 1);
        for (uint256 i; i < n; ++i) {
            l[i] = _create(keccak256(abi.encode(seed, i)));
        }
        l[n] = tail;
    }

    function _bodies(uint256 n) internal pure returns (bytes[] memory) {
        return new bytes[](n);
    }

    function _bodies(uint256 n, uint256 index_, bytes memory body)
        internal
        pure
        returns (bytes[] memory b)
    {
        b = new bytes[](n);
        b[index_] = body;
    }

    function _native(uint64 nonce) internal pure returns (Native memory ctx) {
        ctx.nonce = nonce;
    }

    function _native(uint64 nonce, uint64 deadline, bytes32 executionSet_, bytes32 profile)
        internal
        pure
        returns (Native memory ctx)
    {
        ctx = Native(nonce, deadline, executionSet_, profile);
    }

    // ---- ids ------------------------------------------------------------------------------------------------

    function _rid(bytes32 typeId, bytes memory body) internal pure returns (bytes32) {
        return Keys.recordFromHash(typeId, keccak256(body));
    }

    function _sid(bytes32 p, bytes32 salt) internal pure returns (bytes32) {
        return Keys.subject(p, salt);
    }

    function _key(bytes32 p, bytes32 purpose, bytes32 subject, bytes32 role)
        internal
        pure
        returns (bytes32)
    {
        return Keys.binding(p, Keys.position(purpose, subject, role));
    }

    function _nonce(bytes32 p) internal view returns (uint64 n) {
        (n,) = hot.nonceOf(p);
    }

    function _raw(uint256 slot) internal view returns (bytes32) {
        return vm.load(k.proxy, bytes32(slot));
    }

    function _counts() internal view returns (uint64 a, uint64 r, uint64 b, uint64 p) {
        return hot.counts();
    }

    // ---- execution --------------------------------------------------------------------------------------------

    function _exec(Action[] memory a, bytes[] memory b) internal returns (uint64, uint64) {
        _track(principal, a);
        return ledger.execute(a, b, _native(_nonce(principal)), "");
    }

    /// As a key principal: `eoa` is both `msg.sender` and `tx.origin` (a code-less sender that is not the
    /// origin is refused `E_NATIVE_AMBIGUOUS`).
    function _execAs(address eoa, Action[] memory a, bytes[] memory b)
        internal
        returns (uint64, uint64)
    {
        bytes32 p = Keys.principal(eoa);
        _trackPrincipal(p);
        _track(p, a);
        uint64 n = _nonce(p);
        vm.prank(eoa, eoa);
        return ledger.execute(a, b, _native(n), "");
    }

    function _expectNoChange(Action[] memory a, bytes[] memory b, bytes memory err) internal {
        _expectNoChange(a, b, _native(_nonce(principal)), err);
    }

    /// The refused call reverts exactly `err` and leaves `digest()` and the lock unchanged.
    function _expectNoChange(
        Action[] memory a,
        bytes[] memory b,
        Native memory ctx,
        bytes memory err
    ) internal {
        _track(principal, a);
        bytes32 before = digest();
        vm.expectRevert(err);
        ledger.execute(a, b, ctx, "");
        _assertUnchanged(before);
    }

    /// A refused call under a gas bound, for errors whose arguments name measured gas: returns the revert data
    /// so the test decodes and bounds it; asserts the refusal changed nothing.
    function _refusedWithGas(Action[] memory a, bytes[] memory b, uint256 gas)
        internal
        returns (bytes memory err)
    {
        _track(principal, a);
        bytes32 before = digest();
        bool ok;
        (ok, err) = k.proxy.call{gas: gas}(
            abi.encodeCall(ILedger.execute, (a, b, _native(_nonce(principal)), ""))
        );
        assertFalse(ok, "expected a refusal");
        _assertUnchanged(before);
    }

    function _assertUnchanged(bytes32 before) internal view {
        assertEq(digest(), before, "a refused call changed state");
        (uint8 phase,,,) = hot.phase();
        assertEq(phase, Phase.IDLE, "the lock did not clear");
    }

    /// The arguments of a custom error after checking its selector.
    function _args(bytes memory err, bytes4 selector) internal pure returns (bytes memory out) {
        assertEq(err.length >= 4 ? bytes4(err) : bytes4(0), selector, "unexpected error selector");
        out = new bytes(err.length - 4);
        for (uint256 i; i < out.length; ++i) {
            out[i] = err[i + 4];
        }
    }

    // ---- digest -----------------------------------------------------------------------------------------------

    function _track(bytes32 p, Action[] memory a) internal {
        for (uint256 i; i < a.length; ++i) {
            uint8 kind = a[i].kind;
            if (kind == ActionKind.PUBLISH) {
                _push(trackedRecords, 1, Keys.recordFromHash(a[i].typeId, a[i].bodyHashOrRecordId));
            } else if (kind == ActionKind.REUSE) {
                _push(trackedRecords, 1, a[i].bodyHashOrRecordId);
            } else if (
                kind == ActionKind.BIND || kind == ActionKind.UNBIND || kind == ActionKind.RELEASE
            ) {
                bytes32 pos = Keys.position(a[i].purpose, a[i].subject, a[i].role);
                _push(trackedPositions, 2, pos);
                _push(trackedBindingKeys, 3, Keys.binding(p, pos));
            } else if (kind == ActionKind.CREATE) {
                _push(trackedSubjects, 4, Keys.subject(p, a[i].salt));
            }
        }
    }

    function _trackPrincipal(bytes32 p) internal {
        _push(trackedPrincipals, 5, p);
    }

    function _push(bytes32[] storage list, uint8 listId, bytes32 v) private {
        bytes32 tag = keccak256(abi.encode(listId, v));
        if (_seen[tag]) return;
        _seen[tag] = true;
        list.push(v);
    }

    /// `StateDigest.ledger` over every tracked key, the rows 1..frontier+4, evidence 1..publications+2, each
    /// tracked principal's publicationAt for nonces 0..nonce+1, plus the index double's prefix record.
    function digest() internal view returns (bytes32 h) {
        (uint64 admissions,, uint64 bindings, uint64 publications) = hot.counts();
        StateDigest.LedgerKeys memory key;
        key.recordIds = trackedRecords;
        key.subjectIds = trackedSubjects;
        key.admissionsThrough = admissions + 4;
        key.publicationsThrough = publications + 2;
        key.bindingKeys = trackedBindingKeys;
        key.positionKeys = trackedPositions;
        key.bindingOrdinalsThrough = bindings + 2;
        key.revisionsThrough = hot.revision() + 1;
        uint256 n;
        for (uint256 i; i < trackedPrincipals.length; ++i) {
            n += _nonce(trackedPrincipals[i]) + 2;
        }
        key.principalIds = new bytes32[](n);
        key.nonces = new uint64[](n);
        n = 0;
        for (uint256 i; i < trackedPrincipals.length; ++i) {
            uint64 top = _nonce(trackedPrincipals[i]) + 1;
            for (uint64 j; j <= top; ++j) {
                (key.principalIds[n], key.nonces[n]) = (trackedPrincipals[i], j);
                ++n;
            }
        }
        h = StateDigest.ledger(k.proxy, key);
        IndexDoubleCore d = IndexDoubleCore(index);
        h = keccak256(
            abi.encode(h, d.prefixCalls(), d.prefixDigest(), d.lastProcessed(), d.lastPublication())
        );
    }

    // ---- logs -------------------------------------------------------------------------------------------------

    /// The effects and refs the recording index logged, in order (RecordingIndex.EffectSeen).
    function _effects(Vm.Log[] memory logs)
        internal
        view
        returns (Effect[] memory effects, bytes32[] memory refs)
    {
        uint256 n;
        uint256 m;
        for (uint256 i; i < logs.length; ++i) {
            if (_isEffect(logs[i])) {
                (, bytes32[] memory r) = abi.decode(logs[i].data, (Effect, bytes32[]));
                ++n;
                m += r.length;
            }
        }
        effects = new Effect[](n);
        refs = new bytes32[](m);
        (n, m) = (0, 0);
        for (uint256 i; i < logs.length; ++i) {
            if (!_isEffect(logs[i])) continue;
            bytes32[] memory r;
            (effects[n++], r) = abi.decode(logs[i].data, (Effect, bytes32[]));
            for (uint256 j; j < r.length; ++j) {
                refs[m++] = r[j];
            }
        }
    }

    function _isEffect(Vm.Log memory l) private view returns (bool) {
        return l.emitter == index && l.topics.length != 0
            && l.topics[0] == RecordingIndex.EffectSeen.selector;
    }

    struct PublishedLog {
        bool found;
        uint64 publication;
        bytes32 publicationId;
        bytes32 principalId;
        uint8 proofKind;
        uint64 firstAdmission;
        uint8 leafCount;
        bytes32 effectsHash;
        uint32 revision;
    }

    function _published(Vm.Log[] memory logs) internal view returns (PublishedLog memory p) {
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (l.emitter != k.proxy || l.topics[0] != ILedger.Published.selector) continue;
            p.found = true;
            p.publication = uint64(uint256(l.topics[1]));
            p.publicationId = l.topics[2];
            p.principalId = l.topics[3];
            (p.proofKind, p.firstAdmission, p.leafCount, p.effectsHash, p.revision) =
                abi.decode(l.data, (uint8, uint64, uint8, bytes32, uint32));
        }
    }
}
