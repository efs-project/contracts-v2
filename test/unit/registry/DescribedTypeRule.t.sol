// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {DescribedRealm} from "../../harness/doubles/DescribedRealm.sol";
import {Descriptors} from "../../harness/Descriptors.sol";
import {GasRelay} from "../../harness/doubles/DescribedPredicates.sol";
import {DescribedCodec} from "../../../src/types/DescribedCodec.sol";
import {Keys} from "../../../src/lib/Keys.sol";
import {TypeInfo} from "../../../src/interfaces/ITypeRegistry.sol";
import {AcceptContext, IAcceptor, RefHeader} from "../../../src/interfaces/IAcceptor.sol";
import {
    E_ACCEPTOR_CODE,
    E_BINDING,
    E_BLOB,
    E_BODY,
    E_CODEC,
    E_DECLARATION,
    E_NOT_CONTROLLER,
    E_REF,
    E_TYPE_MISMATCH,
    E_UNKNOWN_TYPE
} from "../../../src/interfaces/Errors.sol";

// The twenty `DescribedTypeProfile` cases (prototype `L/test/DescribedTypeProfile.t.sol`, design §16.3
// unit/registry) → v2. "this file" is test/unit/registry/DescribedTypeRule.t.sol; "Custom" is
// DescribedTypeRuleCustom.t.sol beside it; "S14" is test/security/WrapperContext.t.sol.
//   1 unknown_publish_and_reuse_refuse_initial_profile       → this file test_unregistered_or_retained_only_type_is_unknown
//   2 public_registration_retains_bytes_and_requires_structure → this file test_structural_registration_and_body_law
//   3 custom_instance_valid_structure_and_callback_both_mandatory (L:72) → Custom test_structure_and_predicate_are_both_mandatory
//   4 custom_signature_scope_and_same_code_different_state_squatting (L:88) → Custom test_binding_selects_the_instance_not_the_code
//   5 direct_forged_context_and_fake_ledger_cannot_impersonate → S14 test_ctx_ledger_must_be_the_caller,
//                                                               test_lookalike_coordinator_*
//   6 custom_bad_bool_oversized_return_exhaustion_and_code_drift_refuse (L:120) → Custom test_hostile_predicates_through_the_kernel
//                                                               (v2 change: exhaustion is E_ACCEPTOR_GAS, not a refusal)
//   7 descriptor_canonicality_and_body_negative_matrix       → this file test_text_body_negative_matrix (body half; the
//                                                               descriptor half is TypeRegistry.t.sol testHeaderRefusals)
//   8 public_relayer_wrong_signature_zero_custom_fields_and_opaque_boundary → this file
//                                                               test_relayed_registration_and_the_declarer_is_no_administrator
//                                                               (the opaque `register(shape, rule, refs)` path does not exist in v2)
//   9 portable_destination_unchanged_declaration_and_custom_retention_only → Custom test_portable_identity_across_realms
//  10 unknown_future_leaf_refuses_before_callback_registration → not applicable: index-callback ordering (a Type registered
//                                                               from a callback), owned by integration/atomicity; no wrapper path
//  11 final_failure_rolls_back_described_records_and_nonce    → not applicable: a final-phase index refusal is
//                                                               integration/atomicity MatchedRollback; the wrapper has no final phase
//                                                               (its own whole-batch rollback is case 13)
//  12 all_kinds_optional_presence_and_checked_reference_projection → this file test_every_field_kind_and_exact_reference,
//                                                               test_any_and_self_references
//  13 ordered_prefix_custom_reads_and_whole_batch_rollback (L:213) → Custom test_predicate_reads_the_prefix_and_refusal_rolls_back
//  14 note_maxima_and_max_descriptor_field_reference_body_bytes_combination → this file test_note_and_joint_maxima
//  15 signed_native_duplicate_and_portable_record_identity   → duplicate + portable halves: this file
//                                                               test_structural_registration_and_body_law and Custom
//                                                               test_portable_identity_across_realms; the signed lane is not ported
//                                                               (the wrapper sees the same context on every lane; lanes are unit/ingress)
//  16 retained_declaration_before_opaque_registration_does_not_install_interpretation → this file
//                                                               test_unregistered_or_retained_only_type_is_unknown (no opaque path)
//  17 zero_field_unit_type_requires_exact_empty_body          → this file test_zero_field_type_requires_the_empty_body
//  18 custom_another_realm_requires_its_own_binding_but_preserves_portable_identity (L:265) → Custom
//                                                               test_portable_identity_across_realms
//  19 wrong_local_authority_chain_and_custom_code_refuse_atomically → wrong signer and wrong runtime: Custom
//                                                               test_binding_selects_the_instance_not_the_code; chain scope: S14
//                                                               test_binding_id_is_recomputed
//  20 descriptor_code_and_bounded_registry_return_are_rechecked → this file test_blob_and_wrapper_code_are_rechecked
//                                                               (the v2 wrapper reads no registry, so the bounded-return half is moot)

/// @notice `DescribedTypeRule/1` (design §5.10, §9.1–9.2) through the real kernel, registry and index: grade-1
///         Types over every field kind, valid bodies that land and fold `by-type`, invalid bodies refused
///         `E_REJECTED(leaf, typeId)` with the nonce and every touched row intact, and the refusal reason the SDK
///         reads by simulating the wrapper as the ledger.
contract DescribedTypeRuleTest is DescribedRealm {
    using Descriptors for Descriptors.Params;

    bytes32[] internal none;
    GasRelay internal relay;

    function _bytesFields() internal pure returns (bytes memory) {
        return _f(1, DescribedCodec.KIND_BYTES, 0, 0, 0, 64, 0);
    }

    function _body(uint8 leaf, uint8 code) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(E_BODY.selector, leaf, code);
    }

    function _one32(bytes32 x) internal pure returns (bytes32[] memory l) {
        l = new bytes32[](1);
        l[0] = x;
    }

    function test_activateWrapper_reads_the_wrappers_own_constants() public view {
        (address impl, bytes32 codehash, uint8 codec, bytes32 grammar) = registry().wrapper(1);
        assertEq(impl, address(rule));
        assertEq(codehash, address(rule).codehash);
        assertEq(codec, 1);
        assertEq(grammar, keccak256("efs2/described-grammar/1"));
        assertEq(rule.codecVersion(), 1);
        assertEq(rule.grammarProfile(), grammar);
    }

    function test_structural_registration_and_body_law() public {
        uint64 m = registry().mutations();
        bytes memory d = _structural(_textFields(), 1);
        bytes32 t = _register(d);
        assertEq(registry().mutations(), m, "registration never bumps mutations");
        assertEq(keccak256(registry().descriptorBytes(t)), keccak256(d), "bytes retained");
        TypeInfo memory info = registry().typeInfo(t);
        assertEq(info.grade, 1);
        assertEq(info.mandatory, address(rule));
        assertEq(info.ruleId, address(rule).codehash);
        assertEq(info.custom, address(0));
        bytes32 id = _publish(t, hex"00026869");
        _refuse(t, hex"00036869"); // declares three bytes, carries two
        _expectWrapper(t, hex"00036869", none, _body(0, 7));
        // a second admission of the same body passes the wrapper again and adds an occurrence
        _exec(a, _one(_pub(t, hex"00026869")), _bodies(hex"00026869"));
        (,,, uint64 occurrences,) = hot().recordHeader(id);
        assertEq(occurrences, 2);
    }

    function test_unregistered_or_retained_only_type_is_unknown() public {
        bytes memory d = _structural(_textFields(), 1);
        (bytes32 t, bytes memory sig) = _declare(a, d);
        bytes memory unknown = abi.encodeWithSelector(E_UNKNOWN_TYPE.selector, uint8(0), t);
        bytes32 rid = Keys.recordFromHash(t, keccak256(hex"00026869"));
        _refused(_one(_pub(t, hex"00026869")), _bodies(hex"00026869"), unknown);
        _refused(_one(_reuse(t, rid)), _bodies(""), unknown);
        // retention writes the declaration row and never installs
        registry().retainDeclaration(d, sig);
        (, bool installed,) = registry().declaration(t);
        assertFalse(installed);
        _refused(_one(_pub(t, hex"00026869")), _bodies(hex"00026869"), unknown);
    }

    function test_text_body_negative_matrix() public {
        bytes32 t = _register(_structural(_textFields(), 1));
        bytes[7] memory bad = [
            bytes(hex""),
            hex"0000",
            hex"00016100",
            hex"000109",
            hex"00017f",
            hex"0001ff",
            hex"000261"
        ];
        uint8[7] memory code = [7, 9, 11, 10, 10, 10, 7];
        for (uint256 i; i < bad.length; ++i) {
            _refuse(t, bad[i]);
            _expectWrapper(t, bad[i], none, _body(0, code[i]));
        }
        _publish(t, hex"00020a20"); // LF and space are the TEXT_LF domain
    }

    function test_every_field_kind_and_exact_reference() public {
        bytes32 t0 = _register(_structural(_bytesFields(), 1));
        bytes32 other = _register(_structural(_bytesFields(), 1));
        bytes memory fields = bytes.concat(
            _f(1, DescribedCodec.KIND_REF32, 0, 32, 0, 0, t0),
            _f(2, DescribedCodec.KIND_BYTES32, 0, 32, 0, 0, 0),
            _f(3, DescribedCodec.KIND_UINT, 0, 2, 10, 1000, 0),
            _f(4, DescribedCodec.KIND_BOOL, 0, 1, 0, 1, 0),
            _f(5, DescribedCodec.KIND_ENUM, 0, 1, 1, 2, 0),
            _f(6, DescribedCodec.KIND_BYTES, 0, 0, 0, 4, 0),
            _f(7, DescribedCodec.KIND_TEXT_LF, 0, 0, 1, 1024, 0),
            _f(8, DescribedCodec.KIND_TEXT_PRINTABLE, 1, 0, 1, 64, 0)
        );
        bytes32 t = _register(_structural(fields, 8));
        assertEq(registry().refTypes(t)[0], t0, "the exact reference Type is projected");
        bytes32 ref = _publish(t0, hex"0002aabb");
        // ref ‖ bytes32 ‖ u16 10 ‖ bool 1 ‖ enum 2 ‖ bytes "beef" ‖ text "hi" ‖ optional title absent
        bytes memory valid =
            abi.encodePacked(ref, bytes32(uint256(99)), hex"000a01020002beef0002686900");
        _publish(t, valid);
        uint8[6] memory pos = [65, 66, 67, 69, 76, 76];
        bytes1[6] memory value = [bytes1(0x09), 0x02, 0x03, 0x05, 0x02, 0x01];
        uint8[6] memory code = [9, 9, 9, 9, 6, 7]; // below lo, bool 2, enum 3, length 5 > 4, presence 2, absent
        for (uint256 i; i < 6; ++i) {
            bytes memory b = bytes.concat(valid);
            b[pos[i]] = value[i];
            _refuse(t, b);
            _expectWrapper(t, b, _one32(ref), _body(0, code[i]));
        }
        bytes memory present =
            abi.encodePacked(ref, bytes32(uint256(99)), hex"000a01020002beef0002686901000141");
        _publish(t, present);
        present[present.length - 1] = 0x0a; // LF is outside TEXT_PRINTABLE
        _refuse(t, present);
        _expectWrapper(t, present, _one32(ref), _body(0, 10));
        // the kernel checks references before the wrapper: another Type, a missing record, a sentinel word
        bytes32 wrong = _publish(other, hex"0002aabb");
        bytes32[3] memory leading = [wrong, keccak256("absent"), bytes32(uint256(1))];
        uint8[3] memory refCode = [2, 1, 3];
        for (uint256 i; i < 3; ++i) {
            bytes memory b = bytes.concat(valid);
            bytes32 w = leading[i];
            assembly ("memory-safe") {
                mstore(add(b, 32), w)
            }
            _refused(
                _one(_pub(t, b)),
                _bodies(b),
                abi.encodeWithSelector(E_REF.selector, uint8(0), uint8(0), refCode[i])
            );
        }
    }

    function test_descriptor_reference_grammar_is_refused_at_registration() public {
        bytes memory optionalRef = _structural(_f(1, DescribedCodec.KIND_REF32, 1, 32, 0, 0, 0), 1);
        bytes memory duplicate = _structural(bytes.concat(_bytesFields(), _bytesFields()), 2);
        bytes memory lateRef = _structural(
            bytes.concat(_bytesFields(), _f(2, DescribedCodec.KIND_REF32, 0, 32, 0, 0, 0)), 2
        );
        uint16 first = uint16(134 + 11 + 29); // header + "test-type/1" + the default description
        vm.expectRevert(abi.encodeWithSelector(E_CODEC.selector, first, uint8(24)));
        registry().retainDeclaration(optionalRef, "");
        vm.expectRevert(abi.encodeWithSelector(E_CODEC.selector, first + 164, uint8(21)));
        registry().retainDeclaration(duplicate, "");
        vm.expectRevert(abi.encodeWithSelector(E_CODEC.selector, first + 164, uint8(24)));
        registry().retainDeclaration(lateRef, "");
    }

    function test_any_and_self_references() public {
        bytes32 t0 = _register(_structural(_bytesFields(), 1));
        bytes32 t1 = _register(_structural(_bytesFields(), 1));
        bytes memory anyFields = bytes.concat(
            _f(1, DescribedCodec.KIND_REF32, 0, 32, 0, 0, 0),
            _f(2, DescribedCodec.KIND_BYTES, 0, 0, 0, 64, 0)
        );
        bytes32 anyT = _register(_structural(anyFields, 2));
        assertEq(registry().refTypes(anyT)[0], 0, "ANY");
        bytes32 r0 = _publish(t0, hex"0001aa");
        bytes32 r1 = _publish(t1, hex"0001bb");
        _publish(anyT, abi.encodePacked(r0, hex"0000"));
        _publish(anyT, abi.encodePacked(r1, hex"0000"));
        // SELF: a reference to a record of this same Type
        bytes32 selfT = _register(
            _structural(
                bytes.concat(
                    _f(1, DescribedCodec.KIND_REF32, 0, 32, 0, 0, bytes32(uint256(1))),
                    _f(2, DescribedCodec.KIND_BYTES, 0, 0, 0, 64, 0)
                ),
                2
            )
        );
        assertEq(registry().refTypes(selfT)[0], bytes32(uint256(1)), "SELF");
        // codec 1 has no nullable reference, so a SELF Type has no first record: every candidate names a
        // record of another Type (or none) and the kernel refuses it before the wrapper
        bytes memory b = abi.encodePacked(r0, hex"0000");
        _refused(
            _one(_pub(selfT, b)),
            _bodies(b),
            abi.encodeWithSelector(E_REF.selector, uint8(0), uint8(0), uint8(2))
        );
        // the wrapper's own SELF law: a header of this Type passes, a header of another Type refuses
        RefHeader[] memory h = new RefHeader[](1);
        h[0].typeId = selfT;
        _expectWrapper(_ctxOf(a, selfT), b, _one32(r0), h, "");
        h[0].typeId = t0;
        _expectWrapper(
            _ctxOf(a, selfT),
            b,
            _one32(r0),
            h,
            abi.encodeWithSelector(E_REF.selector, uint8(0), uint8(0), uint8(2))
        );
    }

    function test_note_and_joint_maxima() public {
        bytes memory fields = bytes.concat(
            _f(1, DescribedCodec.KIND_TEXT_LF, 0, 0, 1, 1024, 0),
            _f(2, DescribedCodec.KIND_TEXT_PRINTABLE, 1, 0, 1, 64, 0)
        );
        bytes32 t = _register(_structural(fields, 2));
        bytes memory body =
            abi.encodePacked(uint16(1024), _fill(1024, 0x61), hex"01", uint16(64), _fill(64, 0x62));
        _publish(t, body);
        body[1025] = 0x0a; // LF inside the text
        _publish(t, body);
        body[body.length - 1] = 0x0a; // LF inside the printable title
        _refuse(t, body);
        // the joint maximum: a 4,096-byte descriptor (8 exact references, 7 bytes, an 8,192-bounded BYTES)
        // and an 8,192-byte body
        bytes32 t0 = _register(_structural(_bytesFields(), 1));
        bytes32 ref = _publish(t0, hex"0001aa");
        fields = "";
        body = "";
        bytes32[] memory refs = new bytes32[](8);
        for (uint256 i; i < 8; ++i) {
            fields = bytes.concat(fields, _f(i + 1, DescribedCodec.KIND_REF32, 0, 32, 0, 0, t0));
            body = bytes.concat(body, ref);
            refs[i] = ref;
        }
        for (uint256 i; i < 7; ++i) {
            fields = bytes.concat(fields, _f(i + 9, DescribedCodec.KIND_UINT, 0, 1, 0, 255, 0));
            body = bytes.concat(body, hex"01");
        }
        fields = bytes.concat(fields, _f(16, DescribedCodec.KIND_BYTES, 0, 0, 0, 8192, 0));
        Descriptors.Params memory p = _params(1, 0, fields, 16);
        p.description = _fill(4096 - 134 - p.name.length - 16 * 164, 0x64);
        bytes memory d = p.encode();
        assertEq(d.length, 4096, "descriptor maximum");
        t = _register(d);
        body = bytes.concat(body, abi.encodePacked(uint16(7927)), new bytes(7927));
        assertEq(body.length, 8192, "body maximum");
        _publish(t, body);
        _expectWrapper(t, body, refs, "");
        emit log_named_uint("wrapper gas, 4,096 B descriptor + 8,192 B body", _gasOf(t, body, refs));
        bytes memory over = bytes.concat(body, hex"00");
        _refused(_one(_pub(t, over)), _bodies(over), _body(0, 1)); // the kernel's own cap comes first
    }

    function test_zero_field_type_requires_the_empty_body() public {
        bytes32 t = _register(_structural("", 0));
        _publish(t, "");
        _refuse(t, hex"00");
        _expectWrapper(t, hex"00", none, _body(0, 11));
    }

    function test_relayed_registration_and_the_declarer_is_no_administrator() public {
        bytes memory d = _structural(_textFields(), 1);
        (bytes32 t, bytes memory sig) = _declare(a, d);
        bytes memory wrongSigner = _sign(0xB0B, registry().declarationDigest(t));
        vm.expectRevert(abi.encodeWithSelector(E_DECLARATION.selector, uint8(4)));
        registry().registerDescribed(d, wrongSigner, address(0), "");
        vm.expectRevert(abi.encodeWithSelector(E_BINDING.selector, uint8(1)));
        registry().registerDescribed(d, sig, address(0xC0FFEE), ""); // grade 1 carries no predicate
        uint64 before = registry().catalogCount();
        vm.prank(address(0xCAFE)); // anyone relays
        registry().registerDescribed(d, sig, address(0), "");
        vm.prank(address(0xCAFE));
        registry().registerDescribed(d, sig, address(0), "");
        assertEq(registry().catalogCount(), before + 1, "a duplicate does not advance the catalog");
        vm.prank(key);
        vm.expectRevert(abi.encodeWithSelector(E_NOT_CONTROLLER.selector, key));
        registry().activatePolicy(t, address(0));
        _publish(t, hex"00026869");
    }

    function test_blob_and_wrapper_code_are_rechecked() public {
        bytes memory d = _structural(_textFields(), 1);
        bytes32 t = _register(d);
        _publish(t, hex"00026869");
        address blob = registry().typeInfo(t).descriptorBlob;
        bytes memory code = blob.code;
        // a descriptor byte (the name's first) changes: the wrapper re-derives another id
        bytes memory bad = bytes.concat(code);
        bad[1 + 134] = bytes1(uint8(bad[1 + 134]) ^ 0x01);
        bytes memory changed = new bytes(d.length);
        for (uint256 i; i < d.length; ++i) {
            changed[i] = bad[i + 1];
        }
        vm.etch(blob, bad);
        _refuse(t, hex"00026868");
        _expectWrapper(
            t,
            hex"00026868",
            none,
            abi.encodeWithSelector(E_TYPE_MISMATCH.selector, uint8(0), t, _typeIdOf(changed))
        );
        // the declaration signature is not part of the Type: a changed signature byte still accepts
        bad = bytes.concat(code);
        bad[bad.length - 1] = bytes1(uint8(bad[bad.length - 1]) ^ 0x01);
        vm.etch(blob, bad);
        _publish(t, hex"00026868");
        // no STOP prefix, or a truncated descriptor: E_BLOB
        bad = bytes.concat(code);
        bad[0] = 0x01;
        vm.etch(blob, bad);
        _refuse(t, hex"00026867");
        _expectWrapper(t, hex"00026867", none, abi.encodeWithSelector(E_BLOB.selector, blob));
        bad = new bytes(d.length); // 0x00 ‖ descriptor without its last byte
        for (uint256 i; i < bad.length; ++i) {
            bad[i] = code[i];
        }
        vm.etch(blob, bad);
        _refuse(t, hex"00026867");
        _expectWrapper(t, hex"00026867", none, abi.encodeWithSelector(E_BLOB.selector, blob));
        vm.etch(blob, code);
        _publish(t, hex"00026867");
        // the wrapper's own code is pinned by the kernel per acceptance
        vm.etch(address(rule), hex"00");
        _refused(
            _one(_pub(t, hex"00026866")),
            _bodies(hex"00026866"),
            abi.encodeWithSelector(E_ACCEPTOR_CODE.selector, uint8(0), address(rule))
        );
    }

    /// The wrapper's own gas for one acceptance (plus a warm call), measured from a `GasRelay` that is
    /// `ctx.ledger`: neither a prank nor a direct call from the test contract, both of whose accounting adds
    /// a calldata-proportional charge in Foundry.
    function _gasOf(bytes32 t, bytes memory body, bytes32[] memory refs)
        internal
        returns (uint256 used)
    {
        if (address(relay) == address(0)) relay = new GasRelay();
        AcceptContext memory c = _ctxOf(a, t);
        c.ledger = address(relay);
        bytes memory data = abi.encodeCall(IAcceptor.accept, (c, body, refs, _headersOf(a, refs)));
        bool ok;
        bytes memory reply;
        (ok, reply, used) = relay.relay(address(rule), data, 30_000_000);
        assertTrue(ok && keccak256(reply) == keccak256(abi.encode(IAcceptor.accept.selector)));
    }

    /// The codec's TEXT loop dominates: logged so a regression or an optimisation of `DescribedCodec` shows.
    function test_wrapper_gas_per_acceptance() public {
        bytes32 small = _register(_structural(_textFields(), 1));
        emit log_named_uint("TEXT_LF 2 B", _gasOf(small, hex"00026869", none));
        emit log_named_uint(
            "TEXT_LF 1,024 B", _gasOf(small, bytes.concat(hex"0400", _fill(1024, 0x61)), none)
        );
        bytes32 raw = _register(_structural(_f(1, DescribedCodec.KIND_BYTES, 0, 0, 0, 8190, 0), 1));
        emit log_named_uint(
            "BYTES 8,190 B", _gasOf(raw, bytes.concat(hex"1ffe", new bytes(8190)), none)
        );
    }

    function _fill(uint256 n, bytes1 c) internal pure returns (bytes memory out) {
        out = new bytes(n);
        for (uint256 i; i < n; ++i) {
            out[i] = c;
        }
    }
}
