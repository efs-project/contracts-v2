// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {E_CODE_SHAPE} from "../interfaces/Errors.sol";

/// @title CodeScan — the plain-runtime check at every EFS code pin
/// @notice A plain runtime cannot hand its behaviour to other code or replace itself: no `DELEGATECALL`
///         (0xf4), `CALLCODE` (0xf2), `SELFDESTRUCT` (0xff), `CREATE` (0xf0) or `CREATE2` (0xf5) at an
///         executable position, and not a proxy shape (design §2.2 S6/S16, §8.3 step 5g, §8.5, §9.4).
///         ERC-1967 and beacon proxies delegate, so they fail as forbidden opcodes; the exact EIP-1167
///         minimal proxy fails with its own reason. The two proxied implementations are pinned by
///         codehash and never scanned (the ledger must `DELEGATECALL` its delegates).
/// @dev Consumer-closure library: pure/view, no storage, no external calls beyond `extcodesize` and
///      `extcodecopy`. Reasons are `CodePins`' catalog: 0 plain · 1 no code · 2 EIP-7702 designator ·
///      3 forbidden opcode · 4 trailer malformed · 5 EIP-1167 minimal proxy.
///
///      The walk follows the EVM's own jump-destination analysis: a linear pass from byte 0 in which
///      `PUSH1`..`PUSH32` (0x60..0x7f) own their immediates. The last two bytes are a big-endian `u16`
///      `L` naming the solc CBOR trailer, the last `L + 2` bytes (`L + 2 > size` is reason 4). Under
///      `bytecode_hash = "none"` the trailer is `a1 64 "solc" 43 <maj min patch> 00 0a` (`L = 10`).
///      Every forbidden opcode in the code region `[0, size - L - 2)` refuses. The trailer region is
///      skipped as data only where execution cannot reach it, because a crafted runtime can name any
///      `L`: the walk continues through it, and a forbidden opcode there still refuses (reason 3) when
///      it is live — reachable by falling through from the last code-region instruction (or from pc 0),
///      or after a `JUMPDEST` in the trailer, without an intervening `STOP`, `JUMP`, `RETURN`, `REVERT`
///      or `INVALID`. Undefined opcodes count as non-halting, so a later fork cannot open a path. A solc
///      trailer holds no forbidden byte and no `JUMPDEST`, so it never refuses; an IPFS-hash trailer
///      (third-party builds) refuses only when its hash bytes are live and hold a forbidden opcode.
///      Fail-closed residue: data sections inside the code region (via-IR appends them after the final
///      `INVALID`) are walked as code, so a forbidden byte there refuses a runtime that could never
///      execute it; EFS units are measured against this at C1.
///
///      Gas: one table lookup per instruction (no bounds check: 64 sentinel bytes of 0xff stop the walk),
///      unrolled 16 times; ≈ 32 gas per instruction walked (`test/unit/CodeScan.t.sol` logs the figures).
library CodeScan {
    /// Bit `op` set for each forbidden opcode: f0 CREATE, f2 CALLCODE, f4 DELEGATECALL, f5 CREATE2,
    /// ff SELFDESTRUCT.
    uint256 private constant FORBIDDEN =
        0x8035000000000000000000000000000000000000000000000000000000000000;
    /// Bit `op` set for each opcode after which the next instruction is not reached by falling through:
    /// 00 STOP, 56 JUMP, f3 RETURN, fd REVERT, fe INVALID.
    uint256 private constant HALTING =
        0x6008000000000000000000000000000000000000004000000000000000000001;
    /// Advance table words (one byte per opcode): 1 for an ordinary opcode, 2..33 for PUSH1..PUSH32
    /// (word 3, opcodes 0x60..0x7f), 0 for a forbidden opcode (word 7, opcodes 0xe0..0xff).
    uint256 private constant ONES =
        0x0101010101010101010101010101010101010101010101010101010101010101;
    uint256 private constant PUSHES =
        0x02030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f2021;
    uint256 private constant HIGH =
        0x0101010101010101010101010101010100010001000001010101010101010100;
    /// EIP-1167: `363d3d373d3d3d363d73 ‖ implementation ‖ 5af43d82803e903d91602b57fd5bf3` (45 bytes).
    uint256 private constant MINIMAL_PROXY_HEAD = 0x363d3d373d3d3d363d73;
    uint256 private constant MINIMAL_PROXY_TAIL = 0x5af43d82803e903d91602b57fd5bf3;
    /// Bytes of scratch before the copied runtime: the 256-entry table plus one word of read slack.
    uint256 private constant TABLE_BYTES = 0x120;

    /// Reverts `E_CODE_SHAPE(target, reason)` unless `target`'s runtime is plain (`scan` returns 0).
    function requirePlainRuntime(address target) internal view {
        uint256 size = target.code.length;
        (uint256 table, uint256 code) = _reserve(size);
        assembly ("memory-safe") {
            extcodecopy(target, code, 0, size)
        }
        uint8 reason = _walk(table, code, size);
        _release(table);
        if (reason != 0) revert E_CODE_SHAPE(target, reason);
    }

    /// The scan over an in-memory runtime (`runtime` is not modified): 0 when plain, else the reason.
    function scan(bytes memory runtime) internal pure returns (uint8 reason) {
        uint256 size = runtime.length;
        (uint256 table, uint256 code) = _reserve(size);
        assembly ("memory-safe") {
            mcopy(code, add(runtime, 0x20), size)
        }
        reason = _walk(table, code, size);
        _release(table);
    }

    /// Allocates the table, the runtime copy and the sentinel slack at the free memory pointer.
    function _reserve(uint256 size) private pure returns (uint256 table, uint256 code) {
        assembly ("memory-safe") {
            table := mload(0x40)
            code := add(table, TABLE_BYTES)
            mstore(0x40, and(add(add(code, size), 0x5f), not(0x1f)))
        }
    }

    /// Frees the scratch `_reserve` took, so scanning several units costs the largest one's memory once.
    /// Nothing is allocated between the two calls.
    function _release(uint256 table) private pure {
        assembly ("memory-safe") {
            mstore(0x40, table)
        }
    }

    /// The walk over `size` bytes at `code`, with `TABLE_BYTES` of scratch at `table` and 64 bytes of
    /// slack after the runtime (both from `_reserve`). Leaves the runtime bytes as it found them.
    function _walk(uint256 table, uint256 code, uint256 size) private pure returns (uint8 reason) {
        assembly ("memory-safe") {
            function walk(t, c, n) -> r {
                if iszero(n) {
                    r := 1
                    leave
                }
                let head := mload(c)
                if and(eq(n, 23), eq(shr(232, head), 0xef0100)) {
                    r := 2
                    leave
                }
                if eq(n, 45) {
                    if and(
                        eq(shr(176, head), MINIMAL_PROXY_HEAD),
                        eq(and(mload(add(c, 13)), sub(shl(120, 1), 1)), MINIMAL_PROXY_TAIL)
                    ) {
                        r := 5
                        leave
                    }
                }
                if lt(n, 2) {
                    r := 4
                    leave
                }
                let trailer := add(shr(240, mload(add(c, sub(n, 2)))), 2)
                if gt(trailer, n) {
                    r := 4
                    leave
                }
                let codeEnd := add(c, sub(n, trailer))

                mstore(t, ONES)
                mstore(add(t, 0x20), ONES)
                mstore(add(t, 0x40), ONES)
                mstore(add(t, 0x60), PUSHES)
                mstore(add(t, 0x80), ONES)
                mstore(add(t, 0xa0), ONES)
                mstore(add(t, 0xc0), ONES)
                mstore(add(t, 0xe0), HIGH)

                // Sentinels: a PUSH32 starting before `codeEnd` lands at most 32 bytes past it, on 0xff
                // (advance 0), so the walk stops there without a bounds check. Restored below.
                let saved0 := mload(codeEnd)
                let saved1 := mload(add(codeEnd, 0x20))
                mstore(codeEnd, not(0))
                mstore(add(codeEnd, 0x20), not(0))

                // A forbidden opcode or a sentinel has advance 0, so the pointer stays on it until the
                // check at the end of the group of 16.
                let p := c
                let group := c
                for {} 1 {} {
                    group := p
                    p := add(p, byte(0, mload(add(t, byte(0, mload(p))))))
                    p := add(p, byte(0, mload(add(t, byte(0, mload(p))))))
                    p := add(p, byte(0, mload(add(t, byte(0, mload(p))))))
                    p := add(p, byte(0, mload(add(t, byte(0, mload(p))))))
                    p := add(p, byte(0, mload(add(t, byte(0, mload(p))))))
                    p := add(p, byte(0, mload(add(t, byte(0, mload(p))))))
                    p := add(p, byte(0, mload(add(t, byte(0, mload(p))))))
                    p := add(p, byte(0, mload(add(t, byte(0, mload(p))))))
                    p := add(p, byte(0, mload(add(t, byte(0, mload(p))))))
                    p := add(p, byte(0, mload(add(t, byte(0, mload(p))))))
                    p := add(p, byte(0, mload(add(t, byte(0, mload(p))))))
                    p := add(p, byte(0, mload(add(t, byte(0, mload(p))))))
                    p := add(p, byte(0, mload(add(t, byte(0, mload(p))))))
                    p := add(p, byte(0, mload(add(t, byte(0, mload(p))))))
                    p := add(p, byte(0, mload(add(t, byte(0, mload(p))))))
                    p := add(p, byte(0, mload(add(t, byte(0, mload(p))))))
                    if iszero(byte(0, mload(add(t, byte(0, mload(p)))))) { break }
                }
                mstore(codeEnd, saved0)
                mstore(add(codeEnd, 0x20), saved1)
                if lt(p, codeEnd) {
                    r := 3
                    leave
                }

                // The trailer region, from the first instruction at or after `codeEnd` (inside it when
                // a PUSH straddles the boundary). It is live on entry when pc 0 is in it or when the
                // last code-region instruction falls through; the last group holds that instruction
                // and no forbidden opcode.
                let live := eq(codeEnd, c)
                if iszero(live) {
                    let last := group
                    for { let q := group } lt(q, codeEnd) {} {
                        last := q
                        q := add(q, byte(0, mload(add(t, byte(0, mload(q))))))
                    }
                    live := iszero(and(shr(byte(0, mload(last)), HALTING), 1))
                }
                let end := add(c, n)
                for { let q := p } lt(q, end) {} {
                    let op := byte(0, mload(q))
                    if eq(op, 0x5b) { live := 1 }
                    if and(live, and(shr(op, FORBIDDEN), 1)) {
                        r := 3
                        leave
                    }
                    if and(shr(op, HALTING), 1) { live := 0 }
                    let a := byte(0, mload(add(t, op)))
                    q := add(q, add(a, iszero(a)))
                }
            }
            reason := walk(table, code, size)
        }
    }
}
