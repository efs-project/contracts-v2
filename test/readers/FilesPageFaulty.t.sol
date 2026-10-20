// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FilesPageHarness} from "../harness/doubles/FilesPageHarness.sol";
import {FaultyReads} from "../harness/doubles/FaultyReads.sol";
import {
    FilesPageReader,
    E_FILES_INCONSISTENT,
    E_FILES_READ,
    E_FILES_REPLY
} from "../../src/readers/FilesPageReader.sol";
import {EfsFiles} from "../../src/lib/EfsFiles.sol";
import {Action} from "../../src/interfaces/Actions.sol";
import {BasisCommit, Coverage, Status} from "../../src/interfaces/Results.sol";
import {IFilesPageReader} from "../../src/interfaces/Readers.sol";
import {ILedgerHot} from "../../src/interfaces/ILedgerHot.sol";
import {ILedgerReads} from "../../src/interfaces/ILedgerReads.sol";
import {ILedgerViews} from "../../src/interfaces/ILedgerViews.sol";
import {IIndexReads} from "../../src/interfaces/IIndexReads.sol";
import {IBitmapStore} from "../../src/interfaces/IBitmapStore.sol";

/// @notice `listDirectory` through the `FaultyReads` port (design §11: "every reader is run through the
///         `FaultyReads` port (22 fault modes)"). One `FaultyReads` sits in front of each dependency — the ledger,
///         `LedgerViews`, `LedgerReads`, the index and its bitmap store (the ledger's `index()` and the index's
///         `bitmapStore()` are rewritten to the wrappers) — and a second reader is built over the wrappers. The
///         prototype's 22 modes map onto the generalized primitives as `FaultyReads` documents them (1 ZERO,
///         5 SHORT, 13 SET_WORD, 4 ADD_WORD, 3 FUTURE_ADMISSION: `m01`–`m22`), and the five new primitives
///         (REVERT, EXTRA, STALE, EXHAUST, EMPTY) follow. Every fault ends in a named revert (`E_FILES_READ`,
///         `E_FILES_REPLY`, `E_FILES_INCONSISTENT(code)`) or a refusal as data (UNSUPPORTED / BASIS_STALE with no
///         rows and coverage UNKNOWN); none yields a zero status, a fabricated row or a COMPLETE listing. EXTRA
///         (trailing bytes) is the one fault a correct reader tolerates: the page is the faithful one.
contract FilesPageFaultyTest is FilesPageHarness {
    // FaultyReads modes (its public constants)
    uint8 internal constant M_REVERT = 1;
    uint8 internal constant M_SHORT = 2;
    uint8 internal constant M_EXTRA = 3;
    uint8 internal constant M_SET_WORD = 4;
    uint8 internal constant M_ADD_WORD = 5;
    uint8 internal constant M_ZERO = 6;
    uint8 internal constant M_STALE = 7;
    uint8 internal constant M_FUTURE_ADMISSION = 8;
    uint8 internal constant M_EXHAUST = 9;
    uint8 internal constant M_EMPTY = 10;

    FaultyReads internal fl;
    FaultyReads internal fv;
    FaultyReads internal fr;
    FaultyReads internal fi;
    FaultyReads internal fs;
    FilesPageReader internal faulty;
    IFilesPageReader.DirectoryPage internal faithful;
    bytes32 internal docs;

    function setUp() public {
        _setUpFiles(keccak256("files-page/faulty"));
        docs = _folder(rootDir, "docs");
        (bytes32 file, bytes32 root) = _file(address(this), rootDir, "a.txt", "alpha", true);
        _file(address(this), rootDir, "b.txt", "beta", true);
        (Action[] memory a, bytes[] memory b,) = EfsFiles.edit(t, file, root, "alpha 2", 1);
        _exec(a, b);
        (a, b) = EfsFiles.remove(rootDir, "b.txt", 1);
        _exec(a, b);
        fl = new FaultyReads(address(r.ledger));
        fv = new FaultyReads(address(views));
        fr = new FaultyReads(address(reads));
        fi = new FaultyReads(address(r.g.index));
        fs = new FaultyReads(address(r.g.bitmap));
        // FUTURE_ADMISSION is relative to the ledger's admissions
        fv.setBasis(address(r.ledger));
        fr.setBasis(address(r.ledger));
        fi.setBasis(address(r.ledger));
        fs.setBasis(address(r.ledger));
        _set(fl, ILedgerHot.index.selector, M_SET_WORD, 0, uint160(address(fi)));
        _set(fi, IIndexReads.bitmapStore.selector, M_SET_WORD, 0, uint160(address(fs)));
        faulty = new FilesPageReader(
            address(fl),
            address(fv),
            address(fr),
            typeIds[T_NAME],
            typeIds[T_ROOT],
            typeIds[T_CHILD]
        );
        faithful = _page();
    }

    function _set(FaultyReads f, bytes4 selector, uint8 mode, uint16 word, uint256 value) internal {
        f.setFault(selector, FaultyReads.Fault(mode, word, false, bytes32(0), value));
    }

    function _page() internal view returns (IFilesPageReader.DirectoryPage memory) {
        return faulty.listDirectory(rootDir, _lens(p), _q(F_ALL, 0), _unbound(), "", 0, 0);
    }

    function _call() internal view {
        faulty.listDirectory(rootDir, _lens(p), _q(F_ALL, 0), _unbound(), "", 0, 0);
    }

    function _inconsistent(uint8 code) internal {
        vm.expectRevert(abi.encodeWithSelector(E_FILES_INCONSISTENT.selector, code));
        _call();
    }

    function _reply() internal {
        vm.expectPartialRevert(E_FILES_REPLY.selector);
        _call();
    }

    function _read() internal {
        vm.expectPartialRevert(E_FILES_READ.selector);
        _call();
    }

    function _refusedAsData(Status st) internal view {
        IFilesPageReader.DirectoryPage memory pg = _page();
        assertEq(uint8(pg.q.status), uint8(st));
        assertEq(pg.rows.length, 0);
        assertEq(uint8(pg.listingCoverage), uint8(Coverage.UNKNOWN));
        assertFalse(pg.completeFromOrigin);
        assertEq(pg.next.length, 0);
    }

    function test_the_wrappers_are_faithful_without_a_fault() public view {
        IFilesPageReader.DirectoryPage memory real = _list(rootDir, _lens(p), F_ALL);
        assertEq(faithful.rows.length, 2);
        assertEq(keccak256(abi.encode(faithful.rows)), keccak256(abi.encode(real.rows)));
        assertEq(uint8(faithful.listingCoverage), uint8(Coverage.COMPLETE));
    }

    // ---- 1 ZERO, 5 SHORT ----------------------------------------------------------------------------------

    function test_m01_zero_binding_position_is_a_reply_fault() public {
        fr.setMode(ILedgerReads.bindingPosition.selector, M_ZERO);
        _reply();
    }

    function test_m05_short_heads_at_is_a_reply_fault() public {
        _set(fv, ILedgerViews.headsAt.selector, M_SHORT, 0, 320);
        _reply();
    }

    // ---- 13 SET_WORD ---------------------------------------------------------------------------------------

    function test_m02_live_bits_for_dead_entries() public {
        _set(fs, IBitmapStore.liveWords.selector, M_SET_WORD, 2, type(uint256).max);
        _inconsistent(1);
    }

    function test_m03_scope_live_count_past_its_entries() public {
        _set(fs, IBitmapStore.scopeHead.selector, M_SET_WORD, 1, 9);
        _inconsistent(2);
    }

    function test_m04_scope_entry_past_the_admissions() public {
        _set(fs, IBitmapStore.scopeSlice.selector, M_SET_WORD, 2, 1 << 40);
        _inconsistent(3);
    }

    /// The facets refuse a foreign layout too; the reader answers UNSUPPORTED before calling them.
    function test_m06_foreign_layout_is_unsupported_as_data() public {
        _set(fl, ILedgerHot.layoutId.selector, M_SET_WORD, 0, uint256(keccak256("other")));
        _refusedAsData(Status.UNSUPPORTED);
    }

    function test_m08_execution_set_drift_against_a_bound_basis() public {
        BasisCommit memory b = reads.basis(address(r.ledger));
        _set(fl, ILedgerHot.executionSet.selector, M_SET_WORD, 0, uint256(keccak256("x")));
        IFilesPageReader.DirectoryPage memory pg =
            faulty.listDirectory(rootDir, _lens(p), _q(F_ALL, 0), b, "", 0, 0);
        assertEq(uint8(pg.q.status), uint8(Status.BASIS_STALE));
        assertEq(pg.rows.length, 0);
    }

    function test_m10_heads_at_status_contradicts_its_state() public {
        _set(fv, ILedgerViews.headsAt.selector, M_SET_WORD, 0, uint8(Status.MASKED));
        _inconsistent(5);
    }

    function test_m12_heads_at_selects_nobody() public {
        _set(fv, ILedgerViews.headsAt.selector, M_SET_WORD, 9, 255);
        _inconsistent(5);
    }

    function test_m14_binding_position_of_another_coordinate() public {
        _set(fr, ILedgerReads.bindingPosition.selector, M_SET_WORD, 1, uint256(keccak256("p")));
        _inconsistent(4);
    }

    function test_m16_position_cell_with_a_foreign_role() public {
        _set(fr, ILedgerReads.positionCell.selector, M_SET_WORD, 3, uint256(keccak256("r")));
        _inconsistent(4);
    }

    function test_m17_name_bytes_that_are_not_the_role() public {
        _set(fr, ILedgerReads.bodySlice.selector, M_SET_WORD, 3, uint256(keccak256("n")));
        _inconsistent(7);
    }

    function test_m20_coverage_unset_is_a_reply_fault() public {
        _set(fi, IIndexReads.coverage.selector, M_SET_WORD, 0, 0);
        _reply();
    }

    function test_m21_unlisted_index_profile_is_unsupported_as_data() public {
        _set(fi, bytes4(keccak256("PHYSICAL_PROFILE()")), M_SET_WORD, 0, 1);
        _refusedAsData(Status.UNSUPPORTED);
    }

    function test_m22_heads_at_echoes_another_basis() public {
        _set(fv, ILedgerViews.headsAt.selector, M_SET_WORD, 11, uint256(keccak256("e")));
        _inconsistent(6);
    }

    // ---- 4 ADD_WORD ----------------------------------------------------------------------------------------

    function test_m07_scope_live_count_one_short() public {
        _set(fs, IBitmapStore.scopeHead.selector, M_ADD_WORD, 1, type(uint256).max);
        _inconsistent(1);
    }

    function test_m15_heads_at_state_off_by_one() public {
        _set(fv, ILedgerViews.headsAt.selector, M_ADD_WORD, 1, 1);
        _inconsistent(5);
    }

    function test_m18_name_length_one_short() public {
        _set(fr, ILedgerReads.bodySlice.selector, M_ADD_WORD, 2, type(uint256).max);
        _inconsistent(7);
    }

    function test_m19_coverage_past_its_enum() public {
        _set(fi, IIndexReads.coverage.selector, M_ADD_WORD, 0, 1);
        _reply();
    }

    // ---- 3 FUTURE_ADMISSION --------------------------------------------------------------------------------

    function test_m09_scope_mutated_in_the_future() public {
        _set(fs, IBitmapStore.scopeHead.selector, M_FUTURE_ADMISSION, 2, 1);
        _inconsistent(2);
    }

    function test_m11_head_admitted_in_the_future() public {
        _set(fv, ILedgerViews.headsAt.selector, M_FUTURE_ADMISSION, 3, 1);
        _inconsistent(10);
    }

    function test_m13_coverage_frontier_in_the_future() public {
        _set(fi, IIndexReads.coverage.selector, M_FUTURE_ADMISSION, 2, 1);
        _inconsistent(8);
    }

    // ---- the new primitives: REVERT, EXTRA, STALE, EXHAUST, EMPTY ----------------------------------------

    function test_revert_of_the_index_is_a_read_fault() public {
        fl.setMode(ILedgerHot.index.selector, M_REVERT);
        _read();
    }

    function test_extra_trailing_bytes_are_tolerated() public {
        _set(fs, IBitmapStore.liveWords.selector, M_EXTRA, 0, 64);
        _set(fr, ILedgerReads.bodySlice.selector, M_EXTRA, 0, 96);
        IFilesPageReader.DirectoryPage memory pg = _page();
        assertEq(keccak256(abi.encode(pg)), keccak256(abi.encode(faithful)), "the faithful page");
    }

    function test_stale_heads_at_is_inconsistent() public {
        bytes32 pos = EfsFiles.folderPosition(rootDir, "docs");
        fv.capture(abi.encodeCall(ILedgerViews.headsAt, (address(fl), _lens(p), pos)));
        _file(address(this), docs, "later.txt", "later", true); // a later admission
        fv.setMode(ILedgerViews.headsAt.selector, M_STALE);
        _inconsistent(6);
    }

    function test_exhausting_record_header_is_a_read_fault() public {
        fr.setMode(ILedgerReads.recordHeader.selector, M_EXHAUST);
        _read();
    }

    function test_empty_bitmap_store_address_is_a_reply_fault() public {
        fi.setMode(IIndexReads.bitmapStore.selector, M_EMPTY);
        _reply();
    }

    function test_a_ledger_that_overstates_its_admissions_is_inconsistent() public {
        _set(fl, ILedgerHot.counts.selector, M_ADD_WORD, 0, 3);
        _inconsistent(8);
    }
}
