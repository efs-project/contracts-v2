// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test, Vm, console2} from "forge-std/Test.sol";

/// Reads artifacts and files on behalf of the test, so a missing artifact or a refused read is an ordinary
/// revert the test can catch (cheatcode failures revert the calling frame).
contract ArtifactProbe {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function code(string calldata id)
        external
        view
        returns (bytes memory initcode, bytes memory runtime)
    {
        initcode = vm.getCode(id);
        runtime = vm.getDeployedCode(id);
    }

    function read(string calldata path) external view returns (string memory) {
        return vm.readFile(path);
    }
}

/// @notice The size gate of design §3.3 item 2 over every deployable unit of §3.1/§15: runtime ≤ 19,660 B
///         (20 % under EIP-170; 17,500 B is the warning line) and initcode-with-arguments ≤ 36,864 B. A unit
///         whose artifact does not exist yet is logged as pending, never a failure; a unit that exists is
///         measured, logged and gated. The estimates are the design's (nominal, pessimistic = +15 %), marked
///         `estimate` in `test/snapshots/sizes.json`, which mirrors the table below row for row.
/// @dev Arguments: until a unit is deployed with real constructor arguments (the deployer library, S0.5), the
///      gate adds the row's `argsEstimate` to the bare initcode (≈ 3.7 KB of manifest for `RealmIndex`, a few
///      words elsewhere). `sizes.json` is cross-checked against the table when the test may read it; the
///      committed `fs_permissions` grant reads of `./test/vectors` only, so until that grant includes
///      `./test/snapshots` the cross-check is logged as pending (the table here is then the gate's source).
contract BudgetsTest is Test {
    uint256 internal constant RUNTIME_BUDGET = 19_660;
    uint256 internal constant RUNTIME_WARNING = 17_500;
    uint256 internal constant INITCODE_BUDGET = 36_864;
    uint256 internal constant EIP170 = 24_576;
    string internal constant SNAPSHOT = "test/snapshots/sizes.json";

    struct Unit {
        string name;
        uint256 nominal;
        uint256 pessimistic;
        uint256 argsEstimate;
    }

    ArtifactProbe internal probe;

    function setUp() public {
        probe = new ArtifactProbe();
    }

    /// Design §15 (and §3.1 for the units §15 groups): name, nominal, pessimistic, argument allowance.
    function units() internal pure returns (Unit[] memory u) {
        u = new Unit[](21);
        u[0] = Unit("LedgerCore", 16_400, 18_900, 256);
        u[1] = Unit("LedgerApply", 7_600, 8_700, 256);
        u[2] = Unit("LedgerIngress", 11_500, 13_200, 256); // S1; S2 15,500 / 17,800
        u[3] = Unit("LedgerReads", 12_000, 13_800, 256);
        u[4] = Unit("LedgerViews", 11_000, 12_700, 256);
        u[5] = Unit("TypeRegistry", 12_500, 14_400, 256);
        u[6] = Unit("DescribedTypeRule", 5_200, 6_000, 256);
        u[7] = Unit("DescriptorStore", 1_000, 1_200, 256);
        u[8] = Unit("RealmIndex", 12_500, 14_400, 3_700);
        u[9] = Unit("PostingStore", 5_500, 6_300, 256);
        u[10] = Unit("BitmapStore", 5_000, 5_800, 256);
        u[11] = Unit("IndexBuild", 6_000, 6_900, 256);
        u[12] = Unit("IndexReplayDecoder", 5_200, 6_000, 256);
        u[13] = Unit("FilesFinalValidator", 5_500, 6_300, 256);
        u[14] = Unit("RealmController", 6_000, 6_900, 256);
        u[15] = Unit("RealmGenesis", 3_000, 3_500, 256);
        u[16] = Unit("IndexDeployer", 2_500, 2_900, 256);
        u[17] = Unit("ReaderDirectory", 1_500, 1_800, 256);
        u[18] = Unit("LensReader", 12_000, 13_800, 256);
        u[19] = Unit("FilesPageReader", 15_000, 17_300, 256);
        u[20] = Unit("LedgerControl", 16_500, 19_000, 256); // the third pinned delegate (adoption note 7)
    }

    function artifactOf(string memory name) internal pure returns (string memory) {
        return string.concat(name, ".sol:", name);
    }

    function test_table_is_the_design_table() public view {
        Unit[] memory u = units();
        assertEq(u.length, 21, "every deployable of design section 15 plus the control delegate");
        for (uint256 i; i < u.length; ++i) {
            assertLe(u[i].nominal, u[i].pessimistic, u[i].name);
            // pessimistic is nominal + 15 %, rounded by the design to the nearest 100 B
            assertApproxEqAbs(u[i].pessimistic, u[i].nominal * 115 / 100, 100, u[i].name);
            assertLe(u[i].pessimistic, RUNTIME_BUDGET, u[i].name);
            for (uint256 j; j < i; ++j) {
                assertTrue(keccak256(bytes(u[i].name)) != keccak256(bytes(u[j].name)), u[i].name);
            }
        }
        assertLe(RUNTIME_BUDGET, EIP170 * 80 / 100 + 1, "budget is 20 % under EIP-170");

        try probe.read(SNAPSHOT) returns (string memory json) {
            assertEq(vm.parseJsonUint(json, ".limits.runtimeBudget"), RUNTIME_BUDGET);
            assertEq(vm.parseJsonUint(json, ".limits.runtimeWarning"), RUNTIME_WARNING);
            assertEq(vm.parseJsonUint(json, ".limits.initcodeBudget"), INITCODE_BUDGET);
            for (uint256 i; i < u.length; ++i) {
                string memory row = string.concat(".units[", vm.toString(i), "]");
                assertEq(vm.parseJsonString(json, string.concat(row, ".name")), u[i].name);
                assertEq(
                    vm.parseJsonString(json, string.concat(row, ".artifact")), artifactOf(u[i].name)
                );
                assertEq(
                    vm.parseJsonUint(json, string.concat(row, ".runtimeBudget")), RUNTIME_BUDGET
                );
                assertEq(
                    vm.parseJsonUint(json, string.concat(row, ".initcodeBudget")), INITCODE_BUDGET
                );
                assertEq(
                    vm.parseJsonUint(json, string.concat(row, ".argsEstimate")), u[i].argsEstimate
                );
                assertEq(
                    vm.parseJsonString(json, string.concat(row, ".estimate.status")), "estimate"
                );
                assertEq(
                    vm.parseJsonUint(json, string.concat(row, ".estimate.nominal")), u[i].nominal
                );
                assertEq(
                    vm.parseJsonUint(json, string.concat(row, ".estimate.pessimistic")),
                    u[i].pessimistic
                );
            }
            console2.log("sizes.json: 20 rows equal the table");
        } catch {
            console2.log(
                "sizes.json: cross-check pending (not readable: the committed fs_permissions grant ./test/vectors only)"
            );
        }
    }

    function test_every_present_unit_fits_its_budget() public view {
        Unit[] memory u = units();
        uint256 measured;
        uint256 pending;
        string memory over;
        for (uint256 i; i < u.length; ++i) {
            try probe.code(artifactOf(u[i].name)) returns (
                bytes memory initcode, bytes memory runtime
            ) {
                ++measured;
                uint256 withArgs = initcode.length + u[i].argsEstimate;
                console2.log(
                    string.concat(
                        u[i].name,
                        ": runtime ",
                        vm.toString(runtime.length),
                        " / ",
                        vm.toString(RUNTIME_BUDGET),
                        " (estimate ",
                        vm.toString(u[i].nominal),
                        " / ",
                        vm.toString(u[i].pessimistic),
                        "); initcode ",
                        vm.toString(initcode.length),
                        " + args ",
                        vm.toString(u[i].argsEstimate),
                        " / ",
                        vm.toString(INITCODE_BUDGET),
                        runtime.length > RUNTIME_WARNING ? "; OVER the 17,500 warning line" : ""
                    )
                );
                if (runtime.length == 0 || runtime.length > RUNTIME_BUDGET) {
                    over = string.concat(
                        over, " ", u[i].name, " runtime ", vm.toString(runtime.length), ";"
                    );
                }
                if (withArgs > INITCODE_BUDGET) {
                    over = string.concat(
                        over, " ", u[i].name, " initcode+args ", vm.toString(withArgs), ";"
                    );
                }
            } catch {
                ++pending;
                console2.log(string.concat(u[i].name, ": pending (no artifact yet)"));
            }
        }
        console2.log(
            string.concat(
                "units: ", vm.toString(measured), " measured, ", vm.toString(pending), " pending"
            )
        );
        assertEq(measured + pending, u.length);
        // Every unit is measured and logged first; then one failure names all that are over budget.
        assertTrue(bytes(over).length == 0, string.concat("over budget:", over));
    }

    /// The probe tells a present artifact from a missing one, so "pending" never hides a broken probe.
    function test_probe_distinguishes_present_and_missing_artifacts() public view {
        (bytes memory initcode, bytes memory runtime) = probe.code("Budgets.t.sol:ArtifactProbe");
        assertGt(runtime.length, 0);
        assertGt(initcode.length, runtime.length);
        assertEq(keccak256(runtime), keccak256(address(probe).code));
        try probe.code("NoSuchUnit.sol:NoSuchUnit") {
            revert("a missing artifact was found");
        } catch {}
    }
}
