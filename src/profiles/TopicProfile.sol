// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FilesName} from "./FilesNameRule.sol";

/// A Topics-profile rule refused the record; `code` is listed on `TopicProfile.wordRefusal` (1-7),
/// `TopicWordRule` (8), `TopicRule` (10-13), `TopicProfile.textRefusal` (20-23) and `TextRule` (24).
error E_TOPIC_REFUSED(uint8 code); // none

/// @title TopicProfile — the grammars of the Topics Types (docs/TAG-DESIGN.md §1, §8; design §12.5)
/// @notice Three NATIVE Types beside the Files profile, registered at genesis with it: `topic-word/1` (a word's page,
///         which is also the root-level topic `/<word>`), `topic/1` (a path of two or more words) and `text/1` (a
///         short display string, the value of a label). This library holds the two byte grammars and the one table
///         of refused code points they share; the rules (`TopicWordRule`, `TopicRule`, `TextRule`) call them.
///
///         Nothing is normalized. Lowercasing beyond ASCII, NFC and every other part of folding are SDK obligations:
///         the chain refuses only what a folded word can never contain, so that a word the SDK accepts is always
///         admitted and two spellings the SDK folds alike are never both needed.
/// @dev Internal only; no storage, no immutables (the profile immutables gate, `tools/checks.mjs`). Pure over
///      calldata: one byte at a time on the ASCII path (one bitmap test), one calldata word per multi-byte scalar
///      (`FilesName.scalar`, the strict decoder `files-name/2` already ships: no overlong form, no surrogate, nothing
///      above U+10FFFF, no stray continuation byte, no truncated sequence), and for each such scalar a scan of
///      `REFUSED` that stops at the first entry starting above it (sorted, so an ASCII-adjacent scalar stops at once).
library TopicProfile {
    /// The longest word and the longest text, in bytes.
    uint256 internal constant WORD_MAX = 255;
    uint256 internal constant TEXT_MAX = 255;
    /// Bit c set for an ASCII byte a word admits: 0x21..0x7e minus `/` (0x2f) and `A`-`Z` (0x41..0x5a). Space, the
    /// C0 controls and DEL are refused with the rest.
    uint256 internal constant WORD_ASCII_OK = 0x7ffffffff8000001ffff7ffe00000000;
    /// Bit c set for `0-9a-f` (the address-shaped word of rule 6).
    uint256 internal constant HEX_LOWER = 0x7e0000000003ff000000000000;

    /// The classes of `REFUSED`. A word refuses every class; a text refuses the first three.
    uint8 internal constant CLASS_C1 = 1;
    uint8 internal constant CLASS_BIDI = 2;
    uint8 internal constant CLASS_INVISIBLE = 3;
    uint8 internal constant CLASS_JOINER = 4;
    uint8 internal constant CLASS_NONCHARACTER = 5;

    /// The refused code points of word rule 7, as one table: sorted, disjoint entries of seven bytes
    /// `lo (3) ‖ hi (3) ‖ class (1)`, an inclusive range of scalars and its class. 1 C1 control; 2 bidirectional
    /// control; 3 invisible (a format character Cf, a line or paragraph separator, a default-ignorable code point);
    /// 4 a joiner or variation selector; 5 a noncharacter, or the object and replacement characters. The set is
    /// Unicode 15.1's C1 controls, `Cf`, `Zl`, `Zp` and `Default_Ignorable_Code_Point`, plus every non-ASCII scalar
    /// `files-name/2` refuses (`FilesName.excluded`: so this is at least as strict as names), plus the joiners and
    /// variation selectors names allow (U+034F, U+180B-180D, U+180F, U+200C, U+200D, U+FE00-FE0F, U+E0100-E01EF),
    /// which a folded word never contains. `test/vectors/topics.json` carries the same table for the SDK and
    /// `test/profiles/TopicVectors.t.sol` asserts the two are equal entry for entry.
    ///
    /// This list is fixed at the first lasting deployment of `topic-word/1` (a change is a new rule, hence a new
    /// Type id and new ids for every topic). Until then it may still change: the SDK's fold rule is not yet
    /// confirmed, and the chain must refuse exactly what that rule can never produce.
    bytes internal constant REFUSED = hex"00008000009f01" // U+0080..U+009F C1 controls
        hex"0000ad0000ad03" // U+00AD..U+00AD SOFT HYPHEN
        hex"00034f00034f04" // U+034F..U+034F COMBINING GRAPHEME JOINER
        hex"00060000060503" // U+0600..U+0605 Arabic number signs (Cf)
        hex"00061c00061c02" // U+061C..U+061C ARABIC LETTER MARK
        hex"0006dd0006dd03" // U+06DD..U+06DD ARABIC END OF AYAH (Cf)
        hex"00070f00070f03" // U+070F..U+070F SYRIAC ABBREVIATION MARK (Cf)
        hex"00089000089103" // U+0890..U+0891 Arabic pound and piastre marks above (Cf)
        hex"0008e20008e203" // U+08E2..U+08E2 ARABIC DISPUTED END OF AYAH (Cf)
        hex"00115f00116003" // U+115F..U+1160 Hangul choseong and jungseong fillers
        hex"0017b40017b503" // U+17B4..U+17B5 Khmer inherent vowels
        hex"00180b00180d04" // U+180B..U+180D Mongolian free variation selectors 1-3
        hex"00180e00180e03" // U+180E..U+180E MONGOLIAN VOWEL SEPARATOR
        hex"00180f00180f04" // U+180F..U+180F MONGOLIAN FREE VARIATION SELECTOR FOUR
        hex"00200b00200b03" // U+200B..U+200B ZERO WIDTH SPACE
        hex"00200c00200d04" // U+200C..U+200D ZERO WIDTH NON-JOINER, ZERO WIDTH JOINER
        hex"00200e00200f02" // U+200E..U+200F LEFT-TO-RIGHT MARK, RIGHT-TO-LEFT MARK
        hex"00202800202903" // U+2028..U+2029 LINE SEPARATOR, PARAGRAPH SEPARATOR
        hex"00202a00202e02" // U+202A..U+202E bidi embeddings and overrides
        hex"00206000206503" // U+2060..U+2065 WORD JOINER, invisible operators, U+2065
        hex"00206600206902" // U+2066..U+2069 bidi isolates
        hex"00206a00206f03" // U+206A..U+206F deprecated format characters
        hex"00316400316403" // U+3164..U+3164 HANGUL FILLER
        hex"00fdd000fdef05" // U+FDD0..U+FDEF noncharacters
        hex"00fe0000fe0f04" // U+FE00..U+FE0F variation selectors 1-16
        hex"00feff00feff03" // U+FEFF..U+FEFF ZERO WIDTH NO-BREAK SPACE (BOM)
        hex"00ffa000ffa003" // U+FFA0..U+FFA0 HALFWIDTH HANGUL FILLER
        hex"00fff000fffb03" // U+FFF0..U+FFFB U+FFF0-FFF8 and the interlinear annotation characters
        hex"00fffc00ffff05" // U+FFFC..U+FFFF OBJECT and REPLACEMENT CHARACTER, U+FFFE, U+FFFF
        hex"0110bd0110bd03" // U+110BD..U+110BD KAITHI NUMBER SIGN (Cf)
        hex"0110cd0110cd03" // U+110CD..U+110CD KAITHI NUMBER SIGN ABOVE (Cf)
        hex"01343001343f03" // U+13430..U+1343F Egyptian hieroglyph format controls
        hex"01bca001bca303" // U+1BCA0..U+1BCA3 shorthand format controls
        hex"01d17301d17a03" // U+1D173..U+1D17A musical symbol format controls
        hex"01fffe01ffff05" // U+1FFFE..U+1FFFF plane 1 noncharacters
        hex"02fffe02ffff05" // U+2FFFE..U+2FFFF plane 2 noncharacters
        hex"03fffe03ffff05" // U+3FFFE..U+3FFFF plane 3 noncharacters
        hex"04fffe04ffff05" // U+4FFFE..U+4FFFF plane 4 noncharacters
        hex"05fffe05ffff05" // U+5FFFE..U+5FFFF plane 5 noncharacters
        hex"06fffe06ffff05" // U+6FFFE..U+6FFFF plane 6 noncharacters
        hex"07fffe07ffff05" // U+7FFFE..U+7FFFF plane 7 noncharacters
        hex"08fffe08ffff05" // U+8FFFE..U+8FFFF plane 8 noncharacters
        hex"09fffe09ffff05" // U+9FFFE..U+9FFFF plane 9 noncharacters
        hex"0afffe0affff05" // U+AFFFE..U+AFFFF plane 10 noncharacters
        hex"0bfffe0bffff05" // U+BFFFE..U+BFFFF plane 11 noncharacters
        hex"0cfffe0cffff05" // U+CFFFE..U+CFFFF plane 12 noncharacters
        hex"0dfffe0dffff05" // U+DFFFE..U+DFFFF plane 13 noncharacters
        hex"0e00000e00ff03" // U+E0000..U+E00FF tag characters and their block
        hex"0e01000e01ef04" // U+E0100..U+E01EF variation selectors 17-256
        hex"0e01f00e0fff03" // U+E01F0..U+E0FFF the rest of the default-ignorable block
        hex"0efffe0effff05" // U+EFFFE..U+EFFFF plane 14 noncharacters
        hex"0ffffe0fffff05" // U+FFFFE..U+FFFFF plane 15 noncharacters
        hex"10fffe10ffff05"; // U+10FFFE..U+10FFFF plane 16 noncharacters

    /// The class of scalar `s` in `REFUSED`, 0 when it is not refused.
    function refusedClass(uint256 s) internal pure returns (uint256) {
        return _class(REFUSED, s);
    }

    /// The `topic-word/1` grammar. Returns 0 when `w` is admitted, else the first refusal in this order: 1 empty
    /// or longer than 255 bytes; then, scanning in order, whichever comes first of 2 malformed UTF-8 (an overlong
    /// form, a surrogate U+D800..U+DFFF, a value above U+10FFFF, a stray continuation byte or a truncated sequence),
    /// 3 a forbidden ASCII byte (`/`, a control 0x00..0x1f or 0x7f, space, `A`-`Z`) and 7 a scalar of `REFUSED`;
    /// then 4 the word is `.` or `..`; 5 it starts with `~`; 6 it is `0x` followed by exactly 40 characters of
    /// `0-9a-f` (it would read as an address: an address is a tag's target or a home, never a word). Rules 5 and 6
    /// apply to every word, not only the first of a path, because every word has a root-level page.
    function wordRefusal(bytes calldata w) internal pure returns (uint256) {
        uint256 n = w.length;
        if (n == 0 || n > WORD_MAX) return 1;
        bytes memory table = REFUSED;
        uint256 i;
        while (i < n) {
            uint256 b;
            assembly ("memory-safe") {
                b := byte(0, calldataload(add(w.offset, i)))
            }
            if (b < 0x80) {
                if ((WORD_ASCII_OK >> b) & 1 == 0) return 3;
                unchecked {
                    ++i;
                }
            } else {
                (uint32 s, uint256 width) = FilesName.scalar(w, i, n);
                if (width == 0) return 2;
                if (_class(table, s) != 0) return 7;
                unchecked {
                    i += width;
                }
            }
        }
        return _shape(w, n);
    }

    /// The `text/1` grammar. Returns 0 when `x` is admitted, else the first refusal: 20 empty or longer than 255
    /// bytes; then, scanning in order, whichever comes first of 21 malformed UTF-8 (as `wordRefusal` code 2), 22 a
    /// control character (C0 0x00..0x1f, DEL 0x7f, a C1 control) and 23 a bidirectional control or an invisible
    /// code point (`REFUSED` classes 2 and 3). `/`, spaces, uppercase, joiners, variation selectors and
    /// noncharacters are admitted: a label may read "AC/DC" or carry an emoji sequence.
    function textRefusal(bytes calldata x) internal pure returns (uint256) {
        uint256 n = x.length;
        if (n == 0 || n > TEXT_MAX) return 20;
        bytes memory table = REFUSED;
        uint256 i;
        while (i < n) {
            uint256 b;
            assembly ("memory-safe") {
                b := byte(0, calldataload(add(x.offset, i)))
            }
            if (b < 0x80) {
                if (b < 0x20 || b == 0x7f) return 22;
                unchecked {
                    ++i;
                }
            } else {
                (uint32 s, uint256 width) = FilesName.scalar(x, i, n);
                if (width == 0) return 21;
                uint256 c = _class(table, s);
                if (c == CLASS_C1) return 22;
                if (c == CLASS_BIDI || c == CLASS_INVISIBLE) return 23;
                unchecked {
                    i += width;
                }
            }
        }
        return 0;
    }

    /// Rules 4-6 on a word whose bytes already passed (the whole-word shapes).
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

    /// The class of `s` in `table` (`REFUSED` in memory): the first entry whose `lo` is above `s` ends the scan.
    function _class(bytes memory table, uint256 s) private pure returns (uint256 c) {
        assembly ("memory-safe") {
            let p := add(table, 32)
            let end := add(p, mload(table))
            for {} lt(p, end) { p := add(p, 7) } {
                let e := shr(200, mload(p))
                if lt(s, shr(32, e)) { break }
                if iszero(gt(s, and(shr(8, e), 0xffffff))) {
                    c := and(e, 0xff)
                    break
                }
            }
        }
    }
}
