// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {console2} from "forge-std/Test.sol";
import {FilesPageHarness} from "../harness/doubles/FilesPageHarness.sol";
import {EfsFiles} from "../../src/lib/EfsFiles.sol";
import {Action} from "../../src/interfaces/Actions.sol";
import {Coverage, Status} from "../../src/interfaces/Results.sol";
import {IFilesPageReader} from "../../src/interfaces/Readers.sol";

/// @notice Design §12.3 row "large directory": `FilesPageReader.listDirectory` over a 1,000-entry filtered folder —
///         pages, calls, gas per page and returndata bytes recorded as a regression bound (the prototype needed
///         199 calls), cold versus warm. The folder holds 1,050 files (each with a HEAD on its root record), 50 of
///         them removed (masked: their live bits are clear), and 20 sub-folders; the listing asks for files only
///         (`kinds = 2`) with every field (name, HEAD header, kind), so 1,000 rows come back from 1,070 scope
///         entries. Setup runs with gas metering paused; the writes go through the real kernel, registry and
///         generation-1 index in publications of at most 64 actions (12 file creates each).
contract LargeDirectoryTest is FilesPageHarness {
    uint256 internal constant FILES = 1_050;
    uint256 internal constant REMOVED = 50; // every 21st file
    uint256 internal constant FOLDERS = 20;
    uint256 internal constant LIVE_FILES = FILES - REMOVED;
    bytes32 internal big;

    struct Run {
        uint256 pages;
        uint256 rows;
        uint256 maxGas;
        uint256 totalGas;
        uint256 maxBytes;
        uint256 totalBytes;
    }

    function setUp() public {
        vm.pauseGasMetering();
        _setUpFiles(keccak256("files-page/large"));
        big = _folder(rootDir, "big");
        Action[] memory a = new Action[](0);
        bytes[] memory b = new bytes[](0);
        for (uint256 i; i < FILES; ++i) {
            (Action[] memory x, bytes[] memory y,,) = EfsFiles.createFile(
                t, p, big, bytes32(i + 1), _name(i), bytes.concat("document ", _name(i)), true
            );
            (a, b) = EfsFiles.concat(a, b, x, y);
            if (a.length == 60 || i + 1 == FILES) {
                _exec(a, b);
                a = new Action[](0);
                b = new bytes[](0);
            }
        }
        for (uint256 i; i < FILES; i += 21) {
            (Action[] memory x, bytes[] memory y) = EfsFiles.remove(big, _name(i), 1);
            (a, b) = EfsFiles.concat(a, b, x, y);
        }
        _exec(a, b);
        a = new Action[](0);
        b = new bytes[](0);
        for (uint256 i; i < FOLDERS; ++i) {
            bytes memory n = bytes(string.concat("dir", vm.toString(i)));
            (Action[] memory x, bytes[] memory y,) =
                EfsFiles.createFolder(t, p, big, keccak256(n), n, true);
            (a, b) = EfsFiles.concat(a, b, x, y);
            if (a.length == 40) {
                _exec(a, b);
                a = new Action[](0);
                b = new bytes[](0);
            }
        }
        vm.resumeGasMetering();
    }

    function _name(uint256 i) internal pure returns (bytes memory) {
        bytes memory d = bytes(vm.toString(i + 10_000)); // fixed width: f10000 … f11049
        return bytes.concat("f", d);
    }

    function _cool() internal {
        vm.cool(r.k.proxy);
        vm.cool(address(r.k.implementation));
        vm.cool(address(r.registry));
        vm.cool(address(r.registryImpl));
        vm.cool(address(r.g.index));
        vm.cool(address(r.g.bitmap));
        vm.cool(address(views));
        vm.cool(address(reads));
        vm.cool(address(reader));
    }

    /// Drains the listing under `callGas` per call; checks every row against the expected sequence.
    function _drain(string memory label, uint256 callGas, uint32 limit, bool cold)
        internal
        returns (Run memory run)
    {
        bytes memory next;
        uint256 expect; // the next file index expected
        while (true) {
            if (cold) _cool();
            (IFilesPageReader.DirectoryPage memory pg, uint256 g) = _page(next, callGas, limit);
            expect = _check(pg, expect);
            _account(run, label, pg, g);
            next = pg.next;
            if (next.length == 0) {
                assertEq(pg.scanStatus, SCAN_EXHAUSTED);
                assertEq(
                    uint8(pg.listingCoverage),
                    uint8(run.pages == 1 ? Coverage.COMPLETE : Coverage.PARTIAL),
                    "the listing-coverage law"
                );
                assertEq(pg.rawTotal, FILES + FOLDERS);
                break;
            }
            assertLt(run.pages, 199, "the prototype's 199 calls");
        }
        assertEq(run.rows, LIVE_FILES);
        console2.log(string.concat(label, " pages (calls), rows"), run.pages, run.rows);
        console2.log("  max gas per page, total gas", run.maxGas, run.totalGas);
        console2.log("  max returndata bytes per page, total", run.maxBytes, run.totalBytes);
    }

    function _page(bytes memory next, uint256 callGas, uint32 limit)
        internal
        view
        returns (IFilesPageReader.DirectoryPage memory pg, uint256 g)
    {
        g = gasleft();
        pg = reader.listDirectory{gas: callGas}(
            big, _lens(p), _q(F_ALL, 2), _unbound(), next, limit, 1_500_000
        );
        g -= gasleft();
        assertEq(uint8(pg.q.status), uint8(Status.PRESENT));
    }

    function _check(IFilesPageReader.DirectoryPage memory pg, uint256 expect)
        internal
        pure
        returns (uint256)
    {
        for (uint256 j; j < pg.rows.length; ++j) {
            if (expect % 21 == 0) ++expect; // removed: masked, never listed
            _checkRow(pg.rows[j], expect);
            ++expect;
        }
        return expect;
    }

    function _checkRow(IFilesPageReader.Row memory row, uint256 i) internal pure {
        assertEq(keccak256(row.name), keccak256(_name(i)), "in order, no duplicate, no gap");
        assertEq(row.rowKind, ROW_ENTRY);
        assertEq(row.headRevision, 1);
        assertEq(row.headerWord0, row.target, "the root record's file word");
    }

    function _account(
        Run memory run,
        string memory label,
        IFilesPageReader.DirectoryPage memory pg,
        uint256 g
    ) internal pure {
        uint256 bytes_ = abi.encode(pg).length;
        ++run.pages;
        run.rows += pg.rows.length;
        run.totalGas += g;
        run.totalBytes += bytes_;
        if (g > run.maxGas) run.maxGas = g;
        if (bytes_ > run.maxBytes) run.maxBytes = bytes_;
        console2.log(
            string.concat(label, " page, rows, scanStatus"),
            run.pages,
            pg.rows.length,
            pg.scanStatus
        );
        console2.log("  gas, returndata bytes", g, bytes_);
    }

    function test_large_directory_warm_at_a_30M_call() public {
        Run memory run = _drain("warm 30M", 30_000_000, 0, false);
        assertLe(run.pages, 6, "regression bound: pages at a 30M eth_call");
    }

    function test_large_directory_cold_at_a_30M_call() public {
        Run memory run = _drain("cold 30M", 30_000_000, 0, true);
        assertLe(run.pages, 6, "regression bound: cold pages at a 30M eth_call");
    }

    function test_large_directory_warm_at_a_50M_call() public {
        Run memory run = _drain("warm 50M", 50_000_000, 0, false);
        assertLe(run.pages, 4, "regression bound: pages at the 50M default RPC cap");
    }

    function test_large_directory_in_pages_of_100_rows() public {
        Run memory run = _drain("limit 100", 30_000_000, 100, true);
        // ten full pages, then the LIMIT stop at the first sub-folder candidate leaves a terminal page that
        // scans the 20 filtered folders and returns no row
        assertEq(run.pages, 11);
        assertLe(run.maxBytes, 40_000, "regression bound: returndata of a 100-row page");
        assertLe(run.maxGas, 16_000_000, "regression bound: gas of a 100-row page");
    }
}
