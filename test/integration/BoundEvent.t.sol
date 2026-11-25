// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {FilesRecipesBase} from "./FilesRecipesBase.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {Action, ActionKind, Purpose} from "../../src/interfaces/Actions.sol";
import {ILedger} from "../../src/interfaces/ILedger.sol";

/// @notice SPIKE (tags/topics, Part E): every bind-kind admission emits `Bound` after its `Admitted`, carrying the
///         purpose, subject, role, target, kind, strength, transition kind and target kind, so an indexer follows
///         tags from logs alone. PUBLISH/REUSE/CREATE/WITHDRAW emit no `Bound`.
contract BoundEventTest is FilesRecipesBase {
    bytes32 internal topic;
    bytes32 internal thing;

    function setUp() public override {
        super.setUp();
        (Action memory w, bytes memory wb) = _wordPage("events");
        Action[] memory a = new Action[](2);
        bytes[] memory b = new bytes[](2);
        (a[0], b[0]) = (w, wb);
        a[1] = _create(keccak256("thing"));
        _execAs(address(this), a, b);
        topic = _wordId("events");
        thing = Keys.subject(p, keccak256("thing"));
    }

    function _one(Action memory x) internal pure returns (Action[] memory a) {
        a = new Action[](1);
        a[0] = x;
    }

    function _next() internal view returns (uint64 admission) {
        (admission,,,) = r.hot.counts();
        ++admission;
    }

    function test_assert_mask_release_and_a_lone_negative() public {
        Action memory a = _bind(Purpose.TAG, topic, thing, thing, 0);
        a.salt = bytes32(uint256(75));
        vm.expectEmit(true, true, true, true, address(r.ledger));
        emit ILedger.Bound(_next(), Purpose.TAG, topic, thing, thing, ActionKind.BIND, 75, 1, 2);
        _execAs(address(this), _one(a), new bytes[](1));

        a = _bindKind(ActionKind.UNBIND, Purpose.TAG, topic, thing, 0, 1);
        a.salt = bytes32(uint256(4));
        vm.expectEmit(true, true, true, true, address(r.ledger));
        emit ILedger.Bound(_next(), Purpose.TAG, topic, thing, 0, ActionKind.UNBIND, 4, 3, 0);
        _execAs(address(this), _one(a), new bytes[](1));

        a = _bindKind(ActionKind.RELEASE, Purpose.TAG, topic, thing, 0, 2);
        vm.expectEmit(true, true, true, true, address(r.ledger));
        emit ILedger.Bound(_next(), Purpose.TAG, topic, thing, 0, ActionKind.RELEASE, 0, 4, 0);
        _execAs(address(this), _one(a), new bytes[](1));

        bytes32 addr = bytes32(uint256(uint160(makeAddr("events/addr"))));
        a = _bindKind(ActionKind.UNBIND, Purpose.TAG, topic, addr, 0, 0);
        a.salt = bytes32(uint256(65_535));
        vm.expectEmit(true, true, true, true, address(r.ledger));
        emit ILedger.Bound(_next(), Purpose.TAG, topic, addr, 0, ActionKind.UNBIND, 65_535, 6, 0);
        _execAs(address(this), _one(a), new bytes[](1));

        Action[] memory two = new Action[](1);
        two[0] = _bind(Purpose.TAG, topic, keccak256("other-role"), addr, 0);
        vm.expectEmit(true, true, true, true, address(r.ledger));
        emit ILedger.Bound(
            _next(), Purpose.TAG, topic, keccak256("other-role"), addr, ActionKind.BIND, 0, 1, 3
        );
        _execAs(address(this), two, new bytes[](1));
    }

    /// Exactly one `Bound` per bind-kind admission and none for record or subject kinds; its log is 3 topics +
    /// 192 data bytes.
    function test_one_bound_per_bind_admission() public {
        Action[] memory a = new Action[](3);
        bytes[] memory b = new bytes[](3);
        (a[0], b[0]) = _wordPage("more");
        a[1] = _create(keccak256("thing2"));
        a[2] = _bind(Purpose.TAG, _wordId("more"), thing, thing, 0);
        vm.recordLogs();
        _execAs(address(this), a, b);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 bound;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == ILedger.Bound.selector) {
                ++bound;
                assertEq(logs[i].topics.length, 4);
                assertEq(logs[i].data.length, 192);
            }
        }
        assertEq(bound, 1);
    }
}
