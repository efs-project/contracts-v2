// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FilesFixture} from "../../profiles/FilesFixture.sol";
import {FilesPageReader} from "../../../src/readers/FilesPageReader.sol";
import {LedgerReads} from "../../../src/readers/LedgerReads.sol";
import {LedgerViews} from "../../../src/readers/LedgerViews.sol";
import {EfsFiles} from "../../../src/lib/EfsFiles.sol";
import {Keys} from "../../../src/lib/Keys.sol";
import {Action, Native} from "../../../src/interfaces/Actions.sol";
import {BasisCommit} from "../../../src/interfaces/Results.sol";
import {IFilesPageReader} from "../../../src/interfaces/Readers.sol";
import {ILedgerCommitments} from "../../../src/interfaces/ILedgerCommitments.sol";

/// @notice The `FilesPageReader` suites' fixture: the Files Realm of `FilesFixture` (kernel, real registry proxy,
///         real generation-1 index with `FilesFinalValidator` pinned, the nine Types registered), the two read
///         facets, a `FilesPageReader` over them, the Realm root seeded by this contract's principal through
///         `EfsFiles.rootSeed`, and native-lane writers for this contract and for EOA authors (both expectations
///         bound, the SDK default).
abstract contract FilesPageHarness is FilesFixture {
    uint32 internal constant F_NAME = 1;
    uint32 internal constant F_HEADER = 2;
    uint32 internal constant F_KIND = 4;
    uint32 internal constant F_ALL = 7;
    uint8 internal constant ROW_ENTRY = 1;
    uint8 internal constant ROW_WHITEOUT = 3;
    uint8 internal constant ROW_INVALID = 4;
    uint8 internal constant SCAN_EXHAUSTED = 1;
    uint8 internal constant SCAN_LIMIT = 2;
    uint8 internal constant SCAN_GAS = 3;

    Realm internal r;
    LedgerReads internal reads;
    LedgerViews internal views;
    FilesPageReader internal reader;
    EfsFiles.Types internal t;
    bytes32 internal p; // this contract's principal
    bytes32 internal rootDir;

    function _setUpFiles(bytes32 realmSalt) internal {
        _deployProfile();
        r = _realm(realmSalt);
        _register(r);
        p = r.principal;
        reads = new LedgerReads();
        views = new LedgerViews();
        reader = new FilesPageReader(
            address(r.ledger),
            address(views),
            address(reads),
            typeIds[T_NAME],
            typeIds[T_ROOT],
            typeIds[T_CHILD]
        );
        t = EfsFiles.Types({
            root: typeIds[T_ROOT],
            child: typeIds[T_CHILD],
            directory: typeIds[T_DIRECTORY],
            name: typeIds[T_NAME],
            bytes_: typeIds[T_BYTES],
            content: typeIds[T_CONTENT],
            external_: typeIds[T_EXTERNAL],
            alias_: typeIds[T_ALIAS],
            notice: typeIds[T_NOTICE]
        });
        (Action[] memory a, bytes[] memory b, bytes32 root) =
            EfsFiles.rootSeed(t, p, keccak256("root"));
        rootDir = root;
        _exec(a, b);
    }

    // ---- writers -------------------------------------------------------------------------------------------

    function _exec(Action[] memory a, bytes[] memory b) internal returns (uint64 publication) {
        return _execAs(address(this), a, b);
    }

    /// Native execution as `author` (an EOA author is also tx.origin), both expectations bound.
    function _execAs(address author, Action[] memory a, bytes[] memory b)
        internal
        returns (uint64 publication)
    {
        bytes32 principal = author == address(this) ? p : Keys.principal(author);
        Native memory c;
        (c.nonce,) = r.hot.nonceOf(principal);
        c.expectedExecutionSet = r.hot.executionSet();
        c.expectedAcceptanceProfile =
            ILedgerCommitments(r.hot.ingress()).acceptanceProfileOf(address(r.ledger), a);
        if (author != address(this)) vm.prank(author, author);
        (publication,) = r.ledger.execute(a, b, c, "");
    }

    /// A file in `folder` named `name` with a root record holding `document`; returns (file, rootRecord).
    function _file(
        address author,
        bytes32 folder,
        string memory name,
        string memory document,
        bool withName
    ) internal returns (bytes32 file, bytes32 rootRecord) {
        bytes32 principal = author == address(this) ? p : Keys.principal(author);
        (Action[] memory a, bytes[] memory b, bytes32 f, bytes32 rr) = EfsFiles.createFile(
            t,
            principal,
            folder,
            keccak256(abi.encode(folder, name, author)),
            bytes(name),
            bytes(document),
            withName
        );
        _execAs(author, a, b);
        return (f, rr);
    }

    function _folder(bytes32 parent, string memory name) internal returns (bytes32 dir) {
        (Action[] memory a, bytes[] memory b, bytes32 d) =
            EfsFiles.createFolder(t, p, parent, keccak256(bytes(name)), bytes(name), true);
        _exec(a, b);
        return d;
    }

    // ---- reads ---------------------------------------------------------------------------------------------

    function _lens(bytes32 a) internal pure returns (bytes32[] memory l) {
        l = new bytes32[](1);
        l[0] = a;
    }

    function _lens(bytes32 a, bytes32 b) internal pure returns (bytes32[] memory l) {
        l = new bytes32[](2);
        l[0] = a;
        l[1] = b;
    }

    function _lens(bytes32 a, bytes32 b, bytes32 c) internal pure returns (bytes32[] memory l) {
        l = new bytes32[](3);
        l[0] = a;
        l[1] = b;
        l[2] = c;
    }

    function _q(uint32 fields, uint8 kinds)
        internal
        pure
        returns (IFilesPageReader.Query memory q)
    {
        q.fields = fields;
        q.kinds = kinds;
    }

    function _unbound() internal pure returns (BasisCommit memory b) {}

    function _list(bytes32 folder, bytes32[] memory lens, uint32 fields)
        internal
        view
        returns (IFilesPageReader.DirectoryPage memory)
    {
        return reader.listDirectory(folder, lens, _q(fields, 0), _unbound(), "", 0, 0);
    }

    /// Every page of a listing until it is exhausted (at most `maxPages`).
    function _drain(
        bytes32 folder,
        bytes32[] memory lens,
        IFilesPageReader.Query memory q,
        uint32 limit,
        uint256 callGas,
        uint256 gasReserve,
        uint256 maxPages
    ) internal view returns (IFilesPageReader.DirectoryPage[] memory pages, uint256 n) {
        pages = new IFilesPageReader.DirectoryPage[](maxPages);
        bytes memory next;
        while (n < maxPages) {
            pages[n] = reader.listDirectory{gas: callGas}(
                folder, lens, q, _unbound(), next, limit, gasReserve
            );
            next = pages[n].next;
            ++n;
            if (next.length == 0) break;
        }
    }
}
