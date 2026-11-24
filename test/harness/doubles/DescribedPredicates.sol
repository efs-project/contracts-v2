// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {AcceptContext, IAcceptor, RefHeader} from "../../../src/interfaces/IAcceptor.sol";
import {ILedgerHot} from "../../../src/interfaces/ILedgerHot.sol";
import {ACCEPTOR_REFUSAL} from "./Acceptors.sol";

// Doubles of the CUSTOM grade (design §5.10, §9.3): a predicate nested by `DescribedTypeRule` with the wrapper's
// context unchanged, and a contract that calls the wrapper as if it were a ledger. The hostile reply shapes
// (returndata bomb, gas burner, `EXHAUSTED`, shaped words) are the IAcceptor/2 doubles of `Acceptors.sol`,
// used as predicates directly.

/// The prototype's `DescribedPredicateFixture` under IAcceptor/2: bound by storage (never immutables) to one
/// wrapper build and one ledger, so identical runtime does NOT mean equivalent state; the creator's binding
/// signature, not the codehash, selects the instance (`L/test/DescribedFixtures.sol`). It authenticates the
/// wrapper by `msg.sender.codehash` and compares the wrapper-attested `ctx.ledger` with its ledger. Modes:
/// ACCEPT; REFUSE (a well-formed refusal word); PREFIX (exactly one ref that the ledger already holds — the
/// ordered prefix of the same publication included — and a body not ending in `!`).
contract WrapperBoundPredicate is IAcceptor {
    uint8 public constant ACCEPT = 0;
    uint8 public constant REFUSE = 1;
    uint8 public constant PREFIX = 2;

    bytes32 public wrapperCodehash;
    address public ledger;
    uint8 public mode;

    constructor(bytes32 wrapperCodehash_, address ledger_) {
        wrapperCodehash = wrapperCodehash_;
        ledger = ledger_;
    }

    function setMode(uint8 mode_) external {
        mode = mode_;
    }

    function accept(
        AcceptContext calldata ctx,
        bytes calldata body,
        bytes32[] calldata refs,
        RefHeader[] calldata
    ) external view returns (bytes4) {
        if (msg.sender.codehash != wrapperCodehash || ctx.ledger != ledger) return ACCEPTOR_REFUSAL;
        uint8 m = mode;
        if (m == REFUSE) return ACCEPTOR_REFUSAL;
        if (m == PREFIX) {
            if (refs.length != 1) return ACCEPTOR_REFUSAL;
            (, uint64 first,,,) = ILedgerHot(ctx.ledger).recordHeader(refs[0]);
            if (first == 0 || first >= ctx.admission) return ACCEPTOR_REFUSAL;
            if (body.length != 0 && body[body.length - 1] == 0x21) return ACCEPTOR_REFUSAL;
        }
        return IAcceptor.accept.selector;
    }
}

/// Burns its forward down to `KEEP` gas, then returns 64 KiB whose first word is the selector shape: the
/// caller keeps only its 1/64 (plus its reserve and what comes back), too little to copy the reply — a caller
/// that copies before bounding runs out of gas instead of refusing with its reason.
contract BurningBomb is IAcceptor {
    uint256 public constant KEEP = 20_000;
    uint256 public constant SIZE = 65_536;

    function accept(
        AcceptContext calldata,
        bytes calldata,
        bytes32[] calldata,
        RefHeader[] calldata
    ) external view returns (bytes4) {
        while (gasleft() > KEEP) {}
        bytes4 s = IAcceptor.accept.selector;
        assembly {
            mstore(0, s)
            return(0, SIZE)
        }
    }
}

/// Calls `target` under an exact gas limit from a contract frame and reports what the call used. Foundry 1.8.3
/// charges a call made directly by the test contract a calldata-proportional cost before the callee runs, so a
/// gas sweep from the test itself is not the EVM's; from this frame it is. The target is warmed first, so
/// `used` is the callee's consumption plus the warm call's own cost.
contract GasRelay {
    function relay(address target, bytes calldata data, uint256 gas)
        external
        returns (bool ok, bytes memory reply, uint256 used)
    {
        if (target.code.length == 0) revert();
        uint256 g = gasleft();
        (ok, reply) = target.call{gas: gas}(data);
        used = g - gasleft();
    }
}

/// A lookalike coordinator: calls a wrapper as if it were the ledger, with `ctx.ledger` set to itself and
/// every other field (the Type id, the blob, the grade, the predicate, the binding id) of its choosing.
contract LookalikeCoordinator {
    function ask(
        address wrapper,
        AcceptContext memory ctx,
        bytes memory body,
        bytes32[] memory refs,
        RefHeader[] memory refHeaders
    ) external view returns (bool ok, bytes memory reply) {
        ctx.ledger = address(this);
        (ok, reply) =
            wrapper.staticcall(abi.encodeCall(IAcceptor.accept, (ctx, body, refs, refHeaders)));
    }
}
