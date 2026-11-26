// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {FloorBase} from "./FloorBase.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {EfsTopics} from "../../src/lib/EfsTopics.sol";
import {Action, ActionKind, Native, Purpose} from "../../src/interfaces/Actions.sol";
import {EfsFiles} from "../../src/lib/EfsFiles.sol";
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

    /// 64 first "not this" statements at HEAD about 64 different created files (code 16): the validator reads each
    /// subject's creation, one cold ledger read each.
    function test_floor_final_head_masks_on_files() public {
        Action[] memory c = new Action[](64);
        Action[] memory a = new Action[](64);
        for (uint256 i; i < 64; ++i) {
            bytes32 salt = keccak256(abi.encode("floor head file", i));
            c[i] = _create(salt);
            a[i] = EfsFiles.loneNegative(Purpose.HEAD, Keys.subject(p, salt), 0, 0);
        }
        _execAs(address(this), c, new bytes[](64));
        (uint256 fin, uint256 reserve) = _final("64 first HEAD masks on files", a, new bytes[](64));
        emit log_named_uint(
            "floor 64 first HEAD masks on files final phase per mille of reserve",
            fin * 1000 / reserve
        );
        // ≈ 7.2k per mask against ≈ 7.7k reserved on both schedules (93%): the reserve covers it
        assertGt(fin, 0);
        assertGe(reserve, fin, "the final reserve covers first HEAD masks on files");
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

    // ---- later statements and existing-record publishes (formula 3: the later row, freshPerPublishExisting) ------

    /// Logs one publication's execution gas E, the kernel's share K, the final phase, the callbacks' prefix spend
    /// (E − K − final phase) and the kernel's quote (P, F), then leaves the state as it found it.
    function _spendRow(string memory label, Action[] memory a, bytes[] memory b) internal {
        Need memory w = _need(a, b, address(0));
        uint256 fin = _finalPhase(a, b, w.exec);
        emit log_named_uint(string.concat("floor ", label, " exec"), w.exec);
        emit log_named_uint(string.concat("floor ", label, " kernel"), w.kernel);
        emit log_named_uint(string.concat("floor ", label, " final phase"), fin);
        emit log_named_uint(
            string.concat("floor ", label, " callbacks prefix"), w.exec - w.kernel - fin
        );
        emit log_named_uint(string.concat("floor ", label, " prefixFloor"), w.prefixFloor);
        emit log_named_uint(string.concat("floor ", label, " finalReserve"), w.finalReserve);
        uint256 snap = vm.snapshotState();
        Native memory c = _ctx(a);
        vm.startStateDiffRecording();
        r.ledger.execute(a, b, c, "");
        emit log_named_uint(
            string.concat("floor ", label, " fresh index slots"),
            _freshIndexSlots(vm.stopAndReturnStateDiff())
        );
        vm.revertToStateAndDelete(snap);
    }

    /// The same shape at one action and at all of `a` (33), from the same state: the per-action terms are set from
    /// the difference over 32, the first action's cold costs belong to the per-publication terms.
    function _spendPair(string memory label, Action[] memory a, bytes[] memory b) internal {
        Action[] memory a1 = new Action[](1);
        bytes[] memory b1 = new bytes[](1);
        (a1[0], b1[0]) = (a[0], b[0]);
        _spendRow(string.concat(label, " x1"), a1, b1);
        _spendRow(string.concat(label, " x33"), a, b);
    }

    uint256 internal constant LATER = 33;

    function _things(string memory seed) internal pure returns (bytes32[] memory t) {
        t = new bytes32[](LATER);
        for (uint256 i; i < LATER; ++i) {
            t[i] = bytes32(uint256(uint160(uint256(keccak256(abi.encode(seed, i))))));
        }
    }

    function _assert(bytes32[] memory t) internal {
        Action[] memory a = new Action[](LATER);
        for (uint256 i; i < LATER; ++i) {
            a[i] = EfsTopics.tag(topic, t[i], 0, 0);
        }
        _execAs(address(this), a, new bytes[](LATER));
    }

    function test_floor_later_number_changes() public {
        bytes32[] memory t = _things("later number");
        _assert(t);
        Action[] memory a = new Action[](LATER);
        for (uint256 i; i < LATER; ++i) {
            a[i] = EfsTopics.tag(topic, t[i], 1, 7);
        }
        _spendPair("later number change", a, new bytes[](LATER));
    }

    function test_floor_later_masks() public {
        bytes32[] memory t = _things("later mask");
        _assert(t);
        Action[] memory a = new Action[](LATER);
        for (uint256 i; i < LATER; ++i) {
            a[i] = EfsTopics.deny(topic, t[i], 1, 0);
        }
        _spendPair("later mask", a, new bytes[](LATER));
    }

    function test_floor_later_masks_of_masks() public {
        bytes32[] memory t = _things("later mask of mask");
        Action[] memory a = new Action[](LATER);
        for (uint256 i; i < LATER; ++i) {
            a[i] = EfsTopics.deny(topic, t[i], 0, 0);
        }
        _execAs(address(this), a, new bytes[](LATER));
        for (uint256 i; i < LATER; ++i) {
            a[i] = EfsTopics.deny(topic, t[i], 1, 3);
        }
        _spendPair("later mask of mask", a, new bytes[](LATER));
    }

    function test_floor_later_releases() public {
        bytes32[] memory t = _things("later release");
        _assert(t);
        Action[] memory a = new Action[](LATER);
        for (uint256 i; i < LATER; ++i) {
            a[i] = EfsFiles.release(Purpose.TAG, topic, t[i], 1);
        }
        _spendPair("later release", a, new bytes[](LATER));
    }

    function test_floor_later_restores() public {
        bytes32[] memory t = _things("later restore");
        _assert(t);
        Action[] memory a = new Action[](LATER);
        for (uint256 i; i < LATER; ++i) {
            a[i] = EfsTopics.deny(topic, t[i], 1, 0);
        }
        _execAs(address(this), a, new bytes[](LATER));
        for (uint256 i; i < LATER; ++i) {
            a[i] = EfsTopics.tag(topic, t[i], 2, 0);
        }
        _spendPair("later restore", a, new bytes[](LATER));
    }

    /// A ten-byte file name `la-<3 letters>.md`, distinct per i (< 26^3).
    function _fileName(string memory pre, uint256 i) internal pure returns (string memory) {
        return string(
            bytes.concat(
                bytes(pre),
                bytes1(uint8(97 + (i / 676) % 26)),
                bytes1(uint8(97 + (i / 26) % 26)),
                bytes1(uint8(97 + i % 26)),
                ".md"
            )
        );
    }

    /// Creates LATER files `<pre>xyz.md` in the root folder (five actions each, in publications of 50).
    function _files(string memory pre) internal returns (bytes32[] memory f) {
        f = new bytes32[](LATER);
        Action[] memory a = new Action[](50);
        bytes[] memory b = new bytes[](50);
        uint256 n;
        for (uint256 i; i < LATER; ++i) {
            string memory name = _fileName(pre, i);
            (Action[] memory x, bytes[] memory y) = _createFile(name);
            f[i] = Keys.subject(p, keccak256(bytes(name)));
            for (uint256 j; j < 5; ++j) {
                (a[n], b[n]) = (x[j], y[j]);
                ++n;
            }
            if (n == 50 || i + 1 == LATER) {
                Action[] memory xa = new Action[](n);
                bytes[] memory yb = new bytes[](n);
                for (uint256 j; j < n; ++j) {
                    (xa[j], yb[j]) = (a[j], b[j]);
                }
                _execAs(address(this), xa, yb);
                n = 0;
            }
        }
    }

    /// Re-binds of folder entries to another file (the entry `la-…` from its file to the file of `lb-…`).
    function test_floor_later_folder_rebinds() public {
        _files("la-");
        bytes32[] memory other = _files("lb-");
        Action[] memory a = new Action[](LATER);
        for (uint256 i; i < LATER; ++i) {
            a[i] =
                _bind(Purpose.FOLDER, rootDir, keccak256(bytes(_fileName("la-", i))), other[i], 1);
        }
        _spendPair("later folder rebind", a, new bytes[](LATER));
    }

    /// Re-binds of HEAD to another root record of the same file (an edit).
    function test_floor_later_head_rebinds() public {
        bytes32[] memory f = _files("lh-");
        Action[] memory pa = new Action[](LATER);
        bytes[] memory pb = new bytes[](LATER);
        for (uint256 i; i < LATER; ++i) {
            (pa[i], pb[i]) = _publish(T_ROOT, abi.encodePacked(abi.encode(f[i], uint256(0)), "v2"));
        }
        _execAs(address(this), pa, pb);
        Action[] memory a = new Action[](LATER);
        for (uint256 i; i < LATER; ++i) {
            a[i] = _bind(Purpose.HEAD, f[i], 0, _id(T_ROOT, pb[i]), 1);
        }
        _spendPair("later head rebind", a, new bytes[](LATER));
    }

    function _names(string memory pre) internal view returns (Action[] memory a, bytes[] memory b) {
        a = new Action[](LATER);
        b = new bytes[](LATER);
        for (uint256 i; i < LATER; ++i) {
            (a[i], b[i]) = _name(bytes(_fileName(pre, i)));
        }
    }

    /// Fresh name records (publish-heavy work; the final phase's per-publish term).
    function test_floor_publish_names() public {
        (Action[] memory a, bytes[] memory b) = _names("nn-");
        _spendPair("publish name", a, b);
    }

    /// Repeat PUBLISHes of existing records (the same name bodies again).
    function test_floor_publish_existing() public {
        (Action[] memory a, bytes[] memory b) = _names("ne-");
        _execAs(address(this), a, b);
        _spendPair("publish existing", a, b);
    }

    /// REUSEs of existing records.
    function test_floor_reuse() public {
        (Action[] memory a, bytes[] memory b) = _names("nr-");
        _execAs(address(this), a, b);
        Action[] memory x = new Action[](LATER);
        for (uint256 i; i < LATER; ++i) {
            x[i].kind = ActionKind.REUSE;
            x[i].typeId = typeIds[T_NAME];
            x[i].bodyHashOrRecordId = _id(T_NAME, b[i]);
        }
        _spendPair("reuse", x, new bytes[](LATER));
    }

    /// 64 lone negatives on a one-word topic, the action limit, in one publication. On Glamsterdam (amsterdam profile)
    /// they execute within 2^24 − 21,000 − calldata, but since the floor prices a rewrite at its Glamsterdam 12,100
    /// (docs/GAS-SCHEDULES.md; it was 5,000) the floor's requirement V for 64 is over that room (formula 3: 17.39M
    /// against 16.60M; formula 2: 18.34M), so the planning rule splits them (53 a publication under formula 3,
    /// test/vectors/floor-plan.json). On prague their
    /// execution gas alone is over the cap at 64 (the planning rule splits them there too).
    function test_sixty_four_lone_negatives_fit_the_cap() public {
        (Action[] memory a, bytes[] memory b) = _loneNegatives(64, 5);
        Need memory w = _need(a, b, address(0));
        _log("64 lone negatives (cap)", w);
        if (_amsterdam()) {
            assertLe(w.exec, w.room, "64 lone negatives execute within 2^24 execution gas");
            assertGt(
                w.visible,
                w.room,
                "amsterdam: the floor's requirement for 64 lone negatives is over the cap (the rule splits them)"
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
