// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {FilesRecipesBase} from "./FilesRecipesBase.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {Action, ActionKind, Native, Purpose} from "../../src/interfaces/Actions.sol";
import {ILedgerCommitments} from "../../src/interfaces/ILedgerCommitments.sol";

/// SPIKE probe: writes `n` fresh slots and reports the regular gas it saw itself spend (GAS opcode deltas).
contract SlotWriter {
    function write(uint256 base, uint256 n) external returns (uint256 seen) {
        uint256 g = gasleft();
        for (uint256 i; i < n; ++i) {
            assembly ("memory-safe") {
                sstore(add(base, i), 1)
            }
        }
        seen = g - gasleft();
    }
}

/// @notice SPIKE (tags, Part 2): the kernel's pre-callback availability floor under the two schedules, and what
///         Foundry's amsterdam profile emulates of EIP-8037's state-gas reservoir. Logs `floor <row>`; the probe
///         rows are meaningful on both profiles (state gas is zero on prague).
///
///         The floor (src/core/LedgerIngress.sol `_foldAndQuote`, checked in `dispatchIndex` and, for the final
///         reserve, `LedgerCore._notifyIndex`/`_final`): `prefixFloor = compute + ceil(fresh10/10) * floorFreshGas +
///         ceil(rw10/10) * floorRewriteGas`, slot counts from the index's `WorkModel` (per publication, per fresh
///         publish, per ref, per digest spec, per fresh bind; never per topic level), and before every index
///         callback `(gasleft() - finalReserve - kernelTail) * 63/64 >= remaining prefixFloor` (GAS opcode only).
contract GlamsterdamFloorTest is FilesRecipesBase {
    uint256 internal constant CAP = 1 << 24;
    SlotWriter internal writer;

    function setUp() public override {
        super.setUp();
        writer = new SlotWriter();
    }

    // ---- what the profile emulates ---------------------------------------------------------------------------

    /// (1) the GAS opcode at the top of the test frame; (2) n fresh slots: the regular gas the writer saw, the
    /// caller's GAS delta, and `vm.lastFrameGas` (total and state); (3) the same write under an explicit call gas
    /// far below n * the state price: does state gas come out of the call's gas?
    function test_probe_state_gas_dimension() public {
        emit log_named_uint("floor probe gasleft at test start", gasleft());
        uint256 n = 100;
        uint256 before = gasleft();
        uint256 seen = writer.write(1_000, n);
        uint256 outer = before - gasleft();
        Vm.Gas memory f = vm.lastFrameGas();
        emit log_named_uint("floor probe 100 fresh slots: GAS delta inside", seen);
        emit log_named_uint("floor probe 100 fresh slots: GAS delta of the caller", outer);
        emit log_named_uint("floor probe 100 fresh slots: lastFrameGas.gasTotalUsed", f.gasTotalUsed);
        emit log_named_int("floor probe 100 fresh slots: lastFrameGas.gasStateUsed", f.gasStateUsed);
        // call gas 40k per slot: above the regular price on both schedules, far below 110,020 (amsterdam's total)
        uint256 limit = n * 40_000;
        try writer.write{gas: limit}(5_000, n) returns (uint256 s2) {
            emit log_named_uint("floor probe capped call (4,000,000 gas) succeeded, GAS delta inside", s2);
            emit log_named_int("floor probe capped call state gas", vm.lastFrameGas().gasStateUsed);
        } catch {
            emit log("floor probe capped call (4,000,000 gas) ran out of gas: state gas is drawn from it");
        }
    }

    // ---- the floor on large fresh publications -----------------------------------------------------------------

    function execCapped(Action[] calldata a, bytes[] calldata b, Native calldata c, uint256 gas_)
        external
    {
        require(msg.sender == address(this));
        r.ledger.execute{gas: gas_}(a, b, c, "");
    }

    struct Row {
        uint32 prefixFloor;
        uint32 finalReserve;
        uint32 fresh;
        uint32 rewrites;
        uint256 needed; // the visible gas the first callback check needs (estimate: floor * 64/63 + reserve + tail)
        uint256 exec; // measured regular gas of the publication (uncapped)
        int256 state; // measured state gas
        bool cappedOk; // admitted when the call gets exactly 2^24 of gas
    }

    function _row(string memory label, Action[] memory a, bytes[] memory b)
        internal
        returns (Row memory w)
    {
        (w.prefixFloor, w.finalReserve, w.fresh, w.rewrites) =
            ILedgerCommitments(r.hot.ingress()).indexFloor(address(r.ledger), a);
        w.needed = uint256(w.prefixFloor) * 64 / 63 + w.finalReserve + 20_000;
        Native memory c = _ctx(a);
        uint256 snap = vm.snapshotState();
        try this.execCapped(a, b, c, CAP) {
            w.cappedOk = true;
        } catch (bytes memory err) {
            emit log_named_bytes(string.concat("floor ", label, " capped revert"), err);
        }
        vm.revertToState(snap);
        r.ledger.execute(a, b, c, "");
        Vm.Gas memory f = vm.lastFrameGas();
        w.exec = f.gasTotalUsed;
        w.state = f.gasStateUsed;
        vm.revertToState(snap);
        emit log_named_uint(string.concat("floor ", label, " prefixFloor"), w.prefixFloor);
        emit log_named_uint(string.concat("floor ", label, " finalReserve"), w.finalReserve);
        emit log_named_uint(string.concat("floor ", label, " fresh slots quoted"), w.fresh);
        emit log_named_uint(string.concat("floor ", label, " rewrites quoted"), w.rewrites);
        emit log_named_uint(string.concat("floor ", label, " visible gas the check needs"), w.needed);
        emit log_named_uint(string.concat("floor ", label, " measured exec (regular)"), w.exec);
        emit log_named_int(string.concat("floor ", label, " measured state"), w.state);
        emit log_named_uint(
            string.concat("floor ", label, " admitted with a 2^24 call"), w.cappedOk ? 1 : 0
        );
    }

    function _regPath(string memory name, uint256 n) internal returns (bytes32 leaf) {
        bytes[] memory w = new bytes[](n);
        for (uint256 i; i < n; ++i) {
            w[i] = bytes(string.concat(name, "-", vm.toString(i)));
        }
        (Action[] memory a, bytes[] memory b, bytes32 id) = _pathActions(w, true);
        for (uint256 from; from < a.length; from += 64) {
            uint256 m = a.length - from < 64 ? a.length - from : 64;
            Action[] memory x = new Action[](m);
            bytes[] memory y = new bytes[](m);
            for (uint256 i; i < m; ++i) {
                (x[i], y[i]) = (a[from + i], b[from + i]);
            }
            r.ledger.execute(x, y, _ctx(x), "");
        }
        return id;
    }

    /// A first tag on a fully fresh 64-word path (every list fresh); a 64-action registration chunk (64 fresh word
    /// pages); 64 first tags in one publication on a 64-word path (64 fresh positions, the largest bind count).
    function test_floor_large_fresh_publications() public {
        bytes32 deep = _regPath("floor-deep", 64);
        bytes32 thing = Keys.subject(p, keccak256("floor/thing"));
        Action[] memory one = new Action[](2);
        one[0] = _create(keccak256("floor/thing"));
        one[1] = _bind(Purpose.TAG, deep, thing, thing, 0);
        _row("first tag, fresh 64-word path", one, new bytes[](2));

        Action[] memory reg = new Action[](64);
        bytes[] memory rb = new bytes[](64);
        for (uint256 i; i < 64; ++i) {
            rb[i] = bytes(string.concat("floor-chunk-", vm.toString(i)));
            (reg[i], rb[i]) = _wordPage(rb[i]);
        }
        _row("64 fresh word pages", reg, rb);

        Action[] memory things = new Action[](32);
        for (uint256 i; i < 32; ++i) {
            things[i] = _create(keccak256(abi.encode("floor/many", i)));
        }
        r.ledger.execute(things, new bytes[](32), _ctx(things), "");
        Action[] memory tags = new Action[](32);
        for (uint256 i; i < 32; ++i) {
            bytes32 t = Keys.subject(p, things[i].salt);
            tags[i] = _bind(Purpose.TAG, deep, t, t, 0);
        }
        _row("32 first tags, 64-word path", tags, new bytes[](32));
        Action[] memory tags64 = new Action[](64);
        for (uint256 i; i < 64; ++i) {
            bytes32 role = keccak256(abi.encode("floor/neg", i));
            tags64[i] = _bindKind(ActionKind.UNBIND, Purpose.TAG, _wordId("floor-deep-0"), role, 0, 0);
        }
        Row memory w = _row("64 lone negatives, 1-word topic", tags64, new bytes[](64));
        // The floor alone refuses this publication on every schedule: the first callback check needs more visible
        // gas than the 2^24 cap can give (compute + slot prices + the final reserve of 120,000 per bind).
        assertGt(w.needed, CAP, "the floor needs more than the cap");
        if (w.state > 0) {
            // amsterdam: its regular (execution) gas fits the cap, and EIP-8037 pays the state gas from the
            // reservoir above the cap, so on a real Glamsterdam chain it could pay — and is still refused. (Foundry's
            // amsterdam profile has no reservoir: state gas comes out of the call's gas, so the capped call above
            // also fails for that reason; this row is the regular-gas reading.)
            assertLt(w.exec, CAP, "payable in execution gas");
            emit log("floor 64 lone negatives: REFUSED BY THE FLOOR THOUGH PAYABLE under a reservoir (estimate)");
        }
    }
}
