// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {FilesRecipesBase} from "./FilesRecipesBase.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {
    Action,
    ActionKind,
    FamilyId,
    Native,
    Purpose,
    TypeId
} from "../../src/interfaces/Actions.sol";
import {E_INDEX_CALL} from "../../src/interfaces/Errors.sol";
import {E_FILES_FINAL} from "../../src/profiles/FilesProfile.sol";
import {BasisCommit, Status} from "../../src/interfaces/Results.sol";
import {Cursor, Page} from "../../src/interfaces/Readers.sol";
import {LedgerReads} from "../../src/readers/LedgerReads.sol";
import {LedgerViews} from "../../src/readers/LedgerViews.sol";
import {LensReader} from "../../src/readers/LensReader.sol";

/// @notice Measurements for docs/TAG-OPTIONS.md, option (a): what the generic binding path that exists today costs
///         when it carries a tag. Nothing here defines a tag: the TAG purpose is an ordinary purpose to the kernel
///         and the generation-1 index, with no Type, rule or validator of its own. The shape measured is one
///         binding per (concept, target) pair: position `(TAG, concept, role = target)`, target = the tagged
///         subject. `concept` is an arbitrary 32-byte id (a position's subject need not exist; a target must).
///         Writes are cooled like `GasModel.t.sol`, so each publication pays what a transaction of its own pays.
///         Logs: `tag <key> gas` (and `frame state gas` under the amsterdam profile).
contract TagPathMeasureTest is FilesRecipesBase {
    uint256 internal constant N = 60;
    // SPIKE (tags/topics): every concept is a registered topic (a `topic-word/1` page), registered in `setUp`, so
    // the first-tag check of `FilesFinalValidator` admits it
    bytes32 internal X;
    bytes32 internal Y;

    address[] internal cold;
    bytes32[N] internal s; // CREATE subjects of p: the tagged things
    LensReader internal lens;

    function setUp() public override {
        super.setUp();
        lens = new LensReader(
            address(r.ledger), address(new LedgerViews()), address(new LedgerReads())
        );
        for (uint256 i; i < 10; ++i) {
            _remember(instances[i]);
        }
        _remember(address(validator));
        _remember(address(r.k.ingress));
        _remember(address(r.k.applyDelegate));
        _remember(address(r.k.control));
        _remember(address(r.k.implementation));
        _remember(r.k.proxy);
        _remember(address(r.g.posting));
        _remember(address(r.g.bitmap));
        _remember(address(r.g.index));
        _remember(address(r.registryImpl));
        _remember(address(r.registry));
        for (uint256 from; from < N; from += 20) {
            Action[] memory a = new Action[](20);
            for (uint256 i; i < 20; ++i) {
                a[i] = _create(keccak256(abi.encode("tagged", from + i)));
                s[from + i] = Keys.subject(p, a[i].salt);
            }
            r.ledger.execute(a, new bytes[](20), _ctx(a), "");
        }
        X = _registerWords("measure-x", 1);
        Y = _registerWords("measure-y", 1);
        _registerWords("fresh-", 32);
        _registerWords("concept-", 8);
    }

    /// Publishes the word pages `prefix` (n == 1) or `prefix0..prefix{n-1}`; returns the first page's id.
    function _registerWords(string memory prefix, uint256 n) internal returns (bytes32 first) {
        Action[] memory a = new Action[](n);
        bytes[] memory b = new bytes[](n);
        for (uint256 i; i < n; ++i) {
            bytes memory w = n == 1 ? bytes(prefix) : abi.encodePacked(prefix, vm.toString(i));
            (a[i], b[i]) = _wordPage(w);
        }
        r.ledger.execute(a, b, _ctx(a), "");
        first = Keys.record(a[0].typeId, b[0]);
    }

    function _c8(uint256 i) internal view returns (bytes32) {
        return _wordId(abi.encodePacked("concept-", vm.toString(i)));
    }

    function _remember(address a) internal {
        cold.push(a);
    }

    function _cool() internal {
        for (uint256 i; i < cold.length; ++i) {
            vm.cool(cold[i]);
        }
        vm.cool(address(lens));
    }

    function _beforeExecute() internal override {
        _cool();
    }

    function _tags(bytes32 concept, uint256 from, uint256 n)
        internal
        view
        returns (Action[] memory a)
    {
        a = new Action[](n);
        for (uint256 i; i < n; ++i) {
            a[i] = _bind(Purpose.TAG, concept, s[from + i], s[from + i], 0);
        }
    }

    function _run(string memory key, Action[] memory a) internal {
        _exec(string.concat("tag ", key), a, new bytes[](a.length));
    }

    function _silent(Action[] memory a) internal {
        r.ledger.execute(a, new bytes[](a.length), _ctx(a), "");
    }

    function _one(Action memory x) internal pure returns (Action[] memory a) {
        a = new Action[](1);
        a[0] = x;
    }

    // ---- writes -----------------------------------------------------------------------------------------------

    /// One tag alone, two in one publication, ten in one publication (the first members of a concept).
    function test_assert() public {
        _run("assert k1", _tags(X, 0, 1));
        _run("assert k2", _tags(X, 1, 2));
        _run("assert k10", _tags(X, 3, 10));
        _run("assert k40", _tags(X, 13, 40));
    }

    /// The other key order: position (TAG, target, role = concept). Same kernel work, other lists.
    /// SPIKE (tags/topics): a first tag's subject must be a registered topic or a home, so this key order is now
    /// refused (`E_FILES_FINAL(7, leaf)`) when the target is a created subject; the rows assert the refusal.
    function test_assert_keyed_by_target() public {
        Action[] memory a = new Action[](1);
        a[0] = _bind(Purpose.TAG, s[0], X, s[0], 0);
        _refuse7(a, 0);
        a = new Action[](2);
        a[0] = _bind(Purpose.TAG, s[1], X, s[1], 0);
        a[1] = _bind(Purpose.TAG, s[2], X, s[2], 0);
        _refuse7(a, 0);
    }

    function _refuse7(Action[] memory a, uint8 leaf) internal {
        Native memory c = _ctx(a);
        vm.expectRevert(
            abi.encodeWithSelector(
                E_INDEX_CALL.selector,
                abi.encodeWithSelector(E_FILES_FINAL.selector, uint8(7), leaf)
            )
        );
        r.ledger.execute(a, new bytes[](a.length), c, "");
    }

    /// Deny after an assertion (UNBIND = mask), assert again, deny, then back to silent (RELEASE).
    function test_deny_reassert_silent() public {
        _silent(_tags(X, 0, 3));
        bytes32 key = Keys.binding(p, Keys.position(Purpose.TAG, X, s[0]));
        (, uint64 rev,,,,,) = r.hot.head(key);
        _run(
            "deny (mask an assertion)",
            _one(_bindKind(ActionKind.UNBIND, Purpose.TAG, X, s[0], 0, rev))
        );
        (, rev,,,,,) = r.hot.head(key);
        _run("re-assert a denied tag", _one(_bind(Purpose.TAG, X, s[0], s[0], rev)));
        (, rev,,,,,) = r.hot.head(key);
        _silent(_one(_bindKind(ActionKind.UNBIND, Purpose.TAG, X, s[0], 0, rev)));
        (, rev,,,,,) = r.hot.head(key);
        _run(
            "silent again (release a denial)",
            _one(_bindKind(ActionKind.RELEASE, Purpose.TAG, X, s[0], 0, rev))
        );
    }

    /// A denial of something this author never asserted. On main the kernel masks only a BOUND head, so it is
    /// refused alone and costs an assertion plus a mask (measured in one publication if the kernel takes both, else
    /// two). SPIKE (T-4): it is accepted alone; the assert + mask row is kept for comparison.
    function test_deny_without_a_prior_assertion() public {
        Action[] memory a = new Action[](2);
        a[0] = _bind(Purpose.TAG, X, s[5], s[5], 0);
        a[1] = _bindKind(ActionKind.UNBIND, Purpose.TAG, X, s[5], 0, 1);
        bytes[] memory b = new bytes[](2);
        try this.both(a, b) {
            emit log_named_uint("tag deny from silent: one publication of two actions", 1);
        } catch {
            emit log_named_uint("tag deny from silent: one publication of two actions", 0);
            _run("deny from silent, step 1 (assert)", _one(a[0]));
            (, uint64 rev,,,,,) = r.hot.head(Keys.binding(p, Keys.position(Purpose.TAG, X, s[5])));
            _run(
                "deny from silent, step 2 (mask)",
                _one(_bindKind(ActionKind.UNBIND, Purpose.TAG, X, s[5], 0, rev))
            );
        }
    }

    /// SPIKE (T-4): the same denial, one action, is accepted alone.
    function test_deny_alone_is_accepted() public {
        Action[] memory a = _one(_bindKind(ActionKind.UNBIND, Purpose.TAG, X, s[5], 0, 0));
        bytes[] memory b = new bytes[](1);
        try r.ledger.execute(a, b, _ctx(a), "") {
            emit log_named_uint("tag deny from silent: accepted alone", 1);
        } catch {
            emit log_named_uint("tag deny from silent: accepted alone", 0);
        }
    }

    // ---- SPIKE (T-4): a denial that stands on its own -------------------------------------------------------

    function _denies(bytes32 concept, uint256 from, uint256 n)
        internal
        view
        returns (Action[] memory a)
    {
        a = new Action[](n);
        for (uint256 i; i < n; ++i) {
            a[i] = _bindKind(ActionKind.UNBIND, Purpose.TAG, concept, s[from + i], 0, 0);
        }
    }

    function _concept(uint256 i) internal view returns (bytes32) {
        return _wordId(abi.encodePacked("fresh-", vm.toString(i)));
    }

    /// Fresh (zero → non-zero) storage words one publication writes, from a state diff on a snapshot that is
    /// then reverted (so the measured run that follows is unaffected).
    function _freshWords(string memory key, Action[] memory a) internal {
        uint256 snap = vm.snapshotState();
        vm.startStateDiffRecording();
        r.ledger.execute(a, new bytes[](a.length), _ctx(a), "");
        Vm.AccountAccess[] memory acc = vm.stopAndReturnStateDiff();
        uint256 n;
        bytes32[] memory seen = new bytes32[](512);
        for (uint256 i; i < acc.length; ++i) {
            if (acc[i].reverted) continue;
            for (uint256 j; j < acc[i].storageAccesses.length; ++j) {
                Vm.StorageAccess memory x = acc[i].storageAccesses[j];
                if (!x.isWrite || x.reverted || x.previousValue != 0 || x.newValue == 0) continue;
                bytes32 id = keccak256(abi.encode(x.account, x.slot));
                bool dup;
                for (uint256 m; m < n; ++m) {
                    if (seen[m] == id) dup = true;
                }
                if (!dup) seen[n++] = id;
            }
        }
        emit log_named_uint(string.concat("tag ", key, " fresh words"), n);
        vm.revertToState(snap);
    }

    /// Deny from UNSET: one action. Alone, then 2 and 10 in one publication as later members of concept X (the
    /// same order as `test_assert`), then 2 and 10 as the first members of fresh concepts; the matching assert rows
    /// for fresh concepts are measured in `test_assert_first_members`.
    function test_deny_from_unset() public {
        _freshWords("deny-unset k1", _denies(X, 0, 1));
        _run("deny-unset k1", _denies(X, 0, 1));
        _freshWords("deny-unset later k1", _denies(X, 1, 1));
        _run("deny-unset k2", _denies(X, 1, 2));
        _run("deny-unset k10", _denies(X, 3, 10));
        Action[] memory a = _denies(_concept(1), 13, 2);
        a[1].subject = _concept(2);
        _run("deny-unset k2 first members", a);
        a = _denies(_concept(3), 15, 10);
        for (uint256 i; i < 10; ++i) {
            a[i].subject = _concept(10 + i);
        }
        _run("deny-unset k10 first members", a);
    }

    function test_assert_first_members() public {
        _freshWords("assert k1", _tags(X, 0, 1));
        Action[] memory a = _tags(_concept(1), 13, 2);
        a[1].subject = _concept(2);
        _run("assert k2 first members", a);
        a = _tags(_concept(3), 15, 10);
        for (uint256 i; i < 10; ++i) {
            a[i].subject = _concept(10 + i);
        }
        _run("assert k10 first members", a);
        _silent(_tags(X, 0, 1));
        _freshWords("assert later k1", _tags(X, 1, 1));
    }

    /// Deny from RELEASED (assert, then back to silent, then deny alone); restore over a first mask; release a
    /// first mask.
    function test_deny_lifecycle() public {
        _silent(_tags(X, 0, 3));
        bytes32 key = Keys.binding(p, Keys.position(Purpose.TAG, X, s[0]));
        _silent(_one(_bindKind(ActionKind.RELEASE, Purpose.TAG, X, s[0], 0, 1)));
        _freshWords(
            "deny-released k1", _one(_bindKind(ActionKind.UNBIND, Purpose.TAG, X, s[0], 0, 2))
        );
        _run("deny-released k1", _one(_bindKind(ActionKind.UNBIND, Purpose.TAG, X, s[0], 0, 2)));
        (uint8 state,,,,,,) = r.hot.head(key);
        assertEq(state, 2);
        _silent(_denies(X, 5, 2));
        _run("assert over a first mask (restore)", _one(_bind(Purpose.TAG, X, s[5], s[5], 1)));
        _run(
            "release a first mask", _one(_bindKind(ActionKind.RELEASE, Purpose.TAG, X, s[6], 0, 1))
        );
        (state,,,,,,) = r.hot.head(Keys.binding(p, Keys.position(Purpose.TAG, X, s[5])));
        assertEq(state, 1);
        (state,,,,,,) = r.hot.head(Keys.binding(p, Keys.position(Purpose.TAG, X, s[6])));
        assertEq(state, 3);
    }

    /// The member page of `test_read_members_of_a_concept` (53 entries, 3 denied), with the 3 denials written as
    /// first masks instead of assert + mask: they must not appear and should cost what masked entries cost.
    function test_read_members_with_first_masks() public {
        Action[] memory a = new Action[](53);
        for (uint256 i; i < 53; ++i) {
            a[i] = i % 7 == 0 && i < 21
                ? _bindKind(ActionKind.UNBIND, Purpose.TAG, X, s[i], 0, 0)
                : _bind(Purpose.TAG, X, s[i], s[i], 0);
        }
        Action[] memory part = new Action[](20);
        for (uint256 from; from < 53; from += 20) {
            uint256 n = from + 20 > 53 ? 53 - from : 20;
            if (n != part.length) part = new Action[](n);
            for (uint256 i; i < n; ++i) {
                part[i] = a[from + i];
            }
            _silent(part);
        }
        (uint256 g, uint256 rows, uint8 scan) = _members(10);
        emit log_named_uint("tag read members (first masks): page of 10, gas", g);
        emit log_named_uint("tag read members (first masks): page of 10, rows", rows);
        (g, rows, scan) = _members(50);
        emit log_named_uint("tag read members (first masks): page of 50, gas", g);
        emit log_named_uint("tag read members (first masks): page of 50, rows", rows);
        emit log_named_uint("tag read members (first masks): page of 50, scan status", scan);
    }

    /// The role-scope list of a target with 8 concepts, 3 of them denials written as first masks: the list
    /// finds all 8, and the head read tells the 3 denials apart.
    function test_read_concepts_on_a_target_with_first_masks() public {
        bytes32 target = s[0];
        Action[] memory a = new Action[](8);
        for (uint256 i; i < 8; ++i) {
            bytes32 c = _c8(i);
            a[i] = i % 3 == 1
                ? _bindKind(ActionKind.UNBIND, Purpose.TAG, c, target, 0, 0)
                : _bind(Purpose.TAG, c, target, target, 0);
        }
        _silent(a);
        _cool();
        uint256 before = gasleft();
        (, uint64[] memory entries,) = r.g.index
            .postingSliceOf(
                FamilyId.wrap(Keys.familyId("role-scope")),
                TypeId.wrap(0),
                0,
                Keys.roleScope(p, Purpose.TAG, target),
                0,
                16
            );
        uint256 listGas = before - gasleft();
        assertEq(entries.length, 8);
        emit log_named_uint(
            "tag read concepts on a target (first masks): role-scope entries", entries.length
        );
        emit log_named_uint("tag read concepts on a target (first masks): list gas", listGas);
        before = gasleft();
        uint256 denied;
        for (uint256 i; i < 8; ++i) {
            bytes32 key = Keys.binding(p, Keys.position(Purpose.TAG, _c8(i), target));
            (uint8 state,,,,,,) = r.hot.head(key);
            if (state == 2) ++denied;
        }
        emit log_named_uint(
            "tag read concepts on a target (first masks): 8 head reads gas", before - gasleft()
        );
        assertEq(denied, 3);
    }

    /// Entry 48 is the first scope entry whose live bit lives outside the scope head, in a fresh bitmap word: a first
    /// mask there sets the bit and clears it again in one transaction (0 -> 1 -> 0 on a fresh word).
    function test_deny_and_assert_at_entry_48() public {
        _silent(_tags(X, 0, 20));
        _silent(_tags(X, 20, 20));
        _silent(_tags(X, 40, 8));
        _freshWords("deny-unset at entry 48", _denies(X, 48, 1));
        _freshWords("assert at entry 48", _tags(X, 48, 1));
        uint256 snap = vm.snapshotState();
        _run("deny-unset at entry 48", _denies(X, 48, 1));
        vm.revertToState(snap);
        _run("assert at entry 48", _tags(X, 48, 1));
    }

    function both(Action[] calldata a, bytes[] calldata b) external {
        require(msg.sender == address(this));
        _exec("tag deny from silent (assert + mask in one publication)", a, b);
    }

    // ---- reads ------------------------------------------------------------------------------------------------

    function _members(uint32 budget)
        internal
        returns (uint256 gasUsed, uint256 rows, uint8 scanStatus)
    {
        bytes32[] memory l = new bytes32[](1);
        l[0] = p;
        Cursor memory c;
        BasisCommit memory b;
        _cool();
        uint256 before = gasleft();
        Page memory page = lens.list(l, Purpose.TAG, X, c, budget, 1, b);
        gasUsed = before - gasleft();
        assertEq(uint8(page.q.status), uint8(Status.PRESENT));
        return (gasUsed, page.rows.length, page.scanStatus);
    }

    /// "Everything tagged X by this author", one lens principal, in pages of 10 and 50, 53 members with 3 denied.
    function test_read_members_of_a_concept() public {
        _silent(_tags(X, 0, 20));
        _silent(_tags(X, 20, 20));
        _silent(_tags(X, 40, 13));
        for (uint256 i; i < 3; ++i) {
            _silent(_one(_bindKind(ActionKind.UNBIND, Purpose.TAG, X, s[i * 7], 0, 1)));
        }
        (uint256 g, uint256 rows, uint8 scan) = _members(10);
        emit log_named_uint("tag read members: page of 10, gas", g);
        emit log_named_uint("tag read members: page of 10, rows", rows);
        (g, rows, scan) = _members(50);
        emit log_named_uint("tag read members: page of 50, gas", g);
        emit log_named_uint("tag read members: page of 50, rows", rows);
        emit log_named_uint("tag read members: page of 50, scan status", scan);
    }

    /// "Which concepts did this author put on this target": the role-scope list of (author, TAG, role = target),
    /// then one head read per entry to see whether it is still asserted.
    function test_read_concepts_on_a_target() public {
        bytes32 target = s[0];
        Action[] memory a = new Action[](8);
        for (uint256 i; i < 8; ++i) {
            a[i] = _bind(Purpose.TAG, _c8(i), target, target, 0);
        }
        _silent(a);
        _cool();
        uint256 before = gasleft();
        (, uint64[] memory entries,) = r.g.index
            .postingSliceOf(
                FamilyId.wrap(Keys.familyId("role-scope")),
                TypeId.wrap(0),
                0,
                Keys.roleScope(p, Purpose.TAG, target),
                0,
                16
            );
        uint256 listGas = before - gasleft();
        emit log_named_uint("tag read concepts on a target: role-scope entries", entries.length);
        emit log_named_uint("tag read concepts on a target: list gas", listGas);
        before = gasleft();
        for (uint256 i; i < 8; ++i) {
            bytes32 key = Keys.binding(p, Keys.position(Purpose.TAG, _c8(i), target));
            (uint8 state,,,,,,) = r.hot.head(key);
            assertEq(state, 1);
        }
        emit log_named_uint("tag read concepts on a target: 8 head reads gas", before - gasleft());
    }

    /// "Is this target tagged X" for one author: one head read, cold.
    function test_read_one_membership() public {
        _silent(_tags(X, 0, 1));
        bytes32 key = Keys.binding(p, Keys.position(Purpose.TAG, X, s[0]));
        _cool();
        uint256 before = gasleft();
        (uint8 state,,,,,,) = r.hot.head(key);
        emit log_named_uint("tag read one membership: head gas", before - gasleft());
        assertEq(state, 1);
        Y; // the second concept id is reserved for a later row
    }
}
