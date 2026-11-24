// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ILedgerHot} from "../../../src/interfaces/ILedgerHot.sol";
import {Effect} from "../../../src/interfaces/Index.sol";
import {Phase} from "../../../src/interfaces/Results.sol";
import {E_ORDER, E_STAGED} from "../../../src/interfaces/Errors.sol";
import {BaseIndexDouble} from "./IndexDoubles.sol";

/// @notice The honest index plus a log of every effect it acknowledged, so a test can rebuild the publication's
///         `Effect[]` and `refs` exactly as the prefix calls carried them (design §5.5: `effectsHash =
///         keccak256(abi.encode(Effect[]))`). Each prefix call must observe phase APPLYING with
///         `publication == stagedPublication` (`E_STAGED`), effects contiguous with the last one seen (`E_ORDER`)
///         and the staged frontier `counts().admissions` equal to the last effect's admission.
/// @dev Not a `PrefixAgreement` subclass: its `onAdmission` is not `virtual`. The log is an event, not storage,
///      so the double stays cheap under both gas schedules and the bounded-gas fixtures keep their margins.
contract RecordingIndex is BaseIndexDouble {
    event EffectSeen(uint64 indexed publication, Effect effect, bytes32[] refs);

    error E_RECORDING_DIVERGED(uint8 code, uint64 observed);

    constructor(address ledger_) BaseIndexDouble(ledger_) {}

    function onAdmission(uint64 publication, Effect[] calldata effects, bytes32[] calldata refs)
        public
        override
        returns (bytes4)
    {
        _requireLedger();
        (uint8 phase, uint64 staged,,) = ILedgerHot(msg.sender).phase();
        if (phase != Phase.APPLYING) revert E_RECORDING_DIVERGED(1, phase);
        if (publication != staged) revert E_STAGED(staged, publication);
        uint64 expected = lastProcessed + 1;
        for (uint256 i; i < effects.length; ++i) {
            if (effects[i].admission != expected) revert E_ORDER(expected, effects[i].admission);
            emit EffectSeen(publication, effects[i], refs);
            ++expected;
        }
        (uint64 admissions,,,) = ILedgerHot(msg.sender).counts();
        if (admissions != expected - 1) revert E_RECORDING_DIVERGED(2, admissions);
        return super.onAdmission(publication, effects, refs);
    }
}
