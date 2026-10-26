// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ConsumerFixture} from "./ConsumerFixture.t.sol";
import {ConstructorWriter} from "../harness/doubles/ConsumerDoubles.sol";
import {AcceptAll} from "../harness/doubles/Acceptors.sol";
import {NativeApp} from "../../examples/NativeApp.sol";
import {EfsNative} from "../../src/lib/EfsNative.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {Action, Coordinate, Native} from "../../src/interfaces/Actions.sol";
import {ILedger} from "../../src/interfaces/ILedger.sol";
import {
    AlreadyAdmitted,
    E_ACCEPTANCE_PROFILE,
    E_CAS,
    E_EXECUTION_SET,
    E_INDEX_GAS,
    E_NATIVE_AMBIGUOUS,
    E_NONCE,
    E_PUBLICATION_ACTIVE,
    E_REJECTED,
    E_UNKNOWN_TYPE
} from "../../src/interfaces/Errors.sol";

/// @notice Native-caller authorship through `EfsNative` (design §2.2 S2, §5.14, §16.2) and the plan
///         expectations it binds: `principalOf` for a key, a contract and an exact 23-byte EIP-7702
///         designator; `E_NATIVE_AMBIGUOUS` for a contract writing from its constructor; `currentBind` binding
///         the live execution set and acceptance profile; an activation between preparation and landing
///         refusing the bound plan with `E_EXECUTION_SET`, and a policy activation with
///         `E_ACCEPTANCE_PROFILE`, both with the nonce intact; `tryExecute`'s retry classes.
contract AttributionTest is ConsumerFixture {
    using EfsNative for ILedger;

    address internal constant EOA = address(0xE0A);
    bytes32 internal me;

    function setUp() public override {
        super.setUp();
        _newApp(100); // registers the example Type
        me = Keys.contractPrincipal(origin, address(this));
    }

    function _publishPlan(bytes memory body) internal view returns (Action[] memory a) {
        a = new Action[](1);
        a[0] = EfsNative.publishAction(appTypeId, body);
    }

    function _bodies(bytes memory body) internal pure returns (bytes[] memory b) {
        b = new bytes[](1);
        b[0] = body;
    }

    // ---- principalOf ---------------------------------------------------------------------------------------

    function testPrincipalOfKeyContractAndDesignator() public {
        assertEq(ledger.principalOf(EOA), Keys.principal(EOA), "a key is the padded address");
        assertEq(ledger.principalOf(address(this)), me, "a contract is realm-qualified");
        assertEq(ledger.myPrincipal(), me);
        // exactly ef0100 ‖ address (23 bytes) stays the key's principal, without following the target
        address delegated = address(0x7702);
        vm.etch(delegated, abi.encodePacked(hex"ef0100", address(this)));
        assertEq(delegated.code.length, 23);
        assertEq(ledger.principalOf(delegated), Keys.principal(delegated));
        // near misses are contract principals: 23 bytes under another prefix, and 24 bytes (the
        // EVM refuses other 0xef-prefixed code, EIP-3541, so a 24-byte near miss is not 0xef-prefixed)
        vm.etch(delegated, abi.encodePacked(hex"ee0100", address(this)));
        assertEq(ledger.principalOf(delegated), Keys.contractPrincipal(origin, delegated));
        vm.etch(delegated, abi.encodePacked(hex"600100", address(this), hex"00"));
        assertEq(ledger.principalOf(delegated), Keys.contractPrincipal(origin, delegated));
    }

    function testDesignatedAccountWritesAsItsKey() public {
        address delegated = address(0x7702);
        vm.etch(delegated, abi.encodePacked(hex"ef0100", address(this)));
        Action[] memory a = new Action[](1);
        a[0] = EfsNative.createAction(keccak256("7702"));
        Native memory ctx = EfsNative.context(0, ledger.currentBind(a)); // before the prank
        vm.prank(delegated); // has code, so not ambiguous even though it is not tx.origin
        ledger.execute(a, new bytes[](1), ctx, "");
        assertEq(_nonce(Keys.principal(delegated)), 1);
        assertEq(_nonce(Keys.contractPrincipal(origin, delegated)), 0);
    }

    function testEoaWritesAsItsKeyOnlyAsTxOrigin() public {
        Action[] memory a = new Action[](1);
        a[0] = EfsNative.createAction(keccak256("eoa"));
        Native memory ctx = EfsNative.context(0, ledger.currentBind(a));
        // a code-less caller that is not tx.origin is indistinguishable from a contract under construction
        vm.prank(EOA);
        vm.expectRevert(E_NATIVE_AMBIGUOUS.selector);
        ledger.execute(a, new bytes[](1), ctx, "");
        vm.prank(EOA, EOA);
        ledger.execute(a, new bytes[](1), ctx, "");
        assertEq(_nonce(Keys.principal(EOA)), 1);
    }

    function testConstructorWriteIsAmbiguous() public {
        vm.expectRevert(E_NATIVE_AMBIGUOUS.selector);
        new ConstructorWriter(ledger);
        (uint64 admissions,,, uint64 publications) = hot.counts();
        assertEq(admissions, 0);
        assertEq(publications, 0);
    }

    // ---- currentBind -------------------------------------------------------------------------------------

    function testCurrentBindBindsTheLiveExpectations() public {
        Action[] memory a = _publishPlan("bound");
        EfsNative.Bind memory b = ledger.currentBind(a);
        assertEq(b.executionSet, hot.executionSet());
        assertEq(b.acceptanceProfile, commitments.acceptanceProfileOf(address(ledger), a));
        assertTrue(b.acceptanceProfile != 0);
        Native memory ctx = ledger.currentContext(a);
        assertEq(ctx.nonce, 0);
        assertEq(ctx.deadline, 0);
        assertEq(ctx.expectedExecutionSet, b.executionSet);
        assertEq(ctx.expectedAcceptanceProfile, b.acceptanceProfile);
        (uint64 publication,) = EfsNative.execute(ledger, a, _bodies("bound"), ctx);
        assertEq(publication, 1);
        // the retry key commits to both expectations
        (, bytes32 digest) = hot.publicationAt(me, 0);
        assertEq(
            digest,
            commitments.nativeIntentDigest(
                hot.realmId(), me, ctx, keccak256(abi.encode(a)), keccak256("")
            )
        );
        assertEq(ledger.nextNonce(), 1);
        // the one-shot form, with the bind computed for its own single action
        (uint64 p2, bytes32 recordId) =
            ledger.publish(1, ledger.currentBind(_publishPlan("one-shot")), appTypeId, "one-shot");
        assertEq(p2, 2);
        assertEq(recordId, Keys.record(appTypeId, "one-shot"));
    }

    function testCurrentBindOfAnUnknownTypeReverts() public {
        Action[] memory a = new Action[](1);
        a[0] = EfsNative.publishAction(keccak256("unregistered"), "x");
        vm.expectRevert(
            abi.encodeWithSelector(E_UNKNOWN_TYPE.selector, uint8(0), keccak256("unregistered"))
        );
        this.bindOf(a);
    }

    function bindOf(Action[] calldata a) external view returns (EfsNative.Bind memory) {
        return ledger.currentBind(a);
    }

    function testActivationRefusesTheBoundPlanWithNonceIntact() public {
        Action[] memory a = _publishPlan("prepared before the activation");
        Native memory ctx = ledger.currentContext(a);
        bytes32 prepared = ctx.expectedExecutionSet;
        bytes32 live = _activateNext();
        assertTrue(live != prepared, "the activation changed the execution set");
        // the bound native expectation is E_EXECUTION_SET (E_EXPECTED_SET is the activation's own check)
        vm.expectRevert(abi.encodeWithSelector(E_EXECUTION_SET.selector, prepared, live));
        EfsNative.execute(ledger, a, _bodies("prepared before the activation"), ctx);
        assertEq(ledger.nextNonce(), 0, "nonce intact");
        (uint64 admissions,,,) = hot.counts();
        assertEq(admissions, 0);
        // the plan re-prepared against the live set lands at the intact nonce
        ctx = ledger.currentContext(a);
        assertEq(ctx.expectedExecutionSet, live);
        EfsNative.execute(ledger, a, _bodies("prepared before the activation"), ctx);
        assertEq(ledger.nextNonce(), 1);
    }

    function testPolicyActivationRefusesTheBoundPlanWithNonceIntact() public {
        Action[] memory a = _publishPlan("policy");
        Native memory ctx = ledger.currentContext(a);
        registry.activatePolicy(appTypeId, address(new AcceptAll()));
        bytes32 live = commitments.acceptanceProfileOf(address(ledger), a);
        assertEq(hot.executionSet(), ctx.expectedExecutionSet, "a policy is not an activation");
        vm.expectRevert(
            abi.encodeWithSelector(
                E_ACCEPTANCE_PROFILE.selector, ctx.expectedAcceptanceProfile, live
            )
        );
        EfsNative.execute(ledger, a, _bodies("policy"), ctx);
        assertEq(ledger.nextNonce(), 0, "nonce intact");
        // bound to the execution set alone, the same plan lands under the new policy
        ctx.expectedAcceptanceProfile = 0;
        EfsNative.execute(ledger, a, _bodies("policy"), ctx);
        assertEq(ledger.nextNonce(), 1);
    }

    // ---- tryExecute and retry classes ---------------------------------------------------------------------

    function testTryExecuteClassifiesRefusals() public {
        Action[] memory a = _publishPlan("try");
        Native memory ctx = ledger.currentContext(a);
        (bool ok, uint64 p, uint64 first, bytes4 sel, uint8 retry) =
            EfsNative.tryExecute(ledger, a, _bodies("try"), ctx);
        assertTrue(ok);
        assertEq(p, 1);
        assertEq(first, 1);
        assertEq(sel, bytes4(0));
        // the identical plan again: committed, with its publication
        (ok, p,, sel, retry) = EfsNative.tryExecute(ledger, a, _bodies("try"), ctx);
        assertFalse(ok);
        assertEq(sel, AlreadyAdmitted.selector);
        assertEq(retry, EfsNative.RETRY_COMMITTED);
        assertEq(p, 1);
        // a different plan at a consumed nonce: reprepare
        (ok,,, sel, retry) =
            EfsNative.tryExecute(ledger, _publishPlan("other"), _bodies("other"), ctx);
        assertEq(sel, E_NONCE.selector);
        assertEq(retry, EfsNative.RETRY_REPREPARE);
        // the rule's refusal: none
        a = _publishPlan(hex"ff");
        (ok,,, sel, retry) =
            EfsNative.tryExecute(ledger, a, _bodies(hex"ff"), ledger.currentContext(a));
        assertFalse(ok);
        assertEq(sel, E_REJECTED.selector);
        assertEq(retry, EfsNative.RETRY_NONE);
        assertEq(ledger.nextNonce(), 1, "a refusal consumes no nonce");
    }

    function testRetryClassTable() public pure {
        assertEq(EfsNative.retryClass(E_CAS.selector), EfsNative.RETRY_REPREPARE);
        assertEq(EfsNative.retryClass(E_EXECUTION_SET.selector), EfsNative.RETRY_REPREPARE);
        assertEq(EfsNative.retryClass(E_ACCEPTANCE_PROFILE.selector), EfsNative.RETRY_REPREPARE);
        assertEq(EfsNative.retryClass(E_INDEX_GAS.selector), EfsNative.RETRY_RESUBMIT);
        assertEq(EfsNative.retryClass(E_PUBLICATION_ACTIVE.selector), EfsNative.RETRY_WAIT);
        assertEq(EfsNative.retryClass(E_NATIVE_AMBIGUOUS.selector), EfsNative.RETRY_NONE);
        assertEq(EfsNative.retryClass(bytes4(0)), EfsNative.RETRY_NONE);
    }

    function testOneShotBuildersMatchTheKernelShapes() public {
        EfsNative.Bind memory unbound;
        (uint64 p1, bytes32 subject) = ledger.create(0, unbound, keccak256("s"));
        assertEq(subject, Keys.subject(me, keccak256("s")));
        (, bytes32 rid) = ledger.publish(1, unbound, appTypeId, "r");
        Coordinate memory c = Coordinate(FOLDER, subject, ROLE);
        ledger.bind(2, unbound, c, rid, 0);
        ledger.unbind(3, unbound, c, 1);
        ledger.bind(4, unbound, c, rid, 2);
        ledger.release(5, unbound, c, 3);
        (uint8 state,,,,,,) = hot.head(_headKey(me, subject, ROLE));
        assertEq(state, 3, "RELEASED");
        (uint64 admissions,,,) = hot.counts();
        ledger.withdraw(6, unbound, 2); // the PUBLISH admission
        assertEq(ledger.nextNonce(), 7);
        assertEq(p1, 1);
        assertEq(admissions, 6);
    }
}
