// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Coordinate, ScopeKey} from "./Actions.sol";
import {BasisCommit, Coverage, Qualified, Status} from "./Results.sol";
import {RecordHeader} from "./Views.sol";

// Readers — the Lens and Files page readers and the reader directory (design §5.13, §11). Readers resolve the
// live index per call (`ILedgerHot(ledger).index()`), serve any generation whose callbackProfile/physicalProfile
// they list in `supportedProfiles()` and return UNSUPPORTED otherwise; they pin layoutId through
// `BasisCommit.executionSet` and return BASIS_STALE/UNSUPPORTED as data. Listing-coverage law: a paged reader's
// coverage is the listing's, COMPLETE only when `completeFromOrigin`; a page produced from a continuation is at
// most PARTIAL. `scanStatus` (both page structs): 1 EXHAUSTED (the scope list ended) 2 LIMIT (row limit reached)
// 3 GAS (gasReserve early stop); 0 and 4..255 reserved.

/// A Lens listing continuation. lensHash = keccak(abi.encode(principals)); never msg.sender.
struct Cursor {
    BasisCommit basis;
    ScopeKey scope;
    bytes32 lensHash;
    uint64 lensIndex;
    uint64 rawIndex;
    uint64 selectedSoFar;
    bytes32 queryHash;
}

/// One resolved coordinate under a lens.
struct Selection {
    Status status;
    bytes32 target;
    uint8 targetKind;
    uint64 revision;
    bytes32 principalId;
    uint64 admission;
    uint8 selectedIndex;
}

/// One listed position.
struct Entry {
    bytes32 position;
    bytes32 role;
    Selection selection;
}

/// One page of a Lens listing.
struct Page {
    Qualified q;
    Entry[] rows;
    Cursor next;
    uint64 scanned;
    uint64 rawTotal;
    uint64 observedCurrent;
    uint64 selectedSoFar;
    bytes32 inventoryPin;
    uint8 scanStatus;
    bool startsAtOrigin;
    bool completeFromOrigin;
    Coverage listingCoverage;
}

/// @title IReader — the surface every reader listed in the directory implements (design §5.13)
interface IReader {
    function ledger() external view returns (address);

    function layoutId() external view returns (bytes32);

    function supportedProfiles()
        external
        view
        returns (bytes32[] memory callbackProfiles, bytes32[] memory physicalProfiles);
}

/// @title ILensReader — ordered-principal resolution and listing (design §5.13, §11)
/// @notice `fallThroughPolicy`: 1 MASK_BEATS_FALLTHROUGH (FOLDER, HEAD) or 2 SILENCE_FALLS_THROUGH (tag stances),
///         a reader parameter per purpose, not a kernel law.
interface ILensReader is IReader {
    function resolve(
        bytes32[] calldata principals,
        Coordinate calldata c,
        BasisCommit calldata expected
    ) external view returns (Qualified memory, Selection memory);

    /// One call: resolve + header + body.
    function resolveRecord(
        bytes32[] calldata principals,
        Coordinate calldata c,
        uint32 maxBytes,
        BasisCommit calldata expected
    )
        external
        view
        returns (Qualified memory, Selection memory, RecordHeader memory, bytes memory body);

    function resolveNoTiebreak(
        bytes32[] calldata principals,
        Coordinate calldata c,
        BasisCommit calldata expected
    ) external view returns (Qualified memory, Selection[] memory candidates);

    function resolveAt(
        bytes32[] calldata principals,
        Coordinate calldata c,
        uint64 asOf,
        BasisCommit calldata expected
    ) external view returns (Qualified memory, Selection memory);

    function resolveManyAt(
        bytes32[] calldata principals,
        Coordinate[] calldata coords,
        uint64 asOf,
        BasisCommit calldata expected
    ) external view returns (Qualified memory, Selection[] memory);

    function list(
        bytes32[] calldata principals,
        bytes32 purpose,
        bytes32 subject,
        Cursor calldata cursor,
        uint32 budget,
        uint8 fallThroughPolicy,
        BasisCommit calldata expected
    ) external view returns (Page memory);
}

/// @title IFilesPageReader — Files directory pages and name lookup (design §5.13, §12)
/// @notice Continuations are bound to (queryHash, basis) and refused otherwise.
interface IFilesPageReader is IReader {
    /// fields: F_NAME 1, F_HEADER 2, F_KIND 4, F_TAGS 8.
    struct Query {
        uint32 fields;
        bytes32 tagConcept;
        uint8 kinds;
    }

    /// headRecord/headRevision/headerWord0: the resolved HEAD record of a file row under F_HEADER (so a file
    /// read after a page is one `record()` call); rowKind: 1 ENTRY 2 ALIAS 3 WHITEOUT.
    struct Row {
        bytes32 position;
        bytes name;
        uint8 targetKind;
        bytes32 target;
        bytes32 headRecord;
        uint64 headRevision;
        uint64 admission;
        bytes32 headerWord0;
        uint8 rowKind;
    }

    /// One directory page; see the listing-coverage law above.
    struct DirectoryPage {
        Qualified q;
        Row[] rows;
        Coverage listingCoverage;
        uint64 frontier;
        bytes next;
        uint64 scanned;
        uint64 rawTotal;
        uint64 observedCurrent;
        uint64 selectedSoFar;
        bytes32 inventoryPin;
        uint8 scanStatus;
        bool startsAtOrigin;
        bool completeFromOrigin;
    }

    function listDirectory(
        bytes32 folderSubject,
        bytes32[] calldata principals,
        Query calldata q,
        BasisCommit calldata expected,
        bytes calldata continuation,
        uint32 limit,
        uint256 gasReserve
    ) external view returns (DirectoryPage memory);

    function lookupName(
        bytes32 folderSubject,
        bytes32 nameRole,
        bytes32[] calldata principals,
        BasisCommit calldata expected
    ) external view returns (Qualified memory, Row memory);
}

/// @title IReaderDirectory — the permissionless, append-only, advisory reader directory (design §5.13)
interface IReaderDirectory {
    /// Requires real code and IReader(reader).ledger() == ledger; records codehash, layoutId, physicalProfile.
    function list(address ledger, bytes32 kind, address reader) external;

    /// physicalProfiles[i] = the reader's first listed physical profile at listing time.
    function readers(address ledger, bytes32 kind, uint16 from, uint16 count)
        external
        view
        returns (
            address[] memory,
            bytes32[] memory codehashes,
            bytes32[] memory layoutIds,
            bytes32[] memory physicalProfiles,
            uint16 next
        );
}
