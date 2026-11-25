// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FilesName} from "./FilesNameRule.sol";

// SPIKE (tags/topics, owner rulings 2026-11-25): the Topics profile beside the Files profile. A topic is a path of
// words (`/cars/tesla`); its identity is the path. A word is shared: its page `topic-word/1` is also the root-level
// topic `/<word>`. A path of two or more words is one `topic/1` record `[parent, wordPage]`. Topics are unowned:
// a record id is `Keys.record(typeId, body)`, so anyone computes a topic's id from its words with no chain read
// (`TopicTypes.pathId`). Not for merge as-is.

/// A Topics rule refused the record; `code` is listed on `TopicWord.refusal`, `TopicWordRule` and `TopicRule`.
error E_TOPIC_REFUSED(uint8 code); // none

/// @title TopicWord — the `topic-word/1` grammar (SPIKE)
/// @notice A word is 1..255 bytes of well-formed UTF-8, byte-exact (nothing is normalized; lowercasing beyond
///         ASCII and NFC are SDK obligations). `refusal` returns 0 when the word is admitted, else the first
///         refusal in this order: 1 empty or longer than 255 bytes; then, scanning bytes in order, 2 malformed
///         UTF-8 (an overlong form, a surrogate U+D800..U+DFFF, a value above U+10FFFF, a stray continuation byte
///         or a truncated sequence) or 3 a forbidden ASCII byte (`/`, a control 0x00..0x1f or 0x7f, space, `A`–`Z`),
///         whichever comes first; then 4 the word is `.` or `..`; 5 it starts with `~`; 6 it is `0x` followed by
///         exactly 40 characters of `0-9a-f` (it would shadow a home address in a link). Rules 5 and 6 apply to
///         every word because every word has a root-level page.
/// @dev Pure over calldata, one byte at a time on the ASCII path (one bitmap test), one calldata word per
///      multi-byte scalar (`FilesName.scalar`, the decoder `files-name/2` already ships). `utf8Refusal` and
///      `asciiClassRefusal` are the two halves of the byte loop, exposed only so the measurement can price each.
library TopicWord {
    /// Bit c set for an admitted ASCII byte: 0x21..0x7e minus `/` (0x2f) and `A`–`Z` (0x41..0x5a).
    uint256 internal constant ASCII_OK = 0x7ffffffff8000001ffff7ffe00000000;
    /// Bit c set for `0-9a-f`.
    uint256 internal constant HEX_LOWER = 0x7e0000000003ff000000000000;
    uint256 internal constant MAX = 255;

    function refusal(bytes calldata w) internal pure returns (uint256) {
        uint256 n = w.length;
        if (n == 0 || n > MAX) return 1;
        uint256 i;
        while (i < n) {
            uint256 b;
            assembly ("memory-safe") {
                b := byte(0, calldataload(add(w.offset, i)))
            }
            if (b < 0x80) {
                if ((ASCII_OK >> b) & 1 == 0) return 3;
                unchecked {
                    ++i;
                }
            } else {
                (, uint256 width) = FilesName.scalar(w, i, n);
                if (width == 0) return 2;
                unchecked {
                    i += width;
                }
            }
        }
        return _shape(w, n);
    }

    /// Rules 4–6 on a word whose bytes already passed (the whole-word shapes).
    function _shape(bytes calldata w, uint256 n) private pure returns (uint256) {
        uint256 head;
        assembly ("memory-safe") {
            head := calldataload(w.offset)
        }
        uint256 b0 = head >> 248;
        if (b0 == 0x2e && (n == 1 || (n == 2 && (head >> 240) & 0xff == 0x2e))) return 4;
        if (b0 == 0x7e) return 5;
        if (n == 42 && head >> 240 == 0x3078) {
            for (uint256 i = 2; i < 42; ++i) {
                uint256 c;
                assembly ("memory-safe") {
                    c := byte(0, calldataload(add(w.offset, i)))
                }
                if ((HEX_LOWER >> c) & 1 == 0) return 0;
            }
            return 6;
        }
        return 0;
    }

    /// Measurement half 1: only the UTF-8 decoder (ASCII bytes are skipped unchecked). 2 malformed, else 0.
    function utf8Refusal(bytes calldata w) internal pure returns (uint256) {
        uint256 n = w.length;
        uint256 i;
        while (i < n) {
            uint256 b;
            assembly ("memory-safe") {
                b := byte(0, calldataload(add(w.offset, i)))
            }
            if (b < 0x80) {
                unchecked {
                    ++i;
                }
            } else {
                (, uint256 width) = FilesName.scalar(w, i, n);
                if (width == 0) return 2;
                unchecked {
                    i += width;
                }
            }
        }
        return 0;
    }

    /// Measurement half 2: only the ASCII class test (non-ASCII bytes are skipped one at a time). 3 forbidden.
    function asciiClassRefusal(bytes calldata w) internal pure returns (uint256) {
        uint256 n = w.length;
        for (uint256 i; i < n; ++i) {
            uint256 b;
            assembly ("memory-safe") {
                b := byte(0, calldataload(add(w.offset, i)))
            }
            if (b < 0x80 && (ASCII_OK >> b) & 1 == 0) return 3;
        }
        return 0;
    }
}
