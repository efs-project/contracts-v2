// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {HeadAuthorsBase} from "./HeadAuthorsBase.sol";
import {KernelDeploy} from "../harness/KernelDeploy.sol";
import {
    IHeadAuthorsGeneration,
    ListIndexDeployer,
    RecordingFoldHook
} from "../harness/HeadAuthors.sol";
import {Unit} from "../../src/interfaces/Index.sol";

/// @notice Docs INDEX-BUILD §3.6, §8 test 12: in a build that carries stores, a carried unit's fold hook is not called
///         (it folded live), and a unit new in the building generation has its fold hook called with every effect of
///         history, in order, exactly as a live fold would have called it. Generation 1 here pins a recording fold
///         hook A (purposeFilter 0: every effect) from genesis; the example generation keeps A and adds a recording
///         hook B (`RealmIndex._hookRuns`, overridden by `HeadAuthorsIndex` from `NEW_UNITS_FROM`). Both hooks obey
///         rule (i) of §3.6: they use only the effect and the publication they are given.
contract HeadAuthorsHooksTest is HeadAuthorsBase {
    RecordingFoldHook internal carriedHook;
    RecordingFoldHook internal newHook;

    function setUp() public override {
        carriedHook = new RecordingFoldHook();
        newHook = new RecordingFoldHook();
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

    /// Generation 1's units: the Files validator and the carried recording hook A.
    function _units() internal view virtual override returns (Unit[] memory u) {
        Unit[] memory base = super._units();
        u = new Unit[](base.length + 1);
        for (uint256 i; i < base.length; ++i) {
            u[i] = base[i];
        }
        u[base.length] = _hookUnit(carriedHook, "test/unit/carried-hook");
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

    /// The gap (docs INDEX-BUILD §3.6): a generation that carries every store walks nothing, so a unit it adds with a
    /// fold hook never sees the history. C (the example generation, no new unit) is built and activated; D carries
    /// all three of C's stores and adds B: its build moves the frontier and calls B for nothing, and the kernel
    /// activates it. Nothing in the kernel or the generation refuses that; a unit's hook must be built by a
    /// generation that walks (one with a fresh store), or the unit must not need the history.
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
        assertTrue(d.carriedCheck());
        (uint64 admissions,) = _counts();
        assertEq(d.build(bytes32(0), 64), admissions, "a re-pin: nothing walked");
        assertEq(newHook.calls(), 0, "the new unit's hook saw no history");
        this.activateNow(address(d));
        assertEq(r.hot.index(), address(d), "and the kernel activates it");
    }
}
