// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Limits} from "./Limits.sol";

// ILedgerControl — the controller-only, idle-gated kernel entry points (design §5.4) and the activation and
// transition kernel events (§5.5). The three structs are file-level so `Views.sol`, `IRealmController` and the
// kernel-internal interfaces share one definition.

/// Genesis input of `ILedgerControl.initialize` (design §8.2).
struct RealmInit {
    bytes32 realmSalt;
    address controller;
    address registry;
    address readerDirectory;
    uint16 executionProfileId;
    Limits limits;
}

/// Every pinned component of one revision with its expected codehash (design §8.1).
struct ComponentSet {
    address ledgerImpl;
    bytes32 ledgerImplCodehash;
    address registryImpl;
    bytes32 registryImplCodehash;
    address index;
    bytes32 indexCodehash;
    bytes32 indexManifestHash;
    address ingress;
    bytes32 ingressCodehash;
    address applyDelegate;
    bytes32 applyCodehash;
    address controller;
    bytes32 controllerCodehash;
    address controllerOwner;
    address steward;
    bytes32 verifierProfilesRoot;
}

/// One activation (design §8.3). No terminal flag: the terminal activation is a distinct selector (`freeze`).
struct ActivationSet {
    uint32 revision;
    ComponentSet components;
    bytes32 layoutId;
    uint16 executionProfileId;
    uint16 capabilities;
    uint64 acceptedChainId;
    Limits limits;
    bytes32 expectedExecutionSet;
    bytes32 dependencyRoot;
    bytes32 noticePrincipal;
    bytes32[] migrationScope;
    bytes migration;
}

/// @title ILedgerControl — controller-only kernel control (design §5.4)
/// @notice Revision `n` runs under initializer version `n + 1`: OZ's `initializer` sets `_initialized = 1` and
///         `reinitializer(v)` reverts when `_initialized >= v`.
interface ILedgerControl {
    /// One per activation, including the terminal one inside `freeze`.
    event Activated(
        uint32 indexed revision,
        bytes32 indexed executionSet,
        uint64 activationBlock,
        uint64 admissionHigh,
        uint16 flags
    );
    event TransitionBegun(uint32 indexed targetRevision, uint48 deadlineBlock);
    /// `how`: 1 activated 2 aborted 3 expired (3 is emitted lazily by the first beginTransition or activate
    /// that observes the expiry, design §8.8).
    event TransitionEnded(uint32 indexed targetRevision, uint8 how);

    /// Initializer; genesis creation transaction only.
    function initialize(RealmInit calldata init) external;

    /// reinitializer(uint64(set.revision) + 1); onlyController; phase IDLE.
    function activate(ActivationSet calldata set) external;

    /// reinitializer(uint64(set.revision) + 1); onlyController; terminal; pre-checks of design §8.10.
    function freeze(ActivationSet calldata set) external;

    /// onlyController; a target can be begun once, ever; cooldown;
    /// deadline − block.number ≤ limits.maxTransitionBlocks (design §8.8).
    function beginTransition(uint32 targetRevision, uint48 deadlineBlock) external;

    /// onlyController before the deadline; anyone after it.
    function abortTransition() external;
}
