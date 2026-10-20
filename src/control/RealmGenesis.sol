// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {IRealmController} from "../interfaces/IRealmController.sol";
import {Limits} from "../interfaces/Limits.sol";
import {ILedgerHot} from "../interfaces/ILedgerHot.sol";
import {ILedgerControl, RealmInit} from "../interfaces/ILedgerControl.sol";
import {ITypeRegistry} from "../interfaces/ITypeRegistry.sol";
import {E_GENESIS} from "../interfaces/Errors.sol";

/// @title RealmGenesis — one deploy plan, journaled, every step idempotent (design §8.2 G15–G18)
/// @notice A single-use contract whose address is known before anything it creates exists, so the controller
///         and both proxies are created by its own nonces (controller = CREATE(G, 1), registry proxy =
///         CREATE(G, 2), ledger proxy = CREATE(G, 3)) and each proxy is initialized in its creation: no
///         unauthenticated initialization step, no address cycle, no authority from `msg.sender`. A second
///         `run()` reverts; a stranger's run produces the same addresses and state. The controller's and the
///         proxy's creation codes arrive in the call, pinned by hash, so this contract embeds no creation code.
contract RealmGenesis {
    address public immutable OWNER;
    address public immutable LEDGER_IMPL;
    bytes32 public immutable LEDGER_IMPL_CODEHASH;
    address public immutable REGISTRY_IMPL;
    bytes32 public immutable REGISTRY_IMPL_CODEHASH;
    bytes32 public immutable REALM_SALT;
    uint16 public immutable EXECUTION_PROFILE_ID;
    bytes32 public immutable LIMITS_HASH;
    address public immutable READER_DIRECTORY;
    address public immutable WRAPPER_V1;
    bytes32 public immutable NOTICE_TYPE;
    /// keccak256 of `RealmController`'s creation code without arguments.
    bytes32 public immutable CONTROLLER_INITCODE_HASH;
    /// keccak256 of OZ 5.6.1 `TransparentUpgradeableProxy`'s creation code without arguments.
    bytes32 public immutable PROXY_INITCODE_HASH;

    address public controller;
    address public registryProxy;
    address public ledgerProxy;

    event Genesis(
        address indexed controller, address indexed registryProxy, address indexed ledgerProxy
    );

    constructor(
        address owner_,
        address ledgerImpl,
        address registryImpl,
        bytes32 realmSalt,
        uint16 executionProfileId,
        bytes32 limitsHash,
        address readerDirectory,
        address wrapperV1,
        bytes32 noticeType,
        bytes32 controllerInitcodeHash,
        bytes32 proxyInitcodeHash
    ) {
        OWNER = owner_;
        LEDGER_IMPL = ledgerImpl;
        LEDGER_IMPL_CODEHASH = ledgerImpl.codehash;
        REGISTRY_IMPL = registryImpl;
        REGISTRY_IMPL_CODEHASH = registryImpl.codehash;
        REALM_SALT = realmSalt;
        EXECUTION_PROFILE_ID = executionProfileId;
        LIMITS_HASH = limitsHash;
        READER_DIRECTORY = readerDirectory;
        WRAPPER_V1 = wrapperV1;
        NOTICE_TYPE = noticeType;
        CONTROLLER_INITCODE_HASH = controllerInitcodeHash;
        PROXY_INITCODE_HASH = proxyInitcodeHash;
    }

    /// The three addresses `run()` will create, from this contract's nonces.
    function predict()
        public
        view
        returns (address controller_, address registry_, address ledger_)
    {
        controller_ = _creation(1);
        registry_ = _creation(2);
        ledger_ = _creation(3);
    }

    /// G18: the controller, the registry proxy (initialized against the predicted ledger), the ledger proxy
    /// (initialized with the real controller and registry), then the post-checks and the journal.
    function run(
        Limits calldata limits,
        bytes calldata controllerInitcode,
        bytes calldata proxyInitcode
    ) external {
        if (controller != address(0)) revert E_GENESIS(0);
        if (keccak256(abi.encode(limits)) != LIMITS_HASH) revert E_GENESIS(1);
        if (
            keccak256(controllerInitcode) != CONTROLLER_INITCODE_HASH
                || keccak256(proxyInitcode) != PROXY_INITCODE_HASH
        ) {
            revert E_GENESIS(10);
        }
        if (
            LEDGER_IMPL.codehash != LEDGER_IMPL_CODEHASH
                || REGISTRY_IMPL.codehash != REGISTRY_IMPL_CODEHASH
        ) {
            revert E_GENESIS(9);
        }
        (address pc, address pr, address pl) = predict();
        address c =
            _create(bytes.concat(controllerInitcode, abi.encode(OWNER, pl, pr, NOTICE_TYPE)));
        if (c != pc) revert E_GENESIS(2);
        address r = _create(
            bytes.concat(
                proxyInitcode,
                abi.encode(
                    REGISTRY_IMPL, c, abi.encodeCall(ITypeRegistry.initialize, (pl, WRAPPER_V1))
                )
            )
        );
        if (r != pr) revert E_GENESIS(3);
        RealmInit memory init = RealmInit({
            realmSalt: REALM_SALT,
            controller: c,
            registry: r,
            readerDirectory: READER_DIRECTORY,
            executionProfileId: EXECUTION_PROFILE_ID,
            limits: limits
        });
        address l = _create(
            bytes.concat(
                proxyInitcode,
                abi.encode(LEDGER_IMPL, c, abi.encodeCall(ILedgerControl.initialize, (init)))
            )
        );
        if (l != pl) revert E_GENESIS(4);
        if (ITypeRegistry(r).ledger() != l) revert E_GENESIS(5);
        if (ILedgerHot(l).registry() != r) revert E_GENESIS(6);
        if (ILedgerHot(l).controller() != c) revert E_GENESIS(7);
        (address ledgerAdmin, address registryAdmin) = IRealmController(c).admins();
        if (ProxyAdmin(ledgerAdmin).owner() != c || ProxyAdmin(registryAdmin).owner() != c) {
            revert E_GENESIS(8);
        }
        controller = c;
        registryProxy = r;
        ledgerProxy = l;
        emit Genesis(c, r, l);
    }

    function _create(bytes memory initcode) private returns (address created) {
        assembly ("memory-safe") {
            created := create(0, add(initcode, 32), mload(initcode))
        }
        if (created == address(0)) revert E_GENESIS(11);
    }

    /// CREATE(this, nonce) for nonce 1..127: keccak256(RLP([this, nonce])).
    function _creation(uint8 nonce) private view returns (address) {
        return
            address(uint160(uint256(keccak256(abi.encodePacked(hex"d694", address(this), nonce)))));
    }
}
