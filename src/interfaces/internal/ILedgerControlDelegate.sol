// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

// Kernel-internal: outside the consumer closure. The kernel's control selectors (design §5.4) apply their
// modifiers and forward msg.data verbatim to this delegate, which carries the same selectors.
import {ILedgerControl} from "../ILedgerControl.sol";

/// @title ILedgerControlDelegate — the activation, freeze, transition and genesis writer (design §8)
/// @notice Runs only by DELEGATECALL in the ledger's context; writes `efs.ledger.v2.{realm,revisions}` and
///         the transition word; pinned by the kernel implementation's CONTROL/CONTROL_CODEHASH immutables.
interface ILedgerControlDelegate is ILedgerControl {}
