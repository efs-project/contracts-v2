// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IAcceptor, AcceptContext, RefHeader} from "../interfaces/IAcceptor.sol";
import {E_FILES_SUNSET} from "./FilesProfile.sol";

/// @title RefuseAllPolicy — the explicit sunset policy (design §9.5 (iii))
/// @notice A profile upgrade registers new Types and activates this contract as the policy of each old Type
///         (`activatePolicy(oldType, refuseAll)`), never `address(0)` (which is the no-policy row that sunsets a
///         policy, F5a). Every record of a sunset Type is then refused with `E_POLICY_REJECTED(leaf, typeId, row)`,
///         PUBLISH and REUSE alike; the records already admitted stay readable. It reads nothing and refuses
///         every context, forged or not, so it needs no `ctx.ledger` check.
contract RefuseAllPolicy is IAcceptor {
    function accept(
        AcceptContext calldata,
        bytes calldata,
        bytes32[] calldata,
        RefHeader[] calldata
    ) external pure returns (bytes4) {
        revert E_FILES_SUNSET();
    }
}
