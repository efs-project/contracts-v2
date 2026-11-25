// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {FilesRecipesBase} from "./FilesRecipesBase.sol";
import {Action, ActionKind, Native} from "../../src/interfaces/Actions.sol";
import {ILedger} from "../../src/interfaces/ILedger.sol";
import {IRealmIndex} from "../../src/interfaces/IRealmIndex.sol";
import {E_INDEX_GAS} from "../../src/interfaces/Errors.sol";
import {ILedgerCommitments} from "../../src/interfaces/ILedgerCommitments.sol";

/// @notice What the kernel's availability floor (design §6.4, §6.5, §10.4) needs of a publication on a chain, measured:
///         its execution gas E, the kernel's own share K (the same publication from the same state with the index's
///         two callbacks answered by `vm.mockCall`), the kernel's quote (P, F) and the calldata the transaction carries.
///
///         The sufficient condition (gas/model.json `floor.formula`): with G = 2^24 − 21,000 − calldata of visible
///         execution gas, every floor check passes when G ≥ V = max(K + ceil((ceil(P·64/63) + D)·64/63), E) +
///         ceil(F·64/63) + T (D the ingress's dispatch overhead, T the kernel tail), and the publication runs when
///         G ≥ E. K errs high (the mocked run still pays each callback's dispatch, encoding and CALL), so the bound is
///         conservative.
///
///         What Foundry's amsterdam profile does NOT emulate: it has no state-gas reservoir and no 2^24 cap. State gas
///         is drawn from the call's own gas, so the GAS opcode inside the kernel sees state gas being spent, and a call
///         capped at 2^24 runs out where a chain would draw from the reservoir. On amsterdam the suites therefore run
///         publications with ample gas (they are admitted), take the measured execution gas (`gasTotalUsed`, which
///         excludes state gas) as the chain's capped dimension, and assert V ≤ G by arithmetic on the kernel's own
///         quote. On prague (the release schedule, no reservoir) the publication is also run with exactly G.
abstract contract FloorBase is FilesRecipesBase {
    uint256 internal constant CAP = 1 << 24;
    uint256 internal constant TX_BASE = 21_000;
    /// gas/model.json floor.dispatchOverhead and the Realm's kernel tail (KernelDeploy.s1Limits()).
    uint256 internal constant DISPATCH_OVERHEAD = 2_000;
    uint256 internal constant KERNEL_TAIL = 20_000;

    struct Need {
        uint32 prefixFloor; // the kernel's prepare quote (`_kernelPrefixFloor`)
        uint32 finalReserve; // ILedgerCommitments.indexFloor (exact: it does not depend on heads)
        uint32 fresh; // ILedgerCommitments.indexFloor (every bind priced as a first statement)
        uint32 rewrites; // ILedgerCommitments.indexFloor (every bind priced as a first statement)
        uint256 exec; // E: execution gas of the execute frame
        uint256 kernel; // K: the same with the callbacks mocked
        int256 state; // EIP-8037 state gas (amsterdam only)
        uint256 calldataGas; // the transaction's calldata at 4 / 16 gas per zero / nonzero byte
        uint256 visible; // V
        uint256 room; // G = 2^24 − 21,000 − calldata
    }

    function _amsterdam() internal view returns (bool) {
        return
            keccak256(bytes(vm.envOr("FOUNDRY_PROFILE", string("default"))))
                == keccak256("amsterdam");
    }

    /// Every account the Realm's publications touch, cooled so the measured publication pays the cold costs of a
    /// transaction of its own.
    function _coolRealm() internal {
        address[16] memory a = [
            r.k.proxy,
            address(r.k.implementation),
            address(r.k.ingress),
            address(r.k.applyDelegate),
            address(r.k.control),
            address(r.registry),
            address(r.registryImpl),
            address(r.store),
            address(r.g.index),
            address(r.g.posting),
            address(r.g.bitmap),
            address(r.g.reads),
            address(validator),
            refuseAll,
            address(0),
            address(0)
        ];
        for (uint256 i; i < a.length; ++i) {
            if (a[i] != address(0)) vm.cool(a[i]);
        }
        for (uint256 i; i < instances.length; ++i) {
            vm.cool(instances[i]);
        }
    }

    function _calldataGas(bytes memory data) internal pure returns (uint256 g) {
        for (uint256 i; i < data.length; ++i) {
            g += data[i] == 0 ? 4 : 16;
        }
    }

    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a + b - 1) / b;
    }

    /// V of gas/model.json `floor.formula`.
    function _visible(uint256 e, uint256 k, uint256 p_, uint256 f) internal pure returns (uint256) {
        uint256 prefix = k + _ceilDiv((_ceilDiv(p_ * 64, 63) + DISPATCH_OVERHEAD) * 64, 63);
        return (prefix > e ? prefix : e) + _ceilDiv(f * 64, 63) + KERNEL_TAIL;
    }

    /// The prefix floor the kernel's own `prepare` quoted for this publication (with the author's real heads): the
    /// `quoted` word of the `E_INDEX_GAS` the first callback's check reverts with when the publication is given just
    /// enough gas to reach it. (`ILedgerCommitments.indexFloor` quotes without a principal, so it prices every BIND and
    /// UNBIND as a first statement: an upper bound, exact only when every bind-kind action is one.) Leaves the state
    /// as it found it.
    function _kernelPrefixFloor(
        Action[] memory a,
        bytes[] memory b,
        Native memory c,
        address sender
    ) internal returns (uint32 quoted) {
        // In steps of 50k, and of 1k from the last refusal when a step jumps straight to admission. A publication
        // with no BIND or UNBIND may have no window at all: each PUBLISH and REUSE first requires its acceptor's
        // validation gas (300k by default) to be available, which can cover the floor's check before the callback
        // runs; its quote does not depend on heads, so `indexFloor` is then exact and is what the kernel quoted.
        uint256 step = 50_000;
        for (uint256 g = 50_000; g < 40_000_000; g += step) {
            uint256 snap = vm.snapshotState();
            _coolRealm();
            if (sender != address(0)) vm.prank(sender, sender);
            try r.ledger.execute{gas: g}(a, b, c, "") {
                vm.revertToStateAndDelete(snap);
                if (step == 1000) {
                    for (uint256 i; i < a.length; ++i) {
                        if (a[i].kind == ActionKind.BIND || a[i].kind == ActionKind.UNBIND) {
                            revert("admitted while probing the prefix floor");
                        }
                    }
                    (quoted,,,) =
                        ILedgerCommitments(r.hot.ingress()).indexFloor(address(r.ledger), a);
                    return quoted;
                }
                g -= step;
                step = 1000;
            } catch (bytes memory err) {
                vm.revertToStateAndDelete(snap);
                if (err.length == 68 && bytes4(err) == E_INDEX_GAS.selector) {
                    assembly ("memory-safe") {
                        quoted := mload(add(err, 36))
                    }
                    return quoted;
                }
            }
        }
        revert("no E_INDEX_GAS below 40M gas");
    }

    /// Measures `a` from the current state as principal `p` (sent by `sender`, address(0) = this contract) and leaves
    /// the state as it found it.
    function _need(Action[] memory a, bytes[] memory b, address sender)
        internal
        returns (Need memory w)
    {
        (w.prefixFloor, w.finalReserve, w.fresh, w.rewrites) =
            ILedgerCommitments(r.hot.ingress()).indexFloor(address(r.ledger), a);
        Native memory c = _ctx(a);
        w.prefixFloor = _kernelPrefixFloor(a, b, c, sender);
        w.calldataGas = _calldataGas(abi.encodeCall(ILedger.execute, (a, b, c, "")));
        w.room = CAP - TX_BASE - w.calldataGas;
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
        if (sender != address(0)) vm.prank(sender, sender);
        r.ledger.execute(a, b, c, "");
        w.kernel = vm.lastFrameGas().gasTotalUsed;
        vm.clearMockedCalls();
        vm.revertToState(snap);
        _coolRealm();
        if (sender != address(0)) vm.prank(sender, sender);
        r.ledger.execute(a, b, c, "");
        Vm.Gas memory f = vm.lastFrameGas();
        w.exec = f.gasTotalUsed;
        w.state = f.gasStateUsed;
        vm.revertToStateAndDelete(snap);
        w.visible = _visible(w.exec, w.kernel, w.prefixFloor, w.finalReserve);
    }

    /// The final phase's execution gas: the publication from the same cooled state with only `afterPublication`
    /// answered by `vm.mockCall`, subtracted from the real run (`exec`). The mocked call still pays its CALL and
    /// encoding, so this errs low by a few hundred gas. Leaves the state as it found it.
    function _finalPhase(Action[] memory a, bytes[] memory b, uint256 exec)
        internal
        returns (uint256)
    {
        Native memory c = _ctx(a);
        uint256 snap = vm.snapshotState();
        vm.mockCall(
            address(r.g.index),
            abi.encodeWithSelector(IRealmIndex.afterPublication.selector),
            abi.encode(IRealmIndex.afterPublication.selector)
        );
        _coolRealm();
        r.ledger.execute(a, b, c, "");
        uint256 without = vm.lastFrameGas().gasTotalUsed;
        vm.clearMockedCalls();
        vm.revertToStateAndDelete(snap);
        return exec - without;
    }

    function _log(string memory label, Need memory w) internal {
        emit log_named_uint(string.concat("floor ", label, " exec"), w.exec);
        emit log_named_uint(string.concat("floor ", label, " kernel"), w.kernel);
        emit log_named_int(string.concat("floor ", label, " state"), w.state);
        emit log_named_uint(string.concat("floor ", label, " prefixFloor"), w.prefixFloor);
        emit log_named_uint(string.concat("floor ", label, " finalReserve"), w.finalReserve);
        emit log_named_uint(string.concat("floor ", label, " visible needed"), w.visible);
        emit log_named_uint(string.concat("floor ", label, " room"), w.room);
    }
}
