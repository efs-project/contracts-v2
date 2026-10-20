// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {E_CODE_SHAPE} from "../interfaces/Errors.sol";

/// @title CodePins — real-code, designator and codehash checks for every EFS code pin
/// @notice A pinned dependency must be real code (not an empty account and not an EIP-7702 delegation
///         designator) and must carry the codehash the activation record names (design §2.2 S6/S16,
///         §8.3 step 5g, §8.5, §9.4). `CodeScan.requirePlainRuntime` adds the opcode scan.
/// @dev Consumer-closure library: view only, no storage, no external calls beyond `extcodesize`,
///      `extcodecopy` and `extcodehash`. Every refusal is `E_CODE_SHAPE(target, reason)` with the reasons
///      below; 1–5 are the ones `Errors.sol` names, and **6 (codehash mismatch) is defined here** and
///      belongs in the `Errors.sol` comment beside the others.
///
///      Reasons: 1 no code · 2 EIP-7702 designator · 3 forbidden opcode · 4 trailer malformed ·
///      5 proxy shape (EIP-1167) · 6 codehash mismatch.
library CodePins {
    uint8 internal constant NO_CODE = 1;
    uint8 internal constant DESIGNATOR = 2;
    uint8 internal constant FORBIDDEN_OPCODE = 3;
    uint8 internal constant TRAILER_MALFORMED = 4;
    uint8 internal constant PROXY_SHAPE = 5;
    uint8 internal constant CODEHASH_MISMATCH = 6;

    /// The EIP-7702 delegation designator is exactly `0xef0100 ‖ address`: 23 bytes. EIP-3541 keeps
    /// every other `0xef`-prefixed runtime off chain, so the prefix and the size together are the shape
    /// (the same rule `Keys.principalFor` applies).
    uint256 internal constant DESIGNATOR_SIZE = 23;
    uint24 internal constant DESIGNATOR_PREFIX = 0xef0100;

    /// `extcodehash` of an account that exists and has no code.
    bytes32 internal constant EMPTY_CODEHASH = keccak256("");

    /// True iff `account` holds exactly the 23-byte EIP-7702 delegation designator. The target of the
    /// delegation is never followed.
    function isDesignator(address account) internal view returns (bool) {
        return account.code.length == DESIGNATOR_SIZE && _prefix(account) == DESIGNATOR_PREFIX;
    }

    /// Reverts `E_CODE_SHAPE(account, 1)` for an account without code and `E_CODE_SHAPE(account, 2)`
    /// for an EIP-7702 designator. Any other code passes; whether it is a plain runtime is
    /// `CodeScan.requirePlainRuntime`'s question.
    function requireRealCode(address account) internal view {
        uint256 size = account.code.length;
        if (size == 0) revert E_CODE_SHAPE(account, NO_CODE);
        if (size == DESIGNATOR_SIZE && _prefix(account) == DESIGNATOR_PREFIX) {
            revert E_CODE_SHAPE(account, DESIGNATOR);
        }
    }

    /// Reverts `E_CODE_SHAPE(account, 6)` unless `account.codehash == expected`. A pin never names
    /// absent code: when the hashes agree but are `0` (no account) or `keccak256("")` (no code), the
    /// refusal is `E_CODE_SHAPE(account, 1)`, so a zero or empty-code `expected` cannot pin an empty
    /// address. This does not refuse a designator whose hash happens to be pinned; gates call
    /// `requireRealCode` (or `realCodeAndHash`) first.
    function requireCodehash(address account, bytes32 expected) internal view {
        bytes32 have = account.codehash;
        if (have != expected) revert E_CODE_SHAPE(account, CODEHASH_MISMATCH);
        if (have == bytes32(0) || have == EMPTY_CODEHASH) revert E_CODE_SHAPE(account, NO_CODE);
    }

    /// `requireRealCode(account)`, then the codehash to record in the pin.
    function realCodeAndHash(address account) internal view returns (bytes32) {
        requireRealCode(account);
        return account.codehash;
    }

    /// The first three code bytes of `account`, through the scratch space.
    function _prefix(address account) private view returns (uint24 prefix) {
        assembly ("memory-safe") {
            extcodecopy(account, 0, 0, 3)
            prefix := shr(232, mload(0))
        }
    }
}
