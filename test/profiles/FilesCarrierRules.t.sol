// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IAcceptor, RefHeader} from "../../src/interfaces/IAcceptor.sol";
import {FilesBytesRule} from "../../src/profiles/FilesBytesRule.sol";
import {FilesContentRule} from "../../src/profiles/FilesContentRule.sol";
import {FilesUnitBase} from "./FilesUnitBase.sol";

/// @notice `files-bytes/1` and `files-content/1`: the rule-level cases of the prototype's `FilesCarrierProfile.t.sol`
///         rewritten for the v2 layouts, the large-file laws of docs/LARGE-FILES.md (no bytes cap, the `ANY`
///         reference checked by carrier, carrier 2 over a `files-span/1` root, 64-bit lengths), plus context checks.
///         `files-external/1` is `FilesExternalRule.t.sol`, `files-span/1` is `FilesSpanRule.t.sol`.
contract FilesCarrierRulesTest is FilesUnitBase {
    FilesBytesRule internal bytesRule;
    FilesContentRule internal content;

    bytes32 internal constant BYTES_TYPE = keccak256("test/files/bytes-type");
    bytes32 internal constant SPAN_TYPE = keccak256("test/files/span-type");
    bytes32 internal constant BYTES_REF = keccak256("a files-bytes/1 record");
    uint256 internal constant U64 = type(uint64).max;

    function setUp() public override {
        super.setUp();
        bytesRule = new FilesBytesRule();
        content = new FilesContentRule(BYTES_TYPE, SPAN_TYPE);
    }

    // ---- files-bytes/1 -----------------------------------------------------------------------------------------

    function _bytes(bytes memory payload) internal pure returns (bytes memory) {
        return bytes.concat(abi.encode(sha256(payload)), payload);
    }

    function test_bytes_accepts_empty_binary_and_maximum_payloads() public {
        _accepts(bytesRule, _ctx(), _bytes(""), _none(), _noHeaders()); // the remote sentinel
        _accepts(bytesRule, _ctx(), _bytes(hex"00ff8041"), _none(), _noHeaders());
        _accepts(bytesRule, _ctx(), _bytes(new bytes(8160)), _none(), _noHeaders()); // L test_bytes_maximum_payload_admission
        // no cap of its own: the Realm's maxBody is the only bound (docs/LARGE-FILES.md)
        _accepts(bytesRule, _ctx(), _bytes(new bytes(8161)), _none(), _noHeaders());
        _accepts(bytesRule, _ctx(), _bytes(new bytes(65_536)), _none(), _noHeaders());
    }

    // L test_bytes_supplied_digest_must_match_payload, test_bytes_and_concept_limits (the bytes half)
    function test_bytes_digest_and_limits() public {
        _refuses(
            bytesRule,
            _ctx(),
            bytes.concat(abi.encode(bytes32(uint256(9))), hex"00ff"),
            _none(),
            _noHeaders(),
            3
        );
        _refuses(
            bytesRule,
            _ctx(),
            bytes.concat(abi.encode(keccak256(hex"00ff")), hex"00ff"),
            _none(),
            _noHeaders(),
            3
        );
        _refuses(bytesRule, _ctx(), new bytes(8193), _none(), _noHeaders(), 3); // a wrong digest, not a size
        _refuses(bytesRule, _ctx(), bytes(""), _none(), _noHeaders(), 2);
        _refuses(bytesRule, _ctx(), new bytes(31), _none(), _noHeaders(), 2);
        _refuses(bytesRule, _ctx(), _bytes("x"), _one(BYTES_REF), _noHeaders(), 1);
    }

    function test_bytes_context_is_authenticated() public {
        _contextIsAuthenticated(bytesRule, _bytes("payload"), _none(), _noHeaders());
    }

    // ---- files-content/1 ---------------------------------------------------------------------------------------

    /// The 11 words for `raw`: inline (carrier 0), remote (carrier 1) or span (carrier 2), plaintext.
    function _descriptor(bytes memory raw, uint256 carrier) internal pure returns (bytes memory) {
        return _claim(raw.length, sha256(raw), carrier);
    }

    /// The 11 words of a plaintext descriptor claiming `length` bytes hashing to `digest`.
    function _claim(uint256 length, bytes32 digest, uint256 carrier)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(
            BYTES_REF,
            uint256(1),
            carrier,
            uint256(1),
            length,
            digest,
            uint256(0),
            uint256(0),
            bytes32(0),
            length,
            digest
        );
    }

    /// The header the kernel would pass for a `files-span/1` root of `length` payload bytes.
    function _spanHeader(uint256 length) internal pure returns (RefHeader[] memory) {
        return _header(SPAN_TYPE, 96, keccak256("left"), keccak256("right"), bytes32(length));
    }

    /// The header the kernel would pass for the bytes record that carries `raw` inline (or the sentinel).
    function _bytesHeader(bytes memory payload) internal pure returns (RefHeader[] memory) {
        return _header(BYTES_TYPE, uint32(32 + payload.length), sha256(payload), 0, 0);
    }

    function _content(bytes memory d, RefHeader[] memory h, uint8 code) internal {
        if (code == 0) _accepts(content, _ctx(), d, _one(BYTES_REF), h);
        else _refuses(content, _ctx(), d, _one(BYTES_REF), h, code);
    }

    // L test_empty_and_binary_descriptor_accepted, test_maximum_inline_descriptor_inside_mandatory_budget
    function test_content_inline_empty_binary_and_maximum() public {
        _content(_descriptor("", 0), _bytesHeader(""), 0);
        _content(_descriptor(hex"00ff8041", 0), _bytesHeader(hex"00ff8041"), 0);
        _content(_descriptor(new bytes(8160), 0), _bytesHeader(new bytes(8160)), 0);
        // one chunk larger than 8 KiB under a Realm whose maxBody allows it
        _content(_descriptor(new bytes(20_000), 0), _bytesHeader(new bytes(20_000)), 0);
    }

    // L test_descriptor_extra_missing_length_rejected
    function test_content_exact_length() public {
        bytes memory d = _descriptor(hex"ff", 0);
        _content(bytes.concat(d, hex"00"), _bytesHeader(hex"ff"), 2);
        bytes memory short = new bytes(320);
        for (uint256 i; i < 320; ++i) {
            short[i] = d[i];
        }
        _content(short, _bytesHeader(hex"ff"), 2);
        _refuses(content, _ctx(), d, _none(), _bytesHeader(hex"ff"), 1);
        _refuses(content, _ctx(), d, _one(BYTES_REF), _noHeaders(), 1);
        d[31] = bytes1(uint8(d[31]) ^ 1);
        _content(d, _bytesHeader(hex"ff"), 3); // word 0 is the checked reference
    }

    // L test_unsupported_algorithm_carrier_media_rejected (+ version, cipher, bounds, nonce domain)
    function test_content_unsupported_domains() public {
        uint256[7] memory word = [uint256(1), 2, 3, 4, 6, 7, 9];
        uint8[7] memory bad = [2, 3, 2, 0x11, 3, 2, 0x11];
        for (uint256 i; i < word.length; ++i) {
            bytes memory d = _descriptor(hex"ff", 0);
            if (word[i] == 4 || word[i] == 9) {
                // length / plaintextLength above 2^64 - 1
                bytes32 big = bytes32(U64 + 1);
                for (uint256 j; j < 32; ++j) {
                    d[word[i] * 32 + j] = big[j];
                }
            } else {
                d[word[i] * 32 + 31] = bytes1(bad[i]);
            }
            _content(d, _bytesHeader(hex"ff"), 4);
        }
        bytes memory n = _descriptor(hex"ff", 0);
        n[8 * 32 + 12] = 0x01; // a nonce byte past the 12 left-aligned bytes
        _content(n, _bytesHeader(hex"ff"), 4);
    }

    // L test_inline_target_length_hash_and_type_rejected (the Type half is the kernel's exact-ref check)
    function test_content_inline_length_and_hash_must_match_the_bytes_header() public {
        bytes memory d = _descriptor(hex"ff", 0);
        _content(d, _bytesHeader(hex"ffff"), 8); // length 2 in the header, 1 in the descriptor
        _content(d, _header(BYTES_TYPE, 33, keccak256("other digest"), 0, 0), 8);
        _content(d, _header(BYTES_TYPE, 31, sha256(hex"ff"), 0, 0), 6);
        _content(d, _header(BYTES_TYPE, 8193, sha256(hex"ff"), 0, 0), 8); // no size bound, a length mismatch
        RefHeader[] memory unadmitted = _bytesHeader(hex"ff");
        unadmitted[0].firstAdmission = 0;
        _content(d, unadmitted, 6);
        // the reference is ANY now: carrier 0 checks the Type itself
        _content(d, _header(SPAN_TYPE, 33, sha256(hex"ff"), 0, bytes32(uint256(1))), 6);
        _content(d, _header(keccak256("another Type"), 33, sha256(hex"ff"), 0, 0), 6);
    }

    // L test_external_requires_empty_inline_sentinel
    function test_content_remote_requires_the_empty_sentinel() public {
        _content(_descriptor(hex"ff", 1), _bytesHeader(""), 0);
        _content(_descriptor(hex"ff", 1), _bytesHeader(hex"ff"), 7);
        _content(_descriptor(hex"ff", 0), _bytesHeader(""), 8);
        // the sentinel's shape under another Type is not the sentinel
        _content(_descriptor(hex"ff", 1), _header(SPAN_TYPE, 32, sha256(""), 0, 0), 6);
        _content(_descriptor(hex"ff", 1), _header(keccak256("x"), 32, sha256(""), 0, 0), 6);
    }

    // ---- carrier 2: a files-span/1 root ------------------------------------------------------------------------

    function test_content_span_root_of_the_claimed_length() public {
        bytes memory raw = new bytes(40_000);
        _content(_descriptor(raw, 2), _spanHeader(40_000), 0);
        // the sha256 is the author's claim (never recomputed): any digest is admitted over the right length
        _content(_claim(40_000, keccak256("a claimed digest"), 2), _spanHeader(40_000), 0);
        // the 64-bit bound is inclusive
        _content(_claim(U64, sha256("x"), 2), _spanHeader(U64), 0);
        // the smallest span is two one-byte chunks
        _content(_claim(2, sha256("ab"), 2), _spanHeader(2), 0);
    }

    function test_content_span_wrong_length_or_type_refused() public {
        bytes memory d = _descriptor(new bytes(40_000), 2);
        _content(d, _spanHeader(39_999), 10);
        _content(d, _spanHeader(40_001), 10);
        _content(d, _spanHeader(0), 10);
        // a files-bytes/1 record of the right size is not a span root
        _content(d, _bytesHeader(new bytes(40_000)), 9);
        _content(d, _header(keccak256("another Type"), 96, 0, 0, bytes32(uint256(40_000))), 9);
        RefHeader[] memory unadmitted = _spanHeader(40_000);
        unadmitted[0].firstAdmission = 0;
        _content(d, unadmitted, 9);
        // a single chunk under carrier 2, and a span under carrier 0
        _content(_descriptor(hex"ff", 2), _bytesHeader(hex"ff"), 9);
        _content(_descriptor(new bytes(40_000), 0), _spanHeader(40_000), 6);
        // carrier 3 does not exist
        _content(_descriptor(new bytes(40_000), 3), _spanHeader(40_000), 4);
    }

    function test_content_span_encrypted() public {
        // an encrypted large file: the span holds the ciphertext, length == plaintextLength + 16
        bytes memory d = abi.encode(
            BYTES_REF,
            uint256(1),
            uint256(2),
            uint256(1),
            uint256(100_016),
            keccak256("ciphertext digest"),
            uint256(0),
            uint256(1),
            bytes32(bytes12(keccak256("nonce"))),
            uint256(100_000),
            bytes32(0)
        );
        _content(d, _spanHeader(100_016), 0);
        _content(d, _spanHeader(100_000), 10);
    }

    function _encrypted(uint256 plainLength) internal pure returns (bytes memory d) {
        bytes memory cipherText = new bytes(plainLength + 16);
        d = abi.encode(
            BYTES_REF,
            uint256(1),
            uint256(0),
            uint256(1),
            cipherText.length,
            sha256(cipherText),
            uint256(0),
            uint256(1),
            bytes32(bytes12(keccak256("nonce"))),
            plainLength,
            bytes32(0)
        );
    }

    // L test_encryption_canonical_parameters_required, test_encrypted_public_plaintext_fingerprint_rejected_direct_core
    function test_content_encryption_parameters() public {
        RefHeader[] memory h = _bytesHeader(new bytes(17));
        _content(_encrypted(1), h, 0);
        bytes memory d = _encrypted(1);
        d[9 * 32 + 31] = bytes1(uint8(2)); // plaintextLength + 16 != length
        _content(d, h, 5);
        d = _encrypted(1);
        d[10 * 32 + 31] = 0x01; // a public plaintext fingerprint
        _content(d, h, 5);
        d = _encrypted(1);
        d[8 * 32 + 24] = 0x01; // nonce wider than 12 bytes
        _content(d, h, 4);
        // plaintext with a nonce, or with a fingerprint that is not the digest
        d = _descriptor(hex"ff", 0);
        d[8 * 32] = 0x01;
        _content(d, _bytesHeader(hex"ff"), 5);
        d = _descriptor(hex"ff", 0);
        d[10 * 32] = bytes1(uint8(d[10 * 32]) ^ 1);
        _content(d, _bytesHeader(hex"ff"), 5);
    }

    function test_content_context_is_authenticated() public {
        _contextIsAuthenticated(
            content, _descriptor(hex"ff", 0), _one(BYTES_REF), _bytesHeader(hex"ff")
        );
    }

    function test_content_carrier_types_are_constructor_state() public {
        assertEq(content.bytesTypeId(), BYTES_TYPE);
        assertEq(content.spanTypeId(), SPAN_TYPE);
        FilesContentRule other = new FilesContentRule(SPAN_TYPE, BYTES_TYPE);
        assertEq(address(other).codehash, address(content).codehash, "one runtime for every pair");
        _refuses(other, _ctx(), _descriptor(hex"ff", 0), _one(BYTES_REF), _bytesHeader(hex"ff"), 6);
        _refuses(other, _ctx(), _descriptor(new bytes(9), 2), _one(BYTES_REF), _spanHeader(9), 9);
    }

    function test_carrier_rules_are_plain_runtimes() public {
        _codeChecks(address(bytesRule), "FilesBytesRule");
        _codeChecks(address(content), "FilesContentRule");
    }
}
