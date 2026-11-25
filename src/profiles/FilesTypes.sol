// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Keys} from "../lib/Keys.sol";

/// @title FilesTypes — the codec-1 descriptors and Type ids of the Files profile (design §12.1, §9.2;
///        docs/LARGE-FILES.md)
/// @notice One builder per Type of §12.1 and docs/LARGE-FILES.md (ten Types). Every descriptor is NATIVE (grade 3),
///         `ruleMode` 1 (STATICCALL), namespace `keccak256("efs/files/1")`, `ruleCodehash` = the deployed rule
///         instance's codehash, `ruleInitcodeHash` = keccak of the instance's initcode (its creation code ‖
///         constructor arguments); the instance is CREATE2(0x4e59…956C, salt 0, initcode), which the registry checks. The declaration key is a parameter: the
///         fixture principal signs the declarations at genesis (§8.2 G21), and the ten ids are identical on every
///         Realm and chain for one key. Fields are only the leading REF32 projections the rows name (the bodies are
///         judged by their native rules, not by the described codec's body law, so no other field rows are declared;
///         the layout is in each description): `files-child/1` `[0 = ANY]` with `refHeaderWords` 2, `files-content/1`
///         `[0 = ANY]` with 3 (its rule checks the Type by carrier), `files-external/1` `[files-bytes/1]` with 1,
///         `files-span/1` `[0 = ANY, 0 = ANY]` with 3; the others have none and the codec minimum `refHeaderWords` 1.
///         `validationGas` 0 (the closure default 300,000 is ample: the worst name, 255 bytes of CJK, measured 117k).
///         `dependencyClass` is the creator's disclosure: 2 (realm reads) for the rules that call the ledger, 1 for
///         the rules pure over calldata, `refHeaders` and constructor state.
///
///         Dependency order (a rule's constructor state names sibling Type ids, so the Type it names must be derived
///         first; the constructor arguments are inside `ruleInitcodeHash`, never in the descriptor bytes):
///         bytes → span(bytes) → content(bytes, span) → external (its descriptor's ref is the bytes id) →
///         root(content, external) → child(root, content, external) → directory, name, notice (no siblings) →
///         alias(directory); `FilesFinalValidator(name, directory)` last. Constructor arguments, in order:
///         `FilesSpanRule(bytesTypeId)`, `FilesContentRule(bytesTypeId, spanTypeId)`,
///         `FilesRootRule(contentTypeId, externalTypeId)`, `FilesChildRule(rootTypeId, contentTypeId,
///         externalTypeId)`, `DirectoryAliasRule(directoryTypeId)`; the other five rules take none.
/// @dev Internal and pure/view only, so it compiles into its callers; the release generates the ids (design §5.14
///      `EfsFiles`: "Type ids come from `profiles/FilesTypes.sol` (generated from the release) or the caller").
library FilesTypes {
    bytes32 internal constant NAMESPACE = keccak256("efs/files/1");
    uint8 internal constant GRADE_NATIVE = 3;
    uint8 internal constant KIND_REF32 = 1;
    uint256 internal constant HEADER = 134;
    uint256 internal constant FIELD = 164;
    /// `refTypes` sentinel: any Type.
    bytes32 internal constant REF_ANY = bytes32(0);

    bytes32 internal constant FIELD_PARENT = keccak256("efs/files/field/parent/1");
    bytes32 internal constant FIELD_BYTES = keccak256("efs/files/field/bytes/1");
    bytes32 internal constant FIELD_LEFT = keccak256("efs/files/field/left/1");
    bytes32 internal constant FIELD_RIGHT = keccak256("efs/files/field/right/1");
    bytes32 internal constant SEMANTIC_REVISION = keccak256("efs/files/semantic/parent-revision/1");
    bytes32 internal constant SEMANTIC_CARRIER = keccak256("efs/files/semantic/bytes-carrier/1");
    bytes32 internal constant SEMANTIC_SPAN_CHILD = keccak256("efs/files/semantic/span-child/1");

    struct Spec {
        bytes name;
        bytes description;
        uint8 dependencyClass;
        uint8 refHeaderWords;
        bytes fields;
        uint8 fieldCount;
    }

    // =============================================================================================
    // The ten descriptors
    // =============================================================================================

    function filesRoot(address key, address instance, bytes32 initcodeHash)
        internal
        view
        returns (bytes memory)
    {
        return encode(key, instance.codehash, initcodeHash, rootSpec());
    }

    function filesChild(address key, address instance, bytes32 initcodeHash)
        internal
        view
        returns (bytes memory)
    {
        return encode(key, instance.codehash, initcodeHash, childSpec());
    }

    function filesDirectory(address key, address instance, bytes32 initcodeHash)
        internal
        view
        returns (bytes memory)
    {
        return encode(key, instance.codehash, initcodeHash, directorySpec());
    }

    function filesName(address key, address instance, bytes32 initcodeHash)
        internal
        view
        returns (bytes memory)
    {
        return encode(key, instance.codehash, initcodeHash, nameSpec());
    }

    function filesBytes(address key, address instance, bytes32 initcodeHash)
        internal
        view
        returns (bytes memory)
    {
        return encode(key, instance.codehash, initcodeHash, bytesSpec());
    }

    /// `instance` is `FilesContentRule(bytesTypeId, spanTypeId)`; the reference is `ANY`, so no id is in the bytes.
    function filesContent(address key, address instance, bytes32 initcodeHash)
        internal
        view
        returns (bytes memory)
    {
        return encode(key, instance.codehash, initcodeHash, contentSpec());
    }

    function filesExternal(address key, address instance, bytes32 initcodeHash, bytes32 bytesTypeId)
        internal
        view
        returns (bytes memory)
    {
        return encode(key, instance.codehash, initcodeHash, externalSpec(bytesTypeId));
    }

    /// `instance` is `FilesSpanRule(bytesTypeId)`; both references are `ANY`, so no id is in the bytes.
    function filesSpan(address key, address instance, bytes32 initcodeHash)
        internal
        view
        returns (bytes memory)
    {
        return encode(key, instance.codehash, initcodeHash, spanSpec());
    }

    function directoryAlias(address key, address instance, bytes32 initcodeHash)
        internal
        view
        returns (bytes memory)
    {
        return encode(key, instance.codehash, initcodeHash, aliasSpec());
    }

    function realmNotice(address key, address instance, bytes32 initcodeHash)
        internal
        view
        returns (bytes memory)
    {
        return encode(key, instance.codehash, initcodeHash, noticeSpec());
    }

    // =============================================================================================
    // Specs (identity-bearing: every byte below is inside the shape commitment)
    // =============================================================================================

    function rootSpec() internal pure returns (Spec memory s) {
        s.name = "files-root/1";
        s.description =
            "abi.encode(fileSubject, form) || rest; the first revision of a created file subject; form 0 rest is the file bytes, form 1 rest is one word naming a files-content/1 or files-external/1 record";
        s.dependencyClass = 2;
        s.refHeaderWords = 1;
    }

    function childSpec() internal pure returns (Spec memory s) {
        s.name = "files-child/1";
        s.description =
            "abi.encode(parentRecord, fileSubject, form) || rest; parent is files-root/1 or files-child/1 of the same file; form 0 rest is the file bytes, form 1 rest is one word naming a files-content/1 or files-external/1 record";
        s.dependencyClass = 2;
        s.refHeaderWords = 2;
        s.fields = refField(FIELD_PARENT, SEMANTIC_REVISION, REF_ANY);
        s.fieldCount = 1;
    }

    function directorySpec() internal pure returns (Spec memory s) {
        s.name = "files-directory/1";
        s.description =
        "abi.encode(seedSubject); a directory is this record, seeded by a created subject";
        s.dependencyClass = 2;
        s.refHeaderWords = 1;
    }

    function nameSpec() internal pure returns (Spec memory s) {
        s.name = "files-name/2";
        s.description =
            "raw UTF-8 name, 1-255 bytes, well-formed, byte-exact, case-sensitive, not . or .., ~efs reserved";
        s.dependencyClass = 1;
        s.refHeaderWords = 1;
    }

    function bytesSpec() internal pure returns (Spec memory s) {
        s.name = "files-bytes/1";
        s.description =
            "sha256(payload) || payload; one chunk, bounded only by the Realm maxBody; the empty payload is the remote sentinel";
        s.dependencyClass = 1;
        s.refHeaderWords = 1;
    }

    function contentSpec() internal pure returns (Spec memory s) {
        s.name = "files-content/1";
        s.description =
            "[bytesRef, version, carrier, hashAlg, length, sha256, cipher, nonce12, plaintextLength, plaintextSHA256OrZero] || media, the media type being the rest of the body after 320 bytes; carrier 0 one files-bytes/1 record, 1 the remote sentinel, 2 a files-span/1 root; lengths below 2^64; media empty (unknown) or a lowercase RFC 6838 type/subtype with optional ;parameters, at most 255 bytes";
        s.dependencyClass = 1;
        s.refHeaderWords = 3;
        s.fields = refField(FIELD_BYTES, SEMANTIC_CARRIER, REF_ANY);
        s.fieldCount = 1;
    }

    function externalSpec(bytes32 bytesTypeId) internal pure returns (Spec memory s) {
        s.name = "files-external/1";
        s.description =
            "[bytesRef (the empty sentinel), version 2, carrier 2, hashAlg 1, length, sha256, locatorLength] || locator || media; a URI of 1-2048 printable ASCII bytes with an RFC 3986 scheme, no scheme allowlist; media as files-content/1, the rest of the body";
        s.dependencyClass = 1;
        s.refHeaderWords = 1;
        s.fields = refField(FIELD_BYTES, SEMANTIC_CARRIER, bytesTypeId);
        s.fieldCount = 1;
    }

    function spanSpec() internal pure returns (Spec memory s) {
        s.name = "files-span/1";
        s.description =
            "abi.encode(left, right, length); each child a files-bytes/1 record with a nonempty payload or a files-span/1 record; length is the sum of the children payload lengths, below 2^64";
        s.dependencyClass = 1;
        s.refHeaderWords = 3;
        s.fields = bytes.concat(
            refField(FIELD_LEFT, SEMANTIC_SPAN_CHILD, REF_ANY),
            refField(FIELD_RIGHT, SEMANTIC_SPAN_CHILD, REF_ANY)
        );
        s.fieldCount = 2;
    }

    function aliasSpec() internal pure returns (Spec memory s) {
        s.name = "directory-alias/1";
        s.description =
            "abi.encode(targetObjectId, kind); kind 1 a files-directory/1 record, 2 a created file subject";
        s.dependencyClass = 2;
        s.refHeaderWords = 1;
    }

    function noticeSpec() internal pure returns (Spec memory s) {
        s.name = "realm-notice/1";
        s.description =
            "abi.encode(bytes32 kind, uint256 revision, bytes note); kind frozen | successor | migration";
        s.dependencyClass = 2;
        s.refHeaderWords = 1;
    }

    // =============================================================================================
    // Encoding and identity
    // =============================================================================================

    /// One REF32 field row (164 bytes): required, leading, width 32, no bounds, `ref` the projected Type.
    function refField(bytes32 id, bytes32 semantic, bytes32 ref)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(
            id, semantic, KIND_REF32, uint8(0), uint16(32), uint256(0), uint256(0), ref
        );
    }

    /// The codec-1 bytes (design §9.2 byte offsets) of a NATIVE descriptor.
    function encode(address key, bytes32 ruleCodehash, bytes32 initcodeHash, Spec memory s)
        internal
        pure
        returns (bytes memory)
    {
        return bytes.concat(
            abi.encodePacked(
                uint8(1), // codecVersion
                uint8(0), // wrapperVersion: no wrapper for a NATIVE rule
                GRADE_NATIVE,
                s.fieldCount,
                uint8(1), // ruleMode STATICCALL
                s.dependencyClass,
                uint8(1), // refProjectionProfile: leading words
                uint8(1), // textProfile ASCII
                uint24(0), // validationGas: the closure default
                uint8(0), // indexSpecCount
                uint8(0), // sectionCount
                uint8(s.name.length),
                key,
                NAMESPACE,
                ruleCodehash,
                initcodeHash,
                uint16(s.description.length),
                s.refHeaderWords,
                uint8(0) // reserved
            ),
            s.name,
            s.description,
            s.fields
        );
    }

    /// The reference Types projected from the leading REF32 field rows (design §9.2).
    function refTypesOf(bytes memory d) internal pure returns (bytes32[] memory refs) {
        uint256 fieldCount = uint8(d[3]);
        uint256 start = HEADER + uint8(d[13]) + (uint256(uint8(d[130])) << 8 | uint8(d[131]));
        refs = new bytes32[](fieldCount);
        uint256 n;
        for (uint256 i; i < fieldCount; ++i) {
            uint256 p = start + i * FIELD;
            if (uint8(d[p + 64]) != KIND_REF32) break;
            bytes32 ref;
            assembly ("memory-safe") {
                ref := mload(add(add(d, 32), add(p, 132)))
            }
            refs[n++] = ref;
        }
        assembly ("memory-safe") {
            mstore(refs, n)
        }
    }

    /// `typeId = keccak(DOM_TYPE, keccak(DOM_DESCRIBED_SHAPE, descriptor), keccak(abi.encode(refTypes)), ruleCodehash)`
    /// (design §9.1; the same derivation as `TypeRegistry._retain`).
    function typeIdOf(bytes memory d) internal pure returns (bytes32) {
        bytes32 ruleCodehash;
        assembly ("memory-safe") {
            ruleCodehash := mload(add(add(d, 32), 66))
        }
        return Keys.typeId(
            keccak256(abi.encode(Keys.DOM_DESCRIBED_SHAPE, d)), refTypesOf(d), ruleCodehash
        );
    }
}
