// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {DescribedCodec} from "./DescribedCodec.sol";
import {Keys} from "../lib/Keys.sol";
import {CodePins} from "../lib/CodePins.sol";
import {ClosureConstants} from "../interfaces/Limits.sol";
import {IAcceptor, AcceptContext, RefHeader, EXHAUSTED} from "../interfaces/IAcceptor.sol";
import {IDescribedWrapper} from "../interfaces/internal/IDescribedWrapper.sol";
import {
    E_BINDING,
    E_BLOB,
    E_CODEC,
    E_GRADE,
    E_LEDGER,
    E_REF,
    E_REJECTED,
    E_TYPE_MISMATCH,
    E_WRAPPER
} from "../interfaces/Errors.sol";

/// @title DescribedTypeRule — `DescribedTypeRule/1`, the singleton wrapper acceptor of grades 1–2 (design §5.10)
/// @notice The mandatory rule of every STRUCTURAL and CUSTOM Type. Per acceptance it reloads the descriptor
///         from `ctx.descriptorBlob`, re-derives the Type id from the descriptor, the reference Types it
///         projects and its own codehash, re-checks the grade, the custom predicate's codehash and the
///         binding id, applies the codec-1 body law, then (grade 2) nests the custom predicate. Supplied
///         context alone is not authentication: `ctx.ledger == msg.sender` comes first.
/// @dev No storage, no immutables, no constructor: the runtime, hence the codehash every grade-1/2 Type id
///      commits to, is identical on every Realm and chain. Every external call is a `STATICCALL` with a
///      computed gas forward; at most 32 bytes are copied back from a predicate.
///
///      Refusals revert with a catalog error (`Errors.sol`). The kernel discards acceptor revert data and
///      reports `E_REJECTED(leaf, typeId)`, so the SDK simulates `accept` directly (as the ledger) to read
///      the reason: `E_LEDGER()` caller is not `ctx.ledger` · `E_BLOB(blob)` not STOP-prefixed, or shorter
///      than the header or than the length the header declares · `E_CODEC(offset, code)` the descriptor
///      grammar, or a declared length over 4,096 · `E_TYPE_MISMATCH(leaf, ctx.typeId, recomputed)` ·
///      `E_GRADE(grade)` grade 3, or not `ctx.grade` · `E_WRAPPER(2)` `ruleCodehash` is not this build ·
///      `E_CODE_SHAPE(predicate, 1|2)` no code, or a designator · `E_BINDING(3)` predicate codehash is not
///      `customHash` · `E_BINDING(10)` the binding id differs · `E_BINDING(1)` a grade-1 context carrying a
///      predicate or a binding id · `E_REF(leaf, i, 1|2)` reference header missing, or of another Type ·
///      `E_BODY(leaf, code)` the body law · `E_REJECTED(leaf, typeId)` the nested predicate refused. Nested
///      exhaustion is not a refusal: the reply is the reserved word `EXHAUSTED` (`E_ACCEPTOR_GAS`, resubmit).
contract DescribedTypeRule is IDescribedWrapper {
    /// The grammar profile this build implements (read once by `activateWrapper`).
    bytes32 internal constant GRAMMAR_PROFILE = keccak256("efs2/described-grammar/1");
    /// The registry's binding preimage domain (`TypeRegistry.BINDING_DOMAIN`, design §9.3).
    bytes32 internal constant BINDING_DOMAIN = keccak256("efs2/described-binding/1");
    /// `customAbi` 1: the predicate is an IAcceptor/2 called with the wrapper's context unchanged.
    uint256 internal constant CUSTOM_ABI_NESTED = 1;
    /// Gas kept back from every nested call, on top of the 1/64 the EVM keeps, to classify and reply.
    uint256 internal constant RESERVE = 5_000;
    /// A failed nested call with empty returndata that used at least `forward - SLACK` is exhaustion.
    uint256 internal constant SLACK = 2_000;
    /// The most revert data re-raised from the wrapper's own law (its largest error is 100 bytes).
    uint256 internal constant REVERT_MAX = 0x84;
    /// Outcomes of `_nest`.
    uint256 internal constant FAILED = 0;
    uint256 internal constant EXHAUSTION = 1;
    uint256 internal constant RETURNED = 2;
    uint256 internal constant SELECTOR = 3;

    /// @inheritdoc IDescribedWrapper
    function codecVersion() external pure returns (uint8) {
        return 1;
    }

    /// @inheritdoc IDescribedWrapper
    function grammarProfile() external pure returns (bytes32) {
        return GRAMMAR_PROFILE;
    }

    /// @inheritdoc IAcceptor
    function accept(
        AcceptContext calldata ctx,
        bytes calldata,
        bytes32[] calldata,
        RefHeader[] calldata
    ) external view returns (bytes4) {
        if (ctx.ledger != msg.sender) revert E_LEDGER();
        // The codec reads calldata, so the law re-enters this build by STATICCALL: `check` with this call's
        // own arguments and the descriptor appended. Its refusal reason is re-raised; its exhaustion is
        // reported like a predicate's.
        uint256 outcome = _nest(address(this), _checkCall(ctx.descriptorBlob));
        if (outcome == EXHAUSTION) return _exhausted();
        if (outcome == FAILED) _reraise();
        if (ctx.grade == DescribedCodec.GRADE_CUSTOM) {
            // The predicate receives the context and the arguments unchanged: this call's own calldata,
            // verbatim (the same IAcceptor/2 `accept` selector).
            outcome = _nest(ctx.customPredicate, _ownCalldata());
            if (outcome == EXHAUSTION) return _exhausted();
            if (outcome != SELECTOR) revert E_REJECTED(ctx.leaf, ctx.typeId);
        }
        return IAcceptor.accept.selector;
    }

    /// The wrapper's law over one acceptance: everything `accept` applies except the caller check and the
    /// nested predicate; returns normally or reverts with the reason. The descriptor travels after the
    /// ABI-encoded arguments as `descriptor ‖ uint256(descriptor.length)` (the ABI decoder ignores trailing
    /// calldata), so `accept` forwards its own arguments without re-encoding them. Pure over its calldata and
    /// code hashes: `accept` calls it on itself, and the SDK may call it directly to dry-run a body.
    function check(
        AcceptContext calldata ctx,
        bytes calldata body,
        bytes32[] calldata refs,
        RefHeader[] calldata refHeaders
    ) external view {
        bytes calldata descriptor;
        bool short;
        assembly ("memory-safe") {
            let end := sub(calldatasize(), 0x20)
            let length := calldataload(end)
            short := gt(length, end)
            descriptor.offset := sub(end, length)
            descriptor.length := length
        }
        if (short) revert E_CODEC(0, 1);
        (DescribedCodec.Header memory h, bytes32[] memory refTypes) =
            DescribedCodec.parse(descriptor);
        bytes32 self = address(this).codehash;
        bytes32 id = Keys.typeId(Keys.shape(descriptor), refTypes, self);
        if (id != ctx.typeId) revert E_TYPE_MISMATCH(ctx.leaf, ctx.typeId, id);
        if (h.grade != ctx.grade || h.grade == DescribedCodec.GRADE_NATIVE) {
            revert E_GRADE(h.grade);
        }
        if (h.ruleCodehash != self) revert E_WRAPPER(2);
        address custom = ctx.customPredicate;
        if (h.grade == DescribedCodec.GRADE_CUSTOM) {
            CodePins.requireRealCode(custom);
            if (custom.codehash != h.auxHash) revert E_BINDING(3);
            bytes32 bindingId = keccak256(
                abi.encode(
                    BINDING_DOMAIN,
                    self,
                    block.chainid,
                    ctx.registry,
                    id,
                    custom,
                    h.auxHash,
                    CUSTOM_ABI_NESTED,
                    h.declarationKey
                )
            );
            if (bindingId != ctx.bindingId) revert E_BINDING(10);
        } else if (custom != address(0) || ctx.bindingId != 0) {
            revert E_BINDING(1);
        }
        // The descriptor, not the registry's stored row, is the Type: the reference headers the kernel loaded
        // must carry the Types the descriptor projects (always the row's Types under an honest registry).
        for (uint256 i; i < refTypes.length; ++i) {
            // forge-lint: disable-next-line(unsafe-typecast)
            uint8 pos = uint8(i); // i < DescribedCodec.MAX_REFS
            if (i >= refHeaders.length) revert E_REF(ctx.leaf, pos, 1);
            bytes32 want = refTypes[i];
            if (uint256(want) == DescribedCodec.REF_SELF) want = id;
            if (want != 0 && refHeaders[i].typeId != want) revert E_REF(ctx.leaf, pos, 2);
        }
        DescribedCodec.validateBody(descriptor, h, body, refs, ctx.leaf);
    }

    /// The self-call's calldata: `check`'s selector, this call's arguments, then the descriptor of the
    /// STOP-prefixed blob `0x00 ‖ descriptor ‖ declarationSig` and its length. The length is read from the
    /// descriptor's own header (codec 1 has no index specs or sections) and bounded before anything else is
    /// copied: a blob shorter than the header or than `1 + length`, or not STOP-prefixed, refuses `E_BLOB`; a
    /// declared length over 4,096 refuses `E_CODEC(0, 1)` (it is at least 134 by construction).
    function _checkCall(address blob) private view returns (bytes memory data) {
        uint256 size = blob.code.length;
        if (size < 1 + DescribedCodec.HEADER) revert E_BLOB(blob);
        uint256 prefix;
        uint256 length;
        assembly ("memory-safe") {
            let p := mload(0x40)
            extcodecopy(blob, p, 0, 0x88) // the STOP byte and the 134-byte header
            prefix := byte(0, mload(p))
            // 134 + nameLength (d[13]) + descriptionLength (d[130..131]) + fieldCount (d[3]) × 164
            length := add(
                add(134, byte(0, mload(add(p, 14)))),
                add(shr(240, mload(add(p, 131))), mul(byte(0, mload(add(p, 4))), 164))
            )
        }
        if (prefix != 0) revert E_BLOB(blob);
        if (length > ClosureConstants.DESCRIPTOR_MAX) revert E_CODEC(0, 1);
        if (size < 1 + length) revert E_BLOB(blob);
        uint256 args = msg.data.length;
        data = new bytes(args + length + 32);
        bytes4 selector = this.check.selector;
        assembly ("memory-safe") {
            let p := add(data, 0x20)
            calldatacopy(p, 0, args)
            mstore(p, or(selector, shr(32, shl(32, mload(p))))) // replace the 4-byte selector
            extcodecopy(blob, add(p, args), 1, length)
            mstore(add(add(p, args), length), length)
        }
    }

    /// This call's own calldata, copied to memory.
    function _ownCalldata() private pure returns (bytes memory data) {
        assembly ("memory-safe") {
            data := mload(0x40)
            mstore(data, calldatasize())
            calldatacopy(add(data, 0x20), 0, calldatasize())
            mstore(0x40, add(add(data, 0x20), calldatasize()))
        }
    }

    /// One `STATICCALL` under the 63/64 rule with `RESERVE` kept back and a 32-byte output buffer; nothing
    /// is copied back. `EXHAUSTION` when there is no gas to try, or the call failed with empty returndata
    /// having used at least its forward − `SLACK`; `FAILED` for any other failure; `SELECTOR` when it
    /// returned exactly the 32-byte word `bytes32(IAcceptor.accept.selector)`; `RETURNED` otherwise.
    function _nest(address target, bytes memory data) private view returns (uint256 outcome) {
        uint256 g = gasleft();
        if (g <= RESERVE) return EXHAUSTION;
        uint256 forward = (g - RESERVE) * 63 / 64;
        bytes32 success = bytes32(IAcceptor.accept.selector);
        assembly ("memory-safe") {
            let ok := staticcall(forward, target, add(data, 0x20), mload(data), 0, 0x20)
            let size := returndatasize()
            switch ok
            case 0 {
                if and(iszero(size), iszero(lt(add(sub(g, gas()), SLACK), forward))) {
                    outcome := EXHAUSTION
                }
            }
            default {
                outcome := RETURNED
                if and(eq(size, 0x20), eq(mload(0), success)) { outcome := SELECTOR }
            }
        }
    }

    /// Re-raises the last call's revert data, at most `REVERT_MAX` bytes (the wrapper's own law only).
    function _reraise() private pure {
        assembly ("memory-safe") {
            let p := mload(0x40)
            let n := returndatasize()
            if gt(n, REVERT_MAX) { n := REVERT_MAX }
            returndatacopy(p, 0, n)
            revert(p, n)
        }
    }

    /// Replies with the reserved 32-byte word `EXHAUSTED` (never a 4-byte value) and ends the call.
    function _exhausted() private pure returns (bytes4) {
        bytes32 w = EXHAUSTED;
        assembly ("memory-safe") {
            mstore(0, w)
            return(0, 0x20)
        }
    }
}
