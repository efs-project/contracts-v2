// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Action, Native} from "../../../src/interfaces/Actions.sol";
import {ILedger} from "../../../src/interfaces/ILedger.sol";
import {IReader} from "../../../src/interfaces/Readers.sol";
import {EfsNative} from "../../../src/lib/EfsNative.sol";

// Doubles for the consumer suites (test/consumer/) and the reader-directory suite (test/periphery/).

/// Calls `execute` from its constructor: a code-less caller that is not `tx.origin`, which the kernel refuses
/// with `E_NATIVE_AMBIGUOUS` (design §2.2 S2) — the constructor-time impersonation guard.
contract ConstructorWriter {
    constructor(ILedger ledger) {
        Action[] memory actions = new Action[](1);
        actions[0] = EfsNative.createAction(keccak256("efs2/test/consumer/constructor-writer"));
        Native memory ctx;
        EfsNative.execute(ledger, actions, new bytes[](1), ctx);
    }
}

/// A bare `IReader` whose ledger, layout id and physical profiles are fixed at construction.
contract ReaderDouble is IReader {
    address internal immutable LEDGER;
    bytes32 internal immutable LAYOUT;
    bytes32[] internal _physical;

    constructor(address ledger_, bytes32 layoutId_, bytes32[] memory physical) {
        LEDGER = ledger_;
        LAYOUT = layoutId_;
        _physical = physical;
    }

    function ledger() external view returns (address) {
        return LEDGER;
    }

    function layoutId() external view returns (bytes32) {
        return LAYOUT;
    }

    function supportedProfiles()
        external
        view
        returns (bytes32[] memory callbackProfiles, bytes32[] memory physicalProfiles)
    {
        callbackProfiles = new bytes32[](1);
        callbackProfiles[0] = keccak256("efs2/test/callback-profile");
        physicalProfiles = _physical;
    }
}

/// An `IReader` whose `supportedProfiles()` reply is the raw bytes given at construction (malformed shapes).
contract RawProfilesReader {
    address internal immutable LEDGER;
    bytes internal _reply;

    constructor(address ledger_, bytes memory reply) {
        LEDGER = ledger_;
        _reply = reply;
    }

    function ledger() external view returns (address) {
        return LEDGER;
    }

    function layoutId() external pure returns (bytes32) {
        return keccak256("efs2/test/layout");
    }

    function supportedProfiles() external view returns (bytes32[] memory, bytes32[] memory) {
        bytes memory r = _reply;
        assembly ("memory-safe") {
            return(add(r, 0x20), mload(r))
        }
    }
}
