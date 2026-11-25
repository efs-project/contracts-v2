// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {FilesRecipesBase} from "./FilesRecipesBase.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {EfsFiles} from "../../src/lib/EfsFiles.sol";
import {Action, ActionKind, Purpose} from "../../src/interfaces/Actions.sol";
import {ClosureConstants} from "../../src/interfaces/Limits.sol";
import {ILedger} from "../../src/interfaces/ILedger.sol";

/// @notice The two indexer events (design §5.5). Every bind-kind admission emits `Bound` right after its
///         `Admitted`, with the purpose, subject, role, target, kind, strength, transition kind and target kind;
///         record and subject kinds emit none. A PUBLISH that first admits a record of at most
///         `ClosureConstants.BODY_EVENT_MAX` bytes emits `Body` (record id, Type id, body); a repeat publish, a
///         REUSE and a larger body emit none. Topics are plain ids: no validator checks a TAG subject here.
contract BoundEventTest is FilesRecipesBase {
    bytes32 internal constant TOPIC = keccak256("bound-event/topic");
    bytes32 internal thing;

    function setUp() public override {
        super.setUp();
        Action[] memory a = new Action[](1);
        a[0] = _create(keccak256("thing"));
        _execAs(address(this), a, new bytes[](1));
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
        vm.expectEmit(true, true, true, true, address(r.ledger));
        emit ILedger.Bound(_next(), Purpose.TAG, TOPIC, thing, thing, ActionKind.BIND, 75, 1, 2);
        _execAs(
            address(this),
            _one(EfsFiles.bindWithStrength(Purpose.TAG, TOPIC, thing, thing, 0, 75)),
            new bytes[](1)
        );

        vm.expectEmit(true, true, true, true, address(r.ledger));
        emit ILedger.Bound(_next(), Purpose.TAG, TOPIC, thing, 0, ActionKind.UNBIND, 4, 3, 0);
        _execAs(
            address(this),
            _one(EfsFiles.unbindWithStrength(Purpose.TAG, TOPIC, thing, 1, 4)),
            new bytes[](1)
        );

        vm.expectEmit(true, true, true, true, address(r.ledger));
        emit ILedger.Bound(_next(), Purpose.TAG, TOPIC, thing, 0, ActionKind.RELEASE, 0, 4, 0);
        _execAs(address(this), _one(EfsFiles.release(Purpose.TAG, TOPIC, thing, 2)), new bytes[](1));

        bytes32 addr = bytes32(uint256(uint160(makeAddr("events/addr"))));
        vm.expectEmit(true, true, true, true, address(r.ledger));
        emit ILedger.Bound(_next(), Purpose.TAG, TOPIC, addr, 0, ActionKind.UNBIND, 65_535, 6, 0);
        _execAs(
            address(this),
            _one(EfsFiles.loneNegative(Purpose.TAG, TOPIC, addr, 65_535)),
            new bytes[](1)
        );

        vm.expectEmit(true, true, true, true, address(r.ledger));
        emit ILedger.Bound(
            _next(), Purpose.TAG, TOPIC, keccak256("other-role"), addr, ActionKind.BIND, 0, 1, 3
        );
        _execAs(
            address(this),
            _one(_bind(Purpose.TAG, TOPIC, keccak256("other-role"), addr, 0)),
            new bytes[](1)
        );
    }

    /// Exactly one `Bound` per bind-kind admission and none for record or subject kinds; its log is 3 indexed
    /// topics + 192 data bytes, and it follows the `Admitted` of the same admission.
    function test_one_bound_per_bind_admission() public {
        Action[] memory a = new Action[](3);
        bytes[] memory b = new bytes[](3);
        (a[0], b[0]) = _name("more");
        a[1] = _create(keccak256("thing2"));
        a[2] = _bind(Purpose.TAG, TOPIC, thing, thing, 0);
        vm.recordLogs();
        _execAs(address(this), a, b);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 bound;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == ILedger.Bound.selector) {
                ++bound;
                assertEq(logs[i].topics.length, 4);
                assertEq(logs[i].data.length, 192);
                assertEq(logs[i - 1].topics[0], ILedger.Admitted.selector, "after its Admitted");
                assertEq(logs[i - 1].topics[1], logs[i].topics[1], "the same admission");
            }
        }
        assertEq(bound, 1);
    }

    // ---- Body ------------------------------------------------------------------------------------------------

    function _bodyLogs(Vm.Log[] memory logs) internal pure returns (Vm.Log[] memory out) {
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == ILedger.Body.selector) ++n;
        }
        out = new Vm.Log[](n);
        n = 0;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == ILedger.Body.selector) out[n++] = logs[i];
        }
    }

    function _publishLogs(uint8 t, bytes memory body) internal returns (Vm.Log[] memory) {
        Action[] memory a = new Action[](1);
        bytes[] memory b = new bytes[](1);
        (a[0], b[0]) = _publish(t, body);
        vm.recordLogs();
        _execAs(address(this), a, b);
        return _bodyLogs(vm.getRecordedLogs());
    }

    function _bytes(uint256 n, bytes1 fill) internal pure returns (bytes memory out) {
        out = new bytes(n);
        for (uint256 i; i < n; ++i) {
            out[i] = fill;
        }
    }

    /// A fresh name is logged with its record id, Type id and bytes; publishing it again logs nothing.
    function test_body_on_a_fresh_name_not_on_a_repeat() public {
        bytes memory name = "pet.jpg";
        vm.expectEmit(true, true, false, true, address(r.ledger));
        emit ILedger.Body(_id(T_NAME, name), typeIds[T_NAME], name);
        Vm.Log[] memory logs = _publishLogs(T_NAME, name);
        assertEq(logs.length, 1);
        logs = _publishLogs(T_NAME, name);
        assertEq(logs.length, 0, "a repeat publish is not fresh");
    }

    /// The limit: a 256-byte body is logged, a 257-byte one is not (both fresh `files-bytes/1` chunks).
    function test_body_at_256_and_257_bytes() public {
        assertEq(ClosureConstants.BODY_EVENT_MAX, 256);
        bytes memory at = EfsFiles.bytesBody(_bytes(256 - 32, "a"));
        bytes memory over = EfsFiles.bytesBody(_bytes(257 - 32, "b"));
        assertEq(abi.encode(at.length, over.length), abi.encode(256, 257));
        Vm.Log[] memory logs = _publishLogs(T_BYTES, at);
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[1], _id(T_BYTES, at));
        assertEq(logs[0].topics[2], typeIds[T_BYTES]);
        assertEq(abi.decode(logs[0].data, (bytes)), at);
        logs = _publishLogs(T_BYTES, over);
        assertEq(logs.length, 0, "257 bytes stay in state only");
    }

    /// A folder record (64 bytes) is logged; so an indexer follows names and folders from events alone.
    function test_body_of_a_folder_record() public {
        bytes memory dir = _dirBody(p, keccak256("bound-event/folder"));
        vm.expectEmit(true, true, false, true, address(r.ledger));
        emit ILedger.Body(_id(T_DIRECTORY, dir), typeIds[T_DIRECTORY], dir);
        _publishLogs(T_DIRECTORY, dir);
    }
}
