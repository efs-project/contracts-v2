// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {FilesRecipesBase} from "./FilesRecipesBase.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {EfsFiles} from "../../src/lib/EfsFiles.sol";
import {EfsTopics} from "../../src/lib/EfsTopics.sol";
import {Action, ActionKind, Purpose} from "../../src/interfaces/Actions.sol";
import {ClosureConstants} from "../../src/interfaces/Limits.sol";
import {ILedger} from "../../src/interfaces/ILedger.sol";
import {FilesTypes} from "../../src/profiles/FilesTypes.sol";

/// @notice The two indexer events (design §5.5). Every bind-kind admission emits `Bound` right after its
///         `Admitted`, with the purpose, subject and role as its three indexed topics and the admission, target,
///         kind, strength, transition kind and target kind as data; record and subject kinds emit none. A PUBLISH
///         that first admits a record of a Type whose descriptor sets `TYPE_FLAG_EMITS_BODY` (byte 133 bit 0) and
///         whose body is at most `ClosureConstants.BODY_EVENT_MAX` bytes emits `Body` (record id, Type id, body);
///         an unflagged Type never does, at any size, and neither does a repeat publish, a REUSE or a larger body.
///         The topic is a word page registered in `setUp`.
contract BoundEventTest is FilesRecipesBase {
    bytes32 internal TOPIC;
    bytes32 internal thing;

    function setUp() public override {
        super.setUp();
        Action[] memory a = new Action[](1);
        a[0] = _create(keccak256("thing"));
        _execAs(address(this), a, new bytes[](1));
        thing = Keys.subject(p, keccak256("thing"));
        bytes[] memory b;
        (a, b, TOPIC) = EfsTopics.registerWord(_topicTypes(), "bound-event");
        _execAs(address(this), a, b);
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
    /// topics (purpose, subject, role) + 192 data bytes led by the admission, and it follows the `Admitted` of the
    /// same admission.
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
                assertEq(logs[i].topics[1], Purpose.TAG, "purpose");
                assertEq(logs[i].topics[2], TOPIC, "subject");
                assertEq(logs[i].topics[3], thing, "role");
                assertEq(logs[i].data.length, 192);
                assertEq(logs[i - 1].topics[0], ILedger.Admitted.selector, "after its Admitted");
                (uint64 admission) = abi.decode(_word(logs[i].data, 0), (uint64));
                assertEq(uint256(logs[i - 1].topics[1]), admission, "the same admission");
            }
        }
        assertEq(bound, 1);
    }

    /// The two filter recipes: (purpose TAG, role = the thing) finds every statement about the thing across
    /// topics, the lone negative included; (purpose, subject) finds everything under one topic.
    function test_filter_by_role_and_by_subject() public {
        (Action[] memory a, bytes[] memory b, bytes32 other) =
            EfsTopics.registerWord(_topicTypes(), "bound-event-other");
        _execAs(address(this), a, b);
        a = new Action[](3);
        a[0] = EfsFiles.bindWithStrength(Purpose.TAG, TOPIC, thing, thing, 0, 3);
        a[1] = EfsFiles.loneNegative(Purpose.TAG, other, thing, 9);
        a[2] = _bind(Purpose.TAG, TOPIC, keccak256("bound-event/role/2"), thing, 0);
        vm.recordLogs();
        _execAs(address(this), a, new bytes[](3));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 byRole;
        uint256 bySubject;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != ILedger.Bound.selector || logs[i].topics[1] != Purpose.TAG) {
                continue;
            }
            if (logs[i].topics[3] == thing) ++byRole;
            if (logs[i].topics[2] == TOPIC) ++bySubject;
        }
        assertEq(byRole, 2, "a positive and a lone negative about the thing");
        assertEq(bySubject, 2, "two entries under the topic");
    }

    function _word(bytes memory data, uint256 i) internal pure returns (bytes memory w) {
        w = new bytes(32);
        for (uint256 j; j < 32; ++j) {
            w[j] = data[i * 32 + j];
        }
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

    function _publishLogsAs(bytes32 typeId, bytes memory body) internal returns (Vm.Log[] memory) {
        Action[] memory a = new Action[](1);
        bytes[] memory b = new bytes[](1);
        a[0].kind = ActionKind.PUBLISH;
        a[0].typeId = typeId;
        a[0].bodyHashOrRecordId = keccak256(body);
        b[0] = body;
        vm.recordLogs();
        _execAs(address(this), a, b);
        return _bodyLogs(vm.getRecordedLogs());
    }

    /// A flagged copy of `files-bytes/1`: the same rule instance and descriptor with byte 133 = EMITS_BODY, so a
    /// Type that accepts any bytes shows the 256-byte ceiling. It is a different Type id from the unflagged one.
    function _flaggedBytesType() internal returns (bytes32 typeId) {
        FilesTypes.Spec memory s = FilesTypes.bytesSpec();
        s.flags = ClosureConstants.TYPE_FLAG_EMITS_BODY;
        bytes memory d = FilesTypes.encode(
            declarationKey, instances[T_BYTES].codehash, initcodeHashes[T_BYTES], s
        );
        typeId = FilesTypes.typeIdOf(d);
        assertTrue(typeId != typeIds[T_BYTES], "the flag is identity-bearing");
        bytes memory sig = _declare(r.registry, typeId);
        r.store.put(d, sig);
        (bytes32 got,) = r.registry.registerDescribed(d, sig, instances[T_BYTES], "");
        assertEq(got, typeId);
        assertEq(r.registry.typeInfo(typeId).flags, 1);
        assertEq(r.registry.typeInfo(typeIds[T_BYTES]).flags, 0);
    }

    /// `files-name/2` sets the flag: a fresh name is logged with its record id, Type id and bytes; publishing it
    /// again logs nothing.
    function test_body_on_a_fresh_name_not_on_a_repeat() public {
        assertEq(r.registry.typeInfo(typeIds[T_NAME]).flags, 1);
        bytes memory name = "pet.jpg";
        vm.expectEmit(true, true, false, true, address(r.ledger));
        emit ILedger.Body(_id(T_NAME, name), typeIds[T_NAME], name);
        Vm.Log[] memory logs = _publishLogs(T_NAME, name);
        assertEq(logs.length, 1);
        logs = _publishLogs(T_NAME, name);
        assertEq(logs.length, 0, "a repeat publish is not fresh");
    }

    /// The three Topics Types set the flag: a fresh word page (multi-byte UTF-8 included), a fresh `topic/1` path
    /// record and a fresh `text/1` record are each logged with their record id, Type id and exact bytes; publishing
    /// any of them again logs nothing.
    function test_body_on_fresh_topics_records_not_on_a_repeat() public {
        EfsTopics.Types memory t = _topicTypes();
        assertEq(r.registry.typeInfo(t.word).flags, 1);
        assertEq(r.registry.typeInfo(t.topic).flags, 1);
        assertEq(r.registry.typeInfo(t.text).flags, 1);
        _bodyOnceAs(t.word, bytes("caf\u00e9"));
        bytes memory page = bytes("\u9ce5");
        _bodyOnceAs(t.word, page);
        _bodyOnceAs(t.topic, EfsTopics.pathBody(TOPIC, EfsTopics.wordPageId(t.word, page)));
        _bodyOnceAs(t.text, bytes("Birds of Prey / Raptors"));
    }

    /// A fresh `body` of `typeId` logs exactly one `Body(Keys.record(typeId, body), typeId, body)`; a repeat none.
    function _bodyOnceAs(bytes32 typeId, bytes memory body) internal {
        bytes32 id = Keys.record(typeId, body);
        vm.expectEmit(true, true, false, true, address(r.ledger));
        emit ILedger.Body(id, typeId, body);
        Vm.Log[] memory logs = _publishLogsAs(typeId, body);
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[1], id);
        assertEq(logs[0].topics[2], typeId);
        assertEq(abi.decode(logs[0].data, (bytes)), body);
        assertEq(_publishLogsAs(typeId, body).length, 0, "a repeat publish is not fresh");
    }

    /// A REUSE of a flagged record is never fresh.
    function test_no_body_on_a_reuse() public {
        bytes memory name = "reused.txt";
        _publishLogs(T_NAME, name);
        Action[] memory a = new Action[](1);
        a[0].kind = ActionKind.REUSE;
        a[0].typeId = typeIds[T_NAME];
        a[0].bodyHashOrRecordId = _id(T_NAME, name);
        vm.recordLogs();
        _execAs(address(this), a, new bytes[](1));
        assertEq(_bodyLogs(vm.getRecordedLogs()).length, 0);
    }

    /// The ceiling on a flagged Type: a 256-byte body is logged, a 257-byte one is not (both fresh).
    function test_flagged_body_at_256_and_257_bytes() public {
        assertEq(ClosureConstants.BODY_EVENT_MAX, 256);
        bytes32 flagged = _flaggedBytesType();
        bytes memory at = EfsFiles.bytesBody(_bytes(256 - 32, "a"));
        bytes memory over = EfsFiles.bytesBody(_bytes(257 - 32, "b"));
        assertEq(abi.encode(at.length, over.length), abi.encode(256, 257));
        Vm.Log[] memory logs = _publishLogsAs(flagged, at);
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[1], Keys.record(flagged, at));
        assertEq(logs[0].topics[2], flagged);
        assertEq(abi.decode(logs[0].data, (bytes)), at);
        logs = _publishLogsAs(flagged, over);
        assertEq(logs.length, 0, "257 bytes stay in state only");
        logs = _publishLogsAs(flagged, at);
        assertEq(logs.length, 0, "a repeat publish is not fresh");
    }

    /// An unflagged Type never logs its body, at any size: `files-bytes/1` at 32, 256 and 257 bytes, a folder
    /// record (64 bytes) and a small inline `files-root/1`.
    function test_unflagged_types_never_log_a_body() public {
        assertEq(r.registry.typeInfo(typeIds[T_DIRECTORY]).flags, 0);
        assertEq(r.registry.typeInfo(typeIds[T_ROOT]).flags, 0);
        assertEq(_publishLogs(T_BYTES, EfsFiles.bytesBody("")).length, 0);
        assertEq(_publishLogs(T_BYTES, EfsFiles.bytesBody(_bytes(256 - 32, "a"))).length, 0);
        assertEq(_publishLogs(T_BYTES, EfsFiles.bytesBody(_bytes(257 - 32, "b"))).length, 0);
        assertEq(_publishLogs(T_DIRECTORY, _dirBody(p, keccak256("bound-event/folder"))).length, 0);
        bytes32 file = Keys.subject(p, keccak256("thing"));
        assertEq(_publishLogs(T_ROOT, bytes.concat(abi.encode(file, uint256(0)), "hi")).length, 0);
    }
}
