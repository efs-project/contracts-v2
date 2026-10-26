// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {KernelDeploy} from "../harness/KernelDeploy.sol";
import {IndexDeploy} from "../harness/IndexDeploy.sol";
import {ExecutionSets} from "../harness/ExecutionSets.sol";
import {Descriptors} from "../harness/Descriptors.sol";
import {Factory} from "../harness/doubles/Factory.sol";
import {LedgerReads} from "../../src/readers/LedgerReads.sol";
import {TypeRegistry} from "../../src/types/TypeRegistry.sol";
import {DescriptorStore} from "../../src/types/DescriptorStore.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {ILedger} from "../../src/interfaces/ILedger.sol";
import {ILedgerHot} from "../../src/interfaces/ILedgerHot.sol";
import {ILedgerCommitments} from "../../src/interfaces/ILedgerCommitments.sol";
import {ILedgerControl, ActivationSet} from "../../src/interfaces/ILedgerControl.sol";
import {ITypeRegistry} from "../../src/interfaces/ITypeRegistry.sol";
import {DigestSpec, Unit} from "../../src/interfaces/Index.sol";
import {NativeApp, NativeAppRule} from "../../examples/NativeApp.sol";

/// @notice The consumer suites' Realm: the kernel, the real registry proxy and the real generation-1 index
///         (the `RealRegistryTest` set-up), the EIP-7997 factory etched, and the signed declaration of the
///         example's NATIVE Type (`NativeAppRule` at its deterministic instance). Abstract: no tests here.
abstract contract ConsumerFixture is Test {
    using Descriptors for Descriptors.Params;

    uint256 internal constant DECLARATION_PK = 0xA11CE;
    bytes32 internal constant FOLDER = keccak256("efs2/purpose/folder/1");
    bytes32 internal constant ROLE = keccak256("efs2/test/consumer/role/name");

    KernelDeploy.Kernel internal k;
    IndexDeploy.Gen1 internal g;
    DescriptorStore internal store;
    TypeRegistry internal registryImpl;
    TypeRegistry internal registry;
    ILedger internal ledger;
    ILedgerHot internal hot;
    ILedgerCommitments internal commitments;
    LedgerReads internal reads;
    bytes32 internal origin;

    bytes internal descriptor;
    bytes internal declarationSig;
    bytes32 internal appTypeId;
    bytes32 internal ruleInitcodeHash;

    function setUp() public virtual {
        store = new DescriptorStore();
        registryImpl = new TypeRegistry(address(store));
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
        k = KernelDeploy.deploy(address(this), address(registry), keccak256("efs2/test/consumer"));
        require(k.proxy == predictedLedger, "ledger prediction");
        ledger = ILedger(k.proxy);
        hot = ILedgerHot(k.proxy);
        commitments = ILedgerCommitments(address(k.ingress));
        g = IndexDeploy.deploy(k.proxy, KernelDeploy.HOT_ABI_ID, new Unit[](0), new DigestSpec[](0));
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
        reads = new LedgerReads();
        origin = hot.realmOrigin();
        Factory.ensure();
        _declare();
    }

    /// The example Type's descriptor (grade 3 NATIVE: ruleCodehash = the rule's runtime hash, aux = its
    /// initcode hash) and the declaration key's signature over the registry's declaration digest.
    function _declare() internal {
        ruleInitcodeHash = keccak256(type(NativeAppRule).creationCode);
        bytes32 runtimeHash = keccak256(type(NativeAppRule).runtimeCode);
        descriptor = Descriptors.defaults(3, vm.addr(DECLARATION_PK), runtimeHash, ruleInitcodeHash)
            .encode();
        appTypeId = Keys.typeId(
            keccak256(abi.encode(Keys.DOM_DESCRIBED_SHAPE, descriptor)),
            new bytes32[](0),
            runtimeHash
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(DECLARATION_PK, registry.declarationDigest(appTypeId));
        declarationSig = abi.encodePacked(r, s, v);
    }

    function _newApp(uint64 quota) internal returns (NativeApp) {
        return new NativeApp(ledger, descriptor, declarationSig, quota);
    }

    function _principalOf(address account) internal view returns (bytes32) {
        return Keys.principalFor(account, origin);
    }

    function _nonce(bytes32 principalId) internal view returns (uint64 n) {
        (n,) = hot.nonceOf(principalId);
    }

    function _headKey(bytes32 principalId, bytes32 subject, bytes32 role)
        internal
        pure
        returns (bytes32)
    {
        return Keys.binding(principalId, Keys.position(FOLDER, subject, role));
    }

    /// Activates revision + 1 with the same components: the execution set changes (it commits to the
    /// revision ordinal), nothing else does.
    function _activateNext() internal returns (bytes32 executionSet) {
        uint32 rev = hot.revision() + 1;
        registry.activate(rev);
        ActivationSet memory set = KernelDeploy.genesisSet(
            k, address(this), address(registryImpl), address(g.index), g.index.manifestHash()
        );
        set.revision = rev;
        set.expectedExecutionSet = ExecutionSets.executionSet(set, k.proxy);
        ILedgerControl(k.proxy).activate(set);
        executionSet = hot.executionSet();
        require(executionSet == set.expectedExecutionSet, "activated set");
    }
}
