// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {KernelFixture} from "../../harness/KernelFixture.sol";
import {
    AcceptAll,
    RejectAll,
    RevertingAcceptor,
    ReturndataBomb,
    GasBurner,
    ExhaustedAcceptor,
    ShapedReplyAcceptor,
    ReentrantAcceptor,
    MockAcceptor
} from "../../harness/doubles/Acceptors.sol";
import {Layout} from "../../../src/core/layout/Layout.sol";
import {Action} from "../../../src/interfaces/Actions.sol";
import {ILedger} from "../../../src/interfaces/ILedger.sol";
import {TypeInfo} from "../../../src/interfaces/ITypeRegistry.sol";
import {IAcceptor, EXHAUSTED} from "../../../src/interfaces/IAcceptor.sol";
import {
    AlreadyAdmitted,
    E_ACCEPTOR_CODE,
    E_ACCEPTOR_GAS,
    E_GAS,
    E_INDEX_CALL,
    E_NONCE,
    E_POLICY_REJECTED,
    E_REJECTED
} from "../../../src/interfaces/Errors.sol";

/// @notice The acceptor call (design §6.4, §5.10; §2.2 S3): an assembly `STATICCALL` with a 32-byte output
///         buffer, success only for exactly 32 bytes equal to the selector word, revert data discarded,
///         exhaustion (`EXHAUSTED`, or empty returndata having used ≥ forwarded − 2,000) → `E_ACCEPTOR_GAS`
///         (resubmit), anything else → `E_REJECTED` / `E_POLICY_REJECTED`; the codehash re-check, the declared
///         gas floor and the lock seen from a re-entering rule.
contract AcceptorsTest is KernelFixture {
    uint256 internal constant BOUNDED = 3_000_000;
    bytes internal constant BODY = "acceptors/body";

    function _typeFor(address rule) internal returns (bytes32 t) {
        t = keccak256(abi.encode("acceptors/type", rule));
        _registerType(t, rule);
    }

    function _policyType(address policy, uint16 row) internal returns (bytes32 t) {
        t = keccak256(abi.encode("acceptors/policy", policy, row));
        TypeInfo memory info = _nativeType(address(acceptAll));
        (info.policy, info.policyCodehash, info.policyRow, info.policyRows) =
        (policy, policy.codehash, row, row);
        _registerType(t, info, new bytes32[](0));
    }

    function _one(bytes32 t) internal pure returns (Action[] memory) {
        return _acts(_publish(t, BODY));
    }

    function _body1() internal pure returns (bytes[] memory) {
        return _bodies(1, 0, BODY);
    }

    function _rejected(uint8 leaf, bytes32 t) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(E_REJECTED.selector, leaf, t);
    }

    /// Decodes E_ACCEPTOR_GAS and checks leaf, Type and that the forwarded gas met the 300,000 default floor.
    function _assertAcceptorGas(bytes memory err, uint8 leaf, bytes32 t) internal pure {
        (uint8 l, bytes32 typeId, uint32 forwarded) =
            abi.decode(_args(err, E_ACCEPTOR_GAS.selector), (uint8, bytes32, uint32));
        assertEq(abi.encode(l, typeId), abi.encode(leaf, t));
        assertGe(forwarded, 300_000, "forwarded at least the declared floor");
        assertLt(forwarded, BOUNDED, "forwarded no more than the call had");
    }

    // ---- E_REJECTED -----------------------------------------------------------------------------------------

    function test_reject_all_is_E_REJECTED_at_its_leaf() public {
        _expectNoChange(
            _acts(_create("c"), _publish(TYPE_REJECT, BODY)),
            _bodies(2, 1, BODY),
            _rejected(1, TYPE_REJECT)
        );
    }

    function test_revert_data_is_discarded() public {
        bytes[5] memory forged = [
            abi.encodeWithSelector(E_NONCE.selector, principal, uint64(0), uint64(7)),
            abi.encodeWithSelector(AlreadyAdmitted.selector, uint64(1)),
            abi.encodeWithSelector(E_INDEX_CALL.selector, hex"deadbeef"),
            new bytes(5_000),
            bytes("")
        ];
        for (uint256 i; i < forged.length; ++i) {
            bytes32 t = _typeFor(address(new RevertingAcceptor(forged[i])));
            _expectNoChange(_one(t), _body1(), _rejected(0, t));
        }
    }

    /// 64 KiB of returndata is never copied: the refusal costs about the bomb's own memory expansion over an
    /// ordinary refusal (measured ~9.9k at S1). Copying the reply into any kernel frame would add at least
    /// another 3·2,048 + 2,048²/512 = 14,336 gas of expansion, so a 20k ceiling separates the two.
    function test_returndata_bomb_is_E_REJECTED_with_bounded_gas() public {
        bytes32 bomb = _typeFor(address(new ReturndataBomb()));
        bytes32 reject = _typeFor(address(new RejectAll()));
        _expectNoChange(_one(bomb), _body1(), _rejected(0, bomb));
        uint256 rejectGas = _gasOf(reject);
        uint256 bombGas = _gasOf(bomb);
        emit log_named_uint("refusal gas, RejectAll", rejectGas);
        emit log_named_uint("refusal gas, 64 KiB bomb", bombGas);
        assertLt(bombGas, rejectGas + 20_000, "the kernel copied or expanded for the bomb");
    }

    function _gasOf(bytes32 t) internal returns (uint256 used) {
        bytes memory data = abi.encodeCall(ILedger.execute, (_one(t), _body1(), _native(0), ""));
        uint256 g = gasleft();
        (bool ok,) = k.proxy.call(data);
        used = g - gasleft();
        assertFalse(ok);
    }

    function test_near_miss_reply_shapes_are_E_REJECTED() public {
        bytes32 sel = bytes32(IAcceptor.accept.selector);
        bytes32[7] memory words =
            [sel, sel | bytes32(uint256(1)), sel, sel, sel, EXHAUSTED, EXHAUSTED];
        uint256[7] memory lengths = [uint256(4), 32, 64, 31, 0, 64, 31];
        for (uint256 i; i < words.length; ++i) {
            bytes32 t = _typeFor(address(new ShapedReplyAcceptor(words[i], lengths[i])));
            _expectNoChange(_one(t), _body1(), _rejected(0, t));
        }
        bytes32 exact = _typeFor(address(new ShapedReplyAcceptor(sel, 32)));
        _exec(_one(exact), _body1()); // the control: the exact 32-byte selector word
    }

    // ---- E_ACCEPTOR_GAS (resubmit) --------------------------------------------------------------------------

    function test_gas_burner_is_E_ACCEPTOR_GAS_not_E_REJECTED() public {
        bytes32 burner = _typeFor(address(new GasBurner()));
        _assertAcceptorGas(_refusedWithGas(_one(burner), _body1(), BOUNDED), 0, burner);
        // S3: a two-Type batch with one hostile Type rolls back the honest leaf too
        bytes[] memory b = _bodies(2, 1, BODY);
        b[0] = "honest";
        _assertAcceptorGas(
            _refusedWithGas(_acts(_publish(TYPE_OK, "honest"), _publish(burner, BODY)), b, BOUNDED),
            1,
            burner
        );
    }

    function test_exhausted_word_is_E_ACCEPTOR_GAS() public {
        bytes32 t = _typeFor(address(new ExhaustedAcceptor()));
        _assertAcceptorGas(_refusedWithGas(_one(t), _body1(), BOUNDED), 0, t);
    }

    // ---- policy acceptor ------------------------------------------------------------------------------------

    function test_policy_refusal_is_E_POLICY_REJECTED_with_its_row() public {
        bytes32 t = _policyType(address(rejectAll), 2);
        _expectNoChange(
            _one(t),
            _body1(),
            abi.encodeWithSelector(E_POLICY_REJECTED.selector, uint8(0), t, uint16(2))
        );
        bytes32 ok = _policyType(address(new AcceptAll()), 3);
        _exec(_one(ok), _body1());
        (,,,,,,, uint16 policyRow,,) =
            Layout.unpackAdmissionRowWord0(_raw(Layout.admissionsRowsSlot(1)));
        assertEq(policyRow, 3, "the policy row is recorded in the admission row");
    }

    function test_mock_policy_modes() public {
        MockAcceptor mock = new MockAcceptor();
        bytes32 t = _policyType(address(mock), 2);
        bytes memory refused =
            abi.encodeWithSelector(E_POLICY_REJECTED.selector, uint8(0), t, uint16(2));
        mock.set(mock.REJECT(), 0);
        _expectNoChange(_one(t), _body1(), refused);
        mock.set(mock.REVERT(), 0);
        _expectNoChange(_one(t), _body1(), refused);
        mock.set(mock.ACCEPT(), BODY.length + 1); // the prototype's minBody threshold
        _expectNoChange(_one(t), _body1(), refused);
        mock.set(mock.EXHAUST(), 0);
        _assertAcceptorGas(_refusedWithGas(_one(t), _body1(), BOUNDED), 0, t);
        mock.set(mock.LOOP(), 0);
        _assertAcceptorGas(_refusedWithGas(_one(t), _body1(), BOUNDED), 0, t);
        mock.set(mock.ACCEPT(), 0);
        _exec(_one(t), _body1());
    }

    /// policy == address(0) is a no-policy row: no call and no codehash check, even with a garbage
    /// policyCodehash (a check would read address(0).codehash == 0 and refuse); the row is still recorded.
    function test_zero_policy_means_no_policy_call() public {
        bytes32 t = keccak256("acceptors/no-policy");
        TypeInfo memory info = _nativeType(address(acceptAll));
        (info.policyCodehash, info.policyRow, info.policyRows) = (keccak256("garbage"), 4, 4);
        _registerType(t, info, new bytes32[](0));
        _exec(_one(t), _body1());
        (,,,,,,, uint16 policyRow,,) =
            Layout.unpackAdmissionRowWord0(_raw(Layout.admissionsRowsSlot(1)));
        assertEq(policyRow, 4);
    }

    // ---- E_ACCEPTOR_CODE, E_GAS -----------------------------------------------------------------------------

    function test_changed_codehash_is_E_ACCEPTOR_CODE() public {
        AcceptAll rule = new AcceptAll();
        bytes32 t = _typeFor(address(rule));
        vm.etch(address(rule), address(rejectAll).code);
        _expectNoChange(
            _one(t), _body1(), abi.encodeWithSelector(E_ACCEPTOR_CODE.selector, uint8(0), rule)
        );
        AcceptAll policy = new AcceptAll();
        bytes32 p = _policyType(address(policy), 2);
        vm.etch(address(policy), hex"00");
        _expectNoChange(
            _one(p), _body1(), abi.encodeWithSelector(E_ACCEPTOR_CODE.selector, uint8(0), policy)
        );
    }

    function test_declared_validationGas_above_available_is_E_GAS() public {
        bytes32 t = keccak256("acceptors/heavy");
        TypeInfo memory info = _nativeType(address(acceptAll));
        info.validationGas = 5_000_000;
        _registerType(t, info, new bytes32[](0));
        bytes memory err = _refusedWithGas(_one(t), _body1(), BOUNDED);
        (uint8 leaf, uint32 needed, uint32 available) =
            abi.decode(_args(err, E_GAS.selector), (uint8, uint32, uint32));
        assertEq(abi.encode(leaf, needed), abi.encode(0, 5_000_000));
        assertLt(available, needed);
        assertGt(available, 1_000_000, "available is what the frame had, not zero");
        _exec(_one(t), _body1()); // with ordinary test gas the floor is met and the rule runs
    }

    // ---- S1: a re-entering rule sees the lock ---------------------------------------------------------------

    function test_reentrant_acceptor_is_refused_and_the_publication_lands() public {
        bytes32 t = _typeFor(address(new ReentrantAcceptor()));
        _exec(_one(t), _body1());
        (uint64 admissions,,, uint64 publications) = _counts();
        assertEq(admissions + publications, 2, "only the outer publication landed");
    }
}
