// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test, console2} from "forge-std/Test.sol";
import {E_READER} from "../../src/interfaces/Errors.sol";
import {ReaderDirectory} from "../../src/periphery/ReaderDirectory.sol";
import {RawProfilesReader, ReaderDouble} from "../harness/doubles/ConsumerDoubles.sol";
import {E_CODE_SHAPE} from "../../src/interfaces/Errors.sol";

/// @notice The advisory reader directory (design §5.13, §3.1 row 17): permissionless append, the recorded
///         `(reader, codehash, layoutId, physicalProfile)` row, refusal of duplicates, code-less readers,
///         7702 designators and readers naming another ledger, and paged listing.
contract ReaderDirectoryTest is Test {
    event ReaderListed(
        address indexed ledger, bytes32 indexed kind, address indexed reader, uint16 ordinal
    );

    ReaderDirectory internal dir;
    address internal constant LEDGER = address(0x1ED6E5);
    bytes32 internal constant LENS = keccak256("efs2/reader/lens/1");
    bytes32 internal constant PAGES = keccak256("efs2/reader/files-page/1");
    bytes32 internal constant LAYOUT = keccak256("efs2/test/layout");
    bytes32 internal constant PHYS = keccak256("efs2/test/physical/1");

    function setUp() public {
        dir = new ReaderDirectory();
    }

    function _reader(address ledger, bytes32 profile) internal returns (ReaderDouble) {
        bytes32[] memory p = new bytes32[](profile == 0 ? 0 : 2);
        if (profile != 0) (p[0], p[1]) = (profile, keccak256("efs2/test/physical/2"));
        return new ReaderDouble(ledger, LAYOUT, p);
    }

    function testRuntimeSize() public view {
        console2.log("ReaderDirectory runtime bytes", address(dir).code.length);
        assertLe(address(dir).code.length, 1_800, "design pessimistic size (3.1 row 17)");
    }

    function testListAppendsTheRecordedRow() public {
        ReaderDouble r = _reader(LEDGER, PHYS);
        vm.expectEmit(address(dir));
        emit ReaderListed(LEDGER, LENS, address(r), 0);
        vm.prank(address(0xCAFE)); // anyone lists
        dir.list(LEDGER, LENS, address(r));
        assertEq(dir.count(LEDGER, LENS), 1);
        (
            address[] memory a,
            bytes32[] memory codehashes,
            bytes32[] memory layouts,
            bytes32[] memory phys,
            uint16 next
        ) = dir.readers(LEDGER, LENS, 0, 10);
        assertEq(a.length, 1);
        assertEq(a[0], address(r));
        assertEq(codehashes[0], address(r).codehash);
        assertEq(layouts[0], LAYOUT);
        assertEq(phys[0], PHYS, "the first listed physical profile");
        assertEq(next, 0, "exhausted");
        // listings are per (ledger, kind); an empty list decodes as four empty arrays
        assertEq(dir.count(LEDGER, PAGES), 0);
        (a, codehashes, layouts, phys, next) = dir.readers(LEDGER, PAGES, 0, 10);
        assertEq(a.length + codehashes.length + layouts.length + phys.length, 0);
        assertEq(next, 0);
        assertEq(dir.count(address(0xB0B), LENS), 0);
        // the same reader may be listed under another kind
        dir.list(LEDGER, PAGES, address(r));
        assertEq(dir.count(LEDGER, PAGES), 1);
    }

    function testEmptyPhysicalProfilesRecordZero() public {
        ReaderDouble r = _reader(LEDGER, 0);
        dir.list(LEDGER, LENS, address(r));
        (,,, bytes32[] memory phys,) = dir.readers(LEDGER, LENS, 0, 1);
        assertEq(phys[0], bytes32(0));
    }

    function testDuplicateRefused() public {
        ReaderDouble r = _reader(LEDGER, PHYS);
        dir.list(LEDGER, LENS, address(r));
        vm.expectRevert(abi.encodeWithSelector(E_READER.selector, address(r), uint8(1)));
        dir.list(LEDGER, LENS, address(r));
        assertEq(dir.count(LEDGER, LENS), 1);
    }

    function testCodelessAndDesignatorRefused() public {
        address none = address(0xD00D);
        vm.expectRevert(abi.encodeWithSelector(E_CODE_SHAPE.selector, none, uint8(1)));
        dir.list(LEDGER, LENS, none);
        ReaderDouble r = _reader(LEDGER, PHYS);
        address delegated = address(0xDE1E);
        vm.etch(delegated, abi.encodePacked(hex"ef0100", address(r)));
        vm.expectRevert(abi.encodeWithSelector(E_CODE_SHAPE.selector, delegated, uint8(2)));
        dir.list(LEDGER, LENS, delegated);
        assertEq(dir.count(LEDGER, LENS), 0);
    }

    function testReaderOfAnotherLedgerRefused() public {
        ReaderDouble r = _reader(address(0xB0B), PHYS);
        vm.expectRevert(abi.encodeWithSelector(E_READER.selector, address(r), uint8(2)));
        dir.list(LEDGER, LENS, address(r));
        // a contract that is not a reader at all reverts in the probe
        vm.expectRevert();
        dir.list(LEDGER, LENS, address(dir));
    }

    function testPagedListingInAppendOrder() public {
        address[] memory listed = new address[](5);
        for (uint256 i; i < 5; ++i) {
            listed[i] = address(_reader(LEDGER, bytes32(i + 1)));
            dir.list(LEDGER, LENS, listed[i]);
        }
        assertEq(dir.count(LEDGER, LENS), 5);
        (address[] memory a,,, bytes32[] memory phys, uint16 next) = dir.readers(LEDGER, LENS, 0, 2);
        assertEq(a.length, 2);
        assertEq(a[0], listed[0]);
        assertEq(a[1], listed[1]);
        assertEq(phys[1], bytes32(uint256(2)));
        assertEq(next, 2);
        (a,,,, next) = dir.readers(LEDGER, LENS, next, 2);
        assertEq(a[0], listed[2]);
        assertEq(a[1], listed[3]);
        assertEq(next, 4);
        (a,,,, next) = dir.readers(LEDGER, LENS, next, 2);
        assertEq(a.length, 1);
        assertEq(a[0], listed[4]);
        assertEq(next, 0);
        // past the end: empty, exhausted
        (a,,,, next) = dir.readers(LEDGER, LENS, 9, 2);
        assertEq(a.length, 0);
        assertEq(next, 0);
    }

    function testMalformedProfileRepliesRefused() public {
        bytes[] memory replies = new bytes[](4);
        replies[0] = hex"00"; // shorter than the two head words
        replies[1] = abi.encode(uint256(0x40), uint256(0x1000)); // offset past the reply
        replies[2] = abi.encode(uint256(0x40), uint256(0x40), uint256(1)); // length 1, no element
        replies[3] = abi.encode(uint256(0x40), type(uint256).max); // offset that would wrap
        for (uint256 i; i < replies.length; ++i) {
            RawProfilesReader r = new RawProfilesReader(LEDGER, replies[i]);
            vm.expectRevert(abi.encodeWithSelector(E_READER.selector, address(r), uint8(3)));
            dir.list(LEDGER, LENS, address(r));
        }
        // a well-formed raw reply with an empty physical list is accepted (0 recorded)
        RawProfilesReader ok =
            new RawProfilesReader(LEDGER, abi.encode(new bytes32[](0), new bytes32[](0)));
        dir.list(LEDGER, LENS, address(ok));
        assertEq(dir.count(LEDGER, LENS), 1);
    }
}
