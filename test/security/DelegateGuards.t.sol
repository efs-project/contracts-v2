// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ControlFixture} from "../harness/ControlFixture.sol";
import {Action, Intent, Native} from "../../src/interfaces/Actions.sol";
import {ILedgerIngress} from "../../src/interfaces/internal/ILedgerIngress.sol";
import {ILedgerApply} from "../../src/interfaces/internal/ILedgerApply.sol";
import {ILedgerControl, ActivationSet, RealmInit} from "../../src/interfaces/ILedgerControl.sol";
import {E_DELEGATE_ONLY} from "../../src/interfaces/Errors.sol";

/// @notice §2.2 S5 — the helpers are not callable as contracts. Every state-relevant selector of the three
///         pinned delegates (`LedgerIngress`, `LedgerApply`, `LedgerControl`) reverts `E_DELEGATE_ONLY` when
///         called directly (`address(this) == SELF`), so nobody can run the preparation, dispatch, apply or
///         control bodies against the delegate's own storage or relay through them. The etched-helper half
///         of S5 (`E_HELPER_CODE`) is `test/control/Genesis.t.sol::test_etched_*`.
contract DelegateGuardsTest is ControlFixture {
    function _expectDelegateOnly(address target, bytes memory data, string memory what) internal {
        (bool ok, bytes memory ret) = target.call(data);
        assertFalse(ok, what);
        assertEq(ret, abi.encodeWithSelector(E_DELEGATE_ONLY.selector), what);
    }

    function test_direct_call_to_every_delegate_selector_reverts_E_DELEGATE_ONLY() public {
        (Action[] memory actions, bytes[] memory bodies) = createActions("guards");
        Native memory ctx;
        Intent memory intent;
        address ingress = address(k.ingress);
        _expectDelegateOnly(
            ingress,
            abi.encodeCall(ILedgerIngress.prepareNative, (actions, bodies, ctx, "")),
            "ingress.prepareNative"
        );
        _expectDelegateOnly(
            ingress,
            abi.encodeCall(ILedgerIngress.prepareSigned, (intent, actions, bodies, "", "")),
            "ingress.prepareSigned"
        );
        _expectDelegateOnly(
            ingress,
            abi.encodeCall(ILedgerIngress.validateLeaf, (0, actions[0], "", 1, principal)),
            "ingress.validateLeaf"
        );
        _expectDelegateOnly(
            ingress,
            abi.encodeCall(ILedgerIngress.dispatchIndex, (1, new bytes(33 * 32), 0)),
            "ingress.dispatchIndex"
        );
        _expectDelegateOnly(
            ingress,
            abi.encodeCall(ILedgerIngress.dispatchFinal, (1, new bytes(24 * 32), new bytes32[](0))),
            "ingress.dispatchFinal"
        );
        _expectDelegateOnly(
            address(k.applyDelegate),
            abi.encodeCall(ILedgerApply.applyLeaf, (0, 1, actions[0], "", 0, principal, 1, 1, 0)),
            "apply.applyLeaf"
        );
        address control = address(k.control);
        RealmInit memory init;
        ActivationSet memory set = nextSet();
        _expectDelegateOnly(
            control, abi.encodeCall(ILedgerControl.initialize, (init)), "control.initialize"
        );
        _expectDelegateOnly(
            control, abi.encodeCall(ILedgerControl.activate, (set)), "control.activate"
        );
        _expectDelegateOnly(control, abi.encodeCall(ILedgerControl.freeze, (set)), "control.freeze");
        _expectDelegateOnly(
            control,
            abi.encodeCall(ILedgerControl.beginTransition, (2, uint48(block.number + 10))),
            "control.beginTransition"
        );
        _expectDelegateOnly(
            control, abi.encodeCall(ILedgerControl.abortTransition, ()), "control.abortTransition"
        );
        // the same selectors still work through the ledger, so the guard is the delegate's own
        publishMarker("guards/through-the-ledger");
    }
}
