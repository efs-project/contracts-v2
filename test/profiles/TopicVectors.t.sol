// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {Action, Purpose} from "../../src/interfaces/Actions.sol";
import {AcceptContext, IAcceptor, RefHeader} from "../../src/interfaces/IAcceptor.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {EfsTopics} from "../../src/lib/EfsTopics.sol";
import {E_TOPIC_REFUSED} from "../../src/profiles/TopicProfile.sol";
import {TopicWordRule} from "../../src/profiles/TopicWordRule.sol";
import {TextRule} from "../../src/profiles/TextRule.sol";
import {Genesis} from "../../script/Genesis.s.sol";
import {TopicProbe} from "./TopicRules.t.sol";

/// @notice `test/vectors/topics.json` (`tools/topic-vectors.mjs`, computed in JS from the NatSpec) against the
///         contracts: every word and text verdict against `TopicProfile` and the two rules, the refused table byte for
///         byte, every path id and record on the way against `EfsTopics` and `Keys`, the property keys, the purposes
///         and every builder's encoding; and the release Type ids against `Genesis.profile`.
contract TopicVectorsTest is Test {
    string internal json;
    TopicProbe internal probe;
    TopicWordRule internal wordRule;
    TextRule internal textRule;
    EfsTopics.Types internal tt;

    function setUp() public {
        json = vm.readFile("test/vectors/topics.json");
        probe = new TopicProbe();
        wordRule = new TopicWordRule();
        textRule = new TextRule();
        tt.word = vm.parseJsonBytes32(json, '.typeIds["topic-word/1"]');
        tt.topic = vm.parseJsonBytes32(json, '.typeIds["topic/1"]');
        tt.text = vm.parseJsonBytes32(json, '.typeIds["text/1"]');
    }

    function _at(string memory list, uint256 i, string memory field)
        internal
        pure
        returns (string memory)
    {
        return string.concat(".", list, "[", vm.toString(i), "]", field);
    }

    function _has(string memory list, uint256 i) internal view returns (bool) {
        return vm.keyExistsJson(json, _at(list, i, ""));
    }

    function _ctx(bytes32 typeId) internal view returns (AcceptContext memory c) {
        c.typeId = typeId;
        c.ledger = address(this);
    }

    function wordRuleCall(bytes calldata w) external view returns (bytes4) {
        return wordRule.accept(_ctx(tt.word), w, new bytes32[](0), new RefHeader[](0));
    }

    function textRuleCall(bytes calldata x) external view returns (bytes4) {
        return textRule.accept(_ctx(tt.text), x, new bytes32[](0), new RefHeader[](0));
    }

    function test_words() public {
        // one parse per field: the file is large, and a parse per row costs its whole length in memory
        bytes[] memory words = vm.parseJsonBytesArray(json, ".flat.words.hex");
        uint256[] memory codes = vm.parseJsonUintArray(json, ".flat.words.code");
        bytes32[] memory pages = vm.parseJsonBytes32Array(json, ".flat.words.pageId");
        assertEq(codes.length, words.length);
        uint256 k;
        for (uint256 i; i < words.length; ++i) {
            bytes memory w = words[i];
            uint256 code = codes[i];
            assertEq(probe.wordRefusal(w), code, vm.toString(i));
            if (code == 0) {
                assertEq(this.wordRuleCall(w), IAcceptor.accept.selector);
                assertEq(pages[k++], Keys.record(tt.word, w));
                assertEq(EfsTopics.wordPageId(tt.word, w), Keys.record(tt.word, w));
            } else {
                vm.expectRevert(abi.encodeWithSelector(E_TOPIC_REFUSED.selector, uint8(code)));
                this.wordRuleCall(w);
            }
        }
        assertEq(k, pages.length, "a page id for every admitted word");
        assertGt(words.length, 100);
    }

    function test_texts() public {
        bytes[] memory texts = vm.parseJsonBytesArray(json, ".flat.texts.hex");
        uint256[] memory codes = vm.parseJsonUintArray(json, ".flat.texts.code");
        bytes32[] memory records = vm.parseJsonBytes32Array(json, ".flat.texts.recordId");
        uint256 k;
        for (uint256 i; i < texts.length; ++i) {
            bytes memory x = texts[i];
            uint256 code = codes[i];
            assertEq(probe.textRefusal(x), code, vm.toString(i));
            if (code == 0) {
                assertEq(this.textRuleCall(x), IAcceptor.accept.selector);
                assertEq(records[k++], Keys.record(tt.text, x));
            } else {
                vm.expectRevert(abi.encodeWithSelector(E_TOPIC_REFUSED.selector, uint8(code)));
                this.textRuleCall(x);
            }
        }
        assertEq(k, records.length);
        assertGt(texts.length, 20);
    }

    function test_the_refused_table_is_the_contracts() public view {
        assertEq(vm.parseJsonBytes(json, ".refused.packed"), probe.refusedTable());
        for (uint256 i; _has("refused.entries", i); ++i) {
            uint256 lo = vm.parseJsonUint(json, _at("refused.entries", i, ".lo"));
            uint256 hi = vm.parseJsonUint(json, _at("refused.entries", i, ".hi"));
            uint256 cls = vm.parseJsonUint(json, _at("refused.entries", i, ".class"));
            assertEq(probe.refusedClass(lo), cls);
            assertEq(probe.refusedClass(hi), cls);
        }
    }

    function test_paths() public view {
        for (uint256 i; _has("paths", i); ++i) {
            string[] memory ws = vm.parseJsonStringArray(json, _at("paths", i, ".words"));
            bytes[] memory words = new bytes[](ws.length);
            for (uint256 k; k < ws.length; ++k) {
                words[k] = bytes(ws[k]);
                assertEq(
                    vm.parseJsonBytes32(
                        json, _at("paths", i, string.concat(".pageIds[", vm.toString(k), "]"))
                    ),
                    Keys.record(tt.word, words[k])
                );
            }
            bytes32 id = EfsTopics.pathId(tt, words);
            assertEq(vm.parseJsonBytes32(json, _at("paths", i, ".id")), id);
            // every record on the way, and the registration builder reaches the same id
            (Action[] memory a, bytes[] memory b, bytes32 got) = EfsTopics.registerPath(tt, words);
            assertEq(got, id);
            assertEq(a.length, 2 * words.length - 1);
            for (uint256 k = 1; k < words.length; ++k) {
                string memory rec = string.concat(".records[", vm.toString(k), "]");
                bytes memory body =
                    vm.parseJsonBytes(json, _at("paths", i, string.concat(rec, ".body")));
                assertEq(b[words.length - 1 + k], body);
                assertEq(
                    vm.parseJsonBytes32(json, _at("paths", i, string.concat(rec, ".id"))),
                    Keys.record(tt.topic, body)
                );
            }
        }
    }

    /// A label's language tag is lowercased before its key is derived (`EfsTopics.labelKey`): every vector's key is
    /// its canonical tag's, and `pt-BR` / `EN` are the keys of `pt-br` / `en`.
    function test_label_keys_fold_the_language_tag() public view {
        uint256 n;
        for (uint256 i; _has("labelKeys", i); ++i) {
            bytes memory language =
                bytes(vm.parseJsonString(json, _at("labelKeys", i, ".language")));
            bytes memory canonical =
                bytes(vm.parseJsonString(json, _at("labelKeys", i, ".canonical")));
            bytes32 id = vm.parseJsonBytes32(json, _at("labelKeys", i, ".id"));
            assertEq(EfsTopics.labelKey(language), id);
            assertEq(EfsTopics.labelKey(canonical), id);
            assertEq(EfsTopics.propertyKey(bytes.concat("label:", canonical)), id);
            ++n;
        }
        assertGe(n, 6);
        assertEq(EfsTopics.labelKey("pt-BR"), EfsTopics.labelKey("pt-br"));
        assertEq(EfsTopics.labelKey("EN"), EfsTopics.labelKey("en"));
        assertTrue(EfsTopics.propertyKey("label:EN") != EfsTopics.labelKey("EN"));
        // the caller's bytes are not modified
        bytes memory tagBytes = "pt-BR";
        EfsTopics.labelKey(tagBytes);
        assertEq(tagBytes, bytes("pt-BR"));
    }

    function test_property_keys_and_purposes() public view {
        for (uint256 i; _has("propertyKeys", i); ++i) {
            string memory key = vm.parseJsonString(json, _at("propertyKeys", i, ".key"));
            assertEq(
                vm.parseJsonBytes32(json, _at("propertyKeys", i, ".id")),
                EfsTopics.propertyKey(bytes(key))
            );
        }
        assertEq(EfsTopics.labelKey("en"), EfsTopics.propertyKey("label:en"));
        assertEq(vm.parseJsonBytes32(json, ".purposes.TAG"), Purpose.TAG);
        assertEq(vm.parseJsonBytes32(json, ".purposes.PROPERTY"), Purpose.PROPERTY);
        assertEq(vm.parseJsonBytes32(json, ".purposes.SAME"), Purpose.SAME);
        assertEq(vm.parseJsonBytes32(json, ".purposes.BROADER"), Purpose.BROADER);
    }

    function _check(uint256 i, Action[] memory a, bytes[] memory b) internal view {
        assertEq(
            vm.parseJsonBytes32(json, _at("builders", i, ".actionsHash")),
            keccak256(abi.encode(a)),
            vm.parseJsonString(json, _at("builders", i, ".label"))
        );
        assertEq(
            vm.parseJsonBytes32(json, _at("builders", i, ".bodiesHash")), keccak256(abi.encode(b))
        );
    }

    function _single(Action memory x) internal pure returns (Action[] memory a, bytes[] memory b) {
        a = new Action[](1);
        b = new bytes[](1);
        a[0] = x;
    }

    function test_builders() public view {
        bytes32 thing = vm.parseJsonBytes32(json, ".inputs.thing");
        bytes32 home = vm.parseJsonBytes32(json, ".inputs.home");
        bytes[] memory w = new bytes[](1);
        w[0] = "cars";
        bytes32 cars = EfsTopics.pathId(tt, w);
        w = new bytes[](2);
        (w[0], w[1]) = (bytes("cars"), bytes("tesla"));
        bytes32 tesla = EfsTopics.pathId(tt, w);
        Action[] memory a;
        bytes[] memory b;
        (a, b,) = EfsTopics.registerWord(tt, "tesla");
        _check(0, a, b);
        w = new bytes[](3);
        (w[0], w[1], w[2]) = (bytes("cars"), bytes("tesla"), bytes("model_y"));
        bytes32 id;
        (a, b, id) = EfsTopics.registerPath(tt, w);
        _check(1, a, b);
        assertEq(vm.parseJsonBytes32(json, ".builders[1].id"), id);
        (a, b, id) = EfsTopics.registerChild(tt, tesla, "model_3", true);
        _check(2, a, b);
        assertEq(vm.parseJsonBytes32(json, ".builders[2].id"), id);
        (a, b, id) = EfsTopics.registerChild(tt, cars, "tesla", false);
        _check(3, a, b);
        assertEq(id, tesla);
        (a, b) = _single(EfsTopics.tag(tesla, thing, 0, 75));
        _check(4, a, b);
        (a, b) = _single(EfsTopics.tag(home, thing, 0, 0));
        _check(5, a, b);
        (a, b) = _single(EfsTopics.deny(cars, thing, 0, 0));
        _check(6, a, b);
        (a, b) = _single(EfsTopics.deny(cars, thing, 1, 4));
        _check(7, a, b);
        (a, b) = _single(EfsTopics.property(cars, EfsTopics.propertyKey("moved-to"), home, 0));
        _check(8, a, b);
        bytes32 text;
        (a, b, text) = EfsTopics.label(tt, tesla, "en", "Tesla, Inc.", 0);
        _check(9, a, b);
        assertEq(vm.parseJsonBytes32(json, ".builders[9].textRecord"), text);
        (a, b) = _single(EfsTopics.same(tesla, EfsTopics.wordPageId(tt.word, "tesla"), 0));
        _check(10, a, b);
        (a, b) = _single(EfsTopics.broader(tesla, cars, 0));
        _check(11, a, b);
        assertFalse(_has("builders", 12), "every builder vector is checked");
    }

    /// The vectors name the release's Type ids (the fixture declaration key), from `Genesis.profile`.
    function test_vectors_name_the_release_type_ids() public {
        if (
            keccak256(bytes(vm.envOr("FOUNDRY_PROFILE", string("default"))))
                == keccak256("amsterdam")
        ) {
            return;
        }
        address key = vm.parseJsonAddress(json, ".declarationKey");
        (,,, bytes32[13] memory typeIds,,,) = new Genesis().profile(key);
        assertEq(typeIds[10], tt.word);
        assertEq(typeIds[11], tt.topic);
        assertEq(typeIds[12], tt.text);
    }
}
