// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {LensFixture} from "../harness/doubles/LensHistory.sol";
import {FaultyReads} from "../harness/doubles/FaultyReads.sol";
import {LensReader} from "../../src/readers/LensReader.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {Coverage, Qualified, Status} from "../../src/interfaces/Results.sol";
import {Page, Selection} from "../../src/interfaces/Readers.sol";
import {RecordHeader} from "../../src/interfaces/Views.sol";
import {ILedgerHot} from "../../src/interfaces/ILedgerHot.sol";
import {ILedgerReads} from "../../src/interfaces/ILedgerReads.sol";
import {ILedgerViews} from "../../src/interfaces/ILedgerViews.sol";
import {IIndexReads} from "../../src/interfaces/IIndexReads.sol";
import {IBitmapStore} from "../../src/interfaces/IBitmapStore.sol";

/// @notice The `FaultyReads` port for `LensReader` (design §11: "every reader is run through the FaultyReads port
///         (22 fault modes)"). The prototype's 22 modes (`lab-b/test/FaultyReads.sol`) are mapped onto the replies
///         this reader consumes — `LedgerViews.headsAt` (FaultyReads in front of the views facet), `LedgerReads`
///         (in front of the reads facet) and the Etched hot getters (in front of the ledger) — through the
///         generalized double's per-selector primitives; the generalized primitives the prototype lacked
///         (REVERT, EMPTY, EXHAUST, EXTRA, ZERO) are run too, and the listing surfaces (index, store) last. Every
///         fault must yield UNKNOWN or UNSUPPORTED as data — never PRESENT, ABSENT_PROVEN, a zero status or a
///         COMPLETE listing — and the faithful reply before arming must be the true answer.
///
///         headsAt reply words (lens [pA, pB] at x): 0 status, 1–8 selected, 9 selectedIndex, 10 offset, 11–16
///         basis (11 executionSet, 12 revision, 13 indexGeneration, 14 registryMutations, 15 admissionHighWater,
///         16 phase), 17 length, 18–25 all[0] (18 state, 19 revision, 20 admission, 21 targetKind, 22 prev, 23
///         ordinal, 24 notAfter, 25 target), 26–33 all[1]. record reply: 0 status, 1–6 header (1 typeId, 2
///         firstAdmission, …), 7 offset, 8–13 basis, 14 length, body. Hot `head`: 0 state, 1 revision, 2
///         admission, …, 6 target; hot `recordHeader`: 0 typeId, 1 firstAdmission, 2 length, 3 occurrences, 4 kind.
contract LensFaultyTest is LensFixture {
    uint8 internal constant REVERT = 1;
    uint8 internal constant SHORT = 2;
    uint8 internal constant EXTRA = 3;
    uint8 internal constant SET_WORD = 4;
    uint8 internal constant ADD_WORD = 5;
    uint8 internal constant ZERO = 6;
    uint8 internal constant STALE = 7;
    uint8 internal constant FUTURE_ADMISSION = 8;
    uint8 internal constant EXHAUST = 9;
    uint8 internal constant EMPTY = 10;

    bytes4 internal constant HEADS_AT = ILedgerViews.headsAt.selector;
    bytes4 internal constant RECORD = ILedgerReads.record.selector;
    bytes4 internal constant HOT_HEAD = ILedgerHot.head.selector;
    bytes4 internal constant HOT_RECORD = ILedgerHot.recordHeader.selector;

    FaultyReads internal fv; // in front of LedgerViews
    FaultyReads internal fr; // in front of LedgerReads
    FaultyReads internal fl; // in front of the ledger proxy
    LensReader internal lensV;
    LensReader internal lensR;
    LensReader internal lensL;

    function setUp() public override {
        super.setUp();
        fv = new FaultyReads(address(views));
        fv.setBasis(k.proxy);
        fr = new FaultyReads(address(reads));
        fr.setBasis(k.proxy);
        fl = new FaultyReads(k.proxy);
        lensV = new LensReader(k.proxy, address(fv), address(reads));
        lensR = new LensReader(k.proxy, address(views), address(fr));
        lensL = new LensReader(address(fl), address(views), address(reads));
        _assertFaithful(lensV);
        _assertFaithful(lensR);
        _assertFaithful(lensL);
    }

    // ---- the 22 prototype modes ---------------------------------------------------------------------------------

    function test_fault01_MISSING_PAIR() public {
        fr.setMode(RECORD, ZERO);
        _recordRefused(lensR);
        fr.clear(RECORD);
        fl.setMode(HOT_RECORD, ZERO); // the hot header says the bound record does not exist
        _recordRefused(lensL);
    }

    function test_fault02_WRONG_TYPE_ITEM() public {
        _arm(fr, RECORD, SET_WORD, 1, uint256(keccak256("faulty/not-an-item")));
        _recordRefused(lensR);
    }

    function test_fault03_ADMISSION_NOT_BIND() public {
        _arm(fv, HEADS_AT, SET_WORD, 18, 3); // pA's bound head reported RELEASED: it would fall through to pB
        _refused(lensV);
    }

    function test_fault04_ADMISSION_OUT_OF_RANGE() public {
        _arm(fv, HEADS_AT, SET_WORD, 9, 7); // a selected index beyond the lens
        _refused(lensV);
    }

    function test_fault05_SHORT_EVIDENCE() public {
        _arm(fv, HEADS_AT, SHORT, 0, 32);
        _refused(lensV);
    }

    function test_fault06_PARTIAL_CLAIMS_ENDED() public {
        _arm(fv, HEADS_AT, SET_WORD, 0, uint256(Status.ABSENT_PROVEN)); // "nothing" beside bound heads
        _refused(lensV);
    }

    function test_fault07_WRONG_SELECTED_REVISION() public {
        _arm(fv, HEADS_AT, ADD_WORD, 2, 1);
        _refused(lensV);
    }

    function test_fault08_ZERO_RECORD_FIRST_ADMISSION() public {
        _arm(fr, RECORD, SET_WORD, 2, 0);
        _recordRefused(lensR);
        fr.clear(RECORD);
        _arm(fl, HOT_RECORD, SET_WORD, 1, 0);
        _recordRefused(lensL);
    }

    function test_fault09_FUTURE_RECORD_FIRST_ADMISSION() public {
        _arm(fl, HOT_RECORD, FUTURE_ADMISSION, 1, 1);
        _recordRefused(lensL);
        _arm(fr, RECORD, FUTURE_ADMISSION, 2, 1);
        _recordRefused(lensR);
    }

    function test_fault10_ZERO_SELECTED_ADMISSION() public {
        _arm(fv, HEADS_AT, SET_WORD, 20, 0);
        _refused(lensV);
    }

    function test_fault11_FUTURE_SELECTED_ADMISSION() public {
        _arm(fv, HEADS_AT, FUTURE_ADMISSION, 20, 1);
        _refused(lensV);
    }

    function test_fault12_ZERO_PLACEMENT_ADMISSION() public {
        _arm(fl, HOT_HEAD, SET_WORD, 2, 0); // the Etched head disagrees with the facet
        _refused(lensL);
    }

    function test_fault13_FUTURE_PLACEMENT_ADMISSION() public {
        _arm(fl, HOT_HEAD, FUTURE_ADMISSION, 2, 1);
        _refused(lensL);
    }

    function test_fault14_WRONG_BINDING_POSITION() public {
        _arm(fv, HEADS_AT, SET_WORD, 25, uint256(rA2)); // a real record, the wrong one
        _refused(lensV);
        fv.clear(HEADS_AT);
        _arm(fl, HOT_HEAD, SET_WORD, 6, uint256(rA2));
        _refused(lensL);
        // the listing's form: every scope entry resolves to a real but wrong coordinate (y)
        _arm(
            fr,
            ILedgerReads.bindingPosition.selector,
            SET_WORD,
            1,
            uint256(Keys.position(FOLDER, S, Y))
        );
        _pageRefused(lensR.list(_lens(pA, pB), FOLDER, S, _fresh(), 256, 1, _unpinned()));
    }

    function test_fault15_WRONG_ADMISSION_REVISION() public {
        _arm(fl, HOT_HEAD, ADD_WORD, 1, 1);
        _refused(lensL);
        _arm(fv, HEADS_AT, ADD_WORD, 27, 1); // the second candidate's revision: no-tiebreak confirms it
        (Qualified memory q, Selection[] memory c) =
            lensV.resolveNoTiebreak(_lens(pA, pB), _at(X), _unpinned());
        assertEq(uint8(q.status), uint8(Status.UNKNOWN));
        assertEq(c.length, 0);
    }

    function test_fault16_MAX_ADMISSION_REVISION() public {
        _arm(fv, HEADS_AT, SET_WORD, 19, type(uint256).max); // must not wrap into a uint64 revision
        _refused(lensV);
    }

    function test_fault17_IMPORTED_PUBLICATION() public {
        _arm(fv, HEADS_AT, SET_WORD, 18, 4); // a reserved head state the facet did not report
        _refused(lensV);
    }

    function test_fault18_CURSOR_GENERATION_MISMATCH() public {
        _arm(fv, HEADS_AT, ADD_WORD, 13, 1);
        _refused(lensV);
    }

    function test_fault19_CURSOR_EPOCH_MISMATCH() public {
        _arm(fv, HEADS_AT, ADD_WORD, 12, 1);
        _refused(lensV);
    }

    function test_fault20_CURSOR_CORE_MISMATCH() public {
        _arm(fv, HEADS_AT, SET_WORD, 11, uint256(keccak256("another execution set")));
        _refused(lensV);
    }

    function test_fault21_CURSOR_SCOPE_MISMATCH() public {
        fv.capture(abi.encodeCall(ILedgerViews.headsAt, (k.proxy, _lens(pA, pB), _posX())));
        _mask(address(this), X); // the captured reply is now a stale basis
        fv.setMode(HEADS_AT, STALE);
        _refused(lensV);
    }

    function test_fault22_CURSOR_LENS_MISMATCH() public {
        _arm(fv, HEADS_AT, SET_WORD, 17, 1); // the heads array no longer matches the lens
        _refused(lensV);
    }

    // ---- the generalized primitives -------------------------------------------------------------------------

    function test_primitive_REVERT_EMPTY_EXTRA_ZERO_on_headsAt() public {
        uint8[4] memory modes = [REVERT, EMPTY, EXTRA, ZERO];
        for (uint256 i; i < modes.length; ++i) {
            _arm(fv, HEADS_AT, modes[i], 0, 32);
            _refused(lensV);
        }
    }

    /// A facet that burns every forwarded gas unit leaves the reader the 1/64 the EVM retains, enough to return
    /// UNKNOWN as data (one read per call: each exhausted call costs the caller 63/64 of what remains).
    function test_primitive_EXHAUST_on_headsAt() public {
        _arm(fv, HEADS_AT, EXHAUST, 0, 0);
        (Qualified memory q, Selection memory s) = lensV.resolve(_lens(pA, pB), _at(X), _unpinned());
        assertEq(uint8(q.status), uint8(Status.UNKNOWN));
        assertEq(s.target, 0);
    }

    function test_primitive_faults_on_basis_record_and_hot_head() public {
        fr.setMode(ILedgerReads.basis.selector, REVERT);
        _refused(lensR);
        fr.setMode(ILedgerReads.basis.selector, ZERO);
        _refused(lensR);
        fr.clear(ILedgerReads.basis.selector);
        fr.setMode(RECORD, EMPTY);
        _recordRefused(lensR);
        fl.setMode(HOT_HEAD, ZERO);
        _refused(lensL);
        _arm(fl, HOT_HEAD, EXTRA, 0, 32);
        _refused(lensL);
    }

    // ---- the listing surfaces: index, store, coverage -------------------------------------------------------

    function test_listing_faults_on_index_store_and_coverage() public {
        FaultyReads fi = new FaultyReads(address(g.index));
        FaultyReads fs = new FaultyReads(address(g.bitmap));
        fs.setBasis(k.proxy);
        _arm(fl, ILedgerHot.index.selector, SET_WORD, 0, uint256(uint160(address(fi))));
        _arm(fi, IIndexReads.bitmapStore.selector, SET_WORD, 0, uint256(uint160(address(fs))));
        Page memory p = _page();
        assertEq(uint8(p.q.status), uint8(Status.PRESENT), "faithful through the wrappers");
        assertEq(uint8(p.listingCoverage), uint8(Coverage.COMPLETE));

        _arm(fs, IBitmapStore.scopeSlice.selector, ADD_WORD, 2, 1); // a wrong first entry
        _pageRefused(_page());
        fs.clear(IBitmapStore.scopeSlice.selector);
        _arm(fs, IBitmapStore.scopeHead.selector, FUTURE_ADMISSION, 2, 1); // lastMutation in the future
        _pageRefused(_page());
        fs.clear(IBitmapStore.scopeHead.selector);
        _arm(fs, IBitmapStore.scopeSlice.selector, SHORT, 0, 64);
        _pageRefused(_page());
        fs.clear(IBitmapStore.scopeSlice.selector);

        _arm(fi, IIndexReads.coverage.selector, SET_WORD, 0, uint256(Coverage.UNKNOWN));
        _pageRefused(_page());
        _arm(fi, IIndexReads.coverage.selector, SET_WORD, 0, uint256(Coverage.PARTIAL));
        p = _page();
        assertEq(uint8(p.q.status), uint8(Status.PRESENT));
        assertEq(
            uint8(p.listingCoverage), uint8(Coverage.PARTIAL), "PARTIAL coverage is never COMPLETE"
        );
        assertFalse(p.completeFromOrigin);
        _arm(fi, IIndexReads.coverage.selector, ADD_WORD, 2, 1); // COMPLETE through the wrong admission
        p = _page();
        assertEq(uint8(p.listingCoverage), uint8(Coverage.PARTIAL));
        fi.clear(IIndexReads.coverage.selector);

        _arm(fi, IIndexReads.manifest.selector, SET_WORD, 18, uint256(keccak256("another layout")));
        _pageRefused(_page());
        fi.clear(IIndexReads.manifest.selector);
        _arm(fl, ILedgerHot.index.selector, SET_WORD, 0, 0);
        _pageRefused(_page());
    }

    // ---- helpers ----------------------------------------------------------------------------------------------

    function _arm(FaultyReads f, bytes4 selector, uint8 mode, uint16 word, uint256 value) internal {
        f.setFault(selector, FaultyReads.Fault(mode, word, false, bytes32(0), value));
    }

    function _posX() internal view returns (bytes32) {
        return Keys.position(FOLDER, S, X);
    }

    function _page() internal view returns (Page memory) {
        return lensL.list(_lens(pA, pB), FOLDER, S, _fresh(), 256, 1, _unpinned());
    }

    function _assertFaithful(LensReader l) internal view {
        (Qualified memory q, Selection memory s) = l.resolve(_lens(pA, pB), _at(X), _unpinned());
        _assertSelected(q, s, Status.PRESENT, pA, 0, rRoot);
        bytes memory body;
        (q,,, body) = l.resolveRecord(_lens(pA, pB), _at(X), 1024, _unpinned());
        assertEq(uint8(q.status), uint8(Status.PRESENT));
        assertEq(body, rootBody);
    }

    function _bad(Status st) internal pure returns (bool) {
        return st == Status.UNKNOWN || st == Status.UNSUPPORTED;
    }

    /// Every point read through `l` is refused as data: no selection, no target, no candidates, no record.
    function _refused(LensReader l) internal view {
        (Qualified memory q, Selection memory s) = l.resolve(_lens(pA, pB), _at(X), _unpinned());
        assertTrue(_bad(q.status), "resolve: UNKNOWN or UNSUPPORTED");
        assertEq(uint8(s.status), uint8(q.status), "the selection carries the refusal");
        assertEq(s.target, 0, "no fabricated target");
        assertEq(s.principalId, 0, "no fabricated principal");
        Selection[] memory c;
        (q, c) = l.resolveNoTiebreak(_lens(pA, pB), _at(X), _unpinned());
        assertTrue(_bad(q.status), "resolveNoTiebreak");
        assertEq(c.length, 0);
        (uint64 admissions,,,) = hot.counts();
        (q, s) = l.resolveAt(_lens(pA, pB), _at(X), admissions, _unpinned());
        assertTrue(_bad(q.status), "resolveAt");
        _recordRefused(l);
    }

    function _recordRefused(LensReader l) internal view {
        (Qualified memory q,, RecordHeader memory h, bytes memory body) =
            l.resolveRecord(_lens(pA, pB), _at(X), 1024, _unpinned());
        assertTrue(_bad(q.status), "resolveRecord: UNKNOWN or UNSUPPORTED");
        assertEq(h.typeId, 0, "no header");
        assertEq(body.length, 0, "no body");
    }

    function _pageRefused(Page memory p) internal pure {
        assertTrue(_bad(p.q.status), "page: UNKNOWN or UNSUPPORTED");
        assertEq(p.rows.length, 0, "no rows");
        assertFalse(p.completeFromOrigin);
        assertTrue(p.listingCoverage != Coverage.COMPLETE, "never COMPLETE");
    }
}
