// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {FilesRecipesBase} from "./FilesRecipesBase.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {EfsTopics} from "../../src/lib/EfsTopics.sol";
import {Action, Native, Purpose} from "../../src/interfaces/Actions.sol";
import {ILedgerCommitments} from "../../src/interfaces/ILedgerCommitments.sol";
import {E_INDEX_GAS} from "../../src/interfaces/Errors.sol";

/// @notice The kernel's availability floor against what the index really spends (design §6.4, §10.4), on the release
///         schedule and, under `FOUNDRY_PROFILE=amsterdam`, on EIP-8037/8038.
///
///         The floor is a lower bound on the EXECUTION gas that must be visible to the GAS opcode before each index
///         callback (`remaining prefix floor · 64/63 + finalReserve + kernelTail`) and before the final phase; it is
///         not a quote of total cost (the SDK sets the gas limit from the gas model). On a Glamsterdam chain the GAS
///         opcode never sees the state-gas reservoir and execution gas is capped at 2^24, so a publication passes
///         every check when, at each callback i, `2^24 − E_i ≥ max(0, P − S_i) · 64/63 + F + T` (E_i execution gas
///         spent before callback i, S_i the callbacks' share of it, P the prefix floor, F the final reserve, T the
///         kernel tail). E_i − S_i (the kernel's own execution gas) grows with i and P − S_i shrinks by what the
///         callbacks spend, so `E − S + P · 64/63 + F + T ≤ 2^24` over the publication's totals is sufficient. The
///         suite measures E (`vm.lastFrameGas().gasTotalUsed`, execution gas on both profiles) and the kernel's quote
///         (`indexFloor`), and bounds S from below by what a warm callback must spend (`S_BIND_MIN` per bind-kind
///         action, `S_PUBLISH_MIN` per publish; measured minima of the `-vvvv` traces, execution gas, both schedules).
///
///         What Foundry's amsterdam profile does NOT emulate: it has no reservoir and no 2^24 cap. State gas is drawn
///         from the call's own gas, so the GAS opcode inside the kernel sees state gas being spent, and a call capped
///         at 2^24 runs out where a chain would draw from the reservoir. The publications here therefore run with
///         ample gas (they are admitted), the measured execution gas stands in for the chain's capped dimension, and
///         the chain condition above is asserted by arithmetic on the kernel's own quote. The negative case is
///         direct on both profiles: a publication given clearly too little gas fails with the named `E_INDEX_GAS`.
contract IndexFloorTest is FilesRecipesBase {
    uint256 internal constant CAP = 1 << 24;
    uint256 internal constant KERNEL_TAIL = 20_000;
    EfsTopics.Types internal tt;
    bytes32 internal topic;

    function setUp() public override {
        super.setUp();
        tt = _topicTypes();
        (Action[] memory a, bytes[] memory b, bytes32 id) =
            EfsTopics.registerWord(tt, bytes("floor-topic"));
        _execAs(address(this), a, b);
        topic = id;
    }

    function execGas(Action[] calldata a, bytes[] calldata b, Native calldata c, uint256 gas_)
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
        uint256 exec;
        int256 state;
    }

    function _measure(string memory label, Action[] memory a, bytes[] memory b)
        internal
        returns (Row memory w)
    {
        (w.prefixFloor, w.finalReserve, w.fresh, w.rewrites) =
            ILedgerCommitments(r.hot.ingress()).indexFloor(address(r.ledger), a);
        Native memory c = _ctx(a);
        vm.startStateDiffRecording();
        r.ledger.execute(a, b, c, "");
        Vm.Gas memory f = vm.lastFrameGas();
        emit log_named_uint(
            string.concat("floor ", label, " fresh index slots"),
            _freshIndexSlots(vm.stopAndReturnStateDiff())
        );
        w.exec = f.gasTotalUsed;
        w.state = f.gasStateUsed;
        emit log_named_uint(string.concat("floor ", label, " prefixFloor"), w.prefixFloor);
        emit log_named_uint(string.concat("floor ", label, " finalReserve"), w.finalReserve);
        emit log_named_uint(string.concat("floor ", label, " fresh quoted"), w.fresh);
        emit log_named_uint(string.concat("floor ", label, " rewrites quoted"), w.rewrites);
        emit log_named_uint(string.concat("floor ", label, " exec"), w.exec);
        emit log_named_int(string.concat("floor ", label, " state"), w.state);
    }

    /// Slots of the index and its two stores that went from zero to nonzero in the publication (each counted once):
    /// the callbacks' share of EIP-8037 state gas is 97,920 per such slot.
    function _freshIndexSlots(Vm.AccountAccess[] memory d) internal view returns (uint256 n) {
        address[3] memory who = [address(r.g.index), address(r.g.posting), address(r.g.bitmap)];
        uint256 total;
        for (uint256 i; i < d.length; ++i) {
            total += d[i].storageAccesses.length;
        }
        bytes32[] memory keys = new bytes32[](total);
        bytes32[] memory first = new bytes32[](total);
        bytes32[] memory last = new bytes32[](total);
        uint256 m;
        for (uint256 i; i < d.length; ++i) {
            for (uint256 j; j < d[i].storageAccesses.length; ++j) {
                Vm.StorageAccess memory s = d[i].storageAccesses[j];
                if (!s.isWrite || s.reverted) continue;
                if (s.account != who[0] && s.account != who[1] && s.account != who[2]) continue;
                bytes32 k = keccak256(abi.encode(s.account, s.slot));
                uint256 at = m;
                for (uint256 q; q < m; ++q) {
                    if (keys[q] == k) at = q;
                }
                if (at == m) {
                    keys[m] = k;
                    first[m] = s.previousValue;
                    ++m;
                }
                last[at] = s.newValue;
            }
        }
        for (uint256 q; q < m; ++q) {
            if (first[q] == 0 && last[q] != 0) ++n;
        }
    }

    /// A warm callback's least execution gas per bind-kind action and per publish (measured minima, design §10.4).
    uint256 internal constant S_BIND_MIN = 60_000;
    uint256 internal constant S_PUBLISH_MIN = 20_000;

    /// `E − S_min + P · 64/63 + F + T`: an upper bound on the visible execution gas the floor needs on a chain.
    function _bound(Row memory w, uint256 binds, uint256 publishes)
        internal
        pure
        returns (uint256)
    {
        return w.exec + uint256(w.prefixFloor) * 64 / 63 + w.finalReserve + KERNEL_TAIL - binds
            * S_BIND_MIN - publishes * S_PUBLISH_MIN;
    }

    function _loneNegatives(uint256 n, uint256 seed)
        internal
        view
        returns (Action[] memory a, bytes[] memory b)
    {
        a = new Action[](n);
        b = new bytes[](n);
        for (uint256 i; i < n; ++i) {
            bytes32 thing = bytes32(uint256(uint160(uint256(keccak256(abi.encode(seed, i))))));
            a[i] = EfsTopics.deny(topic, thing, 0, 0);
        }
    }

    function _firstTags(uint256 n, uint256 seed)
        internal
        view
        returns (Action[] memory a, bytes[] memory b)
    {
        a = new Action[](n);
        b = new bytes[](n);
        for (uint256 i; i < n; ++i) {
            bytes32 thing = bytes32(uint256(uint160(uint256(keccak256(abi.encode(seed, i))))));
            a[i] = EfsTopics.tag(topic, thing, 0, 0);
        }
    }

    function _wordPages(uint256 n, string memory prefix)
        internal
        view
        returns (Action[] memory a, bytes[] memory b)
    {
        a = new Action[](n);
        b = new bytes[](n);
        for (uint256 i; i < n; ++i) {
            (Action[] memory x, bytes[] memory y,) =
                EfsTopics.registerWord(tt, bytes(string.concat(prefix, vm.toString(i))));
            (a[i], b[i]) = (x[0], y[0]);
        }
    }

    function _createFile(string memory name)
        internal
        view
        returns (Action[] memory a, bytes[] memory b)
    {
        bytes32 salt = keccak256(bytes(name));
        bytes32 file = Keys.subject(p, salt);
        a = new Action[](5);
        b = new bytes[](5);
        a[0] = _create(salt);
        (a[1], b[1]) = _publish(T_ROOT, abi.encodePacked(abi.encode(file, uint256(0)), name));
        (a[2], b[2]) = _name(bytes(name));
        a[3] = _bind(Purpose.HEAD, file, 0, _id(T_ROOT, b[1]), 0);
        a[4] = _bind(Purpose.FOLDER, rootDir, keccak256(bytes(name)), file, 0);
    }

    /// The rows the work model is fitted from, logged on whichever profile runs (prague by default).
    function test_floor_rows() public {
        uint256 snap = vm.snapshotState();
        (Action[] memory a, bytes[] memory b) = _loneNegatives(1, 1);
        _measure("1 lone negative", a, b);
        vm.revertToState(snap);
        (a, b) = _firstTags(1, 2);
        _measure("1 first tag", a, b);
        vm.revertToState(snap);
        (a, b) = _wordPages(1, "one-");
        _measure("1 word page", a, b);
        vm.revertToState(snap);
        (a, b) = _createFile("floor-file.txt");
        _measure("create file", a, b);
    }

    /// The large rows, one per test: each state diff is large and a test's memory is never freed, so three of them
    /// in one test run out of memory since the first-statement lists (step 3b) added their writes.
    function test_floor_row_32_first_tags() public {
        (Action[] memory a, bytes[] memory b) = _firstTags(32, 3);
        _measure("32 first tags", a, b);
    }

    function test_floor_row_64_word_pages() public {
        (Action[] memory a, bytes[] memory b) = _wordPages(64, "chunk-");
        _measure("64 word pages", a, b);
    }

    function test_floor_row_64_lone_negatives() public {
        (Action[] memory a, bytes[] memory b) = _loneNegatives(64, 4);
        _measure("64 lone negatives", a, b);
    }

    /// Lone negatives on a one-word topic. On prague their execution gas alone is over the cap at 64, so no floor
    /// could admit them in one transaction there and the test only asserts the bound is the quote's, not the floor's.
    /// On Glamsterdam (amsterdam profile) step 3b's first-statement lists (a `position-authors`, `place` and
    /// `role-places` entry per fresh position) raised a lone negative's execution gas, so the floor's sufficient bound
    /// no longer certifies 64 in one transaction (it is logged); the test finds the largest multiple of 8 it
    /// certifies and asserts it is at least 48.
    function test_sixty_four_lone_negatives_fit_the_cap() public {
        uint256 snap = vm.snapshotState();
        (Action[] memory a, bytes[] memory b) = _loneNegatives(64, 5);
        Row memory w = _measure("64 lone negatives (cap)", a, b);
        vm.revertToState(snap);
        assertGt(w.exec, 0);
        if (w.state > 0) {
            uint256 bound = _bound(w, 64, 0);
            emit log_named_uint(
                "floor 64 lone negatives: visible execution gas needed (bound)", bound
            );
            assertLe(w.exec, CAP, "64 lone negatives execute under 2^24 execution gas");
            uint256 k = 64;
            while (bound > CAP) {
                k -= 8;
                (a, b) = _loneNegatives(k, 5);
                w = _measure(string.concat(vm.toString(k), " lone negatives (cap)"), a, b);
                vm.revertToState(snap);
                bound = _bound(w, k, 0);
            }
            emit log_named_uint("floor lone negatives the bound certifies (multiple of 8)", k);
            emit log_named_uint("floor lone negatives: bound at that count", bound);
            assertGe(
                k, 48, "the floor certifies at least 48 lone negatives under 2^24 execution gas"
            );
            assertLe(uint256(w.prefixFloor) * 64 / 63 + w.finalReserve + KERNEL_TAIL, CAP);
        } else {
            assertLe(
                uint256(w.prefixFloor) * 64 / 63 + w.finalReserve + KERNEL_TAIL,
                w.exec,
                "prague: the floor is never the binding constraint, the execution gas is"
            );
        }
    }

    /// A 64-action registration chunk (64 fresh word pages) is admitted, and on amsterdam within the cap.
    function test_sixty_four_word_pages_fit_the_cap() public {
        (Action[] memory a, bytes[] memory b) = _wordPages(64, "fit-");
        Row memory w = _measure("64 word pages (cap)", a, b);
        if (w.state > 0) {
            uint256 bound = _bound(w, 0, 64);
            emit log_named_uint("floor 64 word pages: visible execution gas needed (bound)", bound);
            assertLe(bound, CAP, "a registration chunk fits 2^24 execution gas");
        } else {
            assertLe(w.exec, CAP, "prague: a registration chunk fits one transaction");
        }
    }

    /// Too little gas still fails, and with the named index-gas error, never silently: given seven eighths of what the
    /// publication uses, the prepare and the first leaves run and a callback runs out of gas (or the floor check before
    /// it refuses). Seven eighths, not half: under the amsterdam profile Foundry draws state gas from the call, and at
    /// half the kernel's own share after a failed callback no longer covers its revert since the lists' writes.
    function test_too_little_gas_fails_with_the_named_error() public {
        (Action[] memory a, bytes[] memory b) = _loneNegatives(8, 6);
        Native memory c = _ctx(a);
        uint256 snap = vm.snapshotState();
        uint256 before = gasleft();
        this.execGas(a, b, c, 100_000_000);
        uint256 used = before - gasleft();
        vm.revertToState(snap);
        try this.execGas(a, b, c, used - used / 8) {
            revert("admitted with too little gas");
        } catch (bytes memory err) {
            assertEq(bytes4(err), E_INDEX_GAS.selector, "the named index-gas error");
        }
        // and nothing landed: the same publication still runs in full afterwards
        this.execGas(a, b, c, 100_000_000);
    }
}
