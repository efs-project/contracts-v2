// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ActivationSet} from "./ILedgerControl.sol";

/// @title IRealmController — a Realm's controller (design §5.12)
/// @notice Hand-rolled ownership; no OZ Ownable. There is no no-argument acceptOwnership() and no public
///         renounceOwnership(): ownership changes only through an activation, and the owner is zeroed only
///         inside `freeze`. `frozen()` is true only after `freeze`; a controller replaced by `migrate` reports
///         `retired() == true` and `frozen() == false`. No ProxyAdmin passthrough: the only ProxyAdmin calls
///         are upgradeAndCall inside activate, transferOwnership inside migrate and renounceOwnership inside
///         freeze.
interface IRealmController {
    event OwnershipActivated(address indexed previous, address indexed current, uint32 revision);
    event ControllerMigrated(address indexed successor, uint32 revision);
    /// Emitted here, after the canaries (the kernel emitted Activated inside ledger.freeze).
    event Frozen(
        uint32 indexed terminalRevision,
        bytes32 executionSet,
        uint64 admissionHigh,
        uint64[] canaryPublications
    );

    /// onlyOwner, notFrozen.
    function activate(ActivationSet calldata set) external;

    /// onlyOwner, notFrozen.
    function beginTransition(uint32 targetRevision, uint48 deadlineBlock) external;

    /// onlyOwner before the deadline; anyone after it.
    function abortTransition() external;

    /// onlyOwner; pending only; no effect until accepted.
    function transferOwnership(address pending) external;

    /// pendingOwner; the activation and the owner change are one transaction.
    function acceptOwnershipAndActivate(ActivationSet calldata set) external;

    /// onlyOwner; transfers both ProxyAdmin ownerships inside the activation.
    function migrate(address successor, ActivationSet calldata set) external;

    /// onlyOwner; design §8.10: registry activation, terminal ledger activation, one canary per enabled lane
    /// (laneCanaries = pre-signed executeSigned calldata for b1/b2), renounce everything.
    function freeze(ActivationSet calldata finalSet, bytes[] calldata laneCanaries) external;

    /// onlyOwner, notFrozen → registry (idle-gated).
    function activatePolicy(bytes32 typeId, address acceptor) external;

    function declareRoleExpectation(bytes32 purpose, bytes32 role, bytes32 expectedType) external;

    function activateWrapper(uint8 version, address implementation) external;

    function owner() external view returns (address);

    function pendingOwner() external view returns (address);

    function frozen() external view returns (bool);

    function retired() external view returns (bool);

    function ledger() external view returns (address);

    function registryProxy() external view returns (address);

    function admins() external view returns (address ledgerAdmin, address registryAdmin);
}
