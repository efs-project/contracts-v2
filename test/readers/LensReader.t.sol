// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {LensFixture} from "../harness/doubles/LensHistory.sol";
import {LensReader} from "../../src/readers/LensReader.sol";
import {RealmIndex} from "../../src/index/RealmIndex.sol";
import {Layout} from "../../src/core/layout/Layout.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {Coordinate} from "../../src/interfaces/Actions.sol";
import {BasisCommit, Qualified, Status} from "../../src/interfaces/Results.sol";
import {Selection} from "../../src/interfaces/Readers.sol";
import {RecordHeader} from "../../src/interfaces/Views.sol";

/// @notice `LensReview` (design §11, §16.3), point reads: the flat-ordered law case by case over the two-author
///         history of `LensFixture`, `resolveRecord`, the as-of reads, the basis pin and the principal limits.
contract LensReviewTest is LensFixture {
    // ---- the flat-ordered law ---------------------------------------------------------------------------------

    function test_first_touch_wins() public view {
        (Qualified memory q, Selection memory s) = lens.resolve(_lens(pA, pB), _at(X), _unpinned());
        _assertSelected(q, s, Status.PRESENT, pA, 0, rRoot);
        assertEq(s.targetKind, 1);
        assertEq(s.revision, 1);
        (q, s) = lens.resolve(_lens(pB, pA), _at(X), _unpinned());
        _assertSelected(q, s, Status.PRESENT, pB, 0, rB);
        // an UNSET head falls through
        (q, s) = lens.resolve(_lens(pNobody, pB), _at(X), _unpinned());
        _assertSelected(q, s, Status.PRESENT, pB, 1, rB);
        // nothing anywhere: ABSENT_PROVEN with no selected index, never a zero status
        (q, s) = lens.resolve(_lens(pNobody, pB), _at(keccak256("none")), _unpinned());
        _assertSelected(q, s, Status.ABSENT_PROVEN, 0, 255, 0);
    }

    function test_mask_beats_fall_through() public {
        _mask(address(this), X);
        (Qualified memory q, Selection memory s) = lens.resolve(_lens(pA, pB), _at(X), _unpinned());
        _assertSelected(q, s, Status.MASKED, pA, 0, 0);
        assertEq(s.targetKind, 1, "a mask keeps the target kind");
        assertEq(s.revision, 2);
        (q, s) = lens.resolve(_lens(pB, pA), _at(X), _unpinned());
        _assertSelected(q, s, Status.PRESENT, pB, 0, rB);
    }

    function test_release_falls_through() public {
        _release(address(this), X);
        (Qualified memory q, Selection memory s) = lens.resolve(_lens(pA, pB), _at(X), _unpinned());
        _assertSelected(q, s, Status.PRESENT, pB, 1, rB);
        // a release after a mask falls through too
        _mask(alice, X);
        _release(alice, X);
        (q, s) = lens.resolve(_lens(pA, pB), _at(X), _unpinned());
        _assertSelected(q, s, Status.ABSENT_PROVEN, 0, 255, 0);
        // the restore rebinds and wins again
        _bind(address(this), X, rA2);
        (q, s) = lens.resolve(_lens(pA, pB), _at(X), _unpinned());
        _assertSelected(q, s, Status.PRESENT, pA, 0, rA2);
        assertEq(s.revision, 3);
    }

    function test_no_tiebreak_returns_all_live_candidates_and_conflict() public {
        (Qualified memory q, Selection[] memory c) =
            lens.resolveNoTiebreak(_lens(pA, pB), _at(X), _unpinned());
        assertEq(uint8(q.status), uint8(Status.CONFLICT));
        assertEq(c.length, 2);
        assertEq(c[0].principalId, pA);
        assertEq(c[0].target, rRoot);
        assertEq(c[1].principalId, pB);
        assertEq(c[1].target, rB);
        assertEq(c[1].selectedIndex, 1);
        (q, c) = lens.resolveNoTiebreak(_lens(pA, pB), _at(Y), _unpinned());
        assertEq(uint8(q.status), uint8(Status.PRESENT));
        assertEq(c.length, 1);
        // a live candidate beside a mask is a conflict, never an incidental-order winner
        _mask(address(this), X);
        (q, c) = lens.resolveNoTiebreak(_lens(pA, pB), _at(X), _unpinned());
        assertEq(uint8(q.status), uint8(Status.CONFLICT));
        assertEq(c.length, 1);
        assertEq(c[0].principalId, pB);
        _mask(alice, X);
        (q, c) = lens.resolveNoTiebreak(_lens(pA, pB), _at(X), _unpinned());
        assertEq(uint8(q.status), uint8(Status.MASKED));
        assertEq(c.length, 0);
        (q, c) = lens.resolveNoTiebreak(_lens(pA, pB), _at(keccak256("none")), _unpinned());
        assertEq(uint8(q.status), uint8(Status.ABSENT_PROVEN));
    }

    /// A reserved head state (5..255 are refused by the kernel; written here with `vm.store`) is reported
    /// UNSUPPORTED by `headsAt` and is UNKNOWN to the lens: the answer never falls through to the next author.
    function test_unknown_never_falls_through() public {
        bytes32 key = Keys.binding(pA, Keys.position(FOLDER, S, X));
        bytes32 slot = bytes32(Layout.bindingsHeadsSlot(key));
        bytes32 meta = vm.load(k.proxy, slot);
        vm.store(k.proxy, slot, (meta & ~bytes32(uint256(0xff))) | bytes32(uint256(4)));
        (Status st,, uint8 idx,,) =
            views.headsAt(k.proxy, _lens(pA, pB), Keys.position(FOLDER, S, X));
        assertEq(uint8(st), uint8(Status.UNSUPPORTED), "the facet reports the reserved state");
        assertEq(idx, 0);
        (Qualified memory q, Selection memory s) = lens.resolve(_lens(pA, pB), _at(X), _unpinned());
        _assertSelected(q, s, Status.UNKNOWN, 0, 0, 0);
        (q,) = lens.resolveNoTiebreak(_lens(pA, pB), _at(X), _unpinned());
        assertEq(uint8(q.status), uint8(Status.UNKNOWN));
        (q,,,) = lens.resolveRecord(_lens(pA, pB), _at(X), 1024, _unpinned());
        assertEq(uint8(q.status), uint8(Status.UNKNOWN));
        // a winner before the reserved head still decides
        (q, s) = lens.resolve(_lens(pB, pA), _at(X), _unpinned());
        _assertSelected(q, s, Status.PRESENT, pB, 0, rB);
    }

    // ---- resolveRecord ------------------------------------------------------------------------------------------

    function test_resolveRecord_returns_the_winners_header_and_body() public view {
        (Qualified memory q, Selection memory s, RecordHeader memory h, bytes memory body) =
            lens.resolveRecord(_lens(pA, pB), _at(X), 1024, _unpinned());
        _assertSelected(q, s, Status.PRESENT, pA, 0, rRoot);
        assertEq(h.typeId, TYPE_OK);
        assertEq(h.length, rootBody.length);
        assertEq(h.word0, S);
        assertGt(h.firstAdmission, 0);
        assertLt(h.firstAdmission, s.admission);
        assertEq(body, rootBody);
        (q, s, h, body) = lens.resolveRecord(_lens(pB, pA), _at(X), 1024, _unpinned());
        _assertSelected(q, s, Status.PRESENT, pB, 0, rB);
        assertEq(body, bBody);
        // a body shorter than one word
        (q,, h, body) = lens.resolveRecord(_lens(pA, pB), _at(TINY), 1024, _unpinned());
        assertEq(uint8(q.status), uint8(Status.PRESENT));
        assertEq(body, tinyBody);
    }

    function test_resolveRecord_refusals() public {
        // a subject target is not a record
        (Qualified memory q, Selection memory s,, bytes memory body) =
            lens.resolveRecord(_lens(pA, pB), _at(SUB), 1024, _unpinned());
        assertEq(uint8(q.status), uint8(Status.INVALID));
        assertEq(uint8(s.status), uint8(Status.PRESENT), "the selection itself is true");
        assertEq(s.targetKind, 2);
        assertEq(s.target, S);
        // longer than maxBytes: the verified header, no body
        RecordHeader memory h;
        (q,, h, body) = lens.resolveRecord(_lens(pA, pB), _at(X), 16, _unpinned());
        assertEq(uint8(q.status), uint8(Status.LIMIT_EXCEEDED));
        assertEq(h.length, rootBody.length);
        assertEq(h.word0, S);
        assertEq(body.length, 0);
        // not PRESENT: the selection's status, no record read
        _mask(address(this), X);
        (q,, h,) = lens.resolveRecord(_lens(pA, pB), _at(X), 1024, _unpinned());
        assertEq(uint8(q.status), uint8(Status.MASKED));
        assertEq(h.typeId, 0);
    }

    /// The reader-side HEAD rule (design §12.1): a HEAD target whose word 0 / word 1 is not the subject.
    function test_resolveRecord_head_rule() public view {
        (Qualified memory q,,, bytes memory body) =
            lens.resolveRecord(_lens(pA, pB), _head(), 1024, _unpinned());
        assertEq(uint8(q.status), uint8(Status.PRESENT));
        assertEq(body, rootBody);
        Selection memory s;
        (q, s,,) = lens.resolveRecord(_lens(pB, pA), _head(), 1024, _unpinned());
        assertEq(uint8(q.status), uint8(Status.INVALID));
        assertEq(s.target, rB);
        // the same record under FOLDER is not subject to the HEAD rule
        (q,,,) = lens.resolveRecord(_lens(pB, pA), _at(Z), 1024, _unpinned());
        assertEq(uint8(q.status), uint8(Status.PRESENT));
    }

    // ---- as-of reads --------------------------------------------------------------------------------------------

    function test_resolveAt_and_resolveManyAt() public {
        (uint64 before,,,) = hot.counts();
        _mask(address(this), X);
        _bind(alice, X, rRoot);
        (Qualified memory q, Selection memory s) =
            lens.resolveAt(_lens(pA, pB), _at(X), before, _unpinned());
        _assertSelected(q, s, Status.PRESENT, pA, 0, rRoot);
        assertEq(s.revision, 1);
        (uint64 nowAt,,,) = hot.counts();
        (q, s) = lens.resolveAt(_lens(pA, pB), _at(X), nowAt, _unpinned());
        _assertSelected(q, s, Status.MASKED, pA, 0, 0);
        (q, s) = lens.resolveAt(_lens(pB, pA), _at(X), before, _unpinned());
        _assertSelected(q, s, Status.PRESENT, pB, 0, rB);
        (q, s) = lens.resolveAt(_lens(pB, pA), _at(X), 0, _unpinned());
        _assertSelected(q, s, Status.ABSENT_PROVEN, 0, 255, 0);
        (q, s) = lens.resolveAt(_lens(pA, pB), _at(X), nowAt + 1, _unpinned());
        assertEq(uint8(q.status), uint8(Status.BASIS_STALE));
        // resolveManyAt equals the per-coordinate reads
        Coordinate[] memory coords = new Coordinate[](3);
        coords[0] = _at(X);
        coords[1] = _at(Z);
        coords[2] = _at(keccak256("none"));
        for (uint64 asOf = 0; asOf <= nowAt; asOf += 3) {
            Selection[] memory many;
            (q, many) = lens.resolveManyAt(_lens(pB, pA), coords, asOf, _unpinned());
            assertEq(uint8(q.status), uint8(Status.PRESENT));
            for (uint256 i; i < coords.length; ++i) {
                (, s) = lens.resolveAt(_lens(pB, pA), coords[i], asOf, _unpinned());
                assertEq(keccak256(abi.encode(many[i])), keccak256(abi.encode(s)), "per coordinate");
            }
        }
    }

    // ---- basis pin and limits -------------------------------------------------------------------------------

    function test_expected_basis_pin() public view {
        BasisCommit memory b = reads.basis(k.proxy);
        (Qualified memory q,) = lens.resolve(_lens(pA, pB), _at(X), b);
        assertEq(uint8(q.status), uint8(Status.PRESENT));
        assertEq(keccak256(abi.encode(q.observed)), keccak256(abi.encode(b)), "basis echoed");
        BasisCommit memory other = b;
        other.executionSet = keccak256("another execution set");
        (q,) = lens.resolve(_lens(pA, pB), _at(X), other);
        assertEq(uint8(q.status), uint8(Status.BASIS_STALE));
        other = reads.basis(k.proxy);
        other.indexGeneration += 1;
        (q,) = lens.resolve(_lens(pA, pB), _at(X), other);
        assertEq(uint8(q.status), uint8(Status.BASIS_STALE));
        other = reads.basis(k.proxy);
        other.admissionHighWater += 1; // the caller has seen admissions this node has not
        (q,) = lens.resolve(_lens(pA, pB), _at(X), other);
        assertEq(uint8(q.status), uint8(Status.BASIS_STALE));
    }

    function test_64_principals_in_one_call_65_refused() public view {
        bytes32[] memory many = new bytes32[](64);
        for (uint256 i; i < 63; ++i) {
            many[i] = keccak256(abi.encode("stranger", i));
        }
        many[63] = pB;
        (Qualified memory q, Selection memory s) = lens.resolve(many, _at(X), _unpinned());
        _assertSelected(q, s, Status.PRESENT, pB, 63, rB);
        Selection[] memory c;
        (q, c) = lens.resolveNoTiebreak(many, _at(X), _unpinned());
        assertEq(uint8(q.status), uint8(Status.PRESENT));
        assertEq(c.length, 1);
        bytes32[] memory tooMany = new bytes32[](65);
        tooMany[64] = pB;
        (q, s) = lens.resolve(tooMany, _at(X), _unpinned());
        _assertSelected(q, s, Status.LIMIT_EXCEEDED, 0, 255, 0);
        (q, c) = lens.resolveNoTiebreak(tooMany, _at(X), _unpinned());
        assertEq(uint8(q.status), uint8(Status.LIMIT_EXCEEDED));
        (q, s) = lens.resolve(new bytes32[](0), _at(X), _unpinned());
        assertEq(uint8(q.status), uint8(Status.INVALID));
        assertEq(uint8(s.status), uint8(Status.INVALID));
    }

    function test_reader_identity() public view {
        assertEq(lens.ledger(), k.proxy);
        assertEq(lens.layoutId(), Layout.LAYOUT_ID);
        assertEq(lens.facetVersion(), 1);
        (bytes32[] memory cb, bytes32[] memory phys) = lens.supportedProfiles();
        assertEq(cb.length, 1);
        assertEq(cb[0], RealmIndex(address(g.index)).CALLBACK_PROFILE());
        assertEq(phys[0], RealmIndex(address(g.index)).PHYSICAL_PROFILE());
    }

    function test_reports_runtime_size() public {
        LensReader fresh = new LensReader(k.proxy, address(views), address(reads));
        emit log_named_uint("LensReader runtime bytes", address(fresh).code.length);
        assertGt(address(fresh).code.length, 0);
        assertLe(address(fresh).code.length, 19_660, "within the 19,660 B budget");
    }
}
