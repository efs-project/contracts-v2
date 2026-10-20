// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FilesPageHarness} from "../harness/doubles/FilesPageHarness.sol";
import {FilesPageReader} from "../../src/readers/FilesPageReader.sol";
import {EfsFiles} from "../../src/lib/EfsFiles.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {Action, Purpose} from "../../src/interfaces/Actions.sol";
import {BasisCommit, Coverage, Qualified, Status} from "../../src/interfaces/Results.sol";
import {IFilesPageReader} from "../../src/interfaces/Readers.sol";
import {ILedgerReads} from "../../src/interfaces/ILedgerReads.sol";
import {RecordHeader} from "../../src/interfaces/Views.sol";

/// @notice `FilesPageReader/1` on the Files fixture history (design §11, §5.13, §12.3 "read verified contents"):
///         root, a folder, files, an edit, a rename + move, a removal, a restore and a removal that stays; one
///         page lists exactly the live entries with names and HEAD records, and a file read after the page is one
///         `record()` call; masks from a higher principal; INVALID heads; `limit` and `gasReserve` paging without
///         duplicates or gaps; the listing-coverage law and the §5.13 flags; continuation binding; `lookupName`.
contract FilesPageReaderTest is FilesPageHarness {
    bytes32 internal docs;
    bytes32 internal readme;
    bytes32 internal readmeRoot;
    bytes32 internal readmeChild;
    bytes32 internal fileA;
    bytes32 internal aRoot;
    bytes32 internal fileB;
    bytes32 internal bRoot;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    bytes32 internal pa;
    bytes32 internal pb;

    function setUp() public {
        _setUpFiles(keccak256("files-page/realm"));
        pa = Keys.principal(alice);
        pb = Keys.principal(bob);
        docs = _folder(rootDir, "docs");
        (readme, readmeRoot) = _file(address(this), docs, "readme.txt", "Meeting at 10:00.\n", true);
        (fileA, aRoot) = _file(address(this), rootDir, "a.txt", "alpha", true);
        (fileB, bRoot) = _file(address(this), rootDir, "b.txt", "beta", true);
        _file(address(this), rootDir, "c.txt", "gamma", true);
        Action[] memory a;
        bytes[] memory b;
        (a, b, readmeChild) = EfsFiles.edit(t, readme, readmeRoot, "Meeting at 11:00.\n", 1);
        _exec(a, b);
        (a, b) = EfsFiles.move(t, readme, docs, "readme.txt", 1, rootDir, "notes.txt", 0, true);
        _exec(a, b);
        (a, b) = EfsFiles.remove(rootDir, "b.txt", 1);
        _exec(a, b);
        (a, b) = EfsFiles.restore(rootDir, "b.txt", fileB, 2);
        _exec(a, b);
        (a, b) = EfsFiles.remove(rootDir, "c.txt", 1);
        _exec(a, b);
    }

    function _assertRow(
        IFilesPageReader.Row memory row,
        string memory name,
        bytes32 target,
        uint8 targetKind,
        bytes32 headRecord,
        uint64 headRevision,
        bytes32 word0
    ) internal view {
        assertEq(row.name, bytes(name), "name");
        assertEq(row.position, EfsFiles.folderPosition(rootDir, bytes(name)), "position");
        assertEq(row.target, target, string.concat(name, " target"));
        assertEq(row.targetKind, targetKind, string.concat(name, " target kind"));
        assertEq(row.headRecord, headRecord, string.concat(name, " head record"));
        assertEq(row.headRevision, headRevision, string.concat(name, " head revision"));
        assertEq(row.headerWord0, word0, string.concat(name, " header word 0"));
        assertEq(row.rowKind, ROW_ENTRY, string.concat(name, " row kind"));
        assertTrue(row.admission != 0, "admission");
    }

    // ---- one page lists exactly the live entries ------------------------------------------------------------

    function test_page_lists_exactly_the_live_entries_with_names_and_heads() public {
        // the moved file left docs: its entry is dead there and docs lists empty, COMPLETE
        IFilesPageReader.DirectoryPage memory d = _list(docs, _lens(p), F_ALL);
        assertEq(d.rows.length, 0);
        assertEq(d.rawTotal, 1);
        assertEq(uint8(d.listingCoverage), uint8(Coverage.COMPLETE));
        // 1 call per directory page
        vm.expectCall(address(reader), abi.encodeWithSelector(reader.listDirectory.selector), 1);
        IFilesPageReader.DirectoryPage memory page = _list(rootDir, _lens(p), F_ALL);
        assertEq(uint8(page.q.status), uint8(Status.PRESENT));
        assertEq(page.rows.length, 4, "docs, a.txt, b.txt (restored), notes.txt; c.txt removed");
        _assertRow(page.rows[0], "docs", docs, 1, 0, 0, 0);
        _assertRow(page.rows[1], "a.txt", fileA, 2, aRoot, 1, fileA);
        _assertRow(page.rows[2], "b.txt", fileB, 2, bRoot, 1, fileB);
        _assertRow(page.rows[3], "notes.txt", readme, 2, readmeChild, 2, readmeRoot);
        assertEq(uint8(page.listingCoverage), uint8(Coverage.COMPLETE));
        // 1 call per file read after a page: the HEAD record id is in the row
        vm.expectCall(address(reads), abi.encodeWithSelector(ILedgerReads.record.selector), 1);
        (Status st, RecordHeader memory h, bytes memory body,) =
            reads.record(address(r.ledger), page.rows[3].headRecord);
        assertEq(uint8(st), uint8(Status.PRESENT));
        assertEq(h.typeId, typeIds[T_CHILD]);
        assertEq(h.word0, page.rows[3].headerWord0);
        assertEq(body, EfsFiles.childBody(readmeRoot, readme, "Meeting at 11:00.\n"));
    }

    function test_rows_carry_only_the_requested_fields() public view {
        IFilesPageReader.DirectoryPage memory page = _list(rootDir, _lens(p), 0);
        assertEq(page.rows.length, 4);
        for (uint256 i; i < 4; ++i) {
            IFilesPageReader.Row memory row = page.rows[i];
            assertEq(row.name.length, 0);
            assertEq(row.targetKind, 0);
            assertEq(row.headRecord, 0);
            assertEq(row.headRevision, 0);
            assertEq(row.headerWord0, 0);
            assertTrue(row.position != 0 && row.target != 0 && row.admission != 0);
            assertEq(row.rowKind, ROW_ENTRY);
        }
        page = _list(rootDir, _lens(p), F_NAME);
        assertEq(page.rows[1].name, "a.txt");
        assertEq(page.rows[1].headRecord, 0, "no header without F_HEADER");
    }

    function test_kinds_filter() public view {
        IFilesPageReader.DirectoryPage memory page =
            reader.listDirectory(rootDir, _lens(p), _q(F_NAME, 1), _unbound(), "", 0, 0);
        assertEq(page.rows.length, 1);
        assertEq(page.rows[0].name, "docs");
        page = reader.listDirectory(rootDir, _lens(p), _q(F_NAME, 2), _unbound(), "", 0, 0);
        assertEq(page.rows.length, 3);
        assertEq(page.scanned, 5, "filtered entries are scanned");
        assertEq(uint8(page.listingCoverage), uint8(Coverage.COMPLETE));
    }

    // ---- masks from a higher principal ---------------------------------------------------------------------

    function test_a_higher_principal_bind_is_listed_once_as_its_own() public {
        (bytes32 aliceFile, bytes32 aliceRoot) = _file(alice, rootDir, "a.txt", "alice's a", false);
        IFilesPageReader.DirectoryPage memory page = _list(rootDir, _lens(pa, p), F_ALL);
        assertEq(page.rows.length, 4, "a.txt once");
        assertEq(page.rows[0].name, "a.txt");
        assertEq(page.rows[0].target, aliceFile, "the higher principal's target");
        assertEq(page.rows[0].headRecord, aliceRoot);
        for (uint256 i = 1; i < 4; ++i) {
            assertTrue(page.rows[i].target != fileA, "not listed as the lower's");
        }
        assertEq(page.rawTotal, 6);
        // the other order: the lower principal now wins, alice's entry is skipped
        page = _list(rootDir, _lens(p, pa), F_NAME);
        assertEq(page.rows.length, 4);
        assertEq(page.rows[1].target, fileA);
    }

    function test_a_higher_principal_mask_is_reported_masked_not_listed_as_the_lower() public {
        _file(alice, rootDir, "a.txt", "alice's a", false);
        _file(bob, rootDir, "a.txt", "bob's a", false);
        (Action[] memory a, bytes[] memory b) = EfsFiles.remove(rootDir, "a.txt", 1);
        _execAs(alice, a, b);
        IFilesPageReader.DirectoryPage memory page = _list(rootDir, _lens(pa, pb, p), F_ALL);
        // docs, b.txt, notes.txt and one whiteout (reported by bob, the first lower principal BOUND there)
        assertEq(page.rows.length, 4);
        IFilesPageReader.Row memory w = page.rows[0];
        assertEq(w.rowKind, ROW_WHITEOUT);
        assertEq(w.name, "a.txt");
        assertEq(w.target, 0);
        assertEq(w.position, EfsFiles.folderPosition(rootDir, "a.txt"));
        for (uint256 i = 1; i < 4; ++i) {
            assertEq(page.rows[i].rowKind, ROW_ENTRY);
            assertTrue(keccak256(page.rows[i].name) != keccak256("a.txt"));
        }
        // a files-only filter drops the whiteout; lookupName reports it MASKED
        page = reader.listDirectory(rootDir, _lens(pa, p), _q(F_NAME, 2), _unbound(), "", 0, 0);
        assertEq(page.rows.length, 2);
        (Qualified memory q, IFilesPageReader.Row memory row) =
            reader.lookupName(rootDir, keccak256("a.txt"), _lens(pa, p), _unbound());
        assertEq(uint8(q.status), uint8(Status.MASKED));
        assertEq(row.rowKind, ROW_WHITEOUT);
        // RELEASE falls through: the lower principal's entry is listed again
        (a, b) = EfsFiles.releaseEntry(rootDir, "a.txt", 2);
        _execAs(alice, a, b);
        (q, row) = reader.lookupName(rootDir, keccak256("a.txt"), _lens(pa, p), _unbound());
        assertEq(uint8(q.status), uint8(Status.PRESENT));
        assertEq(row.target, fileA);
        assertEq(row.headRecord, aRoot);
    }

    // ---- INVALID heads (the reader-side §12.1 HEAD law) -------------------------------------------------------

    /// CREATE, PUBLISH name, BIND(HEAD → `headTarget`, or the file subject itself when 0) unless `!withHead`,
    /// BIND(FOLDER, root, name → file): the gen-1 validator judges FOLDER binds only, so any HEAD target lands.
    function _placeWithHead(string memory name, bytes32 headTarget, bool withHead)
        internal
        returns (bytes32 file)
    {
        bytes32 salt = keccak256(bytes(name));
        file = EfsFiles.subjectId(p, salt);
        uint256 n = withHead ? 4 : 3;
        Action[] memory a = new Action[](n);
        bytes[] memory b = new bytes[](n);
        a[0] = EfsFiles.create(salt);
        b[1] = bytes(name);
        a[1] = EfsFiles.publish(t.name, b[1]);
        if (withHead) {
            a[2] = EfsFiles.bind(Purpose.HEAD, file, 0, headTarget == 0 ? file : headTarget, 0);
        }
        a[n - 1] = EfsFiles.bind(Purpose.FOLDER, rootDir, keccak256(bytes(name)), file, 0);
        _exec(a, b);
    }

    function test_invalid_heads_are_reported_invalid_never_dropped() public {
        bytes32 nameRec = Keys.recordFromHash(t.name, keccak256("bad.txt"));
        bytes32 bad = _placeWithHead("bad.txt", nameRec, true); // a files-name/2 record as the HEAD target
        bytes32 wrong = _placeWithHead("wrong.txt", aRoot, true); // another file's root record
        bytes32 self = _placeWithHead("self.txt", 0, true); // a subject (itself) as the HEAD target
        bytes32 none = _placeWithHead("none.txt", 0, false); // no HEAD bound
        IFilesPageReader.DirectoryPage memory page = _list(rootDir, _lens(p), F_ALL);
        assertEq(page.rows.length, 8);
        assertEq(page.rows[4].target, bad);
        assertEq(page.rows[4].rowKind, ROW_INVALID, "a name record is not a revision");
        assertEq(page.rows[4].headRecord, nameRec);
        assertEq(page.rows[5].target, wrong);
        assertEq(page.rows[5].rowKind, ROW_INVALID, "a root record of another file");
        assertEq(page.rows[5].headerWord0, fileA);
        assertEq(page.rows[6].target, self);
        assertEq(page.rows[6].rowKind, ROW_INVALID, "a subject HEAD target");
        assertEq(page.rows[7].target, none);
        assertEq(page.rows[7].rowKind, ROW_ENTRY, "no HEAD is not invalid");
        assertEq(page.rows[7].headRecord, 0);
        assertEq(page.rows[7].headRevision, 0);
        // the kinds filter never hides an INVALID file row behind a files filter
        page = reader.listDirectory(rootDir, _lens(p), _q(F_HEADER, 2), _unbound(), "", 0, 0);
        assertEq(page.rows.length, 7);
        (Qualified memory q, IFilesPageReader.Row memory row) =
            reader.lookupName(rootDir, keccak256("bad.txt"), _lens(p), _unbound());
        assertEq(uint8(q.status), uint8(Status.INVALID));
        assertEq(row.rowKind, ROW_INVALID);
    }

    // ---- paging: limit, gasReserve, continuation, flags ---------------------------------------------------

    function _assertSameRows(
        IFilesPageReader.DirectoryPage[] memory pages,
        uint256 n,
        IFilesPageReader.Row[] memory all
    ) internal pure {
        uint256 k;
        for (uint256 i; i < n; ++i) {
            for (uint256 j; j < pages[i].rows.length; ++j) {
                assertLt(k, all.length, "no extra rows");
                assertEq(pages[i].rows[j].position, all[k].position, "no duplicate, no gap");
                assertEq(pages[i].rows[j].name, all[k].name);
                ++k;
            }
        }
        assertEq(k, all.length, "every row");
    }

    function test_limit_pages_resume_without_duplicates_or_gaps_and_flags() public view {
        IFilesPageReader.DirectoryPage memory full = _list(rootDir, _lens(p), F_ALL);
        assertTrue(full.startsAtOrigin && full.completeFromOrigin);
        assertEq(full.scanStatus, SCAN_EXHAUSTED);
        assertEq(full.next.length, 0);
        assertEq(full.selectedSoFar, 4);
        assertEq(full.scanned, full.rawTotal);
        (uint64 admissions,,,) = r.hot.counts();
        assertEq(full.observedCurrent, admissions);
        assertEq(full.frontier, admissions);
        (IFilesPageReader.DirectoryPage[] memory pages, uint256 n) =
            _drain(rootDir, _lens(p), _q(F_ALL, 0), 1, 30_000_000, 0, 10);
        assertEq(n, 4);
        _assertSameRows(pages, n, full.rows);
        uint256 scanned;
        for (uint256 i; i < n; ++i) {
            IFilesPageReader.DirectoryPage memory pg = pages[i];
            scanned += pg.scanned;
            assertEq(pg.inventoryPin, full.inventoryPin, "one inventory");
            assertEq(pg.startsAtOrigin, i == 0);
            assertFalse(pg.completeFromOrigin);
            assertEq(uint8(pg.listingCoverage), uint8(Coverage.PARTIAL), "never COMPLETE in pieces");
            assertEq(pg.selectedSoFar, i + 1);
            assertEq(pg.scanStatus, i + 1 == n ? SCAN_EXHAUSTED : SCAN_LIMIT);
            assertEq(uint8(pg.q.status), uint8(Status.PRESENT));
        }
        assertEq(scanned, full.rawTotal, "the pages cover the scope list once");
        assertEq(pages[n - 1].next.length, 0);
    }

    function test_gas_reserve_stops_early_and_the_continuation_resumes() public {
        bytes32 dir = _folder(rootDir, "many");
        for (uint256 i; i < 6; ++i) {
            _file(address(this), dir, string.concat("f", vm.toString(i)), "x", true);
        }
        IFilesPageReader.DirectoryPage memory full = _list(dir, _lens(p), F_ALL);
        assertEq(full.rows.length, 6);
        // measure one row, then reserve all but about two rows of a 10M call
        uint256 g0 = gasleft();
        reader.listDirectory(dir, _lens(p), _q(F_ALL, 0), _unbound(), "", 1, 0);
        uint256 one = g0 - gasleft();
        g0 = gasleft();
        reader.listDirectory(dir, _lens(p), _q(F_ALL, 0), _unbound(), "", 2, 0);
        uint256 perRow = g0 - gasleft() - one;
        uint256 callGas = 10_000_000;
        uint256 reserve = callGas - one - perRow;
        (IFilesPageReader.DirectoryPage[] memory pages, uint256 n) =
            _drain(dir, _lens(p), _q(F_ALL, 0), 0, callGas, reserve, 12);
        assertGt(n, 1, "stopped early");
        _assertSameRows(pages, n, full.rows);
        for (uint256 i; i < n; ++i) {
            assertGt(pages[i].rows.length, 0, "progress on every page");
            assertEq(pages[i].scanStatus, i + 1 == n ? SCAN_EXHAUSTED : SCAN_GAS);
            assertFalse(pages[i].completeFromOrigin);
            assertEq(uint8(pages[i].listingCoverage), uint8(Coverage.PARTIAL));
        }
        assertEq(pages[0].next.length, 9 * 32);
        emit log_named_uint("gas-reserve pages over 6 rows", n);
    }

    function test_continuation_binding() public {
        IFilesPageReader.DirectoryPage memory first =
            reader.listDirectory(rootDir, _lens(p), _q(F_NAME, 0), _unbound(), "", 2, 0);
        bytes memory next = first.next;
        // another query: INVALID; a malformed continuation: INVALID
        IFilesPageReader.DirectoryPage memory pg =
            reader.listDirectory(rootDir, _lens(p), _q(F_ALL, 0), _unbound(), next, 2, 0);
        assertEq(uint8(pg.q.status), uint8(Status.INVALID));
        assertEq(pg.rows.length, 0);
        assertEq(uint8(pg.listingCoverage), uint8(Coverage.UNKNOWN));
        pg = reader.listDirectory(rootDir, _lens(p), _q(F_NAME, 0), _unbound(), hex"01", 2, 0);
        assertEq(uint8(pg.q.status), uint8(Status.INVALID));
        // a HEAD edit outside the selected scopes leaves the continuation valid
        (Action[] memory a, bytes[] memory b,) = EfsFiles.edit(t, fileA, aRoot, "alpha 2", 1);
        _exec(a, b);
        pg = reader.listDirectory(rootDir, _lens(p), _q(F_NAME, 0), _unbound(), next, 2, 0);
        assertEq(uint8(pg.q.status), uint8(Status.PRESENT));
        assertEq(pg.rows[0].name, "b.txt");
        assertLt(first.observedCurrent, pg.observedCurrent);
        // a mutation of a selected scope after the origin (a rename): BASIS_STALE
        (a, b) = EfsFiles.move(t, fileA, rootDir, "a.txt", 1, rootDir, "a2.txt", 0, true);
        _exec(a, b);
        pg = reader.listDirectory(rootDir, _lens(p), _q(F_NAME, 0), _unbound(), next, 2, 0);
        assertEq(uint8(pg.q.status), uint8(Status.BASIS_STALE));
        assertEq(pg.rows.length, 0);
        assertEq(pg.scanStatus, 0, "no scan ran");
    }

    function test_expected_basis_and_refusals() public view {
        BasisCommit memory b = reads.basis(address(r.ledger));
        IFilesPageReader.DirectoryPage memory pg =
            reader.listDirectory(rootDir, _lens(p), _q(F_NAME, 0), b, "", 0, 0);
        assertEq(uint8(pg.q.status), uint8(Status.PRESENT));
        assertEq(keccak256(abi.encode(pg.q.observed)), keccak256(abi.encode(b)), "basis echoed");
        b.indexGeneration += 1;
        pg = reader.listDirectory(rootDir, _lens(p), _q(F_NAME, 0), b, "", 0, 0);
        assertEq(uint8(pg.q.status), uint8(Status.BASIS_STALE));
        // tags are S3
        IFilesPageReader.Query memory q = _q(8, 0);
        pg = reader.listDirectory(rootDir, _lens(p), q, _unbound(), "", 0, 0);
        assertEq(uint8(pg.q.status), uint8(Status.UNSUPPORTED));
        q = _q(0, 0);
        q.tagConcept = keccak256("tag");
        pg = reader.listDirectory(rootDir, _lens(p), q, _unbound(), "", 0, 0);
        assertEq(uint8(pg.q.status), uint8(Status.UNSUPPORTED));
        // the lens bound
        pg = reader.listDirectory(rootDir, new bytes32[](0), _q(0, 0), _unbound(), "", 0, 0);
        assertEq(uint8(pg.q.status), uint8(Status.INVALID));
        pg = reader.listDirectory(rootDir, new bytes32[](65), _q(0, 0), _unbound(), "", 0, 0);
        assertEq(uint8(pg.q.status), uint8(Status.LIMIT_EXCEEDED));
        // 64 principals is one headsAt per candidate
        bytes32[] memory lens = new bytes32[](64);
        lens[63] = p;
        pg = reader.listDirectory(rootDir, lens, _q(F_ALL, 0), _unbound(), "", 0, 0);
        assertEq(pg.rows.length, 4);
        assertEq(pg.rows[3].headRecord, readmeChild);
    }

    function test_lookup_name_and_reader_identity() public view {
        (Qualified memory q, IFilesPageReader.Row memory row) =
            reader.lookupName(rootDir, keccak256("notes.txt"), _lens(p), _unbound());
        assertEq(uint8(q.status), uint8(Status.PRESENT));
        assertEq(row.name, "notes.txt");
        assertEq(row.headRecord, readmeChild);
        assertEq(row.targetKind, 2);
        (q, row) = reader.lookupName(rootDir, keccak256("c.txt"), _lens(p), _unbound());
        assertEq(uint8(q.status), uint8(Status.MASKED), "removed");
        (q, row) = reader.lookupName(rootDir, keccak256("zzz"), _lens(p), _unbound());
        assertEq(uint8(q.status), uint8(Status.ABSENT_PROVEN));
        assertEq(row.position, EfsFiles.folderPosition(rootDir, "zzz"));
        assertEq(reader.ledger(), address(r.ledger));
        assertEq(reader.layoutId(), r.hot.layoutId());
        (bytes32[] memory cb, bytes32[] memory ph) = reader.supportedProfiles();
        assertEq(cb[0], r.g.index.CALLBACK_PROFILE());
        assertEq(ph[0], r.g.index.PHYSICAL_PROFILE());
    }

    // ---- EfsFiles ids agree with Keys ---------------------------------------------------------------------

    function test_efs_files_ids_match_keys() public view {
        bytes32 salt = keccak256("s");
        assertEq(EfsFiles.subjectId(p, salt), Keys.subject(p, salt));
        assertEq(EfsFiles.recordId(t.root, "body"), Keys.record(t.root, "body"));
        assertEq(
            EfsFiles.nameRecord(t.name, keccak256("n")), Keys.recordFromHash(t.name, keccak256("n"))
        );
        assertEq(
            EfsFiles.folderPosition(rootDir, "n"),
            Keys.position(Purpose.FOLDER, rootDir, keccak256("n"))
        );
        assertEq(EfsFiles.headPosition(fileA), Keys.position(Purpose.HEAD, fileA, 0));
        assertEq(EfsFiles.folderScope(p, rootDir), Keys.scope(p, Purpose.FOLDER, rootDir));
        assertEq(EfsFiles.directoryRecord(t.directory, Keys.subject(p, keccak256("docs"))), docs);
        assertEq(EfsFiles.bytesBody("x"), bytes.concat(sha256("x"), "x"));
        EfsFiles.Content memory c;
        assertEq(EfsFiles.contentBody(c).length, 352);
        assertEq(EfsFiles.externalBody(0, 2, 1, 0, "ar://x").length, 7 * 32 + 6);
    }
}
