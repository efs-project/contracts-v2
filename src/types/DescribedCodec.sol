// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ClosureConstants} from "../interfaces/Limits.sol";
import {E_CODEC, E_BODY} from "../interfaces/Errors.sol";

/// @title DescribedCodec — codec `efs2/described/1` (design §9.2)
/// @notice The identity-bearing descriptor grammar: a 134-byte header, the name, the description, then
///         `fieldCount` rows of 164 bytes exactly as the prototype's WIRE grammar (kinds 1–8). `parse` is what
///         the registry runs at registration and what the described wrapper re-runs at every acceptance;
///         `validateBody` is the wrapper's body law. Total length 134..4,096 bytes; refusals are
///         `E_CODEC(byteOffset, code)` with the codes listed on `parse`.
/// @dev Pure over calldata; no storage, no external calls, no immutables (profiles/ closure rules).
library DescribedCodec {
    uint256 internal constant HEADER = 134;
    uint256 internal constant FIELD = 164;
    uint256 internal constant MAX_FIELDS = 16;
    uint256 internal constant MAX_REFS = 8;
    uint256 internal constant BODY_MAX = 8_192; // the codec's own cap: validity never reads a Realm limit (§9.5 ii)
    uint8 internal constant GRADE_STRUCTURAL = 1;
    uint8 internal constant GRADE_CUSTOM = 2;
    uint8 internal constant GRADE_NATIVE = 3;
    uint8 internal constant KIND_REF32 = 1;
    uint8 internal constant KIND_BYTES32 = 2;
    uint8 internal constant KIND_UINT = 3;
    uint8 internal constant KIND_BOOL = 4;
    uint8 internal constant KIND_ENUM = 5;
    uint8 internal constant KIND_BYTES = 6;
    uint8 internal constant KIND_TEXT_LF = 7;
    uint8 internal constant KIND_TEXT_PRINTABLE = 8;
    /// `refTypes` sentinels (design §9.2): 0 ANY, 1 SELF; 2..0xFFFF reserved; exact ids are ≥ 2^16.
    uint256 internal constant REF_ANY = 0;
    uint256 internal constant REF_SELF = 1;
    uint256 internal constant REF_EXACT_MIN = 1 << 16;

    struct Header {
        uint8 wrapperVersion;
        uint8 grade;
        uint8 fieldCount;
        uint8 ruleMode;
        uint8 dependencyClass;
        uint8 textProfile;
        uint24 validationGas;
        uint8 nameLength;
        address declarationKey;
        bytes32 namespace;
        bytes32 ruleCodehash;
        bytes32 auxHash; // customHash (grade 2) | ruleInitcodeHash (grade 3) | 0 (grade 1)
        uint16 descriptionLength;
        uint8 refHeaderWords;
        uint256 fieldsStart;
    }

    /// Parses and validates a descriptor; returns the header and the reference Types projected from the
    /// leading REF32 fields. Codes: 1 length outside 134..4,096 or not equal to the header's own sum;
    /// 2 codecVersion; 3 grade; 4 ruleMode; 5 dependencyClass; 6 refProjectionProfile; 7 textProfile;
    /// 8 indexSpecCount; 9 sectionCount; 10 refHeaderWords; 11 reserved byte; 12 fieldCount; 13 name empty;
    /// 14 declarationKey zero; 15 namespace zero; 16 ruleCodehash zero; 17 auxHash shape for the grade;
    /// 20 field ids; 21 duplicate field id; 22 kind; 23 optional flag; 24 REF32 placement or shape;
    /// 25 referenceType; 26 width or bounds for the kind.
    function parse(bytes calldata d)
        internal
        pure
        returns (Header memory h, bytes32[] memory refTypes)
    {
        if (d.length < HEADER || d.length > ClosureConstants.DESCRIPTOR_MAX) {
            revert E_CODEC(0, 1);
        }
        if (uint8(d[0]) != 1) revert E_CODEC(0, 2);
        h.wrapperVersion = uint8(d[1]);
        h.grade = uint8(d[2]);
        if (h.grade < GRADE_STRUCTURAL || h.grade > GRADE_NATIVE) revert E_CODEC(2, 3);
        h.fieldCount = uint8(d[3]);
        if (h.fieldCount > MAX_FIELDS) revert E_CODEC(3, 12);
        h.ruleMode = uint8(d[4]);
        if (h.ruleMode != 1) revert E_CODEC(4, 4);
        h.dependencyClass = uint8(d[5]);
        if (h.dependencyClass < 1 || h.dependencyClass > 3) revert E_CODEC(5, 5);
        if (uint8(d[6]) != 1) revert E_CODEC(6, 6);
        h.textProfile = uint8(d[7]);
        if (h.textProfile != 1) revert E_CODEC(7, 7);
        h.validationGas = uint24(bytes3(d[8:11]));
        if (uint8(d[11]) != 0) revert E_CODEC(11, 8);
        if (uint8(d[12]) != 0) revert E_CODEC(12, 9);
        h.nameLength = uint8(d[13]);
        if (h.nameLength == 0) revert E_CODEC(13, 13);
        h.declarationKey = address(bytes20(d[14:34]));
        if (h.declarationKey == address(0)) revert E_CODEC(14, 14);
        h.namespace = bytes32(d[34:66]);
        if (h.namespace == 0) revert E_CODEC(34, 15);
        h.ruleCodehash = bytes32(d[66:98]);
        if (h.ruleCodehash == 0) revert E_CODEC(66, 16);
        h.auxHash = bytes32(d[98:130]);
        if ((h.grade == GRADE_STRUCTURAL) != (h.auxHash == 0)) revert E_CODEC(98, 17);
        h.descriptionLength = uint16(bytes2(d[130:132]));
        h.refHeaderWords = uint8(d[132]);
        if (h.refHeaderWords < 1 || h.refHeaderWords > 3) revert E_CODEC(132, 10);
        if (uint8(d[133]) != 0) revert E_CODEC(133, 11);
        h.fieldsStart = HEADER + h.nameLength + h.descriptionLength;
        if (h.fieldsStart + uint256(h.fieldCount) * FIELD != d.length) revert E_CODEC(0, 1);
        refTypes = _fields(d, h);
    }

    function _fields(bytes calldata d, Header memory h)
        private
        pure
        returns (bytes32[] memory refTypes)
    {
        bytes32[] memory refs = new bytes32[](MAX_REFS);
        uint256 n;
        uint256 start = h.fieldsStart;
        for (uint256 i; i < h.fieldCount; ++i) {
            uint256 p = start + i * FIELD;
            bytes32 id = bytes32(d[p:p + 32]);
            if (id == 0 || bytes32(d[p + 32:p + 64]) == 0) revert E_CODEC(uint16(p), 20);
            for (uint256 j; j < i; ++j) {
                if (bytes32(d[start + j * FIELD:start + j * FIELD + 32]) == id) {
                    revert E_CODEC(uint16(p), 21);
                }
            }
            uint8 kind = uint8(d[p + 64]);
            uint8 optional = uint8(d[p + 65]);
            uint256 width = uint16(bytes2(d[p + 66:p + 68]));
            uint256 lo = uint256(bytes32(d[p + 68:p + 100]));
            uint256 hi = uint256(bytes32(d[p + 100:p + 132]));
            uint256 ref = uint256(bytes32(d[p + 132:p + 164]));
            if (kind < KIND_REF32 || kind > KIND_TEXT_PRINTABLE) {
                revert E_CODEC(uint16(p + 64), 22);
            }
            if (optional > 1) revert E_CODEC(uint16(p + 65), 23);
            if (lo > hi) revert E_CODEC(uint16(p + 68), 26);
            if (kind == KIND_REF32) {
                // required, leading, at most eight; no nullable references (the kernel's leading-word law)
                if (i != n || n == MAX_REFS || optional != 0 || width != 32 || hi != 0) {
                    revert E_CODEC(uint16(p), 24);
                }
                if (ref != REF_ANY && ref != REF_SELF && ref < REF_EXACT_MIN) {
                    revert E_CODEC(uint16(p + 132), 25);
                }
                refs[n++] = bytes32(ref);
            } else {
                if (ref != 0) revert E_CODEC(uint16(p + 132), 25);
                if (kind == KIND_BYTES32) {
                    if (width != 32 || hi != 0) revert E_CODEC(uint16(p + 66), 26);
                } else if (kind == KIND_UINT) {
                    if (width == 0 || width > 32 || (width < 32 && hi >> (width * 8) != 0)) {
                        revert E_CODEC(uint16(p + 66), 26);
                    }
                } else if (kind == KIND_BOOL) {
                    if (width != 1 || lo != 0 || hi != 1) revert E_CODEC(uint16(p + 66), 26);
                } else if (kind == KIND_ENUM) {
                    if (width != 1 || hi > 255) revert E_CODEC(uint16(p + 66), 26);
                } else if (width != 0 || hi > BODY_MAX) {
                    revert E_CODEC(uint16(p + 66), 26);
                }
            }
        }
        assembly ("memory-safe") {
            mstore(refs, n)
        }
        return refs;
    }

    /// The name bytes (`nameLength` after the header).
    function name(bytes calldata d, Header memory h) internal pure returns (bytes calldata) {
        return d[HEADER:HEADER + h.nameLength];
    }

    /// The wrapper's body law over a parsed descriptor: leading REF32 words equal `refs`, then each field's
    /// payload in order (presence byte for optional fields, u16 length for the byte and text kinds, bounds and
    /// character domains as declared), ending exactly at `body.length`. Refusals: `E_BODY(leaf, 3)` is the
    /// kernel's code for a carrier; here the codes are 4 length cap, 5 ref count, 6 presence byte, 7 payload
    /// overruns, 8 ref word mismatch, 9 bounds, 10 text domain, 11 trailing bytes.
    function validateBody(
        bytes calldata d,
        Header memory h,
        bytes calldata body,
        bytes32[] calldata refs,
        uint8 leaf
    ) internal pure {
        if (body.length > BODY_MAX) revert E_BODY(leaf, 4);
        uint256 cursor;
        uint256 refIndex;
        for (uint256 i; i < h.fieldCount; ++i) {
            uint256 p = h.fieldsStart + i * FIELD;
            uint8 kind = uint8(d[p + 64]);
            if (uint8(d[p + 65]) == 1) {
                if (cursor == body.length) revert E_BODY(leaf, 7);
                uint8 present = uint8(body[cursor++]);
                if (present == 0) continue;
                if (present != 1) revert E_BODY(leaf, 6);
            }
            uint256 length = uint16(bytes2(d[p + 66:p + 68]));
            uint256 lo = uint256(bytes32(d[p + 68:p + 100]));
            uint256 hi = uint256(bytes32(d[p + 100:p + 132]));
            if (kind >= KIND_BYTES) {
                if (cursor + 2 > body.length) revert E_BODY(leaf, 7);
                length = uint16(bytes2(body[cursor:cursor + 2]));
                cursor += 2;
                if (length < lo || length > hi) revert E_BODY(leaf, 9);
            }
            if (cursor + length > body.length) revert E_BODY(leaf, 7);
            if (kind == KIND_REF32) {
                if (refIndex >= refs.length || bytes32(body[cursor:cursor + 32]) != refs[refIndex])
                {
                    revert E_BODY(leaf, 8);
                }
                ++refIndex;
            } else if (kind >= KIND_UINT && kind <= KIND_ENUM) {
                uint256 value =
                    uint256(bytes32(body[cursor:cursor + length]) >> ((32 - length) * 8));
                if (value < lo || value > hi) revert E_BODY(leaf, 9);
            } else if (kind >= KIND_TEXT_LF) {
                bool lf = kind == KIND_TEXT_LF;
                for (uint256 q = cursor; q < cursor + length; ++q) {
                    uint8 c = uint8(body[q]);
                    if ((c < 0x20 || c > 0x7e) && !(lf && c == 0x0a)) revert E_BODY(leaf, 10);
                }
            }
            cursor += length;
        }
        if (refIndex != refs.length) revert E_BODY(leaf, 5);
        if (cursor != body.length) revert E_BODY(leaf, 11);
    }
}
