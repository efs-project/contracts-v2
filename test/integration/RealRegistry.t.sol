// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {KernelDeploy} from "../harness/KernelDeploy.sol";
import {LedgerReads} from "../../src/readers/LedgerReads.sol";
import {AdmissionRow} from "../../src/interfaces/Views.sol";
import {Status} from "../../src/interfaces/Results.sol";
import {IndexDeploy} from "../harness/IndexDeploy.sol";
import {Descriptors} from "../harness/Descriptors.sol";
import {Factory} from "../harness/doubles/Factory.sol";
import {AcceptAll, RejectAll} from "../harness/doubles/Acceptors.sol";
import {TypeRegistry} from "../../src/types/TypeRegistry.sol";
import {DescriptorStore} from "../../src/types/DescriptorStore.sol";
import {DescribedCodec} from "../../src/types/DescribedCodec.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {Action, ActionKind, FamilyId, Native, TypeId} from "../../src/interfaces/Actions.sol";
import {Coverage, Phase} from "../../src/interfaces/Results.sol";
import {ILedger} from "../../src/interfaces/ILedger.sol";
import {ILedgerHot} from "../../src/interfaces/ILedgerHot.sol";
import {ILedgerControl, ActivationSet} from "../../src/interfaces/ILedgerControl.sol";
import {ITypeRegistry, TypeInfo} from "../../src/interfaces/ITypeRegistry.sol";
import {DigestSpec, Unit} from "../../src/interfaces/Index.sol";
import {E_POLICY_REJECTED, E_REGISTRY, E_UNKNOWN_TYPE} from "../../src/interfaces/Errors.sol";

/// @notice The kernel, the real registry proxy and the real generation-1 index together: genesis with
///         `registry.activate(1)` in the ceremony, a NATIVE Type registered against its deterministic
///         instance, a publication validated through the real `typeInfo`, a policy activation that refuses
///         the next publish with the nonce intact (Falsify F3), and the no-policy row that sunsets it (F5a).
contract RealRegistryTest is Test {
    using Descriptors for Descriptors.Params;

    KernelDeploy.Kernel internal k;
    IndexDeploy.Gen1 internal g;
    DescriptorStore internal store;
    TypeRegistry internal registryImpl;
    TypeRegistry internal registry;
    ILedger internal ledger;
    ILedgerHot internal hot;
    LedgerReads internal reads;
    uint256 internal constant PK = 0xA11CE;
    address internal key;
    address internal instance;
    bytes32 internal initcodeHash;
    bytes32 internal typeId;
    bytes32 internal principal;

    function setUp() public {
        store = new DescriptorStore();
        registryImpl = new TypeRegistry(address(store));
        // the registry proxy must name the ledger proxy, which does not exist yet: predict it by nonce
        // (one creation for the registry proxy, four implementations, then the ledger proxy)
        address predictedLedger =
            vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 5);
        registry = TypeRegistry(
            address(
                new TransparentUpgradeableProxy(
                    address(registryImpl),
                    address(this),
                    abi.encodeCall(ITypeRegistry.initialize, (predictedLedger, address(0)))
                )
            )
        );
        k = KernelDeploy.deploy(address(this), address(registry), keccak256("salt"));
        assertEq(k.proxy, predictedLedger, "the ledger proxy landed where the registry expects it");
        ledger = ILedger(k.proxy);
        hot = ILedgerHot(k.proxy);
        g = IndexDeploy.deploy(k.proxy, KernelDeploy.HOT_ABI_ID, new Unit[](0), new DigestSpec[](0));
        // the ceremony: the registry records the revision first, then the ledger activates against it
        registry.activate(1);
        ILedgerControl(k.proxy)
            .activate(
                KernelDeploy.genesisSet(
                    k,
                    address(this),
                    address(registryImpl),
                    address(g.index),
                    g.index.manifestHash()
                )
            );
        key = vm.addr(PK);
        bytes memory initcode = type(AcceptAll).creationCode;
        initcodeHash = keccak256(initcode);
        instance = Factory.deploy(initcode);
        principal = Keys.principalFor(address(this), hot.realmOrigin());
        reads = new LedgerReads();
    }

    function _register() internal returns (bytes32 id) {
        bytes memory d = Descriptors.defaults(3, key, instance.codehash, initcodeHash).encode();
        (, bytes32[] memory refs) = this.parse(d);
        id = Keys.typeId(
            keccak256(abi.encode(Keys.DOM_DESCRIBED_SHAPE, d)), refs, instance.codehash
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PK, registry.declarationDigest(id));
        bytes memory sig = abi.encodePacked(r, s, v);
        store.put(d, sig);
        vm.prank(address(0xCAFE)); // anyone registers
        (bytes32 got,) = registry.registerDescribed(d, sig, instance, "");
        assertEq(got, id);
    }

    function parse(bytes calldata d)
        external
        pure
        returns (DescribedCodec.Header memory, bytes32[] memory)
    {
        return DescribedCodec.parse(d);
    }

    function _publish(bytes memory body, uint64 nonce) internal returns (uint64 publication) {
        Action[] memory actions = new Action[](1);
        actions[0].kind = ActionKind.PUBLISH;
        actions[0].typeId = typeId;
        actions[0].bodyHashOrRecordId = keccak256(body);
        bytes[] memory bodies = new bytes[](1);
        bodies[0] = body;
        Native memory ctx;
        ctx.nonce = nonce;
        (publication,) = ledger.execute(actions, bodies, ctx, "");
    }

    function testGenesisAgreesWithTheRegistry() public view {
        assertEq(hot.registry(), address(registry));
        assertEq(registry.ledger(), k.proxy);
        assertEq(registry.activeRevision(), 1);
        assertEq(registry.implementation(), address(registryImpl));
        assertEq(hot.revision(), 1);
        (uint8 phase,,,) = hot.phase();
        assertEq(phase, Phase.IDLE);
    }

    function testLedgerActivationNeedsTheRegistryRevision() public {
        // a second Realm whose registry has not recorded revision 1
        DescriptorStore s2 = new DescriptorStore();
        TypeRegistry impl2 = new TypeRegistry(address(s2));
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 5);
        TypeRegistry reg2 = TypeRegistry(
            address(
                new TransparentUpgradeableProxy(
                    address(impl2),
                    address(this),
                    abi.encodeCall(ITypeRegistry.initialize, (predicted, address(0)))
                )
            )
        );
        KernelDeploy.Kernel memory k2 =
            KernelDeploy.deploy(address(this), address(reg2), keccak256("two"));
        assertEq(k2.proxy, predicted);
        IndexDeploy.Gen1 memory g2 = IndexDeploy.deploy(k2.proxy, KernelDeploy.HOT_ABI_ID);
        ActivationSet memory set = KernelDeploy.genesisSet(
            k2, address(this), address(impl2), address(g2.index), g2.index.manifestHash()
        );
        vm.expectRevert(abi.encodeWithSelector(E_REGISTRY.selector, uint8(1)));
        ILedgerControl(k2.proxy).activate(set);
        reg2.activate(1);
        ILedgerControl(k2.proxy).activate(set);
        assertEq(ILedgerHot(k2.proxy).revision(), 1);
    }

    function testPublishThroughTheRealRegistryAndIndex() public {
        bytes memory body = "a record under a registered native type";
        // unknown until registered
        typeId = keccak256("not yet");
        Action[] memory actions = new Action[](1);
        actions[0].kind = ActionKind.PUBLISH;
        actions[0].typeId = typeId;
        actions[0].bodyHashOrRecordId = keccak256(body);
        bytes[] memory bodies = new bytes[](1);
        bodies[0] = body;
        Native memory ctx;
        vm.expectRevert(abi.encodeWithSelector(E_UNKNOWN_TYPE.selector, uint8(0), typeId));
        ledger.execute(actions, bodies, ctx, "");

        typeId = _register();
        assertEq(_publish(body, 0), 1);
        bytes32 recordId = Keys.recordFromHash(typeId, keccak256(body));
        (bytes32 t, uint64 fa,,,) = hot.recordHeader(recordId);
        assertEq(t, typeId);
        assertEq(fa, 1);
        (Coverage c, uint64 count,, uint64 last,) = g.index
        .postingHeadOf(FamilyId.wrap(Keys.familyId("by-type")), TypeId.wrap(typeId), 0, 0);
        assertEq(uint8(c), uint8(Coverage.COMPLETE));
        assertEq(count, 1);
        assertEq(last, 1);
        (, count,,,) = g.index
            .postingHeadOf(FamilyId.wrap(Keys.familyId("by-author")), TypeId.wrap(0), 0, principal);
        assertEq(count, 1);
        // the admission row records the implicit policy row
        (, AdmissionRow memory row) = reads.admission(k.proxy, 1);
        assertEq(row.kind, ActionKind.PUBLISH);
        assertEq(row.leaf, 0);
        assertEq(row.publication, 1);
        assertEq(row.policyRow, 1);
    }

    function testPolicyActivationRefusesThenSunsets() public {
        typeId = _register();
        _publish("one", 0);
        RejectAll rejectAll = new RejectAll();
        assertEq(registry.activatePolicy(typeId, address(rejectAll)), 2);
        assertEq(registry.mutations(), 2, "activate(1) and the policy");
        // the next publish is refused by the policy with the nonce intact (F3)
        Action[] memory actions = new Action[](1);
        actions[0].kind = ActionKind.PUBLISH;
        actions[0].typeId = typeId;
        actions[0].bodyHashOrRecordId = keccak256("two");
        bytes[] memory bodies = new bytes[](1);
        bodies[0] = "two";
        Native memory ctx;
        ctx.nonce = 1;
        vm.expectRevert(
            abi.encodeWithSelector(E_POLICY_REJECTED.selector, uint8(0), typeId, uint16(2))
        );
        ledger.execute(actions, bodies, ctx, "");
        (uint64 nonce,) = hot.nonceOf(principal);
        assertEq(nonce, 1);
        (uint64 admissions,,, uint64 publications) = hot.counts();
        assertEq(admissions, 1);
        assertEq(publications, 1);
        // REUSE of the existing record is judged by the same policy
        actions[0].kind = ActionKind.REUSE;
        actions[0].bodyHashOrRecordId = Keys.recordFromHash(typeId, keccak256("one"));
        bodies[0] = "";
        vm.expectRevert(
            abi.encodeWithSelector(E_POLICY_REJECTED.selector, uint8(0), typeId, uint16(2))
        );
        ledger.execute(actions, bodies, ctx, "");
        // the no-policy row sunsets it (F5a) and the row is recorded on the admission
        assertEq(registry.activatePolicy(typeId, address(0)), 3);
        assertEq(_publish("two", 1), 2);
        (, AdmissionRow memory row) = reads.admission(k.proxy, 2);
        assertEq(row.policyRow, 3);
        TypeInfo memory info = registry.typeInfo(typeId);
        assertEq(info.policyRow, 3);
        assertEq(info.policy, address(0));
    }

    function testRegistryObeysTheLedgersController() public {
        typeId = _register();
        vm.prank(address(0xBAD));
        vm.expectRevert();
        registry.activatePolicy(typeId, address(0));
        assertEq(hot.controller(), address(this));
    }
}
