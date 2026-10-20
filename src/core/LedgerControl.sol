// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {LedgerStorage} from "./storage/LedgerStorage.sol";
import {Layout} from "./layout/Layout.sol";
import {Keys} from "../lib/Keys.sol";
import {CodePins} from "../lib/CodePins.sol";
import {CodeScan} from "../lib/CodeScan.sol";
import {Phase} from "../interfaces/Results.sol";
import {Limits} from "../interfaces/Limits.sol";
import {ILedgerHot} from "../interfaces/ILedgerHot.sol";
import {
    ILedgerControl,
    RealmInit,
    ComponentSet,
    ActivationSet
} from "../interfaces/ILedgerControl.sol";
import {ITypeRegistry} from "../interfaces/ITypeRegistry.sol";
import {IRealmIndex} from "../interfaces/IRealmIndex.sol";
import {IPostingStore} from "../interfaces/IPostingStore.sol";
import {FamilyEntry, Readiness, Unit} from "../interfaces/Index.sol";
import {ILedgerControlDelegate} from "../interfaces/internal/ILedgerControlDelegate.sol";
import {
    E_DEADLINE_BOUND,
    E_DELEGATE_ONLY,
    E_EXPECTED_SET,
    E_FREEZE_PRECHECK,
    E_HOT_ABI,
    E_IMPLEMENTATION,
    E_INDEX_NOT_READY,
    E_LAYOUT,
    E_MIGRATION_SCOPE,
    E_NOT_CONTROLLER,
    E_PIN,
    E_REGISTRY,
    E_REVISION,
    E_TRANSITION,
    E_TRANSITION_COOLDOWN,
    E_TRANSITION_TARGET
} from "../interfaces/Errors.sol";

interface IOwnable {
    function owner() external view returns (address);
}

/// @title LedgerControl — the genesis, activation, freeze and transition writer (design §8)
/// @notice Runs only by DELEGATECALL in the kernel's context after the kernel's wrappers applied the
///         controller, idle, initializer and frozen gates; carries the same selectors as `ILedgerControl`
///         so the kernel forwards `msg.data` verbatim. Writes `efs.ledger.v2.{realm,revisions}` and the
///         transition word. Pinned by the kernel implementation's CONTROL / CONTROL_CODEHASH immutables.
contract LedgerControl is ILedgerControlDelegate, LedgerStorage {
    address private immutable SELF = address(this);
    address public immutable INGRESS;
    bytes32 public immutable INGRESS_CODEHASH;
    address public immutable APPLY;
    bytes32 public immutable APPLY_CODEHASH;
    bytes32 public immutable PREDECESSOR_LAYOUT_ID;
    bytes32 public constant LAYOUT_ID = Layout.LAYOUT_ID;

    bytes32 private constant IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 private constant ADMIN_SLOT =
        0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
    bytes32 private constant DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    bytes32 private constant DOMAIN_NAME = keccak256("EFS");
    bytes32 private constant DOMAIN_VERSION = keccak256("2");
    uint64 private constant NOT_MAINTAINED = type(uint64).max;
    uint8 private constant SHAPE_APPEND = 1;
    uint16 private constant REV_FROZEN = 1 << 0;
    uint16 private constant REV_SAME_CODE = 1 << 1;
    uint16 private constant REV_CHAIN = 1 << 2;
    uint16 private constant REV_CONTROLLER = 1 << 3;
    uint16 private constant REV_OWNER = 1 << 4;
    uint16 private constant REV_INDEX = 1 << 5;
    uint16 private constant REV_LAYOUT = 1 << 6;
    uint16 private constant REV_LIMITS = 1 << 7;

    constructor(address ingress_, address apply_, bytes32 predecessorLayoutId) {
        INGRESS = ingress_;
        INGRESS_CODEHASH = ingress_.codehash;
        APPLY = apply_;
        APPLY_CODEHASH = apply_.codehash;
        PREDECESSOR_LAYOUT_ID = predecessorLayoutId;
    }

    modifier delegateOnly() {
        if (address(this) == SELF) revert E_DELEGATE_ONLY();
        _;
    }

    // ---- genesis (design §8.2 step G18.3) -------------------------------------------------------------

    /// @inheritdoc ILedgerControl
    function initialize(RealmInit calldata init) external delegateOnly {
        RealmStorage storage $ = _realm();
        $.realmSalt = init.realmSalt;
        $.controller = init.controller;
        $.registry = init.registry;
        $.readerDirectory = init.readerDirectory;
        $.executionProfileId = init.executionProfileId;
        $.genesisExecutionProfileId = init.executionProfileId;
        $.genesisChainId = uint64(block.chainid);
        $.acceptedChainId = uint64(block.chainid);
        $.realmOrigin = Keys.realmOrigin(uint64(block.chainid), address(this), init.realmSalt);
        $.realmId = Keys.realmId($.realmOrigin, init.executionProfileId);
        $.layoutId = LAYOUT_ID;
        $.limits = init.limits;
        $.limitsProfileId = keccak256(abi.encode(init.limits));
        // writes are disabled until the genesis activation clears this transition
        $.transitionTarget = 1;
        $.transitionDeadline = type(uint48).max;
    }

    // ---- activation and freeze (design §8.3, §8.10) ---------------------------------------------------

    /// @inheritdoc ILedgerControl
    function activate(ActivationSet calldata set) external delegateOnly {
        _activate(set);
    }

    /// @inheritdoc ILedgerControl
    function freeze(ActivationSet calldata set) external delegateOnly {
        RealmStorage storage $ = _realm();
        if (set.acceptedChainId != block.chainid) revert E_FREEZE_PRECHECK(1);
        if ($.transitionTarget != 0 && $.transitionDeadline >= block.number) {
            revert E_FREEZE_PRECHECK(4);
        }
        if (set.components.steward != address(0)) revert E_FREEZE_PRECHECK(5);
        if (set.dependencyRoot == 0) revert E_FREEZE_PRECHECK(6);
        if (set.capabilities & $.capabilities != $.capabilities) revert E_FREEZE_PRECHECK(7);
        if (!_limitsSuperset(set.limits, $.limits)) revert E_FREEZE_PRECHECK(8);
        _activate(set);
        $.frozen = 1;
    }

    function _limitsSuperset(Limits calldata a, Limits storage b) private view returns (bool) {
        return a.maxActions >= b.maxActions && a.maxBody >= b.maxBody && a.maxRefs >= b.maxRefs
            && a.maxReadSetPrincipals >= b.maxReadSetPrincipals
            && a.maxReadSetPositions >= b.maxReadSetPositions && a.maxWitness >= b.maxWitness
            && a.inlineWordMax >= b.inlineWordMax
            && a.maxBindsPerPublication >= b.maxBindsPerPublication
            && a.maxBodyBytesPerPublication >= b.maxBodyBytesPerPublication
            && a.maxReadIds >= b.maxReadIds && a.maxReadCount >= b.maxReadCount;
    }

    function _activate(ActivationSet calldata set) private {
        RealmStorage storage $ = _realm();
        uint32 current = $.revision;
        uint16 flags = msg.sig == ILedgerControl.freeze.selector ? REV_FROZEN : 0; // derived, never a literal argument
        // a. ordinal
        if (set.revision != current + 1) revert E_REVISION(current + 1, set.revision);
        // b. migration (none at S1: a nonempty routine or scope is refused until one exists)
        if (set.migration.length != 0 || set.migrationScope.length != 0) {
            revert E_MIGRATION_SCOPE(0);
        }
        // c. implementation
        address live = _implementation();
        if (live != set.components.ledgerImpl || live.codehash != set.components.ledgerImplCodehash)
        {
            revert E_IMPLEMENTATION(set.components.ledgerImpl, live);
        }
        // d. layout
        if (
            set.layoutId != LAYOUT_ID
                || ($.layoutId != LAYOUT_ID && $.layoutId != PREDECESSOR_LAYOUT_ID)
        ) {
            revert E_LAYOUT(LAYOUT_ID, set.layoutId);
        }
        // e. registry
        ITypeRegistry reg = ITypeRegistry($.registry);
        if (reg.activeRevision() != set.revision) revert E_REGISTRY(1);
        if (reg.ledger() != address(this)) revert E_REGISTRY(2);
        address regImpl = reg.implementation();
        if (regImpl != set.components.registryImpl) revert E_REGISTRY(3);
        if (regImpl.codehash != set.components.registryImplCodehash) revert E_REGISTRY(4);
        // f. the helpers the implementation carries
        if (set.components.ingress != INGRESS || set.components.ingressCodehash != INGRESS_CODEHASH)
        {
            revert E_PIN(set.components.ingress, 1);
        }
        if (set.components.applyDelegate != APPLY || set.components.applyCodehash != APPLY_CODEHASH)
        {
            revert E_PIN(set.components.applyDelegate, 2);
        }
        if (set.components.controller.codehash != set.components.controllerCodehash) {
            revert E_PIN(set.components.controller, 4);
        }
        // g–h. index readiness, pins and scans, the admin ownership
        _checkIndex(set, $);
        _checkAdmin();
        // i. the revision row and the flags
        RevisionRow storage prev = _revisions().rows[current];
        RevisionRow storage row = _revisions().rows[set.revision];
        flags |= _flags(set, prev, $);
        _writeRevision(row, set, flags);
        // j. the realm
        if (set.components.index != $.index) $.indexGeneration = set.revision;
        $.index = set.components.index;
        $.controller = set.components.controller;
        $.steward = set.components.steward;
        $.capabilities = set.capabilities;
        $.acceptedChainId = set.acceptedChainId;
        $.executionProfileId = set.executionProfileId;
        $.layoutId = set.layoutId;
        $.limits = set.limits;
        $.limitsProfileId = keccak256(abi.encode(set.limits));
        $.noticePrincipal = set.noticePrincipal;
        $.revision = set.revision;
        _closeTransition($, set.revision);
        $.domainSeparator = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                DOMAIN_NAME,
                DOMAIN_VERSION,
                uint256(set.acceptedChainId),
                address(this)
            )
        );
        $.indexObligations = keccak256(
            abi.encode(
                set.components.index, set.components.indexCodehash, set.components.indexManifestHash
            )
        );
        bytes32 es = keccak256(
            abi.encode(
                Keys.DOM_EXECUTION_SET,
                set.layoutId,
                $.domainSeparator,
                set.components,
                uint256(set.revision),
                set.executionProfileId,
                set.capabilities,
                set.acceptedChainId,
                $.limitsProfileId
            )
        );
        $.executionSet = es;
        row.executionSet = es;
        if (set.expectedExecutionSet != es) revert E_EXPECTED_SET(set.expectedExecutionSet, es);
        // k.
        emit Activated(set.revision, es, uint64(block.number), _counters().admissions, flags);
    }

    /// Design §8.3 steps 5g–5h: the index's readiness and every pin it enumerates.
    function _checkIndex(ActivationSet calldata set, RealmStorage storage $) private view {
        address index = set.components.index;
        CodePins.requireRealCode(index);
        if (index.codehash != set.components.indexCodehash) revert E_PIN(index, 3);
        if (set.components.steward != address(0)) {
            CodePins.requireRealCode(set.components.steward);
            CodeScan.requirePlainRuntime(set.components.steward);
        }
        if (index == $.index) {
            RevisionRow storage current = _revisions().rows[$.revision];
            if (
                current.indexCodehash != set.components.indexCodehash
                    || current.indexManifestHash != set.components.indexManifestHash
            ) revert E_INDEX_NOT_READY(1);
            if (IRealmIndex(index).replayReadiness().phase != Phase.IDLE) {
                revert E_INDEX_NOT_READY(2);
            }
            return;
        }
        CodeScan.requirePlainRuntime(index);
        Readiness memory r = IRealmIndex(index).replayReadiness();
        if (r.ledger != address(this)) revert E_INDEX_NOT_READY(3);
        if (r.layoutId != set.layoutId) revert E_INDEX_NOT_READY(4);
        bytes32[] memory supported = ILedgerHot(address(this)).supportedHotAbiIds();
        if (!_contains(supported, r.hotAbiId)) revert E_INDEX_NOT_READY(5);
        if (r.manifestHash != set.components.indexManifestHash) revert E_INDEX_NOT_READY(6);
        (uint8 phase,,,) = _unpackLock(_lockWord());
        if (phase != Phase.IDLE) revert E_INDEX_NOT_READY(7);
        CountersStorage storage c = _counters();
        if (r.completedAdmission != c.admissions || r.completedPublication != c.publications) {
            revert E_INDEX_NOT_READY(8);
        }
        if (r.build != address(0)) {
            CodePins.requireRealCode(r.build);
            if (r.build.codehash != r.buildCodehash) revert E_PIN(r.build, 7);
            CodeScan.requirePlainRuntime(r.build);
        }
        for (uint256 i; i < r.units.length; ++i) {
            Unit memory u = r.units[i];
            if (!_contains(supported, u.hotAbiId)) {
                revert E_HOT_ABI(u.finalHook != address(0) ? u.finalHook : u.foldHook);
            }
            _pinUnit(u.foldHook, u.foldCodehash);
            _pinUnit(u.finalHook, u.finalCodehash);
        }
        for (uint256 i; i < r.families.length; ++i) {
            FamilyEntry memory f = r.families[i];
            if (f.fromAdmission == NOT_MAINTAINED) continue;
            if (f.shape == SHAPE_APPEND && f.fromAdmission != 1) revert E_INDEX_NOT_READY(9);
            CodePins.requireRealCode(f.store);
            if (f.store.codehash != f.storeCodehash) revert E_PIN(f.store, 6);
            CodeScan.requirePlainRuntime(f.store);
            if (!_contains(IPostingStore(f.store).familyIds(), f.familyId)) {
                revert E_INDEX_NOT_READY(10);
            }
            _requireContiguousWriters(f.store);
        }
    }

    /// The proxy's admin is a ProxyAdmin owned by the executing controller (S7).
    function _checkAdmin() private view {
        address admin;
        assembly ("memory-safe") {
            admin := sload(ADMIN_SLOT)
        }
        if (admin == address(0) || IOwnable(admin).owner() != msg.sender) revert E_PIN(admin, 9);
    }

    function _pinUnit(address hook, bytes32 expected) private view {
        if (hook == address(0)) return;
        CodePins.requireRealCode(hook);
        if (hook.codehash != expected) revert E_PIN(hook, 5);
        CodeScan.requirePlainRuntime(hook);
    }

    function _requireContiguousWriters(address store) private view {
        (, uint64[] memory from, uint64[] memory to) = IPostingStore(store).writers();
        for (uint256 i = 1; i < from.length; ++i) {
            if (to[i - 1] == 0 || from[i] != to[i - 1] + 1) revert E_INDEX_NOT_READY(11);
        }
    }

    function _contains(bytes32[] memory list, bytes32 x) private pure returns (bool) {
        for (uint256 i; i < list.length; ++i) {
            if (list[i] == x) return true;
        }
        return false;
    }

    function _flags(ActivationSet calldata set, RevisionRow storage prev, RealmStorage storage $)
        private
        view
        returns (uint16 f)
    {
        if ($.revision != 0) {
            ComponentSet calldata c = set.components;
            if (
                c.ledgerImpl == prev.ledgerImpl && c.registryImpl == prev.registryImpl
                    && c.index == prev.index && c.ingress == prev.ingress
                    && c.applyDelegate == prev.applyDelegate && c.controller == prev.controller
                    && c.controllerOwner == prev.controllerOwner && c.steward == prev.steward
                    && c.indexManifestHash == prev.indexManifestHash
            ) f |= REV_SAME_CODE;
            if (c.controller != prev.controller) f |= REV_CONTROLLER;
            if (c.controllerOwner != prev.controllerOwner) f |= REV_OWNER;
            if (c.index != prev.index) f |= REV_INDEX;
            if (set.layoutId != prev.layoutId) f |= REV_LAYOUT;
            if (keccak256(abi.encode(set.limits)) != prev.limitsProfileId) f |= REV_LIMITS;
        }
        if (set.acceptedChainId != $.acceptedChainId) f |= REV_CHAIN;
    }

    function _writeRevision(RevisionRow storage row, ActivationSet calldata set, uint16 flags)
        private
    {
        CountersStorage storage c = _counters();
        ComponentSet calldata cs = set.components;
        row.activationBlock = uint48(block.number);
        row.admissionHigh = c.admissions;
        row.publicationHigh = c.publications;
        row.activationTimestamp = uint40(block.timestamp);
        row.flags = flags;
        row.executionProfileId = set.executionProfileId;
        row.capabilities = set.capabilities;
        row.ledgerImpl = cs.ledgerImpl;
        row.acceptedChainId = set.acceptedChainId;
        row.ledgerImplCodehash = cs.ledgerImplCodehash;
        row.registryImpl = cs.registryImpl;
        row.registryImplCodehash = cs.registryImplCodehash;
        row.index = cs.index;
        row.indexGeneration = cs.index != _realm().index ? set.revision : _realm().indexGeneration;
        row.indexCodehash = cs.indexCodehash;
        row.indexManifestHash = cs.indexManifestHash;
        row.ingress = cs.ingress;
        row.ingressCodehash = cs.ingressCodehash;
        row.applyDelegate = cs.applyDelegate;
        row.applyCodehash = cs.applyCodehash;
        row.controller = cs.controller;
        row.controllerCodehash = cs.controllerCodehash;
        row.controllerOwner = cs.controllerOwner;
        row.steward = cs.steward;
        row.layoutId = set.layoutId;
        row.verifierProfilesRoot = cs.verifierProfilesRoot;
        row.migrationHash = set.migration.length == 0 ? bytes32(0) : keccak256(set.migration);
        row.dependencyRoot = set.dependencyRoot;
        row.limitsProfileId = keccak256(abi.encode(set.limits));
        row.limits = set.limits;
        row.noticePrincipal = set.noticePrincipal;
    }

    function _closeTransition(RealmStorage storage $, uint32 activated) private {
        uint32 target = $.transitionTarget;
        if (target == 0) return;
        if (target == activated) {
            emit TransitionEnded(target, 1);
        } else if ($.transitionDeadline < block.number) {
            emit TransitionEnded(target, 3);
            $.transitionCooldownUntil = $.transitionDeadline + $.limits.maxTransitionBlocks;
        }
        $.transitionTarget = 0;
        $.transitionDeadline = 0;
    }

    function _implementation() private view returns (address impl) {
        assembly ("memory-safe") {
            impl := sload(IMPLEMENTATION_SLOT)
        }
    }

    // ---- transition (design §8.8) --------------------------------------------------------------------

    /// @inheritdoc ILedgerControl
    function beginTransition(uint32 targetRevision, uint48 deadlineBlock) external delegateOnly {
        RealmStorage storage $ = _realm();
        if (targetRevision != $.revision + 1) revert E_REVISION($.revision + 1, targetRevision);
        if (targetRevision == $.transitionLastTarget) revert E_TRANSITION_TARGET(targetRevision);
        if ($.transitionTarget != 0) {
            if ($.transitionDeadline >= block.number) {
                revert E_TRANSITION($.transitionTarget, $.transitionDeadline);
            }
            emit TransitionEnded($.transitionTarget, 3); // expired unobserved
            $.transitionCooldownUntil = $.transitionDeadline + $.limits.maxTransitionBlocks;
        }
        if (block.number < $.transitionCooldownUntil) {
            revert E_TRANSITION_COOLDOWN($.transitionCooldownUntil);
        }
        if (
            deadlineBlock < block.number
                || deadlineBlock - block.number > $.limits.maxTransitionBlocks
        ) {
            revert E_DEADLINE_BOUND(deadlineBlock, $.limits.maxTransitionBlocks);
        }
        $.transitionLastTarget = targetRevision;
        $.transitionTarget = targetRevision;
        $.transitionDeadline = deadlineBlock;
        emit TransitionBegun(targetRevision, deadlineBlock);
    }

    /// @inheritdoc ILedgerControl
    function abortTransition() external delegateOnly {
        RealmStorage storage $ = _realm();
        uint32 target = $.transitionTarget;
        if (target == 0) revert E_TRANSITION_TARGET(0);
        if ($.transitionDeadline >= block.number && msg.sender != $.controller) {
            revert E_NOT_CONTROLLER(msg.sender);
        }
        emit TransitionEnded(target, 2);
        $.transitionCooldownUntil = uint48(block.number) + $.limits.maxTransitionBlocks;
        $.transitionTarget = 0;
        $.transitionDeadline = 0;
    }
}
