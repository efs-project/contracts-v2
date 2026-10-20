// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IReader, IReaderDirectory} from "../interfaces/Readers.sol";
import {CodePins} from "../lib/CodePins.sol";
import {E_READER} from "../interfaces/Errors.sol";

/// @title ReaderDirectory — the permissionless, append-only, advisory reader directory (design §5.13, §3.1 row 17)
/// @notice Anyone lists a reader for `(ledger, kind)`; a listing records the reader's codehash, `layoutId` and
///         first physical profile at listing time and is never removed or changed. Nothing in the kernel reads
///         this contract: a listing is a discovery hint, never an endorsement — a client still pins the reader's
///         codehash from a release it trusts and checks the basis every read echoes. `kind` is the caller's
///         label (for example `keccak256("efs2/reader/lens/1")`); the directory does not interpret it.
/// @dev Immutable, no owner. Refuses a code-less or EIP-7702-designator reader (`E_CODE_SHAPE`, `CodePins`) and,
///      as `E_READER(reader, code)`: 1 already listed under this `(ledger, kind)`, 2 `ledger()` names another
///      ledger, 3 a malformed `supportedProfiles()` reply, 4 the `(ledger, kind)` list is full (the `uint16` page
///      index). The reader's views are called by `STATICCALL`, so a hostile reader cannot re-enter; it can only
///      burn the lister's own gas.
contract ReaderDirectory is IReaderDirectory {
    struct Listing {
        address reader;
        bytes32 codehash;
        bytes32 layoutId;
        bytes32 physicalProfile;
    }

    /// A listing refused; `code` as in the contract notes.

    /// The recorded row is read back through `readers`; the event carries only its position.
    event ReaderListed(
        address indexed ledger, bytes32 indexed kind, address indexed reader, uint16 ordinal
    );

    mapping(address ledger => mapping(bytes32 kind => Listing[])) private _listings;
    mapping(address ledger => mapping(bytes32 kind => mapping(address reader => bool))) private
        _listed;

    /// @inheritdoc IReaderDirectory
    function list(address ledger, bytes32 kind, address reader) external {
        bytes32 codehash = CodePins.realCodeAndHash(reader);
        if (IReader(reader).ledger() != ledger) revert E_READER(reader, 2);
        if (_listed[ledger][kind][reader]) revert E_READER(reader, 1);
        Listing[] storage rows = _listings[ledger][kind];
        uint256 ordinal = rows.length;
        if (ordinal >= type(uint16).max) revert E_READER(reader, 4);
        bytes32 layoutId = IReader(reader).layoutId();
        bytes32 physicalProfile = _firstPhysicalProfile(reader);
        _listed[ledger][kind][reader] = true;
        rows.push(Listing(reader, codehash, layoutId, physicalProfile));
        emit ReaderListed(ledger, kind, reader, uint16(ordinal));
    }

    /// The first element of `supportedProfiles().physicalProfiles`, 0 when the list is empty. Reads only the
    /// second head word, that array's length and its first element, each bounds-checked against the reply.
    function _firstPhysicalProfile(address reader) private view returns (bytes32 p) {
        bytes4 sel = IReader.supportedProfiles.selector;
        bool ok;
        assembly ("memory-safe") {
            mstore(0, sel)
            ok := staticcall(gas(), reader, 0, 4, 0, 0)
            let size := returndatasize()
            ok := and(ok, iszero(lt(size, 0x40)))
            if ok {
                returndatacopy(0, 0x20, 0x20)
                let off := mload(0)
                ok := iszero(gt(off, sub(size, 0x20)))
                if ok {
                    returndatacopy(0, off, 0x20)
                    if mload(0) {
                        ok := iszero(gt(off, sub(size, 0x40)))
                        if ok {
                            returndatacopy(0, add(off, 0x20), 0x20)
                            p := mload(0)
                        }
                    }
                }
            }
        }
        if (!ok) revert E_READER(reader, 3);
    }

    /// @inheritdoc IReaderDirectory
    /// @dev Listing order; `next` is the index to continue from, 0 once the list is exhausted. The reply is
    ///      encoded here directly from the rows (four 32-byte slots each: reader, codehash, layoutId,
    ///      physicalProfile), which keeps the unit inside its 1,500 B design size.
    function readers(address ledger, bytes32 kind, uint16 from, uint16 max)
        external
        view
        returns (address[] memory, bytes32[] memory, bytes32[] memory, bytes32[] memory, uint16)
    {
        Listing[] storage rows = _listings[ledger][kind];
        uint256 total = rows.length;
        uint256 start = from < total ? from : total;
        uint256 end = start + max < total ? start + max : total;
        uint256 next = end < total ? end : 0;
        assembly ("memory-safe") {
            let n := sub(end, start)
            let stride := shl(5, add(n, 1)) // one array: length word + n elements
            let out := mload(0x40)
            mstore(out, 0xa0)
            mstore(add(out, 0x20), add(0xa0, stride))
            mstore(add(out, 0x40), add(0xa0, mul(2, stride)))
            mstore(add(out, 0x60), add(0xa0, mul(3, stride)))
            mstore(add(out, 0x80), next)
            mstore(0, rows.slot)
            let base := add(keccak256(0, 0x20), shl(2, start))
            for { let j := 0 } lt(j, 4) { j := add(j, 1) } {
                let arr := add(add(out, 0xa0), mul(j, stride))
                mstore(arr, n)
                for { let i := 0 } lt(i, n) { i := add(i, 1) } {
                    mstore(add(arr, shl(5, add(i, 1))), sload(add(base, add(shl(2, i), j))))
                }
            }
            return(out, add(0xa0, mul(4, stride)))
        }
    }

    /// The number of readers listed under `(ledger, kind)`.
    function count(address ledger, bytes32 kind) external view returns (uint16) {
        return uint16(_listings[ledger][kind].length);
    }
}
