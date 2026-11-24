// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {LensFixture} from "../harness/doubles/LensHistory.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {ScopeKey} from "../../src/interfaces/Actions.sol";
import {BasisCommit, Coverage, Status} from "../../src/interfaces/Results.sol";
import {Cursor, Page} from "../../src/interfaces/Readers.sol";

/// @notice `LensReview` (design §11, §5.13), listing: candidates from the real `BitmapStore` scope lists, both
///         fall-through policies, the listing-coverage law, and the cursor law — bound to `queryHash` and its
///         origin basis, BASIS_STALE under the strict flag once the basis moved, relaxed continuation accepted
///         while no selected scope mutated and refused once one did (REBIND and RESTORE stamp too, CQ-9/CQ-10).
contract LensListTest is LensFixture {
    uint8 internal constant MASK = 1;
    uint8 internal constant SILENCE = 2;
    uint8 internal constant STRICT = 0x80;

    function _list(bytes32[] memory l, Cursor memory c, uint32 budget, uint8 policy)
        internal
        view
        returns (Page memory)
    {
        return lens.list(l, FOLDER, S, c, budget, policy, _unpinned());
    }

    function _assertRow(Page memory p, uint256 i, bytes32 role, bytes32 principal, bytes32 target)
        internal
        view
    {
        assertEq(p.rows[i].position, Keys.position(FOLDER, S, role), "position");
        assertEq(p.rows[i].role, role, "role");
        assertEq(uint8(p.rows[i].selection.status), uint8(Status.PRESENT));
        assertEq(p.rows[i].selection.principalId, principal, "principal");
        assertEq(p.rows[i].selection.target, target, "target");
    }

    function test_origin_page_is_complete_and_lists_each_position_once() public view {
        Page memory p = _list(_lens(pA, pB), _fresh(), 256, MASK);
        assertEq(uint8(p.q.status), uint8(Status.PRESENT));
        assertEq(p.rows.length, 5);
        _assertRow(p, 0, X, pA, rRoot);
        _assertRow(p, 1, Y, pA, rA2);
        _assertRow(p, 2, SUB, pA, S);
        assertEq(p.rows[2].selection.targetKind, 2);
        _assertRow(p, 3, TINY, pA, rTiny);
        _assertRow(p, 4, Z, pB, rB); // pB's x is under pA's x
        assertEq(p.scanned, 6);
        assertEq(p.rawTotal, 6);
        assertEq(p.selectedSoFar, 5);
        assertEq(p.scanStatus, 1, "EXHAUSTED");
        assertTrue(p.startsAtOrigin);
        assertTrue(p.completeFromOrigin);
        assertEq(uint8(p.listingCoverage), uint8(Coverage.COMPLETE));
        (uint64 admissions,,,) = hot.counts();
        assertEq(p.observedCurrent, admissions);
        assertEq(p.next.basis.admissionHighWater, admissions);
        assertEq(p.next.lensIndex, 2);
        assertEq(ScopeKey.unwrap(p.next.scope), 0);
        assertEq(p.next.queryHash, lens.queryHash(_lens(pA, pB), FOLDER, S, MASK));
        assertEq(p.inventoryPin, 0);
    }

    function test_both_fall_through_policies() public {
        _mask(address(this), X);
        Page memory p = _list(_lens(pA, pB), _fresh(), 256, MASK);
        assertEq(p.rows.length, 4, "pA's mask hides pB's x");
        _assertRow(p, 3, Z, pB, rB);
        p = _list(_lens(pA, pB), _fresh(), 256, SILENCE);
        assertEq(p.rows.length, 5, "a mask is silence under SILENCE_FALLS_THROUGH");
        _assertRow(p, 3, X, pB, rB);
        _assertRow(p, 4, Z, pB, rB);
        _release(address(this), X);
        p = _list(_lens(pA, pB), _fresh(), 256, MASK);
        assertEq(p.rows.length, 5, "a release falls through under both");
        _assertRow(p, 3, X, pB, rB);
    }

    function test_paged_listing_and_the_continuation_coverage_law() public view {
        Page memory p1 = _list(_lens(pA, pB), _fresh(), 2, MASK);
        assertEq(p1.rows.length, 2);
        assertEq(p1.scanStatus, 2, "LIMIT");
        assertEq(uint8(p1.listingCoverage), uint8(Coverage.PARTIAL));
        assertFalse(p1.completeFromOrigin);
        assertEq(p1.next.rawIndex, 2);
        assertEq(
            ScopeKey.unwrap(p1.next.scope), Keys.scope(pA, FOLDER, S), "cursor names its scope"
        );
        Page memory p2 = _list(_lens(pA, pB), p1.next, 2, MASK | STRICT);
        assertEq(uint8(p2.q.status), uint8(Status.PRESENT));
        _assertRow(p2, 0, SUB, pA, S);
        _assertRow(p2, 1, TINY, pA, rTiny);
        assertEq(p2.next.lensIndex, 1);
        assertEq(p2.selectedSoFar, 4);
        assertFalse(p2.startsAtOrigin);
        Page memory p3 = _list(_lens(pA, pB), p2.next, 2, MASK | STRICT);
        assertEq(p3.rows.length, 1);
        _assertRow(p3, 0, Z, pB, rB);
        assertEq(p3.scanStatus, 1, "EXHAUSTED");
        assertFalse(p3.completeFromOrigin);
        assertEq(
            uint8(p3.listingCoverage), uint8(Coverage.PARTIAL), "never COMPLETE from a continuation"
        );
        assertEq(p3.selectedSoFar, 5);
    }

    function test_strict_basis_stale_relaxed_accepted_when_no_selected_scope_mutated() public {
        Page memory p1 = _list(_lens(pA, pB), _fresh(), 2, MASK);
        _unrelated(keccak256("another subject")); // admissions move; no scope of the query is stamped
        Page memory strict = _list(_lens(pA, pB), p1.next, 2, MASK | STRICT);
        assertEq(uint8(strict.q.status), uint8(Status.BASIS_STALE));
        assertEq(strict.rows.length, 0);
        Page memory relaxed = _list(_lens(pA, pB), p1.next, 2, MASK);
        assertEq(uint8(relaxed.q.status), uint8(Status.PRESENT));
        _assertRow(relaxed, 0, SUB, pA, S);
        assertEq(
            relaxed.next.basis.admissionHighWater, p1.next.basis.admissionHighWater, "origin kept"
        );
        assertGt(relaxed.observedCurrent, relaxed.next.basis.admissionHighWater);
    }

    function test_relaxed_continuation_refused_after_a_rebind_of_a_consumed_scope() public {
        Page memory p1 = _list(_lens(pA, pB), _fresh(), 2, MASK);
        _bind(address(this), Y, rTiny); // REBIND of an entry the first page already consumed
        Page memory p2 = _list(_lens(pA, pB), p1.next, 2, MASK);
        assertEq(uint8(p2.q.status), uint8(Status.BASIS_STALE));
        assertEq(uint8(p2.listingCoverage), uint8(Coverage.UNKNOWN));
    }

    function test_relaxed_continuation_refused_after_a_rebind_of_a_later_scope() public {
        Page memory p1 = _list(_lens(pA, pB), _fresh(), 2, MASK);
        _bind(alice, Z, rRoot); // REBIND in pB's scope, not yet reached
        assertEq(uint8(_list(_lens(pA, pB), p1.next, 2, MASK).q.status), uint8(Status.BASIS_STALE));
    }

    function test_relaxed_continuation_refused_after_a_restore() public {
        _mask(address(this), TINY);
        Page memory p1 = _list(_lens(pA, pB), _fresh(), 2, MASK);
        _bind(address(this), TINY, rTiny); // RESTORE (BIND from MASKED) stamps lastMutation
        assertEq(uint8(_list(_lens(pA, pB), p1.next, 2, MASK).q.status), uint8(Status.BASIS_STALE));
    }

    /// The selector list includes empty scopes (CQ-9): a principal of the lens with no entry yet whose first bind
    /// lands between pages refuses the relaxed continuation.
    function test_relaxed_continuation_refused_after_an_empty_scope_gains_an_entry() public {
        bytes32 pE = Keys.principal(makeAddr("eve"));
        bytes32[] memory l = new bytes32[](3);
        (l[0], l[1], l[2]) = (pA, pE, pB);
        Page memory p1 = lens.list(l, FOLDER, S, _fresh(), 2, MASK, _unpinned());
        assertEq(p1.rawTotal, 6);
        address eve = makeAddr("eve");
        _one(eve, _bindAction(eve, FOLDER, keccak256("e"), rRoot));
        Page memory p2 = lens.list(l, FOLDER, S, p1.next, 2, MASK, _unpinned());
        assertEq(uint8(p2.q.status), uint8(Status.BASIS_STALE));
    }

    function test_forged_cursors_and_bad_arguments_are_refused() public view {
        Cursor memory c = _list(_lens(pA, pB), _fresh(), 2, MASK).next;
        Cursor memory f = _copy(c);
        f.lensHash = keccak256("forged");
        _refused(_list(_lens(pA, pB), f, 2, MASK), Status.INVALID);
        _refused(_list(_lens(pB, pA), c, 2, MASK), Status.INVALID); // another lens order
        _refused(_list(_lens(pA, pB), c, 2, SILENCE), Status.INVALID); // another query
        f = _copy(c);
        f.scope = ScopeKey.wrap(Keys.scope(pB, FOLDER, S));
        _refused(_list(_lens(pA, pB), f, 2, MASK), Status.INVALID);
        f = _copy(c);
        f.rawIndex = 9;
        _refused(_list(_lens(pA, pB), f, 2, MASK), Status.INVALID);
        f = _copy(c);
        f.lensIndex = 3;
        _refused(_list(_lens(pA, pB), f, 2, MASK), Status.INVALID);
        f = _copy(c);
        f.basis.executionSet = keccak256("another execution set");
        _refused(_list(_lens(pA, pB), f, 2, MASK), Status.BASIS_STALE);
        f = _copy(c);
        f.basis.indexGeneration += 1;
        _refused(_list(_lens(pA, pB), f, 2, MASK), Status.BASIS_STALE);
        f = _copy(c);
        f.basis.admissionHighWater += 1;
        _refused(_list(_lens(pA, pB), f, 2, MASK), Status.BASIS_STALE);
        f = _fresh();
        f.rawIndex = 1; // a "fresh" cursor must be all zero
        _refused(_list(_lens(pA, pB), f, 2, MASK), Status.INVALID);
        _refused(_list(_lens(pA, pB), _fresh(), 0, MASK), Status.INVALID);
        _refused(_list(_lens(pA, pB), _fresh(), 2, 3), Status.INVALID);
        _refused(_list(new bytes32[](65), _fresh(), 2, MASK), Status.LIMIT_EXCEEDED);
        BasisCommit memory stale = reads.basis(k.proxy);
        stale.executionSet = keccak256("another execution set");
        _refused(lens.list(_lens(pA, pB), FOLDER, S, _fresh(), 2, MASK, stale), Status.BASIS_STALE);
    }

    function _copy(Cursor memory c) internal pure returns (Cursor memory d) {
        d = abi.decode(abi.encode(c), (Cursor));
    }

    function _refused(Page memory p, Status st) internal pure {
        assertEq(uint8(p.q.status), uint8(st), "page status");
        assertEq(p.rows.length, 0, "no rows");
        assertFalse(p.completeFromOrigin);
        assertTrue(p.listingCoverage != Coverage.COMPLETE);
    }
}
