// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {AcceptContext, EXHAUSTED, IAcceptor, RefHeader} from "../../src/interfaces/IAcceptor.sol";
import {ITypeRegistry, TypeInfo} from "../../src/interfaces/ITypeRegistry.sol";
import {IRealmIndex} from "../../src/interfaces/IRealmIndex.sol";
import {IIndexReads} from "../../src/interfaces/IIndexReads.sol";
import {ILedger} from "../../src/interfaces/ILedger.sol";
import {ILedgerHot} from "../../src/interfaces/ILedgerHot.sol";
import {
    Action,
    ActionKind,
    FamilyId,
    Native,
    ScopeKey,
    TypeId
} from "../../src/interfaces/Actions.sol";
import {Effect, FamilyEntry, Readiness, Unit, WorkModel} from "../../src/interfaces/Index.sol";
import {Coverage, Phase} from "../../src/interfaces/Results.sol";
import {E_LEDGER, E_ORDER, E_PUBLICATION_ACTIVE, E_STAGED} from "../../src/interfaces/Errors.sol";
import {CodeScan} from "../../src/lib/CodeScan.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {
    MockCaller,
    MockRegistry,
    MockUnsupported,
    MutatingRegistry
} from "../harness/doubles/MockRegistry.sol";
import {
    ACCEPTOR_REFUSAL,
    AcceptAll,
    ContextAssertingAcceptor,
    ExhaustedAcceptor,
    GasBurner,
    MockAcceptor,
    ReentrantAcceptor,
    RejectAll,
    ReturndataBomb,
    RevertingAcceptor,
    ShapedReplyAcceptor
} from "../harness/doubles/Acceptors.sol";
import {
    AttackIndex,
    BudgetBurning,
    CALLBACK_PROFILE_3,
    IndexDoubleCore,
    LateRefusing,
    LegacyFallback,
    MalformedFinal,
    MutatingRule,
    OversizedCallback,
    PhaseRefusing,
    PrefixAgreement,
    WritingFinal
} from "../harness/doubles/IndexDoubles.sol";
import {
    ContractSignatureWallet,
    DelegatingPassthroughController,
    ERC1271_MAGIC,
    ERC1271_REFUSAL,
    MagicWallet,
    NativeCounterfeit,
    PassthroughController,
    ProxyAcceptor,
    Scoped7702Delegate
} from "../harness/doubles/Signers.sol";
import {FaultyReads} from "../harness/doubles/FaultyReads.sol";

/// A settable stand-in for the hot getters the doubles read, an `execute` that records its caller (or
/// refuses with the lock error while `locked`), and relays so a double sees this contract as its ledger.
contract HotStub {
    /// Relays forward a bounded amount, so an exceptional halt under STATICCALL (which consumes everything it
    /// is given) does not swallow the whole test gas limit.
    uint256 internal constant RELAY_GAS = 10_000_000;

    struct RecordRow {
        bytes32 typeId;
        uint64 firstAdmission;
        uint32 length;
        uint64 occurrences;
    }

    struct HeadRow {
        uint8 state;
        uint64 revision;
        uint64 admission;
        uint64 bindingOrdinal;
        bytes32 target;
    }

    uint8 internal _phase;
    uint64 internal _staged;
    uint64[4] internal _counts;
    mapping(bytes32 => uint64) internal _created;
    mapping(bytes32 => RecordRow) internal _records;
    mapping(bytes32 => HeadRow) internal _heads;
    bool public locked;
    uint256 public executions;
    address public lastExecutor;
    uint256 public lastExecutorCodeSize;

    function setPhase(uint8 p, uint64 staged) external {
        _phase = p;
        _staged = staged;
    }

    function setCounts(uint64 a, uint64 r, uint64 b, uint64 p) external {
        _counts = [a, r, b, p];
    }

    function setCreated(bytes32 subjectId, uint64 admission) external {
        _created[subjectId] = admission;
    }

    function setRecord(bytes32 id, RecordRow calldata row) external {
        _records[id] = row;
    }

    function setHead(bytes32 key, HeadRow calldata row) external {
        _heads[key] = row;
    }

    function setLocked(bool on) external {
        locked = on;
    }

    function counts() external view returns (uint64, uint64, uint64, uint64) {
        return (_counts[0], _counts[1], _counts[2], _counts[3]);
    }

    function phase() external view returns (uint8, uint64, uint64, uint32) {
        return (_phase, _staged, _counts[0], 1);
    }

    function subjectCreatedAt(bytes32 subjectId) external view returns (uint64) {
        return _created[subjectId];
    }

    function recordHeader(bytes32 id)
        external
        view
        returns (bytes32, uint64, uint32, uint64, uint8)
    {
        RecordRow storage r = _records[id];
        return (r.typeId, r.firstAdmission, r.length, r.occurrences, 1);
    }

    function head(bytes32 key)
        external
        view
        returns (uint8, uint64, uint64, uint8, uint64, uint64, bytes32)
    {
        HeadRow storage h = _heads[key];
        return (
            h.state,
            h.revision,
            h.admission,
            1,
            0,
            h.bindingOrdinal,
            h.state == 1 ? h.target : bytes32(0)
        );
    }

    function execute(Action[] calldata, bytes[] calldata, Native calldata, bytes calldata)
        external
        returns (uint64, uint64)
    {
        if (locked) revert E_PUBLICATION_ACTIVE();
        ++executions;
        lastExecutor = msg.sender;
        lastExecutorCodeSize = msg.sender.code.length;
        return (uint64(executions), 1);
    }

    function relay(address target, bytes calldata data)
        external
        returns (bool ok, bytes memory ret)
    {
        (ok, ret) = target.call{gas: RELAY_GAS}(data);
    }

    function relayGas(address target, bytes calldata data, uint256 gasLimit)
        external
        returns (bool ok, bytes memory ret, uint256 used)
    {
        uint256 before = gasleft();
        (ok, ret) = target.call{gas: gasLimit}(data);
        used = before - gasleft();
    }

    function staticRelay(address target, bytes calldata data)
        external
        view
        returns (bool ok, bytes memory ret)
    {
        (ok, ret) = target.staticcall{gas: RELAY_GAS}(data);
    }
}

/// @notice Every double of test/harness/doubles/ deployed and driven without a kernel: the reply shapes the
///         kernel's laws classify, the configurable behaviours, and the refusals the doubles themselves apply.
contract DoublesTest is Test {
    HotStub internal hot;

    function setUp() public {
        hot = new HotStub();
    }

    // ---- helpers ----------------------------------------------------------------------------------------------

    /// The kernel's acceptor call shape (§6.4): assembly STATICCALL into a 32-byte output buffer.
    function acceptCall(
        address acceptor,
        AcceptContext memory ctx,
        bytes memory body,
        bytes32[] memory refs,
        RefHeader[] memory headers,
        uint256 gasLimit
    ) internal view returns (bool ok, uint256 size, bytes32 word, uint256 used) {
        bytes memory data = abi.encodeCall(IAcceptor.accept, (ctx, body, refs, headers));
        uint256 before = gasleft();
        assembly ("memory-safe") {
            mstore(0, 0)
            ok := staticcall(gasLimit, acceptor, add(data, 0x20), mload(data), 0, 0x20)
            size := returndatasize()
            word := mload(0)
        }
        used = before - gasleft();
    }

    function acceptCall(address acceptor, AcceptContext memory ctx, bytes memory body)
        internal
        view
        returns (bool ok, uint256 size, bytes32 word, uint256 used)
    {
        return acceptCall(acceptor, ctx, body, new bytes32[](0), new RefHeader[](0), 1_000_000);
    }

    /// The success law: exactly 32 bytes equal to the left-aligned selector.
    function accepted(bool ok, uint256 size, bytes32 word) internal pure returns (bool) {
        return ok && size == 32 && word == bytes32(IAcceptor.accept.selector);
    }

    function ctxFor(bytes32 typeId) internal view returns (AcceptContext memory c) {
        c.typeId = typeId;
        c.realmId = keccak256("realm");
        c.principalId = keccak256("principal");
        c.admission = 7;
        c.revision = 1;
        c.grade = 1;
        c.leaf = 0;
        c.ledger = address(this);
        c.index = address(0x1d);
        c.registry = address(0x2e);
    }

    function one(Effect memory e) internal pure returns (Effect[] memory es) {
        es = new Effect[](1);
        es[0] = e;
    }

    function effect(uint8 kind, uint64 admission, uint64 publication)
        internal
        pure
        returns (Effect memory e)
    {
        e.kind = kind;
        e.admission = admission;
        e.publication = publication;
        e.principalId = keccak256("principal");
    }

    function prefixCall(uint64 publication, Effect[] memory es)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeCall(IRealmIndex.onAdmission, (publication, es, new bytes32[](0)));
    }

    function finalCall(uint64 publication, Effect[] memory es)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeCall(IRealmIndex.afterPublication, (publication, es, new bytes32[](0)));
    }

    function isAck(bool ok, bytes memory ret, bytes4 selector) internal pure returns (bool) {
        return ok && ret.length == 32 && bytes32(ret) == bytes32(selector);
    }

    /// A typed read through the interface, external so a decode failure is a revert of this call.
    function typedCounts(ILedgerHot h) external view returns (uint64 a) {
        (a,,,) = h.counts();
    }

    // ---- MockRegistry / MutatingRegistry ----------------------------------------------------------------------

    function test_registry_hot_reads_round_trip() public {
        MockRegistry r = new MockRegistry();
        bytes32 t = keccak256("type");
        TypeInfo memory info = TypeInfo({
            grade: 2,
            refCount: 1,
            wrapperVersion: 1,
            ruleMode: 1,
            dependencyClass: 2,
            refHeaderWords: 3,
            validationGas: 123_456,
            policyRows: 2,
            mandatory: address(0xa1),
            ruleId: keccak256("rule"),
            shape: keccak256("shape"),
            descriptorBlob: address(0xb1),
            policy: address(0xc1),
            policyCodehash: keccak256("policy"),
            policyRow: 1,
            custom: address(0xd1),
            bindingId: keccak256("binding")
        });
        bytes32[] memory refs = new bytes32[](2);
        refs[0] = keccak256("parent");
        refs[1] = bytes32(uint256(1)); // SELF sentinel
        r.setType(t, info, refs);
        assertEq(keccak256(abi.encode(r.typeInfo(t))), keccak256(abi.encode(info)));
        assertEq(keccak256(abi.encode(r.refTypes(t))), keccak256(abi.encode(refs)));
        TypeInfo memory none;
        assertEq(
            keccak256(abi.encode(r.typeInfo(keccak256("unknown")))), keccak256(abi.encode(none))
        );
        assertEq(r.refTypes(keccak256("unknown")).length, 0);

        (bytes32 expected, uint16 row) = r.roleExpectation("p", "r");
        assertEq(expected, 0);
        assertEq(row, 0);
        r.setRoleExpectation("p", "r", t, 3);
        (expected, row) = r.roleExpectation("p", "r");
        assertEq(expected, t);
        assertEq(row, 3);

        assertEq(r.mutations(), 0);
        r.bumpMutations();
        r.bumpMutations();
        assertEq(r.mutations(), 2);
        r.setActiveRevision(4);
        assertEq(r.activeRevision(), 4);
        r.setLedger(address(hot));
        assertEq(r.ledger(), address(hot));
        r.setImplementation(address(0x1234));
        assertEq(r.implementation(), address(0x1234));
    }

    function test_registry_unsupported_selectors_revert_MockUnsupported() public {
        MockRegistry r = new MockRegistry();
        bytes[] memory calls = new bytes[](17);
        calls[0] = abi.encodeCall(ITypeRegistry.retainDeclaration, ("", ""));
        calls[1] = abi.encodeCall(ITypeRegistry.registerDescribed, ("", "", address(0), ""));
        calls[2] = abi.encodeCall(ITypeRegistry.activatePolicy, (bytes32(0), address(0)));
        calls[3] = abi.encodeCall(ITypeRegistry.declareRoleExpectation, (0, 0, 0));
        calls[4] = abi.encodeCall(ITypeRegistry.activateWrapper, (1, address(0)));
        calls[5] = abi.encodeCall(ITypeRegistry.initialize, (address(0), address(0)));
        calls[6] = abi.encodeCall(ITypeRegistry.activate, (1));
        calls[7] = abi.encodeCall(ITypeRegistry.catalog, (0));
        calls[8] = abi.encodeCall(ITypeRegistry.catalogCount, ());
        calls[9] = abi.encodeCall(ITypeRegistry.descriptorBytes, (0));
        calls[10] = abi.encodeCall(ITypeRegistry.declaration, (0));
        calls[11] = abi.encodeCall(ITypeRegistry.policy, (0, 0));
        calls[12] = abi.encodeCall(ITypeRegistry.roleRow, (0, 0, 0));
        calls[13] = abi.encodeCall(ITypeRegistry.roleRows, (0, 0));
        calls[14] = abi.encodeCall(ITypeRegistry.wrapper, (1));
        calls[15] = abi.encodeCall(ITypeRegistry.binding, (0));
        calls[16] = abi.encodeCall(ITypeRegistry.typeCommitment, (0));
        for (uint256 i; i < calls.length; ++i) {
            (bool ok, bytes memory err) = address(r).call(calls[i]);
            assertFalse(ok);
            assertEq(err, abi.encodeWithSelector(MockUnsupported.selector, bytes4(calls[i])));
        }
    }

    function test_registry_writes_are_owner_only_and_bumps_need_allowance() public {
        MockRegistry r = new MockRegistry();
        address stranger = address(0xbad);
        TypeInfo memory info;
        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(MockCaller.selector, stranger));
        r.setType("t", info, new bytes32[](0));
        vm.expectRevert(abi.encodeWithSelector(MockCaller.selector, stranger));
        r.setRoleExpectation("p", "r", "t", 1);
        vm.expectRevert(abi.encodeWithSelector(MockCaller.selector, stranger));
        r.bumpMutations();
        vm.stopPrank();
        r.setMutator(stranger, true);
        vm.prank(stranger);
        r.bumpMutations();
        assertEq(r.mutations(), 1);
    }

    function test_mutating_registry_counter_moves_with_the_ledger_admission_frontier() public {
        MutatingRegistry r = new MutatingRegistry();
        assertEq(r.mutations(), 0, "no ledger yet");
        r.setLedger(address(hot));
        hot.setCounts(5, 0, 0, 1);
        assertEq(r.mutations(), 5);
        hot.setCounts(6, 0, 0, 1); // a leaf checkpointed: the per-leaf re-check would see drift
        assertEq(r.mutations(), 6);
        r.bumpMutations();
        assertEq(r.mutations(), 7);
        r.arm(false);
        assertEq(r.mutations(), 1);
    }

    // ---- acceptors ---------------------------------------------------------------------------------------------

    function test_acceptor_reply_shapes_under_the_32_byte_buffer_law() public {
        AcceptContext memory c = ctxFor("t");
        bool ok;
        uint256 size;
        bytes32 word;
        uint256 used;

        (ok, size, word,) = acceptCall(address(new AcceptAll()), c, "");
        assertTrue(accepted(ok, size, word), "AcceptAll");

        (ok, size, word,) = acceptCall(address(new RejectAll()), c, "");
        assertTrue(ok && size == 32 && word == bytes32(ACCEPTOR_REFUSAL), "RejectAll refusal word");

        bytes memory forged = abi.encodeWithSignature("E_NONCE(bytes32,uint64,uint64)", 0, 1, 2);
        (ok, size,,) = acceptCall(address(new RevertingAcceptor(forged)), c, "");
        assertTrue(!ok && size == forged.length, "reverting with forged data");

        (ok, size,, used) = acceptCall(
            address(new RevertingAcceptor("")), c, "", new bytes32[](0), new RefHeader[](0), 300_000
        );
        assertTrue(!ok && size == 0 && used < 20_000, "empty revert that used little gas");

        (ok, size, word,) = acceptCall(address(new ReturndataBomb()), c, "");
        assertTrue(ok && size == 65_536 && word == bytes32(IAcceptor.accept.selector), "bomb");
        assertFalse(accepted(ok, size, word), "the size law refuses the bomb");

        (ok, size,, used) = acceptCall(
            address(new GasBurner()), c, "", new bytes32[](0), new RefHeader[](0), 300_000
        );
        assertTrue(!ok && size == 0 && used >= 300_000, "burner exhausts what it is given");

        (ok, size, word,) = acceptCall(address(new ExhaustedAcceptor()), c, "");
        assertTrue(ok && size == 32 && word == EXHAUSTED, "EXHAUSTED word");

        bytes32 sel = bytes32(IAcceptor.accept.selector);
        (ok, size, word,) = acceptCall(address(new ShapedReplyAcceptor(sel, 4)), c, "");
        assertTrue(ok && size == 4 && !accepted(ok, size, word), "selector in 4 bytes");
        (ok, size, word,) =
            acceptCall(address(new ShapedReplyAcceptor(sel | bytes32(uint256(1)), 32)), c, "");
        assertTrue(ok && size == 32 && !accepted(ok, size, word), "dirty selector word");
        (ok, size, word,) = acceptCall(address(new ShapedReplyAcceptor(sel, 64)), c, "");
        assertTrue(ok && size == 64 && word == sel && !accepted(ok, size, word), "selector + extra");
        (ok, size, word,) = acceptCall(address(new ShapedReplyAcceptor(sel, 32)), c, "");
        assertTrue(accepted(ok, size, word), "the exact shape is the only success");
    }

    function test_context_asserting_acceptor_pins_ledger_type_and_digest() public {
        bytes32 t = keccak256("type");
        AcceptContext memory c = ctxFor(t);
        bool ok;
        uint256 size;
        bytes32 word;

        ContextAssertingAcceptor typeOnly = new ContextAssertingAcceptor(t, 0);
        (ok, size, word,) = acceptCall(address(typeOnly), c, "body");
        assertTrue(accepted(ok, size, word), "ledger == msg.sender and type match");
        c.ledger = address(0x1ed6e7);
        (ok, size, word,) = acceptCall(address(typeOnly), c, "body");
        assertTrue(ok && word == bytes32(ACCEPTOR_REFUSAL), "forged ctx.ledger refused");
        c = ctxFor(keccak256("other"));
        (ok, size, word,) = acceptCall(address(typeOnly), c, "body");
        assertTrue(ok && word == bytes32(ACCEPTOR_REFUSAL), "wrong type refused");

        c = ctxFor(t);
        bytes32[] memory refs = new bytes32[](1);
        refs[0] = keccak256("parent");
        RefHeader[] memory headers = new RefHeader[](1);
        headers[0] = RefHeader(keccak256("parentType"), 3, 64, keccak256("w0"), 0, 0);
        bytes32 digest = keccak256(abi.encode(c, bytes("body"), refs, headers));
        ContextAssertingAcceptor exact = new ContextAssertingAcceptor(t, digest);
        assertEq(exact.digestOf(c, "body", refs, headers), digest);
        (ok, size, word,) = acceptCall(address(exact), c, "body", refs, headers, 1_000_000);
        assertTrue(accepted(ok, size, word), "exact context");
        c.admission += 1;
        (ok, size, word,) = acceptCall(address(exact), c, "body", refs, headers, 1_000_000);
        assertTrue(ok && word == bytes32(ACCEPTOR_REFUSAL), "one field changed");
        c.admission -= 1;
        headers[0].word1 = bytes32(uint256(1)); // an undeclared header word must be zero
        (ok, size, word,) = acceptCall(address(exact), c, "body", refs, headers, 1_000_000);
        assertTrue(ok && word == bytes32(ACCEPTOR_REFUSAL), "one header word changed");
    }

    function test_reentrant_acceptor_succeeds_only_when_its_reentry_reverts() public {
        ReentrantAcceptor a = new ReentrantAcceptor();
        assertEq(ReentrantAcceptor.accept.selector, IAcceptor.accept.selector);
        AcceptContext memory c = ctxFor("t");
        c.ledger = address(hot);
        // STATICCALL (the kernel's shape): the re-entered execute cannot write, so it reverts.
        (bool ok, uint256 size, bytes32 word,) = acceptCall(address(a), c, "");
        assertTrue(accepted(ok, size, word), "re-entry under STATICCALL fails");
        assertEq(hot.executions(), 0);
        // CALL (what the kernel must never do): the re-entry lands and the double refuses.
        (bool called, bytes memory ret) = address(a)
            .call(abi.encodeCall(IAcceptor.accept, (c, "", new bytes32[](0), new RefHeader[](0))));
        assertTrue(called && bytes4(ret) == ACCEPTOR_REFUSAL, "re-entry under CALL lands");
        assertEq(hot.executions(), 1);
        assertEq(hot.lastExecutor(), address(a));
        // A locked ledger refuses the re-entry even under CALL.
        hot.setLocked(true);
        (called, ret) = address(a)
            .call(abi.encodeCall(IAcceptor.accept, (c, "", new bytes32[](0), new RefHeader[](0))));
        assertTrue(called && bytes4(ret) == IAcceptor.accept.selector, "lock refusal");
    }

    function test_mock_acceptor_policy_modes() public {
        MockAcceptor m = new MockAcceptor();
        AcceptContext memory c = ctxFor("t");
        bool ok;
        uint256 size;
        bytes32 word;
        uint256 used;
        (ok, size, word,) = acceptCall(address(m), c, "");
        assertTrue(accepted(ok, size, word), "ACCEPT");
        m.set(m.ACCEPT(), 4);
        (ok, size, word,) = acceptCall(address(m), c, "abc");
        assertTrue(ok && word == bytes32(ACCEPTOR_REFUSAL), "below minBody");
        (ok, size, word,) = acceptCall(address(m), c, "abcd");
        assertTrue(accepted(ok, size, word), "at minBody");
        c.ledger = address(0xfeed);
        (ok, size, word,) = acceptCall(address(m), c, "abcd");
        assertTrue(ok && word == bytes32(ACCEPTOR_REFUSAL), "context law in ACCEPT");
        c = ctxFor("t");
        m.set(m.REJECT(), 0);
        (ok, size, word,) = acceptCall(address(m), c, "");
        assertTrue(ok && size == 32 && word == bytes32(ACCEPTOR_REFUSAL), "REJECT");
        m.set(m.REVERT(), 0);
        (ok, size,,) = acceptCall(address(m), c, "");
        assertTrue(!ok && size == 36, "REVERT carries MockAcceptorRefused(typeId)");
        m.set(m.LOOP(), 0);
        (ok, size,, used) =
            acceptCall(address(m), c, "", new bytes32[](0), new RefHeader[](0), 200_000);
        assertTrue(!ok && size == 0 && used >= 200_000, "LOOP exhausts");
        m.set(m.EXHAUST(), 0);
        (ok, size, word,) = acceptCall(address(m), c, "");
        assertTrue(ok && size == 32 && word == EXHAUSTED, "EXHAUST");
    }

    function test_proxy_acceptor_answers_but_is_not_a_plain_runtime() public {
        AcceptAll impl = new AcceptAll();
        ProxyAcceptor p = new ProxyAcceptor(address(impl));
        bytes32 slot = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
        assertEq(address(uint160(uint256(vm.load(address(p), slot)))), address(impl));
        (bool ok, uint256 size, bytes32 word,) = acceptCall(address(p), ctxFor("t"), "");
        assertTrue(accepted(ok, size, word), "the proxy forwards accept");
        assertEq(CodeScan.scan(address(p).code), 3, "ERC1967Proxy delegates: forbidden opcode");
        assertEq(CodeScan.scan(address(impl).code), 0, "AcceptAll is plain");
    }

    // ---- index doubles -----------------------------------------------------------------------------------------

    function test_prefix_agreement_checks_the_staged_prefix_and_acks() public {
        PrefixAgreement idx = new PrefixAgreement(address(hot));
        bytes32 subjectId = keccak256("subject");
        Effect memory e = effect(ActionKind.CREATE, 1, 1);
        e.subjectId = subjectId;

        hot.setPhase(Phase.APPLYING, 1);
        hot.setCounts(1, 0, 0, 0);
        hot.setCreated(subjectId, 1);
        (bool ok, bytes memory ret) = hot.relay(address(idx), prefixCall(1, one(e)));
        assertTrue(isAck(ok, ret, IRealmIndex.onAdmission.selector), "agreeing prefix acks");
        assertEq(idx.prefixCalls(), 1);
        assertEq(idx.lastProcessed(), 1);
        assertEq(idx.lastPublication(), 1);
        assertEq(idx.effectsSeen(), 1);
        assertEq(
            idx.prefixDigest(),
            keccak256(abi.encode(bytes32(0), uint64(1), one(e), new bytes32[](0)))
        );

        (ok, ret) = hot.relay(address(idx), prefixCall(1, one(e)));
        assertEq(
            ret, abi.encodeWithSelector(E_ORDER.selector, uint64(2), uint64(1)), "replayed effect"
        );

        Effect memory b = effect(ActionKind.BIND, 2, 1);
        b.position = keccak256("position");
        b.target = keccak256("target");
        b.revision = 1;
        b.bindingOrdinal = 1;
        hot.setCounts(2, 0, 1, 0);
        hot.setHead(Keys.binding(b.principalId, b.position), HotStub.HeadRow(1, 1, 2, 1, b.target));
        (ok, ret) = hot.relay(address(idx), prefixCall(2, one(b)));
        assertEq(
            ret,
            abi.encodeWithSelector(E_STAGED.selector, uint64(1), uint64(2)),
            "unstaged publication"
        );
        (ok, ret) = hot.relay(address(idx), prefixCall(1, one(b)));
        assertTrue(isAck(ok, ret, IRealmIndex.onAdmission.selector), "bind agrees with the head");

        Effect memory p = effect(ActionKind.PUBLISH, 3, 1);
        p.typeId = keccak256("type");
        p.recordId = keccak256("record");
        p.freshRecord = true;
        hot.setCounts(3, 1, 1, 0);
        hot.setRecord(p.recordId, HotStub.RecordRow(p.typeId, 2, 32, 1)); // first admission 2 != 3
        (ok, ret) = hot.relay(address(idx), prefixCall(1, one(p)));
        assertEq(
            ret,
            abi.encodeWithSelector(PrefixAgreement.E_PREFIX_DIVERGED.selector, uint8(3), uint64(3))
        );
        hot.setRecord(p.recordId, HotStub.RecordRow(p.typeId, 3, 32, 1));
        (ok, ret) = hot.relay(address(idx), prefixCall(1, one(p)));
        assertTrue(isAck(ok, ret, IRealmIndex.onAdmission.selector), "fresh record agrees");

        hot.setPhase(Phase.IDLE, 0);
        (ok, ret) = hot.relay(address(idx), prefixCall(1, one(effect(ActionKind.CREATE, 4, 1))));
        assertEq(
            ret,
            abi.encodeWithSelector(PrefixAgreement.E_PREFIX_DIVERGED.selector, uint8(1), uint64(0))
        );

        (ok, ret) = hot.staticRelay(address(idx), finalCall(1, one(e)));
        assertTrue(isAck(ok, ret, IRealmIndex.afterPublication.selector), "final ack shape");
        vm.expectRevert(E_LEDGER.selector);
        idx.onAdmission(1, one(e), new bytes32[](0));
        vm.expectRevert(E_LEDGER.selector);
        idx.afterPublication(1, one(e), new bytes32[](0));
    }

    function test_phase_refusing_requires_APPLYING_then_FINAL() public {
        PhaseRefusing idx = new PhaseRefusing(address(hot), 0, false);
        Effect[] memory es = one(effect(ActionKind.CREATE, 1, 1));
        hot.setPhase(Phase.IDLE, 0);
        (bool ok, bytes memory ret) = hot.relay(address(idx), prefixCall(1, es));
        assertEq(
            ret, abi.encodeWithSelector(PhaseRefusing.E_PHASE.selector, Phase.APPLYING, Phase.IDLE)
        );
        hot.setPhase(Phase.APPLYING, 1);
        (ok, ret) = hot.relay(address(idx), prefixCall(1, es));
        assertTrue(isAck(ok, ret, IRealmIndex.onAdmission.selector));
        (ok, ret) = hot.staticRelay(address(idx), finalCall(1, es));
        assertEq(
            ret, abi.encodeWithSelector(PhaseRefusing.E_PHASE.selector, Phase.FINAL, Phase.APPLYING)
        );
        hot.setPhase(Phase.FINAL, 1);
        (ok, ret) = hot.staticRelay(address(idx), finalCall(1, es));
        assertTrue(isAck(ok, ret, IRealmIndex.afterPublication.selector), "final in FINAL acks");

        PhaseRefusing prefixRefuser = new PhaseRefusing(address(hot), 1, false);
        hot.setPhase(Phase.APPLYING, 1);
        (ok, ret) = hot.relay(address(prefixRefuser), prefixCall(1, es));
        assertEq(ret, abi.encodeWithSelector(PhaseRefusing.E_PREFIX.selector, uint64(1)));
        PhaseRefusing finalRefuser = new PhaseRefusing(address(hot), 0, true);
        hot.setPhase(Phase.FINAL, 1);
        (ok, ret) = hot.staticRelay(address(finalRefuser), finalCall(1, es));
        assertEq(ret, abi.encodeWithSelector(PhaseRefusing.E_FINAL.selector));
    }

    function test_legacy_fallback_and_malformed_final_reply_shapes() public {
        Effect[] memory es = one(effect(ActionKind.CREATE, 1, 1));
        LegacyFallback legacy = new LegacyFallback(address(hot));
        (bool ok, bytes memory ret) = hot.relay(address(legacy), prefixCall(1, es));
        assertTrue(isAck(ok, ret, IRealmIndex.onAdmission.selector), "legacy prefix acks");
        (ok, ret) = hot.staticRelay(address(legacy), finalCall(1, es));
        assertTrue(ok && ret.length == 32 && bytes32(ret) == 0, "fallback answers 32 zero bytes");
        assertEq(IRealmIndex(address(legacy)).replayReadiness().callbackProfile, CALLBACK_PROFILE_3);

        uint256[4] memory lengths = [uint256(33), 31, 4, 64];
        for (uint256 i; i < lengths.length; ++i) {
            MalformedFinal bad = new MalformedFinal(address(hot), lengths[i]);
            (ok, ret) = hot.staticRelay(address(bad), finalCall(1, es));
            assertTrue(ok && ret.length == lengths[i], "malformed length");
            assertFalse(isAck(ok, ret, IRealmIndex.afterPublication.selector));
            assertEq(bytes4(ret), IRealmIndex.afterPublication.selector, "selector-shaped prefix");
        }
    }

    function test_writing_final_fails_only_under_STATICCALL() public {
        Effect[] memory es = one(effect(ActionKind.CREATE, 1, 1));
        assertEq(WritingFinal.afterPublication.selector, IRealmIndex.afterPublication.selector);
        WritingFinal direct = new WritingFinal(address(hot), false);
        (bool ok, bytes memory ret) = hot.staticRelay(address(direct), finalCall(1, es));
        assertTrue(!ok && ret.length == 0, "SSTORE under STATICCALL halts with no data");
        (ok, ret) = hot.relay(address(direct), finalCall(1, es));
        assertTrue(isAck(ok, ret, IRealmIndex.afterPublication.selector), "writes under CALL");
        assertEq(direct.finalWrites(), 1);

        WritingFinal nested = new WritingFinal(address(hot), true);
        (ok, ret) = hot.staticRelay(address(nested), finalCall(1, es));
        assertEq(
            ret, abi.encodeWithSelector(WritingFinal.E_FINAL_WRITE.selector), "reported failure"
        );
        (ok, ret) = hot.relay(address(nested), finalCall(1, es));
        assertTrue(isAck(ok, ret, IRealmIndex.afterPublication.selector));
        assertEq(nested.finalWrites(), 1);
    }

    function test_oversized_callback_returns_or_reverts_4097_bytes() public {
        Effect[] memory es = one(effect(ActionKind.CREATE, 1, 1));
        OversizedCallback reverting = new OversizedCallback(address(hot), 4097, true);
        (bool ok, bytes memory ret) = hot.relay(address(reverting), prefixCall(1, es));
        assertTrue(
            !ok && ret.length == 4097 && bytes4(ret) == OversizedCallback.E_OVERSIZED.selector
        );
        assertEq(reverting.touched(), 0, "its write rolled back");
        OversizedCallback returning = new OversizedCallback(address(hot), 4097, false);
        (ok, ret) = hot.relay(address(returning), prefixCall(1, es));
        assertTrue(ok && ret.length == 4097 && bytes4(ret) == IRealmIndex.onAdmission.selector);
        assertEq(returning.touched(), 1);
        (ok, ret) = hot.staticRelay(address(returning), finalCall(1, es));
        assertTrue(
            isAck(ok, ret, IRealmIndex.afterPublication.selector), "its final call is honest"
        );
    }

    function test_budget_burning_spends_all_or_a_fixed_amount() public {
        Effect[] memory es = one(effect(ActionKind.CREATE, 1, 1));
        BudgetBurning all = new BudgetBurning(address(hot), type(uint256).max, 0);
        (bool ok, bytes memory ret, uint256 used) =
            hot.relayGas(address(all), prefixCall(1, es), 300_000);
        assertTrue(
            !ok && ret.length == 0 && used >= 300_000, "ALL burns everything, returns nothing"
        );
        BudgetBurning fixedBurn = new BudgetBurning(address(hot), 100_000, 50_000);
        (ok, ret, used) = hot.relayGas(address(fixedBurn), prefixCall(1, es), 1_000_000);
        assertTrue(
            isAck(ok, ret, IRealmIndex.onAdmission.selector) && used >= 100_000, "fixed prefix burn"
        );
        uint256 before = gasleft();
        (ok, ret) = hot.staticRelay(address(fixedBurn), finalCall(1, es));
        assertTrue(
            isAck(ok, ret, IRealmIndex.afterPublication.selector) && before - gasleft() >= 50_000
        );
    }

    function test_attack_index_records_lock_refusals_and_flags_bypasses() public {
        Effect[] memory es = one(effect(ActionKind.CREATE, 1, 1));
        AttackIndex idx = new AttackIndex(address(hot));
        hot.setLocked(true);
        idx.addAttempt(address(hot), idx.reentryCalldata(), E_PUBLICATION_ACTIVE.selector);
        assertEq(idx.attempts(), 2);
        (bool ok, bytes memory ret) = hot.relay(address(idx), prefixCall(1, es));
        assertTrue(isAck(ok, ret, IRealmIndex.onAdmission.selector), "locked ledger refuses both");
        assertEq(idx.prefixAttempts(), 2);
        assertEq(idx.prefixRefusals(), 2);
        (ok, ret) = hot.staticRelay(address(idx), finalCall(1, es));
        assertTrue(isAck(ok, ret, IRealmIndex.afterPublication.selector), "static attempts refused");

        hot.setLocked(false);
        (ok, ret) = hot.relay(address(idx), prefixCall(1, es));
        assertTrue(
            !ok && bytes4(ret) == AttackIndex.AttackBypassed.selector,
            "an unlocked re-entry is flagged"
        );
        assertEq(hot.executions(), 0, "and rolled back");
        (ok, ret) = hot.staticRelay(address(idx), finalCall(1, es));
        assertTrue(
            !ok && bytes4(ret) == AttackIndex.AttackBypassed.selector, "final bypass flagged"
        );
        idx.setStrict(false);
        (ok, ret) = hot.relay(address(idx), prefixCall(1, es));
        assertTrue(isAck(ok, ret, IRealmIndex.onAdmission.selector));
        assertEq(idx.prefixAttempts(), 4);
        assertEq(idx.prefixRefusals(), 2, "non-strict: recorded, not refused");
        assertEq(hot.executions(), 2);
    }

    function test_late_refusing_acks_prefix_and_refuses_final() public {
        Effect memory bind = effect(ActionKind.BIND, 1, 1);
        bind.position = keccak256("tag-position");
        bytes32 key = Keys.binding(bind.principalId, bind.position);
        Effect[] memory es = one(bind);

        LateRefusing always = new LateRefusing(address(hot), 0);
        (bool ok, bytes memory ret) = hot.relay(address(always), prefixCall(1, es));
        assertTrue(isAck(ok, ret, IRealmIndex.onAdmission.selector));
        (ok, ret) = hot.staticRelay(address(always), finalCall(1, es));
        assertEq(ret, abi.encodeWithSelector(LateRefusing.E_LATE_INDEX.selector, bytes32(0)));

        LateRefusing poisoned = new LateRefusing(address(hot), key);
        (ok, ret) = hot.staticRelay(address(poisoned), finalCall(1, es));
        assertEq(ret, abi.encodeWithSelector(LateRefusing.E_LATE_INDEX.selector, key));
        (ok, ret) =
            hot.staticRelay(address(poisoned), finalCall(1, one(effect(ActionKind.CREATE, 1, 1))));
        assertTrue(
            isAck(ok, ret, IRealmIndex.afterPublication.selector), "unpoisoned publication acks"
        );
    }

    function test_mutating_rule_bumps_only_when_the_registry_allows() public {
        Effect[] memory es = one(effect(ActionKind.CREATE, 1, 1));
        MockRegistry r = new MockRegistry();
        MutatingRule idx = new MutatingRule(address(hot), address(r));
        (bool ok, bytes memory ret) = hot.relay(address(idx), prefixCall(1, es));
        assertTrue(isAck(ok, ret, IRealmIndex.onAdmission.selector));
        assertEq(idx.bumpRefusals(), 1);
        assertEq(r.mutations(), 0, "refused without allowance");
        r.setMutator(address(idx), true);
        (ok, ret) = hot.relay(address(idx), prefixCall(1, es));
        assertTrue(isAck(ok, ret, IRealmIndex.onAdmission.selector));
        assertEq(idx.bumps(), 1);
        assertEq(r.mutations(), 1, "the basis moved from inside the callback");
        idx.setRegistry(address(0));
        (ok, ret) = hot.relay(address(idx), prefixCall(1, es));
        assertTrue(isAck(ok, ret, IRealmIndex.onAdmission.selector));
        assertEq(idx.bumpRefusals(), 2, "code-less registry counted, not trapped");
    }

    function test_index_double_reads_readiness_and_guards() public {
        PrefixAgreement idx = new PrefixAgreement(address(hot));
        assertEq(idx.ledger(), address(hot));
        WorkModel memory w = idx.workModel();
        assertEq(w.formulaVersion, 1);
        assertEq(w.freshPerPublication, 2);
        assertEq(w.rwPerPublication, 10);
        assertEq(w.freshPerPublishFresh, 10);
        assertEq(w.rwPerPublish, 50);
        assertEq(w.freshPerBindFresh, 30);
        assertEq(w.rwPerBind, 40);
        assertEq(w.freshPerRef, 10);
        assertEq(w.freshPerDigestSpec, 10);
        assertEq(w.computeBase, 60_000);
        assertEq(w.computePerAction, 25_000);
        assertEq(w.computePerHookEffect, 60_000);
        assertEq(w.finalComputeBase, 60_000);
        assertEq(w.finalComputePerBind, 120_000);

        FamilyId family = FamilyId.wrap(Keys.familyId("by-type"));
        ScopeKey scope = ScopeKey.wrap(keccak256("scope"));
        (Coverage cov, uint64 from, uint64 through, uint8 phase) = idx.coverage(family, scope);
        assertEq(uint8(cov), uint8(Coverage.UNKNOWN), "default is UNKNOWN, never UNSET or COMPLETE");
        idx.setCoverage(
            abi.encodeCall(IIndexReads.coverage, (family, scope)),
            IndexDoubleCore.CoverageAnswer(Coverage.COMPLETE, 1, 9, Phase.APPLYING)
        );
        (cov, from, through, phase) = idx.coverage(family, scope);
        assertEq(uint8(cov), uint8(Coverage.COMPLETE));
        assertEq(from, 1);
        assertEq(through, 9);
        assertEq(phase, Phase.APPLYING);
        (cov,,,) = idx.coverage(family, ScopeKey.wrap(keccak256("other")));
        assertEq(uint8(cov), uint8(Coverage.UNKNOWN), "answers are per exact query");
        (cov,,,) = idx.coverageOfType(family, TypeId.wrap(keccak256("scope")));
        assertEq(uint8(cov), uint8(Coverage.UNKNOWN), "per selector too");
        (cov,,,,) = idx.postingHeadOf(family, TypeId.wrap(0), 0, 0);
        assertEq(uint8(cov), uint8(Coverage.UNKNOWN));

        Readiness memory derived = idx.replayReadiness();
        assertEq(derived.version, 1);
        assertEq(derived.ledger, address(hot));
        assertEq(derived.callbackProfile, CALLBACK_PROFILE_3);
        assertEq(derived.manifestHash, idx.manifestHash());
        assertEq(derived.provenFrom, 1);
        assertFalse(derived.ready);

        Readiness memory r;
        r.version = 1;
        r.ledger = address(hot);
        r.manifestHash = keccak256("m");
        r.completedAdmission = 5;
        r.ready = true;
        r.units = new Unit[](1);
        r.units[0].finalHook = address(0xf1);
        r.units[0].familyIds = new bytes32[](1);
        r.units[0].familyIds[0] = Keys.familyId("by-type");
        r.families = new FamilyEntry[](1);
        r.families[0].familyId = Keys.familyId("by-type");
        r.families[0].kind = 1;
        idx.setReadiness(r);
        assertEq(keccak256(abi.encode(idx.replayReadiness())), keccak256(abi.encode(r)));
        (, FamilyEntry[] memory families, Unit[] memory units,,,, bytes32 profile) = idx.manifest();
        assertEq(families.length, 1);
        assertEq(units[0].familyIds[0], Keys.familyId("by-type"));
        assertEq(profile, 0, "the configured tuple's profile, not the default");

        vm.expectRevert(
            abi.encodeWithSelector(
                MockUnsupported.selector, IRealmIndex.replayNextPublication.selector
            )
        );
        idx.replayNextPublication(1);
        vm.expectRevert(
            abi.encodeWithSelector(MockUnsupported.selector, IRealmIndex.build.selector)
        );
        idx.build(0, 1);
        vm.expectRevert(
            abi.encodeWithSelector(MockUnsupported.selector, IRealmIndex.backfill.selector)
        );
        idx.backfill(0, scope, 0, 1);
        vm.prank(address(hot));
        vm.expectRevert(abi.encodeWithSelector(MockCaller.selector, address(hot)));
        idx.setLedger(address(0)); // not even the ledger may reconfigure its index
    }

    // ---- signers and code shapes -------------------------------------------------------------------------------

    function test_contract_signature_wallet_modes() public {
        (address signer, uint256 pk) = makeAddrAndKey("wallet-key");
        ContractSignatureWallet w = new ContractSignatureWallet(signer);
        bytes32 digest = keccak256("signing digest");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        bytes memory sig = abi.encodePacked(r, s, v);
        assertEq(w.isValidSignature(digest, sig), ERC1271_MAGIC, "any digest signed by the key");
        w.setDigest(digest);
        assertEq(w.isValidSignature(digest, sig), ERC1271_MAGIC, "the configured digest");
        (v, r, s) = vm.sign(pk, keccak256("other"));
        assertEq(w.isValidSignature(keccak256("other"), abi.encodePacked(r, s, v)), ERC1271_REFUSAL);
        uint256 n = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141;
        (v, r, s) = vm.sign(pk, digest);
        bytes memory highS =
            abi.encodePacked(r, bytes32(n - uint256(s)), v == 27 ? uint8(28) : uint8(27));
        assertEq(w.isValidSignature(digest, highS), ERC1271_REFUSAL, "malleable twin refused");
        (, uint256 otherKey) = makeAddrAndKey("not-the-key");
        (v, r, s) = vm.sign(otherKey, digest);
        assertEq(w.isValidSignature(digest, abi.encodePacked(r, s, v)), ERC1271_REFUSAL);

        bytes memory q = abi.encodeCall(w.isValidSignature, (digest, sig));
        w.setMode(w.SHORT());
        (bool ok, bytes memory ret) = address(w).staticcall(q);
        assertTrue(ok && ret.length == 4 && bytes4(ret) == ERC1271_MAGIC);
        w.setMode(w.DIRTY());
        (ok, ret) = address(w).staticcall(q);
        assertTrue(ok && ret.length == 32 && bytes32(ret) != bytes32(ERC1271_MAGIC));
        w.setMode(w.OVERSIZED());
        (ok, ret) = address(w).staticcall(q);
        assertTrue(ok && ret.length == 8192 && bytes4(ret) == ERC1271_MAGIC);
        w.setMode(w.WRONG());
        (ok, ret) = address(w).staticcall(q);
        assertTrue(ok && bytes4(ret) == ERC1271_REFUSAL);
        w.setMode(w.REVERT());
        (ok, ret) = address(w).staticcall(q);
        assertEq(ret, abi.encodeWithSelector(ContractSignatureWallet.WalletRefused.selector));
        w.setMode(w.BURN());
        (ok, ret) = address(w).staticcall{gas: 200_000}(q);
        assertTrue(!ok && ret.length == 0);
        w.setMode(w.WRITE());
        (ok, ret) = address(w).staticcall{gas: 1_000_000}(q);
        assertTrue(!ok && ret.length == 0, "a write under STATICCALL halts");
        (ok, ret) = address(w).call(q);
        assertTrue(ok && bytes4(ret) == ERC1271_MAGIC && w.writes() == 1);
        w.setMode(w.REENTER());
        (ok, ret) = hot.staticRelay(address(w), q);
        assertTrue(ok, "re-entry under STATICCALL fails, so the wallet answers");
        assertEq(bytes4(ret), ERC1271_MAGIC);
        w.setMode(w.ECDSA());
        w.setCaller(address(hot));
        assertEq(
            w.isValidSignature(digest, sig),
            ERC1271_REFUSAL,
            "only the configured caller is answered"
        );

        vm.prank(address(0xbad));
        vm.expectRevert(
            abi.encodeWithSelector(ContractSignatureWallet.NotController.selector, address(0xbad))
        );
        w.setKey(address(0xbad));
        w.forward(address(hot), abi.encodeCall(HotStub.setLocked, (true)));
        assertTrue(hot.locked(), "the wallet acts as itself");
    }

    function test_magic_wallet_answers_magic_for_any_hash() public {
        MagicWallet m = new MagicWallet();
        assertEq(m.isValidSignature(0, ""), ERC1271_MAGIC);
        assertEq(m.isValidSignature(keccak256("victim"), hex"deadbeef"), ERC1271_MAGIC);
    }

    function test_native_counterfeit_calls_while_code_less_then_as_code() public {
        NativeCounterfeit c = new NativeCounterfeit(address(hot), keccak256("ctor"));
        assertFalse(c.constructorReverted());
        assertEq(hot.lastExecutor(), address(c));
        assertEq(hot.lastExecutorCodeSize(), 0, "the call came from a code-less constructor");
        (bool ok,) = c.attempt(0, keccak256("after"));
        assertTrue(ok);
        assertGt(hot.lastExecutorCodeSize(), 0, "after construction it is an ordinary contract");

        hot.setLocked(true);
        NativeCounterfeit refused = new NativeCounterfeit(address(hot), keccak256("ctor"));
        assertTrue(refused.constructorReverted(), "a refusal is recorded, not bubbled");
        assertEq(
            refused.constructorReturndata(), abi.encodeWithSelector(E_PUBLICATION_ACTIVE.selector)
        );
    }

    function test_scoped_7702_delegate_forwards_only_self_calls() public {
        Scoped7702Delegate d = new Scoped7702Delegate(address(hot));
        Action[] memory actions = new Action[](1);
        actions[0].kind = ActionKind.CREATE;
        actions[0].salt = keccak256("7702");
        Native memory ctx;
        vm.expectRevert(Scoped7702Delegate.E_SELF_ONLY.selector);
        d.execute(actions, new bytes[](1), ctx, "");

        address eoa = makeAddr("delegating-eoa");
        vm.etch(eoa, abi.encodePacked(hex"ef0100", address(d)));
        assertEq(eoa.code.length, 23);
        vm.expectRevert(Scoped7702Delegate.E_SELF_ONLY.selector);
        Scoped7702Delegate(eoa).execute(actions, new bytes[](1), ctx, "");
        vm.prank(eoa);
        Scoped7702Delegate(eoa).execute(actions, new bytes[](1), ctx, "");
        assertEq(hot.lastExecutor(), eoa, "the ledger sees the delegating account");
        assertEq(hot.lastExecutorCodeSize(), 23, "with its designator code");
    }

    function test_passthrough_controllers_and_what_CodeScan_sees() public {
        PassthroughController p = new PassthroughController();
        p.call(address(hot), abi.encodeCall(HotStub.setLocked, (true)));
        assertTrue(hot.locked(), "the owner reaches any target as the controller");
        vm.prank(address(0xbad));
        vm.expectRevert(
            abi.encodeWithSelector(PassthroughController.NotOwner.selector, address(0xbad))
        );
        p.call(address(hot), "");
        // A CALL-only passthrough is a plain runtime: the opcode scan alone cannot refuse it.
        assertEq(CodeScan.scan(address(p).code), 0, "CALL passthrough is plain");

        DelegatingPassthroughController dp = new DelegatingPassthroughController();
        assertEq(CodeScan.scan(address(dp).code), 3, "DELEGATECALL passthrough refused");
    }

    // ---- FaultyReads -------------------------------------------------------------------------------------------

    function test_faulty_reads_primitives() public {
        FaultyReads f = new FaultyReads(address(hot));
        ILedgerHot h = ILedgerHot(address(f));
        hot.setCounts(5, 3, 2, 1);
        bytes4 counts = ILedgerHot.counts.selector;

        (uint64 a, uint64 r, uint64 b, uint64 p) = h.counts();
        assertTrue(a == 5 && r == 3 && b == 2 && p == 1, "faithful");

        f.setFault(counts, FaultyReads.Fault(f.SET_WORD(), 0, false, 0, 9));
        (a,,,) = h.counts();
        assertEq(a, 9, "SET_WORD");
        f.setFault(counts, FaultyReads.Fault(f.ADD_WORD(), 1, false, 0, 1));
        (, r,,) = h.counts();
        assertEq(r, 4, "ADD_WORD");
        f.setFault(counts, FaultyReads.Fault(f.ADD_WORD(), 1, false, 0, type(uint256).max));
        (, r,,) = h.counts();
        assertEq(r, 2, "ADD_WORD wraps: -1");
        f.setFault(counts, FaultyReads.Fault(f.FUTURE_ADMISSION(), 2, false, 0, 1));
        (,, b,) = h.counts();
        assertEq(b, 6, "FUTURE_ADMISSION");
        f.setMode(counts, f.ZERO());
        (a, r, b, p) = h.counts();
        assertTrue(a == 0 && r == 0 && b == 0 && p == 0, "ZERO");

        bytes memory q = abi.encodeCall(ILedgerHot.counts, ());
        f.setFault(counts, FaultyReads.Fault(f.SHORT(), 0, false, 0, 32));
        (bool ok, bytes memory ret) = address(f).staticcall(q);
        assertTrue(ok && ret.length == 32, "SHORT");
        vm.expectRevert();
        this.typedCounts(h); // a typed caller fails closed on the short reply
        f.setFault(counts, FaultyReads.Fault(f.EXTRA(), 0, false, 0, 64));
        (ok, ret) = address(f).staticcall(q);
        assertTrue(ok && ret.length == 192, "EXTRA");
        f.setMode(counts, f.EMPTY());
        (ok, ret) = address(f).staticcall(q);
        assertTrue(ok && ret.length == 0, "EMPTY");
        f.setMode(counts, f.REVERT());
        f.setRevertData(counts, abi.encodeWithSelector(E_LEDGER.selector));
        (ok, ret) = address(f).staticcall(q);
        assertTrue(!ok && bytes4(ret) == E_LEDGER.selector, "REVERT with configured data");
        f.setMode(counts, f.EXHAUST());
        (ok, ret) = address(f).staticcall{gas: 100_000}(q);
        assertTrue(!ok && ret.length == 0, "EXHAUST");
        f.setFault(counts, FaultyReads.Fault(f.SET_WORD(), 9, false, 0, 1));
        vm.expectRevert(abi.encodeWithSelector(FaultyReads.FaultyWord.selector, counts, 9, 128));
        h.counts();

        f.clear(counts);
        f.capture(q);
        hot.setCounts(50, 30, 20, 10);
        f.setMode(counts, f.STALE());
        (a,,, p) = h.counts();
        assertTrue(a == 5 && p == 1, "STALE returns the captured basis");
        f.clear(counts);
        (a,,,) = h.counts();
        assertEq(a, 50, "cleared");
        f.setMode(ILedgerHot.phase.selector, f.STALE());
        vm.expectRevert(
            abi.encodeWithSelector(
                FaultyReads.FaultyNoCapture.selector,
                ILedgerHot.phase.selector,
                keccak256(abi.encodeCall(ILedgerHot.phase, ()))
            )
        );
        h.phase();
    }

    function test_faulty_reads_filters_forwards_and_bubbles() public {
        FaultyReads f = new FaultyReads(address(hot));
        ILedgerHot h = ILedgerHot(address(f));
        bytes32 target = keccak256("target");
        bytes32 other = keccak256("other");
        hot.setRecord(target, HotStub.RecordRow(keccak256("type"), 3, 32, 1));
        hot.setRecord(other, HotStub.RecordRow(keccak256("type"), 4, 32, 1));
        f.setFault(
            ILedgerHot.recordHeader.selector, FaultyReads.Fault(f.ZERO(), 0, true, target, 0)
        );
        (bytes32 t,,,,) = h.recordHeader(target);
        assertEq(t, 0, "the filtered argument is faulted (prototype MISSING_PAIR)");
        uint64 first;
        (t, first,,,) = h.recordHeader(other);
        assertTrue(t == keccak256("type") && first == 4, "other arguments stay faithful");

        // Selectors outside ILedgerHot are forwarded by the same table.
        hot.setLocked(true);
        assertTrue(HotStub(address(f)).locked());
        f.setMode(hot.locked.selector, f.ZERO());
        assertFalse(HotStub(address(f)).locked());

        // A real revert is bubbled unchanged; writes cannot pass (STATICCALL).
        vm.expectRevert(E_PUBLICATION_ACTIVE.selector);
        ILedger(address(f)).execute(new Action[](0), new bytes[](0), Native(0, 0, 0, 0), "");
        hot.setLocked(false);
        (bool ok, bytes memory ret) =
            address(f).call{gas: 1_000_000}(abi.encodeCall(HotStub.setLocked, (true)));
        assertTrue(!ok && ret.length == 0, "a state-changing selector fails under STATICCALL");
        assertFalse(hot.locked());
    }
}
