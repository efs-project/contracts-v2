// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FilesRecipesBase} from "../integration/FilesRecipesBase.sol";
import {EfsFiles} from "../../src/lib/EfsFiles.sol";
import {EfsTopics} from "../../src/lib/EfsTopics.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {Action, Purpose} from "../../src/interfaces/Actions.sol";
import {History, Status} from "../../src/interfaces/Results.sol";
import {Head} from "../../src/interfaces/Views.sol";
import {LedgerViews} from "../../src/readers/LedgerViews.sol";

/// @notice What a planner reads to tell a yes after a lone no from a restore (gas/model.json `laterRows.rule`):
///         `Head.targetKind` is served as stored, so it is 0 exactly for a head that never bound, and `Head.target` is
///         canonical, 0 for every head that is not BOUND, so it cannot tell a lone no from a masked yes. Pinned through
///         `LedgerViews.headsAt` (the live head) and `LedgerViews.historyAt` (the live head, and the head as of every
///         earlier admission of the sequence) over five sequences of one author at one TAG position: a lone no; no,
///         release; no, no; yes, mask; yes, release. The first three never bound (targetKind 0), the last two did
///         (targetKind SUBJECT, the thing's kind); `target` is 0 at the end of all five.
contract HeadTargetKindTest is FilesRecipesBase {
    uint8 internal constant UNSET_KIND = 0;
    uint8 internal constant SUBJECT_KIND = 2; // FilesProfile.TARGET_SUBJECT: the thing is a created subject

    LedgerViews internal views;
    bytes32 internal topic;

    function setUp() public override {
        super.setUp();
        views = new LedgerViews();
        (Action[] memory a, bytes[] memory b, bytes32 id) =
            EfsTopics.registerWord(_topicTypes(), bytes("target-kind"));
        _execAs(address(this), a, b);
        topic = id;
    }

    /// A new file subject of p (the thing every sequence is about).
    function _thing(uint256 i) internal returns (bytes32 thing) {
        bytes32 salt = keccak256(abi.encode("head-target-kind", i));
        Action[] memory a = new Action[](1);
        a[0] = _create(salt);
        _execAs(address(this), a, new bytes[](1));
        thing = Keys.subject(p, salt);
    }

    /// One statement in a publication of its own; returns its admission (the head's after it).
    function _one(Action memory x) internal returns (uint64 admission) {
        Action[] memory a = new Action[](1);
        a[0] = x;
        _execAs(address(this), a, new bytes[](1));
        (,, admission,,,,,) =
            r.hot.head(Keys.binding(p, Keys.position(x.purpose, x.subject, x.role)));
    }

    /// The live head through `headsAt`, and through `historyAt` as of the last admission and every admission in `at`;
    /// every answer's `targetKind` is `kind` and its `target` 0 (the sequences end on a head that is not BOUND).
    function _check(bytes32 thing, uint8 state, uint8 kind, uint64[] memory at, string memory what)
        internal
        view
    {
        bytes32 position = Keys.position(Purpose.TAG, topic, thing);
        bytes32[] memory who = new bytes32[](1);
        who[0] = p;
        // `headsAt` selects the first author whose head is BOUND or MASKED; a RELEASED head falls through
        // (ABSENT_PROVEN) and is read from `all`
        (Status st,,, Head[] memory all,) = views.headsAt(address(r.ledger), who, position);
        assertEq(
            uint8(st),
            uint8(state == 2 ? Status.MASKED : Status.ABSENT_PROVEN),
            string.concat(what, ": status")
        );
        Head memory h = all[0];
        assertEq(h.state, state, string.concat(what, ": state"));
        assertEq(h.targetKind, kind, string.concat(what, ": headsAt targetKind"));
        assertEq(h.target, bytes32(0), string.concat(what, ": headsAt target is canonical zero"));
        bytes32 key = Keys.binding(p, position);
        for (uint256 i; i < at.length; ++i) {
            (History hs, Head memory x) = views.historyAt(address(r.ledger), key, at[i], 64);
            assertEq(uint8(hs), uint8(History.FOUND), string.concat(what, ": historyAt found"));
            if (x.state == 1) continue; // the yes of "yes, mask" and "yes, release": BOUND then, with its target
            assertEq(x.targetKind, kind, string.concat(what, ": historyAt targetKind"));
            assertEq(
                x.target, bytes32(0), string.concat(what, ": historyAt target is canonical zero")
            );
        }
    }

    function _at(uint64 a) internal pure returns (uint64[] memory x) {
        x = new uint64[](1);
        x[0] = a;
    }

    function _at(uint64 a, uint64 b) internal pure returns (uint64[] memory x) {
        x = new uint64[](2);
        (x[0], x[1]) = (a, b);
    }

    function test_a_lone_no_never_bound() public {
        bytes32 t = _thing(0);
        uint64 a0 = _one(EfsFiles.loneNegative(Purpose.TAG, topic, t, 0));
        _check(t, 2, UNSET_KIND, _at(a0), "a lone no");
    }

    function test_no_then_release_never_bound() public {
        bytes32 t = _thing(1);
        uint64 a0 = _one(EfsFiles.loneNegative(Purpose.TAG, topic, t, 0));
        uint64 a1 = _one(EfsFiles.release(Purpose.TAG, topic, t, 1));
        _check(t, 3, UNSET_KIND, _at(a0, a1), "no, release");
    }

    function test_no_then_no_never_bound() public {
        bytes32 t = _thing(2);
        uint64 a0 = _one(EfsFiles.loneNegative(Purpose.TAG, topic, t, 0));
        uint64 a1 = _one(EfsFiles.unbindWithStrength(Purpose.TAG, topic, t, 1, 3));
        _check(t, 2, UNSET_KIND, _at(a0, a1), "no, no");
    }

    function test_yes_then_mask_bound_once() public {
        bytes32 t = _thing(3);
        uint64 a0 = _one(EfsTopics.tag(topic, t, 0, 0));
        uint64 a1 = _one(EfsFiles.unbind(Purpose.TAG, topic, t, 1));
        _check(t, 2, SUBJECT_KIND, _at(a0, a1), "yes, mask");
    }

    function test_yes_then_release_bound_once() public {
        bytes32 t = _thing(4);
        uint64 a0 = _one(EfsTopics.tag(topic, t, 0, 0));
        uint64 a1 = _one(EfsFiles.release(Purpose.TAG, topic, t, 1));
        _check(t, 3, SUBJECT_KIND, _at(a0, a1), "yes, release");
    }
}
