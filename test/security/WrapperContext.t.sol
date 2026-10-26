// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {DescribedRealm} from "../harness/doubles/DescribedRealm.sol";
import {Descriptors} from "../harness/Descriptors.sol";
import {
    BurningBomb,
    GasRelay,
    LookalikeCoordinator,
    WrapperBoundPredicate
} from "../harness/doubles/DescribedPredicates.sol";
import {
    ACCEPTOR_REFUSAL,
    AcceptAll,
    GasBurner,
    ReturndataBomb,
    ShapedReplyAcceptor
} from "../harness/doubles/Acceptors.sol";
import {DescribedTypeRule} from "../../src/types/DescribedTypeRule.sol";
import {DescribedCodec} from "../../src/types/DescribedCodec.sol";
import {CodeScan} from "../../src/lib/CodeScan.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {AcceptContext, EXHAUSTED, IAcceptor, RefHeader} from "../../src/interfaces/IAcceptor.sol";
import {ILedger} from "../../src/interfaces/ILedger.sol";
import {
    E_ACCEPTOR_GAS,
    E_BINDING,
    E_BLOB,
    E_CODE_SHAPE,
    E_CODEC,
    E_GRADE,
    E_LEDGER,
    E_REF,
    E_TYPE_MISMATCH,
    E_WRAPPER
} from "../../src/interfaces/Errors.sol";

/// @notice S14 (design §2.2, §5.10): the singleton wrapper under hostile calldata. `accept` is called directly
///         with forged contexts — by a stranger, by a lookalike coordinator that names itself as `ctx.ledger`
///         and controls the blob, and by the real ledger with one field changed — and refuses unless the
///         caller is `ctx.ledger` and the Type id, grade, rule codehash, predicate codehash, binding id, blob
///         shape and reference Types re-derive. Hostile predicates: a returndata bomb (refused, nothing
///         copied), a gas burner (`EXHAUSTED`, and `E_ACCEPTOR_GAS` through the kernel), the prototype's old
///         success word (refused). The build is a plain runtime without immutables.
contract WrapperContextTest is DescribedRealm {
    using Descriptors for Descriptors.Params;

    bytes internal constant BODY = hex"00026869";
    bytes32[] internal none;
    RefHeader[] internal noHeaders;
    bytes32 internal t1; // a structural text Type
    bytes32 internal t2; // a custom text Type bound to `p`
    WrapperBoundPredicate internal p;

    function setUp() public override {
        super.setUp();
        t1 = _register(_structural(_textFields(), 1));
        p = new WrapperBoundPredicate(address(rule).codehash, a.k.proxy);
        t2 = _registerCustom(a, _custom(address(p), _textFields(), 1), address(p));
    }

    function _err(bytes4 selector, uint8 code) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(selector, code);
    }

    /// The id a descriptor derives under `ruleId` (a registry uses the header's; the wrapper its own).
    function _idFor(bytes memory d, bytes32 ruleId) internal view returns (bytes32) {
        (, bytes32[] memory refs) = this.parse(d);
        return Keys.typeId(keccak256(abi.encode(Keys.DOM_DESCRIBED_SHAPE, d)), refs, ruleId);
    }

    /// A context of the caller's own making: this contract as `ctx.ledger`, the given Type, grade and blob.
    function _forged(bytes32 t, uint8 grade, address blob)
        internal
        view
        returns (AcceptContext memory c)
    {
        c.typeId = t;
        c.grade = grade;
        c.ledger = address(this);
        c.registry = address(registry());
        c.descriptorBlob = blob;
    }

    /// `rule.accept` called by this contract (no prank), under `gas`.
    function _direct(AcceptContext memory c, bytes memory body, uint256 gas)
        internal
        returns (bool ok, bytes memory reply)
    {
        bytes memory data = abi.encodeCall(IAcceptor.accept, (c, body, none, noHeaders));
        (ok, reply) = address(rule).call{gas: gas}(data);
    }

    function _bindingIdFor(AcceptContext memory c, address custom) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("efs2/described-binding/1"),
                address(rule).codehash,
                block.chainid,
                c.registry,
                c.typeId,
                custom,
                custom.codehash,
                uint256(1),
                key
            )
        );
    }

    // ---- the caller -----------------------------------------------------------------------------------------

    function test_ctx_ledger_must_be_the_caller() public {
        AcceptContext memory c = _ctxOf(a, t1);
        vm.expectRevert(E_LEDGER.selector);
        rule.accept(c, BODY, none, noHeaders); // a direct call naming the real ledger
        vm.prank(address(0xBAD));
        vm.expectRevert(E_LEDGER.selector);
        rule.accept(c, BODY, none, noHeaders);
        _expectWrapper(c, BODY, none, noHeaders, ""); // the real ledger
        // the predicate authenticates the wrapper build: a direct caller gets its refusal word
        assertEq(p.accept(_ctxOf(a, t2), BODY, none, noHeaders), ACCEPTOR_REFUSAL);
    }

    // ---- a lookalike coordinator ------------------------------------------------------------------------

    function test_lookalike_coordinator_is_caught_by_the_recomputed_type_id() public {
        LookalikeCoordinator co = new LookalikeCoordinator();
        // a descriptor naming another rule codehash, in a blob the coordinator put
        Descriptors.Params memory q = _params(1, 0, _textFields(), 1);
        q.ruleCodehash = keccak256("efs2/test/another-rule");
        bytes memory d = q.encode();
        address blob = a.store.put(d, hex"01");
        bytes32 claimed = _idFor(d, q.ruleCodehash); // the id a registry derives from this header
        bytes32 own = _idFor(d, address(rule).codehash);
        (bool ok, bytes memory reply) =
            co.ask(address(rule), _forged(claimed, 1, blob), BODY, none, noHeaders);
        assertFalse(ok);
        assertEq(reply, abi.encodeWithSelector(E_TYPE_MISMATCH.selector, uint8(0), claimed, own));
        // claiming the id the wrapper itself derives does not help: the header names another rule
        (ok, reply) = co.ask(address(rule), _forged(own, 1, blob), BODY, none, noHeaders);
        assertEq(reply, _err(E_WRAPPER.selector, 2));
        // a grade the descriptor does not declare, and a native descriptor naming this wrapper
        d = _structural(_textFields(), 1);
        blob = a.store.put(d, hex"01");
        (ok, reply) = co.ask(
            address(rule),
            _forged(_idFor(d, address(rule).codehash), 2, blob),
            BODY,
            none,
            noHeaders
        );
        assertEq(reply, _err(E_GRADE.selector, 1));
        d = _params(3, keccak256("efs2/test/initcode"), _textFields(), 1).encode();
        blob = a.store.put(d, hex"01");
        (ok, reply) = co.ask(
            address(rule),
            _forged(_idFor(d, address(rule).codehash), 3, blob),
            BODY,
            none,
            noHeaders
        );
        assertEq(reply, _err(E_GRADE.selector, 3));
    }

    /// A self-consistent forged context passes the wrapper — it attests consistency and that its caller is
    /// `ctx.ledger`, nothing more — so the lookalike learns only what it could compute itself; a grade-2
    /// predicate then compares the attested `ctx.ledger` with its own ledger and refuses the lookalike.
    function test_lookalike_coordinator_consistent_context_meets_the_predicate() public {
        LookalikeCoordinator co = new LookalikeCoordinator();
        bytes memory d = _structural(_textFields(), 1);
        AcceptContext memory c =
            _forged(_idFor(d, address(rule).codehash), 1, a.store.put(d, hex"01"));
        (bool ok, bytes memory reply) = co.ask(address(rule), c, BODY, none, noHeaders);
        assertTrue(ok);
        assertEq(reply, abi.encode(IAcceptor.accept.selector));
        d = _custom(address(p), _textFields(), 1);
        c = _forged(_idFor(d, address(rule).codehash), 2, a.store.put(d, hex"01"));
        c.customPredicate = address(p);
        c.bindingId = _bindingIdFor(c, address(p));
        (ok, reply) = co.ask(address(rule), c, BODY, none, noHeaders);
        assertFalse(ok);
        assertEq(reply, _rejected(0, c.typeId), "the predicate refused the lookalike's ledger");
        c.ledger = a.k.proxy; // the same context from the ledger the predicate is bound to
        _expectWrapper(c, BODY, none, noHeaders, "");
    }

    // ---- one field changed under the real ledger --------------------------------------------------------

    function test_wrong_ctx_grade() public {
        uint8[3] memory wrong = [0, 2, 3];
        for (uint256 i; i < 3; ++i) {
            AcceptContext memory c = _ctxOf(a, t1);
            c.grade = wrong[i];
            _expectWrapper(c, BODY, none, noHeaders, _err(E_GRADE.selector, 1));
        }
        AcceptContext memory c2 = _ctxOf(a, t2);
        c2.grade = 1;
        _expectWrapper(c2, BODY, none, noHeaders, _err(E_GRADE.selector, 2));
    }

    function test_predicate_codehash_must_be_customHash() public {
        address designator = address(0x7702);
        vm.etch(designator, abi.encodePacked(hex"ef0100", address(p)));
        address[4] memory wrong =
            [address(new AcceptAll()), address(0xBEEF), designator, address(0)];
        bytes[4] memory err = [
            _err(E_BINDING.selector, 3),
            abi.encodeWithSelector(E_CODE_SHAPE.selector, address(0xBEEF), uint8(1)),
            abi.encodeWithSelector(E_CODE_SHAPE.selector, designator, uint8(2)),
            abi.encodeWithSelector(E_CODE_SHAPE.selector, address(0), uint8(1))
        ];
        for (uint256 i; i < 4; ++i) {
            AcceptContext memory c = _ctxOf(a, t2);
            c.customPredicate = wrong[i];
            _expectWrapper(c, BODY, none, noHeaders, err[i]);
        }
        // a grade-1 context carries neither a predicate nor a binding id
        AcceptContext memory s = _ctxOf(a, t1);
        s.customPredicate = address(p);
        _expectWrapper(s, BODY, none, noHeaders, _err(E_BINDING.selector, 1));
        s = _ctxOf(a, t1);
        s.bindingId = keccak256("a binding");
        _expectWrapper(s, BODY, none, noHeaders, _err(E_BINDING.selector, 1));
    }

    function test_binding_id_is_recomputed() public {
        bytes memory refused = _err(E_BINDING.selector, 10);
        AcceptContext memory c = _ctxOf(a, t2);
        c.bindingId = bytes32(uint256(c.bindingId) ^ 1);
        _expectWrapper(c, BODY, none, noHeaders, refused);
        c = _ctxOf(a, t2);
        c.registry = address(0x1234); // the binding commits to the registry
        _expectWrapper(c, BODY, none, noHeaders, refused);
        WrapperBoundPredicate squat = new WrapperBoundPredicate(address(rule).codehash, a.k.proxy);
        c = _ctxOf(a, t2);
        c.customPredicate = address(squat); // same code, not the bound instance
        _expectWrapper(c, BODY, none, noHeaders, refused);
        uint256 chain = vm.getChainId(); // not `block.chainid`: via-IR may re-read it after `vm.chainId`
        vm.chainId(chain + 1); // the binding commits to the chain (prototype case 19)
        _expectWrapper(_ctxOf(a, t2), BODY, none, noHeaders, refused);
        vm.chainId(chain);
        _expectWrapper(_ctxOf(a, t2), BODY, none, noHeaders, "");
    }

    function test_blob_must_be_stop_prefixed_and_complete() public {
        address blob = registry().typeInfo(t1).descriptorBlob;
        bytes memory code = blob.code;
        uint256 len = registry().descriptorBytes(t1).length;
        address fake = address(0xB10B);
        bytes memory shape = bytes.concat(code);
        shape[0] = 0x01;
        bytes[4] memory bad = [shape, _slice(code, 1 + len - 1), _slice(code, 100), bytes("")];
        for (uint256 i; i < 4; ++i) {
            vm.etch(fake, bad[i]);
            AcceptContext memory c = _ctxOf(a, t1);
            c.descriptorBlob = fake;
            _expectWrapper(c, BODY, none, noHeaders, abi.encodeWithSelector(E_BLOB.selector, fake));
        }
        // a header declaring more than 4,096 bytes is refused before anything else is copied
        shape = bytes.concat(code);
        shape[1 + 130] = 0xff;
        shape[1 + 131] = 0xff;
        vm.etch(fake, shape);
        AcceptContext memory h = _ctxOf(a, t1);
        h.descriptorBlob = fake;
        _expectWrapper(h, BODY, none, noHeaders, abi.encodeWithSelector(E_CODEC.selector, 0, 1));
        // another Type's blob re-derives that Type's id; bytes after the descriptor are the declaration's
        h.descriptorBlob = registry().typeInfo(t2).descriptorBlob;
        _expectWrapper(
            h,
            BODY,
            none,
            noHeaders,
            abi.encodeWithSelector(E_TYPE_MISMATCH.selector, uint8(0), t1, t2)
        );
        vm.etch(fake, bytes.concat(code, "trailing"));
        h.descriptorBlob = fake;
        _expectWrapper(h, BODY, none, noHeaders, "");
    }

    /// The kernel resolves references from the registry's row, never from the wrapper; the wrapper binds the
    /// descriptor's own projection twice — through the Type id it re-derives and through the reference
    /// headers' Types — so a row that diverges from the descriptor cannot loosen the Type.
    function test_refTypes_projection_divergence() public {
        bytes32 t0 = _register(_structural(_f(1, DescribedCodec.KIND_BYTES, 0, 0, 0, 64, 0), 1));
        bytes32 tOther = _register(_structural(_f(1, DescribedCodec.KIND_BYTES, 0, 0, 0, 64, 0), 1));
        bytes memory fields = bytes.concat(
            _f(1, DescribedCodec.KIND_REF32, 0, 32, 0, 0, t0),
            _f(2, DescribedCodec.KIND_BYTES, 0, 0, 0, 64, 0)
        );
        bytes memory d = _structural(fields, 2);
        bytes32 t = _register(d);
        bytes32 ref = _publish(t0, hex"0001aa");
        bytes32 wrong = _publish(tOther, hex"0001aa");
        bytes32[] memory refs = new bytes32[](1);
        refs[0] = ref;
        // a context claiming the id an ANY projection of the same descriptor would derive
        AcceptContext memory c = _ctxOf(a, t);
        bytes32[] memory anyRef = new bytes32[](1);
        c.typeId = Keys.typeId(
            keccak256(abi.encode(Keys.DOM_DESCRIBED_SHAPE, d)), anyRef, address(rule).codehash
        );
        bytes memory body = abi.encodePacked(ref, hex"0000");
        _expectWrapper(
            c,
            body,
            refs,
            _headersOf(a, refs),
            abi.encodeWithSelector(E_TYPE_MISMATCH.selector, uint8(0), c.typeId, t)
        );
        // the row diverges (the stored exact Type rewritten to ANY): the kernel admits a reference of another
        // Type to the wrapper, which refuses it against the descriptor
        bytes32 slot = keccak256(
            abi.encode(
                uint256(0),
                keccak256(
                    abi.encode(
                        t,
                        uint256(0xb88a601303f5b59143b779b8925ece487b1fa8710d521523140b6c2d91568c00)
                            + 1
                    )
                )
            )
        );
        assertEq(vm.load(address(registry()), slot), t0, "the refTypes row slot");
        vm.store(address(registry()), slot, bytes32(0));
        assertEq(registry().refTypes(t)[0], bytes32(0));
        bytes memory bad = abi.encodePacked(wrong, hex"0000");
        _refuse(t, bad);
        refs[0] = wrong;
        _expectWrapper(
            t, bad, refs, abi.encodeWithSelector(E_REF.selector, uint8(0), uint8(0), uint8(2))
        );
        _publish(t, body); // the honest reference still publishes
    }

    // ---- hostile predicates -----------------------------------------------------------------------------

    /// A predicate that burns its forward down to ~20k and then returns 64 KiB leaves the wrapper about
    /// (g − 5,000) / 64 + 5,000 plus what it hands back — under 20k here — while copying the reply into the
    /// wrapper's memory would cost more than 20k (expansion and copy). The exact `E_REJECTED` reply therefore
    /// proves nothing beyond the 32-byte buffer was copied; the plain 64 KiB bomb is refused through the kernel.
    function test_predicate_returndata_bomb_is_refused_without_a_copy() public {
        address burning = address(new BurningBomb());
        bytes32 t = _registerCustom(a, _custom(burning, _textFields(), 1), burning);
        AcceptContext memory c = _ctxOf(a, t);
        c.ledger = address(this);
        (bool ok, bytes memory reply) = _direct(c, BODY, 400_000);
        assertFalse(ok);
        assertEq(reply, _rejected(0, t), "refused with its reason: no copy was attempted");
        address bomb = address(new ReturndataBomb());
        bytes32 tb = _registerCustom(a, _custom(bomb, _textFields(), 1), bomb);
        _expectWrapper(tb, BODY, none, _rejected(0, tb));
        _refuse(tb, BODY);
    }

    function test_predicate_burning_all_gas_is_EXHAUSTED_then_E_ACCEPTOR_GAS() public {
        address burner = address(new GasBurner());
        bytes32 t = _registerCustom(a, _custom(burner, _textFields(), 1), burner);
        AcceptContext memory c = _ctxOf(a, t);
        c.ledger = address(this);
        (bool ok, bytes memory reply) = _direct(c, BODY, 1_000_000);
        assertTrue(ok, "exhaustion is a reply, not a revert");
        assertEq(reply, abi.encode(EXHAUSTED));
        bytes32 before = _digest(a, _one(_pub(t, BODY)));
        bytes memory err;
        (ok, err) = a.k.proxy.call{gas: 3_000_000}(
            abi.encodeCall(ILedger.execute, (_one(_pub(t, BODY)), _bodies(BODY), _native(a), ""))
        );
        assertFalse(ok);
        assertEq(bytes4(err), E_ACCEPTOR_GAS.selector, "E_ACCEPTOR_GAS, not E_REJECTED");
        assertEq(_digest(a, _one(_pub(t, BODY))), before, "the nonce and the rows are intact");
    }

    function test_old_success_word_is_refused() public {
        address old = address(new ShapedReplyAcceptor(bytes32(uint256(1)), 32));
        bytes32 t = _registerCustom(a, _custom(old, _textFields(), 1), old);
        _expectWrapper(t, BODY, none, _rejected(0, t));
        _refuse(t, BODY);
        address exact = address(new ShapedReplyAcceptor(bytes32(IAcceptor.accept.selector), 32));
        bytes32 control = _registerCustom(a, _custom(exact, _textFields(), 1), exact);
        _expectWrapper(control, BODY, none, "");
        _publish(control, BODY);
    }

    /// A descriptor whose customHash is this build's codehash registers the wrapper as its own predicate. The
    /// nested call reaches `accept` with the wrapper as caller, which is not `ctx.ledger`: a refusal, never a
    /// recursion.
    function test_wrapper_as_its_own_predicate_refuses() public {
        bytes32 t = _registerCustom(a, _custom(address(rule), _textFields(), 1), address(rule));
        _expectWrapper(t, BODY, none, _rejected(0, t));
        _refuse(t, BODY);
    }

    /// Below any budget the wrapper either accepts, replies `EXHAUSTED` (its own law or the predicate ran
    /// out), or itself runs out having used everything — the kernel's `E_ACCEPTOR_GAS` in every case. It
    /// never refuses with a reason, or fails early and empty, for want of gas. (Swept from a relay contract:
    /// see `GasRelay`.)
    function test_gas_starvation_is_never_a_refusal() public {
        GasRelay relay = new GasRelay();
        address accepting = address(new AcceptAll());
        bytes32 t3 = _registerCustom(a, _custom(accepting, _textFields(), 1), accepting);
        bytes32[2] memory types = [t1, t3];
        bytes memory exhausted = abi.encode(EXHAUSTED);
        bytes memory selector = abi.encode(IAcceptor.accept.selector);
        uint256 nExhausted;
        uint256 nAccepted;
        for (uint256 k; k < 2; ++k) {
            AcceptContext memory c = _ctxOf(a, types[k]);
            c.ledger = address(relay);
            bytes memory data = abi.encodeCall(IAcceptor.accept, (c, BODY, none, noHeaders));
            for (uint256 gas = 1_000; gas <= 60_000; gas += 250) {
                (bool ok, bytes memory reply, uint256 used) = relay.relay(address(rule), data, gas);
                if (ok && keccak256(reply) == keccak256(exhausted)) {
                    ++nExhausted;
                } else if (ok) {
                    assertEq(reply, selector, "only the selector or EXHAUSTED");
                    ++nAccepted;
                } else {
                    assertEq(reply.length, 0, "a refusal reason under gas starvation");
                    assertGe(used + 2_000, gas, "an empty failure that did not use its gas");
                }
            }
        }
        assertGt(nExhausted, 0, "the EXHAUSTED reply was reached");
        assertGt(nAccepted, 0, "the budget sweep reached acceptance");
    }

    // ---- the build --------------------------------------------------------------------------------------

    /// `type(C).runtimeCode` does not compile for a contract with immutables, so this file compiling is the
    /// static half; the deployed runtime equal to the compiler's is the dynamic half. (`foundry.toml` grants no
    /// read of `out/`, so the artifact's `immutableReferences` is checked by `forge build` inspection, not here.)
    function test_plain_runtime_without_immutables() public {
        assertEq(
            CodeScan.scan(address(rule).code), 0, "no DELEGATECALL/CALLCODE/CREATE/SELFDESTRUCT"
        );
        CodeScan.requirePlainRuntime(address(rule));
        assertEq(keccak256(type(DescribedTypeRule).runtimeCode), address(rule).codehash);
        assertEq(vm.getDeployedCode("DescribedTypeRule.sol:DescribedTypeRule"), address(rule).code);
        vm.prank(address(0xD00D));
        DescribedTypeRule other = new DescribedTypeRule();
        DescribedTypeRule salted = new DescribedTypeRule{salt: keccak256("efs2/test/salt")}();
        assertEq(address(other).codehash, address(rule).codehash, "deployer-independent");
        assertEq(address(salted).codehash, address(rule).codehash, "CREATE2-independent");
    }

    /// `check` is the wrapper's law without the caller check or the predicate: a dry run that grants nothing.
    function test_check_is_a_dry_run() public {
        address burner = address(new GasBurner());
        bytes32 t = _registerCustom(a, _custom(burner, _textFields(), 1), burner);
        bytes memory d = registry().descriptorBytes(t);
        AcceptContext memory c = _ctxOf(a, t);
        c.ledger = address(0xBAD); // not consulted
        bytes memory call_ = abi.encodeCall(DescribedTypeRule.check, (c, BODY, none, noHeaders));
        (bool ok,) =
            address(rule).staticcall{gas: 200_000}(bytes.concat(call_, d, abi.encode(d.length)));
        assertTrue(ok, "the predicate (a gas burner) is never reached");
        bytes memory reply;
        (ok, reply) = address(rule).staticcall(call_); // no descriptor appended
        assertFalse(ok);
        assertEq(reply, abi.encodeWithSelector(E_CODEC.selector, 0, 1));
    }

    function _slice(bytes memory b, uint256 n) internal pure returns (bytes memory out) {
        out = new bytes(n);
        for (uint256 i; i < n; ++i) {
            out[i] = b[i];
        }
    }
}
