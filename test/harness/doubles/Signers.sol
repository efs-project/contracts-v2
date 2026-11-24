// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AcceptContext, IAcceptor, RefHeader} from "../../../src/interfaces/IAcceptor.sol";
import {ILedger} from "../../../src/interfaces/ILedger.sol";
import {Action, ActionKind, Native} from "../../../src/interfaces/Actions.sol";

// Authors, wallets and code-shape doubles (design §2.2 S2/S6/S15/S16/S17, §7.1, §16.2 item 6, §16.6).

// ERC-1271 `isValidSignature` magic value.
bytes4 constant ERC1271_MAGIC = 0x1626ba7e;
// The refusal the wallets return.
bytes4 constant ERC1271_REFUSAL = 0xffffffff;

/// `execute` with one CREATE leaf under `nonce`, no deadline, both expectations unbound, empty guard.
function createCalldata(bytes32 salt, uint64 nonce) pure returns (bytes memory) {
    Action[] memory actions = new Action[](1);
    actions[0].kind = ActionKind.CREATE;
    actions[0].salt = salt;
    Native memory ctx;
    ctx.nonce = nonce;
    return abi.encodeCall(ILedger.execute, (actions, new bytes[](1), ctx, ""));
}

/// @notice A deployed ERC-1271 wallet (port of `lab-b/test/ContractSignatureWallet.sol`). Mode ECDSA returns
///         the magic value iff the signature is a 65-byte low-s secp256k1 signature by `key` over `hash`, and
///         `hash == digest` unless `digest` is 0. The other modes are the prototype's failure shapes for the
///         profile-2 lane (§6.2): a revert (`E_SIGNATURE(4)`), a loop (`E_WALLET_GAS`), the magic in 4 bytes,
///         dirty, or inside 8 KiB, a wrong word, a storage write and a ledger re-entry (both must fail under
///         the kernel's `STATICCALL`). `caller`, when set, is the only account answered (others get the
///         refusal). The controller (the deployer) configures it and can author natively through `forward`.
/// @dev Not `IERC1271`: that interface's `isValidSignature` is `view`, which forbids the WRITE and REENTER
///      modes. The selector is the same.
contract ContractSignatureWallet {
    uint8 public constant ECDSA = 0;
    uint8 public constant REVERT = 1;
    uint8 public constant BURN = 2;
    uint8 public constant SHORT = 3;
    uint8 public constant DIRTY = 4;
    uint8 public constant OVERSIZED = 5;
    uint8 public constant WRONG = 6;
    uint8 public constant WRITE = 7;
    uint8 public constant REENTER = 8;

    uint256 internal constant HALF_ORDER =
        0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0;

    error WalletRefused();
    error NotController(address caller);

    address public immutable controller = msg.sender;
    address public key;
    bytes32 public digest;
    address public caller;
    uint8 public mode;
    uint256 public writes;

    modifier onlyController() {
        if (msg.sender != controller) revert NotController(msg.sender);
        _;
    }

    constructor(address key_) {
        key = key_;
    }

    function setKey(address key_) external onlyController {
        key = key_;
    }

    function setDigest(bytes32 digest_) external onlyController {
        digest = digest_;
    }

    function setCaller(address caller_) external onlyController {
        caller = caller_;
    }

    function setMode(uint8 mode_) external onlyController {
        mode = mode_;
    }

    /// The wallet as a native author (or any other call it should make as itself).
    function forward(address target, bytes calldata data)
        external
        onlyController
        returns (bytes memory result)
    {
        bool ok;
        (ok, result) = target.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(result, 0x20), mload(result))
            }
        }
    }

    function isValidSignature(bytes32 hash, bytes calldata signature)
        external
        returns (bytes4 result)
    {
        if (caller != address(0) && msg.sender != caller) return ERC1271_REFUSAL;
        uint8 m = mode;
        if (m == REVERT) revert WalletRefused();
        if (m == BURN) {
            assembly {
                for {} 1 {} {}
            }
        }
        if (m == SHORT) {
            assembly {
                mstore(0, shl(224, 0x1626ba7e))
                return(0, 4)
            }
        }
        if (m == DIRTY) {
            assembly {
                mstore(0, or(shl(224, 0x1626ba7e), 1))
                return(0, 0x20)
            }
        }
        if (m == OVERSIZED) {
            assembly {
                mstore(0, shl(224, 0x1626ba7e))
                return(0, 8192)
            }
        }
        if (m == WRONG) return ERC1271_REFUSAL;
        if (m == WRITE) ++writes;
        if (m == REENTER) {
            (bool ok,) = msg.sender.call(createCalldata(keccak256("efs2/test/wallet/reentry"), 0));
            if (ok) return ERC1271_REFUSAL;
        }
        return valid(hash, signature) ? ERC1271_MAGIC : ERC1271_REFUSAL;
    }

    /// The ECDSA predicate of mode ECDSA.
    function valid(bytes32 hash, bytes calldata signature) public view returns (bool) {
        address k = key;
        if (k == address(0) || signature.length != 65) return false;
        if (digest != 0 && hash != digest) return false;
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly ("memory-safe") {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 0x20))
            v := byte(0, calldataload(add(signature.offset, 0x40)))
        }
        if ((v != 27 && v != 28) || uint256(s) > HALF_ORDER) return false;
        return ecrecover(hash, v, r, s) == k;
    }
}

/// @notice Returns the ERC-1271 magic value for any hash and any bytes (§16 preamble). The S17 attacker: a
///         profile-2 intent naming it as `author` for a victim's `principalId` must be refused
///         `E_SIGNATURE(6)` before any wallet call (§6.2).
contract MagicWallet {
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return ERC1271_MAGIC;
    }
}

/// @notice Calls `ILedger.execute` from its constructor, while it has no code (§2.2 S2: a code-less caller that
///         is not `tx.origin` → `E_NATIVE_AMBIGUOUS`), recording the outcome instead of reverting, and again on
///         demand after construction (`attempt`), when it is an ordinary contract author.
contract NativeCounterfeit {
    address public immutable ledger;
    bool public constructorReverted;
    bytes public constructorReturndata;

    constructor(address ledger_, bytes32 salt) {
        ledger = ledger_;
        (bool ok, bytes memory ret) = ledger_.call(createCalldata(salt, 0));
        constructorReverted = !ok;
        constructorReturndata = ret;
    }

    /// One CREATE leaf under `nonce`; the outcome is returned, never bubbled.
    function attempt(uint64 nonce, bytes32 salt) external returns (bool ok, bytes memory ret) {
        (ok, ret) = ledger.call(createCalldata(salt, nonce));
    }
}

/// @notice An EIP-7702 delegate target (port of `lab-b/test/Scoped7702Delegate.sol` reduced to its scope):
///         an account delegating here forwards `execute` to the one ledger fixed at construction, and only
///         when it calls itself (`msg.sender == address(this)`, a self-sponsored type-4 transaction). The
///         ledger then sees `msg.sender` = the delegating EOA, whose 23-byte `ef0100` designator classifies it
///         in the key namespace (`Keys.principalFor`). It offers no arbitrary-call path.
contract Scoped7702Delegate {
    error E_SELF_ONLY();

    address public immutable LEDGER;

    constructor(address ledger_) {
        LEDGER = ledger_;
    }

    function execute(
        Action[] calldata actions,
        bytes[] calldata bodies,
        Native calldata ctx,
        bytes calldata guard
    ) external returns (uint64 publication, uint64 firstAdmission) {
        if (msg.sender != address(this)) revert E_SELF_ONLY();
        return ILedger(LEDGER).execute(actions, bodies, ctx, guard);
    }
}

/// @notice A controller-successor candidate with an owner-only passthrough `call(address,bytes)`: through it
///         the owner could reach both `ProxyAdmin`s directly, upgrading without an activation (§2.2 S7/S15).
/// @dev Its runtime makes only `CALL`s, so `CodeScan.scan` classifies it **plain** (reason 0): the opcode scan
///      cannot refuse a CALL passthrough (see `test/unit/Doubles.t.sol`). `DelegatingPassthroughController`
///      is the variant the scan does refuse (reason 3).
contract PassthroughController {
    error NotOwner(address caller);

    address public immutable owner = msg.sender;

    function call(address target, bytes calldata data)
        external
        payable
        returns (bytes memory result)
    {
        if (msg.sender != owner) revert NotOwner(msg.sender);
        bool ok;
        (ok, result) = target.call{value: msg.value}(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(result, 0x20), mload(result))
            }
        }
    }
}

/// @notice The `DELEGATECALL` passthrough: owner-only `delegate(address,bytes)` runs any code as the
///         controller. `CodeScan` refuses it as a forbidden opcode (reason 3).
contract DelegatingPassthroughController {
    error NotOwner(address caller);

    address public immutable owner = msg.sender;

    function delegate(address target, bytes calldata data) external returns (bytes memory result) {
        if (msg.sender != owner) revert NotOwner(msg.sender);
        bool ok;
        (ok, result) = target.delegatecall(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(result, 0x20), mload(result))
            }
        }
    }
}

/// `accept` with an empty context, body, refs and headers: the non-empty initializer data OZ 5.6.1's
/// `ERC1967Proxy` constructor demands (it reverts `ERC1967ProxyUninitialized` on empty data unless
/// `_unsafeAllowUninitialized()` is overridden) and delegatecalls into the implementation.
function acceptorProxyInitData() pure returns (bytes memory) {
    AcceptContext memory ctx;
    return abi.encodeCall(IAcceptor.accept, (ctx, "", new bytes32[](0), new RefHeader[](0)));
}

/// @notice An acceptor behind stock OZ 5.6.1 `ERC1967Proxy` (normally pointing at `AcceptAll`): it answers
///         `accept` correctly, but its runtime `DELEGATECALL`s, so `activatePolicy` must refuse it (§2.2 S6/S16,
///         §16.3 unit/registry; `CodeScan` reason 3). The constructor satisfies OZ 5.6's initialization rule by
///         delegatecalling `accept` once (`acceptorProxyInitData`), which `AcceptAll` answers purely.
contract ProxyAcceptor is ERC1967Proxy {
    constructor(address implementation) ERC1967Proxy(implementation, acceptorProxyInitData()) {}
}
