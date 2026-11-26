// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {HeadAuthorsBase} from "./HeadAuthorsBase.sol";
import {LedgerViews} from "../../src/readers/LedgerViews.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {EfsFiles} from "../../src/lib/EfsFiles.sol";
import {FamilyId, PostingKey, Purpose, ScopeKey, TypeId} from "../../src/interfaces/Actions.sol";
import {Coverage, Status} from "../../src/interfaces/Results.sol";
import {FamilyEntry} from "../../src/interfaces/Index.sol";
import {Head} from "../../src/interfaces/Views.sol";
import {IPostingStore} from "../../src/interfaces/IPostingStore.sol";

/// @notice Generation 1's `head-authors` list (design §10.2 family 22; QUESTIONS Q52, ruled 2026-11-26): everyone's
///         versions of a file, kept from genesis in the genesis posting store, and the "show everyone's versions of this
///         file" read a client makes today through existing reads only:
///
///         1. `postingHeadOf(head-authors, 0, 0, position)` at the index: coverage, `count` (authors who ever made a
///            HEAD statement on the file) and `live` (authors whose HEAD there is BOUND now);
///         2. `postingSliceOf(head-authors, 0, 0, position, from, n)`: the entries, each the admission of one author's
///            first HEAD statement on the file;
///         3. `LedgerViews.authorHeads(ledger, position, entries)`: each entry's author and that author's head at the
///            file now (state, revision, target: the version it names).
///
///         `position = Keys.position(Purpose.HEAD, file, 0)`. No new reader or ABI: the three calls are the ones the
///         topic readers make for `position-authors` (family 20).
contract EveryonesVersionsTest is HeadAuthorsBase {
    bytes32 internal constant F_LIST = keccak256("efs/family/head-authors/1");
    LedgerViews internal views;
    address internal dave = makeAddr("everyones-versions/dave");

    function setUp() public override {
        super.setUp();
        views = new LedgerViews();
    }

    struct Versions {
        Coverage coverage;
        uint64 count;
        uint64 live;
        uint64[] entries;
        Status[] status;
        bytes32[] authors;
        Head[] heads;
    }

    /// The read, as a client makes it: the list's head and its entries at the index, then each entry's author and head.
    function _versions(bytes32 file) internal view returns (Versions memory v) {
        bytes32 position = Keys.position(Purpose.HEAD, file, 0);
        (v.coverage, v.count, v.live,,) =
            r.g.index.postingHeadOf(FamilyId.wrap(F_LIST), TypeId.wrap(0), 0, position);
        (, v.entries,) = r.g.index
            .postingSliceOf(FamilyId.wrap(F_LIST), TypeId.wrap(0), 0, position, 0, uint16(v.count));
        (v.status, v.authors, v.heads,) = views.authorHeads(address(r.ledger), position, v.entries);
    }

    /// The admission of `who`'s first HEAD statement on `file`: entry 0 of the binding's history list.
    function _first(address who, bytes32 file) internal view returns (uint64) {
        return IPostingStore(address(r.g.posting))
            .postingAt(
                PostingKey.wrap(
                    Keys.historyList(Keys.binding(_pid(who), Keys.position(Purpose.HEAD, file, 0)))
                ),
                0
            );
    }

    function _counts(bytes32 file) internal view returns (uint64 count, uint64 live) {
        Versions memory v = _versions(file);
        return (v.count, v.live);
    }

    /// Three authors' versions of one file, one of them masked: the list holds the three authors in order of their
    /// first HEAD statement, `live` is the two whose versions stand, and the heads name each author's version (the
    /// masked one names none).
    function test_show_everyones_versions_of_a_file() public {
        bytes32 home = bytes32(uint256(uint160(alice)));
        (bytes32 file, bytes32 root) = _newFile(alice, home, "notes.md");
        bytes32 aliceV2 = _editFile(alice, file, root, "notes v2"); // a re-bind: the list does not move
        bytes32 bobV = _editFile(bob, file, aliceV2, "bob's notes"); // bob's first: a second entry
        _editFile(carol, file, aliceV2, "carol's notes"); // carol's first: a third entry
        _head1(carol, EfsFiles.unbind(Purpose.HEAD, file, 0, _hrev(carol, file))); // carol masks hers

        Versions memory v = _versions(file);
        assertEq(uint8(v.coverage), uint8(Coverage.COMPLETE), "the list is complete");
        assertEq(
            abi.encode(v.count, v.live),
            abi.encode(uint64(3), uint64(2)),
            "three authors, two standing"
        );
        assertEq(v.entries.length, 3);
        assertEq(v.entries[0], _first(alice, file), "alice's first statement");
        assertEq(v.entries[1], _first(bob, file), "bob's first statement");
        assertEq(v.entries[2], _first(carol, file), "carol's first statement");
        assertEq(
            abi.encode(v.authors[0], v.authors[1], v.authors[2]),
            abi.encode(_pid(alice), _pid(bob), _pid(carol)),
            "each entry's author"
        );
        assertEq(uint8(v.status[0]), uint8(Status.PRESENT));
        assertEq(uint8(v.status[1]), uint8(Status.PRESENT));
        assertEq(uint8(v.status[2]), uint8(Status.MASKED), "carol's version is masked");
        assertEq(v.heads[0].target, aliceV2, "alice's current version");
        assertEq(v.heads[1].target, bobV, "bob's version");
        assertEq(v.heads[2].target, 0, "a masked head names no version");
        // the list is the one generation 1 keeps from genesis, in its genesis posting store
        (uint64 c, uint64 l,,) = IPostingStore(address(r.g.posting)).postingHead(_genesisKey(file));
        assertEq(
            abi.encode(c, l), abi.encode(v.count, v.live), "read through the index = the store"
        );
    }

    /// Every HEAD transition and what it does to the list: a first yes appends an entry and raises `live`; a lone
    /// negative (a first no) appends an entry and leaves `live`; a re-bind (an edit) does nothing; a mask or release of
    /// a BOUND head lowers `live`; a mask or release of a head that is not BOUND does nothing; a restore raises `live`;
    /// no later statement appends an entry.
    function test_every_transition() public {
        bytes32 home = bytes32(uint256(uint160(alice)));
        (bytes32 file, bytes32 root) = _newFile(alice, home, "list.md");
        _expect(file, 1, 1, "alice creates: a first yes");
        bytes32 v2 = _editFile(alice, file, root, "v2");
        _expect(file, 1, 1, "alice edits: a re-bind, nothing");
        _editFile(bob, file, v2, "bob's");
        _expect(file, 2, 2, "bob's first yes");
        _head1(carol, EfsFiles.loneNegative(Purpose.HEAD, file, 0, 0));
        _expect(file, 3, 2, "carol's lone negative: an entry, not counted");
        _head1(alice, EfsFiles.unbind(Purpose.HEAD, file, 0, _hrev(alice, file)));
        _expect(file, 3, 1, "alice masks her BOUND head");
        _head1(alice, EfsFiles.release(Purpose.HEAD, file, 0, _hrev(alice, file)));
        _expect(file, 3, 1, "alice releases a masked head: nothing");
        _head1(bob, EfsFiles.release(Purpose.HEAD, file, 0, _hrev(bob, file)));
        _expect(file, 3, 0, "bob releases his BOUND head");
        _head1(carol, EfsFiles.unbind(Purpose.HEAD, file, 0, _hrev(carol, file)));
        _expect(file, 3, 0, "carol masks her masked head: nothing");
        _head1(alice, EfsFiles.bind(Purpose.HEAD, file, 0, v2, _hrev(alice, file)));
        _expect(file, 3, 1, "alice restores");
        _head1(carol, EfsFiles.bind(Purpose.HEAD, file, 0, root, _hrev(carol, file)));
        _expect(file, 3, 2, "carol's yes after her lone no: a restore");
        _editFile(dave, file, v2, "dave's");
        _expect(file, 4, 3, "a fourth author");
        Versions memory v = _versions(file);
        assertEq(v.entries[2], _first(carol, file), "carol's entry: her lone negative");
        assertEq(uint8(v.status[2]), uint8(Status.PRESENT), "carol's head is BOUND now");
    }

    function _expect(bytes32 file, uint64 count, uint64 live, string memory what) internal view {
        (uint64 c, uint64 l) = _counts(file);
        assertEq(abi.encode(c, l), abi.encode(count, live), what);
    }

    /// The family as generation 1 declares it: kind 22, in the genesis posting store, maintained from admission 1,
    /// universe SCOPE and HEADS semantics like `position-authors`, and COMPLETE coverage, so a reader that answers only
    /// from lists the index reports COMPLETE answers from it.
    function test_the_family_is_declared_in_the_genesis_posting_store() public view {
        (, FamilyEntry[] memory families,,,,,) = r.g.reads.manifest();
        bool found;
        for (uint256 i; i < families.length; ++i) {
            if (families[i].familyId != F_LIST) continue;
            found = true;
            assertEq(families[i].kind, 22);
            assertEq(families[i].universe, 3, "SCOPE");
            assertEq(families[i].shape, 1, "APPEND");
            assertEq(families[i].liveSemantics, 3, "HEADS");
            assertTrue(families[i].mandatory);
            assertEq(families[i].fromAdmission, 1);
            assertEq(families[i].store, address(r.g.posting), "the genesis posting store");
        }
        assertTrue(found, "declared");
        bool inStore;
        bytes32[] memory ids = IPostingStore(address(r.g.posting)).familyIds();
        for (uint256 i; i < ids.length; ++i) {
            inStore = inStore || ids[i] == F_LIST;
        }
        assertTrue(inStore, "in the posting store's family set");
        (Coverage c, uint64 from, uint64 through,) =
            r.g.index.coverage(FamilyId.wrap(F_LIST), ScopeKey.wrap(0));
        (uint64 admissions,) = _counts();
        assertEq(uint8(c), uint8(Coverage.COMPLETE));
        assertEq(abi.encode(from, through), abi.encode(uint64(1), admissions));
        assertEq(Keys.familyId("head-authors"), F_LIST);
        assertEq(
            Keys.headAuthorsList(Keys.position(Purpose.HEAD, bytes32(uint256(1)), 0)),
            Keys.posting(0, 22, 0, Keys.position(Purpose.HEAD, bytes32(uint256(1)), 0))
        );
    }
}
