// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FilesRecipesBase} from "./FilesRecipesBase.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {EfsFiles} from "../../src/lib/EfsFiles.sol";
import {Action, ActionKind, Native, Purpose} from "../../src/interfaces/Actions.sol";
import {ILedgerCommitments} from "../../src/interfaces/ILedgerCommitments.sol";
import {E_INDEX_CALL, E_REJECTED} from "../../src/interfaces/Errors.sol";
import {E_FILES_FINAL} from "../../src/profiles/FilesProfile.sol";

/// @notice A folder's identity through the real kernel, registry and generation-1 index (design §12.1, §12.2): a
///         folder is the `files-directory/1` record `abi.encode(creatorPrincipal, salt)` and only the creator can
///         admit it, by PUBLISH or by REUSE; a file is a created subject. Both spoof directions are refused (a
///         non-creator minting `(alice, salt)`, a `files-root/1` naming a folder's id), nobody can make a folder
///         whose id is someone's file subject, and the creator publishing the same folder again stores no new record.
///         `p` (this contract's principal) is the creator; `bob` is an EOA that tries to impersonate it.
contract FilesFolderIdentityTest is FilesRecipesBase {
    address internal bob = makeAddr("bob");
    bytes32 internal pb;

    function setUp() public override {
        super.setUp();
        pb = Keys.principal(bob);
    }

    function _one(Action memory x, bytes memory y)
        internal
        pure
        returns (Action[] memory a, bytes[] memory b)
    {
        a = new Action[](1);
        b = new bytes[](1);
        a[0] = x;
        b[0] = y;
    }

    function _bobCtx(Action[] memory a) internal view returns (Native memory c) {
        (c.nonce,) = r.hot.nonceOf(pb);
        c.expectedExecutionSet = r.hot.executionSet();
        c.expectedAcceptanceProfile =
            ILedgerCommitments(r.hot.ingress()).acceptanceProfileOf(address(r.ledger), a);
    }

    function _execBob(Action[] memory a, bytes[] memory b) internal {
        Native memory c = _bobCtx(a);
        vm.prank(bob, bob);
        r.ledger.execute(a, b, c, "");
    }

    /// Bob's publication is refused with `err`, and nothing lands (counts, Bob's nonce, the index frontier).
    function _bobRefused(Action[] memory a, bytes[] memory b, bytes memory err) internal {
        Native memory c = _bobCtx(a);
        (uint64 adm, uint64 rec, uint64 bnd, uint64 pubs) = r.hot.counts();
        (uint64 processed,,) = r.g.index.progress();
        vm.expectRevert(err);
        vm.prank(bob, bob);
        r.ledger.execute(a, b, c, "");
        (uint64 adm2, uint64 rec2, uint64 bnd2, uint64 pubs2) = r.hot.counts();
        assertEq(
            keccak256(abi.encode(adm, rec, bnd, pubs)),
            keccak256(abi.encode(adm2, rec2, bnd2, pubs2))
        );
        (uint64 nonce,) = r.hot.nonceOf(pb);
        assertEq(nonce, c.nonce, "the nonce is intact");
        (uint64 processed2,,) = r.g.index.progress();
        assertEq(processed2, processed);
    }

    function _rejected(uint8 leaf, uint8 t) internal view returns (bytes memory) {
        return abi.encodeWithSelector(E_REJECTED.selector, leaf, typeIds[t]);
    }

    // ---- spoof direction 1: a folder that reads as created by p, minted by someone else -------------------------

    function test_a_non_creator_cannot_publish_or_reuse_the_creators_folder() public {
        bytes memory body = _dirBody(p, keccak256("docs"));
        bytes32 folder = _id(T_DIRECTORY, body);
        // before p publishes it: Bob's PUBLISH of (p, salt) is refused, nothing lands
        (Action[] memory a, bytes[] memory b) = _one(_pubDir(body), body);
        _bobRefused(a, b, _rejected(0, T_DIRECTORY));
        (bytes32 t,,,,) = r.hot.recordHeader(folder);
        assertEq(t, 0, "no folder was minted");
        // p publishes it
        _exec("recipe publish own folder", a, b);
        (t,,,,) = r.hot.recordHeader(folder);
        assertEq(t, typeIds[T_DIRECTORY]);
        // after: a re-PUBLISH by Bob runs the rule again and is refused
        _bobRefused(a, b, _rejected(0, T_DIRECTORY));
        // REUSE by Bob: the kernel loads the stored body and runs the rule with Bob's principal, so it is refused
        Action memory reuse;
        reuse.kind = ActionKind.REUSE;
        reuse.typeId = typeIds[T_DIRECTORY];
        reuse.bodyHashOrRecordId = folder;
        (a, b) = _one(reuse, "");
        _bobRefused(a, b, _rejected(0, T_DIRECTORY));
        // REUSE by the creator is admitted: one more occurrence of the same record
        _exec("recipe reuse own folder", a, b);
        (,,, uint64 occurrences,) = r.hot.recordHeader(folder);
        assertEq(occurrences, 2);
        // Bob's own folder (pb, salt) is admitted, and is a different id from p's (pb is in the body)
        bytes memory own = _dirBody(pb, keccak256("docs"));
        (a, b) = _one(_pubDir(own), own);
        _execBob(a, b);
        assertTrue(_id(T_DIRECTORY, own) != folder);
    }

    function test_the_same_creator_and_salt_twice_stores_nothing_new() public {
        bytes memory body = _dirBody(p, keccak256("twice"));
        bytes32 folder = _id(T_DIRECTORY, body);
        (Action[] memory a, bytes[] memory b) = _one(_pubDir(body), body);
        _exec("recipe publish folder", a, b);
        (, uint64 records,,) = r.hot.counts();
        (bytes32 t, uint64 first, uint32 length, uint64 occ,) = r.hot.recordHeader(folder);
        assertEq(length, 64);
        assertEq(occ, 1);
        // again, alone and twice in one publication: admitted, no new record, the header unchanged
        _exec("recipe publish the same folder again", a, b);
        Action[] memory a2 = new Action[](2);
        bytes[] memory b2 = new bytes[](2);
        (a2[0], b2[0]) = (_pubDir(body), body);
        (a2[1], b2[1]) = (_pubDir(body), body);
        _exec("recipe publish the same folder twice in one publication", a2, b2);
        (, uint64 records2,,) = r.hot.counts();
        assertEq(records2, records, "no new record");
        (bytes32 t2, uint64 first2, uint32 length2, uint64 occ2,) = r.hot.recordHeader(folder);
        assertEq(
            keccak256(abi.encode(t, first, length)), keccak256(abi.encode(t2, first2, length2))
        );
        assertEq(occ2, 4, "three more occurrences");
        // as for any record, each occurrence is an admission and a by-type posting (the root's, then four here)
        (uint64 count,) = _posting(F_BY_TYPE, typeIds[T_DIRECTORY], 0);
        assertEq(count, 5, "one by-type posting per occurrence");
    }

    // ---- spoof direction 2: a folder's id used as a file ----------------------------------------------------------

    function test_a_files_root_naming_a_folder_is_refused() public {
        bytes memory body = _dirBody(p, keccak256("dir"));
        bytes32 folder = _id(T_DIRECTORY, body);
        (Action[] memory a, bytes[] memory b) = _one(_pubDir(body), body);
        _exec("recipe publish folder", a, b);
        assertEq(r.hot.subjectCreatedAt(folder), 0, "a folder is never a subject");
        // neither the creator nor anyone else can give a folder (or the root) a first revision
        bytes32[2] memory dirs = [folder, rootDir];
        for (uint256 i; i < 2; ++i) {
            bytes memory rb = EfsFiles.rootBody(dirs[i], "not a file");
            (a, b) = _one(_pub(T_ROOT, rb), rb);
            Native memory c = _ctx(a);
            vm.expectRevert(_rejected(0, T_ROOT));
            r.ledger.execute(a, b, c, "");
            _bobRefused(a, b, _rejected(0, T_ROOT));
        }
    }

    /// Nobody can mint a folder over someone's FILE subject by any body: whatever Bob publishes under
    /// `files-directory/1` is refused unless it is his own `(pb, salt ≠ 0)`, and then its id is a record id, never
    /// the file's subject id; the file stays a subject, and a FOLDER bind under it is refused by the final hook.
    function testFuzz_no_body_makes_a_folder_of_a_file_subject(bytes32 w0, bytes32 w1, uint8 mode)
        public
    {
        bytes32 file = Keys.subject(p, keccak256("pet"));
        bytes memory rb = EfsFiles.rootBody(file, "a pet");
        Action[] memory a = new Action[](3);
        bytes[] memory b = new bytes[](3);
        a[0] = _create(keccak256("pet"));
        (a[1], b[1]) = _publish(T_ROOT, rb);
        a[2] = _bind(Purpose.HEAD, file, 0, _id(T_ROOT, rb), 0);
        _exec("recipe create a file", a, b);
        // the bodies Bob might try: the file itself as the creator, p as the creator, his own, a file-salted one
        mode %= 7;
        bytes memory body;
        if (mode == 0) body = abi.encode(file, w1);
        else if (mode == 1) body = abi.encode(p, w1);
        else if (mode == 2) body = abi.encode(pb, w1);
        else if (mode == 3) body = abi.encode(pb, file);
        else if (mode == 4) body = abi.encode(w0, w1);
        else if (mode == 5) body = abi.encode(file, w0, w1);
        else body = abi.encode(file); // the old one-word seed body
        bool admissible = body.length == 64 && _word(body, 0) == pb && _word(body, 1) != 0;
        (a, b) = _one(_pubDir(body), body);
        if (admissible) {
            _execBob(a, b);
            assertTrue(_id(T_DIRECTORY, body) != file, "a record id is never a subject id");
        } else {
            _bobRefused(a, b, _rejected(0, T_DIRECTORY));
        }
        (bytes32 t,,,,) = r.hot.recordHeader(file);
        assertEq(t, 0, "the file is not a record");
        assertTrue(r.hot.subjectCreatedAt(file) != 0, "the file is still a subject");
        // Bob places an entry with the file as its parent: the final hook refuses (the parent is no folder)
        a = new Action[](2);
        b = new bytes[](2);
        (a[0], b[0]) = _name("inside");
        a[1] = _bind(Purpose.FOLDER, file, keccak256("inside"), rootDir, 0);
        _bobRefused(
            a,
            b,
            abi.encodeWithSelector(
                E_INDEX_CALL.selector,
                abi.encodeWithSelector(E_FILES_FINAL.selector, uint8(2), uint8(1))
            )
        );
    }

    /// Kind is a property of the id: the kernel classifies a bind target by which table holds it, a folder lands
    /// as a RECORD target and a file as a SUBJECT target, and `FilesPageReader`/the gateway route on that.
    function test_kind_is_a_property_of_the_id() public {
        bytes memory body = _dirBody(p, keccak256("k"));
        bytes32 folder = _id(T_DIRECTORY, body);
        bytes32 file = Keys.subject(p, keccak256("k"));
        Action[] memory a = new Action[](6);
        bytes[] memory b = new bytes[](6);
        (a[0], b[0]) = _publish(T_DIRECTORY, body);
        a[1] = _create(keccak256("k")); // the same salt: a subject id, a different id from the folder
        (a[2], b[2]) = _name("kdir");
        (a[3], b[3]) = _name("kfile");
        a[4] = _bind(Purpose.FOLDER, rootDir, keccak256("kdir"), folder, 0);
        a[5] = _bind(Purpose.FOLDER, rootDir, keccak256("kfile"), file, 0);
        _exec("recipe a folder and a file of one salt", a, b);
        assertTrue(folder != file);
        (,,, uint8 kd,,,,) = r.hot.head(_key(Purpose.FOLDER, rootDir, keccak256("kdir")));
        (,,, uint8 kf,,,,) = r.hot.head(_key(Purpose.FOLDER, rootDir, keccak256("kfile")));
        assertEq(kd, 1, "TARGET_RECORD");
        assertEq(kf, 2, "TARGET_SUBJECT");
        assertEq(r.hot.subjectCreatedAt(folder), 0);
        (bytes32 t,,,,) = r.hot.recordHeader(file);
        assertEq(t, 0);
    }

    // ---- helpers ------------------------------------------------------------------------------------------------

    function _pubDir(bytes memory body) internal view returns (Action memory a) {
        (a,) = _publish(T_DIRECTORY, body);
    }

    function _pub(uint8 t, bytes memory body) internal view returns (Action memory a) {
        (a,) = _publish(t, body);
    }

    function _word(bytes memory body, uint256 i) internal pure returns (bytes32 w) {
        if (body.length < 32 * (i + 1)) return 0;
        assembly ("memory-safe") {
            w := mload(add(add(body, 32), mul(i, 32)))
        }
    }
}
