// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IAcceptor, AcceptContext, RefHeader} from "../interfaces/IAcceptor.sol";
import {FilesProfile, E_FILES_REFUSED} from "./FilesProfile.sol";

/// @title FilesName — the `files-name/2` grammar (design §12.1; naming reconciliation §4.1)
/// @notice Ported from the measured experiment arm `NameV2F` (`planning/Reviews/2026-09-26-efs-v2-naming-reconciliation/
///         experiment/src/NameFast.sol` `FastName.valid(d, false)` with `NameRules.sol` `Utf8.excluded`/`whitespace`):
///         same acceptance set, same ASCII fast path and single-word scalar decoder. A name is raw UTF-8, 1–255 bytes,
///         byte-exact and case-sensitive (nothing is normalized; NFC is an SDK obligation, never a contract claim):
///         strict UTF-8 scalars (no overlong forms, surrogates or values above U+10FFFF); not `.` or `..`; no C0/C1
///         controls, DEL, `/` or `\`; no U+2028/2029; no bidi controls (U+061C, U+200E/F, U+202A–E, U+2066–9); no pure
///         invisibles (U+00AD, U+180E, U+200B, U+2060–2064, U+206A–206F, U+FEFF); no U+FFF9–FFFD; no noncharacters
///         (U+FDD0–FDEF, U+xFFFE/xFFFF); no leading or trailing Unicode whitespace; no `~efs` prefix (reserved for host
///         and control synthetic entries). ZWJ/ZWNJ, variation selectors and tag characters are allowed.
library FilesName {
    /// 0x20..0x7e minus '/' (0x2f) and '\' (0x5c). Whitespace at the ends is checked after the loop.
    uint256 internal constant ASCII_OK = 0x7fffffffefffffffffff7fff00000000;

    function valid(bytes calldata d) internal pure returns (bool) {
        uint256 n = d.length;
        if (n == 0 || n > 255) return false;
        uint256 head;
        assembly ("memory-safe") {
            head := calldataload(d.offset)
        }
        uint256 b0 = head >> 248;
        if (b0 == 0x2e && (n == 1 || (n == 2 && ((head >> 240) & 0xff) == 0x2e))) return false;
        if (n >= 4 && (head >> 224) == 0x7e656673) return false; // "~efs"
        uint32 first;
        uint32 last;
        uint256 i;
        while (i < n) {
            uint256 b;
            assembly ("memory-safe") {
                b := byte(0, calldataload(add(d.offset, i)))
            }
            uint32 s;
            uint256 w;
            if (b < 0x80) {
                if ((ASCII_OK >> b) & 1 == 0) return false;
                s = uint32(b);
                w = 1;
            } else {
                (s, w) = scalar(d, i, n);
                if (w == 0 || excluded(s)) return false;
            }
            if (i == 0) first = s;
            last = s;
            unchecked {
                i += w;
            }
        }
        return !whitespace(first) && !whitespace(last);
    }

    /// One calldata word per scalar; bytes past the end read as zero and are refused by the length checks.
    /// Returns (scalar, width); width 0 means malformed at `i`.
    function scalar(bytes calldata d, uint256 i, uint256 n)
        internal
        pure
        returns (uint32 s, uint256 w)
    {
        uint256 word;
        assembly ("memory-safe") {
            word := calldataload(add(d.offset, i))
        }
        uint256 b0 = word >> 248;
        uint256 b1 = (word >> 240) & 0xff;
        if (b0 < 0xc2 || b0 > 0xf4 || (b1 & 0xc0) != 0x80) return (0, 0);
        if (b0 <= 0xdf) {
            if (i + 2 > n) return (0, 0);
            return (uint32(((b0 & 0x1f) << 6) | (b1 & 0x3f)), 2);
        }
        uint256 b2 = (word >> 232) & 0xff;
        if ((b2 & 0xc0) != 0x80) return (0, 0);
        if (b0 <= 0xef) {
            if (i + 3 > n) return (0, 0);
            uint256 v = ((b0 & 0x0f) << 12) | ((b1 & 0x3f) << 6) | (b2 & 0x3f);
            if (v < 0x800 || (v >= 0xd800 && v <= 0xdfff)) return (0, 0);
            return (uint32(v), 3);
        }
        uint256 b3 = (word >> 224) & 0xff;
        if (i + 4 > n || (b3 & 0xc0) != 0x80) return (0, 0);
        uint256 u = ((b0 & 0x07) << 18) | ((b1 & 0x3f) << 12) | ((b2 & 0x3f) << 6) | (b3 & 0x3f);
        if (u < 0x10000 || u > 0x10ffff) return (0, 0);
        return (uint32(u), 4);
    }

    /// Per-scalar exclusions: controls, separators, line/paragraph separators, bidi controls, pure invisibles,
    /// BOM, object/replacement characters, noncharacters.
    function excluded(uint32 s) internal pure returns (bool) {
        if (s <= 0x1f) return true;
        if (s < 0x7f) return s == 0x2f || s == 0x5c;
        if (s <= 0x9f) return true; // DEL and C1
        if (s == 0xad) return true; // soft hyphen
        if (s == 0x061c) return true; // Arabic letter mark (bidi control)
        if (s < 0x180e) return false;
        if (s == 0x180e) return true; // Mongolian vowel separator
        if (s < 0x200b) return false;
        if (s == 0x200b || s == 0x200e || s == 0x200f) return true; // ZWSP, LRM, RLM
        if (s >= 0x202a && s <= 0x202e) return true; // bidi embeddings/overrides
        if (s == 0x2028 || s == 0x2029) return true; // line / paragraph separator
        if (s >= 0x2060 && s <= 0x2064) return true; // WJ and invisible operators
        if (s >= 0x2066 && s <= 0x206f) return true; // bidi isolates, deprecated format chars
        if (s < 0xfdd0) return false;
        if (s <= 0xfdef) return true; // noncharacters block
        if (s == 0xfeff) return true; // BOM / ZWNBSP
        if (s >= 0xfff9 && s <= 0xfffd) return true; // interlinear annotations, OBJ, REPLACEMENT
        if ((s & 0xfffe) == 0xfffe) return true; // U+xFFFE, U+xFFFF in every plane
        return false;
    }

    /// Unicode White_Space minus the code points already excluded above.
    function whitespace(uint32 s) internal pure returns (bool) {
        return s == 0x20 || s == 0xa0 || s == 0x1680 || (s >= 0x2000 && s <= 0x200a) || s == 0x202f
            || s == 0x205f || s == 0x3000;
    }
}

/// @title FilesNameRule — the mandatory rule of `files-name/2` (design §12.1)
/// @notice §12.1 row: "`files-name/2` | NATIVE | raw UTF-8, 1–255 B, well-formed, byte-exact, case-sensitive, `~efs`
///         reserved | none | the measured 1,477-byte validator (naming reconciliation ... experiment `NameV2F`, 4–14k
///         gas for ordinary names; the prototype's ASCII `FilesNameRule` at `L/test/FilesNamesProfile.sol:73` is the
///         structural analog); pending N1/N2 (Q7)". The body is the name itself; a FOLDER bind's role is
///         `keccak256(name)` and `FilesFinalValidator` requires the record `recordFromHash(nameType, role)`.
/// @dev Pure over calldata. Refusal codes (`E_FILES_REFUSED`): 1 refs present, 2 not a `files-name/2` name.
contract FilesNameRule is IAcceptor {
    function accept(
        AcceptContext calldata ctx,
        bytes calldata body,
        bytes32[] calldata refs,
        RefHeader[] calldata refHeaders
    ) external view returns (bytes4) {
        FilesProfile.requireLedger(ctx);
        if (refs.length != 0 || refHeaders.length != 0) revert E_FILES_REFUSED(1);
        if (!FilesName.valid(body)) revert E_FILES_REFUSED(2);
        return IAcceptor.accept.selector;
    }
}
