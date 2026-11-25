// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {FloorBase} from "./FloorBase.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {EfsTopics} from "../../src/lib/EfsTopics.sol";
import {Action, Native, Purpose} from "../../src/interfaces/Actions.sol";
import {ILedgerCommitments} from "../../src/interfaces/ILedgerCommitments.sol";
import {E_INDEX_GAS} from "../../src/interfaces/Errors.sol";

/// @notice The kernel's availability floor against what the index really spends (design §6.4, §10.4), on the release
///         schedule and, under `FOUNDRY_PROFILE=amsterdam`, on EIP-8037/8038. The method is `FloorBase`'s: measure the
///         publication's execution gas E and the kernel's own share K (callbacks mocked) from the same cooled state,
///         take the kernel's quote (P, F), and assert the sufficient bound V = max(K + ceil((ceil(P·64/63) + D)·64/63),
///         E) + ceil(F·64/63) + T against the visible execution gas a transaction capped at 2^24 has after its
///         intrinsic cost and calldata. Foundry's amsterdam profile has no reservoir and no cap, so there the
///         publications run with ample gas and the chain condition is asserted by that arithmetic; the negative case
///         is direct on both profiles: a publication given clearly too little gas fails with the named `E_INDEX_GAS`
///         and admits nothing. `test/integration/FloorPlan.t.sol` proves the planning rule's largest publications.
contract IndexFloorTest is FloorBase {
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

    /// Logs the publication's need (`FloorBase._need`) and the index slots it makes fresh, then leaves the state as it
    /// found it.
    function _measure(string memory label, Action[] memory a, bytes[] memory b)
        internal
        returns (Need memory w)
    {
        w = _need(a, b, address(0));
        _log(label, w);
        uint256 snap = vm.snapshotState();
        Native memory c = _ctx(a);
        vm.startStateDiffRecording();
        r.ledger.execute(a, b, c, "");
        emit log_named_uint(
            string.concat("floor ", label, " fresh index slots"),
            _freshIndexSlots(vm.stopAndReturnStateDiff())
        );
        emit log_named_uint(string.concat("floor ", label, " fresh quoted"), w.fresh);
        emit log_named_uint(string.concat("floor ", label, " rewrites quoted"), w.rewrites);
        vm.revertToStateAndDelete(snap);
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

    // ---- the final phase's worst cases (design §6.5): the Files validator's final hook ------------------------------

    /// Logs the final phase's execution gas against the final reserve and returns both. These rows measure the final
    /// phase only: a 64-action publication of them need not fit one transaction (the planning rule splits it), and a
    /// final phase that spends more than the reserve is still paid for, since the rule's V includes E (the reserve is
    /// a floor of visibility, never a cap).
    function _final(string memory label, Action[] memory a, bytes[] memory b)
        internal
        returns (uint256 fin, uint256 reserve)
    {
        Need memory w = _need(a, b, address(0));
        _log(label, w);
        fin = _finalPhase(a, b, w.exec);
        reserve = w.finalReserve;
        emit log_named_uint(string.concat("floor ", label, " final phase"), fin);
    }

    /// 64 first masks ("not this") whose roles are 64 different created subjects: the validator's code-15 check reads
    /// the role as a record (none) and then the subject's creation, two cold ledger reads each.
    function test_floor_final_masks_on_subjects() public {
        Action[] memory c = new Action[](64);
        Action[] memory a = new Action[](64);
        for (uint256 i; i < 64; ++i) {
            bytes32 salt = keccak256(abi.encode("floor subject", i));
            c[i] = _create(salt);
            a[i] = EfsTopics.deny(topic, Keys.subject(p, salt), 0, 0);
        }
        _execAs(address(this), c, new bytes[](64));
        (uint256 fin, uint256 reserve) = _final("64 first masks on subjects", a, new bytes[](64));
        // the per-bind reserve is set for TAG statements about addresses and topics (design §10.4): a first mask
        // about a subject spends ≈ 15k in the final phase against ≈ 7.4k reserved, which only the planner's E covers
        assertGt(fin, reserve);
        assertLe(fin, 3 * reserve, "within three times the reserve");
    }

    /// 64 first masks whose roles are 64 different records: one cold ledger read each (the record header).
    function test_floor_final_masks_on_records() public {
        (Action[] memory w, bytes[] memory wb) = _wordPages(64, "mask-record-");
        _execAs(address(this), w, wb);
        Action[] memory a = new Action[](64);
        for (uint256 i; i < 64; ++i) {
            a[i] = EfsTopics.deny(topic, _id(T_TOPIC_WORD, wb[i]), 0, 0);
        }
        (uint256 fin, uint256 reserve) = _final("64 first masks on records", a, new bytes[](64));
        // ≈ 11k per first mask about a record against ≈ 7.4k reserved (see the subjects row)
        assertGt(fin, reserve);
        assertLe(fin, 2 * reserve, "within twice the reserve");
    }

    /// 64 first tags on 64 different registered topics: the subject law reads each topic's record header.
    function test_floor_final_tags_on_topics() public {
        (Action[] memory w, bytes[] memory wb) = _wordPages(64, "tag-topic-");
        _execAs(address(this), w, wb);
        Action[] memory a = new Action[](64);
        for (uint256 i; i < 64; ++i) {
            bytes32 thing = bytes32(uint256(uint160(uint256(keccak256(abi.encode("tt", i))))));
            a[i] = EfsTopics.tag(_id(T_TOPIC_WORD, wb[i]), thing, 0, 0);
        }
        (uint256 fin, uint256 reserve) = _final("64 first tags on topics", a, new bytes[](64));
        assertGt(fin, 0);
        assertGe(reserve, fin, "the final reserve covers first tags on distinct topics");
    }

    /// The common case: 64 lone negatives about addresses on one topic.
    function test_floor_final_lone_negatives() public {
        (Action[] memory a, bytes[] memory b) = _loneNegatives(64, 7);
        (uint256 fin, uint256 reserve) = _final("64 lone negatives", a, b);
        assertGe(reserve, fin, "the final reserve covers the common case");
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

    /// 64 lone negatives on a one-word topic, the action limit, in one publication. On Glamsterdam (amsterdam profile)
    /// the floor certifies them: V ≤ 2^24 − 21,000 − calldata, and they execute within it. On prague their execution
    /// gas alone is over the cap at 64 (the planning rule splits them there), so the test asserts only that.
    function test_sixty_four_lone_negatives_fit_the_cap() public {
        (Action[] memory a, bytes[] memory b) = _loneNegatives(64, 5);
        Need memory w = _need(a, b, address(0));
        _log("64 lone negatives (cap)", w);
        if (_amsterdam()) {
            assertLe(w.exec, w.room, "64 lone negatives execute within 2^24 execution gas");
            assertLe(
                w.visible, w.room, "the floor admits 64 lone negatives under 2^24 execution gas"
            );
        } else {
            assertGt(
                w.exec, w.room, "prague: 64 lone negatives are over the cap by execution gas alone"
            );
        }
    }

    /// A 64-action registration chunk (64 fresh word pages) is admitted, and fits the cap on both schedules.
    function test_sixty_four_word_pages_fit_the_cap() public {
        (Action[] memory a, bytes[] memory b) = _wordPages(64, "fit-");
        Need memory w = _need(a, b, address(0));
        _log("64 word pages (cap)", w);
        assertLe(w.exec, w.room, "a registration chunk executes within one transaction");
        assertLe(w.visible, w.room, "the floor admits a registration chunk in one transaction");
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
        // and nothing landed: the nonce is unspent and the same publication still runs in full afterwards
        (uint64 nonce,) = r.hot.nonceOf(p);
        assertEq(nonce, c.nonce, "the refused publication consumed nothing");
        this.execGas(a, b, c, 100_000_000);
    }
}
