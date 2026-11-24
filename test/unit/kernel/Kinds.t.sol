// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {KernelFixture} from "../../harness/KernelFixture.sol";
import {Keys} from "../../../src/lib/Keys.sol";
import {Layout} from "../../../src/core/layout/Layout.sol";
import {Action, ActionKind} from "../../../src/interfaces/Actions.sol";
import {ILedger} from "../../../src/interfaces/ILedger.sol";
import {Effect} from "../../../src/interfaces/Index.sol";
import {
    E_BODY,
    E_CAS,
    E_MISSING_RECORD,
    E_NOT_LIVE,
    E_SHAPE,
    E_SUBJECT_EXISTS,
    E_TARGET_MISSING,
    E_TARGET_TYPE,
    E_TYPE_MISMATCH,
    E_UNKNOWN_TYPE,
    E_WITHDRAW
} from "../../../src/interfaces/Errors.sol";

/// @notice One happy path and every refusal of each action kind through the apply delegate (design §6.4,
///         §4.3; §2.2 S11/S12; ports of RecordOccurrenceBounds, BindingRelease and FilesWithdrawal semantics).
contract KindsTest is KernelFixture {
    bytes32 internal constant ROLE_T = keccak256("kinds/role/typed");
    bytes32 internal constant SA = keccak256("kinds/subject/a");
    bytes32 internal constant SB = keccak256("kinds/subject/b");

    struct Row {
        uint8 kind;
        uint8 leaf;
        uint48 publication;
        uint48 bindingOrdinal;
        uint48 expectedRevision;
        uint48 prevAdmission;
        uint8 withdrawn;
        uint16 policyRow;
        uint16 roleRow;
        uint8 targetKind;
        bytes32 a;
    }

    struct Head {
        uint8 state;
        uint64 revision;
        uint64 admission;
        uint8 targetKind;
        uint64 prev;
        uint64 ordinal;
        bytes32 target;
    }

    function _row(uint256 o) internal view returns (Row memory r) {
        uint256 s = Layout.admissionsRowsSlot(o);
        (
            r.kind,
            r.leaf,
            r.publication,
            r.bindingOrdinal,
            r.expectedRevision,
            r.prevAdmission,
            r.withdrawn,
            r.policyRow,
            r.roleRow,
            r.targetKind
        ) = Layout.unpackAdmissionRowWord0(_raw(s));
        r.a = _raw(s + 1);
    }

    function _head(bytes32 key) internal view returns (Head memory h) {
        (h.state, h.revision, h.admission, h.targetKind, h.prev, h.ordinal, h.target) =
            hot.head(key);
    }

    function _occ(bytes32 rid) internal view returns (uint64 o) {
        (,,, o,) = hot.recordHeader(rid);
    }

    function _logged(Action[] memory a, bytes[] memory b) internal returns (Effect[] memory e) {
        vm.recordLogs();
        _exec(a, b);
        (e,) = _effects(vm.getRecordedLogs());
    }

    function _land(bytes memory body) internal returns (bytes32 rid) {
        rid = _rid(TYPE_OK, body);
        _exec(_acts(_publish(TYPE_OK, body)), _bodies(1, 0, body));
    }

    function _pattern(uint256 len, uint256 seed) internal pure returns (bytes memory b) {
        b = new bytes(len);
        for (uint256 i; i < len; ++i) {
            b[i] = bytes1(uint8(seed * 31 + i * 7) | 1);
        }
    }

    function _targetWrites(Vm.AccountAccess[] memory acc, bytes32 key)
        internal
        view
        returns (uint256 n)
    {
        bytes32 slot = bytes32(Layout.bindingsHeadsSlot(key) + 1);
        for (uint256 i; i < acc.length; ++i) {
            if (acc[i].reverted) continue;
            for (uint256 j; j < acc[i].storageAccesses.length; ++j) {
                Vm.StorageAccess memory s = acc[i].storageAccesses[j];
                if (s.isWrite && !s.reverted && s.account == k.proxy && s.slot == slot) ++n;
            }
        }
    }

    /// One action as the only leaf / after one CREATE leaf, refused with `err` and no state change.
    function _refuse1(Action memory a, bytes memory body, bytes memory err) internal {
        _expectNoChange(_acts(a), _bodies(1, 0, body), err);
    }

    function _refuse2(Action memory a, bytes memory body, bytes memory err) internal {
        _expectNoChange(_acts(_create("c"), a), _bodies(2, 1, body), err);
    }

    // ---- PUBLISH -------------------------------------------------------------------------------------------

    function test_publish_fresh_record() public {
        bytes memory body = "kinds/fresh";
        bytes32 rid = _rid(TYPE_OK, body);
        bytes32 before = digest();
        Effect[] memory e = _logged(_acts(_publish(TYPE_OK, body)), _bodies(1, 0, body));
        assertTrue(digest() != before, "the digest sees a landed write");
        (bytes32 t, uint64 first, uint32 len, uint64 occ, uint8 carrier) = hot.recordHeader(rid);
        assertEq(abi.encode(t, first, len, occ, carrier), abi.encode(TYPE_OK, 1, body.length, 1, 0));
        (, uint64 records,,) = _counts();
        assertEq(records, 1);
        Row memory r = _row(1);
        assertEq(
            abi.encode(r.kind, r.leaf, r.publication, r.policyRow, r.a), abi.encode(1, 0, 1, 1, rid)
        );
        assertEq(e.length, 1);
        assertTrue(e[0].freshRecord);
        assertEq(abi.encode(e[0].kind, e[0].recordId, e[0].typeId), abi.encode(1, rid, TYPE_OK));
    }

    function test_publish_same_body_twice_bumps_occurrences() public {
        bytes memory body = "kinds/twice";
        bytes32 rid = _rid(TYPE_OK, body);
        bytes[] memory b = new bytes[](2);
        (b[0], b[1]) = (body, body);
        Effect[] memory e = _logged(_acts(_publish(TYPE_OK, body), _publish(TYPE_OK, body)), b);
        assertTrue(e[0].freshRecord && !e[1].freshRecord, "only the first admission is fresh");
        assertEq(_occ(rid), 2);
        _land(body);
        (, uint64 first,, uint64 occ,) = hot.recordHeader(rid);
        (, uint64 records,,) = _counts();
        assertEq(abi.encode(first, occ, records), abi.encode(1, 3, 1));
    }

    function test_publish_body_lengths_round_trip_with_masked_tail() public {
        uint256[7] memory lens = [uint256(0), 1, 31, 32, 33, 64, 8192];
        for (uint256 i; i < lens.length; ++i) {
            bytes memory body = _pattern(lens[i], i);
            bytes32 rid = _land(body);
            (,, uint32 len,,) = hot.recordHeader(rid);
            assertEq(len, lens[i], "recordHeader length");
            bytes memory padded = bytes.concat(body, new bytes(32));
            uint256 words = (lens[i] + 31) / 32;
            for (uint256 w; w < words; ++w) {
                bytes32 want;
                assembly ("memory-safe") {
                    want := mload(add(add(padded, 32), mul(w, 32)))
                }
                assertEq(_raw(Layout.recordsBodyWordsSlot(rid, w)), want, "body word");
            }
            assertEq(_raw(Layout.recordsBodyWordsSlot(rid, words)), 0, "no word beyond length");
        }
    }

    /// S11: dirty ABI padding after a body in the outer calldata never reaches storage. (The kernel re-encodes
    /// the body into the apply payload, which zero-pads; `_storeBody`'s mask is the second line of defence.)
    function test_publish_dirty_calldata_padding_never_reaches_storage() public {
        bytes memory body = new bytes(33);
        for (uint256 i; i < 33; ++i) {
            body[i] = bytes1(0xaa);
        }
        Action[] memory a = _acts(_publish(TYPE_OK, body));
        _track(principal, a);
        bytes memory data =
            abi.encodeCall(ILedger.execute, (a, _bodies(1, 0, body), _native(0), ""));
        uint256 start;
        for (uint256 p = 4; p + 33 <= data.length; ++p) {
            if (
                data[p] == bytes1(0xaa) && data[p + 32] == bytes1(0xaa)
                    && data[p - 1] == bytes1(0x21)
            ) {
                start = p;
                break;
            }
        }
        assertTrue(start != 0);
        for (uint256 i = start + 33; i < start + 64; ++i) {
            data[i] = bytes1(0xff);
        }
        (bool ok,) = k.proxy.call(data);
        assertTrue(ok);
        bytes32 rid = _rid(TYPE_OK, body);
        assertEq(_raw(Layout.recordsBodyWordsSlot(rid, 1)), bytes32(bytes1(0xaa)), "tail canonical");
    }

    function test_publish_body_bounds_and_hash() public {
        bytes memory big = new bytes(8193);
        _refuse2(
            _publish(TYPE_OK, big), big, abi.encodeWithSelector(E_BODY.selector, uint8(1), uint8(1))
        );
        Action memory wrong = _publish(TYPE_OK, "declared");
        _refuse2(wrong, "sent", abi.encodeWithSelector(E_BODY.selector, uint8(1), uint8(2)));
        big = _pattern(8192, 9);
        _land(big); // 8,192 bytes is the limit itself
        bytes32 unknown = keccak256("kinds/unregistered");
        _refuse1(
            _publish(unknown, "u"),
            "u",
            abi.encodeWithSelector(E_UNKNOWN_TYPE.selector, uint8(0), unknown)
        );
    }

    // ---- REUSE ---------------------------------------------------------------------------------------------

    function test_reuse_bumps_occurrence_and_records_row() public {
        bytes32 rid = _land("kinds/reuse");
        Effect[] memory e = _logged(_acts(_reuse(TYPE_OK, rid)), _bodies(1));
        assertEq(_occ(rid), 2);
        Row memory r = _row(2);
        assertEq(abi.encode(r.kind, r.a, r.policyRow), abi.encode(2, rid, 1));
        assertFalse(e[0].freshRecord);
        assertEq(e[0].recordId, rid);
    }

    function test_reuse_refusals() public {
        bytes32 rid = _land("kinds/reuse/refusals");
        bytes32 missing = keccak256("kinds/missing");
        _refuse2(
            _reuse(TYPE_OK, missing),
            "",
            abi.encodeWithSelector(E_MISSING_RECORD.selector, uint8(1), missing)
        );
        _refuse1(
            _reuse(TYPE_OK2, rid),
            "",
            abi.encodeWithSelector(E_TYPE_MISMATCH.selector, uint8(0), TYPE_OK2, TYPE_OK)
        );
        _refuse1(
            _reuse(TYPE_OK, rid), "x", abi.encodeWithSelector(E_SHAPE.selector, uint8(0), uint8(3))
        );
    }

    // ---- BIND ------------------------------------------------------------------------------------------------

    function test_bind_fresh_keys_mint_ordinals_in_order() public {
        bytes32 r = _land("kinds/bind/target");
        Effect[] memory e =
            _logged(_acts(_bind(FOLDER, SA, ROLE, r, 0), _bind(FOLDER, SB, 0, r, 0)), _bodies(2));
        Head memory a = _head(_key(principal, FOLDER, SA, ROLE));
        assertEq(abi.encode(a), abi.encode(Head(1, 1, 2, 1, 0, 1, r)));
        assertEq(_head(_key(principal, FOLDER, SB, 0)).ordinal, 2);
        (,, uint64 bindings,) = _counts();
        assertEq(bindings, 2);
        bytes32 posB = Keys.position(FOLDER, SB, 0);
        assertEq(_raw(Layout.bindingsBindingPositionSlot(1)), Keys.position(FOLDER, SA, ROLE));
        assertEq(_raw(Layout.bindingsBindingPositionSlot(2)), posB);
        uint256 ps = Layout.bindingsPositionsSlot(posB);
        assertEq(abi.encode(_raw(ps), _raw(ps + 1), _raw(ps + 2)), abi.encode(FOLDER, SB, 0));
        assertEq(abi.encode(e[0].transitionKind, e[0].bindingOrdinal), abi.encode(1, 1));
        assertEq(abi.encode(e[1].transitionKind, e[1].bindingOrdinal), abi.encode(1, 2));
        Row memory row = _row(2);
        assertEq(
            abi.encode(row.kind, row.a, row.targetKind, row.prevAdmission), abi.encode(3, r, 1, 0)
        );
    }

    function test_rebind_same_target_rewrites_meta_only() public {
        bytes32 r = _land("kinds/rebind");
        bytes32 key = _key(principal, FOLDER, SA, ROLE);
        _exec(_acts(_bind(FOLDER, SA, ROLE, r, 0)), _bodies(1));
        vm.startStateDiffRecording();
        Effect[] memory e = _logged(_acts(_bind(FOLDER, SA, ROLE, r, 1)), _bodies(1));
        assertEq(_targetWrites(vm.stopAndReturnStateDiff(), key), 0, "same target is not rewritten");
        assertEq(abi.encode(_head(key)), abi.encode(Head(1, 2, 3, 1, 2, 1, r)));
        assertEq(
            abi.encode(e[0].transitionKind, e[0].oldTarget, e[0].oldTargetKind), abi.encode(2, r, 1)
        );
        (,, uint64 bindings,) = _counts();
        assertEq(bindings, 1, "a rebind mints no ordinal");
    }

    function test_rebind_new_target_rewrites_target_word() public {
        bytes32 r1 = _land("kinds/rebind/1");
        bytes32 r2 = _land("kinds/rebind/2");
        bytes32 key = _key(principal, FOLDER, SA, ROLE);
        _exec(_acts(_bind(FOLDER, SA, ROLE, r1, 0)), _bodies(1));
        vm.startStateDiffRecording();
        Effect[] memory e = _logged(_acts(_bind(FOLDER, SA, ROLE, r2, 1)), _bodies(1));
        assertEq(_targetWrites(vm.stopAndReturnStateDiff(), key), 1);
        assertEq(_head(key).target, r2);
        assertEq(
            abi.encode(e[0].transitionKind, e[0].oldTarget, e[0].target), abi.encode(2, r1, r2)
        );
    }

    function test_restore_after_mask_and_after_release() public {
        bytes32 r = _land("kinds/restore");
        bytes32 key = _key(principal, FOLDER, SA, ROLE);
        _exec(_acts(_bind(FOLDER, SA, ROLE, r, 0), _unbind(FOLDER, SA, ROLE, 1)), _bodies(2));
        vm.startStateDiffRecording();
        Effect[] memory e = _logged(_acts(_bind(FOLDER, SA, ROLE, r, 2)), _bodies(1));
        assertEq(_targetWrites(vm.stopAndReturnStateDiff(), key), 0, "RESTORE reuses the kept word");
        assertEq(abi.encode(_head(key)), abi.encode(Head(1, 3, 4, 1, 3, 1, r)));
        assertEq(
            abi.encode(e[0].transitionKind, e[0].oldTarget, e[0].prevAdmission), abi.encode(5, 0, 3)
        );
        _exec(_acts(_release(FOLDER, SA, ROLE, 3)), _bodies(1));
        e = _logged(_acts(_bind(FOLDER, SA, ROLE, r, 4)), _bodies(1));
        assertEq(abi.encode(e[0].transitionKind, e[0].bindingOrdinal), abi.encode(5, 1));
        (,, uint64 bindings,) = _counts();
        assertEq(bindings, 1);
    }

    function test_bind_refusals() public {
        bytes32 r = _land("kinds/bind/refusals");
        bytes32 key = _key(principal, FOLDER, SA, ROLE);
        _exec(_acts(_bind(FOLDER, SA, ROLE, r, 0)), _bodies(1));
        _refuse2(
            _bind(FOLDER, SA, ROLE, r, 0),
            "",
            abi.encodeWithSelector(E_CAS.selector, key, uint64(0), uint64(1))
        );
        bytes32 nowhere = keccak256("kinds/nowhere");
        _refuse2(
            _bind(FOLDER, SB, ROLE, nowhere, 0),
            "",
            abi.encodeWithSelector(E_TARGET_MISSING.selector, uint8(1), nowhere)
        );
    }

    function test_bind_subject_target_kind_2() public {
        bytes32 sid = _sid(principal, "kinds/subject");
        Effect[] memory e =
            _logged(_acts(_create("kinds/subject"), _bind(FOLDER, SA, ROLE, sid, 0)), _bodies(2));
        assertEq(_head(_key(principal, FOLDER, SA, ROLE)).targetKind, 2);
        assertEq(_row(2).targetKind, 2);
        assertEq(abi.encode(e[1].targetKind, e[1].target), abi.encode(2, sid));
    }

    function test_role_expectation_E_TARGET_TYPE_and_roleRow() public {
        registry.setRoleExpectation(FOLDER, ROLE_T, TYPE_OK2, 3);
        bytes32 r1 = _land("kinds/role/1");
        _refuse1(
            _bind(FOLDER, SA, ROLE_T, r1, 0),
            "",
            abi.encodeWithSelector(E_TARGET_TYPE.selector, uint8(0), TYPE_OK2, TYPE_OK, uint16(3))
        );
        bytes memory body = "kinds/role/2";
        bytes32 r2 = _rid(TYPE_OK2, body);
        _exec(
            _acts(_publish(TYPE_OK2, body), _bind(FOLDER, SA, ROLE_T, r2, 0)), _bodies(2, 0, body)
        );
        assertEq(_row(3).roleRow, 3, "the role row is recorded per admission");
    }

    // DESIGN-DIVERGENCE: §6.4 BIND orders head state → CAS → target existence → role expectation; the kernel
    // runs the role expectation first (src/core/LedgerCore.sol:395-404) and only then the apply delegate's
    // state/CAS/target checks, so a typed role turns a CAS mismatch or a missing target into E_TARGET_TYPE.
    function test_role_expectation_precedes_cas_and_target_existence() public {
        registry.setRoleExpectation(FOLDER, ROLE_T, TYPE_OK2, 3);
        bytes32 r = _land("kinds/role/precedence");
        bytes32 nowhere = keccak256("kinds/nowhere");
        _refuse1(
            _bind(FOLDER, SA, ROLE_T, r, 7),
            "",
            abi.encodeWithSelector(E_TARGET_TYPE.selector, uint8(0), TYPE_OK2, TYPE_OK, uint16(3))
        );
        _refuse1(
            _bind(FOLDER, SA, ROLE_T, nowhere, 0),
            "",
            abi.encodeWithSelector(
                E_TARGET_TYPE.selector, uint8(0), TYPE_OK2, bytes32(0), uint16(3)
            )
        );
    }

    // KERNEL-BUG: LedgerApply.applyLeaf (src/core/LedgerApply.sol:70-91) never writes AdmissionRow.bindingOrdinal
    // or .expectedRevision, so a bind-kind row cannot be re-encoded into its signed Action (design §4.3: "purpose/
    // subject/role from position[bindingPosition[bindingOrdinal]] ... expectedRevision from meta"); an UNBIND/
    // RELEASE row (meta only, a == 0) then names no position at all.
    function test_bind_kind_rows_carry_ordinal_and_expected_revision() public {
        bytes32 r = _land("kinds/rows");
        _exec(
            _acts(
                _bind(FOLDER, SA, ROLE, r, 0),
                _bind(FOLDER, SA, ROLE, r, 1),
                _unbind(FOLDER, SA, ROLE, 2)
            ),
            _bodies(3)
        );
        for (uint64 o = 2; o <= 4; ++o) {
            Row memory row = _row(o);
            assertEq(row.bindingOrdinal, 1, "row.bindingOrdinal");
            assertEq(row.expectedRevision, o - 2, "row.expectedRevision");
        }
    }

    // ---- UNBIND / RELEASE ------------------------------------------------------------------------------------

    function test_unbind_keeps_target_word_and_head_is_canonical() public {
        bytes32 r = _land("kinds/mask");
        bytes32 key = _key(principal, FOLDER, SA, ROLE);
        _exec(_acts(_bind(FOLDER, SA, ROLE, r, 0)), _bodies(1));
        uint256 hs = Layout.bindingsHeadsSlot(key);
        vm.startStateDiffRecording();
        Effect[] memory e = _logged(_acts(_unbind(FOLDER, SA, ROLE, 1)), _bodies(1));
        assertEq(_targetWrites(vm.stopAndReturnStateDiff(), key), 0);
        assertEq(_raw(hs + 1), r, "the raw target word is kept");
        assertEq(abi.encode(_head(key)), abi.encode(Head(2, 2, 3, 1, 2, 1, bytes32(0))));
        assertEq(
            abi.encode(e[0].transitionKind, e[0].oldTarget, e[0].oldTargetKind, e[0].target),
            abi.encode(3, r, 1, 0)
        );
        Row memory row = _row(3);
        assertEq(abi.encode(row.kind, row.a, row.prevAdmission), abi.encode(4, 0, 2));
    }

    function test_unbind_and_release_refusals() public {
        bytes32 r = _land("kinds/mask/refusals");
        bytes32 key = _key(principal, FOLDER, SA, ROLE);
        for (uint8 kind = ActionKind.UNBIND; kind <= ActionKind.RELEASE; kind += 3) {
            Action memory m = _unbind(FOLDER, SA, ROLE, 0);
            m.kind = kind;
            _refuse2(m, "", abi.encodeWithSelector(E_NOT_LIVE.selector, uint8(1), key, uint8(0)));
        }
        _exec(_acts(_bind(FOLDER, SA, ROLE, r, 0)), _bodies(1));
        _refuse1(
            _unbind(FOLDER, SA, ROLE, 5),
            "",
            abi.encodeWithSelector(E_CAS.selector, key, uint64(5), uint64(1))
        );
        _exec(_acts(_unbind(FOLDER, SA, ROLE, 1)), _bodies(1));
        _refuse1(
            _unbind(FOLDER, SA, ROLE, 2),
            "",
            abi.encodeWithSelector(E_NOT_LIVE.selector, uint8(0), key, uint8(2))
        );
        _exec(_acts(_release(FOLDER, SA, ROLE, 2)), _bodies(1));
        for (uint8 kind = ActionKind.UNBIND; kind <= ActionKind.RELEASE; kind += 3) {
            Action memory m = _unbind(FOLDER, SA, ROLE, 3);
            m.kind = kind;
            _refuse1(m, "", abi.encodeWithSelector(E_NOT_LIVE.selector, uint8(0), key, uint8(3)));
        }
    }

    function test_release_from_bound_and_from_masked() public {
        bytes32 r = _land("kinds/release");
        bytes32 key = _key(principal, FOLDER, SA, ROLE);
        _exec(_acts(_bind(FOLDER, SA, ROLE, r, 0)), _bodies(1));
        Effect[] memory e = _logged(_acts(_release(FOLDER, SA, ROLE, 1)), _bodies(1));
        assertEq(abi.encode(_head(key)), abi.encode(Head(3, 2, 3, 1, 2, 1, bytes32(0))));
        assertEq(_raw(Layout.bindingsHeadsSlot(key) + 1), r, "RELEASE keeps the target word");
        assertEq(abi.encode(e[0].transitionKind, e[0].oldTarget), abi.encode(4, r));
        bytes32 key2 = _key(principal, FOLDER, SB, ROLE);
        _exec(_acts(_bind(FOLDER, SB, ROLE, r, 0), _unbind(FOLDER, SB, ROLE, 1)), _bodies(2));
        e = _logged(_acts(_release(FOLDER, SB, ROLE, 2)), _bodies(1));
        assertEq(_head(key2).state, 3);
        assertEq(abi.encode(e[0].transitionKind, e[0].oldTarget), abi.encode(4, 0));
    }

    /// I8: head states 4..255 are reserved and refused by every bind kind.
    function test_reserved_head_state_is_refused() public {
        bytes32 r = _land("kinds/state4");
        bytes32 key = _key(principal, FOLDER, SA, ROLE);
        _exec(_acts(_bind(FOLDER, SA, ROLE, r, 0)), _bodies(1));
        uint256 hs = Layout.bindingsHeadsSlot(key);
        vm.store(k.proxy, bytes32(hs), bytes32((uint256(_raw(hs)) & ~uint256(0xff)) | 4));
        Action[3] memory m = [
            _bind(FOLDER, SA, ROLE, r, 1),
            _unbind(FOLDER, SA, ROLE, 1),
            _release(FOLDER, SA, ROLE, 1)
        ];
        for (uint256 i; i < 3; ++i) {
            _refuse1(m[i], "", abi.encodeWithSelector(E_NOT_LIVE.selector, uint8(0), key, uint8(4)));
        }
    }

    // ---- CREATE ------------------------------------------------------------------------------------------------

    function test_create_subject_cell_and_repeat_is_E_SUBJECT_EXISTS() public {
        bytes32 sid = _sid(principal, "kinds/create");
        _exec(_acts(_create("kinds/create")), _bodies(1));
        assertEq(hot.subjectCreatedAt(sid), 1);
        (uint48 created, uint8 creatorKind) =
            Layout.unpackSubjectCell(_raw(Layout.subjectsCellsSlot(sid)));
        assertEq(abi.encode(created, creatorKind), abi.encode(1, 2), "contract principal creator");
        assertEq(abi.encode(_row(1).kind, _row(1).a), abi.encode(5, bytes32("kinds/create")));
        _refuse1(
            _create("kinds/create"),
            "",
            abi.encodeWithSelector(E_SUBJECT_EXISTS.selector, uint8(0), sid)
        );
        bytes32 sid2 = _sid(principal, "kinds/create/2");
        _expectNoChange(
            _acts(_create("kinds/create/2"), _create("kinds/create/2")),
            _bodies(2),
            abi.encodeWithSelector(E_SUBJECT_EXISTS.selector, uint8(1), sid2)
        );
        address alice = makeAddr("alice");
        _execAs(alice, _acts(_create("kinds/create")), _bodies(1));
        bytes32 aliceSid = _sid(Keys.principal(alice), "kinds/create");
        (, creatorKind) = Layout.unpackSubjectCell(_raw(Layout.subjectsCellsSlot(aliceSid)));
        assertEq(creatorKind, 1, "key principal creator; same salt, different subject");
    }

    // DESIGN-DIVERGENCE: §6.4 names `E_SALT` for a zero CREATE salt; the shape law (src/core/LedgerCore.sol:466)
    // refuses it first as E_SHAPE(leaf, 1), so the apply delegate's E_SALT (src/core/LedgerApply.sol:287) is
    // unreachable through the kernel.
    function test_create_salt_zero_is_shape_not_E_SALT() public {
        _refuse2(_create(0), "", abi.encodeWithSelector(E_SHAPE.selector, uint8(1), uint8(1)));
    }

    // ---- WITHDRAW ----------------------------------------------------------------------------------------------

    function test_withdraw_codes_0_to_3() public {
        _exec(_acts(_publish(TYPE_OK, "w/1"), _create("w/s")), _bodies(2, 0, "w/1"));
        _execAs(makeAddr("alice"), _acts(_publish(TYPE_OK, "w/a")), _bodies(1, 0, "w/a"));
        bytes memory e0self = abi.encodeWithSelector(E_WITHDRAW.selector, uint8(0), uint8(0));
        _refuse1(_withdraw(4), "", e0self); // its own admission
        _refuse1(_withdraw(99), "", e0self); // a future admission
        _refuse1(_withdraw(2), "", abi.encodeWithSelector(E_WITHDRAW.selector, 0, 1));
        _refuse1(_withdraw(3), "", abi.encodeWithSelector(E_WITHDRAW.selector, 0, 3));
        _expectNoChange(
            _acts(_withdraw(1), _withdraw(1)),
            _bodies(2),
            abi.encodeWithSelector(E_WITHDRAW.selector, 1, 2)
        );
        _exec(_acts(_withdraw(1)), _bodies(1));
        _refuse1(_withdraw(1), "", abi.encodeWithSelector(E_WITHDRAW.selector, 0, 2));
    }

    /// FilesWithdrawal / RecordOccurrenceBounds: fresh one, withdraw to zero, reuse one; bytes never erased.
    function test_withdraw_decrements_keeps_bytes_and_reuse_revives() public {
        bytes memory body = _pattern(40, 3);
        bytes32 rid = _land(body);
        bytes32 w0 = _raw(Layout.recordsBodyWordsSlot(rid, 0));
        bytes32 w1 = _raw(Layout.recordsBodyWordsSlot(rid, 1));
        Effect[] memory e = _logged(_acts(_withdraw(1)), _bodies(1));
        (bytes32 t, uint64 first, uint32 len, uint64 occ,) = hot.recordHeader(rid);
        assertEq(abi.encode(t, first, len, occ), abi.encode(TYPE_OK, 1, 40, 0));
        assertEq(_raw(Layout.recordsBodyWordsSlot(rid, 0)), w0, "bytes never erased");
        assertEq(_raw(Layout.recordsBodyWordsSlot(rid, 1)), w1, "bytes never erased");
        assertEq(_row(1).withdrawn, 1);
        assertEq(abi.encode(_row(2).kind, _row(2).a), abi.encode(6, bytes32(uint256(1))));
        assertEq(
            abi.encode(
                e[0].recordId, e[0].typeId, e[0].withdrawnAdmission, e[0].withdrawnPrincipal
            ),
            abi.encode(rid, TYPE_OK, 1, principal)
        );
        _exec(_acts(_reuse(TYPE_OK, rid)), _bodies(1));
        assertEq(_occ(rid), 1, "a retained record is reusable at zero occurrences");
    }

    function test_withdraw_a_reused_occurrence() public {
        bytes32 rid = _land("w/reused");
        _exec(_acts(_reuse(TYPE_OK, rid)), _bodies(1));
        _exec(_acts(_withdraw(2)), _bodies(1));
        assertEq(_occ(rid), 1);
        assertEq(abi.encode(_row(1).withdrawn, _row(2).withdrawn), abi.encode(0, 1));
    }

    // ---- Admitted events -----------------------------------------------------------------------------------

    function _expectAdmitted(uint64 admission, uint8 kind, bytes32 topic3, bytes32 id) internal {
        vm.expectEmit(true, true, true, true, k.proxy);
        emit ILedger.Admitted(admission, kind, topic3, id, principal);
    }

    function test_admitted_event_topic3_per_kind() public {
        bytes memory body = "kinds/events";
        bytes32 rid = _rid(TYPE_OK, body);
        bytes32 sid = _sid(principal, "e");
        bytes32 scope = Keys.scope(principal, FOLDER, sid);
        bytes32 pos = Keys.position(FOLDER, sid, ROLE);
        _expectAdmitted(1, ActionKind.CREATE, sid, sid);
        _expectAdmitted(2, ActionKind.PUBLISH, TYPE_OK, rid);
        _expectAdmitted(3, ActionKind.BIND, scope, pos);
        _exec(
            _acts(_create("e"), _publish(TYPE_OK, body), _bind(FOLDER, sid, ROLE, rid, 0)),
            _bodies(3, 1, body)
        );
        _expectAdmitted(4, ActionKind.REUSE, TYPE_OK, rid);
        _expectAdmitted(5, ActionKind.UNBIND, scope, pos);
        _expectAdmitted(6, ActionKind.WITHDRAW, TYPE_OK, bytes32(uint256(4)));
        _exec(_acts(_reuse(TYPE_OK, rid), _unbind(FOLDER, sid, ROLE, 1), _withdraw(4)), _bodies(3));
        _expectAdmitted(7, ActionKind.RELEASE, scope, pos);
        _exec(_acts(_release(FOLDER, sid, ROLE, 2)), _bodies(1));
    }
}
