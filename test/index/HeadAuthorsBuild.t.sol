// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {HeadAuthorsBase} from "./HeadAuthorsBase.sol";
import {IGeneration1} from "../harness/IndexDeploy.sol";
import {IHeadAuthorsGeneration, ListIndexDeployer} from "../harness/HeadAuthors.sol";
import {PostingStore} from "../../src/index/PostingStore.sol";
import {Layout} from "../../src/core/layout/Layout.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {EfsFiles} from "../../src/lib/EfsFiles.sol";
import {FamilyId, PostingKey, Purpose, TypeId} from "../../src/interfaces/Actions.sol";
import {Coverage} from "../../src/interfaces/Results.sol";
import {Readiness} from "../../src/interfaces/Index.sol";
import {IPostingStore} from "../../src/interfaces/IPostingStore.sol";
import {IBitmapStore} from "../../src/interfaces/IBitmapStore.sol";
import {E_BUILD, E_INDEX_NOT_READY} from "../../src/interfaces/Errors.sol";

/// @notice Docs INDEX-BUILD step 3b, case (b) of §2.2: a generation that adds a NEW list (`head-authors`, provisional
///         kind 22; an example in a test harness, not product) in a third store and builds it from history, carrying the
///         two genesis stores. Over the mixed history of `TopicListsHistory` plus a HEAD history that moves every
///         counter of the new list:
///
///         1. built equals live (§8 test 1): Realm B runs generation 1, then builds and activates the example
///            generation; Realm L runs the example generation from genesis; every recorded key of every family in the
///            three stores is equal, before and after more traffic;
///         2. the §2.2 trace, live and built;
///         3. interrupted builds (fuzzed budgets, one publication per call) equal one build;
///         4. racing and switching on: coverage per family while building, refusal of an unfinished build (8), build and
///            activate in one transaction, the first live HEAD statement attaching the third store;
///         5. refusals with the third store: another contract's store (12 / `E_BUILD(7)`, on an empty Realm and with
///            admissions) and an attached one (13 / `E_BUILD(2)`).
contract HeadAuthorsBuildTest is HeadAuthorsBase {
    function _history() internal {
        _mixedHistory();
        _headHistory();
        _genesisKeys();
    }

    // =============================================================================================
    // 1. Built equals live, every family and counter (docs INDEX-BUILD §8 test 1)
    // =============================================================================================

    function test_built_equals_live_every_family() public {
        // Realm B: generation 1 live, then the example generation built and activated
        _history();
        _assertCountersMoved(IPostingStore(address(r.g.posting)));
        (ListIndexDeployer d, IHeadAuthorsGeneration ix) =
            _headGen(address(r.g.posting), address(r.g.bitmap), address(0));
        (IPostingStore bp, IBitmapStore bb, IPostingStore bt) = _three(d);
        assertEq(address(bp), address(r.g.posting), "posting carried");
        assertEq(address(bb), address(r.g.bitmap), "bitmap carried");
        (uint64 admissions, uint64 publications) = _counts();
        uint256 g0 = gasleft();
        uint256 calls = _buildAll(ix);
        uint256 buildGas = g0 - gasleft();
        assertTrue(ix.replayReadiness().ready);
        this.activateNow(address(ix));
        assertEq(r.hot.index(), address(ix));
        _assertHeadCountersMoved(bt);
        bytes32[] memory b1 = _capture3(bp, bb, bt);
        (, uint256 nonEmpty, uint256 entries) = _capture(bp, bb);
        _traffic();
        bytes32[] memory b2 = _capture3(bp, bb, bt);
        uint256 headLists = headKeys.length;
        // a preview of the walk's gas (warm within this test's one transaction; step 4 measures cold)
        emit log_named_uint("build: publications", publications);
        emit log_named_uint("build: admissions", admissions);
        emit log_named_uint("build: calls (budget 64)", calls);
        emit log_named_uint("build: gas, all calls", buildGas);
        emit log_named_uint("build: gas per publication", buildGas / publications);
        emit log_named_uint("build: gas per leaf", buildGas / admissions);

        // Realm L: the example generation live from genesis, the same history and traffic
        _realmL();
        _history();
        IPostingStore lt = IPostingStore(genesisThird);
        bytes32[] memory l1 =
            _capture3(IPostingStore(address(r.g.posting)), IBitmapStore(address(r.g.bitmap)), lt);
        _assertHeadCountersMoved(lt);
        _assertSame3(b1, l1, "built on B vs live on L");
        _traffic();
        assertEq(headKeys.length, headLists, "the same head-authors lists recorded");
        bytes32[] memory l2 =
            _capture3(IPostingStore(address(r.g.posting)), IBitmapStore(address(r.g.bitmap)), lt);
        _assertSame3(b2, l2, "after more traffic, B vs L");
        assertGt(nonEmpty, 80, "many non-empty lists compared");
        assertGt(entries, 150, "many entries compared");
        // the traffic moved the new list again: alice's first mask on f1, carol's new file
        (uint64 c, uint64 l,) = _headOf(lt, f1);
        assertEq(abi.encode(c, l), abi.encode(uint64(4), uint64(2)), "f1 after the traffic");
    }

    // =============================================================================================
    // 2. The trace of docs INDEX-BUILD §2.2, live and built
    // =============================================================================================

    /// Alice creates notes.md, edits it, Bob saves his own version, Alice releases her head, Alice restores it. End
    /// state, both ways: count 2, live 2, last = Bob's first statement, entries [Alice's, Bob's].
    function _trace(IPostingStore third) internal returns (bytes32 file) {
        bytes32 home = bytes32(uint256(uint160(alice)));
        bytes32 root;
        (file, root) = _newFile(alice, home, "notes.md");
        uint64 a = _admission(alice, Purpose.HEAD, file, 0);
        _assertTrace(third, file, 1, 1, a, "alice creates");
        bytes32 child = _editFile(alice, file, root, "notes v2");
        _assertTrace(third, file, 1, 1, a, "alice edits: a re-bind, nothing");
        _editFile(bob, file, child, "bob's notes");
        uint64 b = _admission(bob, Purpose.HEAD, file, 0);
        _assertTrace(third, file, 2, 2, b, "bob saves his version");
        _head1(alice, EfsFiles.release(Purpose.HEAD, file, 0, _hrev(alice, file)));
        _assertTrace(third, file, 2, 1, b, "alice releases");
        _head1(alice, EfsFiles.bind(Purpose.HEAD, file, 0, child, _hrev(alice, file)));
        _assertTrace(third, file, 2, 2, b, "alice restores");
        if (address(third) != address(0)) {
            assertEq(
                abi.encode(_entriesOf(third, _headKey(file))),
                abi.encode(_list2(a, b)),
                "entries [alice, bob]"
            );
        }
    }

    function _assertTrace(
        IPostingStore third,
        bytes32 file,
        uint64 count,
        uint64 live,
        uint64 last,
        string memory what
    ) internal view {
        if (address(third) == address(0)) return; // built: checked at the end
        (uint64 c, uint64 l, uint64 t) = _headOf(third, file);
        assertEq(abi.encode(c, l, t), abi.encode(count, live, last), what);
    }

    function test_head_authors_trace() public {
        uint256 snap = vm.snapshotState();
        // live: the example generation is the live index before the trace
        (ListIndexDeployer d, IHeadAuthorsGeneration ix) =
            _headGen(address(r.g.posting), address(r.g.bitmap), address(0));
        _buildAll(ix);
        this.activateNow(address(ix));
        (,, IPostingStore live) = _three(d);
        bytes32 file = _trace(live);
        bytes32 liveList = _list(live, _headKey(file));
        vm.revertToState(snap);
        // built: the trace under generation 1, then the build
        bytes32 again = _trace(IPostingStore(address(0)));
        assertEq(again, file, "the same file");
        (d, ix) = _headGen(address(r.g.posting), address(r.g.bitmap), address(0));
        _buildAll(ix);
        (,, IPostingStore built) = _three(d);
        (uint64 c, uint64 l, uint64 t) = _headOf(built, file);
        assertEq(
            abi.encode(c, l, t),
            abi.encode(uint64(2), uint64(2), _admission(bob, Purpose.HEAD, file, 0)),
            "built: count 2, live 2, last = bob's"
        );
        assertEq(_list(built, _headKey(file)), liveList, "built equals live");
        // the reads contract routes the list read to the third store
        (Coverage cov, uint64 rc, uint64 rl,,) = ix.postingHeadOf(
            FamilyId.wrap(F_HEAD_AUTHORS), TypeId.wrap(0), 0, Keys.position(Purpose.HEAD, file, 0)
        );
        assertEq(uint8(cov), uint8(Coverage.COMPLETE));
        assertEq(
            abi.encode(rc, rl), abi.encode(uint64(2), uint64(2)), "read through the generation"
        );
        (, uint64[] memory e,) = ix.postingSliceOf(
            FamilyId.wrap(F_HEAD_AUTHORS),
            TypeId.wrap(0),
            0,
            Keys.position(Purpose.HEAD, file, 0),
            0,
            10
        );
        assertEq(abi.encode(e), abi.encode(_entriesOf(built, _headKey(file))));
    }

    // =============================================================================================
    // 3. Interrupted and resumed (docs INDEX-BUILD §8 test 3)
    // =============================================================================================

    function _leaves(uint64 n) internal view returns (uint8 leaves) {
        (,,,, leaves,,) = Layout.unpackEvidenceCellWord0(
            r.hot.extsload(bytes32(Layout.publicationsEvidenceSlot(n)))
        );
    }

    function _sum(uint64 from, uint64 to) internal view returns (uint64 s) {
        for (uint64 n = from; n <= to; ++n) {
            s += _leaves(n);
        }
    }

    /// cfg 0: both genesis stores carried, the third fresh; 1: posting fresh too; 2: every store fresh.
    function _cfg(uint8 cfg) internal returns (ListIndexDeployer, IHeadAuthorsGeneration) {
        return _headGen(
            cfg == 0 ? address(r.g.posting) : address(0),
            cfg == 2 ? address(0) : address(r.g.bitmap),
            address(0)
        );
    }

    /// forge-config: default.fuzz.runs = 6
    /// forge-config: ci.fuzz.runs = 12
    function testFuzz_interrupted_build_equals_one_build(uint256 seed) public {
        _history();
        (uint64 admissions, uint64 publications) = _counts();
        uint8 cfg = uint8(seed % 3);
        (ListIndexDeployer d1, IHeadAuthorsGeneration one) = _cfg(cfg);
        assertEq(one.build(bytes32(0), type(uint16).max), admissions, "one call builds it all");
        (ListIndexDeployer d2, IHeadAuthorsGeneration cut) = _cfg(cfg);
        uint256 calls;
        while (true) {
            (uint64 processed, uint64 lastPublication,) = cut.progress();
            if (lastPublication == publications) break;
            uint8 leaves = _leaves(lastPublication + 1);
            seed = uint256(keccak256(abi.encode(seed)));
            uint256 mode = seed % 5;
            uint16 budget = mode == 0
                ? 64
                : mode == 1
                    ? leaves
                    : mode == 2 ? uint16(leaves - 1) : uint16(1 + (seed >> 8) % 200);
            if (budget < leaves) {
                vm.expectRevert(abi.encodeWithSelector(E_BUILD.selector, uint8(6)));
                cut.build(bytes32(0), budget);
                (uint64 p2, uint64 l2,) = cut.progress();
                assertEq(abi.encode(p2, l2), abi.encode(processed, lastPublication), "unchanged");
                continue;
            }
            uint64 through = cut.build(bytes32(0), budget);
            ++calls;
            (, uint64 l3,) = cut.progress();
            assertGt(l3, lastPublication, "at least one publication");
            if (mode == 1) assertEq(l3, lastPublication + 1, "exactly one publication");
            assertEq(through, processed + _sum(lastPublication + 1, l3));
        }
        (IPostingStore p1, IBitmapStore b1, IPostingStore t1) = _three(d1);
        (IPostingStore p2s, IBitmapStore b2s, IPostingStore t2) = _three(d2);
        _assertSame3(_capture3(p1, b1, t1), _capture3(p2s, b2s, t2), "interrupted vs one call");
        _assertSame3(
            _capture3(IPostingStore(address(r.g.posting)), IBitmapStore(address(r.g.bitmap)), t1),
            _capture3(p2s, b2s, t2),
            "interrupted vs live (genesis stores) and one call (third)"
        );
        assertTrue(cut.replayReadiness().ready);
        _assertHeadCountersMoved(t2);
        emit log_named_uint("calls", calls);
    }

    /// One publication per call, every call: the same stores.
    function test_one_publication_per_call() public {
        _history();
        (, uint64 publications) = _counts();
        (ListIndexDeployer d1, IHeadAuthorsGeneration one) = _cfg(0);
        _buildAll(one);
        (ListIndexDeployer d2, IHeadAuthorsGeneration cut) = _cfg(0);
        for (uint64 n = 1; n <= publications; ++n) {
            cut.build(bytes32(0), _leaves(n));
            (, uint64 l,) = cut.progress();
            assertEq(l, n);
        }
        (,, IPostingStore t1) = _three(d1);
        (,, IPostingStore t2) = _three(d2);
        _assertSame3(
            _capture3(IPostingStore(address(r.g.posting)), IBitmapStore(address(r.g.bitmap)), t1),
            _capture3(IPostingStore(address(r.g.posting)), IBitmapStore(address(r.g.bitmap)), t2),
            "one publication per call"
        );
    }

    // =============================================================================================
    // 4. Racing and switching on (docs INDEX-BUILD §5.1, §5.4, §8 tests 4 and 8)
    // =============================================================================================

    function test_build_races_and_switches_on() public {
        _history();
        (uint64 admissions,) = _counts();
        (ListIndexDeployer d, IHeadAuthorsGeneration ix) =
            _headGen(address(r.g.posting), address(r.g.bitmap), address(0));
        (,, IPostingStore third) = _three(d);
        // unbuilt: the built family PARTIAL through 0; the carried families too (the check passes, frontier 0)
        _assertCoverage(ix, F_HEAD_AUTHORS, Coverage.PARTIAL, 0, "head-authors, unbuilt");
        _assertCoverage(ix, F_PLACE, Coverage.PARTIAL, 0, "carried posting family, unbuilt");
        assertTrue(ix.carriedCheck(), "the carried check passes");
        uint64 frontier = ix.build(bytes32(0), 64);
        assertGt(frontier, 0);
        assertLt(frontier, admissions);
        _assertCoverage(ix, F_HEAD_AUTHORS, Coverage.PARTIAL, frontier, "head-authors, mid-build");
        _assertCoverage(ix, F_PLACE, Coverage.PARTIAL, frontier, "carried, mid-build");
        _assertCoverage(
            ix, Keys.familyId("live-scope"), Coverage.PARTIAL, frontier, "carried bitmap, mid-build"
        );
        (Coverage lc,,,,) = ix.postingHeadOf(
            FamilyId.wrap(F_HEAD_AUTHORS), TypeId.wrap(0), 0, Keys.position(Purpose.HEAD, f1, 0)
        );
        assertEq(uint8(lc), uint8(Coverage.PARTIAL), "a list read carries PARTIAL");
        vm.expectRevert(abi.encodeWithSelector(E_INDEX_NOT_READY.selector, uint8(8)));
        this.activateNow(address(ix));
        // publications land between build calls; the builder catches up
        _traffic();
        _buildAll(ix);
        (admissions,) = _counts();
        assertTrue(ix.replayReadiness().ready);
        _assertCoverage(ix, F_HEAD_AUTHORS, Coverage.COMPLETE, admissions, "built");
        _assertCoverage(ix, F_PLACE, Coverage.COMPLETE, admissions, "carried, caught up");
        // a HEAD statement slips in before activation: refused as behind, nothing changes
        _head1(bob, EfsFiles.release(Purpose.HEAD, f1, 0, _hrev(bob, f1)));
        _assertCoverage(ix, F_HEAD_AUTHORS, Coverage.PARTIAL, admissions, "behind by one");
        vm.expectRevert(abi.encodeWithSelector(E_INDEX_NOT_READY.selector, uint8(8)));
        this.activateNow(address(ix));
        assertEq(r.hot.index(), address(r.g.index));
        // build and activate in one transaction
        this.buildThenActivate(address(ix));
        assertEq(r.hot.index(), address(ix));
        (admissions,) = _counts();
        _assertCoverage(ix, F_HEAD_AUTHORS, Coverage.COMPLETE, admissions, "live");
        (address[] memory g0, uint64[] memory f0, uint64[] memory t0) = third.writers();
        assertEq(g0.length, 1, "built: one range");
        assertEq(abi.encode(g0[0], f0[0], t0[0]), abi.encode(address(ix), uint64(1), uint64(0)));
        assertFalse(third.attached(), "a build write never attaches");
        (uint64 c0, uint64 l0,) = _headOf(third, f2);
        // the first live HEAD statement appends to the third store and attaches it
        _head1(carol, EfsFiles.loneNegative(Purpose.HEAD, f2, 0, 0));
        assertTrue(third.attached(), "the first live write attaches");
        (uint64 c1, uint64 l1, uint64 last) = _headOf(third, f2);
        assertEq(c1, c0 + 1, "appended");
        assertEq(last, _admission(carol, Purpose.HEAD, f2, 0));
        assertEq(l1, l0, "uncounted");
        (g0, f0, t0) = third.writers();
        assertEq(g0.length, 1, "still one range, from 1, into live");
        assertEq(abi.encode(g0[0], f0[0], t0[0]), abi.encode(address(ix), uint64(1), uint64(0)));
        (uint64 processed,,) = ix.progress();
        (admissions,) = _counts();
        assertEq(processed, admissions);
    }

    function buildThenActivate(address ix) external {
        require(msg.sender == address(this), "self");
        _buildAll(IGeneration1(ix));
        this.activateNow(ix);
    }

    // =============================================================================================
    // 5. Refusals with the third store (docs INDEX-BUILD §5.3; kernel checks 12 and 13 per store)
    // =============================================================================================

    function _strangerThird() internal returns (address) {
        return address(new PostingStore(address(r.ledger), makeAddr("stranger"), _headFamilies()));
    }

    /// An empty Realm: a third store whose INITIAL_WRITER is another contract is refused (12 / 7); one that is the
    /// candidate's own, or nobody's, activates.
    function test_empty_realm_refuses_another_writers_third_store() public {
        r = _realm(keccak256("head-authors/empty"));
        _register(r);
        (uint64 admissions,) = _counts();
        assertEq(admissions, 0);
        uint256 snap = vm.snapshotState();
        (, IHeadAuthorsGeneration bad) =
            _headGen(address(r.g.posting), address(r.g.bitmap), _strangerThird());
        assertFalse(bad.carriedCheck());
        vm.expectRevert(abi.encodeWithSelector(E_BUILD.selector, uint8(7)));
        bad.build(bytes32(0), 64);
        vm.expectRevert(abi.encodeWithSelector(E_INDEX_NOT_READY.selector, uint8(12)));
        this.activateNow(address(bad));
        // the candidate's own fresh third store, and a third store nobody can write in build mode
        (, IHeadAuthorsGeneration own) =
            _headGen(address(r.g.posting), address(r.g.bitmap), address(0));
        this.activateNow(address(own));
        assertEq(r.hot.index(), address(own));
        vm.revertToState(snap);
        address nobody = address(new PostingStore(address(r.ledger), address(0), _headFamilies()));
        (, IHeadAuthorsGeneration zero) =
            _headGen(address(r.g.posting), address(r.g.bitmap), nobody);
        this.activateNow(address(zero));
        assertEq(r.hot.index(), address(zero));
    }

    /// With admissions, another contract's third store is "carried", and the live index does not declare
    /// `head-authors` in it: 12, and `build` 7.
    function test_admissions_refuse_another_writers_third_store() public {
        _history();
        (, IHeadAuthorsGeneration bad) =
            _headGen(address(r.g.posting), address(r.g.bitmap), _strangerThird());
        assertFalse(bad.carriedCheck());
        Readiness memory rd = bad.replayReadiness();
        assertEq(rd.completedAdmission, 0, "claims nothing");
        _assertCoverage(bad, F_HEAD_AUTHORS, Coverage.PARTIAL, 0, "claims nothing for the list");
        vm.expectRevert(abi.encodeWithSelector(E_BUILD.selector, uint8(7)));
        bad.build(bytes32(0), 64);
        vm.expectRevert(abi.encodeWithSelector(E_INDEX_NOT_READY.selector, uint8(12)));
        this.activateNow(address(bad));
    }

    /// C builds and is activated; D carries all three of C's stores and replaces C before any admission reaches it;
    /// D's first live HEAD statement attaches C's third store; C's build is then refused (2). Between
    /// the two, C's build is already refused (7): its copy of the live manifest went stale when D went live, and the
    /// kernel names that first (14).
    function test_an_attached_third_store_refuses_the_build() public {
        _history();
        (ListIndexDeployer dc, IHeadAuthorsGeneration c) =
            _headGen(address(r.g.posting), address(r.g.bitmap), address(0));
        (,, IPostingStore third) = _three(dc);
        _buildAll(c);
        this.activateNow(address(c));
        (, IHeadAuthorsGeneration dgen) =
            _headGen(address(r.g.posting), address(r.g.bitmap), address(third));
        assertTrue(dgen.carriedCheck(), "the live C declares head-authors in its store from 1");
        _buildAll(dgen); // nothing to walk: every store carried
        this.activateNow(address(dgen));
        assertEq(r.hot.index(), address(dgen));
        // C carries the genesis stores, and its copy of the live index's manifest is generation 1's, stale since D
        // went live: its build is refused (7) and writes nothing (docs INDEX-BUILD §10; before the copy C could still
        // build here, with nothing new to fold)
        assertFalse(c.carriedCheck(), "C's copy is stale");
        vm.expectRevert(abi.encodeWithSelector(E_BUILD.selector, uint8(7)));
        c.build(bytes32(0), 64);
        assertFalse(third.attached());
        _head1(carol, EfsFiles.loneNegative(Purpose.HEAD, f2, 0, 0));
        assertTrue(third.attached(), "D's live write attached C's third store");
        (address[] memory g,,) = third.writers();
        assertEq(g.length, 2, "C's build range, closed; D's live range");
        assertEq(abi.encode(g[0], g[1]), abi.encode(address(c), address(dgen)));
        vm.expectRevert(abi.encodeWithSelector(E_BUILD.selector, uint8(2)));
        c.build(bytes32(0), 64);
        assertFalse(c.carriedCheck());
        // the kernel meets C's carried genesis families first, and C's copy is stale: 14 (before the copy, 13 from the
        // third store; 13 for a candidate that carries nothing is `Carried.t.sol::testAFreshStoreAlreadyAttachedIsRefused13`)
        vm.expectRevert(abi.encodeWithSelector(E_INDEX_NOT_READY.selector, uint8(14)));
        this.activateNow(address(c));
    }

    /// Check 12 and 13 judge the third store on its own: a candidate whose genesis stores pass and whose third store
    /// fails is refused for the third store alone (shown by the two tests above), and a candidate carrying all three
    /// stores of a live three-store index passes (D above). Here: an index that does not keep `head-authors` (the
    /// live generation 1) cannot vouch for a candidate carrying a third store it never named, even an unwritten one.
    function test_a_third_store_the_live_index_never_named_is_refused() public {
        _history();
        address nobody = address(new PostingStore(address(r.ledger), address(0), _headFamilies()));
        (, IHeadAuthorsGeneration ix) = _headGen(address(r.g.posting), address(r.g.bitmap), nobody);
        assertFalse(ix.carriedCheck());
        vm.expectRevert(abi.encodeWithSelector(E_BUILD.selector, uint8(7)));
        ix.build(bytes32(0), 64);
        vm.expectRevert(abi.encodeWithSelector(E_INDEX_NOT_READY.selector, uint8(12)));
        this.activateNow(address(ix));
    }
}
