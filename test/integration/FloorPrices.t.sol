// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {KernelDeploy} from "../harness/KernelDeploy.sol";
import {Limits} from "../../src/interfaces/Limits.sol";

/// Slots 1..16 hold nonzero values from the constructor; slots 1000.. are zero. Each function measures one storage
/// operation with the GAS opcode around it and returns the difference.
contract SlotProbe {
    constructor() {
        for (uint256 i = 1; i <= 16; ++i) {
            assembly ("memory-safe") {
                sstore(i, add(i, 0x100))
            }
        }
    }

    function nothing() external view returns (uint256 used) {
        assembly ("memory-safe") {
            let g := gas()
            used := sub(g, gas())
        }
    }

    function write(uint256 slot, uint256 v) external returns (uint256 used) {
        assembly ("memory-safe") {
            let g := gas()
            sstore(slot, v)
            used := sub(g, gas())
        }
    }

    function read(uint256 slot) external view returns (uint256 used) {
        assembly ("memory-safe") {
            let g := gas()
            let x := sload(slot)
            used := sub(g, gas())
            if eq(x, not(0)) { revert(0, 0) }
        }
    }

    /// A read of the slot, then (warm) a write of it: [read, write].
    function readThenWrite(uint256 slot, uint256 v) external returns (uint256 r, uint256 w) {
        assembly ("memory-safe") {
            let g := gas()
            let x := sload(slot)
            r := sub(g, gas())
            g := gas()
            sstore(slot, v)
            w := sub(g, gas())
            if eq(x, not(0)) { revert(0, 0) }
        }
    }
}

/// Several probe calls inside one call frame (one transaction), so warm and dirty slots are measured as a callback
/// of a publication meets them.
contract ProbeDriver {
    SlotProbe internal immutable P;

    constructor(SlotProbe p) {
        P = p;
    }

    function twice(uint256 slot, uint256 v1, uint256 v2) external returns (uint256 a, uint256 b) {
        a = P.write(slot, v1);
        b = P.write(slot, v2);
    }

    function readThenWriteLater(uint256 slot, uint256 v) external returns (uint256 a, uint256 b) {
        a = P.read(slot);
        b = P.write(slot, v);
    }
}

/// @notice The floor's storage prices (design §10.4, `Limits.floorFreshGas` / `floorRewriteGas`) are the schedule
///         table's (tools/deploy-plan.mjs GAS_SCHEDULES, mirrored in test/vectors/gas-schedules.json; docs/GAS-SCHEDULES.md),
///         and the table is what the EVM charges, measured here on whichever profile runs (prague by default;
///         `FOUNDRY_PROFILE=amsterdam` for EIP-8037/8038).
///
///         What the floor's "rewrite" stands for: the first write in a transaction of a slot that already holds a
///         nonzero value (the index slots that were nonzero and changed, each counted once). It costs the same whether
///         the slot is written cold or read first and then written: prague 5,000 = 2,100 cold + 2,900, amsterdam
///         12,100 = 2,100 cold + 10,000 (EIP-8038 raises the write, not the cold access; a cold read is 2,100 on both).
///         A later write of the same slot in the same transaction is 100 on both schedules and is not a rewrite.
///
///         State gas: Foundry's amsterdam profile draws it from the same gas, so the GAS opcode's difference around a
///         fresh write is execution + state gas; the state part is `vm.lastFrameGas().gasStateUsed` of that call
///         (the only state the probe call creates), and the execution part is the difference less it.
contract FloorPricesTest is Test {
    /// The GAS opcode and the stack operations around a measured opcode (measured: 5 on both schedules; 16 for the
    /// read-then-write pair, two measurements).
    uint256 internal constant TOLERANCE = 20;

    SlotProbe internal probe;
    ProbeDriver internal driver;
    string internal json;

    function setUp() public {
        probe = new SlotProbe();
        driver = new ProbeDriver(probe);
        json = vm.readFile("test/vectors/gas-schedules.json");
    }

    function _amsterdam() internal view returns (bool) {
        return
            keccak256(bytes(vm.envOr("FOUNDRY_PROFILE", string("default"))))
                == keccak256("amsterdam");
    }

    function _schedule() internal view returns (string memory) {
        return _amsterdam() ? "amsterdam" : "prague";
    }

    function _u(string memory schedule, string memory field) internal view returns (uint256) {
        return vm.parseJsonUint(json, string.concat(".schedules.", schedule, ".", field));
    }

    function _near(uint256 measured, uint256 price, string memory what) internal {
        emit log_named_uint(string.concat(what, " measured"), measured);
        emit log_named_uint(string.concat(what, " table"), price);
        assertApproxEqAbs(measured, price, TOLERANCE, what);
    }

    /// Both schedules' harness constants and this profile's `s1Limits()` are the table's prices.
    function test_harness_floor_prices_are_the_table() public view {
        assertEq(KernelDeploy.PRAGUE_FLOOR_FRESH_GAS, _u("prague", "freshSlot.executionGas"));
        assertEq(
            KernelDeploy.PRAGUE_FLOOR_REWRITE_GAS, _u("prague", "rewriteColdSlot.executionGas")
        );
        assertEq(
            KernelDeploy.GLAMSTERDAM_FLOOR_FRESH_GAS, _u("amsterdam", "freshSlot.executionGas")
        );
        assertEq(
            KernelDeploy.GLAMSTERDAM_FLOOR_REWRITE_GAS,
            _u("amsterdam", "rewriteColdSlot.executionGas")
        );
        Limits memory l = KernelDeploy.s1Limits();
        assertEq(l.floorFreshGas, _u(_schedule(), "freshSlot.executionGas"), "s1Limits fresh");
        assertEq(
            l.floorRewriteGas, _u(_schedule(), "rewriteColdSlot.executionGas"), "s1Limits rewrite"
        );
    }

    /// A cold write of a fresh slot and a cold rewrite of an existing one cost this schedule's table prices; the
    /// floor's prices on this profile are those measured prices.
    function test_measured_prices_are_the_table() public {
        string memory s = _schedule();
        Limits memory l = KernelDeploy.s1Limits();
        vm.cool(address(probe));
        uint256 used = probe.write(1000, 7);
        uint256 state = uint256(uint64(vm.lastFrameGas().gasStateUsed));
        assertEq(state, _u(s, "freshSlot.stateGas"), "a fresh slot's state gas");
        _near(used - state, _u(s, "freshSlot.executionGas"), "cold fresh slot, execution gas");
        _near(used - state, l.floorFreshGas, "cold fresh slot against floorFreshGas");
        vm.cool(address(probe));
        used = probe.write(1, 7);
        assertEq(vm.lastFrameGas().gasStateUsed, 0, "a rewrite creates no state");
        _near(used, _u(s, "rewriteColdSlot.executionGas"), "cold rewrite");
        _near(used, l.floorRewriteGas, "cold rewrite against floorRewriteGas");
        // read first, then written: the same rewrite with its cold access paid by the read (2,100 on both schedules).
        // Measured 5,016 on prague (2,111 + 2,905) and 12,216 on amsterdam (2,111 + 10,105): on amsterdam a read
        // then a write costs 100 more than a cold write, so the rewrite term prices it within 1%.
        vm.cool(address(probe));
        (uint256 r, uint256 w) = driver.readThenWriteLater(8, 0x81);
        emit log_named_uint("cold read then rewrite measured", r + w);
        assertApproxEqAbs(
            r + w,
            _u(s, "rewriteColdSlot.executionGas") + (_amsterdam() ? 100 : 0),
            TOLERANCE,
            "cold read then rewrite"
        );
        // a second write of the same slot in the transaction is a dirty write, 100 on both schedules
        vm.cool(address(probe));
        (r, w) = driver.twice(7, 0x71, 0x72);
        _near(r, _u(s, "rewriteColdSlot.executionGas"), "first write of an existing slot");
        _near(w, 100, "second write of the slot in the transaction");
    }
}
