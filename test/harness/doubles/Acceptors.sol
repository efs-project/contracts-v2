// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {
    AcceptContext,
    EXHAUSTED,
    IAcceptor,
    RefHeader
} from "../../../src/interfaces/IAcceptor.sol";
import {ILedger} from "../../../src/interfaces/ILedger.sol";
import {Action, ActionKind, Native} from "../../../src/interfaces/Actions.sol";

// IAcceptor/2 test doubles (design §5.10, §6.4, §2.2 S3). Success is exactly 32 bytes of returndata equal to
// `bytes32(IAcceptor.accept.selector)`; `EXHAUSTED` is the one reserved 32-byte reply; any other 32-byte word
// refuses. Each double below produces one reply shape so a kernel test can pin how the ingress classifies it:
// success, E_REJECTED / E_POLICY_REJECTED, or E_ACCEPTOR_GAS. None of them is a Files rule; none is meant to be
// a Type's mandatory rule except where its codehash pins its whole behaviour (everything here but
// `MockAcceptor`, whose storage mode changes behaviour under one codehash).

// The refusal word the refusing doubles return: neither the selector nor `EXHAUSTED`.
bytes4 constant ACCEPTOR_REFUSAL = bytes4(keccak256("efs2/test/acceptor/refuse"));

/// The selector, always (no context check: the context-checking variant is `ContextAssertingAcceptor`).
/// Also the implementation behind `ProxyAcceptor` (Signers.sol).
contract AcceptAll is IAcceptor {
    function accept(
        AcceptContext calldata,
        bytes calldata,
        bytes32[] calldata,
        RefHeader[] calldata
    ) external pure returns (bytes4) {
        return IAcceptor.accept.selector;
    }
}

/// A well-formed 32-byte refusal word, always.
contract RejectAll is IAcceptor {
    function accept(
        AcceptContext calldata,
        bytes calldata,
        bytes32[] calldata,
        RefHeader[] calldata
    ) external pure returns (bytes4) {
        return ACCEPTOR_REFUSAL;
    }
}

/// Reverts with the constructor's bytes (a forged kernel error, a long reason, or empty). The kernel discards
/// acceptor revert data (S3): a forged `E_NONCE` here must surface as `E_REJECTED`, and an empty revert that
/// used little gas is a refusal, not exhaustion.
contract RevertingAcceptor is IAcceptor {
    bytes internal _data;

    constructor(bytes memory data) {
        _data = data;
    }

    function revertData() external view returns (bytes memory) {
        return _data;
    }

    function accept(
        AcceptContext calldata,
        bytes calldata,
        bytes32[] calldata,
        RefHeader[] calldata
    ) external view returns (bytes4) {
        bytes memory d = _data;
        assembly ("memory-safe") {
            revert(add(d, 0x20), mload(d))
        }
    }
}

/// Returns 64 KiB whose first and last words are the selector shape. The 32-byte output-buffer law (§6.4:
/// `returndatasize() == 32 && word == selector`) refuses it; a caller that reads only the first or only the
/// last word, or copies the reply before bounding it, does not.
contract ReturndataBomb is IAcceptor {
    uint256 public constant SIZE = 65_536;

    function accept(
        AcceptContext calldata,
        bytes calldata,
        bytes32[] calldata,
        RefHeader[] calldata
    ) external pure returns (bytes4) {
        bytes4 s = IAcceptor.accept.selector;
        assembly {
            mstore(0, s)
            mstore(sub(SIZE, 0x20), s)
            return(0, SIZE)
        }
    }
}

/// Loops until the forwarded gas is gone: empty returndata having used everything, which the kernel
/// classifies `E_ACCEPTOR_GAS` (resubmit), never `E_REJECTED` (§6.4).
contract GasBurner is IAcceptor {
    function accept(
        AcceptContext calldata,
        bytes calldata,
        bytes32[] calldata,
        RefHeader[] calldata
    ) external view returns (bytes4) {
        while (gasleft() != 0) {} // runs until the frame is out of gas
        return ACCEPTOR_REFUSAL;
    }
}

/// Returns the reserved `EXHAUSTED` word: a wrapper reporting nested exhaustion (§5.10) → `E_ACCEPTOR_GAS`.
contract ExhaustedAcceptor is IAcceptor {
    function accept(
        AcceptContext calldata,
        bytes calldata,
        bytes32[] calldata,
        RefHeader[] calldata
    ) external pure returns (bytes4) {
        bytes32 w = EXHAUSTED;
        assembly ("memory-safe") {
            mstore(0, w)
            return(0, 0x20)
        }
    }
}

/// Returns `LENGTH` bytes whose first word is `WORD` (zero-padded; truncated when `LENGTH < 32`). Covers the
/// near-miss shapes of the success law: the selector in 4 bytes, the selector with dirty low bytes in 32,
/// the clean selector word followed by more bytes.
contract ShapedReplyAcceptor is IAcceptor {
    bytes32 public immutable WORD;
    uint256 public immutable LENGTH;

    constructor(bytes32 word, uint256 length) {
        WORD = word;
        LENGTH = length;
    }

    function accept(
        AcceptContext calldata,
        bytes calldata,
        bytes32[] calldata,
        RefHeader[] calldata
    ) external view returns (bytes4) {
        bytes32 w = WORD;
        uint256 n = LENGTH;
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, w)
            calldatacopy(add(p, 0x20), calldatasize(), n) // zero padding
            return(p, n)
        }
    }
}

/// Returns the selector iff `ctx.ledger == msg.sender` (the law every acceptor must apply, §5.10),
/// `ctx.typeId == EXPECTED_TYPE` and, when `EXPECTED_DIGEST != 0`, `digestOf(ctx, body, refs, refHeaders)`
/// equals it — so a test can pin the exact `AcceptContext`/`RefHeader[]` the ingress built (§16.3
/// unit/ingress "validateLeaf builds RefHeader[] and AcceptContext exactly").
contract ContextAssertingAcceptor is IAcceptor {
    bytes32 public immutable EXPECTED_TYPE;
    bytes32 public immutable EXPECTED_DIGEST;

    constructor(bytes32 expectedType, bytes32 expectedDigest) {
        EXPECTED_TYPE = expectedType;
        EXPECTED_DIGEST = expectedDigest;
    }

    function accept(
        AcceptContext calldata ctx,
        bytes calldata body,
        bytes32[] calldata refs,
        RefHeader[] calldata refHeaders
    ) external view returns (bytes4) {
        if (ctx.ledger != msg.sender || ctx.typeId != EXPECTED_TYPE) {
            return ACCEPTOR_REFUSAL;
        }
        if (EXPECTED_DIGEST != 0 && digestOf(ctx, body, refs, refHeaders) != EXPECTED_DIGEST) {
            return ACCEPTOR_REFUSAL;
        }
        return IAcceptor.accept.selector;
    }

    /// keccak256(abi.encode(ctx, body, refs, refHeaders)): the value to pass as `expectedDigest`.
    function digestOf(
        AcceptContext calldata ctx,
        bytes calldata body,
        bytes32[] calldata refs,
        RefHeader[] calldata refHeaders
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(ctx, body, refs, refHeaders));
    }
}

/// Tries to re-enter `ILedger(ctx.ledger).execute` from inside `accept` and returns the selector only if
/// that call reverted. The kernel calls acceptors by `STATICCALL` (§6.4), so the re-entry must fail (on the
/// lock, `E_PUBLICATION_ACTIVE`, or on the static context); a kernel that used `CALL` and had no lock would
/// see the refusal word instead.
/// @dev Deliberately not `is IAcceptor`: the interface's `accept` is `view`, which forbids the `CALL` this
///      double exists to attempt. The selector is the same (`accept` is selected by name and parameter types).
contract ReentrantAcceptor {
    function accept(
        AcceptContext calldata ctx,
        bytes calldata,
        bytes32[] calldata,
        RefHeader[] calldata
    ) external returns (bytes4) {
        (bool ok,) = ctx.ledger.call(reentryCalldata());
        return ok ? ACCEPTOR_REFUSAL : IAcceptor.accept.selector;
    }

    /// `execute` with one CREATE leaf, an unbound native context and the canonical-empty guard.
    function reentryCalldata() public pure returns (bytes memory) {
        Action[] memory actions = new Action[](1);
        actions[0].kind = ActionKind.CREATE;
        actions[0].salt = keccak256("efs2/test/acceptor/reentry");
        Native memory ctx;
        return abi.encodeCall(ILedger.execute, (actions, new bytes[](1), ctx, ""));
    }
}

/// The prototype's MockAcceptor, as a **policy-only** double (`L/src/LabHarness.sol` `MockAcceptor`): its
/// mode is storage, so it changes behaviour under an unchanged codehash and pins nothing about what it
/// accepts — never a Type's mandatory rule, only a policy row installed by `activatePolicy` (a refusal is
/// `E_POLICY_REJECTED`). The test sets the mode between publications; `accept` runs under `STATICCALL` and
/// cannot change it. Mode ACCEPT also applies the context law and the prototype's `minBody` threshold.
contract MockAcceptor is IAcceptor {
    uint8 public constant ACCEPT = 0;
    uint8 public constant REJECT = 1;
    uint8 public constant REVERT = 2;
    uint8 public constant LOOP = 3;
    uint8 public constant EXHAUST = 4;

    error MockAcceptorRefused(bytes32 typeId);

    uint8 public mode;
    uint256 public minBody;

    function set(uint8 mode_, uint256 minBody_) external {
        mode = mode_;
        minBody = minBody_;
    }

    function accept(
        AcceptContext calldata ctx,
        bytes calldata body,
        bytes32[] calldata,
        RefHeader[] calldata
    ) external view returns (bytes4) {
        uint8 m = mode;
        if (m == REJECT) return ACCEPTOR_REFUSAL;
        if (m == REVERT) revert MockAcceptorRefused(ctx.typeId);
        if (m == LOOP) {
            assembly {
                for {} 1 {} {}
            }
        }
        if (m == EXHAUST) {
            bytes32 w = EXHAUSTED;
            assembly ("memory-safe") {
                mstore(0, w)
                return(0, 0x20)
            }
        }
        if (ctx.ledger != msg.sender || body.length < minBody) return ACCEPTOR_REFUSAL;
        return IAcceptor.accept.selector;
    }
}
