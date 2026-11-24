// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Effect} from "./Index.sol";

/// @title IIndexHook — a pinned index unit's fold and final hooks (design §5.11, §10.3)
interface IIndexHook {
    /// Bounded CALL; may write only its declared companion store.
    function fold(Effect calldata effect, bytes32[] calldata refs, uint64 publication)
        external
        returns (bytes4);

    /// Bounded STATICCALL; exact selector ack; reads only write-once facts.
    function validate(uint64 publication, Effect[] calldata effects, bytes32[] calldata refs)
        external
        view
        returns (bytes4);
}
