// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IIndexReads} from "../../../src/interfaces/IIndexReads.sol";
import {IBitmapStore} from "../../../src/interfaces/IBitmapStore.sol";

/// @notice A read wrapper over an index reads contract or a bitmap store that forwards every read faithfully and
///         REVERTS any entry read asking for more than `CAP` entries or words: `postingSliceOf` (`n`),
///         `scopeSlice` (`n`) and `liveWords` (`n`). In front of an index, `bitmapStore()` answers `BITMAP` (another
///         instance in front of the store) when it is set, so both stores' reads pass a cap. Reads only (`STATICCALL`).
contract CountCapReads {
    error E_COUNT(bytes4 selector, uint256 n);

    address public immutable REAL;
    uint256 public immutable CAP;
    address public immutable BITMAP;

    constructor(address real_, uint256 cap_, address bitmap_) {
        REAL = real_;
        CAP = cap_;
        BITMAP = bitmap_;
    }

    fallback() external {
        bytes4 s = msg.sig;
        // the count word: postingSliceOf(family, typeId, ordinal, value, from, n) word 5; scopeSlice(scope, from, n)
        // word 2; liveWords(scope, family, fromWord, n) word 3
        uint256 w = s == IIndexReads.postingSliceOf.selector
            ? 5
            : s == IBitmapStore.scopeSlice.selector
                ? 2
                : s == IBitmapStore.liveWords.selector ? 3 : 0;
        if (w != 0) {
            uint256 n = uint256(bytes32(msg.data[4 + 32 * w:36 + 32 * w]));
            if (n > CAP) revert E_COUNT(s, n);
        }
        if (s == IIndexReads.bitmapStore.selector && BITMAP != address(0)) {
            bytes memory out = abi.encode(BITMAP);
            assembly ("memory-safe") {
                return(add(out, 32), mload(out))
            }
        }
        address real = REAL;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := staticcall(gas(), real, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            if iszero(ok) { revert(0, returndatasize()) }
            return(0, returndatasize())
        }
    }
}
