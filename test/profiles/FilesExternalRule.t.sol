// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IAcceptor, RefHeader} from "../../src/interfaces/IAcceptor.sol";
import {FilesExternalContentRule} from "../../src/profiles/FilesExternalContentRule.sol";
import {FilesUnitBase} from "./FilesUnitBase.sol";

/// @notice `files-external/1` (docs/LARGE-FILES.md): the structural locator law — a URI of 1..2,048 printable ASCII
///         bytes starting with an RFC 3986 scheme and at least one byte after the colon, with no scheme allowlist —
///         the 7-word head (the media type, the body's tail, is `FilesMediaType.t.sol`), the empty-sentinel reference and the context check; a fuzzed differential against a
///         byte-at-a-time reference of the law.
contract FilesExternalRuleTest is FilesUnitBase {
    FilesExternalContentRule internal ext;

    bytes32 internal constant BYTES_TYPE = keccak256("test/files/bytes-type");
    bytes32 internal constant BYTES_REF = keccak256("a files-bytes/1 record");
    bytes32 internal constant EMPTY = sha256("");
    string internal constant AR = "ar://AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";

    function setUp() public override {
        super.setUp();
        ext = new FilesExternalContentRule();
    }

    function _external(uint256 length, bytes memory uri) internal pure returns (bytes memory) {
        return _external(length, uri, 2);
    }

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

    function _sentinel() internal pure returns (RefHeader[] memory) {
        return _header(BYTES_TYPE, 32, EMPTY, 0, 0);
    }

    function _ext(bytes memory b, uint8 code) internal {
        if (code == 0) _accepts(ext, _ctx(), b, _one(BYTES_REF), _sentinel());
        else _refuses(ext, _ctx(), b, _one(BYTES_REF), _sentinel(), code);
    }

    function _uri(bytes memory uri, uint8 code) internal {
        _ext(_external(5, uri), code);
    }

    /// `n` bytes: `a:` then `x`s.
    function _long(uint256 n) internal pure returns (bytes memory u) {
        u = new bytes(n);
        u[0] = "a";
        u[1] = ":";
        for (uint256 i = 2; i < n; ++i) {
            u[i] = "x";
        }
    }

    // ---- accepted: any scheme ----------------------------------------------------------------------------------

    function test_locators_of_every_scheme_are_admitted() public {
        _uri(bytes(AR), 0);
        _uri("ipfs://QmYwAPJzv5CZsnAzt8auVZRnGi2C2ZWfQ7eFMbB7xq4GoH/hello.txt", 0);
        _uri("ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi", 0);
        _uri("bzz://2477cc8584cc61091b5cc084cdcdb45bf3c6210c263b0143f030cf7d750e894d", 0);
        _uri("web3://0x5a985f13345e820aa9618826b85f74c3986e1463:1/path/index.html", 0);
        _uri("https://example.org/a?b=c#d", 0);
        _uri("data:text/plain,hi", 0);
        // schemes that do not exist yet, with every scheme character class
        _uri("coap+tcp://host/x", 0);
        _uri("x-y.z9:1", 0);
        _uri("Z:z", 0);
        _uri("a:b", 0); // the shortest scheme with one byte after the colon
        // the printable boundaries 0x21 and 0x7e anywhere after the scheme
        _uri("a:!~!~", 0);
        _uri("a:\"#$%&'()*+,-./0123456789:;<=>?@[\\]^_`{|}~", 0);
    }

    function test_locator_lengths_and_word_boundaries() public {
        // every length across the first three words (the printable check runs a word at a time)
        for (uint256 n = 3; n <= 97; ++n) {
            _uri(_long(n), 0);
        }
        _uri(_long(2_048), 0); // the inclusive maximum
        (bool ok,) = _call(ext, _ctx(), _external(5, _long(2_048)), _one(BYTES_REF), _sentinel());
        assertTrue(ok);
    }

    function test_locator_gas_worst_cases() public {
        // a full-length locator, and a full-length scheme (the scheme scan is the byte-at-a-time part)
        bytes memory longScheme = new bytes(2_048);
        for (uint256 i; i < 2_046; ++i) {
            longScheme[i] = "a";
        }
        longScheme[2_046] = ":";
        longScheme[2_047] = "x";
        bytes[2] memory uris = [_long(2_048), longScheme];
        string[2] memory labels = ["2,048-byte locator", "2,046-byte scheme"];
        for (uint256 i; i < 2; ++i) {
            bytes memory body = _external(5, uris[i]);
            RefHeader[] memory sentinel = _sentinel(); // computed before the prank (sha256 is a call)
            vm.prank(address(stub));
            uint256 before = gasleft();
            bytes4 got = ext.accept(_ctx(), body, _one(BYTES_REF), sentinel);
            uint256 used = before - gasleft();
            assertEq(got, IAcceptor.accept.selector);
            assertLt(used, 300_000, "inside the closure default acceptor budget");
            emit log_named_uint(string.concat("files-external/1 accept gas, ", labels[i]), used);
        }
    }

    function test_external_domains_inclusive_bounds() public {
        _ext(_external(type(uint64).max, bytes(AR)), 0); // the length bound is inclusive
        _ext(_external(0, bytes(AR)), 0);
        assertEq(_external(5, bytes(AR)).length, 272, "seven words and 48 locator bytes");
    }

    // ---- refused: the locator law ------------------------------------------------------------------------------

    function test_malformed_locators_are_refused() public {
        _uri("", 5); // empty
        _uri(_long(2_049), 5); // one byte over
        _uri("https://example.org/a b", 6); // a space
        _uri(" https://example.org", 6);
        _uri("https://example.org/\n", 6); // a control byte
        _uri(bytes.concat("a:x", hex"00"), 6); // NUL
        _uri(bytes.concat("a:x", hex"7f"), 6); // DEL
        _uri(bytes.concat("a:caf", hex"c3a9"), 6); // non-ASCII (UTF-8 e-acute)
        _uri(bytes.concat("a:x", hex"80"), 6);
        _uri(bytes.concat("a:x", hex"ff"), 6);
        _uri("example.org/path", 6); // no colon
        _uri("abc", 6);
        _uri("1http://x", 6); // a scheme starting with a digit
        _uri("+a:x", 6);
        _uri(":x", 6); // an empty scheme
        _uri("https:", 6); // nothing after the colon
        _uri("a:", 6);
        _uri("ht_tp://x", 6); // a byte outside the scheme alphabet before the colon
        _uri("ht%74p://x", 6);
        _uri("a/b:c", 6);
    }

    function test_a_bad_byte_in_any_lane_is_refused() public {
        uint8[5] memory bad = [0x20, 0x7f, 0x80, 0x00, 0x09];
        uint16[9] memory at = [2, 5, 31, 32, 33, 63, 64, 1_000, 2_047];
        for (uint256 i; i < bad.length; ++i) {
            for (uint256 j; j < at.length; ++j) {
                bytes memory u = _long(2_048);
                u[at[j]] = bytes1(bad[i]);
                _uri(u, 6);
            }
        }
        // the last byte of a short locator, in every lane of the tail word
        for (uint256 n = 3; n <= 40; ++n) {
            bytes memory u = _long(n);
            u[n - 1] = 0x20;
            _uri(u, 6);
        }
    }

    function test_the_first_colon_in_every_lane() public {
        // "a" + "b"s + ":" + "x"s: valid iff the colon is not the last byte; a second colon never matters
        // each case's memory is released before the next (nothing outlives it): about 7,000 calls would otherwise
        // grow memory past the test's gas
        uint256 free;
        assembly ("memory-safe") {
            free := mload(0x40)
        }
        for (uint256 n = 2; n <= 70; ++n) {
            for (uint256 c = 1; c < n; ++c) {
                assembly ("memory-safe") {
                    mstore(0x40, free)
                }
                bytes memory u = new bytes(n);
                for (uint256 i; i < n; ++i) {
                    u[i] = i == 0
                        ? bytes1("a")
                        : i < c ? bytes1("b") : i == c ? bytes1(":") : bytes1("x");
                }
                _uri(u, c + 1 < n ? 0 : 6);
                if (c + 1 < n) {
                    u[n - 1] = ":"; // a later colon in the last lane
                    _uri(u, 0);
                    u[c - 1 == 0 ? 0 : c - 1] = c == 1 ? bytes1("1") : bytes1("_"); // a bad byte before it
                    _uri(u, 6);
                }
            }
        }
    }

    function testFuzz_locator_law_matches_the_reference(bytes memory uri) public {
        if (uri.length > 2_100) {
            assembly ("memory-safe") {
                mstore(uri, 2100)
            }
        }
        bool want = uri.length >= 1 && uri.length <= 2_048 && _reference(uri);
        uint8 code = uri.length == 0 || uri.length > 2_048 ? 5 : 6;
        _uri(uri, want ? 0 : code);
    }

    function testFuzz_prefixed_locators_match_the_reference(bytes memory tail, uint8 mode) public {
        // mostly printable inputs, so the scheme and colon branches are reached
        bytes memory head =
            mode % 3 == 0 ? bytes("web3:") : mode % 3 == 1 ? bytes("x+1.-") : bytes("");
        bytes memory uri = bytes.concat(head, tail);
        for (uint256 i; i < uri.length; ++i) {
            if (mode & 0x80 != 0) uri[i] = bytes1(uint8(0x21 + uint8(uri[i]) % 0x5e));
        }
        if (uri.length > 2_048) {
            assembly ("memory-safe") {
                mstore(uri, 2048)
            }
        }
        bool want = uri.length >= 1 && _reference(uri);
        _uri(uri, want ? 0 : (uri.length == 0 ? 5 : 6));
    }

    /// The law one byte at a time.
    function _reference(bytes memory u) internal pure returns (bool) {
        for (uint256 i; i < u.length; ++i) {
            uint8 c = uint8(u[i]);
            if (c < 0x21 || c > 0x7e) return false;
        }
        if (!_isAlpha(uint8(u[0]))) return false;
        for (uint256 i = 1; i < u.length; ++i) {
            uint8 c = uint8(u[i]);
            if (c == 0x3a) return i + 1 < u.length;
            if (!_isAlpha(c) && !(c >= 0x30 && c <= 0x39) && c != 0x2b && c != 0x2d && c != 0x2e) {
                return false;
            }
        }
        return false;
    }

    function _isAlpha(uint8 c) internal pure returns (bool) {
        return (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a);
    }

    // ---- refused: the head and the reference -------------------------------------------------------------------

    // L test_invalid_external_and_sentinel_fail_closed, test_new_type_does_not_reinterpret_old_type_or_descriptor
    function test_external_invalid_domains() public {
        _ext(_external(uint256(type(uint64).max) + 1, bytes(AR)), 4);
        bytes memory b = _external(5, bytes(AR));
        b[63] = 0x01;
        _ext(b, 4); // version 1 under the external Type
        _ext(_external(5, bytes(AR), 3), 4); // the retired ipfs carrier
        _ext(_external(5, bytes(AR), 0), 4);
        _ext(_external(5, bytes(AR), 1), 4);
        b = _external(5, bytes(AR));
        b[127] = 0x02;
        _ext(b, 4); // another hash algorithm
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

    function test_external_locator_length_and_the_media_tail() public {
        bytes memory b = _external(5, bytes(AR));
        // bytes after the locator are the media type, judged by its grammar ("x" has no "/")
        _ext(bytes.concat(b, "x"), 9);
        _ext(bytes.concat(b, "text/plain"), 0);
        // a locator length past the body
        b[223] = bytes1(uint8(b[223]) + 1);
        _ext(b, 5);
        // a shorter locator length leaves the locator's last byte ("A") as the media type: refused
        b[223] = bytes1(uint8(b[223]) - 2);
        _ext(b, 9);
        _ext(new bytes(223), 2);
        // a length word claiming a 2,049-byte locator that is present
        _ext(_external(5, bytes.concat(_long(2_048), "x")), 5);
    }

    function test_external_requires_the_empty_sentinel() public {
        bytes memory b = _external(5, bytes(AR));
        _refuses(ext, _ctx(), b, _one(BYTES_REF), _header(BYTES_TYPE, 33, sha256("x"), 0, 0), 7);
        _refuses(ext, _ctx(), b, _one(BYTES_REF), _header(BYTES_TYPE, 32, sha256("x"), 0, 0), 7);
        RefHeader[] memory h = _sentinel();
        h[0].firstAdmission = 0;
        _refuses(ext, _ctx(), b, _one(BYTES_REF), h, 7);
        b[31] = bytes1(uint8(b[31]) ^ 1);
        _ext(b, 3);
        _refuses(ext, _ctx(), _external(5, bytes(AR)), _none(), h, 1);
    }

    function test_external_context_is_authenticated() public {
        _contextIsAuthenticated(ext, _external(5, bytes(AR)), _one(BYTES_REF), _sentinel());
    }

    function test_external_rule_is_a_plain_runtime() public {
        _codeChecks(address(ext), "FilesExternalContentRule");
    }
}
