// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {KernelDeploy} from "../KernelDeploy.sol";
import {IndexDeploy} from "../IndexDeploy.sol";
import {Descriptors} from "../Descriptors.sol";
import {StateDigest} from "../StateDigest.sol";
import {DescribedTypeRule} from "../../../src/types/DescribedTypeRule.sol";
import {TypeRegistry} from "../../../src/types/TypeRegistry.sol";
import {DescriptorStore} from "../../../src/types/DescriptorStore.sol";
import {DescribedCodec} from "../../../src/types/DescribedCodec.sol";
import {Keys} from "../../../src/lib/Keys.sol";
import {Action, ActionKind, FamilyId, Native, TypeId} from "../../../src/interfaces/Actions.sol";
import {Phase} from "../../../src/interfaces/Results.sol";
import {ILedger} from "../../../src/interfaces/ILedger.sol";
import {ILedgerHot} from "../../../src/interfaces/ILedgerHot.sol";
import {ILedgerControl} from "../../../src/interfaces/ILedgerControl.sol";
import {ITypeRegistry, TypeInfo} from "../../../src/interfaces/ITypeRegistry.sol";
import {AcceptContext, IAcceptor, RefHeader} from "../../../src/interfaces/IAcceptor.sol";
import {DigestSpec, Unit} from "../../../src/interfaces/Index.sol";
import {E_REJECTED} from "../../../src/interfaces/Errors.sol";

/// One Realm of the described-Type suites: its descriptor store, registry (proxy and implementation), kernel
/// and generation-1 index.
struct Realm {
    DescriptorStore store;
    TypeRegistry impl;
    TypeRegistry registry;
    KernelDeploy.Kernel k;
    IndexDeploy.Gen1 g;
}

/// @notice The described-Type fixture (design §5.10, §9): the kernel, the real registry proxy and the real
///         generation-1 index deployed exactly as `test/integration/RealRegistry.t.sol` does, with the real
///         `DescribedTypeRule` activated as wrapper version 1; descriptor builders, grade-1/2 registration,
///         publication through `ledger.execute`, and a refusal helper that proves the nonce and every touched
///         row are unchanged. The test contract is the author (a contract principal of each Realm).
abstract contract DescribedRealm is Test {
    using Descriptors for Descriptors.Params;

    uint256 internal constant PK = 0xA11CE;
    DescribedTypeRule internal rule;
    Realm internal a; // the primary Realm
    address internal key;
    uint256 private _namespaces;

    function setUp() public virtual {
        key = vm.addr(PK);
        rule = new DescribedTypeRule();
        a = _deployRealm(keccak256("described/primary"), rule);
    }

    /// Genesis with `registry.activate(1)` in the ceremony, then `activateWrapper(1, wrapper)`.
    function _deployRealm(bytes32 salt, DescribedTypeRule wrapper)
        internal
        returns (Realm memory x)
    {
        x.store = new DescriptorStore();
        x.impl = new TypeRegistry(address(x.store));
        // the registry proxy names the ledger proxy, created five creations later (four implementations)
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 5);
        x.registry = TypeRegistry(
            address(
                new TransparentUpgradeableProxy(
                    address(x.impl),
                    address(this),
                    abi.encodeCall(ITypeRegistry.initialize, (predicted, address(0)))
                )
            )
        );
        x.k = KernelDeploy.deploy(address(this), address(x.registry), salt);
        assertEq(x.k.proxy, predicted, "ledger proxy where the registry expects it");
        x.g = IndexDeploy.deploy(
            x.k.proxy, KernelDeploy.HOT_ABI_ID, new Unit[](0), new DigestSpec[](0)
        );
        x.registry.activate(1);
        ILedgerControl(x.k.proxy)
            .activate(
                KernelDeploy.genesisSet(
                    x.k,
                    address(this),
                    address(x.impl),
                    address(x.g.index),
                    x.g.index.manifestHash()
                )
            );
        x.registry.activateWrapper(1, address(wrapper));
    }

    // ---- views of the primary Realm ------------------------------------------------------------------------

    function ledger() internal view returns (ILedger) {
        return ILedger(a.k.proxy);
    }

    function hot() internal view returns (ILedgerHot) {
        return ILedgerHot(a.k.proxy);
    }

    function registry() internal view returns (TypeRegistry) {
        return a.registry;
    }

    function principalOf(Realm memory x) internal view returns (bytes32) {
        return Keys.principalFor(address(this), ILedgerHot(x.k.proxy).realmOrigin());
    }

    // ---- descriptors ---------------------------------------------------------------------------------------

    /// A codec-1 field row: id `n`, semantic `n + 100`.
    function _f(
        uint256 n,
        uint8 kind,
        uint8 optional,
        uint16 width,
        uint256 lo,
        uint256 hi,
        bytes32 ref
    ) internal pure returns (bytes memory) {
        return Descriptors.field(bytes32(n), bytes32(n + 100), kind, optional, width, lo, hi, ref);
    }

    /// Grade 1 or 2 against this wrapper build, in a fresh namespace (so equal fields never collide).
    function _params(uint8 grade, bytes32 customHash, bytes memory fields, uint8 count)
        internal
        returns (Descriptors.Params memory p)
    {
        p = Descriptors.defaults(grade, key, address(rule).codehash, customHash);
        p.namespace = keccak256(abi.encode("described/namespace", ++_namespaces));
        p.fields = fields;
        p.fieldCount = count;
    }

    function _structural(bytes memory fields, uint8 count) internal returns (bytes memory) {
        return _params(1, 0, fields, count).encode();
    }

    function _custom(address predicate, bytes memory fields, uint8 count)
        internal
        returns (bytes memory)
    {
        return _params(2, predicate.codehash, fields, count).encode();
    }

    /// One TEXT_LF field of 1..1024 bytes: the prototype's Note descriptor.
    function _textFields() internal pure returns (bytes memory) {
        return _f(1, DescribedCodec.KIND_TEXT_LF, 0, 0, 1, 1024, 0);
    }

    function parse(bytes calldata d)
        external
        pure
        returns (DescribedCodec.Header memory, bytes32[] memory)
    {
        return DescribedCodec.parse(d);
    }

    function _typeIdOf(bytes memory d) internal view returns (bytes32) {
        (DescribedCodec.Header memory h, bytes32[] memory refs) = this.parse(d);
        return Keys.typeId(keccak256(abi.encode(Keys.DOM_DESCRIBED_SHAPE, d)), refs, h.ruleCodehash);
    }

    function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// The creator's declaration signature, with the blob put in `x`'s store.
    function _declare(Realm memory x, bytes memory d)
        internal
        returns (bytes32 typeId, bytes memory sig)
    {
        typeId = _typeIdOf(d);
        sig = _sign(PK, x.registry.declarationDigest(typeId));
        x.store.put(d, sig);
    }

    /// The registry's binding preimage hash for `custom` in `x` (design §9.3).
    function _bindingId(Realm memory x, bytes32 typeId, address custom)
        internal
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                keccak256("efs2/described-binding/1"),
                address(rule).codehash,
                block.chainid,
                address(x.registry),
                typeId,
                custom,
                custom.codehash,
                uint256(1),
                key
            )
        );
    }

    function _register(Realm memory x, bytes memory d) internal returns (bytes32 typeId) {
        bytes memory sig;
        (typeId, sig) = _declare(x, d);
        (bytes32 got,) = x.registry.registerDescribed(d, sig, address(0), "");
        assertEq(got, typeId, "the registry derives the same id");
    }

    function _register(bytes memory d) internal returns (bytes32) {
        return _register(a, d);
    }

    function _registerCustom(Realm memory x, bytes memory d, address custom)
        internal
        returns (bytes32 typeId)
    {
        bytes memory sig;
        (typeId, sig) = _declare(x, d);
        bytes memory bindingSig = _sign(PK, x.registry.bindingDigest(_bindingId(x, typeId, custom)));
        (bytes32 got,) = x.registry.registerDescribed(d, sig, custom, bindingSig);
        assertEq(got, typeId, "the registry derives the same id");
    }

    // ---- publication -------------------------------------------------------------------------------------

    function _pub(bytes32 typeId, bytes memory body) internal pure returns (Action memory p) {
        p.kind = ActionKind.PUBLISH;
        p.typeId = typeId;
        p.bodyHashOrRecordId = keccak256(body);
    }

    function _reuse(bytes32 typeId, bytes32 recordId) internal pure returns (Action memory p) {
        p.kind = ActionKind.REUSE;
        p.typeId = typeId;
        p.bodyHashOrRecordId = recordId;
    }

    function _one(Action memory x) internal pure returns (Action[] memory l) {
        l = new Action[](1);
        l[0] = x;
    }

    function _two(Action memory x, Action memory y) internal pure returns (Action[] memory l) {
        l = new Action[](2);
        (l[0], l[1]) = (x, y);
    }

    function _bodies(bytes memory x) internal pure returns (bytes[] memory l) {
        l = new bytes[](1);
        l[0] = x;
    }

    function _bodies(bytes memory x, bytes memory y) internal pure returns (bytes[] memory l) {
        l = new bytes[](2);
        (l[0], l[1]) = (x, y);
    }

    function _native(Realm memory x) internal view returns (Native memory n) {
        (n.nonce,) = ILedgerHot(x.k.proxy).nonceOf(principalOf(x));
    }

    function _exec(Realm memory x, Action[] memory acts, bytes[] memory bodies)
        internal
        returns (uint64 publication)
    {
        (publication,) = ILedger(x.k.proxy).execute(acts, bodies, _native(x), "");
    }

    /// Publishes one body in `x`; returns its record id and asserts it landed and `by-type` folded it.
    function _publish(Realm memory x, bytes32 typeId, bytes memory body)
        internal
        returns (bytes32 recordId)
    {
        (, uint64 before,,,) = x.g.index
            .postingHeadOf(FamilyId.wrap(Keys.familyId("by-type")), TypeId.wrap(typeId), 0, 0);
        _exec(x, _one(_pub(typeId, body)), _bodies(body));
        recordId = Keys.recordFromHash(typeId, keccak256(body));
        (bytes32 t, uint64 first,,,) = ILedgerHot(x.k.proxy).recordHeader(recordId);
        assertEq(t, typeId, "the record landed under its Type");
        assertGt(first, 0, "the record has an admission");
        (, uint64 count,, uint64 last,) = x.g.index
            .postingHeadOf(FamilyId.wrap(Keys.familyId("by-type")), TypeId.wrap(typeId), 0, 0);
        assertEq(count, before + 1, "by-type folded the admission");
        (uint64 admissions,,,) = ILedgerHot(x.k.proxy).counts();
        assertEq(last, admissions, "by-type ends at the new admission");
    }

    function _publish(bytes32 typeId, bytes memory body) internal returns (bytes32) {
        return _publish(a, typeId, body);
    }

    /// The refused call reverts exactly `err`, and the nonce, the counts, every touched record, the next
    /// admission and publication rows, the `by-type` heads of the touched Types and the lock are unchanged.
    function _refused(Realm memory x, Action[] memory acts, bytes[] memory bodies, bytes memory err)
        internal
    {
        bytes32 before = _digest(x, acts);
        Native memory n = _native(x);
        vm.expectRevert(err);
        ILedger(x.k.proxy).execute(acts, bodies, n, "");
        assertEq(_digest(x, acts), before, "a refused publication changed state");
        (uint8 phase,,,) = ILedgerHot(x.k.proxy).phase();
        assertEq(phase, Phase.IDLE, "the lock cleared");
    }

    function _refused(Action[] memory acts, bytes[] memory bodies, bytes memory err) internal {
        _refused(a, acts, bodies, err);
    }

    /// One PUBLISH refused by the wrapper: `E_REJECTED(0, typeId)`.
    function _refuse(bytes32 typeId, bytes memory body) internal {
        _refused(_one(_pub(typeId, body)), _bodies(body), _rejected(0, typeId));
    }

    function _rejected(uint8 leaf, bytes32 typeId) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(E_REJECTED.selector, leaf, typeId);
    }

    // ---- the wrapper simulated directly (what the SDK does to read a refusal reason) ----------------------

    /// The context the ingress builds for leaf 0 of the next publication of `t` in `x`.
    function _ctxOf(Realm memory x, bytes32 t) internal view returns (AcceptContext memory c) {
        ILedgerHot l = ILedgerHot(x.k.proxy);
        TypeInfo memory info = x.registry.typeInfo(t);
        (uint64 admissions,,,) = l.counts();
        c = AcceptContext({
            typeId: t,
            realmId: l.realmId(),
            principalId: principalOf(x),
            admission: admissions + 1,
            revision: l.revision(),
            grade: info.grade,
            leaf: 0,
            ledger: x.k.proxy,
            index: l.index(),
            registry: address(x.registry),
            descriptorBlob: info.descriptorBlob,
            customPredicate: info.custom,
            bindingId: info.bindingId
        });
    }

    /// The reference headers the kernel loads (word0..2 are not read by the wrapper and stay zero here).
    function _headersOf(Realm memory x, bytes32[] memory refs)
        internal
        view
        returns (RefHeader[] memory h)
    {
        h = new RefHeader[](refs.length);
        for (uint256 i; i < refs.length; ++i) {
            (h[i].typeId, h[i].firstAdmission, h[i].length,,) =
                ILedgerHot(x.k.proxy).recordHeader(refs[i]);
        }
    }

    /// `rule.accept` called by `c.ledger` (pranked): the raw outcome.
    function _accept(
        AcceptContext memory c,
        bytes memory body,
        bytes32[] memory refs,
        RefHeader[] memory h
    ) internal returns (bool ok, bytes memory reply) {
        vm.prank(c.ledger);
        (ok, reply) = address(rule).call(abi.encodeCall(IAcceptor.accept, (c, body, refs, h)));
    }

    /// The wrapper, called as `c.ledger`, accepts (exactly the 32-byte selector word) or refuses with `err`.
    function _expectWrapper(
        AcceptContext memory c,
        bytes memory body,
        bytes32[] memory refs,
        RefHeader[] memory h,
        bytes memory err
    ) internal {
        (bool ok, bytes memory reply) = _accept(c, body, refs, h);
        if (err.length == 0) {
            assertTrue(ok, "the wrapper accepts");
            assertEq(reply, abi.encode(IAcceptor.accept.selector), "exactly the selector word");
        } else {
            assertFalse(ok, "the wrapper refuses");
            assertEq(reply, err, "the refusal reason");
        }
    }

    /// The wrapper's verdict on the next leaf-0 publication of `t` in the primary Realm, read directly.
    function _expectWrapper(bytes32 t, bytes memory body, bytes32[] memory refs, bytes memory err)
        internal
    {
        _expectWrapper(_ctxOf(a, t), body, refs, _headersOf(a, refs), err);
    }

    function _digest(Realm memory x, Action[] memory acts) internal view returns (bytes32 h) {
        ILedgerHot l = ILedgerHot(x.k.proxy);
        bytes32 p = principalOf(x);
        (uint64 nonce,) = l.nonceOf(p);
        (uint64 admissions,, uint64 bindings, uint64 publications) = l.counts();
        StateDigest.LedgerKeys memory keys;
        keys.recordIds = new bytes32[](acts.length);
        for (uint256 i; i < acts.length; ++i) {
            keys.recordIds[i] = acts[i].kind == ActionKind.PUBLISH
                ? Keys.recordFromHash(acts[i].typeId, acts[i].bodyHashOrRecordId)
                : acts[i].bodyHashOrRecordId;
            (, uint64 count,,,) = x.g.index
                .postingHeadOf(
                    FamilyId.wrap(Keys.familyId("by-type")), TypeId.wrap(acts[i].typeId), 0, 0
                );
            h = keccak256(abi.encode(h, count));
        }
        keys.admissionsThrough = admissions + 2;
        keys.publicationsThrough = publications + 2;
        keys.principalIds = new bytes32[](2);
        keys.nonces = new uint64[](2);
        (keys.principalIds[0], keys.nonces[0]) = (p, nonce);
        (keys.principalIds[1], keys.nonces[1]) = (p, nonce + 1);
        keys.bindingOrdinalsThrough = bindings + 1;
        keys.revisionsThrough = l.revision() + 1;
        h = keccak256(
            abi.encode(h, StateDigest.ledger(x.k.proxy, keys), nonce, admissions, publications)
        );
    }
}
