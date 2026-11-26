// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {TopicListsHistory} from "../integration/TopicListsHistory.sol";
import {IGeneration1} from "../harness/IndexDeploy.sol";
import {IndexDeployer} from "../../src/control/IndexDeployer.sol";
import {Layout} from "../../src/core/layout/Layout.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {EfsTopics} from "../../src/lib/EfsTopics.sol";
import {
    Action,
    FamilyId,
    Native,
    Purpose,
    ScopeKey,
    TypeId
} from "../../src/interfaces/Actions.sol";
import {Coverage} from "../../src/interfaces/Results.sol";
import {Readiness} from "../../src/interfaces/Index.sol";
import {IPostingStore} from "../../src/interfaces/IPostingStore.sol";
import {IBitmapStore} from "../../src/interfaces/IBitmapStore.sol";
import {ILedgerControl} from "../../src/interfaces/ILedgerControl.sol";
import {ILedgerCommitments} from "../../src/interfaces/ILedgerCommitments.sol";
import {E_BUILD, E_INDEX_NOT_READY, E_TRANSITION} from "../../src/interfaces/Errors.sol";

/// @notice Docs INDEX-BUILD step 2 on the real Files Realm: `build(0, maxFacts)` walks history into a generation's
///         fresh stores, whole publications at a time under a leaf budget, folding only the families of its fresh
///         stores. Over the mixed history of `TopicListsHistory` (it moves every counter of §4.2):
///
///         - both stores fresh: the built stores equal the replayed ones and the live ones, list by list (§8 test 1);
///         - one store fresh (posting carried, bitmap fresh; posting fresh, bitmap carried): the rebuilt store equals
///           the live one, the carried store is untouched, the generation activates and, after more traffic, both of
///           its stores equal those of a twin that never switched (the same Realm's state before the switch, restored
///           by a snapshot), with the writer ranges §5.4 predicts;
///         - interrupted builds (fuzzed budgets, one publication per call, budgets below the next publication) equal
///           one large build (§8 test 3);
///         - publications that land between build calls, build and activate in one transaction, a publication that
///           slips in (`E_INDEX_NOT_READY(8)`) and the transition route (§5.4, §8 test 4);
///         - coverage and readiness while building (§5.1) and the heaviest admitted publications built by one call
///           under 2^24 gas (§3.3, §8 test 11 preview).
contract BuildWalkTest is TopicListsHistory {
    uint256 internal constant TX_CAP = 1 << 24;
    /// The execution gas a 2^24 transaction leaves a `build(bytes32, uint16)` call: the 21,000 base and a calldata
    /// allowance of 1,000 (the call's 68 bytes cost at most 1,088 at 16 a byte; zero bytes cost 4).
    uint256 internal constant BUILD_CALL_GAS = TX_CAP - 21_000 - 1_000;
    uint8 internal constant BOTH_FRESH = 0;
    uint8 internal constant HEAL_BITMAP = 1; // posting carried, bitmap fresh
    uint8 internal constant HEAL_POSTING = 2; // posting fresh, bitmap carried

    bytes32 internal constant ROLE = keccak256("shared.txt");

    // ---- helpers ------------------------------------------------------------------------------------------------------

    function _cfg(uint8 cfg) internal returns (IndexDeployer d, IGeneration1 ix) {
        return _generation(
            cfg == HEAL_BITMAP ? address(r.g.posting) : address(0),
            cfg == HEAL_POSTING ? address(r.g.bitmap) : address(0)
        );
    }

    function _stores(IndexDeployer d) internal view returns (IPostingStore, IBitmapStore) {
        return (IPostingStore(d.postingStore()), IBitmapStore(d.bitmapStore()));
    }

    function _live() internal view returns (IPostingStore, IBitmapStore) {
        return (IPostingStore(address(r.g.posting)), IBitmapStore(address(r.g.bitmap)));
    }

    function _counts() internal view returns (uint64 admissions, uint64 publications) {
        (admissions,,, publications) = r.hot.counts();
    }

    function _leaves(uint64 n) internal view returns (uint8 leaves) {
        (,,,, leaves,,) = Layout.unpackEvidenceCellWord0(
            r.hot.extsload(bytes32(Layout.publicationsEvidenceSlot(n)))
        );
    }

    /// Builds with budget 64 until caught up; returns the calls made.
    function _buildAll(IGeneration1 ix) internal returns (uint256 calls) {
        (uint64 admissions,) = _counts();
        while (true) {
            uint64 through = ix.build(bytes32(0), 64);
            ++calls;
            if (through == admissions) return calls;
        }
    }

    function _assertCoverage(
        IGeneration1 ix,
        bytes32 family,
        Coverage want,
        uint64 through,
        string memory what
    ) internal view {
        (Coverage c, uint64 from, uint64 t,) = ix.coverage(FamilyId.wrap(family), ScopeKey.wrap(0));
        assertEq(uint8(c), uint8(want), string.concat(what, ": coverage"));
        assertEq(from, want == Coverage.UNKNOWN ? 0 : 1, string.concat(what, ": from"));
        assertEq(t, through, string.concat(what, ": through"));
    }

    /// Traffic after a switch, touching both stores and every bind transition the fold distinguishes: a PUBLISH, a
    /// first tag on the deepest topic (scope entry, first-statement lists, ancestor walk), a mask of a BOUND head
    /// (live bit, backlink and yes-count released), a same-target re-bind (stamp only), a release of a masked head,
    /// a restore of a masked FOLDER head (yes-count retained) and a FOLDER first bind under the new name.
    function _traffic() internal {
        bytes32 deep = topicIds[5];
        bytes32 home = bytes32(uint256(uint160(alice)));
        Action[] memory x = new Action[](1);
        bytes[] memory y = new bytes[](1);
        (x[0], y[0]) = _name("after.txt");
        _execAs(address(this), x, y);
        _tagAs(carol, deep, things[11], 0);
        _denyAs(alice, deep, things[0]);
        _tagAs(bob, deep, things[0], 7);
        _releaseAs(carol, Purpose.TAG, deep, things[0]);
        _say(
            carol,
            _bind(Purpose.FOLDER, home, ROLE, things[5], _rev(carol, Purpose.FOLDER, home, ROLE))
        );
        _say(alice, _bind(Purpose.FOLDER, home, keccak256("after.txt"), things[12], 0));
    }

    /// `ledger.execute` from this contract's principal, returning the revert data (empty when admitted).
    function _tryExec(Action[] memory a, bytes[] memory b) internal returns (bytes memory err) {
        Native memory c;
        (c.nonce,) = r.hot.nonceOf(p);
        c.expectedExecutionSet = r.hot.executionSet();
        c.expectedAcceptanceProfile =
            ILedgerCommitments(r.hot.ingress()).acceptanceProfileOf(address(r.ledger), a);
        try r.ledger.execute(a, b, c, "") {}
        catch (bytes memory e) {
            err = e;
        }
    }

    // =============================================================================================
    // 1. Both stores fresh: build equals replay equals live (docs INDEX-BUILD §8 test 1)
    // =============================================================================================

    function test_build_equals_replay_equals_live() public {
        _mixedHistory();
        (uint64 admissions, uint64 publications) = _counts();
        (IndexDeployer dr, IGeneration1 replayed) = _cfg(BOTH_FRESH);
        uint256 g = gasleft();
        while (replayed.replayNextPublication(64) != 0) {}
        uint256 replayGas = g - gasleft();
        (IndexDeployer db, IGeneration1 built) = _cfg(BOTH_FRESH);
        g = gasleft();
        uint256 calls = _buildAll(built);
        uint256 buildGas = g - gasleft();
        (IPostingStore lp, IBitmapStore lb) = _live();
        (IPostingStore rp, IBitmapStore rb) = _stores(dr);
        (IPostingStore bp, IBitmapStore bb) = _stores(db);
        (uint256 nonEmpty, uint256 entries) = _assertSameStores(lp, lb, rp, rb, "replayed vs live");
        _assertSameStores(lp, lb, bp, bb, "built vs live");
        _assertSameStores(rp, rb, bp, bb, "built vs replayed");
        _assertCountersMoved(lp);
        assertGt(nonEmpty, 60, "many non-empty lists compared");
        assertGt(entries, 100, "many entries compared");
        (uint64 processed, uint64 publication,) = built.progress();
        assertEq(abi.encode(processed, publication), abi.encode(admissions, publications));
        assertTrue(built.replayReadiness().ready);
        assertTrue(replayed.replayReadiness().ready);
        // one call per 64 leaves at most: the walk filled each call's budget with whole publications
        assertLt(calls, publications, "several publications per call");
        // a preview of the build's gas (warm within this test's one transaction; step 4 measures cold)
        emit log_named_uint("build: publications", publications);
        emit log_named_uint("build: admissions", admissions);
        emit log_named_uint("build: calls (budget 64)", calls);
        emit log_named_uint("build: gas, all calls", buildGas);
        emit log_named_uint("replay: gas, one publication per call", replayGas);
        emit log_named_uint("build: gas per publication", buildGas / publications);
        emit log_named_uint("build: gas per leaf", buildGas / admissions);
    }

    // =============================================================================================
    // 2. Heal one store (posting carried + bitmap fresh; posting fresh + bitmap carried)
    // =============================================================================================

    function test_heal_the_bitmap_store() public {
        _heal(HEAL_BITMAP);
    }

    function test_heal_the_posting_store() public {
        _heal(HEAL_POSTING);
    }

    function _heal(uint8 cfg) internal {
        _mixedHistory();
        (uint64 admissions,) = _counts();
        (IndexDeployer d, IGeneration1 ix) = _cfg(cfg);
        (IPostingStore hp, IBitmapStore hb) = _stores(d);
        (IPostingStore lp, IBitmapStore lb) = _live();
        address carried = cfg == HEAL_BITMAP ? address(lp) : address(lb);
        address fresh = cfg == HEAL_BITMAP ? address(hb) : address(hp);
        assertEq(cfg == HEAL_BITMAP ? address(hp) : address(hb), carried, "the carried store");
        (address[] memory cg0, uint64[] memory cf0, uint64[] memory ct0) =
            IPostingStore(carried).writers();
        assertEq(cg0.length, 1);
        assertEq(cg0[0], address(r.g.index));
        assertEq(ct0[0], 0);
        (bytes32[] memory liveBefore,,) = _capture(lp, lb);

        // before the build: behind, every family PARTIAL through 0
        Readiness memory rd = ix.replayReadiness();
        assertFalse(rd.ready);
        assertEq(rd.completedAdmission, 0);
        _assertCoverage(ix, F_PLACE, Coverage.PARTIAL, 0, "posting family, unbuilt");
        _assertCoverage(ix, Keys.familyId("scope"), Coverage.PARTIAL, 0, "bitmap family, unbuilt");

        // one call: PARTIAL through the frontier, in both stores' families
        uint64 frontier = ix.build(bytes32(0), 64);
        assertGt(frontier, 0);
        assertLt(frontier, admissions);
        _assertCoverage(ix, F_PLACE, Coverage.PARTIAL, frontier, "posting family, mid-build");
        _assertCoverage(
            ix, Keys.familyId("live-scope"), Coverage.PARTIAL, frontier, "bitmap family, mid-build"
        );
        assertFalse(ix.replayReadiness().ready);
        _buildAll(ix);

        // the carried store was never written by the build; the rebuilt store equals the live one
        (address[] memory cg1, uint64[] memory cf1, uint64[] memory ct1) =
            IPostingStore(carried).writers();
        assertEq(
            keccak256(abi.encode(cg1, cf1, ct1)),
            keccak256(abi.encode(cg0, cf0, ct0)),
            "carried writers untouched"
        );
        (bytes32[] memory liveAfter,,) = _capture(lp, lb);
        _assertSameCapture(liveBefore, liveAfter, "live stores untouched by the build");
        _assertSameStores(lp, lb, hp, hb, "healed vs live");
        (address[] memory fg, uint64[] memory ff, uint64[] memory ft) =
            IPostingStore(fresh).writers();
        assertEq(fg.length, 1, "the fresh store: one range");
        assertEq(fg[0], address(ix));
        assertEq(ff[0], 1, "from 1");
        assertEq(ft[0], 0, "open");
        assertFalse(IPostingStore(fresh).attached(), "a build write never attaches");
        rd = ix.replayReadiness();
        assertTrue(rd.ready);
        assertEq(rd.completedAdmission, admissions);
        _assertCoverage(ix, F_PLACE, Coverage.COMPLETE, admissions, "posting family, built");
        _assertCoverage(
            ix, Keys.familyId("scope"), Coverage.COMPLETE, admissions, "bitmap family, built"
        );
        assertEq(ix.build(bytes32(0), 64), admissions, "nothing pending: the frontier, no revert");

        // the twin: the same Realm, never switched, takes the same traffic
        uint256 snap = vm.snapshotState();
        _traffic();
        (bytes32[] memory twin,,) = _capture(lp, lb);
        vm.revertToState(snap);

        this.activateNow(address(ix));
        assertEq(r.hot.index(), address(ix));
        _traffic();
        (bytes32[] memory healed,,) = _capture(hp, hb);
        _assertSameCapture(twin, healed, "healed generation vs the twin that never switched");
        (uint64 processed,,) = ix.progress();
        (uint64 now_,) = _counts();
        assertEq(processed, now_);

        // writer ranges: the fresh store keeps one range from 1 into live; the carried store's old range is closed
        // at the admission before the new generation's first live write to it
        (fg, ff, ft) = IPostingStore(fresh).writers();
        assertEq(fg.length, 1, "fresh: still one range");
        assertEq(ff[0], 1);
        assertEq(ft[0], 0);
        assertTrue(IPostingStore(fresh).attached());
        (cg1, cf1, ct1) = IPostingStore(carried).writers();
        assertEq(cg1.length, 2, "carried: the old range and the new");
        assertEq(cg1[0], address(r.g.index));
        assertEq(cf1[0], cf0[0]);
        assertEq(cg1[1], address(ix));
        assertEq(ct1[0], cf1[1] - 1, "closed at the first live write - 1");
        assertGt(cf1[1], admissions, "the first live write is after the build's frontier");
        assertEq(ct1[1], 0);
        // the PUBLISH at admissions + 1 is the first live write of the posting store; the first bind (+2) the bitmap's
        assertEq(cf1[1], cfg == HEAL_BITMAP ? admissions + 1 : admissions + 2);
    }

    // =============================================================================================
    // 3. Interrupted and resumed (docs INDEX-BUILD §8 test 3)
    // =============================================================================================

    /// forge-config: default.fuzz.runs = 6
    /// forge-config: ci.fuzz.runs = 12
    function testFuzz_interrupted_build_equals_one_build(uint256 seed) public {
        _mixedHistory();
        (uint64 admissions, uint64 publications) = _counts();
        uint8 cfg = uint8(seed % 3);
        (IndexDeployer d1, IGeneration1 one) = _cfg(cfg);
        assertEq(one.build(bytes32(0), type(uint16).max), admissions, "one call builds it all");
        (IndexDeployer d2, IGeneration1 cut) = _cfg(cfg);
        uint256 refused;
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
                    ? leaves  // exactly one publication
                    : mode == 2
                        ? uint16(leaves - 1)  // below the next publication: refused
                        : uint16(1 + (seed >> 8) % 200);
            if (budget < leaves) {
                vm.expectRevert(abi.encodeWithSelector(E_BUILD.selector, uint8(6)));
                cut.build(bytes32(0), budget);
                (uint64 p2, uint64 l2,) = cut.progress();
                assertEq(abi.encode(p2, l2), abi.encode(processed, lastPublication), "unchanged");
                ++refused;
                continue;
            }
            uint64 through = cut.build(bytes32(0), budget);
            ++calls;
            (, uint64 l3,) = cut.progress();
            assertGt(l3, lastPublication, "at least one publication");
            if (mode == 1) assertEq(l3, lastPublication + 1, "exactly one publication");
            assertEq(through, processed + _sum(lastPublication + 1, l3));
        }
        (IPostingStore p1, IBitmapStore b1) = _stores(d1);
        (IPostingStore p2s, IBitmapStore b2s) = _stores(d2);
        (IPostingStore lp, IBitmapStore lb) = _live();
        _assertSameStores(p1, b1, p2s, b2s, "interrupted vs one call");
        _assertSameStores(lp, lb, p2s, b2s, "interrupted vs live");
        assertTrue(cut.replayReadiness().ready);
        emit log_named_uint("calls", calls);
        emit log_named_uint("refused calls", refused);
    }

    function _sum(uint64 from, uint64 to) internal view returns (uint64 s) {
        for (uint64 n = from; n <= to; ++n) {
            s += _leaves(n);
        }
    }

    /// The budget's edges, without fuzzing: 0 and a budget one below the next publication's leaf count refuse with
    /// `E_BUILD(6)`; the exact count folds exactly that publication; with nothing pending any budget returns the
    /// frontier.
    function test_budget_edges() public {
        _mixedHistory();
        (uint64 admissions, uint64 publications) = _counts();
        (, IGeneration1 ix) = _cfg(HEAL_POSTING);
        uint8 first = _leaves(1);
        vm.expectRevert(abi.encodeWithSelector(E_BUILD.selector, uint8(6)));
        ix.build(bytes32(0), 0);
        if (first > 1) {
            vm.expectRevert(abi.encodeWithSelector(E_BUILD.selector, uint8(6)));
            ix.build(bytes32(0), first - 1);
        }
        assertEq(ix.build(bytes32(0), first), first);
        (, uint64 lastPublication,) = ix.progress();
        assertEq(lastPublication, 1);
        // the 16 CREATEs of setUp are one publication of 16 leaves
        uint8 second = _leaves(2);
        assertEq(second, 16);
        vm.expectRevert(abi.encodeWithSelector(E_BUILD.selector, uint8(6)));
        ix.build(bytes32(0), 15);
        assertEq(ix.build(bytes32(0), 16), uint64(first) + 16);
        assertEq(ix.build(bytes32(0), type(uint16).max), admissions);
        (, lastPublication,) = ix.progress();
        assertEq(lastPublication, publications);
        assertEq(ix.build(bytes32(0), 0), admissions, "nothing pending: budget 0 is fine");
    }

    // =============================================================================================
    // 4. Racing live admissions; closing the gap (docs INDEX-BUILD §5.4, §8 test 4)
    // =============================================================================================

    function test_build_races_live_admissions_then_one_transaction() public {
        _mixedHistory();
        (IndexDeployer d, IGeneration1 ix) = _cfg(HEAL_BITMAP);
        uint64 first = ix.build(bytes32(0), 64);
        // publications land between build calls; the builder catches up, more calls each time
        _traffic();
        (uint64 admissions,) = _counts();
        assertLt(first, admissions);
        _buildAll(ix);
        assertTrue(ix.replayReadiness().ready);
        // a publication slips in before activation: refused as behind, nothing changes
        _tagAs(carol, topicIds[3], things[13], 0);
        assertFalse(ix.replayReadiness().ready);
        _assertCoverage(ix, Keys.familyId("scope"), Coverage.PARTIAL, admissions, "behind by one");
        vm.expectRevert(abi.encodeWithSelector(E_INDEX_NOT_READY.selector, uint8(8)));
        this.activateNow(address(ix));
        assertEq(r.hot.index(), address(r.g.index));
        // build and activate in one transaction (one external call from the controller)
        _tagAs(alice, topicIds[3], things[13], 0);
        this.buildThenActivate(address(ix));
        assertEq(r.hot.index(), address(ix));
        _tagAs(bob, topicIds[3], things[13], 0);
        (uint64 processed,,) = ix.progress();
        (admissions,) = _counts();
        assertEq(processed, admissions);
        (IPostingStore hp, IBitmapStore hb) = _stores(d);
        assertEq(address(hp), address(r.g.posting));
        assertTrue(hb.attached());
    }

    /// The controller's one transaction (route 1 of §5.4): build until caught up, then activate.
    function buildThenActivate(address ix) external {
        require(msg.sender == address(this), "self");
        _buildAll(IGeneration1(ix));
        this.activateNow(ix);
    }

    function test_transition_route() public {
        _mixedHistory();
        (, IGeneration1 ix) = _cfg(HEAL_POSTING);
        ix.build(bytes32(0), 64); // the bulk before the transition
        ILedgerControl(r.k.proxy).beginTransition(revision + 1, uint48(block.number + 100));
        Action[] memory x = new Action[](1);
        bytes[] memory y = new bytes[](1);
        (x[0], y[0]) = _name("during.txt");
        bytes memory err = _tryExec(x, y);
        assertEq(bytes4(err), E_TRANSITION.selector, "ordinary writes refused");
        // build still works during the transition
        _buildAll(ix);
        assertTrue(ix.replayReadiness().ready);
        this.activateNow(address(ix));
        assertEq(r.hot.index(), address(ix));
        assertEq(_tryExec(x, y).length, 0, "the activation ended the transition");
        (uint64 processed,,) = ix.progress();
        (uint64 admissions,) = _counts();
        assertEq(processed, admissions);
    }

    // =============================================================================================
    // 6. Activation refuses an unfinished build; coverage says so (docs INDEX-BUILD §8 test 8)
    // =============================================================================================

    function test_activation_refuses_an_unfinished_build() public {
        _mixedHistory();
        (uint64 admissions,) = _counts();
        for (uint8 cfg; cfg < 3; ++cfg) {
            (, IGeneration1 ix) = _cfg(cfg);
            uint64 frontier = ix.build(bytes32(0), 64);
            assertLt(frontier, admissions);
            Readiness memory rd = ix.replayReadiness();
            assertFalse(rd.ready);
            assertEq(rd.completedAdmission, frontier);
            _assertCoverage(ix, F_PLACE, Coverage.PARTIAL, frontier, "posting family");
            _assertCoverage(ix, Keys.familyId("live-scope"), Coverage.PARTIAL, frontier, "bitmap");
            (Coverage c,,,,) =
                ix.postingHeadOf(FamilyId.wrap(F_PLACE), TypeId.wrap(Purpose.TAG), 0, topicIds[5]);
            assertEq(uint8(c), uint8(Coverage.PARTIAL), "a list read carries PARTIAL");
            vm.expectRevert(abi.encodeWithSelector(E_INDEX_NOT_READY.selector, uint8(8)));
            this.activateNow(address(ix));
        }
        // the live index is unaffected: COMPLETE, one extra ledger read
        _assertCoverage(
            IGeneration1(address(r.g.index)), F_PLACE, Coverage.COMPLETE, admissions, "live"
        );
    }

    // =============================================================================================
    // 7. The heaviest publications build in one call under 2^24 (docs INDEX-BUILD §3.3, §8 test 11 preview)
    // =============================================================================================

    function _thing(string memory seed, uint256 i) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(uint256(keccak256(abi.encode(seed, i))))));
    }

    function _amsterdam() internal view returns (bool) {
        return
            keccak256(bytes(vm.envOr("FOUNDRY_PROFILE", string("default"))))
                == keccak256("amsterdam");
    }

    function _k(string memory shape) internal view returns (uint256) {
        return vm.parseJsonUint(
            vm.readFile("test/vectors/floor-plan.json"),
            string.concat(".schedules.", _amsterdam() ? "amsterdam" : "prague", ".", shape, ".k")
        );
    }

    function _cool(IndexDeployer d, IGeneration1 ix) internal {
        address[13] memory a = [
            r.k.proxy,
            address(r.k.implementation),
            address(r.k.ingress),
            address(r.k.applyDelegate),
            address(r.k.control),
            address(r.registry),
            address(r.registryImpl),
            address(ix),
            ix.READS(),
            ix.decoder(),
            d.postingStore(),
            d.bitmapStore(),
            address(r.store)
        ];
        for (uint256 i; i < a.length; ++i) {
            vm.cool(a[i]);
        }
    }

    /// Admits `a` (ample gas), then builds it alone in one cold call. The call is measured with ample gas first
    /// (`vm.lastFrameGas`: total and, on amsterdam, state gas); it fits when its execution gas is within what a 2^24
    /// transaction leaves the call (`BUILD_CALL_GAS`). EIP-7825's cap bounds execution gas only (state gas is drawn
    /// from a reservoir beyond it, docs/GAS-SCHEDULES.md), and Foundry's amsterdam profile draws state gas from the
    /// call's own gas, so the cap is judged on `gasTotalUsed` (regular gas; state gas is `gasStateUsed`); on prague the same
    /// call is then also run with exactly `BUILD_CALL_GAS`, which must succeed when it fits.
    function _measure(IndexDeployer d, IGeneration1 ix, string memory label, Action[] memory a)
        internal
        returns (bool fit, uint256 execution)
    {
        _execAs(address(this), a, new bytes[](a.length));
        uint256 snap = vm.snapshotState();
        _cool(d, ix);
        ix.build(bytes32(0), 64);
        Vm.Gas memory f = vm.lastFrameGas();
        execution = f.gasTotalUsed; // regular gas only: Foundry reports EIP-8037 state gas apart
        fit = execution <= BUILD_CALL_GAS;
        vm.revertToState(snap);
        if (!_amsterdam()) {
            _cool(d, ix);
            try ix.build{gas: BUILD_CALL_GAS}(bytes32(0), 64) {
                assertTrue(fit, "a capped call that fits was measured as fitting");
            } catch {
                assertFalse(fit, "a capped call that fails was measured as not fitting");
                ix.build(bytes32(0), 64);
            }
        } else {
            ix.build(bytes32(0), 64);
        }
        emit log_named_uint(string.concat(label, ": leaves"), a.length);
        emit log_named_uint(string.concat(label, ": build execution gas, one cold call"), execution);
        emit log_named_uint(string.concat(label, ": frame total gas"), f.gasTotalUsed);
        emit log_named_int(string.concat(label, ": frame state gas"), f.gasStateUsed);
        emit log_named_string(string.concat(label, ": fits 2^24"), fit ? "yes" : "NO");
        (uint64 admissions,) = _counts();
        (uint64 processed,,) = ix.progress();
        assertEq(processed, admissions, "built");
    }

    function _tags(bytes32 topic, string memory seed, uint256 n, bool deny)
        internal
        pure
        returns (Action[] memory a)
    {
        a = new Action[](n);
        for (uint256 i; i < n; ++i) {
            a[i] = deny
                ? EfsTopics.deny(topic, _thing(seed, i), 0, 0)
                : EfsTopics.tag(topic, _thing(seed, i), 0, 0);
        }
    }

    function test_heaviest_publications_build_in_one_call() public {
        bytes32 word = _regPath("heavy", 1)[0];
        bytes32 deep8 = _regPath("eight", 8)[7];
        bytes32 deep64 = _regPath("sixtyfour", 64)[63];
        (IndexDeployer d, IGeneration1 ix) = _cfg(BOTH_FRESH);
        _buildAll(ix);
        bool fit;
        // the largest publication of each shape the planning rule admits on this schedule
        (fit,) =
            _measure(d, ix, "lone negatives (k)", _tags(word, "ln-k", _k("loneNegatives"), true));
        assertTrue(fit, "the largest admitted lone negatives");
        (fit,) = _measure(
            d, ix, "depth-8 first tags (k)", _tags(deep8, "d8-k", _k("firstTagsDepth8New"), false)
        );
        assertTrue(fit, "the largest admitted depth-8 first tags");
        (fit,) = _measure(
            d,
            ix,
            "depth-64 first tags (k)",
            _tags(deep64, "d64-k", _k("firstTagsDepth64New"), false)
        );
        assertTrue(fit, "the largest admitted depth-64 first tags");
        // 64 leaves of each (admitted here with the test's ample gas; the floor admits fewer)
        (fit,) = _measure(d, ix, "64 lone negatives", _tags(word, "ln-64", 64, true));
        assertTrue(fit, "64 lone negatives");
        _measure(d, ix, "64 depth-8 first tags", _tags(deep8, "d8-64", 64, false));
        _measure(d, ix, "64 depth-64 first tags", _tags(deep64, "d64-64", 64, false));
    }
}
