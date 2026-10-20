// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IAcceptor, RefHeader} from "../../src/interfaces/IAcceptor.sol";
import {FilesBytesRule} from "../../src/profiles/FilesBytesRule.sol";
import {FilesContentRule} from "../../src/profiles/FilesContentRule.sol";
import {FilesExternalContentRule} from "../../src/profiles/FilesExternalContentRule.sol";
import {FilesUnitBase} from "./FilesUnitBase.sol";

/// @notice `files-bytes/1`, `files-content/1` and `files-external/1`: the rule-level cases of the prototype's
///         `FilesCarrierProfile.t.sol` and `FilesExternalContentProfile.t.sol`, rewritten for the v2 layouts (the
///         external Type is the 7-word head of design §12.1, not the prototype's packed head), plus context checks.
contract FilesCarrierRulesTest is FilesUnitBase {
    FilesBytesRule internal bytesRule;
    FilesContentRule internal content;
    FilesExternalContentRule internal ext;

    bytes32 internal constant BYTES_TYPE = keccak256("test/files/bytes-type");
    bytes32 internal constant BYTES_REF = keccak256("a files-bytes/1 record");
    bytes32 internal constant EMPTY = sha256("");
    string internal constant AR = "ar://AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    string internal constant IPFS0 =
        "ipfs://QmYwAPJzv5CZsnAzt8auVZRnGi2C2ZWfQ7eFMbB7xq4GoH/hello.txt";
    string internal constant IPFS1 =
        "ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi";

    function setUp() public override {
        super.setUp();
        bytesRule = new FilesBytesRule();
        content = new FilesContentRule();
        ext = new FilesExternalContentRule();
    }

    // ---- files-bytes/1 -----------------------------------------------------------------------------------------

    function _bytes(bytes memory payload) internal pure returns (bytes memory) {
        return bytes.concat(abi.encode(sha256(payload)), payload);
    }

    function test_bytes_accepts_empty_binary_and_maximum_payloads() public {
        _accepts(bytesRule, _ctx(), _bytes(""), _none(), _noHeaders()); // the remote sentinel
        _accepts(bytesRule, _ctx(), _bytes(hex"00ff8041"), _none(), _noHeaders());
        _accepts(bytesRule, _ctx(), _bytes(new bytes(8160)), _none(), _noHeaders()); // L test_bytes_maximum_payload_admission
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
        _refuses(bytesRule, _ctx(), new bytes(8193), _none(), _noHeaders(), 2);
        _refuses(bytesRule, _ctx(), _bytes(new bytes(8161)), _none(), _noHeaders(), 2);
        _refuses(bytesRule, _ctx(), bytes(""), _none(), _noHeaders(), 2);
        _refuses(bytesRule, _ctx(), new bytes(31), _none(), _noHeaders(), 2);
        _refuses(bytesRule, _ctx(), _bytes("x"), _one(BYTES_REF), _noHeaders(), 1);
    }

    function test_bytes_context_is_authenticated() public {
        _contextIsAuthenticated(bytesRule, _bytes("payload"), _none(), _noHeaders());
    }

    // ---- files-content/1 ---------------------------------------------------------------------------------------

    /// The 11 words for `raw`: inline (carrier 0) or remote (carrier 1), plaintext.
    function _descriptor(bytes memory raw, uint256 carrier) internal pure returns (bytes memory) {
        return abi.encode(
            BYTES_REF,
            uint256(1),
            carrier,
            uint256(1),
            raw.length,
            sha256(raw),
            uint256(0),
            uint256(0),
            bytes32(0),
            raw.length,
            sha256(raw)
        );
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
        uint8[7] memory bad = [2, 2, 2, 0x11, 3, 2, 0x11];
        for (uint256 i; i < word.length; ++i) {
            bytes memory d = _descriptor(hex"ff", 0);
            if (word[i] == 4 || word[i] == 9) {
                // length / plaintextLength above 1 MiB
                bytes32 big = bytes32((uint256(1) << 20) + 1);
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
        _content(d, _header(BYTES_TYPE, 8193, sha256(hex"ff"), 0, 0), 6);
        RefHeader[] memory unadmitted = _bytesHeader(hex"ff");
        unadmitted[0].firstAdmission = 0;
        _content(d, unadmitted, 6);
    }

    // L test_external_requires_empty_inline_sentinel
    function test_content_remote_requires_the_empty_sentinel() public {
        _content(_descriptor(hex"ff", 1), _bytesHeader(""), 0);
        _content(_descriptor(hex"ff", 1), _bytesHeader(hex"ff"), 7);
        _content(_descriptor(hex"ff", 0), _bytesHeader(""), 8);
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

    // ---- files-external/1 --------------------------------------------------------------------------------------

    function _external(uint256 length, bytes memory uri, uint256 carrier)
        internal
        pure
        returns (bytes memory)
    {
        return bytes.concat(
            abi.encode(
                BYTES_REF, uint256(2), carrier, uint256(1), length, sha256("hello"), uri.length
            ),
            uri
        );
    }

    function _ext(bytes memory b, uint8 code) internal {
        RefHeader[] memory sentinel = _header(BYTES_TYPE, 32, EMPTY, 0, 0);
        if (code == 0) _accepts(ext, _ctx(), b, _one(BYTES_REF), sentinel);
        else _refuses(ext, _ctx(), b, _one(BYTES_REF), sentinel, code);
    }

    // L test_compact_ar_and_ipfs_exact_locator_retained (the rule half; retention is FilesRecipes)
    function test_external_ar_and_ipfs_locators() public {
        _ext(_external(5, bytes(AR), 2), 0);
        assertEq(_external(5, bytes(AR), 2).length, 272, "seven words and 48 locator bytes");
        _ext(_external(5, bytes(IPFS0), 3), 0);
        _ext(_external(5, bytes(IPFS1), 3), 0);
        _ext(_external(5, bytes.concat(bytes(IPFS1), "/a/b.c_d~e-f"), 3), 0);
        _ext(_external(1 << 24, bytes(AR), 2), 0); // the length bound is inclusive
        _ext(_external(0, bytes(AR), 2), 0);
    }

    // L test_invalid_external_and_sentinel_fail_closed, test_new_type_does_not_reinterpret_old_type_or_descriptor
    function test_external_invalid_locators_and_domains() public {
        _ext(_external((1 << 24) + 1, bytes(AR), 2), 4);
        _ext(_external(5, "ar://short", 2), 6);
        _ext(_external(5, bytes(AR), 3), 6); // an ar locator under the ipfs carrier
        _ext(_external(5, bytes(IPFS0), 2), 6);
        _ext(_external(5, bytes.concat(bytes(IPFS0), "/../x"), 3), 6);
        _ext(_external(5, bytes.concat(bytes(IPFS0), "/%2e"), 3), 6);
        _ext(_external(5, bytes.concat(bytes(IPFS0), "/"), 3), 6);
        _ext(_external(5, bytes.concat(bytes(IPFS0), "//x"), 3), 6);
        _ext(_external(5, bytes.concat(bytes(IPFS0), "/./x"), 3), 6);
        _ext(_external(5, "ipfs://QmYwAPJzv5CZsnAzt8auVZRnGi2C2ZWfQ7eFMbB7xq4Go0", 3), 6); // base58 has no 0
        _ext(_external(5, "ipfs://QmYwAPJzv5CZsnAzt8auVZRnGi2C2ZWfQ7eFMbB7xq4GoHH", 3), 6); // 45 chars after Qm
        _ext(_external(5, "ipfs://bAFYBEIGDYRZT5SFP7UDM7HU76UH7Y26NF3", 3), 6); // upper-case base32
        _ext(_external(5, "ipfs://zb2rhe5P4gXftAwvA4eXQ5HJwsER2owDyS9", 3), 6); // another multibase
        bytes memory arBad = bytes.concat(bytes("ar://"), new bytes(43)); // NUL is not base64url
        _ext(_external(5, arBad, 2), 6);
        // version, carrier, algorithm
        bytes memory b = _external(5, bytes(AR), 2);
        b[63] = 0x01;
        _ext(b, 4); // version 1 under the external Type
        b = _external(5, bytes(AR), 4);
        _ext(b, 4);
        b = _external(5, bytes(AR), 2);
        b[127] = 0x02;
        _ext(b, 4);
        // the prototype's v1 descriptor (352 bytes) is not reinterpreted: version 1 is refused
        bytes memory v1 = abi.encode(
            BYTES_REF,
            uint256(1),
            uint256(1),
            uint256(1),
            uint256(5),
            sha256("hello"),
            uint256(1),
            uint256(0),
            bytes32(0),
            uint256(5),
            sha256("hello")
        );
        _ext(v1, 4);
    }

    function test_external_locator_length_is_the_body_tail() public {
        bytes memory b = _external(5, bytes(AR), 2);
        _ext(bytes.concat(b, "x"), 5); // a trailing byte the length word does not cover
        b[223] = bytes1(uint8(b[223]) + 1);
        _ext(b, 5);
        _ext(_external(5, "", 2), 5);
        _ext(new bytes(223), 2);
        bytes memory long = bytes.concat(bytes(IPFS0));
        while (long.length <= 512) long = bytes.concat(long, "/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
        _ext(_external(5, long, 3), 5);
    }

    function test_external_requires_the_empty_sentinel() public {
        bytes memory b = _external(5, bytes(AR), 2);
        _refuses(ext, _ctx(), b, _one(BYTES_REF), _header(BYTES_TYPE, 33, sha256("x"), 0, 0), 7);
        _refuses(ext, _ctx(), b, _one(BYTES_REF), _header(BYTES_TYPE, 32, sha256("x"), 0, 0), 7);
        RefHeader[] memory h = _header(BYTES_TYPE, 32, EMPTY, 0, 0);
        h[0].firstAdmission = 0;
        _refuses(ext, _ctx(), b, _one(BYTES_REF), h, 7);
        b[31] = bytes1(uint8(b[31]) ^ 1);
        _ext(b, 3);
        _refuses(ext, _ctx(), _external(5, bytes(AR), 2), _none(), h, 1);
    }

    function test_external_context_is_authenticated() public {
        _contextIsAuthenticated(
            ext, _external(5, bytes(AR), 2), _one(BYTES_REF), _header(BYTES_TYPE, 32, EMPTY, 0, 0)
        );
    }

    function test_carrier_rules_are_plain_runtimes() public {
        _codeChecks(address(bytesRule), "FilesBytesRule");
        _codeChecks(address(content), "FilesContentRule");
        _codeChecks(address(ext), "FilesExternalContentRule");
    }
}
