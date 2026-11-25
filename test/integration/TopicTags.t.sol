// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FilesRecipesBase} from "./FilesRecipesBase.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {Action, ActionKind, Purpose} from "../../src/interfaces/Actions.sol";
import {E_INDEX_CALL} from "../../src/interfaces/Errors.sol";
import {E_FILES_FINAL} from "../../src/profiles/FilesProfile.sol";

/// @notice SPIKE (tags/topics, Part B): a first tag (FIRST_BIND or FIRST_MASK on purpose TAG) stands on a registered
///         topic (`topic/1` or `topic-word/1`) or on a home (an address-shaped subject); anything else is refused by
///         `FilesFinalValidator` with `E_FILES_FINAL(7, leaf)`, nested in `E_INDEX_CALL`.
contract TopicTagsTest is FilesRecipesBase {
    bytes32 internal thing;

    function setUp() public override {
        super.setUp();
        Action[] memory a = new Action[](1);
        a[0] = _create(keccak256("thing"));
        thing = Keys.subject(p, a[0].salt);
        _execAs(address(this), a, new bytes[](1));
    }

    function execExternal(Action[] calldata a, bytes[] calldata b) external {
        require(msg.sender == address(this));
        _execAs(address(this), a, b);
    }

    function _refused(Action[] memory a, bytes[] memory b, uint8 leaf) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                E_INDEX_CALL.selector,
                abi.encodeWithSelector(E_FILES_FINAL.selector, uint8(7), leaf)
            )
        );
        this.execExternal(a, b);
    }

    function _tag(bytes32 topic) internal view returns (Action memory) {
        return _bind(Purpose.TAG, topic, thing, thing, 0);
    }

    function _deny(bytes32 topic) internal view returns (Action memory) {
        return _bindKind(ActionKind.UNBIND, Purpose.TAG, topic, thing, 0, 0);
    }

    function _one(Action memory x) internal pure returns (Action[] memory a) {
        a = new Action[](1);
        a[0] = x;
    }

    function test_unregistered_topic_refused_first_assert() public {
        bytes32 topic = _wordId("never-registered");
        _refused(_one(_tag(topic)), new bytes[](1), 0);
        // an arbitrary concept word (the pre-topic shape) is refused the same way
        _refused(_one(_tag(keccak256("concept"))), new bytes[](1), 0);
    }

    function test_unregistered_topic_refused_first_lone_negative() public {
        _refused(_one(_deny(_wordId("never-registered"))), new bytes[](1), 0);
    }

    function test_refusal_names_the_leaf() public {
        (Action memory w, bytes memory wb) = _wordPage("cars");
        Action[] memory a = new Action[](3);
        bytes[] memory b = new bytes[](3);
        (a[0], b[0]) = (w, wb);
        a[1] = _tag(_wordId("cars"));
        a[2] = _bindKind(ActionKind.UNBIND, Purpose.TAG, _wordId("boats"), thing, 0, 0);
        _refused(a, b, 2);
    }

    /// The registration and the tag in one publication: page, `/cars/tesla`, then the first tag on it.
    function test_registered_in_the_same_publication_before_the_tag() public {
        bytes[] memory w = new bytes[](2);
        w[0] = "cars";
        w[1] = "tesla";
        (Action[] memory reg, bytes[] memory rb, bytes32 topic) = _pathActions(w, true);
        Action[] memory a = new Action[](reg.length + 2);
        bytes[] memory b = new bytes[](reg.length + 2);
        for (uint256 i; i < reg.length; ++i) {
            (a[i], b[i]) = (reg[i], rb[i]);
        }
        a[reg.length] = _tag(topic);
        a[reg.length + 1] = _deny(_wordId("cars")); // a lone negative on the one-word topic /cars
        _execAs(address(this), a, b);
        (uint8 st,,) = _head(_key(Purpose.TAG, topic, thing));
        assertEq(st, 1);
        (st,,) = _head(_key(Purpose.TAG, _wordId("cars"), thing));
        assertEq(st, 2);
    }

    /// The topic must be first admitted strictly before the tag's own admission: the index walks the topic's
    /// ancestors at the tag's admission, so a tag ahead of its registration in one publication would get no roll-up
    /// entries for good. It is refused (code 7, the tag's leaf); registrations come first.
    function test_registered_later_in_the_same_publication_is_refused() public {
        (Action memory w, bytes memory wb) = _wordPage("later");
        Action[] memory a = new Action[](2);
        bytes[] memory b = new bytes[](2);
        a[0] = _tag(_wordId("later"));
        (a[1], b[1]) = (w, wb);
        _refused(a, b, 0);
        // a lone negative ahead of its registration, the same
        a[0] = _deny(_wordId("later"));
        _refused(a, b, 0);
        // a two-word path: the page and the path record first, then the tag, is admitted (see above); the path
        // record AFTER the tag is refused even though its parent page came first
        bytes[] memory words = new bytes[](2);
        words[0] = "early";
        words[1] = "late";
        (Action[] memory reg, bytes[] memory rb, bytes32 topic) = _pathActions(words, true);
        a = new Action[](4);
        b = new bytes[](4);
        (a[0], b[0]) = (reg[0], rb[0]);
        (a[1], b[1]) = (reg[1], rb[1]);
        a[2] = _tag(topic);
        (a[3], b[3]) = (reg[2], rb[2]);
        _refused(a, b, 2);
    }

    function test_a_home_subject_is_admitted() public {
        bytes32 home = bytes32(uint256(uint160(makeAddr("topic-tags/home"))));
        Action[] memory a = new Action[](2);
        a[0] = _bind(Purpose.TAG, home, thing, thing, 0);
        a[1] = _bindKind(ActionKind.UNBIND, Purpose.TAG, home, keccak256("other"), 0, 0);
        _execAs(address(this), a, new bytes[](2));
        (uint8 st,,) = _head(_key(Purpose.TAG, home, thing));
        assertEq(st, 1);
    }

    /// Later transitions on an existing binding are never refused: the validator judges only the first one
    /// (mask, re-assert and release below are not looked at again).
    function test_later_transitions_are_not_judged() public {
        (Action memory w, bytes memory wb) = _wordPage("cars");
        Action[] memory a = new Action[](2);
        bytes[] memory b = new bytes[](2);
        (a[0], b[0]) = (w, wb);
        bytes32 topic = _wordId("cars");
        a[1] = _tag(topic);
        _execAs(address(this), a, b);
        _execAs(
            address(this),
            _one(_bindKind(ActionKind.UNBIND, Purpose.TAG, topic, thing, 0, 1)),
            new bytes[](1)
        );
        _execAs(address(this), _one(_bind(Purpose.TAG, topic, thing, thing, 2)), new bytes[](1));
        _execAs(
            address(this),
            _one(_bindKind(ActionKind.RELEASE, Purpose.TAG, topic, thing, 0, 3)),
            new bytes[](1)
        );
        (uint8 st, uint64 rev,) = _head(_key(Purpose.TAG, topic, thing));
        assertEq(st, 3);
        assertEq(rev, 4);
    }
}
