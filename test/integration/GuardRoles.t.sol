// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FilesRecipesBase} from "./FilesRecipesBase.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {EfsTopics} from "../../src/lib/EfsTopics.sol";
import {Layout} from "../../src/core/layout/Layout.sol";
import {
    Action,
    ActionKind,
    Capability,
    Native,
    Purpose,
    ReadSet
} from "../../src/interfaces/Actions.sol";
import {ILedgerCommitments} from "../../src/interfaces/ILedgerCommitments.sol";
import {E_INDEX_CALL, E_READSET_STALE} from "../../src/interfaces/Errors.sol";
import {E_FILES_FINAL} from "../../src/profiles/FilesProfile.sol";
import {LedgerViews} from "../../src/readers/LedgerViews.sol";

/// @notice The planner's guard rule for the role-targeted purposes, tied to the validator that makes it true.
///         `tools/RELEASE.md` item 61, third table row: for a MASKED or RELEASED head whose purpose is TAG, SAME or
///         BROADER, the target in the head's snapshot (the stored word the read-set guard hashes, profile 2) is the
///         position's ROLE, with no read, because `FilesFinalValidator` refuses every BIND there whose target is not
///         the role: code 14 for TAG (first bind, re-bind, restore) and code 13 for SAME and BROADER. So the last
///         bound target of a once-bound head at such a position is always its role.
///
///         On the Files Realm with the real validator and b0 `NATIVE_GUARD` on, for each of the three purposes:
///         the refusals that make the row true; the stored word is the role after BIND, UNBIND, RELEASE and a
///         later UNBIND while the canonical head read serves 0 once the head is not BOUND; a first "not this" (a
///         lone no) stores 0; a guard computed exactly as item 61 says (state, revision, admission from the head
///         read, target = the role) is admitted while the same guard with target 0 is `E_READSET_STALE` (the lone
///         no the other way round); and a restore guarded from the role is admitted.
/// @dev What moves together: if the validator's codes 13 or 14 change (renumbered, narrowed to the first bind,
///      or dropped), item 61's third row, the SDK's guard planner for TAG/SAME/BROADER (which hashes the role
///      without reading `headSnapshots`), these tests and the validator's NatSpec code table must all change in one
///      release. If the validator stops refusing a bind whose target is not the role, the row is false: such a
///      planner must read the target (item 62's `targets`) like any other purpose.
contract GuardRolesTest is FilesRecipesBase {
    EfsTopics.Types internal tt;
    LedgerViews internal views;
    ILedgerCommitments internal cm;
    uint256 internal saltCounter;

    /// One purpose's positions: (purpose, subject, role) is the once-bound position; `wrong` is an existing id that
    /// is not the role (the kernel admits it as a target; the validator must not); `loneRole` names a fresh position
    /// of the same purpose and subject for a first "not this".
    struct Case {
        bytes32 purpose;
        bytes32 subject;
        bytes32 role;
        bytes32 wrong;
        bytes32 loneRole;
        uint8 code;
    }

    /// A head as the canonical read serves it, and as stored (word 0 unpacked, word +1 raw).
    struct Seen {
        uint8 state;
        uint64 revision;
        uint64 admission;
        bytes32 target; // canonical: 0 unless BOUND
        uint8 rawTargetKind;
        bytes32 rawWord;
    }

    function _capabilities() internal pure override returns (uint16) {
        return Capability.NATIVE_GUARD;
    }

    function setUp() public override {
        super.setUp();
        tt = _topicTypes();
        views = new LedgerViews();
        cm = ILedgerCommitments(r.hot.ingress());
    }

    // ---- the three cases -----------------------------------------------------------------------------------------

    function _subjectNamed(string memory salt) internal returns (bytes32) {
        _execAs(address(this), _one(_create(keccak256(bytes(salt)))), new bytes[](1));
        return Keys.subject(p, keccak256(bytes(salt)));
    }

    function _word(string memory w) internal returns (bytes32 page) {
        (Action[] memory a, bytes[] memory b, bytes32 id) = EfsTopics.registerWord(tt, bytes(w));
        _execAs(address(this), a, b);
        return id;
    }

    /// TAG: (topic, role = thing) → thing; the wrong target is another created subject.
    function _tagCase() internal returns (Case memory c) {
        c.purpose = Purpose.TAG;
        c.subject = _word("guard-roles");
        c.role = _subjectNamed("guard-roles/thing");
        c.wrong = _subjectNamed("guard-roles/other");
        c.loneRole = _subjectNamed("guard-roles/lone");
        c.code = 14;
    }

    /// SAME or BROADER: (topic, role = other topic) → the other topic; the wrong target is a third topic.
    function _relationCase(bytes32 purpose) internal returns (Case memory c) {
        c.purpose = purpose;
        c.subject = _word("alpha");
        c.role = _word("beta");
        c.wrong = _word("gamma");
        c.loneRole = _word("delta");
        c.code = 13;
    }

    // ---- builders and reads --------------------------------------------------------------------------------------

    function _one(Action memory x) internal pure returns (Action[] memory a) {
        a = new Action[](1);
        a[0] = x;
    }

    function _pos(Case memory c) internal pure returns (bytes32) {
        return Keys.position(c.purpose, c.subject, c.role);
    }

    function _lonePos(Case memory c) internal pure returns (bytes32) {
        return Keys.position(c.purpose, c.subject, c.loneRole);
    }

    function _bindTo(Case memory c, bytes32 target, uint64 expected)
        internal
        pure
        returns (Action memory)
    {
        return _bind(c.purpose, c.subject, c.role, target, expected);
    }

    function _unbind(Case memory c, bytes32 role, uint64 expected)
        internal
        pure
        returns (Action memory)
    {
        return _bindKind(ActionKind.UNBIND, c.purpose, c.subject, role, 0, expected);
    }

    function _release(Case memory c, uint64 expected) internal pure returns (Action memory) {
        return _bindKind(ActionKind.RELEASE, c.purpose, c.subject, c.role, 0, expected);
    }

    function _seen(bytes32 position) internal view returns (Seen memory s) {
        bytes32 key = Keys.binding(p, position);
        (s.state, s.revision, s.admission,,,, s.target,) = r.hot.head(key);
        uint256 slot = Layout.bindingsHeadsSlot(key);
        (,,, s.rawTargetKind,,,,) = Layout.unpackHeadRowWord0(r.hot.extsload(bytes32(slot)));
        s.rawWord = r.hot.extsload(bytes32(slot + 1));
    }

    function _targetsOf(bytes32 position) internal view returns (bytes32 snapshot, bytes32 target) {
        bytes32[] memory pr = new bytes32[](1);
        bytes32[] memory po = new bytes32[](1);
        (pr[0], po[0]) = (p, position);
        (bytes32[] memory snapshots, bytes32[] memory targets) =
            views.headSnapshots(address(r.ledger), pr, po);
        return (snapshots[0], targets[0]);
    }

    /// Item 61's computation: (state, revision, admission) from the canonical head read, the target given.
    function _planned(Seen memory s, bytes32 target) internal view returns (bytes32) {
        return cm.headSnapshotHash(s.state, s.revision, s.admission, target);
    }

    function _guard(bytes32 position, bytes32 expected) internal view returns (bytes memory) {
        bytes32[] memory pr = new bytes32[](1);
        bytes32[] memory po = new bytes32[](1);
        bytes32[] memory h = new bytes32[](1);
        (pr[0], po[0], h[0]) = (p, position, expected);
        return abi.encode(ReadSet(pr, po, h));
    }

    /// A CREATE with a fresh salt: touches no head.
    function _touchNothing() internal returns (Action[] memory) {
        return _one(_create(keccak256(abi.encode("guard-roles/salt", ++saltCounter))));
    }

    function _execG(Action[] memory a, bytes memory guard) internal {
        Native memory c = _ctx(a);
        r.ledger.execute(a, new bytes[](a.length), c, guard);
    }

    function _refuseG(Action[] memory a, bytes memory guard, bytes memory err) internal {
        Native memory c = _ctx(a);
        vm.expectRevert(err);
        r.ledger.execute(a, new bytes[](a.length), c, guard);
    }

    function _exec1(Action memory x) internal {
        _execAs(address(this), _one(x), new bytes[](1));
    }

    function _refusedByValidator(Action memory x, uint8 code) internal {
        Native memory c = _ctx(_one(x));
        vm.expectRevert(
            abi.encodeWithSelector(
                E_INDEX_CALL.selector,
                abi.encodeWithSelector(E_FILES_FINAL.selector, code, uint8(0))
            )
        );
        r.ledger.execute(_one(x), new bytes[](1), c, "");
    }

    function _stale(bytes32 position) internal view returns (bytes memory) {
        return abi.encodeWithSelector(E_READSET_STALE.selector, position, p);
    }

    // ---- the checks ----------------------------------------------------------------------------------------------

    /// After a statement at a once-bound position: the stored word is the role, `headSnapshots` names it, and the
    /// canonical read serves the role only while BOUND (0 otherwise).
    function _assertStoresRole(Case memory c, uint8 state, string memory step)
        internal
        view
        returns (Seen memory s)
    {
        s = _seen(_pos(c));
        assertEq(s.state, state, string.concat(step, ": head state"));
        assertEq(s.rawWord, c.role, string.concat(step, ": the stored word is the role"));
        assertTrue(s.rawTargetKind != 0, string.concat(step, ": targetKind is not 0"));
        (bytes32 snapshot, bytes32 target) = _targetsOf(_pos(c));
        assertEq(target, c.role, string.concat(step, ": headSnapshots.targets is the role"));
        assertEq(
            snapshot, _planned(s, c.role), string.concat(step, ": headSnapshots hashes the role")
        );
        assertEq(
            s.target,
            state == 1 ? c.role : bytes32(0),
            string.concat(step, ": the canonical head read serves the role only when BOUND")
        );
    }

    /// Item 61 row 3 on a once-bound head that is not BOUND: the guard from the role passes, the guard from 0 is
    /// stale. The target comes from the case's role, never from `headSnapshots`.
    function _assertGuardFromRole(Case memory c, string memory step) internal {
        Seen memory s = _seen(_pos(c));
        assertTrue(s.state != 1, string.concat(step, ": the head is not BOUND"));
        assertEq(s.target, bytes32(0), string.concat(step, ": the head read serves target 0"));
        _execG(_touchNothing(), _guard(_pos(c), _planned(s, c.role)));
        _refuseG(_touchNothing(), _guard(_pos(c), _planned(s, 0)), _stale(_pos(c)));
    }

    // ---- 1. the refusals that make the rule true -----------------------------------------------------------------

    function _refusals(Case memory c) internal {
        _refusedByValidator(_bindTo(c, c.wrong, 0), c.code); // first bind
        _exec1(_bindTo(c, c.role, 0)); // revision 1, BOUND
        _refusedByValidator(_bindTo(c, c.wrong, 1), c.code); // re-bind
        _exec1(_unbind(c, c.role, 1)); // revision 2, MASKED
        _refusedByValidator(_bindTo(c, c.wrong, 2), c.code); // restore
        _exec1(_release(c, 2)); // revision 3, RELEASED
        _refusedByValidator(_bindTo(c, c.wrong, 3), c.code); // a bind on the released head
        Seen memory s = _seen(_pos(c));
        assertEq(s.revision, 3, "bind, mask, release: the refusals landed nothing");
        assertEq(s.rawWord, c.role, "the stored word is still the role");
    }

    function test_tag_bind_whose_target_is_not_the_role_is_refused_code_14() public {
        _refusals(_tagCase());
    }

    function test_same_bind_whose_target_is_not_the_role_is_refused_code_13() public {
        _refusals(_relationCase(Purpose.SAME));
    }

    function test_broader_bind_whose_target_is_not_the_role_is_refused_code_13() public {
        _refusals(_relationCase(Purpose.BROADER));
    }

    // ---- 2 + 4. a removed head keeps the role; the planner's guard from the role passes, from 0 is stale ---------

    function _removedKeepsRole(Case memory c) internal {
        _exec1(_bindTo(c, c.role, 0));
        _assertStoresRole(c, 1, "BIND");
        _exec1(_unbind(c, c.role, 1));
        _assertStoresRole(c, 2, "UNBIND");
        _assertGuardFromRole(c, "MASKED");
        _exec1(_release(c, 2));
        _assertStoresRole(c, 3, "RELEASE");
        _assertGuardFromRole(c, "RELEASED");
        _exec1(_unbind(c, c.role, 3)); // a "no" after the release: MASKED again, once-bound
        _assertStoresRole(c, 2, "UNBIND after RELEASE");
        _assertGuardFromRole(c, "MASKED after RELEASE");
    }

    function test_tag_removed_head_keeps_the_role_and_a_guard_from_the_role_passes() public {
        _removedKeepsRole(_tagCase());
    }

    function test_same_removed_head_keeps_the_role_and_a_guard_from_the_role_passes() public {
        _removedKeepsRole(_relationCase(Purpose.SAME));
    }

    function test_broader_removed_head_keeps_the_role_and_a_guard_from_the_role_passes() public {
        _removedKeepsRole(_relationCase(Purpose.BROADER));
    }

    // ---- 3 + 4. a first "not this" stores 0; the guard from 0 passes, from the role is stale --------------------

    function _loneNoStoresZero(Case memory c) internal {
        bytes32 position = _lonePos(c);
        _exec1(_unbind(c, c.loneRole, 0));
        Seen memory s = _seen(position);
        assertEq(s.state, 2, "a lone no is MASKED");
        assertEq(s.rawWord, bytes32(0), "a lone no stores word 0");
        assertEq(s.rawTargetKind, 0, "a lone no stores targetKind 0");
        (, bytes32 target) = _targetsOf(position);
        assertEq(target, bytes32(0), "headSnapshots.targets is 0 for a lone no");
        _execG(_touchNothing(), _guard(position, _planned(s, 0)));
        _refuseG(_touchNothing(), _guard(position, _planned(s, c.loneRole)), _stale(position));
    }

    function test_tag_first_not_this_stores_zero_and_a_guard_from_zero_passes() public {
        _loneNoStoresZero(_tagCase());
    }

    function test_same_first_not_this_stores_zero_and_a_guard_from_zero_passes() public {
        _loneNoStoresZero(_relationCase(Purpose.SAME));
    }

    function test_broader_first_not_this_stores_zero_and_a_guard_from_zero_passes() public {
        _loneNoStoresZero(_relationCase(Purpose.BROADER));
    }

    // ---- 5. a restore under a guard from the role ----------------------------------------------------------------

    function _guardedRestore(Case memory c) internal {
        _exec1(_bindTo(c, c.role, 0));
        _exec1(_unbind(c, c.role, 1));
        Seen memory s = _seen(_pos(c));
        assertEq(s.state, 2, "MASKED before the restore");
        _execG(_one(_bindTo(c, c.role, s.revision)), _guard(_pos(c), _planned(s, c.role)));
        Seen memory after_ = _seen(_pos(c));
        assertEq(after_.state, 1, "restored: BOUND");
        assertEq(after_.target, c.role, "restored to the role");
    }

    function test_tag_restore_guarded_from_the_role_is_admitted() public {
        _guardedRestore(_tagCase());
    }

    function test_same_restore_guarded_from_the_role_is_admitted() public {
        _guardedRestore(_relationCase(Purpose.SAME));
    }

    function test_broader_restore_guarded_from_the_role_is_admitted() public {
        _guardedRestore(_relationCase(Purpose.BROADER));
    }
}
