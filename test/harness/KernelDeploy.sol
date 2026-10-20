// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {LedgerCore} from "../../src/core/LedgerCore.sol";
import {LedgerApply} from "../../src/core/LedgerApply.sol";
import {LedgerIngress} from "../../src/core/LedgerIngress.sol";
import {LedgerControl} from "../../src/core/LedgerControl.sol";
import {Layout} from "../../src/core/layout/Layout.sol";
import {Limits} from "../../src/interfaces/Limits.sol";
import {RealmInit, ComponentSet, ActivationSet} from "../../src/interfaces/ILedgerControl.sol";
import {ILedgerControl} from "../../src/interfaces/ILedgerControl.sol";
import {ExecutionSets} from "./ExecutionSets.sol";

/// @notice Test-only deployer for the kernel vertical: the three delegates, the implementation, the
///         Transparent proxy (its ProxyAdmin owned by `controller`) and the genesis `initialize`, then a
///         helper that builds a genesis activation set against a registry and an index of the test's choice.
///         The real deployer (`RealmGenesis`, design §8.2) replaces this at S1.4; the S1 limits are the
///         design's §4.2 values.
library KernelDeploy {
    bytes32 internal constant HOT_ABI_ID = keccak256("efs2/ledger-hot/1:test");

    struct Kernel {
        LedgerIngress ingress;
        LedgerApply applyDelegate;
        LedgerControl control;
        LedgerCore implementation;
        address proxy;
    }

    function s1Limits() internal pure returns (Limits memory l) {
        l.maxActions = 64;
        l.maxBody = 8_192;
        l.maxRefs = 8;
        l.maxReadSetPrincipals = 64;
        l.maxReadSetPositions = 4;
        l.maxWitness = 4_096;
        l.maxTransitionBlocks = 7_200;
        l.inlineWordMax = 256;
        l.witnessRetention = 1;
        l.maxBindsPerPublication = 64;
        l.maxBodyBytesPerPublication = 16_384;
        l.maxFreshSlotsPerPublication = 600;
        l.maxReadIds = 64;
        l.maxReadCount = 256;
        l.floorFreshGas = 22_100;
        l.floorRewriteGas = 5_000;
        l.kernelTail = 20_000;
    }

    /// Deploys everything and initializes the proxy; `controller` becomes the ProxyAdmin owner and the
    /// realm's controller; `registry` is recorded in the realm. Writes stay disabled until `activate`.
    function deploy(address controller, address registry, bytes32 realmSalt)
        internal
        returns (Kernel memory k)
    {
        k.ingress = new LedgerIngress(address(0));
        k.applyDelegate = new LedgerApply();
        k.control = new LedgerControl(address(k.ingress), address(k.applyDelegate), bytes32(0));
        k.implementation = new LedgerCore(
            address(k.ingress), address(k.applyDelegate), address(k.control), HOT_ABI_ID
        );
        RealmInit memory init = RealmInit({
            realmSalt: realmSalt,
            controller: controller,
            registry: registry,
            readerDirectory: address(0),
            executionProfileId: 1,
            limits: s1Limits()
        });
        k.proxy = address(
            new TransparentUpgradeableProxy(
                address(k.implementation),
                controller,
                abi.encodeCall(ILedgerControl.initialize, (init))
            )
        );
    }

    /// The genesis set (revision 1) for a registry whose `implementation()` is `registryImpl` and an index
    /// whose `manifestHash()` is `manifestHash`; `expectedExecutionSet` is filled in.
    function genesisSet(
        Kernel memory k,
        address controller,
        address registryImpl,
        address index,
        bytes32 manifestHash
    ) internal view returns (ActivationSet memory set) {
        set.revision = 1;
        set.components = ComponentSet({
            ledgerImpl: address(k.implementation),
            ledgerImplCodehash: address(k.implementation).codehash,
            registryImpl: registryImpl,
            registryImplCodehash: registryImpl.codehash,
            index: index,
            indexCodehash: index.codehash,
            indexManifestHash: manifestHash,
            ingress: address(k.ingress),
            ingressCodehash: address(k.ingress).codehash,
            applyDelegate: address(k.applyDelegate),
            applyCodehash: address(k.applyDelegate).codehash,
            controller: controller,
            controllerCodehash: controller.codehash,
            controllerOwner: controller,
            steward: address(0),
            verifierProfilesRoot: bytes32(0)
        });
        set.layoutId = Layout.LAYOUT_ID;
        set.executionProfileId = 1;
        set.capabilities = 0;
        set.acceptedChainId = uint64(block.chainid);
        set.limits = s1Limits();
        set.dependencyRoot = bytes32(0);
        set.noticePrincipal = bytes32(0);
        set.migrationScope = new bytes32[](0);
        set.migration = "";
        set.expectedExecutionSet = ExecutionSets.executionSet(set, k.proxy);
    }
}
