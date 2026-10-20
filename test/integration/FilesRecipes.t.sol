// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {FilesFixture} from "../profiles/FilesFixture.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {
    Action,
    ActionKind,
    FamilyId,
    Native,
    Purpose,
    ScopeKey,
    TypeId
} from "../../src/interfaces/Actions.sol";
import {Coverage} from "../../src/interfaces/Results.sol";
import {ClosureConstants} from "../../src/interfaces/Limits.sol";
import {ILedgerCommitments} from "../../src/interfaces/ILedgerCommitments.sol";
import {Readiness} from "../../src/interfaces/Index.sol";
import {
    E_CAS,
    E_INDEX_CALL,
    E_POLICY_REJECTED,
    E_REF,
    E_REJECTED
} from "../../src/interfaces/Errors.sol";
import {E_FILES_FINAL} from "../../src/profiles/FilesProfile.sol";

/// @notice The first-milestone recipes of design §12.2 on the native lane, end to end through the real kernel, the
///         real registry proxy and the real generation-1 index with `FilesFinalValidator` pinned: root seed, create
///         folder, create file, edit (CAS on HEAD), rename + move (atomic), remove, restore, release; the index's
///         folder-scope lists and live bits, backlinks and history after each step; the final hook refusing a FOLDER
///         bind with no name record (nothing lands); a stale CAS refused whole; inline and external content found
///         by sha256 through the digest family; Type ids identical across Realms and chains. Gas of every step is
///         logged (gasleft delta around `execute`, and the callee frame).
contract FilesRecipesTest is FilesFixture {
    Realm internal r;
    bytes32 internal p; // address(this) as a contract principal of the Realm

    bytes32 internal F_BACKLINK = Keys.familyId("backlink");
    bytes32 internal F_HISTORY = Keys.familyId("history");
    bytes32 internal F_BY_TYPE = Keys.familyId("by-type");
    bytes32 internal F_DIGEST = Keys.familyId("digest");
    bytes32 internal F_REFERENCE = Keys.familyId("reference-position");

    bytes32 internal rootSubject;
    bytes32 internal rootDir;

    function setUp() public {
        _deployProfile();
        r = _realm(keccak256("files/realm-a"));
        _register(r);
        p = r.principal;
        // Root (the seed, once per Realm): CREATE(rootSalt), PUBLISH(files-directory/1, rootSubject); no FOLDER bind
        rootSubject = Keys.subject(p, keccak256("root"));
        Action[] memory a = new Action[](2);
        bytes[] memory b = new bytes[](2);
        a[0] = _create(keccak256("root"));
        (a[1], b[1]) = _publish(T_DIRECTORY, abi.encode(rootSubject));
        rootDir = _id(T_DIRECTORY, b[1]);
        _exec("recipe root seed (CREATE + PUBLISH directory)", a, b);
    }

    // ---- builders -----------------------------------------------------------------------------------------------

    function _id(uint8 t, bytes memory body) internal view returns (bytes32) {
        return Keys.record(typeIds[t], body);
    }

    function _create(bytes32 salt) internal pure returns (Action memory a) {
        a.kind = ActionKind.CREATE;
        a.salt = salt;
    }

    function _publish(uint8 t, bytes memory body)
        internal
        view
        returns (Action memory a, bytes memory)
    {
        a.kind = ActionKind.PUBLISH;
        a.typeId = typeIds[t];
        a.bodyHashOrRecordId = keccak256(body);
        return (a, body);
    }

    function _bindKind(
        uint8 kind,
        bytes32 purpose,
        bytes32 subject,
        bytes32 role,
        bytes32 target,
        uint64 expected
    ) internal pure returns (Action memory a) {
        a.kind = kind;
        a.purpose = purpose;
        a.subject = subject;
        a.role = role;
        a.target = target;
        a.expectedRevision = expected;
    }

    function _bind(bytes32 purpose, bytes32 subject, bytes32 role, bytes32 target, uint64 expected)
        internal
        pure
        returns (Action memory)
    {
        return _bindKind(ActionKind.BIND, purpose, subject, role, target, expected);
    }

    /// Both expectations bound (the SDK default, design Q22): the live execution set and the acceptance profile.
    function _ctx(Action[] memory actions) internal view returns (Native memory c) {
        (c.nonce,) = r.hot.nonceOf(p);
        c.expectedExecutionSet = r.hot.executionSet();
        c.expectedAcceptanceProfile =
            ILedgerCommitments(r.hot.ingress()).acceptanceProfileOf(address(r.ledger), actions);
    }

    function _exec(string memory label, Action[] memory actions, bytes[] memory bodies)
        internal
        returns (uint64 publication)
    {
        Native memory c = _ctx(actions);
        uint256 before = gasleft();
        (publication,) = r.ledger.execute(actions, bodies, c, "");
        uint256 used = before - gasleft();
        Vm.Gas memory frame = vm.lastFrameGas();
        emit log_named_uint(string.concat(label, " gas"), used);
        emit log_named_uint(string.concat(label, " frame gas"), frame.gasTotalUsed);
        // EIP-8037 state gas: zero under the release schedule (prague), meaningful under `--profile amsterdam`
        if (frame.gasStateUsed != 0) {
            emit log_named_int(string.concat(label, " frame state gas"), frame.gasStateUsed);
        }
    }

    function _name(bytes memory n) internal view returns (Action memory a, bytes memory) {
        return _publish(T_NAME, n);
    }

    function _key(bytes32 purpose, bytes32 subject, bytes32 role) internal view returns (bytes32) {
        return Keys.binding(p, Keys.position(purpose, subject, role));
    }

    function _scope(bytes32 dir)
        internal
        view
        returns (uint64 count, uint64 live, uint48 bits, uint64 entry0)
    {
        (count, live,, bits,, entry0) =
            r.g.bitmap.scopeHead(ScopeKey.wrap(Keys.scope(p, Purpose.FOLDER, dir)));
    }

    function _posting(bytes32 family, bytes32 typeId, bytes32 value)
        internal
        view
        returns (uint64 count, uint64 live)
    {
        Coverage c;
        (c, count, live,,) =
            r.g.index.postingHeadOf(FamilyId.wrap(family), TypeId.wrap(typeId), 0, value);
        assertEq(uint8(c), uint8(Coverage.COMPLETE), "honest coverage");
    }

    function _head(bytes32 key)
        internal
        view
        returns (uint8 state, uint64 revision, bytes32 target)
    {
        (state, revision,,,,, target) = r.hot.head(key);
    }

    function _assertScope(bytes32 dir, uint64 count, uint64 live, uint48 bits) internal view {
        (uint64 c, uint64 l, uint48 b,) = _scope(dir);
        assertEq(c, count, "scope entries");
        assertEq(l, live, "scope live");
        assertEq(b, bits, "scope live bits");
    }

    function _assertBacklink(bytes32 target, uint64 count, uint64 live) internal view {
        (uint64 c, uint64 l) = _posting(F_BACKLINK, 0, target);
        assertEq(c, count, "backlink entries");
        assertEq(l, live, "backlink live");
    }

    function _assertHistory(bytes32 key, uint64 count) internal view {
        (uint64 c,) = _posting(F_HISTORY, 0, key);
        assertEq(c, count, "history entries");
    }

    // ---- the recipes ---------------------------------------------------------------------------------------------

    function test_root_seed() public view {
        (bytes32 t, uint64 first,,,) = r.hot.recordHeader(rootDir);
        assertEq(t, typeIds[T_DIRECTORY]);
        assertEq(first, 2);
        assertEq(r.hot.subjectCreatedAt(rootSubject), 1);
        _assertScope(rootDir, 0, 0, 0);
        (uint64 count,) = _posting(F_BY_TYPE, typeIds[T_DIRECTORY], 0);
        assertEq(count, 1);
        assertTrue(r.g.index.replayReadiness().ready);
    }

    function test_recipes_folder_file_edit_move_remove_restore_release() public {
        // ---- create folder: CREATE, PUBLISH directory, PUBLISH name, BIND(FOLDER, parent, keccak(name) → dir, 0)
        bytes32 docsSubject = Keys.subject(p, keccak256("docs"));
        Action[] memory a = new Action[](4);
        bytes[] memory b = new bytes[](4);
        a[0] = _create(keccak256("docs"));
        (a[1], b[1]) = _publish(T_DIRECTORY, abi.encode(docsSubject));
        bytes32 docsDir = _id(T_DIRECTORY, b[1]);
        (a[2], b[2]) = _name("docs");
        a[3] = _bind(Purpose.FOLDER, rootDir, keccak256("docs"), docsDir, 0);
        _exec("recipe create folder", a, b);
        bytes32 docsKey = _key(Purpose.FOLDER, rootDir, keccak256("docs"));
        _assertScope(rootDir, 1, 1, 1);
        _assertBacklink(docsDir, 1, 1);
        _assertHistory(docsKey, 1);
        (uint8 state, uint64 rev, bytes32 target) = _head(docsKey);
        assertEq(state, 1);
        assertEq(rev, 1);
        assertEq(target, docsDir);

        // ---- create file: CREATE, PUBLISH root, PUBLISH name, BIND(HEAD, file, 0 → root, 0),
        //      BIND(FOLDER, folder, keccak(name) → file, 0)
        bytes32 file = Keys.subject(p, keccak256("readme"));
        a = new Action[](5);
        b = new bytes[](5);
        a[0] = _create(keccak256("readme"));
        (a[1], b[1]) = _publish(T_ROOT, bytes.concat(abi.encode(file), "Meeting at 10:00.\n"));
        bytes32 rootRec = _id(T_ROOT, b[1]);
        (a[2], b[2]) = _name("readme.txt");
        a[3] = _bind(Purpose.HEAD, file, 0, rootRec, 0);
        a[4] = _bind(Purpose.FOLDER, docsDir, keccak256("readme.txt"), file, 0);
        _exec("recipe create file", a, b);
        bytes32 headKey = _key(Purpose.HEAD, file, 0);
        bytes32 readmeKey = _key(Purpose.FOLDER, docsDir, keccak256("readme.txt"));
        _assertScope(docsDir, 1, 1, 1);
        _assertBacklink(file, 1, 1);
        _assertBacklink(rootRec, 1, 1);
        _assertHistory(readmeKey, 1);
        (, rev, target) = _head(headKey);
        assertEq(rev, 1);
        assertEq(target, rootRec);

        // ---- edit: PUBLISH child, BIND(HEAD, file, 0 → child, exp current)
        a = new Action[](2);
        b = new bytes[](2);
        (a[0], b[0]) =
            _publish(T_CHILD, bytes.concat(abi.encode(rootRec, file), "Meeting at 11:00.\n"));
        bytes32 childRec = _id(T_CHILD, b[0]);
        a[1] = _bind(Purpose.HEAD, file, 0, childRec, 1);
        _exec("recipe edit", a, b);
        (, rev, target) = _head(headKey);
        assertEq(rev, 2);
        assertEq(target, childRec);
        _assertBacklink(rootRec, 1, 0); // released by the REBIND
        _assertBacklink(childRec, 1, 1);
        _assertHistory(headKey, 2);
        (uint64 parents,) = _posting(F_REFERENCE, typeIds[T_CHILD], rootRec);
        assertEq(parents, 1, "the child's parent reference");

        // ---- rename + move: PUBLISH name, UNBIND old FOLDER, BIND new FOLDER, atomically
        a = new Action[](3);
        b = new bytes[](3);
        (a[0], b[0]) = _name("notes.txt");
        a[1] = _bindKind(ActionKind.UNBIND, Purpose.FOLDER, docsDir, keccak256("readme.txt"), 0, 1);
        a[2] = _bind(Purpose.FOLDER, rootDir, keccak256("notes.txt"), file, 0);
        _exec("recipe rename + move", a, b);
        bytes32 notesKey = _key(Purpose.FOLDER, rootDir, keccak256("notes.txt"));
        _assertScope(docsDir, 1, 0, 0);
        _assertScope(rootDir, 2, 2, 3);
        _assertBacklink(file, 2, 1);
        _assertHistory(readmeKey, 2);
        _assertHistory(notesKey, 1);
        (state,,) = _head(readmeKey);
        assertEq(state, 2, "the old placement is masked");

        // ---- remove: UNBIND
        a = new Action[](1);
        b = new bytes[](1);
        a[0] = _bindKind(ActionKind.UNBIND, Purpose.FOLDER, rootDir, keccak256("notes.txt"), 0, 1);
        _exec("recipe remove", a, b);
        _assertScope(rootDir, 2, 1, 1);
        _assertBacklink(file, 2, 0);

        // ---- restore: BIND (the kept target word makes a same-target restore a rewrite)
        a[0] = _bind(Purpose.FOLDER, rootDir, keccak256("notes.txt"), file, 2);
        _exec("recipe restore", a, b);
        _assertScope(rootDir, 2, 2, 3);
        _assertBacklink(file, 3, 1);
        (state, rev, target) = _head(notesKey);
        assertEq(state, 1);
        assertEq(rev, 3);
        assertEq(target, file);

        // ---- stop claiming: RELEASE
        a[0] = _bindKind(ActionKind.RELEASE, Purpose.FOLDER, rootDir, keccak256("notes.txt"), 0, 3);
        _exec("recipe release", a, b);
        (state, rev,) = _head(notesKey);
        assertEq(state, 3, "released");
        assertEq(rev, 4);
        _assertScope(rootDir, 2, 1, 1);
        _assertBacklink(file, 3, 0);
        _assertHistory(notesKey, 4);
        // and the moved file still has its HEAD; the folder entry for docs is untouched
        (, rev, target) = _head(headKey);
        assertEq(target, childRec);
        (state,,) = _head(docsKey);
        assertEq(state, 1);
        assertTrue(r.g.index.replayReadiness().ready);
    }

    function test_mask_then_release_then_restore_a_placement() public {
        bytes32 file = Keys.subject(p, keccak256("cycle"));
        Action[] memory a = new Action[](3);
        bytes[] memory b = new bytes[](3);
        a[0] = _create(keccak256("cycle"));
        (a[1], b[1]) = _name("cycle.txt");
        a[2] = _bind(Purpose.FOLDER, rootDir, keccak256("cycle.txt"), file, 0);
        _exec("recipe create + place", a, b);
        bytes32 key = _key(Purpose.FOLDER, rootDir, keccak256("cycle.txt"));
        a = new Action[](1);
        b = new bytes[](1);
        a[0] = _bindKind(ActionKind.UNBIND, Purpose.FOLDER, rootDir, keccak256("cycle.txt"), 0, 1);
        _exec("recipe remove", a, b);
        // RELEASE from MASKED: no live bit to clear twice, no backlink to release twice
        a[0] = _bindKind(ActionKind.RELEASE, Purpose.FOLDER, rootDir, keccak256("cycle.txt"), 0, 2);
        _exec("recipe release a removed placement", a, b);
        (uint8 state, uint64 rev,) = _head(key);
        assertEq(state, 3);
        assertEq(rev, 3);
        _assertScope(rootDir, 1, 0, 0);
        _assertBacklink(file, 1, 0);
        // BIND from RELEASED is a restore, judged by the final hook like any FOLDER bind
        a[0] = _bind(Purpose.FOLDER, rootDir, keccak256("cycle.txt"), file, 3);
        _exec("recipe restore a released placement", a, b);
        _assertScope(rootDir, 1, 1, 1);
        _assertBacklink(file, 2, 1);
        _assertHistory(key, 4);
    }

    // ---- refusals land nothing ---------------------------------------------------------------------------------

    struct Snapshot {
        uint64 admissions;
        uint64 records;
        uint64 bindings;
        uint64 publications;
        uint64 nonce;
        uint64 processed;
        uint64 scopeCount;
        uint64 scopeLive;
        uint64 backlinks;
    }

    function _snapshot(bytes32 dir, bytes32 target) internal view returns (Snapshot memory s) {
        (s.admissions, s.records, s.bindings, s.publications) = r.hot.counts();
        (s.nonce,) = r.hot.nonceOf(p);
        (s.processed,,) = r.g.index.progress();
        (s.scopeCount, s.scopeLive,,) = _scope(dir);
        (s.backlinks,) = _posting(F_BACKLINK, 0, target);
    }

    function _assertSame(Snapshot memory x, Snapshot memory y) internal pure {
        assertEq(keccak256(abi.encode(x)), keccak256(abi.encode(y)), "nothing landed");
    }

    function test_folder_bind_without_a_name_record_lands_nothing() public {
        bytes32 file = Keys.subject(p, keccak256("nameless"));
        Action[] memory a = new Action[](2);
        a[0] = _create(keccak256("nameless"));
        a[1] = _bind(Purpose.FOLDER, rootDir, keccak256("never-published.txt"), file, 0);
        bytes[] memory b = new bytes[](2);
        Snapshot memory before = _snapshot(rootDir, file);
        Native memory c = _ctx(a);
        vm.expectRevert(
            abi.encodeWithSelector(
                E_INDEX_CALL.selector,
                abi.encodeWithSelector(E_FILES_FINAL.selector, uint8(1), uint8(1))
            )
        );
        r.ledger.execute(a, b, c, "");
        _assertSame(before, _snapshot(rootDir, file));
        assertEq(r.hot.subjectCreatedAt(file), 0, "the CREATE rolled back with it");
        (uint8 state,,) = _head(_key(Purpose.FOLDER, rootDir, keccak256("never-published.txt")));
        assertEq(state, 0);
        // the same publication with the name lands (the name may follow the bind: the hook runs at the final phase)
        a = new Action[](3);
        b = new bytes[](3);
        a[0] = _create(keccak256("nameless"));
        a[1] = _bind(Purpose.FOLDER, rootDir, keccak256("never-published.txt"), file, 0);
        (a[2], b[2]) = _name("never-published.txt");
        _exec("recipe create + FOLDER bind before its name", a, b);
        _assertScope(rootDir, 1, 1, 1);
    }

    // L FilesDirectory test_nonexistent/file_subject/unrelated_record parent, unrelated record target, self link
    function test_placement_laws_through_the_kernel() public {
        bytes32 file = Keys.subject(p, keccak256("f"));
        Action[] memory a = new Action[](3);
        bytes[] memory b = new bytes[](3);
        a[0] = _create(keccak256("f"));
        (a[1], b[1]) = _name("entry");
        a[2] = _bind(Purpose.FOLDER, rootDir, keccak256("entry"), file, 0);
        _exec("recipe create + name + place", a, b);
        bytes32 nameRec = _id(T_NAME, "entry");
        a = new Action[](1);
        b = new bytes[](1);
        bytes32[5] memory parents = [bytes32(uint256(999)), file, nameRec, rootDir, rootDir];
        bytes32[5] memory targets = [file, file, file, nameRec, rootDir];
        uint8[5] memory codes = [2, 2, 2, 5, 3];
        for (uint256 i; i < 5; ++i) {
            a[0] = _bind(Purpose.FOLDER, parents[i], keccak256("entry"), targets[i], i >= 3 ? 1 : 0);
            Native memory c = _ctx(a);
            Snapshot memory before = _snapshot(parents[i], targets[i]);
            vm.expectRevert(
                abi.encodeWithSelector(
                    E_INDEX_CALL.selector,
                    abi.encodeWithSelector(E_FILES_FINAL.selector, codes[i], uint8(0))
                )
            );
            r.ledger.execute(a, b, c, "");
            _assertSame(before, _snapshot(parents[i], targets[i]));
        }
    }

    // L FilesDirectory test_required_index_failure_rolls_back_whole_signed_batch (native lane here; S2 signs)
    function test_refused_placement_rolls_back_the_whole_batch() public {
        bytes32 file = Keys.subject(p, keccak256("late"));
        Action[] memory a = new Action[](3);
        bytes[] memory b = new bytes[](3);
        a[0] = _create(keccak256("late"));
        a[1] = _bind(Purpose.FOLDER, bytes32(uint256(999)), keccak256("late-name"), file, 0);
        (a[2], b[2]) = _name("late-name");
        Snapshot memory before = _snapshot(bytes32(uint256(999)), file);
        Native memory c = _ctx(a);
        vm.expectRevert(
            abi.encodeWithSelector(
                E_INDEX_CALL.selector,
                abi.encodeWithSelector(E_FILES_FINAL.selector, uint8(2), uint8(1))
            )
        );
        r.ledger.execute(a, b, c, "");
        _assertSame(before, _snapshot(bytes32(uint256(999)), file));
        (bytes32 t,,,,) = r.hot.recordHeader(_id(T_NAME, "late-name"));
        assertEq(t, 0, "the name did not leak");
        assertEq(r.hot.subjectCreatedAt(file), 0, "the subject did not leak");
        (uint8 state,,) = _head(_key(Purpose.FOLDER, bytes32(uint256(999)), keccak256("late-name")));
        assertEq(state, 0, "the head did not leak");
        (, uint64 count,,,) = r.g.index
            .postingHeadOf(
                FamilyId.wrap(F_HISTORY),
                TypeId.wrap(0),
                0,
                _key(Purpose.FOLDER, bytes32(uint256(999)), keccak256("late-name"))
            );
        assertEq(count, 0, "no history posting");
    }

    // L FilesDirectory test_release_nonempty_directory_placement_preserves_children_and_other_placement
    function test_release_of_a_nonempty_directory_placement_keeps_its_children() public {
        bytes32 childSubject = Keys.subject(p, keccak256("child"));
        bytes32 file = Keys.subject(p, keccak256("file"));
        Action[] memory a = new Action[](9);
        bytes[] memory b = new bytes[](9);
        a[0] = _create(keccak256("child"));
        (a[1], b[1]) = _publish(T_DIRECTORY, abi.encode(childSubject));
        bytes32 childDir = _id(T_DIRECTORY, b[1]);
        (a[2], b[2]) = _name("child");
        (a[3], b[3]) = _name("other");
        a[4] = _bind(Purpose.FOLDER, rootDir, keccak256("child"), childDir, 0);
        a[5] = _bind(Purpose.FOLDER, rootDir, keccak256("other"), childDir, 0);
        a[6] = _create(keccak256("file"));
        (a[7], b[7]) = _name("file");
        a[8] = _bind(Purpose.FOLDER, childDir, keccak256("file"), file, 0);
        _exec("recipe a folder at two names with a file inside", a, b);
        a = new Action[](1);
        b = new bytes[](1);
        a[0] = _bindKind(ActionKind.RELEASE, Purpose.FOLDER, rootDir, keccak256("child"), 0, 1);
        _exec("recipe release one placement of a non-empty folder", a, b);
        (bytes32 t, uint64 first,,,) = r.hot.recordHeader(childDir);
        assertEq(t, typeIds[T_DIRECTORY]);
        assertTrue(first != 0, "the directory is not erased");
        _assertScope(childDir, 1, 1, 1);
        _assertScope(rootDir, 2, 1, 2);
        _assertBacklink(childDir, 2, 1);
    }

    // L FilesDirectory test_withdrawn_descriptor_remains_valid_and_bind_before_name_parent_publish_is_atomic
    function test_bind_before_its_parent_and_name_then_a_withdrawn_parent_stays_valid() public {
        bytes32 seed = Keys.subject(p, keccak256("later-dir"));
        bytes32 parent = _id(T_DIRECTORY, abi.encode(seed));
        bytes32 target = Keys.subject(p, keccak256("later-file"));
        Action[] memory a = new Action[](5);
        bytes[] memory b = new bytes[](5);
        a[0] = _create(keccak256("later-dir"));
        a[1] = _create(keccak256("later-file"));
        a[2] = _bind(Purpose.FOLDER, parent, keccak256("later"), target, 0);
        (a[3], b[3]) = _publish(T_DIRECTORY, abi.encode(seed));
        (a[4], b[4]) = _name("later");
        _exec("recipe bind before its parent and name publish", a, b);
        (, uint64 first,, uint64 occurrences,) = r.hot.recordHeader(parent);
        assertEq(occurrences, 1);
        a = new Action[](1);
        b = new bytes[](1);
        a[0].kind = ActionKind.WITHDRAW;
        a[0].target = bytes32(uint256(first));
        _exec("recipe withdraw the directory occurrence", a, b);
        (,,, occurrences,) = r.hot.recordHeader(parent);
        assertEq(occurrences, 0, "occurrence withdrawn");
        // a withdrawal is not an erasure: the directory still takes placements
        a = new Action[](2);
        b = new bytes[](2);
        (a[0], b[0]) = _name("later2");
        a[1] = _bind(Purpose.FOLDER, parent, keccak256("later2"), target, 0);
        _exec("recipe place under a withdrawn directory", a, b);
        _assertScope(parent, 2, 2, 3);
    }

    function test_stale_cas_is_refused_whole() public {
        bytes32 file = Keys.subject(p, keccak256("cas"));
        Action[] memory a = new Action[](3);
        bytes[] memory b = new bytes[](3);
        a[0] = _create(keccak256("cas"));
        (a[1], b[1]) = _publish(T_ROOT, bytes.concat(abi.encode(file), "v1"));
        bytes32 rootRec = _id(T_ROOT, b[1]);
        a[2] = _bind(Purpose.HEAD, file, 0, rootRec, 0);
        _exec("recipe create file without placement", a, b);
        // a plan prepared against revision 0 after the head moved to 1
        a = new Action[](2);
        b = new bytes[](2);
        (a[0], b[0]) = _publish(T_CHILD, bytes.concat(abi.encode(rootRec, file), "v2"));
        bytes32 childRec = _id(T_CHILD, b[0]);
        a[1] = _bind(Purpose.HEAD, file, 0, childRec, 0);
        Snapshot memory before = _snapshot(rootDir, rootRec);
        Native memory c = _ctx(a);
        vm.expectRevert(
            abi.encodeWithSelector(
                E_CAS.selector, _key(Purpose.HEAD, file, 0), uint64(0), uint64(1)
            )
        );
        r.ledger.execute(a, b, c, "");
        _assertSame(before, _snapshot(rootDir, rootRec));
        (bytes32 t,,,,) = r.hot.recordHeader(childRec);
        assertEq(t, 0, "the child publish rolled back with the stale bind");
    }

    // L FilesJoined test_missing_unrelated_and_wrong_file_parents_roll_back, through the kernel
    function test_child_parents_through_the_kernel() public {
        bytes32 file = Keys.subject(p, keccak256("joined"));
        Action[] memory a = new Action[](2);
        bytes[] memory b = new bytes[](2);
        a[0] = _create(keccak256("joined"));
        (a[1], b[1]) = _publish(T_ROOT, bytes.concat(abi.encode(file), "r0"));
        bytes32 r0 = _id(T_ROOT, b[1]);
        _exec("recipe create + root (no binds)", a, b);
        a = new Action[](1);
        b = new bytes[](1);
        // a missing parent is the kernel's reference check
        bytes32 missing = keccak256("missing parent");
        (a[0], b[0]) = _publish(T_CHILD, bytes.concat(abi.encode(missing, file), "x"));
        Native memory c = _ctx(a);
        vm.expectRevert(abi.encodeWithSelector(E_REF.selector, uint8(0), uint8(0), uint8(1)));
        r.ledger.execute(a, b, c, "");
        // an unrelated Type whose word0 is the file (a directory record seeded by the file subject)
        bytes32 unrelated = _id(T_DIRECTORY, abi.encode(file));
        (a[0], b[0]) = _publish(T_DIRECTORY, abi.encode(file));
        _exec("recipe publish directory", a, b);
        (a[0], b[0]) = _publish(T_CHILD, bytes.concat(abi.encode(unrelated, file), "x"));
        c = _ctx(a);
        vm.expectRevert(abi.encodeWithSelector(E_REJECTED.selector, uint8(0), typeIds[T_CHILD]));
        r.ledger.execute(a, b, c, "");
        // a child of a child, cold large documents (L test_cold_large_root_and_child_headers_accept)
        (a[0], b[0]) = _publish(T_CHILD, bytes.concat(abi.encode(r0, file), new bytes(8128)));
        bytes32 large = _id(T_CHILD, b[0]);
        _exec("recipe publish large child", a, b);
        (a[0], b[0]) = _publish(T_CHILD, bytes.concat(abi.encode(large, file), "grandchild"));
        _exec("recipe publish grandchild", a, b);
    }

    // ---- content by sha256 -------------------------------------------------------------------------------------

    function test_inline_and_external_content_found_by_sha256() public {
        bytes memory payload = "hello, efs files";
        bytes32 digest = sha256(payload);
        Action[] memory a = new Action[](4);
        bytes[] memory b = new bytes[](4);
        (a[0], b[0]) = _publish(T_BYTES, bytes.concat(abi.encode(digest), payload));
        bytes32 bytesRec = _id(T_BYTES, b[0]);
        (a[1], b[1]) = _publish(
            T_CONTENT,
            abi.encode(
                bytesRec,
                uint256(1),
                uint256(0),
                uint256(1),
                payload.length,
                digest,
                uint256(0),
                uint256(0),
                bytes32(0),
                payload.length,
                digest
            )
        );
        bytes32 inlineRec = _id(T_CONTENT, b[1]);
        (a[2], b[2]) = _publish(T_BYTES, abi.encode(sha256("")));
        bytes32 sentinel = _id(T_BYTES, b[2]);
        bytes memory locator = "ar://AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
        (a[3], b[3]) = _publish(
            T_EXTERNAL,
            bytes.concat(
                abi.encode(
                    sentinel,
                    uint256(2),
                    uint256(2),
                    uint256(1),
                    payload.length,
                    digest,
                    locator.length
                ),
                locator
            )
        );
        bytes32 externalRec = _id(T_EXTERNAL, b[3]);
        _exec("recipe inline bytes + content + sentinel + external", a, b);

        (Coverage cov,,,) = r.g.index.coverageOfDigest(SHA256);
        assertEq(uint8(cov), uint8(Coverage.COMPLETE));
        (cov,,,) =
            r.g.index.coverageOfSpec(FamilyId.wrap(F_DIGEST), TypeId.wrap(typeIds[T_EXTERNAL]), 1);
        assertEq(uint8(cov), uint8(Coverage.COMPLETE), "the second gen-1 digest spec");
        bytes32 value = keccak256(abi.encode(bytes32(uint256(SHA256)), digest));
        (uint64 count,) = _posting(F_DIGEST, 0, value);
        assertEq(count, 2, "found by sha256, inline and external");
        uint64[] memory entries;
        (, entries,) =
            r.g.index.postingSliceOf(FamilyId.wrap(F_DIGEST), TypeId.wrap(0), 0, value, 0, 8);
        (, uint64 inlineAt,,,) = r.hot.recordHeader(inlineRec);
        (, uint64 externalAt,,,) = r.hot.recordHeader(externalRec);
        assertEq(entries.length, 2);
        assertEq(entries[0], inlineAt);
        assertEq(entries[1], externalAt);
        (, count,, entries) = r.g.index.occurrencesOf(inlineRec);
        assertEq(count, 1);
        assertEq(entries[0], inlineAt);
        (count,) = _posting(F_REFERENCE, typeIds[T_CONTENT], bytesRec);
        assertEq(count, 1, "content -> bytes reference");
        // the external locator is retained byte for byte
        (bytes32 t,, uint32 length,,) = r.hot.recordHeader(externalRec);
        assertEq(t, typeIds[T_EXTERNAL]);
        assertEq(length, 224 + locator.length);
    }

    // ---- policy, notice ----------------------------------------------------------------------------------------

    function test_refuse_all_sunsets_a_type_with_the_nonce_intact() public {
        assertEq(r.registry.activatePolicy(typeIds[T_NAME], refuseAll), 2);
        Action[] memory a = new Action[](1);
        bytes[] memory b = new bytes[](1);
        (a[0], b[0]) = _name("sunset.txt");
        Native memory c = _ctx(a);
        (uint64 nonce,) = r.hot.nonceOf(p);
        vm.expectRevert(
            abi.encodeWithSelector(E_POLICY_REJECTED.selector, uint8(0), typeIds[T_NAME], uint16(2))
        );
        r.ledger.execute(a, b, c, "");
        (uint64 after_,) = r.hot.nonceOf(p);
        assertEq(after_, nonce);
    }

    function test_realm_notice_frozen_by_the_controller_principal() public {
        // address(this) is this Realm's controller, so its contract principal may publish frozen/migration notices
        Action[] memory a = new Action[](1);
        bytes[] memory b = new bytes[](1);
        (a[0], b[0]) =
            _publish(T_NOTICE, abi.encode(ClosureConstants.NOTICE_FROZEN, uint256(1), bytes("")));
        _exec("recipe realm-notice/1 frozen", a, b);
        // no notice principal at genesis: a successor notice is refused
        (a[0], b[0]) = _publish(
            T_NOTICE, abi.encode(ClosureConstants.NOTICE_SUCCESSOR, uint256(1), bytes(""))
        );
        Native memory c = _ctx(a);
        vm.expectRevert(abi.encodeWithSelector(E_REJECTED.selector, uint8(0), typeIds[T_NOTICE]));
        r.ledger.execute(a, b, c, "");
    }

    // ---- identity across Realms and chains ---------------------------------------------------------------------

    function test_type_ids_are_identical_across_realms_and_chains() public {
        bytes32[9] memory ids = typeIds;
        vm.chainId(11_155_111);
        Realm memory other = _realm(keccak256("files/realm-b"));
        assertTrue(other.hot.realmId() != r.hot.realmId());
        assertTrue(other.hot.realmOrigin() != r.hot.realmOrigin());
        // the rule instances are the same deterministic addresses; the descriptors and ids derive alike
        _deployProfile();
        for (uint8 t; t < 9; ++t) {
            assertEq(typeIds[t], ids[t], "the same Type id on another chain and Realm");
        }
        _register(other);
        for (uint8 t; t < 9; ++t) {
            assertEq(other.registry.typeInfo(ids[t]).mandatory, instances[t]);
            assertEq(r.registry.typeInfo(ids[t]).ruleId, other.registry.typeInfo(ids[t]).ruleId);
        }
        // and the other Realm runs the same recipe under the same ids
        bytes32 seed = Keys.subject(other.principal, keccak256("root"));
        Action[] memory a = new Action[](2);
        bytes[] memory b = new bytes[](2);
        a[0] = _create(keccak256("root"));
        (a[1], b[1]) = _publish(T_DIRECTORY, abi.encode(seed));
        Native memory c;
        other.ledger.execute(a, b, c, "");
        (bytes32 t_,,,,) = other.hot.recordHeader(Keys.record(ids[T_DIRECTORY], abi.encode(seed)));
        assertEq(t_, ids[T_DIRECTORY]);
        Readiness memory rd = other.g.index.replayReadiness();
        assertTrue(rd.ready);
        assertEq(rd.units.length, 1);
        assertEq(rd.units[0].finalHook, address(validator), "one validator serves both Realms");
    }
}
