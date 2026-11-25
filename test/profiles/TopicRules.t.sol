// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {AcceptContext, IAcceptor, RefHeader} from "../../src/interfaces/IAcceptor.sol";
import {E_FILES_CONTEXT} from "../../src/profiles/FilesProfile.sol";
import {TopicWord, E_TOPIC_REFUSED} from "../../src/profiles/TopicProfile.sol";
import {TopicWordRule} from "../../src/profiles/TopicWordRule.sol";
import {TopicRule} from "../../src/profiles/TopicRule.sol";

/// The grammar library over calldata, so the tests (and a vector generator) can call it directly.
contract TopicWordProbe {
    function refusal(bytes calldata w) external pure returns (uint256) {
        return TopicWord.refusal(w);
    }

    function utf8Refusal(bytes calldata w) external pure returns (uint256) {
        return TopicWord.utf8Refusal(w);
    }

    function asciiClassRefusal(bytes calldata w) external pure returns (uint256) {
        return TopicWord.asciiClassRefusal(w);
    }
}

/// @notice SPIKE (tags/topics): `TopicWord.refusal` (every code, boundaries) and the two rules called directly with
///         this contract as the ledger.
contract TopicRulesTest is Test {
    bytes32 internal constant WORD_TYPE = keccak256("test/topic-word");
    bytes32 internal constant TOPIC_TYPE = keccak256("test/topic");

    TopicWordProbe internal probe;
    TopicWordRule internal wordRule;
    TopicRule internal topicRule;

    function setUp() public {
        probe = new TopicWordProbe();
        wordRule = new TopicWordRule();
        topicRule = new TopicRule(WORD_TYPE);
    }

    function _code(bytes memory w) internal view returns (uint256) {
        return probe.refusal(w);
    }

    function _repeat(bytes memory unit, uint256 n) internal pure returns (bytes memory out) {
        for (uint256 i; i < n; ++i) {
            out = bytes.concat(out, unit);
        }
    }

    // ---- 1: length ---------------------------------------------------------------------------------------

    function test_length() public view {
        assertEq(_code(""), 1);
        assertEq(_code("a"), 0);
        assertEq(_code(_repeat("a", 255)), 0);
        assertEq(_code(_repeat("a", 256)), 1);
        assertEq(_code(bytes.concat(_repeat(hex"e69db1", 85))), 0); // 255 bytes of CJK
        assertEq(_code(bytes.concat(_repeat(hex"e69db1", 85), "a")), 1);
    }

    // ---- 2: UTF-8 ------------------------------------------------------------------------------------------

    function test_utf8_well_formed() public view {
        assertEq(_code(bytes("caf\xc3\xa9")), 0); // café
        assertEq(_code(hex"e69db1e4baac"), 0); // 東京
        assertEq(_code(hex"f09f9a97"), 0); // U+1F697
        assertEq(_code(hex"f48fbfbf"), 0); // U+10FFFF
        assertEq(_code(hex"c280"), 0); // U+0080 (a C1 control: not refused by this grammar)
    }

    function test_utf8_malformed() public view {
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

    // ---- 3: forbidden ASCII ----------------------------------------------------------------------------------

    function test_forbidden_ascii() public view {
        assertEq(_code("a/b"), 3);
        assertEq(_code("/"), 3);
        assertEq(_code("a b"), 3);
        assertEq(_code(hex"00"), 3);
        assertEq(_code(hex"611f"), 3);
        assertEq(_code(hex"7f"), 3);
        assertEq(_code(hex"09"), 3);
        assertEq(_code("Tesla"), 3);
        assertEq(_code("teslA"), 3);
        assertEq(_code("Z"), 3);
        assertEq(_code("~A"), 3, "a byte refusal comes before the shape refusals");
        for (uint256 c = 0x21; c < 0x7f; ++c) {
            bool bad = c == 0x2f || (c >= 0x41 && c <= 0x5a);
            assertEq(_code(abi.encodePacked(bytes1(uint8(c)))) == 3, bad, "every printable byte");
        }
        assertEq(_code("e\xcc\x81\x2f"), 3, "a / after a multi-byte scalar");
    }

    // ---- 4, 5, 6: whole-word shapes --------------------------------------------------------------------------

    function test_dot_words() public view {
        assertEq(_code("."), 4);
        assertEq(_code(".."), 4);
        assertEq(_code("..."), 0);
        assertEq(_code(".a"), 0);
        assertEq(_code("a."), 0);
    }

    function test_tilde() public view {
        assertEq(_code("~"), 5);
        assertEq(_code("~efs"), 5);
        assertEq(_code("a~"), 0);
    }

    function test_address_shadow() public view {
        bytes memory hex40 = "00112233445566778899aabbccddeeff00112233";
        assertEq(_code(bytes.concat("0x", hex40)), 6);
        assertEq(_code(bytes.concat("0x", _repeat("f", 40))), 6);
        assertEq(_code(bytes.concat("0x", _repeat("f", 39))), 0, "39 hex");
        assertEq(_code(bytes.concat("0x", _repeat("f", 41))), 0, "41 hex");
        assertEq(_code(bytes.concat("0x", _repeat("f", 39), "g")), 0, "a non-hex character");
        assertEq(_code(bytes.concat("0y", hex40)), 0);
        assertEq(_code(bytes.concat("0X", hex40)), 3, "uppercase X is a byte refusal");
        assertEq(_code(bytes.concat("0x", _repeat("F", 40))), 3, "uppercase hex is a byte refusal");
        assertEq(_code("0x"), 0);
    }

    function test_halves() public view {
        assertEq(probe.utf8Refusal(hex"eda080"), 2);
        assertEq(probe.utf8Refusal("A/ b"), 0);
        assertEq(probe.asciiClassRefusal("A"), 3);
        assertEq(probe.asciiClassRefusal(hex"eda080"), 0);
    }

    /// Any word the full grammar admits is admitted by both halves (they are its two loops).
    function testFuzz_halves_agree(bytes calldata w) public view {
        vm.assume(w.length > 0 && w.length < 256);
        uint256 code = probe.refusal(w);
        if (code == 0) {
            assertEq(probe.utf8Refusal(w), 0);
            assertEq(probe.asciiClassRefusal(w), 0);
        }
        if (code == 2) assertEq(probe.utf8Refusal(w), 2);
    }

    // ---- the rules, called directly ------------------------------------------------------------------------

    function _ctx(bytes32 typeId) internal view returns (AcceptContext memory c) {
        c.typeId = typeId;
        c.ledger = address(this);
    }

    function test_word_rule() public view {
        assertEq(
            wordRule.accept(_ctx(WORD_TYPE), "tesla", new bytes32[](0), new RefHeader[](0)),
            IAcceptor.accept.selector
        );
    }

    function test_word_rule_codes() public {
        bytes[6] memory bad = [
            bytes(""),
            bytes(hex"c080"),
            bytes("Tesla"),
            bytes(".."),
            bytes("~x"),
            bytes.concat("0x", _repeat("a", 40))
        ];
        for (uint256 i; i < 6; ++i) {
            vm.expectRevert(abi.encodeWithSelector(E_TOPIC_REFUSED.selector, uint8(i + 1)));
            wordRule.accept(_ctx(WORD_TYPE), bad[i], new bytes32[](0), new RefHeader[](0));
        }
        vm.expectRevert(abi.encodeWithSelector(E_TOPIC_REFUSED.selector, uint8(7)));
        wordRule.accept(_ctx(WORD_TYPE), "a", new bytes32[](1), new RefHeader[](1));
    }

    function test_word_rule_context() public {
        AcceptContext memory c = _ctx(WORD_TYPE);
        c.ledger = address(0xBEEF);
        vm.expectRevert(
            abi.encodeWithSelector(E_FILES_CONTEXT.selector, address(0xBEEF), address(this))
        );
        wordRule.accept(c, "a", new bytes32[](0), new RefHeader[](0));
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
        bytes memory body = new bytes(len);
        return topicRule.accept(_ctx(TOPIC_TYPE), body, refs, h);
    }

    function test_topic_rule() public view {
        assertEq(
            _topicCall(WORD_TYPE, WORD_TYPE, 64), IAcceptor.accept.selector, "parent a word page"
        );
        assertEq(_topicCall(TOPIC_TYPE, WORD_TYPE, 64), IAcceptor.accept.selector, "parent a topic");
        assertEq(topicRule.wordTypeId(), WORD_TYPE);
    }

    function test_topic_rule_codes() public {
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

    function topicCallExternal(bytes32 parentType, bytes32 wordType, uint256 len)
        external
        view
        returns (bytes4)
    {
        return _topicCall(parentType, wordType, len);
    }
}
