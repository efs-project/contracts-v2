// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {AcceptContext, IAcceptor, RefHeader} from "../../src/interfaces/IAcceptor.sol";
import {CodeScan} from "../../src/lib/CodeScan.sol";
import {E_FILES_CONTEXT} from "../../src/profiles/FilesProfile.sol";
import {FilesName} from "../../src/profiles/FilesNameRule.sol";
import {TopicProfile, E_TOPIC_REFUSED} from "../../src/profiles/TopicProfile.sol";
import {TopicWordRule} from "../../src/profiles/TopicWordRule.sol";
import {TopicRule} from "../../src/profiles/TopicRule.sol";
import {TextRule} from "../../src/profiles/TextRule.sol";

/// The grammar library over calldata, so the tests (and the vectors suite) can call it directly.
contract TopicProbe {
    function wordRefusal(bytes calldata w) external pure returns (uint256) {
        return TopicProfile.wordRefusal(w);
    }

    function textRefusal(bytes calldata x) external pure returns (uint256) {
        return TopicProfile.textRefusal(x);
    }

    function refusedClass(uint256 s) external pure returns (uint256) {
        return TopicProfile.refusedClass(s);
    }

    function refusedTable() external pure returns (bytes memory) {
        return TopicProfile.REFUSED;
    }

    function nameValid(bytes calldata d) external pure returns (bool) {
        return FilesName.valid(d);
    }
}

/// @notice `TopicProfile.wordRefusal` and `textRefusal` (every code, boundaries, the refused table) and the three rules
///         called directly with this contract as the ledger. The full vector list is `TopicVectors.t.sol`.
contract TopicRulesTest is Test {
    bytes32 internal constant WORD_TYPE = keccak256("test/topic-word");
    bytes32 internal constant TOPIC_TYPE = keccak256("test/topic");
    bytes32 internal constant TEXT_TYPE = keccak256("test/text");

    TopicProbe internal probe;
    TopicWordRule internal wordRule;
    TopicRule internal topicRule;
    TextRule internal textRule;

    function setUp() public {
        probe = new TopicProbe();
        wordRule = new TopicWordRule();
        topicRule = new TopicRule(WORD_TYPE);
        textRule = new TextRule();
    }

    function _code(bytes memory w) internal view returns (uint256) {
        return probe.wordRefusal(w);
    }

    function _text(bytes memory x) internal view returns (uint256) {
        return probe.textRefusal(x);
    }

    function _repeat(bytes memory unit, uint256 n) internal pure returns (bytes memory out) {
        for (uint256 i; i < n; ++i) {
            out = bytes.concat(out, unit);
        }
    }

    /// UTF-8 of scalar `s` (no validation).
    function _utf8(uint256 s) internal pure returns (bytes memory) {
        if (s < 0x80) return abi.encodePacked(uint8(s));
        if (s < 0x800) return abi.encodePacked(uint8(0xc0 | (s >> 6)), uint8(0x80 | (s & 0x3f)));
        if (s < 0x10000) {
            return abi.encodePacked(
                uint8(0xe0 | (s >> 12)), uint8(0x80 | ((s >> 6) & 0x3f)), uint8(0x80 | (s & 0x3f))
            );
        }
        return abi.encodePacked(
            uint8(0xf0 | (s >> 18)),
            uint8(0x80 | ((s >> 12) & 0x3f)),
            uint8(0x80 | ((s >> 6) & 0x3f)),
            uint8(0x80 | (s & 0x3f))
        );
    }

    // ---- word: 1 length ------------------------------------------------------------------------------------

    function test_word_length() public view {
        assertEq(_code(""), 1);
        assertEq(_code("a"), 0);
        assertEq(_code(_repeat("a", 255)), 0);
        assertEq(_code(_repeat("a", 256)), 1);
        assertEq(_code(_repeat(hex"e69db1", 85)), 0); // 255 bytes of CJK
        assertEq(_code(bytes.concat(_repeat(hex"e69db1", 85), "a")), 1);
    }

    // ---- word: 2 UTF-8 --------------------------------------------------------------------------------------

    function test_word_utf8() public view {
        assertEq(_code(bytes("caf\xc3\xa9")), 0);
        assertEq(_code(hex"e69db1e4baac"), 0);
        assertEq(_code(hex"f09f9a97"), 0);
        assertEq(_code(_utf8(0x10fffd)), 0);
        assertEq(_code(hex"c080"), 2, "overlong 2-byte");
        assertEq(_code(hex"c1bf"), 2, "overlong 2-byte");
        assertEq(_code(hex"e08080"), 2, "overlong 3-byte");
        assertEq(_code(hex"f0808080"), 2, "overlong 4-byte");
        assertEq(_code(hex"eda080"), 2, "surrogate D800");
        assertEq(_code(hex"edbfbf"), 2, "surrogate DFFF");
        assertEq(_code(hex"f4908080"), 2, "above 10FFFF");
        assertEq(_code(hex"f5808080"), 2, "lead F5");
        assertEq(_code(hex"e282"), 2, "truncated 3-byte");
        assertEq(_code(hex"61e2"), 2, "truncated at the end");
        assertEq(_code(hex"80"), 2, "stray continuation");
        assertEq(_code(hex"c3"), 2, "lone lead");
        assertEq(_code(hex"c341"), 2, "lead then ASCII");
    }

    // ---- word: 3 an ASCII byte outside the 39 ------------------------------------------------------------------

    /// The 39 ASCII characters a word admits: `a`-`z`, `0`-`9`, `-`, `_`, `.`.
    function _wordAscii(uint256 c) internal pure returns (bool) {
        return
            (c >= 0x61 && c <= 0x7a) || (c >= 0x30 && c <= 0x39) || c == 0x2d || c == 0x5f
                || c == 0x2e;
    }

    function test_word_forbidden_ascii() public view {
        uint256 admitted;
        for (uint256 c; c < 0x80; ++c) {
            bool ok = _wordAscii(c);
            if (ok) ++admitted;
            assertEq(_code(abi.encodePacked(bytes1(uint8(c)), "x")), ok ? 0 : 3, "first");
            assertEq(_code(abi.encodePacked("x", bytes1(uint8(c)), "x")), ok ? 0 : 3, "inside");
            // last: '.' is the shape refusal 4
            assertEq(
                _code(abi.encodePacked("x", bytes1(uint8(c)))), ok ? (c == 0x2e ? 4 : 0) : 3, "last"
            );
        }
        assertEq(admitted, 39, "39 characters");
        assertEq(_code("~A"), 3, "a byte refusal comes before the shape refusals");
        assertEq(_code("A."), 3, "a byte refusal before a trailing dot");
        assertEq(_code("e\xcc\x81\x2f"), 3, "a / after a multi-byte scalar");
        assertEq(_code("a\\b"), 3, "a backslash reads as a path separator");
        assertEq(_code("\\"), 3, "only a backslash");
        assertEq(_code("c++"), 3, "c++ is not a word");
        assertEq(_code("c#"), 3, "c# is not a word");
        assertEq(_code("q&a"), 3, "& is not a word character");
        assertEq(_code("-a"), 0, "a leading - is admitted");
        assertEq(_text("C:\\x"), 0, "a text admits a backslash");
    }

    // ---- word: 4, 6 whole-word shapes (5 is unused) --------------------------------------------------------------

    function test_word_shapes() public view {
        assertEq(_code("."), 4);
        assertEq(_code(".."), 4);
        assertEq(_code("..."), 4);
        assertEq(_code("a."), 4);
        assertEq(_code(".a"), 0);
        assertEq(_code("a.b"), 0);
        assertEq(_code("a..b"), 0);
        // a `~` is a byte refusal anywhere: code 5 (once "starts with ~") is never returned
        assertEq(_code("~"), 3);
        assertEq(_code("~efs"), 3);
        assertEq(_code("a~"), 3);
        assertEq(_code("a~b"), 3);
        bytes memory hex40 = "00112233445566778899aabbccddeeff00112233";
        assertEq(_code(bytes.concat("0x", hex40)), 6);
        assertEq(_code(bytes.concat("0x", _repeat("f", 39))), 0, "39 hex");
        assertEq(_code(bytes.concat("0x", _repeat("f", 41))), 0, "41 hex");
        assertEq(_code(bytes.concat("0x", _repeat("f", 39), "g")), 0, "a non-hex character");
        assertEq(_code(bytes.concat("0X", hex40)), 3, "uppercase X is a byte refusal");
        assertEq(_code(bytes.concat("0x", _repeat("f", 39), ".")), 4, "a trailing dot first");
        assertEq(_code("0x"), 0);
        assertEq(_code("0xsplits"), 0, "only 0x and 40 hex is refused");
    }

    function testFuzz_word_never_answers_5(bytes memory w) public view {
        assertTrue(probe.wordRefusal(w) != 5);
    }

    // ---- word: 7 refused code points; the table -----------------------------------------------------------------

    function test_word_refused_classes() public view {
        uint256[12] memory refused = [
            uint256(0x85),
            0x61c,
            0x200b,
            0x200c,
            0x200d,
            0x202e,
            0x2066,
            0xfe0f,
            0xfeff,
            0xe0041,
            0xe0100,
            0x10ffff
        ];
        for (uint256 i; i < refused.length; ++i) {
            assertEq(_code(bytes.concat("a", _utf8(refused[i]))), 7);
        }
        // the neighbours of the entries are admitted
        uint256[12] memory ok = [
            uint256(0xa1),
            0x167f,
            0x1681,
            0x1fff,
            0x2030,
            0x205e,
            0x2fff,
            0x3001,
            0x2070,
            0xfe10,
            0xe1000,
            0x10fffd
        ];
        for (uint256 i; i < ok.length; ++i) {
            assertEq(_code(_utf8(ok[i])), 0);
        }
    }

    /// The table is sorted and disjoint, and every class of it is refused by a word; a text refuses classes 1-3.
    function test_table_shape_and_text_classes() public view {
        bytes memory t = probe.refusedTable();
        assertEq(t.length % 7, 0);
        uint256 prevHi;
        for (uint256 i; i < t.length; i += 7) {
            uint256 lo = uint24(bytes3(abi.encodePacked(t[i], t[i + 1], t[i + 2])));
            uint256 hi = uint24(bytes3(abi.encodePacked(t[i + 3], t[i + 4], t[i + 5])));
            uint256 cls = uint8(t[i + 6]);
            assertLe(lo, hi);
            if (i != 0) assertGt(lo, prevHi, "sorted, disjoint");
            prevHi = hi;
            assertTrue(cls >= 1 && cls <= 6);
            assertGe(lo, 0x80, "ASCII is the byte rules' business");
            assertLe(hi, 0x10ffff);
            for (uint256 s = lo; s <= hi; s += (hi - lo) / 2 + 1) {
                assertEq(probe.refusedClass(s), cls);
                if (s >= 0xd800 && s <= 0xdfff) continue;
                assertEq(_code(_utf8(s)), 7);
                uint256 tc = _text(_utf8(s));
                assertEq(tc, cls == 1 ? 22 : (cls <= 3 || cls == 5) ? 23 : 0);
            }
            assertEq(probe.refusedClass(hi), cls);
        }
    }

    // ---- whitespace: none at all in a word; spaces but no line breaks in a text ----------------------------------

    /// `tesla` followed by U+00A0 NO-BREAK SPACE looks like `tesla`: refused (code 7, class 6).
    function test_word_with_a_no_break_space_is_refused() public view {
        assertEq(_code("tesla"), 0);
        assertEq(_code(bytes.concat("tesla", _utf8(0xa0))), 7);
        assertEq(_code(bytes.concat(_utf8(0xa0), "tesla")), 7);
        assertEq(_code(bytes.concat("tes", _utf8(0xa0), "la")), 7);
    }

    function _whitespaceWord(uint256 s) internal view {
        assertEq(probe.refusedClass(s), TopicProfile.CLASS_WHITESPACE, "class 6");
        assertEq(_code(_utf8(s)), 7, "alone");
        assertEq(_code(bytes.concat("a", _utf8(s), "b")), 7, "inside");
        assertEq(_text(bytes.concat("a", _utf8(s), "b")), 0, "a text admits it");
    }

    function test_whitespace_u00a0() public view {
        _whitespaceWord(0xa0);
    }

    function test_whitespace_u1680() public view {
        _whitespaceWord(0x1680);
    }

    function test_whitespace_u2000_first_of_range() public view {
        _whitespaceWord(0x2000);
    }

    function test_whitespace_u200a_last_of_range() public view {
        _whitespaceWord(0x200a);
        for (uint256 s = 0x2001; s < 0x200a; ++s) {
            _whitespaceWord(s);
        }
        assertEq(probe.refusedClass(0x1fff), 0, "U+1FFF is not refused");
        assertEq(probe.refusedClass(0x200b), TopicProfile.CLASS_INVISIBLE, "U+200B keeps its class");
    }

    function test_whitespace_u202f() public view {
        _whitespaceWord(0x202f);
    }

    function test_whitespace_u205f() public view {
        _whitespaceWord(0x205f);
    }

    function test_whitespace_u3000() public view {
        _whitespaceWord(0x3000);
    }

    /// The White_Space members already refused by another class keep it (one class per scalar), so a text still
    /// refuses them: U+0085 is a C1 control (22), U+2028 and U+2029 are invisible (23). A word refuses them (7).
    function test_whitespace_with_an_earlier_class() public view {
        assertEq(probe.refusedClass(0x85), TopicProfile.CLASS_C1);
        assertEq(probe.refusedClass(0x2028), TopicProfile.CLASS_INVISIBLE);
        assertEq(probe.refusedClass(0x2029), TopicProfile.CLASS_INVISIBLE);
        assertEq(_code(bytes.concat("a", _utf8(0x85), "b")), 7);
        assertEq(_code(bytes.concat("a", _utf8(0x2028), "b")), 7);
        assertEq(_code(bytes.concat("a", _utf8(0x2029), "b")), 7);
        assertEq(_text(bytes.concat("a", _utf8(0x85), "b")), 22);
        assertEq(_text(bytes.concat("a", _utf8(0x2028), "b")), 23);
        assertEq(_text(bytes.concat("a", _utf8(0x2029), "b")), 23);
    }

    /// ASCII White_Space (U+0009-000D, U+0020) is the byte rule's: code 3 in a word; a text admits only U+0020.
    function test_ascii_whitespace() public view {
        uint8[6] memory ws = [0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x20];
        for (uint256 i; i < ws.length; ++i) {
            bytes memory w = abi.encodePacked("a", bytes1(ws[i]), "b");
            assertEq(_code(w), 3, "word");
            assertEq(_text(w), ws[i] == 0x20 ? 0 : 22, "text");
        }
    }

    /// Every Unicode 15.1 `White_Space` code point is refused in a word (PropList.txt, 25 code points).
    function test_every_white_space_is_refused_in_a_word() public view {
        uint24[25] memory ws = [
            uint24(0x09),
            0x0a,
            0x0b,
            0x0c,
            0x0d,
            0x20,
            0x85,
            0xa0,
            0x1680,
            0x2000,
            0x2001,
            0x2002,
            0x2003,
            0x2004,
            0x2005,
            0x2006,
            0x2007,
            0x2008,
            0x2009,
            0x200a,
            0x2028,
            0x2029,
            0x202f,
            0x205f,
            0x3000
        ];
        for (uint256 i; i < ws.length; ++i) {
            uint256 code = _code(bytes.concat("a", _utf8(ws[i]), "b"));
            assertEq(code, ws[i] < 0x80 ? 3 : 7);
        }
    }

    // ---- noncharacters in a text ----------------------------------------------------------------------------

    /// Class 5 (noncharacters, U+FFFC, U+FFFD) is refused in a text with code 23, as bidi and invisible are.
    function test_text_refuses_noncharacters() public view {
        uint24[10] memory nc = [
            uint24(0xfdd0),
            0xfdef,
            0xfffc,
            0xfffd,
            0xfffe,
            0xffff,
            0x1fffe,
            0x1ffff,
            0x10fffe,
            0x10ffff
        ];
        for (uint256 i; i < nc.length; ++i) {
            assertEq(probe.refusedClass(nc[i]), TopicProfile.CLASS_NONCHARACTER);
            assertEq(_text(_utf8(nc[i])), 23);
            assertEq(_text(bytes.concat("label ", _utf8(nc[i]))), 23);
        }
        assertEq(_text(_utf8(0xfdcf)), 0, "the scalar before U+FDD0");
        assertEq(_text(_utf8(0xfdf0)), 0, "the scalar after U+FDEF");
        assertEq(_text(_utf8(0x10fffd)), 0, "U+10FFFD");
    }

    /// Every non-ASCII scalar `files-name/3` refuses, a word refuses too ("at least as strictly as names").
    function testFuzz_word_at_least_as_strict_as_names(uint24 raw) public view {
        uint256 s = uint256(raw) % 0x110000;
        vm.assume(s >= 0x80 && (s < 0xd800 || s > 0xdfff));
        bytes memory u = _utf8(s);
        if (!probe.nameValid(bytes.concat("a", u, "a"))) {
            assertEq(_code(bytes.concat("a", u, "a")), 7);
        }
    }

    // ---- text -----------------------------------------------------------------------------------------------

    function test_text() public view {
        assertEq(_text("AC/DC"), 0);
        assertEq(_text("The quick brown fox."), 0);
        assertEq(_text(" "), 0);
        assertEq(_text(_repeat("x", 255)), 0);
        assertEq(_text(bytes.concat(_utf8(0x1f468), _utf8(0x200d), _utf8(0x1f469))), 0, "ZWJ");
        assertEq(_text(bytes.concat(_utf8(0x2764), _utf8(0xfe0f))), 0, "VS16");
        assertEq(_text(""), 20);
        assertEq(_text(_repeat("x", 256)), 20);
        assertEq(_text(hex"c0af"), 21);
        assertEq(_text(hex"eda080"), 21);
        assertEq(_text("a\nb"), 22);
        assertEq(_text(hex"7f"), 22);
        assertEq(_text(bytes.concat("a", _utf8(0x85))), 22);
        assertEq(_text(bytes.concat("a", _utf8(0x202e), "b")), 23);
        assertEq(_text(_utf8(0x200b)), 23);
        assertEq(_text(hex"0ac0"), 22, "the first refusal in scan order");
    }

    // ---- the rules, called directly ------------------------------------------------------------------------

    function _ctx(bytes32 typeId) internal view returns (AcceptContext memory c) {
        c.typeId = typeId;
        c.ledger = address(this);
    }

    function test_word_rule() public {
        assertEq(
            wordRule.accept(_ctx(WORD_TYPE), "tesla", new bytes32[](0), new RefHeader[](0)),
            IAcceptor.accept.selector
        );
        bytes[7] memory bad = [
            bytes(""),
            bytes(hex"c080"),
            bytes("Tesla"),
            bytes("inc."),
            bytes("~x"), // code 3 again: code 5 is unused
            bytes.concat("0x", _repeat("a", 40)),
            bytes.concat("a", _utf8(0x200d))
        ];
        // a word with a trailing no-break space, through the rule
        vm.expectRevert(abi.encodeWithSelector(E_TOPIC_REFUSED.selector, uint8(7)));
        wordRule.accept(
            _ctx(WORD_TYPE),
            bytes.concat("tesla", _utf8(0xa0)),
            new bytes32[](0),
            new RefHeader[](0)
        );
        uint8[7] memory codes = [1, 2, 3, 4, 3, 6, 7];
        for (uint256 i; i < 7; ++i) {
            vm.expectRevert(abi.encodeWithSelector(E_TOPIC_REFUSED.selector, codes[i]));
            wordRule.accept(_ctx(WORD_TYPE), bad[i], new bytes32[](0), new RefHeader[](0));
        }
        vm.expectRevert(abi.encodeWithSelector(E_TOPIC_REFUSED.selector, uint8(8)));
        wordRule.accept(_ctx(WORD_TYPE), "a", new bytes32[](1), new RefHeader[](1));
    }

    function test_text_rule() public {
        assertEq(
            textRule.accept(_ctx(TEXT_TYPE), "AC/DC", new bytes32[](0), new RefHeader[](0)),
            IAcceptor.accept.selector
        );
        bytes[4] memory bad =
            [bytes(""), bytes(hex"c080"), bytes("a\tb"), bytes.concat("a", _utf8(0x2066))];
        for (uint256 i; i < 4; ++i) {
            vm.expectRevert(abi.encodeWithSelector(E_TOPIC_REFUSED.selector, uint8(20 + i)));
            textRule.accept(_ctx(TEXT_TYPE), bad[i], new bytes32[](0), new RefHeader[](0));
        }
        // spaces a label may hold, and what it may not
        assertEq(
            textRule.accept(
                _ctx(TEXT_TYPE),
                bytes.concat("Tesla", _utf8(0xa0), "Inc."),
                new bytes32[](0),
                new RefHeader[](0)
            ),
            IAcceptor.accept.selector
        );
        vm.expectRevert(abi.encodeWithSelector(E_TOPIC_REFUSED.selector, uint8(23)));
        textRule.accept(
            _ctx(TEXT_TYPE),
            bytes.concat("a", _utf8(0x2028), "b"),
            new bytes32[](0),
            new RefHeader[](0)
        );
        vm.expectRevert(abi.encodeWithSelector(E_TOPIC_REFUSED.selector, uint8(23)));
        textRule.accept(_ctx(TEXT_TYPE), _utf8(0xfffd), new bytes32[](0), new RefHeader[](0));
        vm.expectRevert(abi.encodeWithSelector(E_TOPIC_REFUSED.selector, uint8(24)));
        textRule.accept(_ctx(TEXT_TYPE), "a", new bytes32[](1), new RefHeader[](1));
    }

    function test_rules_require_the_ledger() public {
        AcceptContext memory c = _ctx(WORD_TYPE);
        c.ledger = address(0xBEEF);
        bytes memory err =
            abi.encodeWithSelector(E_FILES_CONTEXT.selector, address(0xBEEF), address(this));
        vm.expectRevert(err);
        wordRule.accept(c, "a", new bytes32[](0), new RefHeader[](0));
        vm.expectRevert(err);
        textRule.accept(c, "a", new bytes32[](0), new RefHeader[](0));
        vm.expectRevert(err);
        topicRule.accept(c, new bytes(64), new bytes32[](2), new RefHeader[](2));
    }

    function _topicCall(bytes32 parentType, bytes32 wordType, uint256 len)
        internal
        view
        returns (bytes4)
    {
        bytes32[] memory refs = new bytes32[](2);
        refs[0] = keccak256("parent");
        refs[1] = keccak256("word");
        RefHeader[] memory h = new RefHeader[](2);
        h[0].typeId = parentType;
        h[1].typeId = wordType;
        return topicRule.accept(_ctx(TOPIC_TYPE), new bytes(len), refs, h);
    }

    function topicCallExternal(bytes32 parentType, bytes32 wordType, uint256 len)
        external
        view
        returns (bytes4)
    {
        return _topicCall(parentType, wordType, len);
    }

    function test_topic_rule() public {
        assertEq(_topicCall(WORD_TYPE, WORD_TYPE, 64), IAcceptor.accept.selector, "parent a page");
        assertEq(_topicCall(TOPIC_TYPE, WORD_TYPE, 64), IAcceptor.accept.selector, "parent a topic");
        assertEq(topicRule.wordTypeId(), WORD_TYPE);
        vm.expectRevert(abi.encodeWithSelector(E_TOPIC_REFUSED.selector, uint8(11)));
        this.topicCallExternal(WORD_TYPE, WORD_TYPE, 96);
        vm.expectRevert(abi.encodeWithSelector(E_TOPIC_REFUSED.selector, uint8(11)));
        this.topicCallExternal(WORD_TYPE, WORD_TYPE, 63);
        vm.expectRevert(abi.encodeWithSelector(E_TOPIC_REFUSED.selector, uint8(12)));
        this.topicCallExternal(keccak256("a directory type"), WORD_TYPE, 64);
        vm.expectRevert(abi.encodeWithSelector(E_TOPIC_REFUSED.selector, uint8(13)));
        this.topicCallExternal(WORD_TYPE, TOPIC_TYPE, 64);
        vm.expectRevert(abi.encodeWithSelector(E_TOPIC_REFUSED.selector, uint8(10)));
        topicRule.accept(_ctx(TOPIC_TYPE), new bytes(64), new bytes32[](1), new RefHeader[](1));
    }

    function test_rules_are_plain_runtimes() public {
        assertEq(CodeScan.scan(address(wordRule).code), 0);
        assertEq(CodeScan.scan(address(topicRule).code), 0);
        assertEq(CodeScan.scan(address(textRule).code), 0);
        emit log_named_uint("TopicWordRule runtime bytes", address(wordRule).code.length);
        emit log_named_uint("TopicRule runtime bytes", address(topicRule).code.length);
        emit log_named_uint("TextRule runtime bytes", address(textRule).code.length);
    }

    /// The word rule's cost per byte (direct call, warm): ASCII, Latin-1, CJK and emoji words of 12 and 240 bytes.
    function test_word_rule_gas_per_byte() public {
        bytes[4] memory units =
            [bytes("a"), bytes(hex"c3a9"), bytes(hex"e69db1"), bytes(hex"f09f9a97")];
        string[4] memory names = ["ascii", "latin-1", "cjk", "emoji"];
        for (uint256 i; i < 4; ++i) {
            bytes memory w12 = _repeat(units[i], 12 / units[i].length);
            bytes memory w240 = _repeat(units[i], 240 / units[i].length);
            uint256 g0 = gasleft();
            probe.wordRefusal(w12);
            uint256 g12 = g0 - gasleft();
            g0 = gasleft();
            probe.wordRefusal(w240);
            uint256 g240 = g0 - gasleft();
            emit log_named_uint(string.concat("word rule ", names[i], " 12 B gas"), g12);
            emit log_named_uint(string.concat("word rule ", names[i], " 240 B gas"), g240);
            emit log_named_uint(
                string.concat("word rule ", names[i], " gas per byte"), (g240 - g12) / 228
            );
        }
    }
}
