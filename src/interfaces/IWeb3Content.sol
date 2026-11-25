// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {KeyValue} from "./IWeb3Gateway.sol";

/// @title IWeb3Content — the content half of the `web3://` gateway (docs/LARGE-FILES.md "`web3://`")
/// @notice Serves one Files revision record as an ERC-5219 response: inline bytes, one chunk of a `files-content/1`
///         descriptor (carrier 0 or a span tree), or a `files-external/1` location as a `307`. Stateless and
///         immutable; `EfsWeb3Gateway` reaches it by STATICCALL at an immutable address whose codehash it records.
///         It resolves no name and no lens: the gateway does that and hands it the revision record its HEAD law
///         selected. Every input it takes is one a `web3://` URL can name (`/~efs/v/<revision>?offset=<n>`), so a
///         direct call reveals nothing the gateway does not. Refusals revert `E_WEB3_STATUS(status, reason)`.
interface IWeb3Content {
    /// The ledger this server reads (the gateway refuses a server bound to another).
    function ledger() external view returns (address);

    /// Revision record `revision` served from byte `offset`.
    /// @param file the file subject the revision must belong to (the reader-side HEAD law: a `files-root/1` or
    ///        `files-child/1` record whose file word is `file`; a breach is a 500), or 0 for a revision link (any
    ///        revision record of this profile; another existing record or a created subject is 501, an id that
    ///        names nothing 404)
    /// @param name the final path name whose extension gives `Content-Type` when no descriptor declares a media
    ///        type; empty when there is none (`application/octet-stream`)
    /// @return status 200 or 307
    /// @return body the bytes served (one chunk of a large file), empty for a 307
    /// @return headers `Content-Type` first, then the record and descriptor headers
    /// @return next the offset of the next chunk when the response does not reach the end of the file, else 0
    function serveRevision(bytes32 revision, bytes32 file, bytes calldata name, uint256 offset)
        external
        view
        returns (uint16 status, bytes memory body, KeyValue[] memory headers, uint256 next);
}
