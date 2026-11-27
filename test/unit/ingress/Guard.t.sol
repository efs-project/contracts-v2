// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {KernelFixture} from "../../harness/KernelFixture.sol";
import {GuardBase} from "./GuardBase.sol";
import {Keys} from "../../../src/lib/Keys.sol";
import {Action, Intent, ReadSet} from "../../../src/interfaces/Actions.sol";
import {Evidence} from "../../../src/interfaces/Views.sol";
import {ILedger} from "../../../src/interfaces/ILedger.sol";
import {
    AlreadyAdmitted,
    E_INTENT,
    E_NONCE,
    E_READSET_SHAPE,
    E_UNSUPPORTED_GUARD
} from "../../../src/interfaces/Errors.sol";

/// @notice Capability b0 clear (the fixture's default): any non-empty guard is refused before it is decoded.
contract GuardDisabledTest is KernelFixture {
    function test_a_guard_without_b0_is_E_UNSUPPORTED_GUARD() public {
        ReadSet memory rs;
        rs.principals = new bytes32[](1);
        rs.principals[0] = principal;
        rs.positions = new bytes32[](1);
        rs.positions[0] = keccak256("guard/off/position");
        rs.expectedHeads = new bytes32[](1);
        rs.expectedHeads[0] = commitments.headSnapshotHash(0, 0, 0, 0); // a guard that would pass
        bytes[] memory guards = new bytes[](3);
        guards[0] = abi.encode(rs);
        guards[1] = hex"01"; // not even decodable: b0 is checked first
        rs.principals = new bytes32[](0); // shape 1 under b0
        guards[2] = abi.encode(rs);
        for (uint256 i; i < guards.length; ++i) {
            Action[] memory a = _acts(_create(keccak256(abi.encode("guard/off", i))));
            _track(principal, a);
            bytes32 before = digest();
            uint64 n = _nonce(principal);
            vm.expectRevert(E_UNSUPPORTED_GUARD.selector);
            ledger.execute(a, _bodies(1), _native(n), guards[i]);
            _assertUnchanged(before);
        }
        // the same action unguarded is admitted
        _exec(_acts(_create(keccak256(abi.encode("guard/off", uint256(0))))), _bodies(1));
    }
}

/// @notice The read-set guard on the native and secp256k1 lanes (design §5.1, `LedgerIngress._checkGuard`,
///         head-snapshot profile 2): what passes, what is recorded, each hashed field going stale, the stored
///         target word of MASKED and RELEASED heads, the pre-state rule, position-major order, every shape
///         refusal and their order, a second principal, retries, and the signed lane's `readSetHash` binding.
/// @dev A BIND with target 0 is refused `E_SHAPE(leaf, 1)` before any head is written; that is pinned by
///      `ShapeTest.test_missing_required_field_is_E_SHAPE_1_for_every_kind` (test/unit/kernel/Shape.t.sol,
///      the `[BIND, F_TARGET]` row) and is why a stored target word is 0 exactly when `targetKind` is 0
///      (GuardHeadsTest walks every sequence).
contract GuardTest is GuardBase {
    function _bindA() internal returns (Raw memory h) {
        _exec(_acts(_bind(FOLDER, SUBJECT, ROLE, recA, 0)), _bodies(1));
        h = _rawHead(principal, pos);
    }

    // ---- a passing guard ------------------------------------------------------------------------------------

    function test_a_passing_guard_is_recorded_and_emitted() public {
        uint64 unguarded = _nextPublication();
        Raw memory h = _bindA();
        (uint64 admissions,,,) = hot.counts();
        assertEq(
            abi.encode(h.state, h.revision, h.admission, h.targetKind, h.word),
            abi.encode(1, 1, admissions, 1, recA)
        );
        bytes memory guard = _guard1(principal, pos, _snap(1, 1, admissions, recA));
        bytes32 rsHash = keccak256(guard);
        assertEq(
            rsHash, commitments.readSetHash(abi.decode(guard, (ReadSet))), "raw hash = readSetHash"
        );
        uint64 expected = _nextPublication();
        vm.expectEmit(true, true, false, true, k.proxy);
        emit ILedger.ReadSetChecked(expected, rsHash, guard);
        uint64 publication = _execG(_touchNothing(), _bodies(1), guard);
        assertEq(publication, expected);
        Evidence memory e = _evidence(publication);
        assertTrue(e.guarded, "guarded flag");
        assertEq(e.readSetHash, rsHash, "readSetHash stored");
        // the native intent digest binds the guard bytes
        assertEq(
            e.intentDigest,
            commitments.nativeIntentDigest(
                hot.realmId(), principal, _native(e.nonce), e.actionsHash, rsHash
            )
        );
        Evidence memory u = _evidence(unguarded);
        assertFalse(u.guarded, "an unguarded publication");
        assertEq(u.readSetHash, 0);
    }

    function test_an_unset_head_passes_with_the_zero_snapshot() public {
        _execG(_touchNothing(), _bodies(1), _guard1(principal, pos, _snap(0, 0, 0, 0)));
        _refuseG(
            _touchNothing(),
            _bodies(1),
            _guard1(principal, pos, _snap(0, 0, 0, recA)),
            _stale(pos, principal)
        );
    }

    // ---- each hashed field goes stale ----------------------------------------------------------------------

    function test_stale_state() public {
        Raw memory h = _bindA();
        _refuseG(
            _touchNothing(),
            _bodies(1),
            _guard1(principal, pos, _snap(2, h.revision, h.admission, recA)),
            _stale(pos, principal)
        );
        _execG(
            _touchNothing(),
            _bodies(1),
            _guard1(principal, pos, _snap(1, h.revision, h.admission, recA))
        );
    }

    function test_stale_revision() public {
        Raw memory h = _bindA();
        _refuseG(
            _touchNothing(),
            _bodies(1),
            _guard1(principal, pos, _snap(1, h.revision + 1, h.admission, recA)),
            _stale(pos, principal)
        );
        _refuseG(
            _touchNothing(),
            _bodies(1),
            _guard1(principal, pos, _snap(1, 0, h.admission, recA)),
            _stale(pos, principal)
        );
    }

    function test_stale_admission() public {
        Raw memory h = _bindA();
        _refuseG(
            _touchNothing(),
            _bodies(1),
            _guard1(principal, pos, _snap(1, h.revision, h.admission - 1, recA)),
            _stale(pos, principal)
        );
    }

    function test_stale_target_of_a_bound_head() public {
        Raw memory h = _bindA();
        _refuseG(
            _touchNothing(),
            _bodies(1),
            _guard1(principal, pos, _snapWith(h, recB)),
            _stale(pos, principal)
        );
        _refuseG(
            _touchNothing(),
            _bodies(1),
            _guard1(principal, pos, _snapWith(h, 0)),
            _stale(pos, principal)
        );
    }

    /// A rebind moves revision, admission and target: the expectation taken before it is stale.
    function test_a_rebind_changes_the_snapshot() public {
        Raw memory h1 = _bindA();
        _exec(_acts(_bind(FOLDER, SUBJECT, ROLE, recB, 1)), _bodies(1));
        Raw memory h2 = _rawHead(principal, pos);
        assertEq(abi.encode(h2.state, h2.revision, h2.word), abi.encode(1, 2, recB));
        _refuseG(
            _touchNothing(),
            _bodies(1),
            _guard1(principal, pos, _snapWith(h1, recA)),
            _stale(pos, principal)
        );
        _execG(_touchNothing(), _bodies(1), _guard1(principal, pos, _snapWith(h2, recB)));
    }

    // ---- the stored target word -------------------------------------------------------------------------

    function test_a_masked_head_is_compared_with_its_last_bound_target() public {
        _bindA();
        _exec(_acts(_unbind(FOLDER, SUBJECT, ROLE, 1)), _bodies(1));
        Raw memory h = _rawHead(principal, pos);
        assertEq(
            abi.encode(h.state, h.revision, h.targetKind, h.word),
            abi.encode(2, 2, 1, recA),
            "MASKED keeps A"
        );
        (,,,,,, bytes32 served,) = hot.head(Keys.binding(principal, pos));
        assertEq(served, 0, "the head read serves target 0");
        _refuseG(
            _touchNothing(),
            _bodies(1),
            _guard1(principal, pos, _snapWith(h, 0)),
            _stale(pos, principal)
        );
        _refuseG(
            _touchNothing(),
            _bodies(1),
            _guard1(principal, pos, _snapWith(h, recB)),
            _stale(pos, principal)
        );
        _execG(_touchNothing(), _bodies(1), _guard1(principal, pos, _snapWith(h, recA)));
    }

    function test_a_released_head_is_compared_with_its_last_bound_target() public {
        _bindA();
        _exec(_acts(_release(FOLDER, SUBJECT, ROLE, 1)), _bodies(1));
        Raw memory h = _rawHead(principal, pos);
        assertEq(
            abi.encode(h.state, h.revision, h.targetKind, h.word),
            abi.encode(3, 2, 1, recA),
            "RELEASED keeps A"
        );
        _refuseG(
            _touchNothing(),
            _bodies(1),
            _guard1(principal, pos, _snapWith(h, 0)),
            _stale(pos, principal)
        );
        _refuseG(
            _touchNothing(),
            _bodies(1),
            _guard1(principal, pos, _snapWith(h, recB)),
            _stale(pos, principal)
        );
        _execG(_touchNothing(), _bodies(1), _guard1(principal, pos, _snapWith(h, recA)));
    }

    function test_a_never_bound_masked_head_is_compared_with_zero() public {
        _exec(_acts(_unbind(FOLDER, SUBJECT, ROLE, 0)), _bodies(1));
        Raw memory h = _rawHead(principal, pos);
        assertEq(
            abi.encode(h.state, h.revision, h.targetKind, h.word),
            abi.encode(2, 1, 0, bytes32(0)),
            "a first mask writes neither"
        );
        _refuseG(
            _touchNothing(),
            _bodies(1),
            _guard1(principal, pos, _snapWith(h, recA)),
            _stale(pos, principal)
        );
        _execG(_touchNothing(), _bodies(1), _guard1(principal, pos, _snapWith(h, 0)));
        // and released from there: still no target
        _exec(_acts(_release(FOLDER, SUBJECT, ROLE, 1)), _bodies(1));
        h = _rawHead(principal, pos);
        assertEq(abi.encode(h.state, h.targetKind, h.word), abi.encode(3, 0, bytes32(0)));
        _refuseG(
            _touchNothing(),
            _bodies(1),
            _guard1(principal, pos, _snapWith(h, recA)),
            _stale(pos, principal)
        );
        _execG(_touchNothing(), _bodies(1), _guard1(principal, pos, _snapWith(h, 0)));
    }

    function test_a_restore_to_a_new_target_then_a_mask_keeps_the_new_target() public {
        _bindA();
        _exec(_acts(_unbind(FOLDER, SUBJECT, ROLE, 1)), _bodies(1));
        _exec(_acts(_bind(FOLDER, SUBJECT, ROLE, recB, 2)), _bodies(1)); // restore to B
        _exec(_acts(_unbind(FOLDER, SUBJECT, ROLE, 3)), _bodies(1));
        Raw memory h = _rawHead(principal, pos);
        assertEq(abi.encode(h.state, h.revision, h.word), abi.encode(2, 4, recB));
        _refuseG(
            _touchNothing(),
            _bodies(1),
            _guard1(principal, pos, _snapWith(h, recA)),
            _stale(pos, principal)
        );
        _refuseG(
            _touchNothing(),
            _bodies(1),
            _guard1(principal, pos, _snapWith(h, 0)),
            _stale(pos, principal)
        );
        _execG(_touchNothing(), _bodies(1), _guard1(principal, pos, _snapWith(h, recB)));
    }

    // ---- the pre-state rule ----------------------------------------------------------------------------------

    /// The guard is checked in prepare, before any leaf applies: a publication that binds a head is compared
    /// with that head as it stood before the publication.
    function test_a_guard_over_the_publications_own_head_sees_the_pre_state() public {
        Action[] memory bind = _acts(_bind(FOLDER, SUBJECT, ROLE, recA, 0));
        (uint64 admissions,,,) = hot.counts();
        // the post-state this publication would write: BOUND, revision 1, its own admission, A
        bytes memory post = _guard1(principal, pos, _snap(1, 1, admissions + 1, recA));
        _refuseG(bind, _bodies(1), post, _stale(pos, principal));
        _execG(bind, _bodies(1), _guard1(principal, pos, _snap(0, 0, 0, 0)));
        Raw memory h = _rawHead(principal, pos);
        assertEq(
            _snapWith(h, h.word),
            _snap(1, 1, admissions + 1, recA),
            "the post-state was what the refused guard named"
        );
    }

    // ---- order ----------------------------------------------------------------------------------------------

    /// expectedHeads[j * n + i] is binding(principals[i], positions[j]); the first mismatch in that order is
    /// reported. With wrong entries at (position 0, principal 1) and (position 1, principal 0), position-major
    /// order reports the first; principal-major order would report the second.
    function test_the_first_stale_entry_in_position_major_order_is_reported() public {
        _bindA();
        Raw memory h = _rawHead(principal, pos);
        bytes32 unset = _snap(0, 0, 0, 0);
        bytes32[] memory heads = new bytes32[](4);
        heads[0] = _snapWith(h, recA); // (pos, principal) right
        heads[1] = _snap(1, 1, 1, recB); // (pos, alice) wrong
        heads[2] = _snap(1, 1, 1, recB); // (pos2, principal) wrong
        heads[3] = unset; // (pos2, alice) right
        bytes32[] memory principals = _two(principal, pAlice);
        bytes32[] memory positions = _two(pos, pos2);
        _refuseG(
            _touchNothing(), _bodies(1), _rs(principals, positions, heads), _stale(pos, pAlice)
        );
        heads[1] = unset;
        _refuseG(
            _touchNothing(), _bodies(1), _rs(principals, positions, heads), _stale(pos2, principal)
        );
        heads[2] = unset;
        _execG(_touchNothing(), _bodies(1), _rs(principals, positions, heads));
    }

    // ---- shapes -----------------------------------------------------------------------------------------------

    function _shape(uint8 reason) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(E_READSET_SHAPE.selector, reason);
    }

    function _unsetHeads(uint256 n) internal view returns (bytes32[] memory heads) {
        heads = new bytes32[](n);
        bytes32 u = _snap(0, 0, 0, 0);
        for (uint256 i; i < n; ++i) {
            heads[i] = u;
        }
    }

    function _distinct(bytes32 seed, uint256 n) internal pure returns (bytes32[] memory l) {
        l = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            l[i] = keccak256(abi.encode(seed, i));
        }
    }

    function test_shape_1_principals() public {
        _refuseG(
            _touchNothing(),
            _bodies(1),
            _rs(new bytes32[](0), _one(pos), new bytes32[](0)),
            _shape(1)
        );
        _refuseG(
            _touchNothing(),
            _bodies(1),
            _rs(_distinct("p", 65), _one(pos), _unsetHeads(65)),
            _shape(1)
        );
        _execG(_touchNothing(), _bodies(1), _rs(_distinct("p", 64), _one(pos), _unsetHeads(64)));
    }

    function test_shape_2_positions() public {
        _refuseG(
            _touchNothing(),
            _bodies(1),
            _rs(_one(principal), new bytes32[](0), new bytes32[](0)),
            _shape(2)
        );
        _refuseG(
            _touchNothing(),
            _bodies(1),
            _rs(_one(principal), _distinct("q", 129), _unsetHeads(129)),
            _shape(2)
        );
        _execG(
            _touchNothing(), _bodies(1), _rs(_one(principal), _distinct("q", 128), _unsetHeads(128))
        );
    }

    function test_shape_3_heads_length() public {
        bytes32[] memory p2 = _two(principal, pAlice);
        bytes32[] memory q2 = _two(pos, pos2);
        _refuseG(_touchNothing(), _bodies(1), _rs(p2, q2, _unsetHeads(3)), _shape(3));
        _refuseG(_touchNothing(), _bodies(1), _rs(p2, q2, _unsetHeads(5)), _shape(3));
        _refuseG(_touchNothing(), _bodies(1), _rs(p2, q2, _unsetHeads(2)), _shape(3)); // n + m, not n·m
        _execG(_touchNothing(), _bodies(1), _rs(p2, q2, _unsetHeads(4)));
    }

    function test_shape_4_non_canonical_bytes() public {
        bytes memory canonical = _guard1(principal, pos, _snap(0, 0, 0, 0));
        // trailing bytes: abi.decode accepts them, the canonical re-encoding does not match
        _refuseG(_touchNothing(), _bodies(1), bytes.concat(canonical, bytes32(0)), _shape(4));
        _refuseG(_touchNothing(), _bodies(1), bytes.concat(canonical, hex"00"), _shape(4));
        // a non-canonical outer offset (0x40) with a padding word before the tuple: decodes to the same read set
        bytes memory tuple = new bytes(canonical.length - 32);
        for (uint256 i; i < tuple.length; ++i) {
            tuple[i] = canonical[i + 32];
        }
        bytes memory shifted = bytes.concat(bytes32(uint256(0x40)), bytes32(0), tuple);
        ReadSet memory decoded = abi.decode(shifted, (ReadSet));
        assertEq(keccak256(abi.encode(decoded)), keccak256(canonical), "the same read set");
        _refuseG(_touchNothing(), _bodies(1), shifted, _shape(4));
        _execG(_touchNothing(), _bodies(1), canonical);
    }

    function test_shape_5_principals_times_positions_over_maxReadCount() public {
        // exactly maxReadCount (256): no shape refusal, and every head is compared
        bytes32[] memory principals = _two(principal, pAlice);
        bytes32[] memory positions = _distinct("r", 128);
        _execG(_touchNothing(), _bodies(1), _rs(principals, positions, _unsetHeads(256)));
        bytes32[] memory heads = _unsetHeads(256);
        heads[255] = _snap(0, 0, 0, recA);
        _refuseG(
            _touchNothing(),
            _bodies(1),
            _rs(principals, positions, heads),
            _stale(positions[127], pAlice)
        );
        // 3 × 128 = 384 and 64 × 5 = 320 are each within their own bound and over the product
        _refuseG(
            _touchNothing(),
            _bodies(1),
            _rs(_distinct("p", 3), positions, _unsetHeads(384)),
            _shape(5)
        );
        _refuseG(
            _touchNothing(),
            _bodies(1),
            _rs(_distinct("p", 64), _distinct("r", 5), _unsetHeads(320)),
            _shape(5)
        );
        // 64 × 4 = 256 passes
        _execG(
            _touchNothing(),
            _bodies(1),
            _rs(_distinct("p", 64), _distinct("r", 4), _unsetHeads(256))
        );
    }

    /// Where two refusals apply, the earlier in the order 1, 2, 3, 5, 4, stale is reported.
    function test_shape_refusals_are_checked_in_order() public {
        // 1 before 2: no principals and no positions
        _refuseG(
            _touchNothing(),
            _bodies(1),
            _rs(new bytes32[](0), new bytes32[](0), new bytes32[](0)),
            _shape(1)
        );
        // 1 before 2: 65 principals and 129 positions
        _refuseG(
            _touchNothing(),
            _bodies(1),
            _rs(_distinct("p", 65), _distinct("r", 129), new bytes32[](0)),
            _shape(1)
        );
        // 2 before 3: 129 positions and a wrong heads length
        _refuseG(
            _touchNothing(),
            _bodies(1),
            _rs(_one(principal), _distinct("r", 129), new bytes32[](0)),
            _shape(2)
        );
        // 3 before 5: over the product and a wrong heads length
        _refuseG(
            _touchNothing(),
            _bodies(1),
            _rs(_distinct("p", 3), _distinct("r", 128), new bytes32[](0)),
            _shape(3)
        );
        // 5 before 4: over the product and non-canonical bytes
        bytes memory over = _rs(_distinct("p", 3), _distinct("r", 128), _unsetHeads(384));
        _refuseG(_touchNothing(), _bodies(1), bytes.concat(over, bytes32(0)), _shape(5));
        // 4 before stale: non-canonical bytes and a stale head
        bytes memory stale = _guard1(principal, pos, _snap(1, 1, 1, recA));
        _refuseG(_touchNothing(), _bodies(1), stale, _stale(pos, principal));
        _refuseG(_touchNothing(), _bodies(1), bytes.concat(stale, bytes32(0)), _shape(4));
    }

    // ---- a second principal ------------------------------------------------------------------------------

    function test_a_guard_over_another_authors_head() public {
        _execAs(alice, _acts(_bind(FOLDER, SUBJECT, ROLE, recB, 0)), _bodies(1));
        Raw memory h = _rawHead(pAlice, pos);
        assertEq(abi.encode(h.state, h.revision, h.word), abi.encode(1, 1, recB));
        bytes memory guard = _guard1(pAlice, pos, _snapWith(h, recB));
        _execG(_touchNothing(), _bodies(1), guard);
        // this principal's own head at the same position is a different head
        _refuseG(
            _touchNothing(),
            _bodies(1),
            _guard1(principal, pos, _snapWith(h, recB)),
            _stale(pos, principal)
        );
        // alice changes her head: the same expectation is stale
        _execAs(alice, _acts(_unbind(FOLDER, SUBJECT, ROLE, 1)), _bodies(1));
        _refuseG(_touchNothing(), _bodies(1), guard, _stale(pos, pAlice));
        Raw memory h2 = _rawHead(pAlice, pos);
        _execG(_touchNothing(), _bodies(1), _guard1(pAlice, pos, _snapWith(h2, recB)));
    }

    // ---- retries ---------------------------------------------------------------------------------------------

    /// The retry compare runs before prepare: an admitted guarded publication re-sent byte for byte answers
    /// `AlreadyAdmitted` even though its guard is stale now; the same actions with other guard bytes at that
    /// nonce are a different intent (`keccak256(guard)` is in the native digest) and answer `E_NONCE`.
    function test_a_retry_of_a_guarded_publication() public {
        Raw memory h = _bindA();
        bytes memory guard = _guard1(principal, pos, _snapWith(h, recA));
        Action[] memory a = _touchNothing();
        uint64 n = _nonce(principal);
        uint64 publication = _execG(a, _bodies(1), guard);
        _exec(_acts(_unbind(FOLDER, SUBJECT, ROLE, 1)), _bodies(1)); // the guarded head moves
        bytes32 before = digest();
        vm.expectRevert(abi.encodeWithSelector(AlreadyAdmitted.selector, publication));
        ledger.execute(a, _bodies(1), _native(n), guard);
        _assertUnchanged(before);
        // the guard of today at the old nonce: a different intent
        Raw memory h2 = _rawHead(principal, pos);
        bytes memory fresh = _guard1(principal, pos, _snapWith(h2, recA));
        vm.expectRevert(abi.encodeWithSelector(E_NONCE.selector, principal, n, publication));
        ledger.execute(a, _bodies(1), _native(n), fresh);
        // and the old guard at the next nonce is stale
        _refuseG(a, _bodies(1), guard, _stale(pos, principal));
        _assertUnchanged(before);
    }

    // ---- the signed lane -----------------------------------------------------------------------------------

    function test_signed_lane_guard_passes_and_is_recorded() public {
        Raw memory h = _bindA();
        bytes memory guard = _guard1(principal, pos, _snapWith(h, recA));
        Action[] memory a = _acts(_create(keccak256("guard/signed/ok")));
        (Intent memory it, bytes memory w) = _signed(a, keccak256(guard));
        uint64 expected = _nextPublication();
        vm.expectEmit(true, true, false, true, k.proxy);
        emit ILedger.ReadSetChecked(expected, keccak256(guard), guard);
        (uint64 publication,) = ledger.executeSigned(it, a, _bodies(1), guard, w);
        assertEq(publication, expected);
        Evidence memory e = _evidence(publication);
        assertEq(e.proofKind, 2, "secp256k1");
        assertEq(e.principalId, pSigner);
        assertTrue(e.guarded);
        assertEq(e.readSetHash, keccak256(guard));
    }

    function test_signed_lane_readSetHash_must_be_the_guard_hash() public {
        Raw memory h = _bindA();
        bytes memory guard = _guard1(principal, pos, _snapWith(h, recA));
        Action[] memory a = _acts(_create(keccak256("guard/signed/mismatch")));
        bytes32[3] memory wrong =
            [bytes32(0), keccak256(""), keccak256(bytes.concat(guard, hex"00"))];
        for (uint256 i; i < wrong.length; ++i) {
            (Intent memory it, bytes memory w) = _signed(a, wrong[i]);
            vm.expectRevert(abi.encodeWithSelector(E_INTENT.selector, uint8(5)));
            ledger.executeSigned(it, a, _bodies(1), guard, w);
        }
        // an empty guard binds keccak256("")
        (Intent memory it0, bytes memory w0) = _signed(a, bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(E_INTENT.selector, uint8(5)));
        ledger.executeSigned(it0, a, _bodies(1), "", w0);
    }

    function test_signed_lane_stale_head() public {
        Raw memory h = _bindA();
        bytes memory guard = _guard1(principal, pos, _snapWith(h, recB));
        Action[] memory a = _acts(_create(keccak256("guard/signed/stale")));
        (Intent memory it, bytes memory w) = _signed(a, keccak256(guard));
        vm.expectRevert(_stale(pos, principal));
        ledger.executeSigned(it, a, _bodies(1), guard, w);
        assertEq(_nonce(pSigner), 0, "nothing admitted");
    }
}
