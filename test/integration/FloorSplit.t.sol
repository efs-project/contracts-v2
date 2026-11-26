// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {FloorBase} from "./FloorBase.sol";
import {EfsTopics} from "../../src/lib/EfsTopics.sol";
import {EfsFiles} from "../../src/lib/EfsFiles.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {Action, ActionKind, Native, Purpose} from "../../src/interfaces/Actions.sol";
import {WorkModel} from "../../src/interfaces/Index.sol";
import {IIndexReads} from "../../src/interfaces/IIndexReads.sol";
import {ILedgerCommitments} from "../../src/interfaces/ILedgerCommitments.sol";
import {IndexDoubleDefaults, LIST_LENGTH_CLAIM} from "../harness/doubles/IndexDoubles.sol";

/// @notice The work model's evidence, per action (docs/WORK-MODEL-V3.md §2): what the index's prefix callbacks spend
///         on each kind of action, split into the index-side slots they make fresh, the slots they rewrite and the
///         rest (compute, calls, cold reads), against the kernel's formula-3 quote, on whichever profile runs.
///
///         Method: each shape is built from its state and measured at 1 action and at N = 33 from that state
///         (`FloorBase._need` and `_finalPhase`, every Realm account cooled; spend = E − K − the final phase; slots from
///         Foundry's state diff of the index and its two stores). The one-action figure is the "lists new" state for a
///         first statement (the author's lists at the place are new) and carries the publication's cold costs; the
///         per-action figure, the difference over 32, is the "lists exist" state.
///
///         What it asserts, so that a change which thins the floor's margin or hides compute in a slot count fails:
///         - the quote covers the spend at one action (≥ 1.03) and per action (first and later statements and every
///           WITHDRAW after the first ≥ 1.03 on prague and ≥ 1.05 on amsterdam; PUBLISH, REUSE and CREATE, whose terms
///           formula 3 did not change, ≥ 1.005). Measured at formula 3: per action 1.035 (prague, a first yes) and
///           1.053 (amsterdam, a restore); at one action 1.034 (amsterdam, a WITHDRAW);
///         - the slot counts are true: the fresh slots and rewrites a statement makes per action are at most its row's;
///         - a later statement writes a fresh index slot (formula 2 quoted none), a re-bind two;
///         - the exceptions are pinned inside bands, so a change either way shows: lists beyond 4,096 entries, two
///           statements at one position, and a yes after a lone no (3 fresh index slots, the later row's 2.0; prague
///           covers it in lists of up to 256 entries, amsterdam at the claim).
contract FloorSplitTest is FloorBase {
    uint256 internal constant N = 33;
    uint8 internal constant FIRST = 1;
    uint8 internal constant LATER = 2;
    uint8 internal constant WITHDRAW = 3;
    uint8 internal constant OTHER = 4; // PUBLISH, REUSE, CREATE: formula 2's terms, unchanged
    uint8 internal constant REBIND = 5; // a BIND on a BOUND head

    EfsTopics.Types internal tt;
    bytes32 internal topic;
    address internal bob = makeAddr("floor-split/bob");

    function setUp() public override {
        super.setUp();
        tt = _topicTypes();
        (Action[] memory a, bytes[] memory b, bytes32 id) =
            EfsTopics.registerWord(tt, bytes("split-topic"));
        _execAs(address(this), a, b);
        topic = id;
    }

    // ---- measurement ---------------------------------------------------------------------------------------------

    struct Shot {
        uint256 spend;
        uint256 prefixFloor;
        uint256 fresh;
        uint256 rewritten;
    }

    /// Index-side slots written by `a` from the cooled current state (fresh: zero before, nonzero after; rewritten:
    /// nonzero before and changed). Leaves the state as it found it.
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
                if (!s.isWrite || s.reverted) continue;
                if (
                    s.account != address(r.g.index) && s.account != address(r.g.posting)
                        && s.account != address(r.g.bitmap)
                ) continue;
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
            if (first[q] == 0 && last[q] != 0) ++fresh;
            else if (first[q] != 0 && last[q] != first[q]) ++rewritten;
        }
    }

    function _shot(Action[] memory a, bytes[] memory b) internal returns (Shot memory s) {
        Need memory w = _need(a, b, address(0));
        s.spend = w.exec - w.kernel - _finalPhase(a, b, w.exec);
        s.prefixFloor = w.prefixFloor;
        (s.fresh, s.rewritten) = _slots(a, b);
    }

    /// Measures `a` (N actions of one kind) at 1 and at N actions, logs the split and asserts the floor's rules for
    /// `cls`. Returns the per-action fresh slots ×100.
    function _row(string memory label, uint8 cls, Action[] memory a, bytes[] memory b)
        internal
        returns (uint256 perFresh)
    {
        uint256 oneRatio;
        uint256 perRatio;
        (perFresh, oneRatio, perRatio) = _measure(label, cls, a, b);
        assertGe(oneRatio, 1030, string.concat(label, ": one action, the quote covers the spend"));
        uint256 floor_ = cls == OTHER ? 1005 : _amsterdam() ? 1050 : 1030;
        assertGe(perRatio, floor_, string.concat(label, ": per action, the quote covers the spend"));
    }

    /// A row the floor does not claim (a list longer than the claim): measured and pinned inside [lo, hi] thousandths
    /// per action (the documented exception, docs/WORK-MODEL-V3.md §3.5), so a change to the quote or the index shows.
    function _beyond(
        string memory label,
        Action[] memory a,
        bytes[] memory b,
        uint256 lo,
        uint256 hi
    ) internal returns (uint256 perRatio) {
        (,, perRatio) = _measure(label, LATER, a, b);
        assertGe(perRatio, lo, string.concat(label, ": the exception's ratio moved down"));
        assertLe(perRatio, hi, string.concat(label, ": the exception's ratio moved up"));
    }

    /// Measures `a` at 1 and at all of its actions, logs the split and checks the slot counts against the row of `cls`
    /// (and that a later statement writes a fresh slot). Returns the per-action fresh slots ×100 and both ratios ×1000.
    function _measure(string memory label, uint8 cls, Action[] memory a, bytes[] memory b)
        internal
        returns (uint256 perFresh, uint256 oneRatio, uint256 perRatio)
    {
        uint256 perRw;
        (perFresh, perRw, oneRatio, perRatio) = _split(label, a, b);
        if (cls == OTHER) return (perFresh, oneRatio, perRatio);
        WorkModel memory wm = r.g.index.workModel();
        uint256 rowFresh = cls == FIRST
            ? wm.freshPerBindFirst
            : cls == REBIND ? wm.freshPerRebind : wm.freshPerBindLater;
        uint256 rowRw =
            cls == FIRST ? wm.rwPerBindFirst : cls == REBIND ? wm.rwPerRebind : wm.rwPerBindLater;
        // ×100 measured against ×10 quoted
        assertLe(
            perFresh, rowFresh * 10, string.concat(label, ": no more fresh slots than its row")
        );
        assertLe(perRw, rowRw * 10, string.concat(label, ": no more rewrites than its row"));
        if (cls != FIRST) {
            assertGe(perFresh, 100, string.concat(label, ": a later statement writes a fresh slot"));
        }
    }

    /// Measures `a` at 1 and at all of its actions and logs the split. Returns the per-action fresh and rewritten
    /// slots ×100 and both ratios ×1000.
    function _split(string memory label, Action[] memory a, bytes[] memory b)
        internal
        returns (uint256 perFresh, uint256 perRw, uint256 oneRatio, uint256 perRatio)
    {
        Action[] memory a1 = new Action[](1);
        bytes[] memory b1 = new bytes[](1);
        (a1[0], b1[0]) = (a[0], b[0]);
        Shot memory one = _shot(a1, b1);
        Shot memory all = _shot(a, b);
        uint256 n = a.length - 1;
        uint256 perSpend = (all.spend - one.spend) / n;
        uint256 perQuote = (all.prefixFloor - one.prefixFloor) / n;
        perFresh = (all.fresh - one.fresh) * 100 / n;
        perRw = (all.rewritten - one.rewritten) * 100 / n;
        emit log_named_string("split row", label);
        emit log_named_uint("split one: spend", one.spend);
        emit log_named_uint("split one: quote", one.prefixFloor);
        emit log_named_uint("split one: fresh slots", one.fresh);
        emit log_named_uint("split one: rewritten slots", one.rewritten);
        emit log_named_uint("split per action: spend", perSpend);
        emit log_named_uint("split per action: quote", perQuote);
        emit log_named_uint("split per action: fresh slots x100", perFresh);
        emit log_named_uint("split per action: rewritten slots x100", perRw);
        oneRatio = one.prefixFloor * 1000 / one.spend;
        perRatio = perQuote * 1000 / perSpend;
        emit log_named_uint("split one: quote / spend x1000", oneRatio);
        emit log_named_uint("split per action: quote / spend x1000", perRatio);
    }

    // ---- helpers ---------------------------------------------------------------------------------------------------

    function _things(string memory seed) internal pure returns (bytes32[] memory t) {
        t = new bytes32[](N);
        for (uint256 i; i < N; ++i) {
            t[i] = bytes32(uint256(uint160(uint256(keccak256(abi.encode(seed, i))))));
        }
    }

    function _tags(bytes32[] memory t, uint64 expected, uint16 strength, bool yes)
        internal
        view
        returns (Action[] memory a)
    {
        a = new Action[](N);
        for (uint256 i; i < N; ++i) {
            a[i] = yes
                ? EfsTopics.tag(topic, t[i], expected, strength)
                : EfsTopics.deny(topic, t[i], expected, strength);
        }
    }

    function _ft() internal view returns (EfsFiles.Types memory t) {
        t.root = typeIds[T_ROOT];
        t.child = typeIds[T_CHILD];
        t.directory = typeIds[T_DIRECTORY];
        t.name = typeIds[T_NAME];
    }

    function _fname(string memory pre, uint256 i) internal pure returns (bytes memory) {
        return bytes.concat(
            bytes(pre), bytes1(uint8(97 + (i / 26) % 26)), bytes1(uint8(97 + i % 26)), ".md"
        );
    }

    /// N files in the root by this principal (one publication each).
    function _files(string memory pre)
        internal
        returns (bytes32[] memory f, bytes32[] memory roots)
    {
        f = new bytes32[](N);
        roots = new bytes32[](N);
        for (uint256 i; i < N; ++i) {
            bytes memory name = _fname(pre, i);
            Action[] memory a;
            bytes[] memory b;
            (a, b, f[i], roots[i]) = EfsFiles.createFile(
                _ft(), p, rootDir, keccak256(abi.encode(pre, i)), name, name, true
            );
            _execAs(address(this), a, b);
        }
    }

    /// N files of bob in his home.
    function _bobFiles(string memory pre)
        internal
        returns (bytes32[] memory f, bytes32[] memory roots)
    {
        f = new bytes32[](N);
        roots = new bytes32[](N);
        for (uint256 i; i < N; ++i) {
            bytes memory name = _fname(pre, i);
            Action[] memory a;
            bytes[] memory b;
            (a, b, f[i], roots[i]) = EfsFiles.createFile(
                _ft(),
                Keys.principal(bob),
                bytes32(uint256(uint160(bob))),
                keccak256(abi.encode(pre, i)),
                name,
                name,
                true
            );
            _execAs(bob, a, b);
        }
    }

    function _names(string memory pre) internal view returns (Action[] memory a, bytes[] memory b) {
        a = new Action[](N);
        b = new bytes[](N);
        for (uint256 i; i < N; ++i) {
            (a[i], b[i]) = _name(_fname(pre, i));
        }
    }

    // ---- TAG ---------------------------------------------------------------------------------------------------------

    function test_split_tag_first_lone_negative() public {
        _row("tag first lone negative", FIRST, _tags(_things("ln"), 0, 0, false), new bytes[](N));
    }

    function test_split_tag_first_yes() public {
        _row("tag first yes", FIRST, _tags(_things("fy"), 0, 0, true), new bytes[](N));
    }

    function test_split_tag_second_author_first_yes() public {
        bytes32[] memory t = _things("sa");
        _execAs(bob, _tags(t, 0, 0, true), new bytes[](N));
        _row("tag second author first yes", FIRST, _tags(t, 0, 0, true), new bytes[](N));
    }

    function test_split_tag_second_author_first_no() public {
        bytes32[] memory t = _things("sn");
        _execAs(bob, _tags(t, 0, 0, true), new bytes[](N));
        _row("tag second author first no", FIRST, _tags(t, 0, 0, false), new bytes[](N));
    }

    function test_split_tag_later_number_change() public {
        bytes32[] memory t = _things("nc");
        _execAs(address(this), _tags(t, 0, 0, true), new bytes[](N));
        _row("tag later number change", REBIND, _tags(t, 1, 7, true), new bytes[](N));
    }

    function test_split_tag_later_mask() public {
        bytes32[] memory t = _things("mk");
        _execAs(address(this), _tags(t, 0, 0, true), new bytes[](N));
        _row("tag later mask", LATER, _tags(t, 1, 0, false), new bytes[](N));
    }

    function test_split_tag_later_mask_of_mask() public {
        bytes32[] memory t = _things("mm");
        _execAs(address(this), _tags(t, 0, 0, false), new bytes[](N));
        _row("tag later mask of mask", LATER, _tags(t, 1, 3, false), new bytes[](N));
    }

    function test_split_tag_later_release() public {
        bytes32[] memory t = _things("rl");
        _execAs(address(this), _tags(t, 0, 0, true), new bytes[](N));
        Action[] memory a = new Action[](N);
        for (uint256 i; i < N; ++i) {
            a[i] = EfsFiles.release(Purpose.TAG, topic, t[i], 1);
        }
        _row("tag later release", LATER, a, new bytes[](N));
    }

    function test_split_tag_later_restore() public {
        bytes32[] memory t = _things("rs");
        _execAs(address(this), _tags(t, 0, 0, true), new bytes[](N));
        _execAs(address(this), _tags(t, 1, 0, false), new bytes[](N));
        _row("tag later restore", LATER, _tags(t, 2, 0, true), new bytes[](N));
    }

    // ---- FOLDER ------------------------------------------------------------------------------------------------------

    function test_split_folder_later_rebind() public {
        _files("fa");
        (bytes32[] memory other,) = _files("fb");
        Action[] memory a = new Action[](N);
        for (uint256 i; i < N; ++i) {
            a[i] = EfsFiles.bind(Purpose.FOLDER, rootDir, keccak256(_fname("fa", i)), other[i], 1);
        }
        uint256 fresh = _row("folder later rebind", REBIND, a, new bytes[](N));
        assertEq(fresh, 200, "a re-bind writes two fresh index slots");
    }

    function test_split_folder_later_mask() public {
        _files("fm");
        Action[] memory a = new Action[](N);
        for (uint256 i; i < N; ++i) {
            a[i] = EfsFiles.unbind(Purpose.FOLDER, rootDir, keccak256(_fname("fm", i)), 1);
        }
        _row("folder later mask", LATER, a, new bytes[](N));
    }

    function test_split_folder_later_release() public {
        _files("fr");
        Action[] memory a = new Action[](N);
        for (uint256 i; i < N; ++i) {
            a[i] = EfsFiles.release(Purpose.FOLDER, rootDir, keccak256(_fname("fr", i)), 1);
        }
        _row("folder later release", LATER, a, new bytes[](N));
    }

    function test_split_folder_later_restore() public {
        (bytes32[] memory f,) = _files("fs");
        Action[] memory a = new Action[](N);
        for (uint256 i; i < N; ++i) {
            a[i] = EfsFiles.unbind(Purpose.FOLDER, rootDir, keccak256(_fname("fs", i)), 1);
        }
        _execAs(address(this), a, new bytes[](N));
        for (uint256 i; i < N; ++i) {
            a[i] = EfsFiles.bind(Purpose.FOLDER, rootDir, keccak256(_fname("fs", i)), f[i], 2);
        }
        _row("folder later restore", LATER, a, new bytes[](N));
    }

    // ---- HEAD --------------------------------------------------------------------------------------------------------

    function test_split_head_first_second_author() public {
        (bytes32[] memory f, bytes32[] memory roots) = _bobFiles("hb");
        Action[] memory a = new Action[](N);
        for (uint256 i; i < N; ++i) {
            a[i] = EfsFiles.bind(Purpose.HEAD, f[i], 0, roots[i], 0);
        }
        _row("head first second author", FIRST, a, new bytes[](N));
    }

    function test_split_head_first_lone_negative() public {
        (bytes32[] memory f,) = _bobFiles("hn");
        Action[] memory a = new Action[](N);
        for (uint256 i; i < N; ++i) {
            a[i] = EfsFiles.loneNegative(Purpose.HEAD, f[i], 0, 0);
        }
        _row("head first lone negative", FIRST, a, new bytes[](N));
    }

    function test_split_head_later_rebind() public {
        (bytes32[] memory f,) = _files("hr");
        Action[] memory pa = new Action[](N);
        bytes[] memory pb = new bytes[](N);
        for (uint256 i; i < N; ++i) {
            (pa[i], pb[i]) = _publish(T_ROOT, abi.encodePacked(abi.encode(f[i], uint256(0)), "v2"));
        }
        _execAs(address(this), pa, pb);
        Action[] memory a = new Action[](N);
        for (uint256 i; i < N; ++i) {
            a[i] = _bind(Purpose.HEAD, f[i], 0, _id(T_ROOT, pb[i]), 1);
        }
        uint256 fresh = _row("head later rebind", REBIND, a, new bytes[](N));
        assertEq(fresh, 200, "a re-bind writes two fresh index slots");
    }

    function test_split_head_later_mask() public {
        (bytes32[] memory f,) = _files("hm");
        Action[] memory a = new Action[](N);
        for (uint256 i; i < N; ++i) {
            a[i] = EfsFiles.unbind(Purpose.HEAD, f[i], 0, 1);
        }
        _row("head later mask", LATER, a, new bytes[](N));
    }

    function test_split_head_later_release() public {
        (bytes32[] memory f,) = _files("hl");
        Action[] memory a = new Action[](N);
        for (uint256 i; i < N; ++i) {
            a[i] = EfsFiles.release(Purpose.HEAD, f[i], 0, 1);
        }
        _row("head later release", LATER, a, new bytes[](N));
    }

    function test_split_head_later_restore() public {
        (bytes32[] memory f, bytes32[] memory roots) = _files("hs");
        Action[] memory a = new Action[](N);
        for (uint256 i; i < N; ++i) {
            a[i] = EfsFiles.unbind(Purpose.HEAD, f[i], 0, 1);
        }
        _execAs(address(this), a, new bytes[](N));
        for (uint256 i; i < N; ++i) {
            a[i] = EfsFiles.bind(Purpose.HEAD, f[i], 0, roots[i], 2);
        }
        _row("head later restore", LATER, a, new bytes[](N));
    }

    // ---- publishes, CREATE, WITHDRAW -----------------------------------------------------------------------------------

    function test_split_publish_new() public {
        (Action[] memory a, bytes[] memory b) = _names("pn");
        _row("publish new name", OTHER, a, b);
    }

    function test_split_publish_existing() public {
        (Action[] memory a, bytes[] memory b) = _names("pe");
        _execAs(address(this), a, b);
        _row("publish existing name", OTHER, a, b);
    }

    function test_split_reuse() public {
        (Action[] memory a, bytes[] memory b) = _names("pr");
        _execAs(address(this), a, b);
        Action[] memory x = new Action[](N);
        for (uint256 i; i < N; ++i) {
            x[i].kind = ActionKind.REUSE;
            x[i].typeId = typeIds[T_NAME];
            x[i].bodyHashOrRecordId = _id(T_NAME, b[i]);
        }
        _row("reuse name", OTHER, x, new bytes[](N));
    }

    function test_split_create() public {
        Action[] memory a = new Action[](N);
        for (uint256 i; i < N; ++i) {
            a[i] = _create(keccak256(abi.encode("split create", i)));
        }
        _row("create", OTHER, a, new bytes[](N));
    }

    /// Withdraws of name records: the first of a publication is covered by the per-publication terms, every later one
    /// is quoted with the later-statement row (formula 2 quoted it `computePerAction` only: 0.12× / 0.14×).
    function test_split_withdraw() public {
        (Action[] memory a, bytes[] memory b) = _names("pw");
        _execAs(address(this), a, b);
        Action[] memory x = new Action[](N);
        for (uint256 i; i < N; ++i) {
            (, uint64 first,,,) = r.hot.recordHeader(_id(T_NAME, b[i]));
            x[i].kind = ActionKind.WITHDRAW;
            x[i].target = bytes32(uint256(first));
        }
        _row("withdraw", WITHDRAW, x, new bytes[](N));
    }

    // ---- later statements across distinct scopes, and long scope lists -------------------------------------------
    // A later statement moves its scope's bitmap head (`BitmapStore.setBit`/`stamp` write `lastMutation`, and `live`
    // and `liveBits0` when a bit changes). In one scope that head is rewritten once per publication; across distinct
    // scopes (topics, folders) once per statement. From entry 48 a scope's live bits are in words of their own, and the
    // kernel's `_entryIndex` bisects the author's scope list with one store call per probe.

    /// `n` registered one-word topics, in publications of 32.
    function _topics(string memory seed, uint256 n) internal returns (bytes32[] memory t) {
        t = new bytes32[](n);
        Action[] memory a = new Action[](n);
        bytes[] memory b = new bytes[](n);
        for (uint256 i; i < n; ++i) {
            (Action[] memory x, bytes[] memory y, bytes32 id) =
                EfsTopics.registerWord(tt, bytes(string.concat(seed, vm.toString(i))));
            (a[i], b[i], t[i]) = (x[0], y[0], id);
        }
        _sendIn(a, b, 32);
    }

    function _sendIn(Action[] memory a, bytes[] memory b, uint256 per) internal {
        for (uint256 from; from < a.length; from += per) {
            uint256 m = a.length - from < per ? a.length - from : per;
            Action[] memory x = new Action[](m);
            bytes[] memory y = new bytes[](m);
            for (uint256 j; j < m; ++j) {
                (x[j], y[j]) = (a[from + j], b[from + j]);
            }
            _execAs(address(this), x, y);
        }
    }

    /// One statement at each of `topics[i]` about `things[i]`.
    function _across(
        bytes32[] memory topics,
        bytes32[] memory things,
        uint64 expected,
        uint16 strength,
        bool yes
    ) internal pure returns (Action[] memory a) {
        a = new Action[](topics.length);
        for (uint256 i; i < topics.length; ++i) {
            a[i] = yes
                ? EfsTopics.tag(topics[i], things[i], expected, strength)
                : EfsTopics.deny(topics[i], things[i], expected, strength);
        }
    }

    function test_split_scopes_tag_masks() public {
        bytes32[] memory t = _topics("sm-", N);
        bytes32[] memory x = _things("sm");
        _execAs(address(this), _across(t, x, 0, 0, true), new bytes[](N));
        _row("tag masks across topics", LATER, _across(t, x, 1, 0, false), new bytes[](N));
    }

    function test_split_scopes_tag_restores() public {
        bytes32[] memory t = _topics("sr-", N);
        bytes32[] memory x = _things("sr");
        _execAs(address(this), _across(t, x, 0, 0, true), new bytes[](N));
        _execAs(address(this), _across(t, x, 1, 0, false), new bytes[](N));
        _row("tag restores across topics", LATER, _across(t, x, 2, 0, true), new bytes[](N));
    }

    function test_split_scopes_tag_releases() public {
        bytes32[] memory t = _topics("sl-", N);
        bytes32[] memory x = _things("sl");
        _execAs(address(this), _across(t, x, 0, 0, true), new bytes[](N));
        Action[] memory a = new Action[](N);
        for (uint256 i; i < N; ++i) {
            a[i] = EfsFiles.release(Purpose.TAG, t[i], x[i], 1);
        }
        _row("tag releases across topics", LATER, a, new bytes[](N));
    }

    function test_split_scopes_tag_number_changes() public {
        bytes32[] memory t = _topics("sc-", N);
        bytes32[] memory x = _things("sc");
        _execAs(address(this), _across(t, x, 0, 0, true), new bytes[](N));
        _row("tag number changes across topics", REBIND, _across(t, x, 1, 7, true), new bytes[](N));
    }

    function test_split_scopes_tag_masks_of_masks() public {
        bytes32[] memory t = _topics("so-", N);
        bytes32[] memory x = _things("so");
        _execAs(address(this), _across(t, x, 0, 0, false), new bytes[](N));
        _row("tag masks of masks across topics", LATER, _across(t, x, 1, 3, false), new bytes[](N));
    }

    /// `n` folders in the root by this principal, one file of this principal in each.
    function _folders(string memory seed, uint256 n)
        internal
        returns (bytes32[] memory dirs, bytes32[] memory files)
    {
        dirs = new bytes32[](n);
        files = new bytes32[](n);
        EfsFiles.Types memory ft = _ft();
        for (uint256 i; i < n; ++i) {
            bytes memory name = _fname(seed, i);
            (Action[] memory a, bytes[] memory b, bytes32 d) =
                EfsFiles.createFolder(ft, p, rootDir, keccak256(abi.encode(seed, i)), name, true);
            _execAs(address(this), a, b);
            dirs[i] = d;
            (a, b, files[i],) = EfsFiles.createFile(
                ft, p, d, keccak256(abi.encode(seed, "file", i)), "a.md", "a.md", true
            );
            _execAs(address(this), a, b);
        }
    }

    function _folderAcross(
        bytes32[] memory dirs,
        bytes32[] memory targets,
        uint8 kind,
        uint64 expected
    ) internal pure returns (Action[] memory a) {
        a = new Action[](dirs.length);
        for (uint256 i; i < dirs.length; ++i) {
            bytes32 role = keccak256("a.md");
            a[i] = kind == ActionKind.BIND
                ? EfsFiles.bind(Purpose.FOLDER, dirs[i], role, targets[i], expected)
                : kind == ActionKind.UNBIND
                    ? EfsFiles.unbind(Purpose.FOLDER, dirs[i], role, expected)
                    : EfsFiles.release(Purpose.FOLDER, dirs[i], role, expected);
        }
    }

    function test_split_scopes_folder_masks() public {
        (bytes32[] memory d, bytes32[] memory f) = _folders("dm", N);
        _row(
            "folder masks across folders",
            LATER,
            _folderAcross(d, f, ActionKind.UNBIND, 1),
            new bytes[](N)
        );
    }

    function test_split_scopes_folder_releases() public {
        (bytes32[] memory d, bytes32[] memory f) = _folders("dl", N);
        _row(
            "folder releases across folders",
            LATER,
            _folderAcross(d, f, ActionKind.RELEASE, 1),
            new bytes[](N)
        );
    }

    function test_split_scopes_folder_restores() public {
        (bytes32[] memory d, bytes32[] memory f) = _folders("ds", N);
        _execAs(address(this), _folderAcross(d, f, ActionKind.UNBIND, 1), new bytes[](N));
        _row(
            "folder restores across folders",
            LATER,
            _folderAcross(d, f, ActionKind.BIND, 2),
            new bytes[](N)
        );
    }

    function test_split_scopes_folder_rebinds() public {
        (bytes32[] memory d,) = _folders("dr", N);
        (, bytes32[] memory g) = _folders("dg", N);
        _row(
            "folder re-binds across folders",
            REBIND,
            _folderAcross(d, g, ActionKind.BIND, 1),
            new bytes[](N)
        );
    }

    /// `len` first yeses by this principal at one topic (things `seed`/0..len-1), with gas metering paused.
    function _list(bytes32 topic_, string memory seed, uint256 len)
        internal
        returns (bytes32[] memory x)
    {
        x = new bytes32[](len);
        Action[] memory a = new Action[](len);
        for (uint256 i; i < len; ++i) {
            x[i] = bytes32(uint256(uint160(uint256(keccak256(abi.encode(seed, i))))));
            a[i] = EfsTopics.tag(topic_, x[i], 0, 0);
        }
        _sendIn(a, new bytes[](len), 64);
    }

    /// Masks (and, when `restore`, restores after a mask) of the LAST N entries of a `len`-entry list at one topic.
    function _longList(uint256 len, bool restore) internal {
        vm.pauseGasMetering();
        bytes32 t = _topics(string.concat("ll", vm.toString(len), "-"), 1)[0];
        bytes32[] memory x = _list(t, "ll", len);
        Action[] memory a = new Action[](N);
        for (uint256 i; i < N; ++i) {
            a[i] = EfsTopics.deny(t, x[len - N + i], 1, 0);
        }
        if (restore) {
            _execAs(address(this), a, new bytes[](N));
            for (uint256 i; i < N; ++i) {
                a[i] = EfsTopics.tag(t, x[len - N + i], 2, 0);
            }
        }
        vm.resumeGasMetering();
        _row(
            string.concat(
                restore ? "restores" : "masks", " at the end of a list of ", vm.toString(len)
            ),
            LATER,
            a,
            new bytes[](N)
        );
    }

    function test_split_list_64_masks() public {
        _longList(64, false);
    }

    function test_split_list_64_restores() public {
        _longList(64, true);
    }

    function test_split_list_512_restores() public {
        _longList(512, true);
    }

    function test_split_list_4096_masks() public {
        _longList(4096, false);
    }

    function test_split_list_4096_restores() public {
        _longList(4096, true);
    }

    /// Across N topics where the author's list holds 49 entries: a mask of entry 48 (the only entry of its bits
    /// word, so the word goes to zero), and a restore of it after the mask (the word goes from zero: a fresh slot).
    function _bits48(bool restore) internal {
        vm.pauseGasMetering();
        bytes32[] memory t = _topics(restore ? "b48r-" : "b48m-", N);
        bytes32[] memory last = new bytes32[](N);
        for (uint256 i; i < N; ++i) {
            bytes32[] memory x =
                _list(t[i], string.concat(restore ? "b48r" : "b48m", vm.toString(i)), 49);
            last[i] = x[48];
        }
        if (restore) _execAs(address(this), _across(t, last, 1, 0, false), new bytes[](N));
        vm.resumeGasMetering();
        _row(
            restore ? "restores of entry 48 across topics" : "masks of entry 48 across topics",
            LATER,
            restore ? _across(t, last, 2, 0, true) : _across(t, last, 1, 0, false),
            new bytes[](N)
        );
    }

    function test_split_scopes_entry48_masks() public {
        _bits48(false);
    }

    function test_split_scopes_entry48_restores() public {
        _bits48(true);
    }

    /// The dearest later statement the floor claims (docs/WORK-MODEL-V3.md §3.5): across `n` topics whose author's list
    /// holds `len` + 1 entries, the last entry (`len`, alone in its live-bits word) masked and, when `restore`, restored
    /// after the mask (its bits word goes from zero: a fresh slot), with a cold scope head per place and the longest
    /// bisection of the list. Gas metering is paused while the lists are built (real first tags, 64 a publication).
    function _farAcross(uint256 n, uint256 len, bool restore) internal returns (Action[] memory a) {
        vm.pauseGasMetering();
        string memory seed = string.concat(restore ? "far-r" : "far-m", vm.toString(len), "-");
        bytes32[] memory t = _topics(seed, n);
        bytes32[] memory last = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            bytes32[] memory x = _list(t[i], string.concat(seed, vm.toString(i)), len + 1);
            last[i] = x[len];
        }
        if (restore) _execAs(address(this), _across(t, last, 1, 0, false), new bytes[](n));
        vm.resumeGasMetering();
        a = restore ? _across(t, last, 2, 0, true) : _across(t, last, 1, 0, false);
    }

    /// The claim: a restore of a far entry across nine places, in lists just past `LIST_LENGTH_CLAIM` entries, is quoted
    /// at the floor's per-action margin (≥ 1.05 on amsterdam; measured 1.062 / 1.052).
    function test_split_claim_restores_across_lists_at_the_claim() public {
        _row(
            "claim: restores of a far entry across places",
            LATER,
            _farAcross(9, LIST_LENGTH_CLAIM, true),
            new bytes[](9)
        );
    }

    function test_split_claim_masks_across_lists_at_the_claim() public {
        _row(
            "claim: masks of a far entry across places",
            LATER,
            _farAcross(9, LIST_LENGTH_CLAIM, false),
            new bytes[](9)
        );
    }

    // ---- a yes after a lone no: the documented exception ----------------------------------------------------------
    // A yes after a lone no is a restore that is the binding's SECOND statement. `PostingStore._append` at count 1
    // materializes the binding's history word 0, a fresh slot; every restore the rows above measure is a binding's third
    // statement (yes, mask, yes), whose append rewrites that word. In a list of lone noes no live bit is ever set, so the
    // entry's live-bits word is empty and the yes writes it fresh; with the thing's backlink list holding one entry, the
    // yes writes that list's word 0 fresh too. The yes then writes 3 fresh index slots and rewrites 4, against the later
    // row's 2.0 and 5.0. Measured per action across nine topics (prague / amsterdam; quote 162,200 / 177,700): lists of
    // 48 lone noes 1.258 / 1.289 (2 fresh: the live bit is in the head word); 256 entries 1.004 / 1.106; 257 entries
    // 0.992 / 1.093; 1,025 entries 0.955 / 1.052 (spend 169,693 / 168,771). Prague covers this shape in lists of up to
    // 256 entries; amsterdam (a fresh slot and a rewrite both cost 12,100 of execution there) covers it at the claim.
    // At one topic of 1,025, nine spread entries: 1.106 / 1.238. The same yes with the lone no last in a list of 1,024
    // first yeses spends what the all-noes list spends (the entry is alone in its bits word either way); with the
    // thing unlinked it writes 3 fresh and 3 rewritten (0.986 / 1.136 at 1,025).

    /// `len` lone noes by this principal at `topic_` (things `seed`/0..len-1), in publications of 64.
    function _noList(bytes32 topic_, string memory seed, uint256 len)
        internal
        returns (bytes32[] memory x)
    {
        x = new bytes32[](len);
        Action[] memory m = new Action[](len);
        for (uint256 j; j < len; ++j) {
            x[j] = bytes32(uint256(uint160(uint256(keccak256(abi.encode(seed, j))))));
            m[j] = EfsTopics.deny(topic_, x[j], 0, 0);
        }
        _sendIn(m, new bytes[](len), 64);
    }

    /// One first yes of each of `things` at one new topic: each thing's backlink list then holds one entry.
    function _linkOnce(bytes32[] memory things, string memory seed) internal {
        bytes32 o = _topics(string.concat(seed, "o"), 1)[0];
        Action[] memory l = new Action[](things.length);
        for (uint256 i; i < things.length; ++i) {
            l[i] = EfsTopics.tag(o, things[i], 0, 0);
        }
        _sendIn(l, new bytes[](things.length), 64);
    }

    /// Across `n` topics whose author's list holds `len` lone noes: the yes after the last of them (entry len − 1).
    /// `linked`: each thing has one backlink entry. Gas metering is paused while the lists are built.
    function _loneNoAcross(uint256 n, uint256 len, bool linked) internal returns (Action[] memory) {
        vm.pauseGasMetering();
        string memory seed = string.concat(linked ? "nal-" : "nau-", vm.toString(len), "-");
        bytes32[] memory t = _topics(seed, n);
        bytes32[] memory last = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            last[i] = _noList(t[i], string.concat(seed, vm.toString(i)), len)[len - 1];
        }
        if (linked) _linkOnce(last, seed);
        vm.resumeGasMetering();
        return _across(t, last, 1, 0, true);
    }

    /// At ONE topic whose author's list holds `len` lone noes: yeses after `k` of them, spread (entries
    /// len − 1 − (k − 1 − j)·⌊(len − 1) / k⌋), each thing linked once.
    function _loneNoOnePlace(uint256 k, uint256 len) internal returns (Action[] memory a) {
        vm.pauseGasMetering();
        string memory seed = string.concat("nop-", vm.toString(len), "-");
        bytes32 t = _topics(seed, 1)[0];
        bytes32[] memory x = _noList(t, seed, len);
        bytes32[] memory m = new bytes32[](k);
        uint256 step = (len - 1) / k;
        a = new Action[](k);
        for (uint256 j; j < k; ++j) {
            m[j] = x[len - 1 - (k - 1 - j) * step];
            a[j] = EfsTopics.tag(t, m[j], 1, 0);
        }
        _linkOnce(m, seed);
        vm.resumeGasMetering();
    }

    /// Across `n` topics whose author's list holds `len` first yeses and then a lone no (entry `len`): the yes after it,
    /// each thing linked once.
    function _loneNoAfterYeses(uint256 n, uint256 len) internal returns (Action[] memory a) {
        vm.pauseGasMetering();
        string memory seed = string.concat("nyl-", vm.toString(len), "-");
        bytes32[] memory t = _topics(seed, n);
        bytes32[] memory last = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            _list(t[i], string.concat(seed, vm.toString(i)), len);
            last[i] = bytes32(uint256(uint160(uint256(keccak256(abi.encode(seed, "no", i))))));
        }
        _linkOnce(last, seed);
        _execAs(address(this), _across(t, last, 0, 0, false), new bytes[](n));
        vm.resumeGasMetering();
        a = _across(t, last, 1, 0, true);
    }

    /// The exception pinned: per action, the ratio inside [band[0], band[1]] thousandths on prague and [band[2],
    /// band[3]] on amsterdam, and exactly `fresh` and `rewritten` index slots (×100), so a change either way shows.
    function _loneNo(
        string memory label,
        Action[] memory a,
        uint256[4] memory band,
        uint256 fresh,
        uint256 rewritten
    ) internal returns (uint256 perRatio) {
        uint256 perFresh;
        uint256 perRw;
        (perFresh, perRw,, perRatio) = _split(label, a, new bytes[](a.length));
        (uint256 lo, uint256 hi) = _amsterdam() ? (band[2], band[3]) : (band[0], band[1]);
        assertGe(perRatio, lo, string.concat(label, ": the exception's ratio moved down"));
        assertLe(perRatio, hi, string.concat(label, ": the exception's ratio moved up"));
        assertEq(perFresh, fresh, string.concat(label, ": fresh index slots per yes"));
        assertEq(perRw, rewritten, string.concat(label, ": rewritten index slots per yes"));
    }

    /// The length up to which prague covers a yes after a lone no across places (measured 1.004 at 256 entries, 0.992
    /// at 257; the search makes one more store call there, and 512 and 513 entries measure alike, 0.967).
    uint256 internal constant LONE_NO_COVERED_UP_TO = 256;

    /// A short list (48 lone noes, the short tier's top): covered on both schedules (measured 1.258 / 1.289).
    function test_split_lone_no_yes_short_list() public {
        uint256 r = _loneNo(
            "lone no: yeses across places, lists of 48",
            _loneNoAcross(9, 48, true),
            [uint256(1230), 1290, 1260, 1320],
            200,
            400
        );
        assertGe(r, 1000, "covered in a short list");
    }

    function test_split_lone_no_yes_covered_at_256() public {
        uint256 r = _loneNo(
            "lone no: yeses across places, lists of 256",
            _loneNoAcross(9, LONE_NO_COVERED_UP_TO, true),
            [uint256(1000), 1030, 1080, 1130],
            300,
            400
        );
        assertGe(r, 1000, "covered at 256 entries");
    }

    function test_split_lone_no_yes_not_covered_at_257() public {
        uint256 r = _loneNo(
            "lone no: yeses across places, lists of 257",
            _loneNoAcross(9, LONE_NO_COVERED_UP_TO + 1, true),
            [uint256(970), 999, 1070, 1120],
            300,
            400
        );
        if (_amsterdam()) assertGe(r, 1000, "amsterdam: covered at 257 entries");
        else assertLt(r, 1000, "prague: the documented exception, not covered from 257 entries");
    }

    /// At the claim (lists of 1,025): measured 0.955 on prague (not covered), 1.052 on amsterdam (covered).
    function test_split_lone_no_yes_at_the_claim() public {
        uint256 r = _loneNo(
            "lone no: yeses across places, lists of 1,025",
            _loneNoAcross(9, LIST_LENGTH_CLAIM + 1, true),
            [uint256(935), 975, 1030, 1075],
            300,
            400
        );
        if (_amsterdam()) assertGe(r, 1000, "amsterdam: covered at the claim");
        else assertLt(r, 1000, "prague: the documented exception, not covered at the claim");
    }

    /// The thing unlinked (its backlink list empty: the yes writes the list's head, no word): 3 fresh, 3 rewritten;
    /// measured 0.986 / 1.136, so the linked case is the dearer.
    function test_split_lone_no_yes_at_the_claim_unlinked() public {
        _loneNo(
            "lone no: yeses across places, lists of 1,025, things unlinked",
            _loneNoAcross(9, LIST_LENGTH_CLAIM + 1, false),
            [uint256(965), 999, 1110, 1160],
            300,
            300
        );
    }

    /// A lone no last in a list of 1,024 first yeses: the same spend as in a list of lone noes (0.955 / 1.052).
    function test_split_lone_no_yes_after_yeses_at_the_claim() public {
        _loneNo(
            "lone no: yeses across places, a lone no after 1,024 first yeses",
            _loneNoAfterYeses(9, LIST_LENGTH_CLAIM),
            [uint256(935), 975, 1030, 1075],
            300,
            400
        );
    }

    /// At ONE topic of 1,025 lone noes, nine spread entries: covered on both (measured 1.106 / 1.238; the scope head
    /// is warm after the first, and the nine share five live-bits words).
    function test_split_lone_no_yes_one_place_at_the_claim() public {
        uint256 r = _loneNo(
            "lone no: yeses at one topic of 1,025",
            _loneNoOnePlace(9, LIST_LENGTH_CLAIM + 1),
            [uint256(1080), 1130, 1210, 1260],
            250,
            300
        );
        assertGe(r, 1000, "covered at one place");
    }

    /// The length where the quote stops covering, pinned: the bisection makes one more store call each time a list
    /// passes a power of two, so a restore of a far entry across places is covered in lists of up to 4,096 entries
    /// (twelve probes) and not from 4,097 (thirteen; measured 0.995 / 0.991; at 4,096: 1.008 / 1.003). The restore sets it: it writes the most
    /// (2 fresh, 5 rewritten) on top of the bisection.
    uint256 internal constant COVERED_UP_TO = 4096;

    /// At exactly `COVERED_UP_TO` entries: the far entry is 4,095 and every entry of its bits word (3,840-4,095) is
    /// masked first, so its restore writes the word from zero as at the claim.
    function test_split_break_even_covered_at_4096() public {
        uint256 n = 9;
        vm.pauseGasMetering();
        bytes32[] memory t = _topics("be-", n);
        Action[] memory a = new Action[](n);
        for (uint256 i; i < n; ++i) {
            bytes32[] memory x = _list(t[i], string.concat("be-", vm.toString(i)), COVERED_UP_TO);
            Action[] memory m = new Action[](256);
            for (uint256 j; j < 256; ++j) {
                m[j] = EfsTopics.deny(t[i], x[COVERED_UP_TO - 256 + j], 1, 0);
            }
            _sendIn(m, new bytes[](256), 64);
            a[i] = EfsTopics.tag(t[i], x[COVERED_UP_TO - 1], 2, 0);
        }
        vm.resumeGasMetering();
        (,, uint256 perRatio) =
            _measure("break-even: restores at 4,096 entries", LATER, a, new bytes[](n));
        assertGe(perRatio, 1000, "covered at 4,096 entries");
    }

    function test_split_break_even_not_covered_at_4097() public {
        uint256 r = _beyond(
            "beyond: restores at 4,097 entries",
            _farAcross(9, COVERED_UP_TO, true),
            new bytes[](9),
            960,
            999
        );
        assertLt(r, 1000, "the documented exception: not covered from 4,097 entries");
    }

    function test_split_beyond_masks_at_4097() public {
        // a mask writes less than a restore, so it is still covered here (measured 1.107 / 1.029)
        _beyond(
            "beyond: masks at 4,097 entries",
            _farAcross(9, COVERED_UP_TO, false),
            new bytes[](9),
            1000,
            1150
        );
    }

    /// A re-bind never searches (design §10.4: `T_REBIND` only stamps the scope head and moves no yes-count): number
    /// changes of a far entry across nine places in lists of `LIST_LENGTH_CLAIM` + 1 entries cost what they cost in
    /// one-entry lists.
    function test_split_rebinds_across_lists_at_the_claim() public {
        uint256 n = 9;
        vm.pauseGasMetering();
        bytes32[] memory t = _topics("rb-", n);
        bytes32[] memory last = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            bytes32[] memory x =
                _list(t[i], string.concat("rb-", vm.toString(i)), LIST_LENGTH_CLAIM + 1);
            last[i] = x[LIST_LENGTH_CLAIM];
        }
        vm.resumeGasMetering();
        _row(
            "number changes of a far entry across places",
            REBIND,
            _across(t, last, 1, 7, true),
            new bytes[](n)
        );
    }

    /// Two statements at one position in one publication (outside what the floor claims, docs/WORK-MODEL-V3.md §3.5):
    /// the quote reads the author's heads before the publication, so a first yes followed by a mask of the same
    /// position is quoted as two first statements, though the mask is a later one. In short lists the first row still
    /// covers the mask (measured per pair 1.420 prague, 1.467 amsterdam); the ratio is pinned so a change shows.
    function test_split_two_statements_at_one_position() public {
        bytes32[] memory x = _things("pair");
        uint256 n = 16;
        Action[] memory a = new Action[](2 * n);
        for (uint256 i; i < n; ++i) {
            a[2 * i] = EfsTopics.tag(topic, x[i], 0, 0);
            a[2 * i + 1] = EfsTopics.deny(topic, x[i], 1, 0);
        }
        Action[] memory one = new Action[](2);
        (one[0], one[1]) = (a[0], a[1]);
        Shot memory s1 = _shot(one, new bytes[](2));
        Shot memory sn = _shot(a, new bytes[](2 * n));
        uint256 ratio = (sn.prefixFloor - s1.prefixFloor) * 1000 / (sn.spend - s1.spend);
        emit log_named_uint("split per pair (first yes, then a mask): quote / spend x1000", ratio);
        assertGe(
            ratio,
            _amsterdam() ? 1350 : 1300,
            "two statements at one position: the ratio moved down"
        );
        assertLe(
            ratio, _amsterdam() ? 1600 : 1550, "two statements at one position: the ratio moved up"
        );
    }

    // ---- indexFloor: an upper bound whatever the work model --------------------------------------------------------

    /// With no principal the quote takes the larger of the two rows in each field (design §10.4), so `indexFloor` is at
    /// or above the kernel's quote of the same publication by any author, even under a work model whose later row
    /// out-quotes its first row at every price; checked with generation 1's model and with such a model (mocked).
    function test_index_floor_bounds_every_author_whatever_the_rows() public {
        bytes32[] memory x = _things("ub");
        _execAs(address(this), _tags(x, 0, 0, true), new bytes[](N));
        Action[] memory later = _tags(x, 1, 0, false); // masks: later statements for this principal
        Action[] memory first = _tags(_things("ub-first"), 0, 0, false); // first statements
        ILedgerCommitments c = ILedgerCommitments(r.hot.ingress());
        for (uint256 m; m < 2; ++m) {
            if (m == 1) {
                WorkModel memory w = IndexDoubleDefaults.workModel();
                (w.freshPerBindLater, w.rwPerBindLater, w.computePerBindLater) = (90, 200, 400_000);
                vm.mockCall(
                    address(r.g.index),
                    abi.encodeWithSelector(IIndexReads.workModel.selector),
                    abi.encode(w)
                );
            }
            (uint32 boundLater,,,) = c.indexFloor(address(r.ledger), later);
            (uint32 boundFirst,,,) = c.indexFloor(address(r.ledger), first);
            uint32 realLater = _kernelPrefixFloor(later, new bytes[](N), _ctx(later), address(0));
            uint32 realFirst = _kernelPrefixFloor(first, new bytes[](N), _ctx(first), address(0));
            assertGe(boundLater, realLater, "indexFloor bounds a publication of later statements");
            assertGe(boundFirst, realFirst, "indexFloor bounds a publication of first statements");
            if (m == 1) {
                assertGt(realLater, realFirst, "this model's later row out-quotes its first row");
            }
        }
        vm.clearMockedCalls();
    }
}
