// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {HeadAuthorsBase} from "./HeadAuthorsBase.sol";
import {KernelDeploy} from "../harness/KernelDeploy.sol";
import {IGeneration1, IndexDeploy} from "../harness/IndexDeploy.sol";
import {ManifestCopy} from "../harness/ManifestCopy.sol";
import {IndexDoubleDefaults} from "../harness/doubles/IndexDoubles.sol";
import {IndexDeployer} from "../../src/control/IndexDeployer.sol";
import {IndexReplayDecoder} from "../../src/index/IndexReplayDecoder.sol";
import {RealmIndex} from "../../src/index/RealmIndex.sol";
import {IndexReads} from "../../src/index/IndexReads.sol";
import {Action, Purpose} from "../../src/interfaces/Actions.sol";
import {Readiness} from "../../src/interfaces/Index.sol";
import {E_BUILD, E_INDEX_NOT_READY} from "../../src/interfaces/Errors.sol";
import {
    IHeadAuthorsGeneration,
    ListIndexDeployer,
    RecordingFoldHook
} from "../harness/HeadAuthors.sol";
import {Unit} from "../../src/interfaces/Index.sol";

/// The same recording hook with other code (another codehash at the same address, by `vm.etch`).
contract OtherRecordingFoldHook is RecordingFoldHook {
    function other() external pure returns (uint256) {
        return 2;
    }
}

/// @notice Docs INDEX-BUILD §3.6, §8 test 12: in a build that carries stores, a carried unit's fold hook is not called
///         (it folded live), and a unit new in the building generation has its fold hook called with every effect of
///         history, in order, exactly as a live fold would have called it. Generation 1 here pins a recording fold
///         hook A (purposeFilter 0: every effect) from genesis; the example generation keeps A and adds a recording
///         hook B, named by its reads contract's `_builtHooks` (from `NEW_UNITS_FROM`), which `RealmIndex._hookRuns`
///         reads. Both hooks obey rule (i) of §3.6: they use only the effect and the publication they are given.
///         Option A (§3.6): a carried unit is one the live index declares with the same fold hook, fold codehash and
///         purposeFilter; any other fold-hook unit is new and refused unless the generation walks and builds it.
contract HeadAuthorsHooksTest is HeadAuthorsBase {
    RecordingFoldHook internal carriedHook;
    RecordingFoldHook internal newHook;
    /// A second carried hook, pinned from genesis with purposeFilter TAG (for the wider/narrower filter cases).
    RecordingFoldHook internal tagHook;

    function setUp() public override {
        carriedHook = new RecordingFoldHook();
        newHook = new RecordingFoldHook();
        tagHook = new RecordingFoldHook();
        super.setUp();
    }

    function _hookUnit(RecordingFoldHook h, string memory id) internal view returns (Unit memory) {
        return Unit({
            foldHook: address(h),
            foldCodehash: address(h).codehash,
            finalHook: address(0),
            finalCodehash: 0,
            familyIds: new bytes32[](0),
            purposeFilter: 0,
            hotAbiId: KernelDeploy.HOT_ABI_ID,
            identity: keccak256(bytes(id))
        });
    }

    /// Generation 1's units: the Files validator, the carried recording hook A (every effect) and the tag hook
    /// (TAG effects only).
    function _units() internal view virtual override returns (Unit[] memory u) {
        Unit[] memory base = super._units();
        u = new Unit[](base.length + 2);
        for (uint256 i; i < base.length; ++i) {
            u[i] = base[i];
        }
        u[base.length] = _hookUnit(carriedHook, "test/unit/carried-hook");
        u[base.length + 1] = _hookUnit(tagHook, "test/unit/tag-hook");
        u[base.length + 1].purposeFilter = Purpose.TAG;
    }

    /// The index of unit A in `_units()`.
    function _aAt() internal view returns (uint256) {
        return super._units().length;
    }

    /// Generation 1's code over the two genesis stores (both carried: it walks nothing) with `units`, a current copy.
    function _repinWith(Unit[] memory units) internal returns (IGeneration1 ix) {
        IndexDeployer.Plan memory plan;
        plan.hotAbiId = KernelDeploy.HOT_ABI_ID;
        plan.decoder = address(new IndexReplayDecoder());
        plan.postingFamilies = IndexDeploy.postingFamilies();
        plan.posting = address(r.g.posting);
        plan.bitmapFamilies = IndexDeploy.bitmapFamilies();
        plan.bitmap = address(r.g.bitmap);
        plan.readsInitcode = type(IndexReads).creationCode;
        plan.generationInitcode = type(RealmIndex).creationCode;
        plan.units = units;
        plan.specs = _specs();
        plan.work = IndexDoubleDefaults.workModel();
        plan.topicTypeId = typeIds[T_TOPIC];
        plan.topicWordTypeId = typeIds[T_TOPIC_WORD];
        plan.liveManifest = ManifestCopy.ofLive(address(r.ledger));
        IndexDeployer d = new IndexDeployer(address(r.ledger), keccak256(abi.encode(plan)));
        ix = IGeneration1(d.run(plan));
    }

    /// Option A's refusal: the carried check fails, `build` 7, readiness claims nothing, activation 8.
    function _expectNewUnitRefused(IGeneration1 ix, string memory label) internal {
        assertFalse(IHeadAuthorsGeneration(address(ix)).carriedCheck(), label);
        Readiness memory rd = ix.replayReadiness();
        assertFalse(rd.ready, label);
        assertEq(rd.completedAdmission, 0, label);
        vm.expectRevert(abi.encodeWithSelector(E_BUILD.selector, uint8(7)));
        ix.build(bytes32(0), 64);
        vm.expectRevert(abi.encodeWithSelector(E_INDEX_NOT_READY.selector, uint8(8)));
        this.activateNow(address(ix));
    }

    /// A re-pin keeps every carried unit unchanged and is built and activated as before.
    function _expectCarriedBuilds(IGeneration1 ix, string memory label) internal {
        assertTrue(IHeadAuthorsGeneration(address(ix)).carriedCheck(), label);
        (uint64 admissions,) = _counts();
        assertEq(ix.build(bytes32(0), 64), admissions, label);
        this.activateNow(address(ix));
        assertEq(r.hot.index(), address(ix), label);
    }

    /// The example generation's units: generation 1's, then B (new).
    function _withNew() internal view returns (Unit[] memory u, uint256 newFrom) {
        Unit[] memory base = _units();
        newFrom = base.length;
        u = new Unit[](base.length + 1);
        for (uint256 i; i < base.length; ++i) {
            u[i] = base[i];
        }
        u[base.length] = _hookUnit(newHook, "test/unit/new-hook");
    }

    function test_a_new_units_fold_hook_is_built_and_a_carried_units_is_not() public {
        _mixedHistory();
        _headHistory();
        uint256 liveCalls = carriedHook.calls();
        bytes32 liveChain = carriedHook.chain();
        assertGt(liveCalls, 50, "A folded the whole history live");
        (Unit[] memory units, uint256 newFrom) = _withNew();
        (, IHeadAuthorsGeneration ix) =
            _headGenWith(address(r.g.posting), address(r.g.bitmap), address(0), units, newFrom);
        assertEq(ix.NEW_UNITS_FROM(), newFrom);
        // the opt-out: the reads contract names B, and the generation's `_hookRuns` reads the same mask
        assertEq(IndexReads(_reads(ix)).builtHooks(), uint256(1) << newFrom);
        assertEq(RealmIndex(address(ix)).BUILT_HOOKS(), uint256(1) << newFrom);
        assertTrue(ix.carriedCheck(), "B is new and built: the walk calls it");
        _buildAll(ix);
        assertEq(
            carriedHook.calls(), liveCalls, "the carried unit's hook is not called by the build"
        );
        assertEq(carriedHook.chain(), liveChain);
        assertEq(newHook.calls(), liveCalls, "the new unit's hook gets every effect of history");
        assertEq(newHook.chain(), liveChain, "in the order and with the inputs of the live fold");
        // switched on: both hooks are called live, with the same effects
        this.activateNow(address(ix));
        _traffic();
        assertGt(carriedHook.calls(), liveCalls);
        assertEq(newHook.calls(), carriedHook.calls());
        assertEq(newHook.chain(), carriedHook.chain(), "built then live = live from genesis");
    }

    /// The gap of step 3b, closed (Option A, docs INDEX-BUILD §3.6): a generation that carries every store walks
    /// nothing, so a unit it adds with a fold hook would never see the history. C (the example generation, no new
    /// unit) is built and activated; D carries all three of C's stores and adds B, and D's reads contract even claims
    /// to build B (`_builtHooks`): the claim is not accepted, because D walks nothing, so D is refused (`build` 7,
    /// activation 8) and B sees nothing.
    function test_a_re_pin_cannot_build_a_new_units_hook() public {
        _mixedHistory();
        _headHistory();
        (ListIndexDeployer dc, IHeadAuthorsGeneration c) =
            _headGen(address(r.g.posting), address(r.g.bitmap), address(0));
        _buildAll(c);
        this.activateNow(address(c));
        (Unit[] memory units, uint256 newFrom) = _withNew();
        (, IHeadAuthorsGeneration d) =
            _headGenWith(address(r.g.posting), address(r.g.bitmap), dc.store(2), units, newFrom);
        assertEq(RealmIndex(address(d)).BUILT_HOOKS(), uint256(1) << newFrom, "D claims B");
        _expectNewUnitRefused(d, "a re-pin that walks nothing cannot build B");
        assertEq(newHook.calls(), 0, "the new unit's hook saw no history");
    }

    /// Option A by default: generation 1's code carrying both genesis stores and adding B (no opt-out) is refused.
    function test_a_new_fold_hook_unit_is_refused_by_default() public {
        _mixedHistory();
        (Unit[] memory units,) = _withNew();
        _expectNewUnitRefused(_repinWith(units), "B is new");
        assertEq(IndexReads(_reads(_repinWith(units))).builtHooks(), 0, "generation 1 builds none");
    }

    /// The same hook address with a different codehash is NEW: here the code at A's address is replaced (`vm.etch`)
    /// and the candidate pins what is there now; the live index pinned the old code.
    function test_the_same_hook_with_another_codehash_is_new() public {
        _mixedHistory();
        bytes32 pinned = r.g.index.replayReadiness().units[_aAt()].foldCodehash;
        vm.etch(address(carriedHook), address(new OtherRecordingFoldHook()).code);
        Unit[] memory units = _units(); // reads the codehash at A's address now
        assertTrue(units[_aAt()].foldCodehash != pinned, "another codehash, same address");
        _expectNewUnitRefused(_repinWith(units), "another codehash");
    }

    /// The match includes `purposeFilter`: A narrowed to TAG is new (its record holds folds of effects it would no
    /// longer be given); the tag hook widened to every effect is new (it never saw the others); identical units are
    /// carried and the re-pin builds and activates.
    function test_a_wider_or_narrower_filter_is_new_and_identical_units_are_carried() public {
        _mixedHistory();
        Unit[] memory narrower = _units();
        narrower[_aAt()].purposeFilter = Purpose.TAG;
        _expectNewUnitRefused(_repinWith(narrower), "narrower");
        Unit[] memory wider = _units();
        wider[_aAt() + 1].purposeFilter = 0;
        _expectNewUnitRefused(_repinWith(wider), "wider");
        // fields that decide no fold call are not compared: a carried unit with another identity is still carried
        Unit[] memory same = _units();
        same[_aAt()].identity = keccak256("test/unit/carried-hook/renamed");
        _expectCarriedBuilds(_repinWith(same), "identical where it matters");
    }

    /// A unit with only a final hook is never judged: a new one, and the Files validator's unit with another identity,
    /// in a re-pin that walks nothing, build and activate.
    function test_final_hook_only_units_are_not_affected() public {
        _mixedHistory();
        Unit[] memory base = _units();
        Unit[] memory units = new Unit[](base.length + 1);
        for (uint256 i; i < base.length; ++i) {
            units[i] = base[i];
        }
        units[0].identity = keccak256("test/unit/validator/changed");
        units[base.length] = Unit({
            foldHook: address(0),
            foldCodehash: 0,
            finalHook: address(newHook),
            finalCodehash: address(newHook).codehash,
            familyIds: new bytes32[](0),
            purposeFilter: 0,
            hotAbiId: KernelDeploy.HOT_ABI_ID,
            identity: keccak256("test/unit/new-final")
        });
        _expectCarriedBuilds(_repinWith(units), "final-only units");
        // the next publication runs the new final hook (it acknowledges) and folds live
        Action[] memory x = new Action[](1);
        bytes[] memory y = new bytes[](1);
        (x[0], y[0]) = _name("final-only.txt");
        _execAs(address(this), x, y);
    }

    function _reads(IGeneration1 ix) internal view returns (address reads) {
        (reads,) = ix.readsContract();
    }
}
