// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {FloorBase} from "./FloorBase.sol";
import {KernelDeploy} from "../harness/KernelDeploy.sol";
import {EfsFiles} from "../../src/lib/EfsFiles.sol";
import {EfsTopics} from "../../src/lib/EfsTopics.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {Action, Native, Purpose} from "../../src/interfaces/Actions.sol";
import {Effect, Unit} from "../../src/interfaces/Index.sol";
import {IIndexHook} from "../../src/interfaces/IIndexHook.sol";
import {IRealmIndex} from "../../src/interfaces/IRealmIndex.sol";
import {E_INDEX_GAS} from "../../src/interfaces/Errors.sol";

/// @notice Docs INDEX-BUILD §10 (step 4), part E: generation 1's prefix quote against what a create-file recipe's index
///         callbacks spend, in the three states the repository measures it in, and what a quote below the spend can
///         and cannot do.
///
///         The kernel's rule (`LedgerCore._notifyIndex`, `LedgerIngress.dispatchIndex`, `_ack`; design §6.4, §6.5):
///         before each `onAdmission` it requires (gasleft − F − T)·63/64·63/64 ≥ the remaining prefix floor
///         (P less what the earlier callbacks of the publication spent, never below 0), then calls the index with
///         everything it has; a callback that fails with empty returndata (out of gas) is `E_INDEX_GAS`, any other
///         failure `E_INDEX_CALL` / `E_INDEX_ACK` / `E_INDEX_RETURNDATA`, and every one of them reverts the whole
///         publication (design §6.6). The final phase the same with F. So the floor is a check that refuses early,
///         never a cap: a quote below the spend can only let a transaction that is too small pass the early check
///         and then fail inside a callback with the same named error, consuming nothing.
///
///         Step 4 measured the one quote below the spend: on amsterdam, in state B (the author already has files in
///         the folder), 0.969× with `floorRewriteGas` 5,000. Since the Glamsterdam floor prices a rewrite at 12,100
///         (docs/GAS-SCHEDULES.md) every state is covered on both schedules, and this suite asserts it: P / spend ≥ 1
///         in A (one recipe and the planned batch) and B, and on both schedules the planned batch and one recipe in
///         state A are admitted with exactly the plan (plus, on amsterdam, the state gas). Relation to
///         `FloorStates.t.sol`: that suite asserts the same P / spend ≥ 1 rule over every shape the floor claims, the
///         create-file recipe in both states among them (the same recipe, the same state B, so the one-recipe ratios
///         agree); this one keeps the create-file recipe's per-leaf split, the slot counts, the least gas that admits
///         it against the plan, and the sweep below the least.
///
///         "Prefix spend" here is `FloorBase`'s: E − K − the final phase (K = the publication with both callbacks
///         mocked, so K still pays each mocked call's dispatch, encoding and CALL). It is split per leaf by mocking
///         the callbacks of leaves ≥ i (and the final call): spend_i = M(i+1) − M(i), M(0) = K, M(n) = E − final.
contract FloorReconcileTest is FloorBase {
    EfsTopics.Types internal tt;
    string internal json;
    address internal bob = makeAddr("reconcile/bob");
    address internal carol = makeAddr("reconcile/carol");

    function setUp() public virtual override {
        super.setUp();
        tt = _topicTypes();
        // FloorPlan.t.sol's setUp: one registered word (this principal has written twice before the measured one)
        (Action[] memory a, bytes[] memory b,) = EfsTopics.registerWord(tt, bytes("floor-plan"));
        _execAs(address(this), a, b);
        json = vm.readFile("test/vectors/floor-plan.json");
    }

    // ---- recipes -------------------------------------------------------------------------------------------------

    function _ft() internal view returns (EfsFiles.Types memory t) {
        t = EfsFiles.Types({
            root: typeIds[T_ROOT],
            child: typeIds[T_CHILD],
            directory: typeIds[T_DIRECTORY],
            name: typeIds[T_NAME],
            bytes_: typeIds[T_BYTES],
            content: typeIds[T_CONTENT],
            external_: typeIds[T_EXTERNAL],
            alias_: typeIds[T_ALIAS],
            notice: typeIds[T_NOTICE],
            span: typeIds[T_SPAN]
        });
    }

    /// FloorPlan.t.sol's create-file recipes (`test_plan_create_files`): n files into the root, a 10-byte name and an
    /// 18-byte document each, salts `keccak(abi.encode(seed, i))`.
    function _recipes(string memory seed, uint256 n)
        internal
        view
        returns (Action[] memory a, bytes[] memory b)
    {
        a = new Action[](n * 5);
        b = new bytes[](n * 5);
        for (uint256 i; i < n; ++i) {
            bytes memory name = bytes.concat(
                "f", bytes1(uint8(97 + (i / 26) % 26)), bytes1(uint8(97 + i % 26)), "-doc.md"
            );
            (Action[] memory x, bytes[] memory y,,) = EfsFiles.createFile(
                _ft(), p, rootDir, keccak256(abi.encode(seed, i)), name, "Meeting at 10:00.\n", true
            );
            for (uint256 j; j < 5; ++j) {
                (a[i * 5 + j], b[i * 5 + j]) = (x[j], y[j]);
            }
        }
    }

    function _home(address who) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(who)));
    }

    function _newFile(address who, string memory name) internal returns (bytes32 f, bytes32 root) {
        Action[] memory a;
        bytes[] memory b;
        bytes32 pid = who == address(this) ? p : Keys.principal(who);
        (a, b, f, root) = EfsFiles.createFile(
            _ft(),
            pid,
            who == address(this) ? rootDir : _home(who),
            keccak256(bytes(name)),
            bytes(name),
            bytes(name),
            true
        );
        _execAs(who, a, b);
    }

    function _one(Action memory x) internal pure returns (Action[] memory a) {
        a = new Action[](1);
        a[0] = x;
    }

    /// `test/index/HeadAuthorsFloor.t.sol::test_head_shapes`'s state before its "create file": bob's and carol's
    /// files in their homes, bob's version of carol's, this principal's `mine.txt` and `masked.txt` in the root (the
    /// second masked).
    function _headFloorState() internal {
        _newFile(bob, "bob.txt");
        (bytes32 g, bytes32 gRoot) = _newFile(carol, "carol.txt");
        _execAs(bob, _one(EfsFiles.bind(Purpose.HEAD, g, 0, gRoot, 0)), new bytes[](1));
        _newFile(address(this), "mine.txt");
        (bytes32 k,) = _newFile(address(this), "masked.txt");
        (, uint64 rev,,,,,,) = r.hot.head(Keys.binding(p, Keys.position(Purpose.HEAD, k, 0)));
        _execAs(address(this), _one(EfsFiles.unbind(Purpose.HEAD, k, 0, rev)), new bytes[](1));
    }

    // ---- measurement ---------------------------------------------------------------------------------------------

    struct Split {
        Need w;
        uint256 finalPhase;
        uint256 spend; // E − K − final phase
        uint256[] perLeaf; // spend_i
        uint256 freshIndexSlots; // index-side slots that went 0 → nonzero
        uint256 rewrittenIndexSlots; // index-side slots that were nonzero and changed
        string label;
    }

    /// The onAdmission calldata prefix of leaf `leaf` (kind `kind`) of publication `pub`: selector, publication, the
    /// two offsets, the effects length 1, then the effect's first two words (kind, leaf).
    function _leafPrefix(uint64 pub, uint8 kind, uint256 leaf)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(
            IRealmIndex.onAdmission.selector,
            uint256(pub),
            uint256(0x60),
            uint256(0x380),
            uint256(1),
            uint256(kind),
            leaf
        );
    }

    /// Execution gas of `a` from the cooled current state with the callbacks of leaves ≥ `from` and the final call
    /// mocked. Leaves the state as it found it.
    function _mockedFrom(Action[] memory a, bytes[] memory b, uint256 from)
        internal
        returns (uint256 exec)
    {
        Native memory c = _ctx(a);
        (,,, uint64 pubs) = r.hot.counts();
        uint256 snap = vm.snapshotState();
        address index = address(r.g.index);
        for (uint256 i = from; i < a.length; ++i) {
            vm.mockCall(
                index,
                _leafPrefix(pubs + 1, a[i].kind, i),
                abi.encode(IRealmIndex.onAdmission.selector)
            );
        }
        vm.mockCall(
            index,
            abi.encodeWithSelector(IRealmIndex.afterPublication.selector),
            abi.encode(IRealmIndex.afterPublication.selector)
        );
        _coolRealm();
        r.ledger.execute(a, b, c, "");
        exec = vm.lastFrameGas().gasTotalUsed;
        vm.clearMockedCalls();
        vm.revertToStateAndDelete(snap);
    }

    function _indexSide(address account) internal view returns (bool) {
        return account == address(r.g.index) || account == address(r.g.posting)
            || account == address(r.g.bitmap);
    }

    /// Index-side slots written by `a` (fresh: zero before, nonzero after; rewritten: nonzero before and changed).
    function _slots(Action[] memory a, bytes[] memory b)
        internal
        returns (uint256 fresh, uint256 rewritten)
    {
        Native memory c = _ctx(a);
        uint256 snap = vm.snapshotState();
        _coolRealm();
        vm.startStateDiffRecording();
        r.ledger.execute(a, b, c, "");
        Vm.AccountAccess[] memory d = vm.stopAndReturnStateDiff();
        vm.revertToStateAndDelete(snap);
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
                if (!s.isWrite || s.reverted || !_indexSide(s.account)) continue;
                bytes32 k = keccak256(abi.encode(s.account, s.slot));
                uint256 idx = m;
                for (uint256 q; q < m; ++q) {
                    if (keys[q] == k) idx = q;
                }
                if (idx == m) {
                    keys[m] = k;
                    first[m] = s.previousValue;
                    ++m;
                }
                last[idx] = s.newValue;
            }
        }
        for (uint256 q; q < m; ++q) {
            if (first[q] == 0 && last[q] != 0) ++fresh;
            else if (first[q] != 0 && last[q] != first[q]) ++rewritten;
        }
    }

    function _split(string memory label, Action[] memory a, bytes[] memory b, bool perLeaf)
        internal
        returns (Split memory s)
    {
        s.w = _need(a, b, address(0));
        s.finalPhase = _finalPhase(a, b, s.w.exec);
        s.spend = s.w.exec - s.w.kernel - s.finalPhase;
        (s.freshIndexSlots, s.rewrittenIndexSlots) = _slots(a, b);
        s.label = label;
        if (!perLeaf) return s;
        s.perLeaf = new uint256[](a.length);
        uint256 prev = s.w.kernel;
        for (uint256 i; i < a.length; ++i) {
            uint256 m = i + 1 == a.length ? s.w.exec - s.finalPhase : _mockedFrom(a, b, i + 1);
            s.perLeaf[i] = m - prev;
            prev = m;
        }
    }

    /// Logged at the end of a test: a snapshot revert drops the logs emitted before it.
    function _report(Split memory s) internal {
        string memory label = s.label;
        _log(label, s.w);
        emit log_named_uint(string.concat("floor ", label, " final phase"), s.finalPhase);
        emit log_named_uint(string.concat("floor ", label, " prefix spend"), s.spend);
        emit log_named_uint(
            string.concat("floor ", label, " P / spend (x1000)"),
            uint256(s.w.prefixFloor) * 1000 / s.spend
        );
        emit log_named_uint(
            string.concat("floor ", label, " fresh index slots written"), s.freshIndexSlots
        );
        emit log_named_uint(
            string.concat("floor ", label, " index slots rewritten"), s.rewrittenIndexSlots
        );
        emit log_named_uint(string.concat("floor ", label, " fresh quoted"), s.w.fresh);
        emit log_named_uint(string.concat("floor ", label, " rewrites quoted"), s.w.rewrites);
        for (uint256 i; i < s.perLeaf.length; ++i) {
            emit log_named_uint(
                string.concat("floor ", label, " callback spend, leaf ", vm.toString(i)),
                s.perLeaf[i]
            );
        }
    }

    // ---- 1. the figure in three states ---------------------------------------------------------------------------

    /// The ratio of generation 1's prefix quote to a create-file recipe's prefix spend in (A) FloorPlan's state, one
    /// recipe and the planned batch k; (B) HeadAuthorsFloor's state (this principal already has two files in the
    /// root); with the slots each writes, and the spend per leaf for one recipe.
    function test_create_file_quote_against_spend() public {
        uint256 snap = vm.snapshotState();
        (Action[] memory a, bytes[] memory b) = _recipes("floor-plan file", 1);
        Split memory a1 = _split("A: FloorPlan state, 1 recipe", a, b, true);
        uint256 k = vm.parseJsonUint(
            json,
            string.concat(".schedules.", _amsterdam() ? "amsterdam" : "prague", ".createFiles.k")
        );
        (a, b) = _recipes("floor-plan file", k);
        Split memory ak = _split("A: FloorPlan state, k recipes", a, b, false);
        assertEq(ak.w.prefixFloor, vm.parseJsonUint(json, _vec("createFiles.prefixFloor")));
        vm.revertToState(snap);
        _headFloorState();
        (a, b,,) = EfsFiles.createFile(
            _ft(), p, rootDir, keccak256("new.txt"), "new.txt", "new.txt", true
        );
        Split memory h = _split("B: HeadAuthorsFloor state, 1 recipe", a, b, true);
        _report(a1);
        _report(ak);
        _report(h);
        // what the quote covers, in thousandths, for the report
        emit log_named_uint("ratio A1 x1000", uint256(a1.w.prefixFloor) * 1000 / a1.spend);
        emit log_named_uint("ratio Ak x1000", uint256(ak.w.prefixFloor) * 1000 / ak.spend);
        emit log_named_uint("ratio B1 x1000", uint256(h.w.prefixFloor) * 1000 / h.spend);
        // the fixed behavior (measured: prague 1.104 / 1.280 / 1.486, amsterdam 1.437 / 1.697 / 1.259; B on amsterdam
        // was 0.969 with a rewrite priced at 5,000): the quote covers the spend in every state on both schedules
        assertGe(
            uint256(a1.w.prefixFloor) * 1000 / a1.spend, 1000, "A, 1 recipe: P covers the spend"
        );
        assertGe(
            uint256(ak.w.prefixFloor) * 1000 / ak.spend, 1000, "A, k recipes: P covers the spend"
        );
        assertGe(uint256(h.w.prefixFloor) * 1000 / h.spend, 1000, "B, 1 recipe: P covers the spend");
    }

    function _vec(string memory field) internal view returns (string memory) {
        return string.concat(".schedules.", _amsterdam() ? "amsterdam" : "prague", ".", field);
    }

    // ---- 2. with the planned gas, can it fail? --------------------------------------------------------------------

    /// Runs `a` with exactly `gas_` of execution gas from the cooled state; returns the revert data (empty = admitted)
    /// and leaves the state as it found it.
    function _tryWith(Action[] memory a, bytes[] memory b, uint256 gas_)
        internal
        returns (bool ok, bytes memory err)
    {
        Native memory c = _ctx(a);
        uint256 snap = vm.snapshotState();
        _coolRealm();
        try r.ledger.execute{gas: gas_}(a, b, c, "") {
            ok = true;
        } catch (bytes memory e) {
            err = e;
        }
        vm.revertToStateAndDelete(snap);
    }

    /// The smallest execution gas (to 1 gas) with which `a` is admitted from the cooled current state, and the error
    /// one gas below it.
    function _minimum(Action[] memory a, bytes[] memory b, uint256 lo, uint256 hi)
        internal
        returns (uint256 least, bytes memory below)
    {
        (bool ok,) = _tryWith(a, b, hi);
        require(ok, "the upper bound must admit");
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            (ok,) = _tryWith(a, b, mid);
            if (ok) hi = mid;
            else lo = mid;
        }
        least = hi;
        (, below) = _tryWith(a, b, hi - 1);
    }

    /// The planned gas for the shape at k (gas/model.json through tools/gas-plan.mjs: max(E, V), the model's own E
    /// and V) and one recipe (V from the measured E and K and the kernel's own quote, as FloorPlan.t.sol does), against
    /// the least gas that admits it. On prague that is the chain's condition exactly. On Foundry's amsterdam profile
    /// state gas is drawn from the same gas (no reservoir), which is the chain's condition for a transaction whose
    /// gas limit is at most 2^24 (EIP-8037 gives such a transaction no reservoir); the measured minimum less the state
    /// gas is then the execution part, compared with the plan.
    function test_planned_gas_admits_create_files() public {
        uint256 k = vm.parseJsonUint(json, _vec("createFiles.k"));
        uint256 planE = vm.parseJsonUint(json, _vec("createFiles.E"));
        uint256 planV = vm.parseJsonUint(json, _vec("createFiles.V"));
        uint256 planK = planE > planV ? planE : planV;
        uint256 snap = vm.snapshotState();
        Planned[4] memory x;
        x[0] = _planned("A, k recipes", k, planK, true);
        x[1] = _planned("A, 1 recipe", 1, 0, true);
        vm.revertToState(snap);
        _headFloorState();
        x[2] = _planned("B, k recipes", k, planK, false);
        x[3] = _planned("B, 1 recipe", 1, 0, false);
        for (uint256 i; i < 4; ++i) {
            _reportPlanned(x[i]);
        }
    }

    struct Planned {
        string label;
        uint256 plan; // max(E, V) of the plan (the model's for k; from the measured E, K and the kernel's quote for 1)
        uint256 exec;
        uint256 visible;
        uint256 state;
        uint256 least;
        uint256 prefixFloor;
        uint256 spend;
        bytes below;
        bool atPlan;
        bool atHeadroom;
    }

    /// With `plan` 0 the plan is max(E, V) from the measured E and K and the kernel's quote (as FloorPlan.t.sol
    /// computes V); the publication is run with exactly the plan, and with the plan and the 15% headroom (plan / 0.85),
    /// each plus the state gas on amsterdam (Foundry draws it from the same gas).
    function _planned(string memory label, uint256 n, uint256 plan, bool mustFit)
        internal
        returns (Planned memory x)
    {
        (Action[] memory a, bytes[] memory b) = _recipes("floor-plan file", n);
        Need memory w = _need(a, b, address(0));
        x.label = label;
        x.plan = plan != 0 ? plan : (w.visible > w.exec ? w.visible : w.exec);
        x.exec = w.exec;
        x.visible = w.visible;
        x.state = w.state > 0 ? uint256(w.state) : 0;
        x.prefixFloor = w.prefixFloor;
        x.spend = w.exec - w.kernel - _finalPhase(a, b, w.exec);
        (x.least, x.below) = _minimum(a, b, w.exec / 2, x.plan + x.state + 3_000_000);
        (x.atPlan,) = _tryWith(a, b, x.plan + x.state);
        (x.atHeadroom,) = _tryWith(a, b, x.plan * 100 / 85 + x.state);
        // one gas below the least: refused by the floor or by running out, never admitted and never another error
        assertTrue(
            x.below.length == 0 || bytes4(x.below) == E_INDEX_GAS.selector,
            "too little gas is E_INDEX_GAS or out of gas"
        );
        assertTrue(x.atHeadroom, string.concat(label, ": admitted with the plan and its headroom"));
        // exactly the plan admits it: on prague (no state gas) the plan alone; on amsterdam the plan is execution gas
        // and the transaction also carries the state gas, drawn by Foundry from the same gas. Before the Glamsterdam
        // rewrite price one recipe sent with exactly plan + state gas was refused on amsterdam in both states
        // (24,277 and 14,144 short); with it, 114,791 (A) and 78,791 (B) to spare (measured, see the report).
        if (mustFit) {
            assertTrue(x.atPlan, string.concat(label, ": admitted with exactly the planned gas"));
        }
    }

    function _reportPlanned(Planned memory x) internal {
        string memory l = x.label;
        emit log_named_uint(string.concat(l, ": planned max(E, V)"), x.plan);
        emit log_named_uint(string.concat(l, ": measured E"), x.exec);
        emit log_named_uint(string.concat(l, ": measured V"), x.visible);
        emit log_named_uint(string.concat(l, ": state gas"), x.state);
        emit log_named_uint(string.concat(l, ": prefix floor P"), x.prefixFloor);
        emit log_named_uint(string.concat(l, ": prefix spend"), x.spend);
        _reportPlanned2(x);
    }

    function _reportPlanned2(Planned memory x) internal {
        string memory l = x.label;
        emit log_named_uint(string.concat(l, ": least gas admitted"), x.least);
        emit log_named_uint(
            string.concat(l, ": least gas admitted, less state gas"), x.least - x.state
        );
        emit log_named_int(
            string.concat(l, ": margin plan - (least - state)"),
            int256(x.plan) - int256(x.least - x.state)
        );
        emit log_named_int(
            string.concat(l, ": least - (plan + state)"), int256(x.least) - int256(x.plan + x.state)
        );
        emit log_named_bytes(string.concat(l, ": error one gas below"), x.below);
        emit log_named_string(
            string.concat(l, ": admitted with exactly the plan"), x.atPlan ? "yes" : "NO"
        );
        emit log_named_string(
            string.concat(l, ": admitted with the plan and headroom"), x.atHeadroom ? "yes" : "NO"
        );
    }

    // ---- 3. a callback that runs out admits nothing -----------------------------------------------------------------

    /// One gas below the least that admits a create-file recipe, in both states: the publication is refused (with
    /// `E_INDEX_GAS` when the floor or a callback ran out, or by running out in the kernel, empty), and nothing is
    /// admitted. `E_INDEX_GAS(quoted, available)` with available ≥ quoted means every floor check passed and a
    /// callback then ran out (the `_ack` path); available < quoted, the early check.
    function test_a_callback_that_runs_out_admits_nothing() public {
        uint256 snap = vm.snapshotState();
        uint256[4] memory x = _below();
        vm.revertToState(snap);
        _headFloorState();
        uint256[4] memory y = _below();
        _logBelow("A", x);
        _logBelow("B", y);
    }

    function _logBelow(string memory label, uint256[4] memory x) internal {
        emit log_named_uint(string.concat(label, ": least gas admitted"), x[0]);
        emit log_named_uint(string.concat(label, ": refusals after every floor check passed"), x[1]);
        emit log_named_uint(string.concat(label, ": refusals by the early floor check"), x[2]);
        emit log_named_uint(
            string.concat(label, ": refusals out of gas in the kernel (empty)"), x[3]
        );
    }

    /// [least, refusals after the checks passed, early refusals, empty refusals], 2,000 gas below the least.
    function _below() internal returns (uint256[4] memory x) {
        (Action[] memory a, bytes[] memory b) = _recipes("floor-plan file", 1);
        Need memory w = _need(a, b, address(0));
        (uint256 least,) = _minimum(
            a, b, w.exec / 2, w.visible + uint256(w.state > 0 ? w.state : int256(0)) + 1_000_000
        );
        (uint64 adm0,,, uint64 pub0) = r.hot.counts();
        (uint64 nonce0,) = r.hot.nonceOf(p);
        // every gas from 2,000 below the least to one below it: refused, and only so
        uint256 inside;
        uint256 early;
        uint256 empty;
        for (uint256 g = least - 2_000; g < least; g += 50) {
            (bool ok, bytes memory err) = _tryWith(a, b, g);
            assertFalse(ok, "refused below the least");
            if (err.length == 0) {
                ++empty;
                continue;
            }
            assertEq(bytes4(err), E_INDEX_GAS.selector, "E_INDEX_GAS");
            (uint32 quoted, uint32 available) = abi.decode(_tail(err), (uint32, uint32));
            if (available >= quoted) ++inside;
            else ++early;
        }
        (uint64 adm1,,, uint64 pub1) = r.hot.counts();
        (uint64 nonce1,) = r.hot.nonceOf(p);
        assertEq(abi.encode(adm0, pub0, nonce0), abi.encode(adm1, pub1, nonce1), "nothing admitted");
        x = [least, inside, early, empty];
    }

    function _tail(bytes memory err) internal pure returns (bytes memory t) {
        t = new bytes(err.length - 4);
        for (uint256 i; i < t.length; ++i) {
            t[i] = err[i + 4];
        }
    }
}

/// A unit hook that, once armed, spends everything it is given (fold and validate): it runs out of gas.
contract BurningHook is IIndexHook {
    bool public armed;

    function arm() external {
        armed = true;
    }

    function fold(Effect calldata, bytes32[] calldata, uint64) external view returns (bytes4) {
        while (armed && gasleft() != 0) {}
        return IIndexHook.fold.selector;
    }

    function validate(uint64, Effect[] calldata, bytes32[] calldata)
        external
        view
        returns (bytes4)
    {
        while (armed && gasleft() != 0) {}
        return IIndexHook.validate.selector;
    }
}

/// Part E, item 1 of the integration owner's addition: a unit's fold hook (in a prefix callback) or final hook (in
/// the final phase) that runs out of gas refuses the whole publication with `E_INDEX_GAS`; nothing is admitted.
abstract contract BurningHookBase is FloorBase {
    BurningHook internal burner;

    function _fold() internal pure virtual returns (bool);

    function setUp() public override {
        burner = new BurningHook();
        super.setUp();
    }

    function _units() internal view override returns (Unit[] memory u) {
        Unit[] memory base = super._units();
        u = new Unit[](base.length + 1);
        for (uint256 i; i < base.length; ++i) {
            u[i] = base[i];
        }
        u[base.length] = Unit({
            foldHook: _fold() ? address(burner) : address(0),
            foldCodehash: _fold() ? address(burner).codehash : bytes32(0),
            finalHook: _fold() ? address(0) : address(burner),
            finalCodehash: _fold() ? bytes32(0) : address(burner).codehash,
            familyIds: new bytes32[](0),
            purposeFilter: Purpose.HEAD,
            hotAbiId: KernelDeploy.HOT_ABI_ID,
            identity: keccak256("test/unit/burning-hook")
        });
    }

    function test_a_hook_that_runs_out_admits_nothing() public {
        burner.arm();
        bytes32 file = Keys.subject(p, keccak256("burn.txt"));
        Action[] memory a = new Action[](3);
        bytes[] memory b = new bytes[](3);
        a[0] = _create(keccak256("burn.txt"));
        (a[1], b[1]) = _publish(T_ROOT, abi.encodePacked(abi.encode(file, uint256(0)), "burn.txt"));
        a[2] = _bind(Purpose.HEAD, file, 0, _id(T_ROOT, b[1]), 0);
        Native memory c = _ctx(a);
        (uint64 adm0,,, uint64 pub0) = r.hot.counts();
        (uint64 nonce0,) = r.hot.nonceOf(p);
        // on amsterdam Foundry draws state gas from the same gas, so the publication needs more to reach the hook
        uint256[3] memory gases = _amsterdam()
            ? [uint256(20_000_000), 60_000_000, 200_000_000]
            : [uint256(3_000_000), 10_000_000, 30_000_000];
        for (uint256 i; i < gases.length; ++i) {
            try r.ledger.execute{gas: gases[i]}(a, b, c, "") {
                revert("admitted with a hook that ran out");
            } catch (bytes memory err) {
                assertEq(bytes4(err), E_INDEX_GAS.selector, "a hook out of gas is E_INDEX_GAS");
                emit log_named_bytes("refused with", err);
            }
        }
        (uint64 adm1,,, uint64 pub1) = r.hot.counts();
        (uint64 nonce1,) = r.hot.nonceOf(p);
        assertEq(abi.encode(adm0, pub0, nonce0), abi.encode(adm1, pub1, nonce1), "nothing admitted");
    }
}

contract BurningFoldHookTest is BurningHookBase {
    function _fold() internal pure override returns (bool) {
        return true;
    }
}

contract BurningFinalHookTest is BurningHookBase {
    function _fold() internal pure override returns (bool) {
        return false;
    }
}
