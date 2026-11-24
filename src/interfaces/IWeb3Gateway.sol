// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// One ERC-5219 query parameter or response header.
struct KeyValue {
    string key;
    string value;
}

/// @title IWeb3Gateway — the ERC-5219 resource-request mode (ERC-4804/6860 `web3://` URLs, ERC-7617 chunks)
/// @notice A `web3://<contract>:<chainId>/<path>?<query>` client calls `resolveMode()` and, on `"5219"`, `request`
///         with the URL path split on `/` and percent-decoded (`resource`) and the query pairs (`params`). The
///         response is an HTTP status, the body (raw bytes carried in a `string`) and the headers. ERC-7617: a
///         response that is not the last chunk carries the header `web3-next-chunk` whose value is the URL (path and
///         query, starting with `/`) of the next chunk; the client concatenates the bodies. The EFS implementation
///         is `EfsWeb3Gateway` (docs/LARGE-FILES.md "`web3://`").
interface IWeb3Gateway {
    /// `bytes32("5219")`.
    function resolveMode() external pure returns (bytes32);

    function request(string[] memory resource, KeyValue[] memory params)
        external
        view
        returns (uint16 statusCode, string memory body, KeyValue[] memory headers);
}
