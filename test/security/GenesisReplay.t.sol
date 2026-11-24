// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {KernelDeploy} from "../harness/KernelDeploy.sol";
import {RealmController} from "../../src/control/RealmController.sol";
import {RealmGenesis} from "../../src/control/RealmGenesis.sol";
import {TypeRegistry} from "../../src/types/TypeRegistry.sol";
import {DescriptorStore} from "../../src/types/DescriptorStore.sol";
import {Layout} from "../../src/core/layout/Layout.sol";
import {Limits} from "../../src/interfaces/Limits.sol";
import {ILedgerHot} from "../../src/interfaces/ILedgerHot.sol";
import {ILedgerControl, RealmInit} from "../../src/interfaces/ILedgerControl.sol";
import {ITypeRegistry} from "../../src/interfaces/ITypeRegistry.sol";
import {E_GENESIS} from "../../src/interfaces/Errors.sol";

/// @notice §2.2 S9 — genesis cannot be front-run, squatted or cycled. `RealmGenesis` is itself CREATE2-deployed
///         from its plan (so the plan fixes its address and a stranger can only re-create the same contract or
///         collide), it creates the controller and both proxies by its own nonces and initializes each proxy in
///         its creation, and nothing it creates takes authority from `msg.sender`. A stranger who runs the
///         plan first produces exactly the addresses and state the owner's run would have; a second run, or
///         an initializer call on either proxy, reverts.
/// @dev The `deploy/plan.json` file itself is replayed by the release tooling (`script/`, `tools/`), which is
///      in progress; this suite proves the contract-level property the plan relies on.
contract GenesisReplayTest is Test {
    address internal constant OWNER = address(0x0A11CE);
    address internal constant STRANGER = address(0x0BEEF);
    bytes32 internal constant SALT = keccak256("efs2/test/security/genesis/create2-salt");

    KernelDeploy.Kernel internal k;
    TypeRegistry internal registryImpl;
    Limits internal limits;

    function setUp() public {
        k = KernelDeploy.deployImplementations();
        registryImpl = new TypeRegistry(address(new DescriptorStore()));
        limits = KernelDeploy.s1Limits();
    }

    function _initcode(address owner_) internal view returns (bytes memory) {
        return bytes.concat(
            type(RealmGenesis).creationCode,
            abi.encode(
                owner_,
                address(k.implementation),
                address(registryImpl),
                keccak256("efs2/test/security/genesis/realm-salt"),
                uint16(1),
                keccak256(abi.encode(limits)),
                address(0),
                address(0),
                keccak256("efs2/test/security/genesis/notice"),
                keccak256(type(RealmController).creationCode),
                keccak256(type(TransparentUpgradeableProxy).creationCode)
            )
        );
    }

    /// Deploys the plan's RealmGenesis through the deterministic CREATE2 factory as `who`.
    function _deployGenesis(address who, bytes memory initcode)
        internal
        returns (bool ok, address created)
    {
        bytes memory ret;
        vm.prank(who);
        (ok, ret) = CREATE2_FACTORY.call{gas: 10_000_000}(abi.encodePacked(SALT, initcode)); // a collision burns what it is given
        if (ok && ret.length == 20) created = address(bytes20(ret));
    }

    function _run(RealmGenesis genesis, address who) internal {
        vm.prank(who, who);
        genesis.run(
            limits,
            type(RealmController).creationCode,
            type(TransparentUpgradeableProxy).creationCode
        );
    }

    /// Everything a genesis run fixes: the three addresses, the controller's owner and wiring, both admins and
    /// their owners, the registry's wiring, and the ledger's sixteen realm words.
    function _state(RealmGenesis genesis) internal view returns (bytes memory s) {
        RealmController c = RealmController(genesis.controller());
        address l = genesis.ledgerProxy();
        address r = genesis.registryProxy();
        (address la, address ra) = c.admins();
        s = abi.encode(
            address(c),
            r,
            l,
            c.owner(),
            c.pendingOwner(),
            c.ledger(),
            c.registryProxy(),
            la,
            ra,
            ProxyAdmin(la).owner(),
            ProxyAdmin(ra).owner()
        );
        s = bytes.concat(
            s,
            abi.encode(
                ITypeRegistry(r).ledger(),
                ITypeRegistry(r).activeRevision(),
                ITypeRegistry(r).implementation(),
                ILedgerHot(l).controller(),
                ILedgerHot(l).registry(),
                ILedgerHot(l).revision()
            )
        );
        for (uint256 i; i < 16; ++i) {
            s = bytes.concat(
                s, ILedgerHot(l).extsload(bytes32(uint256(Layout.LEDGER_REALM_ROOT) + i))
            );
        }
    }

    function test_stranger_replay_yields_identical_addresses_and_state_or_reverts() public {
        bytes memory initcode = _initcode(OWNER);
        address predicted = vm.computeCreate2Address(SALT, keccak256(initcode), CREATE2_FACTORY);

        // the plan's RealmGenesis lands at the predicted address whoever submits it; a re-submission collides
        (bool ok, address created) = _deployGenesis(STRANGER, initcode);
        assertTrue(ok, "factory deployment");
        assertEq(created, predicted, "the plan fixes the genesis address");
        (ok,) = _deployGenesis(OWNER, initcode);
        assertFalse(ok, "a replayed deployment collides instead of squatting");
        // a stranger's plan with itself as owner is a different contract at a different address
        (, address squat) = _deployGenesis(STRANGER, _initcode(STRANGER));
        assertTrue(squat != predicted && squat != address(0));

        RealmGenesis genesis = RealmGenesis(predicted);
        (address pc, address pr, address pl) = genesis.predict();
        uint256 snap = vm.snapshotState();
        _run(genesis, OWNER);
        bytes memory byOwner = _state(genesis);
        vm.revertToState(snap);
        _run(genesis, STRANGER);
        bytes memory byStranger = _state(genesis);
        assertEq(byStranger, byOwner, "a stranger's run equals the owner's");
        assertEq(
            abi.encode(genesis.controller(), genesis.registryProxy(), genesis.ledgerProxy()),
            abi.encode(pc, pr, pl)
        );
        assertEq(
            RealmController(pc).owner(), OWNER, "authority comes from the plan, not the runner"
        );

        // single use, for anyone
        vm.expectRevert(abi.encodeWithSelector(E_GENESIS.selector, uint8(0)));
        _run(genesis, OWNER);
        vm.expectRevert(abi.encodeWithSelector(E_GENESIS.selector, uint8(0)));
        _run(genesis, STRANGER);

        // no initializer is left to front-run: both proxies were initialized in their creation
        RealmInit memory init;
        init.controller = STRANGER;
        init.registry = STRANGER;
        init.limits = limits;
        vm.prank(STRANGER);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        ILedgerControl(pl).initialize(init);
        vm.prank(STRANGER);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        ITypeRegistry(pr).initialize(STRANGER, address(0));
        assertEq(ILedgerHot(pl).controller(), pc);
        assertEq(ITypeRegistry(pr).ledger(), pl);
    }
}
