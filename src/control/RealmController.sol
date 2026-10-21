// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {
    ITransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Layout} from "../core/layout/Layout.sol";
import {Keys} from "../lib/Keys.sol";
import {CodePins} from "../lib/CodePins.sol";
import {CodeScan} from "../lib/CodeScan.sol";
import {Action, ActionKind, Capability, Native, Purpose, ReadSet} from "../interfaces/Actions.sol";
import {Phase} from "../interfaces/Results.sol";
import {ClosureConstants} from "../interfaces/Limits.sol";
import {ILedger} from "../interfaces/ILedger.sol";
import {ILedgerHot} from "../interfaces/ILedgerHot.sol";
import {ILedgerControl, ActivationSet, ComponentSet} from "../interfaces/ILedgerControl.sol";
import {ILedgerCommitments} from "../interfaces/ILedgerCommitments.sol";
import {ITypeRegistry} from "../interfaces/ITypeRegistry.sol";
import {IRealmIndex} from "../interfaces/IRealmIndex.sol";
import {IRealmController} from "../interfaces/IRealmController.sol";
import {
    E_CANARY,
    E_CONTROLLER,
    E_EXPECTED_SET,
    E_FREEZE_PRECHECK,
    E_FROZEN,
    E_NOT_IDLE,
    E_NOT_OWNER,
    E_PENDING,
    E_RETIRED,
    E_SUCCESSOR
} from "../interfaces/Errors.sol";

/// @title RealmController — a Realm's controller (design §5.12, §8.3–§8.5, §8.10)
/// @notice Hand-rolled two-step ownership; owns both ProxyAdmins; the only paths that change an
///         implementation are the activation family, each writing a revision row before returning. No
///         ProxyAdmin passthrough: `upgradeAndCall` inside an activation, `transferOwnership` inside
///         `migrate`, `renounceOwnership` inside `freeze`. Ownership changes only through an activation; the
///         owner is zeroed only inside `freeze`. A controller replaced by `migrate` is retired for good.
/// @dev Immutable; its runtime is pinned by `controllerCodehash` in the execution set and scanned plain at
///      `migrate`. The ProxyAdmin addresses are the proxies' first creations (OZ 5 creates the admin in
///      the proxy constructor), so they are known from the predicted proxy addresses at construction.
contract RealmController is IRealmController {
    address public immutable LEDGER;
    address public immutable REGISTRY;
    address public immutable LEDGER_ADMIN;
    address public immutable REGISTRY_ADMIN;
    /// The realm-notice/1 Type the freeze canary publishes (deterministic, so known before genesis).
    bytes32 public immutable NOTICE_TYPE;
    bytes32 private constant IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    address private _owner;
    address private _pendingOwner;
    bool private _frozen;
    bool private _retired;

    constructor(address owner_, address ledger_, address registry_, bytes32 noticeType) {
        _owner = owner_;
        LEDGER = ledger_;
        REGISTRY = registry_;
        LEDGER_ADMIN = _firstCreation(ledger_);
        REGISTRY_ADMIN = _firstCreation(registry_);
        NOTICE_TYPE = noticeType;
    }

    // =============================================================================================
    // Gates
    // =============================================================================================

    modifier onlyOwner() {
        if (msg.sender != _owner) revert E_NOT_OWNER(msg.sender);
        _;
    }

    modifier live() {
        if (_frozen) revert E_FROZEN();
        if (_retired) revert E_RETIRED();
        _;
    }

    // =============================================================================================
    // Activations (design §8.3)
    // =============================================================================================

    /// @inheritdoc IRealmController
    function activate(ActivationSet calldata set) external live onlyOwner {
        _checkSet(set.components, address(this), _owner);
        _activate(set, false);
    }

    /// @inheritdoc IRealmController
    function transferOwnership(address pending) external live onlyOwner {
        _pendingOwner = pending;
    }

    /// @inheritdoc IRealmController
    function acceptOwnershipAndActivate(ActivationSet calldata set) external live {
        address pending = _pendingOwner;
        if (msg.sender != pending || pending == address(0)) revert E_PENDING(pending);
        address previous = _owner;
        _owner = pending;
        _pendingOwner = address(0);
        _checkSet(set.components, address(this), pending);
        _activate(set, false);
        emit OwnershipActivated(previous, pending, set.revision);
    }

    /// @inheritdoc IRealmController
    function migrate(address successor, ActivationSet calldata set) external live onlyOwner {
        CodePins.requireRealCode(successor);
        CodeScan.requirePlainRuntime(successor);
        if (successor.codehash != set.components.controllerCodehash) revert E_SUCCESSOR(1);
        if (set.components.controller != successor) revert E_SUCCESSOR(2);
        if (set.components.controllerOwner != IRealmController(successor).owner()) {
            revert E_SUCCESSOR(3);
        }
        // a successor that could never act would strand the control plane for good
        if (successor == address(this)) revert E_SUCCESSOR(5);
        if (IRealmController(successor).retired() || IRealmController(successor).frozen()) {
            revert E_SUCCESSOR(6);
        }
        if (IRealmController(successor).ledger() != LEDGER) revert E_SUCCESSOR(7);
        if (IRealmController(successor).registryProxy() != REGISTRY) revert E_SUCCESSOR(8);
        _activate(set, false);
        ProxyAdmin(LEDGER_ADMIN).transferOwnership(successor);
        ProxyAdmin(REGISTRY_ADMIN).transferOwnership(successor);
        if (
            ProxyAdmin(LEDGER_ADMIN).owner() != successor
                || ProxyAdmin(REGISTRY_ADMIN).owner() != successor
        ) {
            revert E_SUCCESSOR(4);
        }
        _retired = true;
        emit ControllerMigrated(successor, set.revision);
    }

    /// Steps 1–6 of §8.3: idle, optional implementation upgrades, the registry's activation, the ledger's
    /// activation (or freeze), and the execution-set agreement.
    function _activate(ActivationSet calldata set, bool freezing) private {
        _requireIdle();
        ComponentSet calldata c = set.components;
        if (_ledgerImplementation() != c.ledgerImpl) {
            ProxyAdmin(LEDGER_ADMIN)
                .upgradeAndCall(ITransparentUpgradeableProxy(LEDGER), c.ledgerImpl, "");
        }
        if (ITypeRegistry(REGISTRY).implementation() != c.registryImpl) {
            ProxyAdmin(REGISTRY_ADMIN)
                .upgradeAndCall(ITransparentUpgradeableProxy(REGISTRY), c.registryImpl, "");
        }
        ITypeRegistry(REGISTRY).activate(set.revision);
        if (freezing) ILedgerControl(LEDGER).freeze(set);
        else ILedgerControl(LEDGER).activate(set);
        bytes32 liveSet = ILedgerHot(LEDGER).executionSet();
        if (liveSet != set.expectedExecutionSet) {
            revert E_EXPECTED_SET(set.expectedExecutionSet, liveSet);
        }
    }

    /// §8.3 step 0.
    function _checkSet(ComponentSet calldata c, address controller, address owner_) private view {
        if (c.controller != controller) revert E_CONTROLLER(1);
        if (c.controllerCodehash != controller.codehash) revert E_CONTROLLER(2);
        if (c.controllerOwner != owner_) revert E_CONTROLLER(3);
    }

    function _requireIdle() private view {
        (uint8 phase,,,) = ILedgerHot(LEDGER).phase();
        if (phase != Phase.IDLE) revert E_NOT_IDLE();
    }

    // =============================================================================================
    // Transitions (design §8.8)
    // =============================================================================================

    /// @inheritdoc IRealmController
    function beginTransition(uint32 targetRevision, uint48 deadlineBlock) external live onlyOwner {
        ILedgerControl(LEDGER).beginTransition(targetRevision, deadlineBlock);
    }

    /// @inheritdoc IRealmController
    function abortTransition() external live {
        (, uint48 deadline,,) = Layout.unpackRealmStorageWord15(
            ILedgerHot(LEDGER).extsload(bytes32(uint256(Layout.LEDGER_REALM_ROOT) + 15))
        );
        if (deadline >= block.number && msg.sender != _owner) revert E_NOT_OWNER(msg.sender);
        ILedgerControl(LEDGER).abortTransition();
    }

    // =============================================================================================
    // Freeze (design §8.10)
    // =============================================================================================

    /// @inheritdoc IRealmController
    function freeze(ActivationSet calldata finalSet, bytes[] calldata laneCanaries)
        external
        live
        onlyOwner
    {
        ILedgerHot hot = ILedgerHot(LEDGER);
        // 1. the controller's pre-checks (the ledger runs 1, 4, 5, 6, 7, 8 itself)
        if (finalSet.components.index != hot.index()) {
            if (!IRealmIndex(finalSet.components.index).replayReadiness().ready) {
                revert E_FREEZE_PRECHECK(2);
            }
        }
        _requireIdle(); // (3)
        uint16 lanes = finalSet.capabilities & (Capability.SIGNED_SECP256K1 | Capability.ERC1271);
        uint256 expectedCanaries = (lanes & Capability.SIGNED_SECP256K1 != 0 ? 1 : 0)
            + (lanes & Capability.ERC1271 != 0 ? 1 : 0);
        if (laneCanaries.length != expectedCanaries) revert E_FREEZE_PRECHECK(9);
        // 2–6
        _checkSet(finalSet.components, address(this), _owner);
        _activate(finalSet, true);
        // 7. canaries: one real publication per enabled lane through every write-path dependency
        uint64[] memory canaries = new uint64[](1 + laneCanaries.length);
        canaries[0] = _nativeCanary(hot, finalSet);
        uint256 n = 1;
        if (lanes & Capability.SIGNED_SECP256K1 != 0) {
            canaries[n++] = _signedCanary(laneCanaries[0], 1);
        }
        if (lanes & Capability.ERC1271 != 0) {
            canaries[n] = _signedCanary(laneCanaries[laneCanaries.length - 1], 2);
        }
        // 8–9. renounce everything
        ProxyAdmin(LEDGER_ADMIN).renounceOwnership();
        ProxyAdmin(REGISTRY_ADMIN).renounceOwnership();
        _owner = address(0);
        _pendingOwner = address(0);
        _frozen = true;
        (uint64 admissions,,,) = hot.counts();
        emit Frozen(finalSet.revision, hot.executionSet(), admissions, canaries);
    }

    /// The native canary: PUBLISH realm-notice/1 {frozen, revision} as this controller's contract principal,
    /// bound to the terminal execution set, carrying a one-entry read set over its own UNSET head when the
    /// guard capability is enabled so the guard codec is exercised too.
    function _nativeCanary(ILedgerHot hot, ActivationSet calldata finalSet)
        private
        returns (uint64 publication)
    {
        bytes32 principal = Keys.contractPrincipal(hot.realmOrigin(), address(this));
        (uint64 nonce,) = hot.nonceOf(principal);
        Action[] memory actions = new Action[](1);
        bytes[] memory bodies = new bytes[](1);
        bodies[0] =
            abi.encode(ClosureConstants.NOTICE_FROZEN, uint256(finalSet.revision), bytes(""));
        actions[0].kind = ActionKind.PUBLISH;
        actions[0].typeId = NOTICE_TYPE;
        actions[0].bodyHashOrRecordId = keccak256(bodies[0]);
        Native memory ctx;
        ctx.nonce = nonce;
        ctx.expectedExecutionSet = finalSet.expectedExecutionSet;
        bytes memory guard;
        if (finalSet.capabilities & Capability.NATIVE_GUARD != 0) {
            ReadSet memory rs;
            rs.principals = new bytes32[](1);
            rs.principals[0] = principal;
            rs.positions = new bytes32[](1);
            rs.positions[0] =
                Keys.position(Purpose.HEAD, keccak256("efs2/notice/canary/1"), bytes32(0));
            rs.expectedHeads = new bytes32[](1);
            rs.expectedHeads[0] =
                ILedgerCommitments(hot.ingress()).headSnapshotHash(0, 0, 0, bytes32(0));
            guard = abi.encode(rs);
        }
        try ILedger(LEDGER).execute(actions, bodies, ctx, guard) returns (uint64 p, uint64) {
            publication = p;
        } catch {
            revert E_CANARY(0);
        }
    }

    /// A pre-signed `executeSigned` calldata for lane 1 (secp256k1) or 2 (ERC-1271).
    function _signedCanary(bytes calldata canary, uint8 lane) private returns (uint64 publication) {
        if (canary.length < 4 || bytes4(canary[0:4]) != ILedger.executeSigned.selector) {
            revert E_CANARY(lane);
        }
        (bool ok, bytes memory ret) = LEDGER.call(canary);
        if (!ok || ret.length < 64) revert E_CANARY(lane);
        (publication,) = abi.decode(ret, (uint64, uint64));
        // the publication must be the lane it claims (proof kind 2 secp256k1, 3 ERC-1271) and must have
        // published a realm-notice record: a canary proves its own lane, not any lane
        ILedgerHot hot = ILedgerHot(LEDGER);
        (, uint8 proofKind,,,, uint48 first,) = Layout.unpackEvidenceCellWord0(
            hot.extsload(bytes32(Layout.publicationsEvidenceSlot(publication)))
        );
        if (proofKind != lane + 1) revert E_CANARY(lane);
        bytes32 recordId = hot.extsload(bytes32(Layout.admissionsRowsSlot(first) + 1));
        if (hot.extsload(bytes32(Layout.recordsCellsSlot(recordId))) != NOTICE_TYPE) {
            revert E_CANARY(lane);
        }
    }

    // =============================================================================================
    // Registry activations (design §9.4): forwarded; the registry gates on the ledger's phase and flag
    // =============================================================================================

    /// @inheritdoc IRealmController
    function activatePolicy(bytes32 typeId, address acceptor) external live onlyOwner {
        ITypeRegistry(REGISTRY).activatePolicy(typeId, acceptor);
    }

    /// @inheritdoc IRealmController
    function declareRoleExpectation(bytes32 purpose, bytes32 role, bytes32 expectedType)
        external
        live
        onlyOwner
    {
        ITypeRegistry(REGISTRY).declareRoleExpectation(purpose, role, expectedType);
    }

    /// @inheritdoc IRealmController
    function activateWrapper(uint8 version, address implementation) external live onlyOwner {
        ITypeRegistry(REGISTRY).activateWrapper(version, implementation);
    }

    // =============================================================================================
    // Views
    // =============================================================================================

    function owner() external view returns (address) {
        return _owner;
    }

    function pendingOwner() external view returns (address) {
        return _pendingOwner;
    }

    function frozen() external view returns (bool) {
        return _frozen;
    }

    function retired() external view returns (bool) {
        return _retired;
    }

    function ledger() external view returns (address) {
        return LEDGER;
    }

    function registryProxy() external view returns (address) {
        return REGISTRY;
    }

    function admins() external view returns (address ledgerAdmin, address registryAdmin) {
        return (LEDGER_ADMIN, REGISTRY_ADMIN);
    }

    function _ledgerImplementation() private view returns (address) {
        return address(uint160(uint256(ILedgerHot(LEDGER).extsload(IMPLEMENTATION_SLOT))));
    }

    /// The address of `deployer`'s first creation (nonce 1): RLP([deployer, 1]) = 0xd6 0x94 ‖ deployer ‖ 0x01.
    function _firstCreation(address deployer) private pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(hex"d694", deployer, hex"01")))));
    }
}
