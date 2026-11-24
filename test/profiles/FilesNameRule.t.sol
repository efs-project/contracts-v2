// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IAcceptor} from "../../src/interfaces/IAcceptor.sol";
import {FilesName, FilesNameRule} from "../../src/profiles/FilesNameRule.sol";
import {FilesUnitBase} from "./FilesUnitBase.sol";
import {FilesNameVectors} from "./FilesNameVectors.sol";

/// @notice `files-name/2`: agreement with the naming experiment's 50 oracle vectors, the prototype's exhaustive
///         byte and 255-boundary canary (rewritten for the UTF-8 grammar), malformed UTF-8 classes, the reserved
///         prefix, a differential fuzz against the experiment's naive arm (`NameV2`), measured gas and code shape.
contract FilesNameRuleTest is FilesUnitBase {
    FilesNameRule internal rule;

    function setUp() public override {
        super.setUp();
        rule = new FilesNameRule();
    }

    function valid(bytes calldata d) external pure returns (bool) {
        return FilesName.valid(d);
    }

    function _accept(bytes memory name) internal returns (bool ok) {
        (ok,) = _call(rule, _ctx(), name, _none(), _noHeaders());
    }

    // ---- the experiment's oracle ---------------------------------------------------------------------------

    function test_name_oracle_vectors_and_roles() public {
        FilesNameVectors.V[] memory vs = FilesNameVectors.all();
        for (uint256 i; i < vs.length; ++i) {
            assertEq(keccak256(vs[i].data), vs[i].role, "role is keccak256(name)");
            assertEq(
                this.valid(vs[i].data),
                vs[i].valid,
                string.concat("grammar vector ", vm.toString(i))
            );
            if (vs[i].valid) _accepts(rule, _ctx(), vs[i].data, _none(), _noHeaders());
            else _refuses(rule, _ctx(), vs[i].data, _none(), _noHeaders(), 2);
        }
    }

    // ---- L FilesNames test_name_grammar_exhaustive_bytes_and_255_boundaries, for files-name/2 ---------------

    function test_name_exhaustive_single_bytes_and_255_boundaries() public view {
        for (uint256 c; c < 256; ++c) {
            bool printable = c >= 0x20 && c <= 0x7e && c != 0x2f && c != 0x5c;
            bytes memory one = new bytes(1);
            one[0] = bytes1(uint8(c));
            // one byte: printable ASCII except '/', '\', the dot name and a lone space (whitespace at the ends)
            assertEq(this.valid(one), printable && c != 0x2e && c != 0x20, "single-byte grammar");
            bytes memory two = new bytes(2);
            two[0] = bytes1(uint8(c));
            two[1] = "a";
            // a leading byte: '.' is fine before 'a'; a leading space is not; no lone byte >= 0x80 is UTF-8
            assertEq(this.valid(two), printable && c != 0x20, "leading-byte grammar");
            two[0] = "a";
            two[1] = bytes1(uint8(c));
            assertEq(this.valid(two), printable && c != 0x20, "trailing-byte grammar");
        }
        assertFalse(this.valid(".") || this.valid(".."), "the dot names");
        assertTrue(
            this.valid("...") && this.valid(".hidden") && this.valid("ends."), "literal dots"
        );
        bytes memory edge = new bytes(255);
        for (uint256 i; i < 255; ++i) {
            edge[i] = "a";
        }
        assertTrue(this.valid(edge), "Name255");
        edge[0] = hex"00";
        assertFalse(this.valid(edge), "first byte ignored");
        edge[0] = "a";
        edge[127] = hex"ff";
        assertFalse(this.valid(edge), "middle byte ignored");
        edge[127] = "a";
        edge[254] = hex"7f";
        assertFalse(this.valid(edge), "last byte ignored");
        edge[254] = "z";
        assertTrue(this.valid(edge), "a valid last byte");
        assertFalse(this.valid(new bytes(0)), "empty");
        assertFalse(this.valid(bytes.concat(edge, "a")), "256 bytes");
        // 255 bytes of 3-byte CJK minus the truncation: 85 scalars fit exactly, an 86th does not
        bytes memory cjk;
        for (uint256 i; i < 85; ++i) {
            cjk = bytes.concat(cjk, hex"e7958c");
        }
        assertTrue(this.valid(cjk), "255-byte CJK");
        assertFalse(this.valid(bytes.concat(cjk, hex"e7958c")), "258-byte CJK");
    }

    function test_name_malformed_utf8_refused() public view {
        bytes[14] memory bad = [
            bytes(hex"c080"), // overlong NUL
            hex"c1bf", // overlong
            hex"e08080", // overlong 3-byte
            hex"e09fbf", // overlong below U+0800
            hex"f0808080", // overlong 4-byte
            hex"f08fbfbf", // overlong below U+10000
            hex"eda080", // surrogate U+D800
            hex"edbfbf", // surrogate U+DFFF
            hex"f4908080", // above U+10FFFF
            hex"f5808080", // invalid lead
            hex"61c3", // truncated 2-byte at the end
            hex"61e695", // truncated 3-byte at the end
            hex"61f09f93", // truncated 4-byte at the end
            hex"61806162" // lone continuation byte
        ];
        for (uint256 i; i < bad.length; ++i) {
            assertFalse(this.valid(bad[i]), string.concat("malformed ", vm.toString(i)));
        }
        // the boundaries of each width
        assertFalse(this.valid(hex"c280"), "U+0080 is a C1 control");
        assertTrue(this.valid(hex"c2a1"), "U+00A1");
        assertTrue(this.valid(hex"dfbf"), "U+07FF");
        assertTrue(this.valid(hex"e0a080"), "U+0800");
        assertTrue(this.valid(hex"ee8080"), "U+E000");
        assertTrue(this.valid(hex"f0908080"), "U+10000");
        assertTrue(this.valid(hex"f48fbfbd"), "U+10FFFD");
        assertFalse(this.valid(hex"f48fbfbf"), "U+10FFFF is a noncharacter");
    }

    function test_name_reserved_prefix_and_excluded_scalars() public view {
        assertFalse(this.valid("~efs"), "~efs");
        assertFalse(this.valid("~efs-control"), "~efs prefix");
        assertTrue(this.valid("~ef"), "shorter than the prefix");
        assertTrue(this.valid("~Efs"), "case-sensitive prefix");
        assertTrue(this.valid("a~efs"), "not a prefix");
        assertTrue(this.valid("~backup.txt"), "leading tilde");
        // whitespace at the ends: U+00A0, U+3000; inside is fine
        assertFalse(this.valid(hex"c2a061"), "leading NBSP");
        assertFalse(this.valid(hex"61e38080"), "trailing ideographic space");
        assertTrue(this.valid(hex"61e3808061"), "inner ideographic space");
        // exclusion sets: line separator, bidi isolate, noncharacter, U+1FFFE, replacement character
        assertFalse(this.valid(hex"61e280a8"), "U+2028");
        assertFalse(this.valid(hex"61e281a6"), "U+2066");
        assertFalse(this.valid(hex"61efb790"), "U+FDD0");
        assertFalse(this.valid(hex"61f09fbfbe"), "U+1FFFE");
        assertFalse(this.valid(hex"61efbfbd"), "U+FFFD");
        assertTrue(this.valid(hex"61e2808d62"), "ZWJ is allowed");
        assertTrue(this.valid(hex"61efb88f"), "variation selector 16 is allowed");
    }

    /// The experiment's naive arm (`NameV2`), as the reference for the fast decoder.
    function _naive(bytes memory d) internal pure returns (bool) {
        uint256 n = d.length;
        if (n == 0 || n > 255) return false;
        if (d[0] == 0x2e && (n == 1 || (n == 2 && d[1] == 0x2e))) return false;
        if (n >= 4 && d[0] == 0x7e && d[1] == 0x65 && d[2] == 0x66 && d[3] == 0x73) return false;
        uint32 first;
        uint32 last;
        for (uint256 i; i < n;) {
            uint8 f = uint8(d[i]);
            uint256 w;
            uint32 s;
            if (f < 0x80) {
                (s, w) = (f, 1);
            } else if (f >= 0xc2 && f <= 0xdf) {
                (s, w) = (f & 0x1f, 2);
            } else if (f >= 0xe0 && f <= 0xef) {
                (s, w) = (f & 0x0f, 3);
            } else if (f >= 0xf0 && f <= 0xf4) {
                (s, w) = (f & 0x07, 4);
            } else {
                return false;
            }
            if (i + w > n) return false;
            for (uint256 j = 1; j < w; ++j) {
                uint8 x = uint8(d[i + j]);
                if (x < 0x80 || x > 0xbf) return false;
                s = (s << 6) | uint32(x & 0x3f);
            }
            if (
                (w == 2 && s < 0x80) || (w == 3 && s < 0x800)
                    || (w == 4 && (s < 0x10000 || s > 0x10ffff)) || (s >= 0xd800 && s <= 0xdfff)
            ) return false;
            if (FilesName.excluded(s)) return false;
            if (i == 0) first = s;
            last = s;
            i += w;
        }
        return !FilesName.whitespace(first) && !FilesName.whitespace(last);
    }

    function testFuzz_name_fast_path_matches_the_naive_decoder(bytes memory d) public view {
        assertEq(this.valid(d), _naive(d));
    }

    function testFuzz_name_multibyte_mix_matches_the_naive_decoder(uint256 seed, uint8 len)
        public
        view
    {
        // bias towards UTF-8-shaped bytes: leads and continuations
        bytes memory d = new bytes(uint256(len) % 64 + 1);
        for (uint256 i; i < d.length; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint8 b = uint8(r);
            uint8 k = uint8(r >> 8) % 4;
            d[i] = bytes1(
                k == 0
                    ? (b % 0x5f) + 0x20
                    : k == 1 ? (b % 0x40) + 0x80 : k == 2 ? (b % 0x35) + 0xc0 : b
            );
        }
        assertEq(this.valid(d), _naive(d));
    }

    // ---- measured gas (warm external call as the ledger, including calldata) -----------------------------------

    function test_name_gas() public {
        FilesNameVectors.V[] memory vs = FilesNameVectors.all();
        _accept(vs[0].data); // warm the rule and the stub
        uint256[6] memory pick = [uint256(0), 3, 5, 27, 28, 36];
        for (uint256 i; i < pick.length; ++i) {
            bytes memory name = vs[pick[i]].data;
            assertTrue(_accept(name));
            uint256 used = vm.lastFrameGas().gasTotalUsed; // the rule's own frame, warm
            emit log_named_uint(
                string.concat(
                    "files-name/2 accept frame gas, vector ",
                    vm.toString(pick[i]),
                    ", bytes ",
                    vm.toString(name.length)
                ),
                used
            );
            assertLt(used, 150_000, "inside the 300k acceptor default");
        }
    }

    function test_name_refs_refused_and_context_is_authenticated() public {
        _refuses(rule, _ctx(), "readme.txt", _one(keccak256("x")), _noHeaders(), 1);
        _contextIsAuthenticated(rule, "readme.txt", _none(), _noHeaders());
    }

    function test_name_rule_is_a_plain_runtime() public {
        _codeChecks(address(rule), "FilesNameRule");
    }
}
