// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {console2} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ConsumerFixture} from "./ConsumerFixture.t.sol";
import {Factory} from "../harness/doubles/Factory.sol";
import {NativeApp, NativeAppRule} from "../../examples/NativeApp.sol";
import {EfsNative} from "../../src/lib/EfsNative.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {Action, Coordinate, FamilyId, Native, TypeId} from "../../src/interfaces/Actions.sol";
import {Status} from "../../src/interfaces/Results.sol";
import {Evidence} from "../../src/interfaces/Views.sol";
import {TypeInfo} from "../../src/interfaces/ITypeRegistry.sol";
import {ILedger} from "../../src/interfaces/ILedger.sol";
import {E_REJECTED} from "../../src/interfaces/Errors.sol";

/// @notice The tiny external Solidity consumer of design §12.3 against the kernel, the real registry and the
///         real generation-1 index: the app registers its NATIVE Type at the deterministic instance, writes
///         CREATE + PUBLISH + BIND(FOLDER) with both expectations bound, reads back through the hot getters;
///         atomicity both directions; the forwarding writer is the author; a proxy-hosted app authors as the
///         proxy; two composing apps each author their own writes; an EOA through the app and the same EOA
///         straight to the ledger are different principals.
contract NativeAppTest is ConsumerFixture {
    using EfsNative for ILedger;

    address internal constant ALICE = address(0xA11CE5);
    address internal constant BOB = address(0xB0B);

    NativeApp internal app;
    bytes32 internal appPrincipal;

    function setUp() public override {
        super.setUp();
        app = _newApp(100);
        appPrincipal = Keys.contractPrincipal(origin, address(app));
    }

    function _counts() internal view returns (uint64 a, uint64 r, uint64 b, uint64 p) {
        return hot.counts();
    }

    function _author(uint64 publication) internal view returns (Evidence memory e) {
        Status s;
        (s, e) = reads.evidence(address(ledger), publication);
        assertEq(uint8(s), uint8(Status.PRESENT));
    }

    function testRuntimeSize() public view {
        console2.log("NativeApp runtime bytes", address(app).code.length);
        console2.log("NativeAppRule runtime bytes", app.rule().code.length);
    }

    function testRegistersItsNativeTypeAtTheDeterministicInstance() public view {
        assertEq(app.typeId(), appTypeId);
        address instance = registry.predictInstance(ruleInitcodeHash);
        assertEq(app.rule(), instance);
        assertEq(instance, Factory.predict(type(NativeAppRule).creationCode));
        assertEq(instance.codehash, keccak256(type(NativeAppRule).runtimeCode));
        TypeInfo memory info = registry.typeInfo(appTypeId);
        assertEq(info.grade, 3, "NATIVE");
        assertEq(info.mandatory, instance);
        assertEq(info.ruleId, instance.codehash);
        assertEq(registry.catalogCount(), 1);
    }

    function testWritesAndReadsBack() public {
        vm.prank(ALICE, ALICE);
        (uint64 n, bytes32 subject, bytes32 recordId, uint64 publication) =
            app.write("hello, ledger", ROLE);
        assertEq(n, 1);
        assertEq(publication, 1);
        assertEq(subject, Keys.subject(appPrincipal, bytes32(uint256(1))));
        assertEq(recordId, Keys.record(appTypeId, "hello, ledger"));
        (bool present, bool bound, uint64 revision) = app.readBack(1);
        assertTrue(present, "record");
        assertTrue(bound, "FOLDER head bound to the record");
        assertEq(revision, 1);
        assertEq(hot.subjectCreatedAt(subject), 1, "the CREATE leaf");
        (uint64 admissions, uint64 records, uint64 bindings, uint64 publications) = _counts();
        assertEq(admissions, 3);
        assertEq(records, 1);
        assertEq(bindings, 1);
        assertEq(publications, 1);
        assertEq(_nonce(appPrincipal), 1);
        // the plan carried both expectations
        Evidence memory e = _author(1);
        assertTrue(e.executionBound, "execution set bound");
        assertTrue(e.acceptanceBound, "acceptance profile bound");
        assertEq(e.executionSet, hot.executionSet());
        // the real index folded the write under the app's principal
        (, uint64 count,,,) = g.index
            .postingHeadOf(
                FamilyId.wrap(Keys.familyId("by-author")), TypeId.wrap(0), 0, appPrincipal
            );
        assertEq(count, 1);
        (, count,,,) = g.index
            .postingHeadOf(FamilyId.wrap(Keys.familyId("by-type")), TypeId.wrap(appTypeId), 0, 0);
        assertEq(count, 1);
        // a second write gets a fresh subject from the app's counter and the next nonce
        app.write("second", ROLE);
        assertEq(_nonce(appPrincipal), 2);
        (present, bound,) = app.readBack(2);
        assertTrue(present && bound);
    }

    function testLedgerRefusalRevertsTheAppsState() public {
        app.write("first", ROLE);
        (uint64 a0, uint64 r0, uint64 b0, uint64 p0) = _counts();
        // the app's own rule refuses a body starting 0xff: leaf 1 is the PUBLISH
        vm.expectRevert(abi.encodeWithSelector(E_REJECTED.selector, uint8(1), appTypeId));
        app.write(hex"ff00", ROLE);
        assertEq(app.written(), 1, "the app's counter rolled back");
        (bytes32 subject,,,,) = app.entries(2);
        assertEq(subject, bytes32(0), "no app entry");
        (uint64 a1, uint64 r1, uint64 b1, uint64 p1) = _counts();
        assertEq(a1, a0);
        assertEq(r1, r0);
        assertEq(b1, b0);
        assertEq(p1, p0);
        assertEq(_nonce(appPrincipal), 1, "nonce intact");
        // an empty body is the other refused shape
        vm.expectRevert(abi.encodeWithSelector(E_REJECTED.selector, uint8(1), appTypeId));
        app.write("", ROLE);
        // and the next accepted write lands at the intact nonce and counter
        (uint64 n,,, uint64 publication) = app.write("third", ROLE);
        assertEq(n, 2);
        assertEq(publication, 2);
    }

    function testAppRefusalRevertsTheLedger() public {
        NativeApp capped = _newApp(1);
        bytes32 cappedPrincipal = Keys.contractPrincipal(origin, address(capped));
        capped.write("within quota", ROLE);
        (uint64 a0,,, uint64 p0) = _counts();
        bytes32 secondSubject = Keys.subject(cappedPrincipal, bytes32(uint256(2)));
        // the ledger accepts the publication, then the app refuses after the call: both roll back
        vm.expectRevert(abi.encodeWithSelector(NativeApp.QuotaExceeded.selector, 2, 1));
        capped.write("over quota", ROLE);
        (uint64 a1,,, uint64 p1) = _counts();
        assertEq(a1, a0);
        assertEq(p1, p0);
        assertEq(_nonce(cappedPrincipal), 1, "nonce intact");
        assertEq(hot.subjectCreatedAt(secondSubject), 0, "the CREATE rolled back");
        (bytes32 typeId,,,,) = hot.recordHeader(Keys.record(appTypeId, "over quota"));
        assertEq(typeId, bytes32(0), "the PUBLISH rolled back");
        assertEq(capped.written(), 1);
    }

    function testForwardingWriterBecomesTheAuthor() public {
        vm.prank(ALICE, ALICE);
        (, bytes32 subject,, uint64 publication) = app.forward(BOB, "on behalf of bob", ROLE);
        Evidence memory e = _author(publication);
        assertEq(e.author, address(app), "the app called execute");
        assertEq(e.principalId, appPrincipal);
        assertEq(e.principalKind, 2, "a contract principal");
        (,,,, address requestedBy) = app.entries(1);
        assertEq(requestedBy, BOB, "app-level bookkeeping only");
        // the head exists under the app's principal and under neither EOA's
        (uint8 state,,,,,,) = hot.head(_headKey(appPrincipal, subject, ROLE));
        assertEq(state, 1);
        (state,,,,,,) = hot.head(_headKey(Keys.principal(ALICE), subject, ROLE));
        assertEq(state, 0);
        (state,,,,,,) = hot.head(_headKey(Keys.principal(BOB), subject, ROLE));
        assertEq(state, 0);
        assertEq(_nonce(Keys.principal(ALICE)), 0);
        assertEq(_nonce(Keys.principal(BOB)), 0);
        assertEq(_nonce(appPrincipal), 1);
    }

    function testEoaThroughTheAppAndDirectAreDifferentPrincipals() public {
        vm.prank(ALICE, ALICE);
        (,,, uint64 viaApp) = app.write("via the app", ROLE);
        // the same EOA straight to the ledger: the app forwards nothing, so the EOA is the author
        bytes32 alice = Keys.principal(ALICE);
        bytes32 salt = keccak256("alice/direct");
        Action[] memory actions = new Action[](3);
        actions[0] = EfsNative.createAction(salt);
        actions[1] = EfsNative.publishAction(appTypeId, "direct");
        actions[2] = EfsNative.bindAction(
            Coordinate(FOLDER, Keys.subject(alice, salt), ROLE), Keys.record(appTypeId, "direct"), 0
        );
        bytes[] memory bodies = new bytes[](3);
        bodies[1] = "direct";
        Native memory ctx = EfsNative.context(0, ledger.currentBind(actions));
        vm.prank(ALICE, ALICE);
        (uint64 direct,) = ledger.execute(actions, bodies, ctx, "");
        Evidence memory e1 = _author(viaApp);
        Evidence memory e2 = _author(direct);
        assertEq(e1.principalId, appPrincipal);
        assertEq(e2.principalId, alice);
        assertEq(e2.author, ALICE);
        assertEq(e2.principalKind, 1, "a key principal");
        assertTrue(e1.principalId != e2.principalId);
        assertEq(ledger.principalOf(ALICE), alice);
        assertEq(ledger.principalOf(address(app)), appPrincipal);
        assertEq(_nonce(alice), 1);
        assertEq(_nonce(appPrincipal), 1);
    }

    function testProxyHostedAppAuthorsAsTheProxy() public {
        NativeApp bare = new NativeApp(ILedger(address(0)), "", "", 0);
        assertEq(address(bare.ledger()), address(0), "an implementation with a zero ledger is bare");
        address proxy = address(
            new ERC1967Proxy(
                address(bare),
                abi.encodeCall(NativeApp.initialize, (ledger, descriptor, declarationSig, 10))
            )
        );
        NativeApp hosted = NativeApp(proxy);
        assertEq(hosted.typeId(), appTypeId, "idempotent registration: the shared Type");
        assertEq(registry.catalogCount(), 1);
        (,,, uint64 publication) = hosted.write("hosted", ROLE);
        bytes32 proxyPrincipal = Keys.contractPrincipal(origin, proxy);
        Evidence memory e = _author(publication);
        assertEq(e.author, proxy);
        assertEq(e.principalId, proxyPrincipal);
        assertEq(_nonce(proxyPrincipal), 1);
        assertEq(_nonce(Keys.contractPrincipal(origin, address(bare))), 0, "not the implementation");
        (bool present, bool bound,) = hosted.readBack(1);
        assertTrue(present && bound);
        assertEq(bare.written(), 0, "the implementation's storage is untouched");
    }

    function testTwoComposingApps() public {
        NativeApp a = app;
        NativeApp b = _newApp(100);
        bytes32 bPrincipal = Keys.contractPrincipal(origin, address(b));
        vm.prank(ALICE, ALICE);
        (uint64 bN, uint64 aN) = b.compose(a, "from b", "from a", ROLE);
        assertEq(bN, 1);
        assertEq(aN, 1);
        assertEq(_author(1).principalId, bPrincipal, "B's own write");
        assertEq(_author(2).principalId, appPrincipal, "A wrote as A, not as its caller B");
        assertEq(_author(2).author, address(a));
        (,,,, address requestedBy) = a.entries(1);
        assertEq(requestedBy, address(b));
        assertEq(_nonce(bPrincipal), 1);
        assertEq(_nonce(appPrincipal), 1);
        // A's refusal reverts B's write in the same transaction
        (uint64 a0,,, uint64 p0) = _counts();
        vm.expectRevert(abi.encodeWithSelector(E_REJECTED.selector, uint8(1), appTypeId));
        b.compose(a, "b again", hex"ff", ROLE);
        (uint64 a1,,, uint64 p1) = _counts();
        assertEq(a1, a0);
        assertEq(p1, p0);
        assertEq(b.written(), 1);
        assertEq(_nonce(bPrincipal), 1);
    }
}
