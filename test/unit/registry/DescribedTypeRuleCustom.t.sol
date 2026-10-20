// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {DescribedRealm, Realm} from "../../harness/doubles/DescribedRealm.sol";
import {WrapperBoundPredicate} from "../../harness/doubles/DescribedPredicates.sol";
import {
    AcceptAll,
    ExhaustedAcceptor,
    GasBurner,
    RejectAll,
    ReturndataBomb,
    RevertingAcceptor,
    ShapedReplyAcceptor
} from "../../harness/doubles/Acceptors.sol";
import {DescribedTypeRule} from "../../../src/types/DescribedTypeRule.sol";
import {DescribedCodec} from "../../../src/types/DescribedCodec.sol";
import {Keys} from "../../../src/lib/Keys.sol";
import {TypeInfo} from "../../../src/interfaces/ITypeRegistry.sol";
import {AcceptContext, IAcceptor} from "../../../src/interfaces/IAcceptor.sol";
import {ILedger} from "../../../src/interfaces/ILedger.sol";
import {
    E_ACCEPTOR_GAS,
    E_BINDING,
    E_NONCE,
    E_UNKNOWN_TYPE
} from "../../../src/interfaces/Errors.sol";

/// @notice The CUSTOM grade of `DescribedTypeRule/1` through the real kernel (design §5.10, §9.3): the wrapper's
///         structure and the nested predicate are both mandatory on PUBLISH and REUSE; the creator's binding
///         selects the predicate instance (same code, other state is not the same binding); every hostile
///         predicate reply is a refusal except nested exhaustion, which is `E_ACCEPTOR_GAS`; a predicate reads
///         the ordered prefix and its refusal rolls the whole batch back; and Type and Record ids are portable
///         across Realms while bindings are not. Prototype mapping: DescribedTypeRule.t.sol (cases 3, 4, 6, 9,
///         13, 15, 18).
contract DescribedTypeRuleCustomTest is DescribedRealm {
    bytes internal constant BODY = hex"00026869";

    function _predicate(Realm memory x) internal returns (WrapperBoundPredicate) {
        return new WrapperBoundPredicate(address(rule).codehash, x.k.proxy);
    }

    function _customText(address predicate) internal returns (bytes32) {
        return _registerCustom(a, _custom(predicate, _textFields(), 1), predicate);
    }

    // ---- case 3: structure and predicate are both mandatory ---------------------------------------------------

    function test_structure_and_predicate_are_both_mandatory() public {
        WrapperBoundPredicate p = _predicate(a);
        bytes32 t = _customText(address(p));
        TypeInfo memory info = registry().typeInfo(t);
        assertEq(info.grade, 2);
        assertEq(info.mandatory, address(rule), "the wrapper is the mandatory rule");
        assertEq(info.custom, address(p));
        assertEq(info.bindingId, _bindingId(a, t, address(p)));
        bytes32 id = _publish(t, BODY);
        _refuse(t, hex"00036869"); // the predicate would accept: the structure refuses
        registry().activatePolicy(t, address(new AcceptAll())); // a permissive policy changes nothing
        p.setMode(p.REFUSE());
        _refuse(t, BODY); // the same body again: an existing record does not skip the mandatory rule
        _refused(_one(_reuse(t, id)), _bodies(""), _rejected(0, t)); // REUSE is judged too
        registry().activatePolicy(t, address(0));
        _refuse(t, BODY);
        p.setMode(p.ACCEPT());
        _exec(a, _one(_reuse(t, id)), _bodies(""));
        (,,, uint64 occurrences,) = hot().recordHeader(id);
        assertEq(occurrences, 2, "the reuse landed once the predicate agreed");
    }

    // ---- cases 4 and 19: the binding selects the instance --------------------------------------------------

    function test_binding_selects_the_instance_not_the_code() public {
        WrapperBoundPredicate p = _predicate(a);
        WrapperBoundPredicate squat = _predicate(a);
        squat.setMode(squat.REFUSE());
        assertEq(address(squat).codehash, address(p).codehash, "same code, other state");
        bytes memory d = _custom(address(p), _textFields(), 1);
        (bytes32 t, bytes memory sig) = _declare(a, d);
        bytes memory auth = _sign(PK, registry().bindingDigest(_bindingId(a, t, address(p))));
        vm.expectRevert(abi.encodeWithSelector(E_BINDING.selector, uint8(5)));
        registry().registerDescribed(d, sig, address(squat), auth);
        bytes memory stranger = _sign(0xB0B, registry().bindingDigest(_bindingId(a, t, address(p))));
        vm.expectRevert(abi.encodeWithSelector(E_BINDING.selector, uint8(5))); // another signer
        registry().registerDescribed(d, sig, address(p), stranger);
        vm.expectRevert(abi.encodeWithSelector(E_BINDING.selector, uint8(3))); // the wrapper as predicate
        registry().registerDescribed(d, sig, address(rule), auth);
        assertEq(registry().typeInfo(t).mandatory, address(0), "failed registrations are atomic");
        (, bool installed,) = registry().declaration(t);
        assertFalse(installed);
        registry().registerDescribed(d, sig, address(p), auth);
        // a fresh valid authorization cannot move an installed binding; the identical relay is idempotent
        bytes memory alternate =
            _sign(PK, registry().bindingDigest(_bindingId(a, t, address(squat))));
        vm.expectRevert(abi.encodeWithSelector(E_BINDING.selector, uint8(6)));
        registry().registerDescribed(d, sig, address(squat), alternate);
        (bytes32 again,) = registry().registerDescribed(d, sig, address(p), auth);
        assertEq(again, t);
        // the wrapper re-derives the binding from its context: naming the squat under the real id refuses
        AcceptContext memory c = _ctxOf(a, t);
        c.customPredicate = address(squat);
        bytes32[] memory none = new bytes32[](0);
        _expectWrapper(
            c,
            BODY,
            none,
            _headersOf(a, none),
            abi.encodeWithSelector(E_BINDING.selector, uint8(10))
        );
        _publish(t, BODY);
    }

    // ---- case 6: hostile predicate replies ------------------------------------------------------------------

    function test_hostile_predicates_through_the_kernel() public {
        address[8] memory hostile = [
            address(new ShapedReplyAcceptor(bytes32(uint256(2)), 32)), // the prototype's "bad bool"
            address(new ShapedReplyAcceptor(bytes32(uint256(1)), 32)), // the prototype's success word
            address(new ShapedReplyAcceptor(bytes32(IAcceptor.accept.selector), 4)), // a bare bytes4
            address(new ShapedReplyAcceptor(bytes32(IAcceptor.accept.selector), 64)), // 32 + trailing
            address(new ReturndataBomb()),
            address(new RejectAll()),
            address(new RevertingAcceptor(abi.encodeWithSelector(E_NONCE.selector, 0, 0, 0))),
            address(new ExhaustedAcceptor()) // a predicate's own EXHAUSTED word is not propagated
        ];
        for (uint256 i; i < hostile.length; ++i) {
            _refuse(_customText(hostile[i]), BODY);
        }
        _publish(_customText(address(new AcceptAll())), BODY); // the control
        // code drift after registration: the codehash no longer matches customHash, or no code at all
        WrapperBoundPredicate p = _predicate(a);
        bytes32 t = _customText(address(p));
        _publish(t, BODY);
        vm.etch(address(p), hex"00");
        _refuse(t, hex"00026868");
        vm.etch(address(p), "");
        _refuse(t, hex"00026868");
    }

    function test_predicate_exhaustion_is_E_ACCEPTOR_GAS_never_E_REJECTED() public {
        bytes32 t = _customText(address(new GasBurner()));
        bytes32 before = _digest(a, _one(_pub(t, BODY)));
        (bool ok, bytes memory err) = a.k.proxy.call{gas: 3_000_000}(
            abi.encodeCall(ILedger.execute, (_one(_pub(t, BODY)), _bodies(BODY), _native(a), ""))
        );
        assertFalse(ok);
        assertEq(bytes4(err), E_ACCEPTOR_GAS.selector, "resubmit, not a refusal");
        (uint8 leaf, bytes32 typeId, uint32 forwarded) =
            abi.decode(_tail(err), (uint8, bytes32, uint32));
        assertEq(leaf, 0);
        assertEq(typeId, t);
        assertGe(forwarded, 300_000, "the kernel forwarded at least the default floor");
        assertEq(_digest(a, _one(_pub(t, BODY))), before, "nothing changed");
    }

    /// The wrapper's own law over a maximal TEXT body (8,190 bytes) validates: the text scan runs in assembly
    /// at a few dozen gas per byte, so the acceptor stays inside the default 300k floor and the publication's
    /// cost is the kernel's body storage, not the validation. (The exhaustion classification — an empty
    /// failure that used its forward is `EXHAUSTED`, mapped to `E_ACCEPTOR_GAS` — is proven through the
    /// nested predicate in the test above.)
    function test_maximal_text_body_validates() public {
        bytes32 t = _register(_structural(_f(1, DescribedCodec.KIND_TEXT_LF, 0, 0, 0, 8190, 0), 1));
        bytes memory text = new bytes(8190);
        for (uint256 i; i < text.length; ++i) {
            text[i] = 0x61;
        }
        bytes memory body = bytes.concat(hex"1ffe", text);
        _publish(t, body);
        (, uint64 at,,,) = hot().recordHeader(Keys.recordFromHash(t, keccak256(body)));
        assertTrue(at != 0, "the maximal text body landed");
    }

    // ---- case 13: the ordered prefix and whole-batch rollback -------------------------------------------------

    function test_predicate_reads_the_prefix_and_refusal_rolls_back() public {
        bytes32 t0 = _register(_structural(_f(1, DescribedCodec.KIND_BYTES, 0, 0, 0, 64, 0), 1));
        WrapperBoundPredicate p = _predicate(a);
        p.setMode(p.PREFIX());
        bytes memory fields = bytes.concat(
            _f(1, DescribedCodec.KIND_REF32, 0, 32, 0, 0, t0),
            _f(2, DescribedCodec.KIND_TEXT_LF, 0, 0, 1, 1024, 0)
        );
        bytes32 t = _registerCustom(a, _custom(address(p), fields, 2), address(p));
        bytes memory first = hex"0002beef";
        bytes32 ref = Keys.recordFromHash(t0, keccak256(first));
        bytes memory good = abi.encodePacked(ref, BODY);
        _exec(a, _two(_pub(t0, first), _pub(t, good)), _bodies(first, good));
        (, uint64 refAt,,,) = hot().recordHeader(ref);
        (, uint64 at,,,) = hot().recordHeader(Keys.recordFromHash(t, keccak256(good)));
        assertEq(at, refAt + 1, "the predicate saw the record admitted by the previous leaf");
        // a semantic refusal (a body ending in "!") and a structural one both roll back the prefix leaf
        first = hex"0002babe";
        ref = Keys.recordFromHash(t0, keccak256(first));
        bytes[2] memory bad =
            [abi.encodePacked(ref, hex"00026821"), abi.encodePacked(ref, hex"00036869")];
        for (uint256 i; i < 2; ++i) {
            _refused(
                _two(_pub(t0, first), _pub(t, bad[i])), _bodies(first, bad[i]), _rejected(1, t)
            );
        }
        (, at,,,) = hot().recordHeader(ref);
        assertEq(at, 0, "a refused batch leaked its prefix");
    }

    // ---- cases 9, 15, 18: portable Type and Record ids, Realm-local bindings ---------------------------------

    function test_portable_identity_across_realms() public {
        DescribedTypeRule other = new DescribedTypeRule();
        Realm memory b = _deployRealm(keccak256("described/second"), other);
        assertEq(
            address(other).codehash, address(rule).codehash, "one wrapper build, two instances"
        );
        // structural: the same declaration installs the same Type; the same body is the same Record
        bytes memory d = _structural(_textFields(), 1);
        bytes32 t = _register(a, d);
        assertEq(_register(b, d), t, "the declaration is chain- and Realm-free");
        assertEq(
            b.registry.typeInfo(t).mandatory, address(other), "each Realm pins its own instance"
        );
        assertEq(_publish(a, t, BODY), _publish(b, t, BODY), "portable record identity");
        // custom: retention installs nothing, and the source binding does not authorize the destination
        WrapperBoundPredicate pa = _predicate(a);
        WrapperBoundPredicate pb = _predicate(b);
        assertEq(address(pa).codehash, address(pb).codehash);
        bytes memory dc = _custom(address(pa), _textFields(), 1);
        bytes32 tc = _registerCustom(a, dc, address(pa));
        (, bytes memory sig) = _declare(b, dc);
        b.registry.retainDeclaration(dc, sig);
        assertEq(b.registry.typeInfo(tc).mandatory, address(0), "retention is not admission");
        _refused(
            b,
            _one(_pub(tc, BODY)),
            _bodies(BODY),
            abi.encodeWithSelector(E_UNKNOWN_TYPE.selector, uint8(0), tc)
        );
        bytes memory sourceAuth =
            _sign(PK, a.registry.bindingDigest(_bindingId(a, tc, address(pa))));
        vm.expectRevert(abi.encodeWithSelector(E_BINDING.selector, uint8(5)));
        b.registry.registerDescribed(dc, sig, address(pb), sourceAuth);
        assertEq(_registerCustom(b, dc, address(pb)), tc, "the custom Type id is portable");
        assertEq(_publish(a, tc, BODY), _publish(b, tc, BODY), "portable custom record identity");
        assertTrue(
            a.registry.typeInfo(tc).bindingId != b.registry.typeInfo(tc).bindingId,
            "the binding is Realm-local"
        );
    }

    function _tail(bytes memory err) internal pure returns (bytes memory out) {
        out = new bytes(err.length - 4);
        for (uint256 i; i < out.length; ++i) {
            out[i] = err[i + 4];
        }
    }
}
