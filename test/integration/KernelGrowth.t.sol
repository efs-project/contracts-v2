// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {FloorBase} from "./FloorBase.sol";
import {EfsFiles} from "../../src/lib/EfsFiles.sol";
import {EfsTopics} from "../../src/lib/EfsTopics.sol";
import {Action, Native, Purpose} from "../../src/interfaces/Actions.sol";
import {IRealmIndex} from "../../src/interfaces/IRealmIndex.sol";

/// @notice The kernel's cost of one more action grows with the size of its publication (the list release, 2026-11-26;
///         stated in tools/RELEASE.md and gas/model.json, to be modelled as a term in n² at the next regeneration). The
///         model's rows are k = 1 → 2 marginals, so they price every action at its cost in a one- or two-action
///         publication; in a publication of n actions the kernel spends about 60 to 85 × n² gas more than the rows say
///         (measured: 257,980 short for 16 create-file recipes without a name PUBLISH, 64 actions).
///
///         Measured here, on whichever profile runs, for four kinds of action: CREATE, a fresh name PUBLISH, a repeat
///         name PUBLISH and a TAG mask (a later statement), the kernel's own execution gas (`vm.lastFrameGas` of the
///         execute frame with the index's two callbacks answered by `vm.mockCall`, every Realm account cooled first) of
///         publications of n = 1, 2, 8, 16, 32 and 60 actions of that kind, each from the same state. Logged:
///         `growth <kind> n <n> kernel frame gas` and the marginal cost of one more action over each step. Asserted, a
///         loose band on the slope, so a change shows: the marginal from 32 to 60 actions exceeds the marginal from 1 to 2
///         by 2,000 to 20,000 gas (measured 7,095 for CREATE on prague).
///
///         Cause, CONFIRMED from one trace (`test_growth_memory_trace`): memory expansion. The kernel frame's peak memory
///         offset grows by about 175 words an action, so its memory cost 3·W + W²/512 grows as n²; the trace measures the
///         highest MLOAD/MSTORE offset in the ledger's frames for 2 and 8 CREATEs and asserts the per-action growth is
///         between 100 and 300 words. The trace needs Foundry's debug tracer, so that test runs only under `-vvv` (it is
///         skipped otherwise); the release note gives its measured figures. The n = 60 publications take well under a
///         second each; the suite runs in seconds.
contract KernelGrowthTest is FloorBase {
    uint256[6] internal N = [uint256(1), 2, 8, 16, 32, 60];

    function setUp() public override {
        super.setUp();
    }

    /// The kernel's own execution gas of `a` from the current state (the callbacks mocked, the Realm cooled), and the
    /// state left as it was.
    function _kernel(Action[] memory a, bytes[] memory b) internal returns (uint256 g) {
        Native memory c = _ctx(a);
        uint256 snap = vm.snapshotState();
        address index = address(r.g.index);
        vm.mockCall(
            index,
            abi.encodeWithSelector(IRealmIndex.onAdmission.selector),
            abi.encode(IRealmIndex.onAdmission.selector)
        );
        vm.mockCall(
            index,
            abi.encodeWithSelector(IRealmIndex.afterPublication.selector),
            abi.encode(IRealmIndex.afterPublication.selector)
        );
        _coolRealm();
        r.ledger.execute(a, b, c, "");
        g = vm.lastFrameGas().gasTotalUsed;
        vm.clearMockedCalls();
        vm.revertToStateAndDelete(snap);
    }

    function _name10(string memory pre, uint256 i) internal pure returns (bytes memory) {
        return bytes.concat(
            bytes(pre),
            bytes1(uint8(97 + (i / 676) % 26)),
            bytes1(uint8(97 + (i / 26) % 26)),
            bytes1(uint8(97 + i % 26)),
            ".txt"
        );
    }

    function _thing(uint256 i) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(uint256(keccak256(abi.encode("growth thing", i))))));
    }

    /// The first n actions of `kind`: 0 CREATE, 1 a fresh name PUBLISH, 2 a repeat name PUBLISH, 3 a TAG mask.
    function _actions(uint256 kind, uint256 n, bytes32 topic)
        internal
        view
        returns (Action[] memory a, bytes[] memory b)
    {
        a = new Action[](n);
        b = new bytes[](n);
        for (uint256 i; i < n; ++i) {
            if (kind == 0) a[i] = _create(keccak256(abi.encode("growth create", i)));
            else if (kind == 1) (a[i], b[i]) = _name(_name10("gf-", i));
            else if (kind == 2) (a[i], b[i]) = _name(_name10("gr-", i));
            else a[i] = EfsFiles.unbind(Purpose.TAG, topic, _thing(i), 1);
        }
    }

    /// The state the kinds need: the repeat names published, a topic with 60 asserted tags.
    function _state() internal returns (bytes32 topic) {
        (Action[] memory a, bytes[] memory b) = _actions(1, 60, 0);
        for (uint256 i; i < 60; ++i) {
            (a[i], b[i]) = _name(_name10("gr-", i));
        }
        _execAs(address(this), a, b);
        (Action[] memory ra, bytes[] memory rb, bytes32 id) =
            EfsTopics.registerWord(_topicTypes(), bytes("growth"));
        _execAs(address(this), ra, rb);
        topic = id;
        Action[] memory t = new Action[](60);
        for (uint256 i; i < 60; ++i) {
            t[i] = EfsTopics.tag(topic, _thing(i), 0, 0);
        }
        _execAs(address(this), t, new bytes[](60));
    }

    function _growth(uint256 kind, string memory what) internal {
        bytes32 topic = _state();
        uint256[6] memory g;
        for (uint256 j; j < 6; ++j) {
            (Action[] memory a, bytes[] memory b) = _actions(kind, N[j], topic);
            g[j] = _kernel(a, b);
            emit log_named_uint(
                string.concat("growth ", what, " n ", vm.toString(N[j]), " kernel frame gas"), g[j]
            );
            if (j != 0) {
                emit log_named_uint(
                    string.concat(
                        "growth ",
                        what,
                        " marginal ",
                        vm.toString(N[j - 1]),
                        " to ",
                        vm.toString(N[j])
                    ),
                    (g[j] - g[j - 1]) / (N[j] - N[j - 1])
                );
            }
        }
        uint256 first = g[1] - g[0];
        uint256 last = (g[5] - g[4]) / (N[5] - N[4]);
        emit log_named_uint(
            string.concat("growth ", what, " rise of the marginal, 1-2 to 32-60"), last - first
        );
        assertGt(
            last,
            first + 2000,
            string.concat(what, ": the marginal grows with the publication (slope moved down)")
        );
        assertLt(last, first + 20_000, string.concat(what, ": the slope moved up"));
    }

    function test_growth_create() public {
        _growth(0, "create");
    }

    function test_growth_fresh_name_publish() public {
        _growth(1, "fresh name publish");
    }

    function test_growth_repeat_name_publish() public {
        _growth(2, "repeat name publish");
    }

    function test_growth_tag_mask() public {
        _growth(3, "tag mask");
    }

    /// The highest memory offset an MLOAD or MSTORE reaches in the ledger's frames (the proxy and the kernel code it
    /// runs), from a debug trace of `n` CREATEs with the callbacks mocked.
    function _peakMemory(uint256 n) internal returns (uint256 peak) {
        (Action[] memory a, bytes[] memory b) = _actions(0, n, 0);
        Native memory c = _ctx(a);
        uint256 snap = vm.snapshotState();
        address index = address(r.g.index);
        vm.mockCall(
            index,
            abi.encodeWithSelector(IRealmIndex.onAdmission.selector),
            abi.encode(IRealmIndex.onAdmission.selector)
        );
        vm.mockCall(
            index,
            abi.encodeWithSelector(IRealmIndex.afterPublication.selector),
            abi.encode(IRealmIndex.afterPublication.selector)
        );
        try vm.startDebugTraceRecording() {}
        catch {
            // the debug tracer exists only under -vvv or more: this one measurement is skipped elsewhere
            vm.revertToStateAndDelete(snap);
            return 0;
        }
        r.ledger.execute(a, b, c, "");
        Vm.DebugStep[] memory steps = vm.stopAndReturnDebugTraceRecording();
        vm.clearMockedCalls();
        vm.revertToStateAndDelete(snap);
        address ledger = address(r.ledger);
        for (uint256 i; i < steps.length; ++i) {
            Vm.DebugStep memory s = steps[i];
            if (s.contractAddr != ledger || s.stack.length == 0) continue;
            if (s.opcode != 0x51 && s.opcode != 0x52) continue; // MLOAD, MSTORE
            uint256 top = s.stack[0] + 32;
            if (top > peak && s.stack[0] < 1 << 32) peak = top;
        }
    }

    /// Runs only with Foundry's debug tracer and a raised gas limit (`forge test --match-test test_growth_memory_trace -vvv --gas-limit 100000000000`: the decoded trace is large); without it the
    /// test is skipped.
    function test_growth_memory_trace() public {
        uint256 p2 = _peakMemory(2);
        if (p2 == 0) {
            vm.skip(true);
            return;
        }
        uint256 p8 = _peakMemory(8);
        uint256 perAction = (p8 - p2) / 6 / 32;
        emit log_named_uint("growth memory trace peak bytes, 2 creates", p2);
        emit log_named_uint("growth memory trace peak bytes, 8 creates", p8);
        emit log_named_uint("growth memory trace words per action", perAction);
        assertGe(perAction, 100, "the kernel's memory grows by at least 100 words an action");
        assertLe(perAction, 300, "and by at most 300");
    }
}
