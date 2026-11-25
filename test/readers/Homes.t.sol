// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FilesPageHarness} from "../harness/doubles/FilesPageHarness.sol";
import {EfsFiles} from "../../src/lib/EfsFiles.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {Action, ActionKind, Purpose} from "../../src/interfaces/Actions.sol";
import {BasisCommit, Qualified, Status} from "../../src/interfaces/Results.sol";
import {Cursor, IFilesPageReader, Page} from "../../src/interfaces/Readers.sol";
import {E_INDEX_CALL, E_SHAPE} from "../../src/interfaces/Errors.sol";
import {E_FILES_FINAL} from "../../src/profiles/FilesProfile.sol";
import {LensReader} from "../../src/readers/LensReader.sol";

/// @notice Homes (design §12.5; docs/TAG-DESIGN.md §3): anyone can attach files to any address; the address,
///         left-padded, is the id of that home (`bytes32(uint256(uint160(addr)))`, equal to `Keys.principal(addr)` for
///         a key account). A FOLDER bind whose parent is address-shaped passes `FilesFinalValidator` with no check of
///         the address. The existing page reader and lens reader serve a home unchanged.
contract HomesTest is FilesPageHarness {
    address internal attacher = makeAddr("homes/attacher");
    address internal owner = makeAddr("homes/owner"); // never transacts until the second test
    bytes32 internal home;
    LensReader internal lens;

    function setUp() public {
        _setUpFiles(keccak256("homes/realm"));
        home = bytes32(uint256(uint160(owner)));
        assertEq(home, Keys.principal(owner), "a key account's home is its principal id");
        lens = new LensReader(address(r.ledger), address(views), address(reads));
    }

    function _home(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    /// A third party attaches a file to an address that never transacted; it lists through the page reader with
    /// lens = [attacher], is found by `lookupName`, and is listed by `LensReader.list` on the FOLDER scope.
    function test_third_party_attaches_to_a_fresh_address() public {
        assertEq(owner.code.length, 0);
        assertEq(owner.balance, 0);
        (uint64 nonce,) = r.hot.nonceOf(Keys.principal(owner));
        assertEq(nonce, 0, "the owner never transacted");
        (bytes32 file, bytes32 rootRecord) = _file(attacher, home, "hello.txt", "hi there", true);
        bytes32 pa = Keys.principal(attacher);

        IFilesPageReader.DirectoryPage memory page = _list(home, _lens(pa), F_ALL);
        assertEq(uint8(page.q.status), uint8(Status.PRESENT));
        assertEq(page.rows.length, 1);
        assertEq(page.rows[0].name, "hello.txt");
        assertEq(page.rows[0].target, file);
        assertEq(page.rows[0].headRecord, rootRecord);
        assertEq(page.rows[0].rowKind, ROW_ENTRY);
        assertEq(page.rows[0].position, EfsFiles.folderPosition(home, "hello.txt"));
        emit log_named_uint("home listing (attacher lens) rows", page.rows.length);

        // the owner's lens sees nothing: the owner wrote nothing there
        page = _list(home, _lens(Keys.principal(owner)), F_ALL);
        assertEq(uint8(page.q.status), uint8(Status.PRESENT));
        assertEq(page.rows.length, 0);

        (Qualified memory q, IFilesPageReader.Row memory row) =
            reader.lookupName(home, keccak256("hello.txt"), _lens(pa), _unbound());
        assertEq(uint8(q.status), uint8(Status.PRESENT), "lookupName at a home");
        assertEq(row.target, file);

        Cursor memory c;
        BasisCommit memory b;
        Page memory lp = lens.list(_lens(pa), Purpose.FOLDER, home, c, 16, 1, b);
        assertEq(uint8(lp.q.status), uint8(Status.PRESENT), "LensReader.list at a home");
        assertEq(lp.rows.length, 1);
        assertEq(lp.rows[0].selection.target, file);
    }

    /// The owner later attaches their own entry: lens = [owner] shows only theirs; [owner, attacher] shows both
    /// (the owner first), and the same name falls through to the owner's entry.
    function test_owner_entries_are_their_own() public {
        (bytes32 attacherFile,) = _file(attacher, home, "hello.txt", "from a stranger", true);
        (bytes32 ownerFile,) = _file(owner, home, "mine.txt", "from the owner", true);
        IFilesPageReader.DirectoryPage memory page =
            _list(home, _lens(Keys.principal(owner)), F_ALL);
        assertEq(page.rows.length, 1);
        assertEq(page.rows[0].name, "mine.txt");
        assertEq(page.rows[0].target, ownerFile);
        page = _list(home, _lens(Keys.principal(owner), Keys.principal(attacher)), F_ALL);
        assertEq(page.rows.length, 2);
        assertEq(page.rows[0].target, ownerFile);
        assertEq(page.rows[1].target, attacherFile);
    }

    /// An unbind (first mask) at a home position works with no earlier placement, and masks a stranger's entry
    /// in the owner's lens; a TAG link with a home as the position subject needs nothing either.
    function test_first_mask_and_tag_at_a_home() public {
        (bytes32 attacherFile,) = _file(attacher, home, "hello.txt", "spam", true);
        Action[] memory a = new Action[](1);
        a[0] = EfsFiles.bind(Purpose.FOLDER, home, keccak256("hello.txt"), 0, 0);
        a[0].kind = ActionKind.UNBIND;
        _execAs(owner, a, new bytes[](1));
        (uint8 state,,,,,,,) = r.hot
            .head(Keys.binding(Keys.principal(owner), EfsFiles.folderPosition(home, "hello.txt")));
        assertEq(state, 2, "a first mask at a home");
        IFilesPageReader.DirectoryPage memory page =
            _list(home, _lens(Keys.principal(owner), Keys.principal(attacher)), F_ALL);
        // the owner's first mask hides the stranger's entry (mask beats fall-through)
        for (uint256 i; i < page.rows.length; ++i) {
            assertTrue(
                page.rows[i].target != attacherFile || page.rows[i].rowKind != ROW_ENTRY,
                "masked by the owner"
            );
        }
        emit log_named_uint(
            "home listing [owner, attacher] after a first mask, rows", page.rows.length
        );
        // TAG: position (TAG, home, role = file) → file, by the attacher
        a[0] = EfsFiles.bind(Purpose.TAG, home, attacherFile, attacherFile, 0);
        _execAs(attacher, a, new bytes[](1));
        (state,,,,,,,) = r.hot
            .head(
                Keys.binding(
                    Keys.principal(attacher), Keys.position(Purpose.TAG, home, attacherFile)
                )
            );
        assertEq(state, 1, "a TAG link at a home");
    }

    /// Precompile addresses are just unowned homes.
    function test_low_address_is_an_ordinary_home() public {
        (bytes32 file,) = _file(attacher, _home(address(1)), "ecrecover.txt", "x", true);
        IFilesPageReader.DirectoryPage memory page =
            _list(_home(address(1)), _lens(Keys.principal(attacher)), F_ALL);
        assertEq(page.rows.length, 1);
        assertEq(page.rows[0].target, file);
    }

    /// The zero address is never a home: the shape law refuses subject == 0 before the validator runs.
    function test_zero_address_is_not_a_home() public {
        bytes32 file = Keys.subject(p, keccak256("homes/zero"));
        Action[] memory a = new Action[](3);
        bytes[] memory b = new bytes[](3);
        a[0].kind = ActionKind.CREATE;
        a[0].saltOrStrength = keccak256("homes/zero");
        (a[1], b[1]) = (EfsFiles.publish(t.name, "z"), bytes("z"));
        a[2] = EfsFiles.bind(Purpose.FOLDER, bytes32(0), keccak256("z"), file, 0);
        vm.expectRevert(abi.encodeWithSelector(E_SHAPE.selector, uint8(2), uint8(1)));
        this.execExternal(a, b);
    }

    /// A parent that is neither a directory record nor address-shaped is still refused with code 2.
    function test_other_parent_is_still_refused() public {
        bytes32 bogus = keccak256("homes/not-a-directory");
        assertTrue(uint256(bogus) >> 160 != 0);
        bytes32 bogus2 = bytes32(uint256(1) << 160); // the lowest word that is not address-shaped
        bytes32[2] memory parents = [bogus, bogus2];
        for (uint256 i; i < 2; ++i) {
            (Action[] memory a, bytes[] memory b,,) = EfsFiles.createFile(
                t, p, parents[i], keccak256(abi.encode("homes/bogus", i)), "x.txt", "x", true
            );
            vm.expectRevert(
                abi.encodeWithSelector(
                    E_INDEX_CALL.selector,
                    abi.encodeWithSelector(E_FILES_FINAL.selector, uint8(2), uint8(a.length - 1))
                )
            );
            this.execExternal(a, b);
        }
    }

    function execExternal(Action[] calldata a, bytes[] calldata b) external {
        require(msg.sender == address(this));
        _exec(a, b);
    }
}
