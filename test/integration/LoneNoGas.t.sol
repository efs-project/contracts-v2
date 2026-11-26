// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FloorBase} from "./FloorBase.sol";
import {EfsFiles} from "../../src/lib/EfsFiles.sol";
import {EfsTopics} from "../../src/lib/EfsTopics.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {Action, Native, Purpose} from "../../src/interfaces/Actions.sol";
import {ILedger} from "../../src/interfaces/ILedger.sol";
import {IRealmIndex} from "../../src/interfaces/IRealmIndex.sol";

/// @notice Whole publications of a yes after a lone no (logged only: these labels start "lone no ", not "model ", so
///         tools/gas-model.mjs does not read them). Since the list release the gas model prices this shape with its own
///         rows (`bindTagAfterNo` and its tiers, gas/model.json `laterRows`), and GasModel.t.sol section 10 measures the
///         composites of 32 yeses across 48- and 256-entry lists, 16 across 1,025 and 32 at one topic of 1,025 inside the
///         stated maxima. The 51-statement batches (the largest restore batch of the formula-3 release) and the 32 at one
///         topic of 48 and 256 stay here, logged only: each 51 × 1,025 state is 52,275 lone noes, about a minute per
///         profile, too slow for the model's suite.
///
///         A yes after a lone no is a BIND that is the binding's 2nd statement on a head that never bound. Against a
///         restore (the 3rd statement: yes, mask, yes) it writes two more fresh slots per statement: one in the index
///         (`PostingStore._append` at count 1 materializes the binding's history word 0) and one on the kernel's side (the
///         head's stored target, written fresh). Compare a run with the `bindTagAfterNo` rows of gas/model.json by hand
///         (`fixed` plus each statement's `laterKey` constant; error = (predicted − measured) / measured).
///
///         Method as GasModel.t.sol's: the native lane through `FilesRecipesBase._exec` (label, `gas`, `frame gas`,
///         `frame state gas` under amsterdam), every Realm account cooled before the measured execute
///         (`FloorBase._coolRealm`), the kernel's own share logged as `<label> kernel frame gas`, the calldata of the
///         transaction as `<label> calldata gas` (4 / 16 gas per zero / nonzero byte). The worst realistic state: the
///         author's lists hold only lone noes (no live bit set, so every live-bits word is empty), the measured things
///         are file subjects (as the model's rows' are) and each has one backlink entry (a first yes at another topic),
///         so its yes writes the backlink list's word 0 too. Lists are built with gas metering paused.
///
///         Reproduce: `forge test --match-path test/integration/LoneNoGas.t.sol -vv` on each profile.
contract LoneNoGasTest is FloorBase {
    EfsTopics.Types internal tt;
    bool internal measuring; // false during setUp: its seed publication is not cooled (as in GasModel.t.sol)

    function setUp() public override {
        super.setUp();
        tt = _topicTypes();
        measuring = true;
    }

    function _beforeExecute() internal override {
        if (measuring) _coolRealm();
    }

    /// The kernel's own share (the index's two callbacks answered by `vm.mockCall`), as GasModel.t.sol logs it.
    function _beforeMeasure(
        string memory label,
        Action[] memory a,
        bytes[] memory b,
        Native memory c
    ) internal override {
        if (!measuring) return;
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
        emit log_named_uint(
            string.concat(label, " kernel frame gas"), vm.lastFrameGas().gasTotalUsed
        );
        vm.clearMockedCalls();
        vm.revertToStateAndDelete(snap);
    }

    function _salt(string memory seed, uint256 i) internal pure returns (bytes32) {
        return keccak256(abi.encode("lone-no-gas", seed, i));
    }

    function _filler(string memory seed, uint256 i, uint256 e) internal pure returns (bytes32) {
        return
            bytes32(uint256(uint160(uint256(keccak256(abi.encode("lone-no filler", seed, i, e))))));
    }

    function _sendIn(Action[] memory a, uint256 per) internal {
        for (uint256 from; from < a.length; from += per) {
            uint256 m = a.length - from < per ? a.length - from : per;
            Action[] memory x = new Action[](m);
            for (uint256 j; j < m; ++j) {
                x[j] = a[from + j];
            }
            _execAs(address(this), x, new bytes[](m));
        }
    }

    /// `n` registered one-word topics.
    function _topics(string memory seed, uint256 n) internal returns (bytes32[] memory t) {
        t = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            (Action[] memory a, bytes[] memory b, bytes32 id) =
                EfsTopics.registerWord(tt, bytes(string.concat(seed, vm.toString(i))));
            _execAs(address(this), a, b);
            t[i] = id;
        }
    }

    /// `k` new file subjects of p (the measured things), each then tagged yes once at one other topic.
    function _things(string memory seed, uint256 k) internal returns (bytes32[] memory th) {
        th = new bytes32[](k);
        Action[] memory a = new Action[](k);
        for (uint256 i; i < k; ++i) {
            a[i] = _create(_salt(seed, i));
            th[i] = Keys.subject(p, _salt(seed, i));
        }
        _sendIn(a, 64);
        bytes32 o = _topics(string.concat(seed, "o-"), 1)[0];
        for (uint256 i; i < k; ++i) {
            a[i] = _bind(Purpose.TAG, o, th[i], th[i], 0);
        }
        _sendIn(a, 64);
    }

    /// The yes (revision 1, after the lone no) about each (tp[i], th[i]), measured as "lone no <what>".
    function _yeses(string memory what, bytes32[] memory tp, bytes32[] memory th) internal {
        Action[] memory a = new Action[](tp.length);
        for (uint256 i; i < tp.length; ++i) {
            a[i] = _bind(Purpose.TAG, tp[i], th[i], th[i], 1);
        }
        bytes[] memory b = new bytes[](tp.length);
        string memory label = string.concat("lone no ", what);
        emit log_named_uint(
            string.concat(label, " calldata gas"),
            _calldataGas(abi.encodeCall(ILedger.execute, (a, b, _ctx(a), "")))
        );
        _exec(label, a, b);
    }

    /// `k` topics, the author's list at each holding `len` lone noes; the last (entry len − 1) about th[i].
    function _across(string memory seed, uint256 k, uint256 len) internal {
        vm.pauseGasMetering();
        bytes32[] memory t = _topics(seed, k);
        bytes32[] memory th = _things(seed, k);
        for (uint256 i; i < k; ++i) {
            Action[] memory f = new Action[](len);
            for (uint256 e; e < len; ++e) {
                f[e] = EfsFiles.loneNegative(
                    Purpose.TAG, t[i], e == len - 1 ? th[i] : _filler(seed, i, e), 0
                );
            }
            _sendIn(f, 64);
        }
        vm.resumeGasMetering();
        _yeses(
            string.concat("yeses across ", vm.toString(k), " topics of ", vm.toString(len)), t, th
        );
    }

    /// One topic whose author's list holds `len` lone noes; `k` of them, spread (entries len − 1 − (k − 1 − j)·step,
    /// step ⌊(len − 1) / k⌋), about th[j].
    function _one(string memory seed, uint256 k, uint256 len) internal {
        vm.pauseGasMetering();
        bytes32 t = _topics(seed, 1)[0];
        bytes32[] memory th = _things(seed, k);
        uint256 step = (len - 1) / k;
        uint256 e0 = len - 1 - (k - 1) * step;
        Action[] memory f = new Action[](len);
        for (uint256 e; e < len; ++e) {
            bool m = e >= e0 && (e - e0) % step == 0;
            f[e] = EfsFiles.loneNegative(
                Purpose.TAG, t, m ? th[(e - e0) / step] : _filler(seed, 0, e), 0
            );
        }
        _sendIn(f, 64);
        bytes32[] memory tp = new bytes32[](k);
        for (uint256 j; j < k; ++j) {
            tp[j] = t;
        }
        vm.resumeGasMetering();
        _yeses(
            string.concat(
                "yeses of ", vm.toString(k), " entries of ", vm.toString(len), " at one topic"
            ),
            tp,
            th
        );
    }

    // the composites' sizes of GasModel.t.sol sections 8 and 9b: 32 across places in short lists, 16 at 1,025, 32 at one
    // topic; and 51, the largest planned batch of tag restores (test/vectors/floor-plan.json `tagRestores`)

    function test_lone_no_across_48() public {
        _across("na48-", 32, 48);
    }

    function test_lone_no_one_48() public {
        _one("no48-", 32, 48);
    }

    function test_lone_no_across_256() public {
        _across("na256-", 32, 256);
    }

    function test_lone_no_one_256() public {
        _one("no256-", 32, 256);
    }

    function test_lone_no_across_1025() public {
        _across("na1k-", 16, 1025);
    }

    function test_lone_no_one_1025() public {
        _one("no1k-", 32, 1025);
    }

    function test_lone_no_across_1025_full() public {
        _across("na1kf-", 51, 1025);
    }

    function test_lone_no_one_1025_full() public {
        _one("no1kf-", 51, 1025);
    }
}
