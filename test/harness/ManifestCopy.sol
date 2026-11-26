// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ILedgerHot} from "../../src/interfaces/ILedgerHot.sol";
import {IIndexReads} from "../../src/interfaces/IIndexReads.sol";
import {DigestSpec, FamilyEntry, Unit, WorkModel} from "../../src/interfaces/Index.sol";

/// @notice The copy of a live index's manifest preimage a later generation is deployed with
///         (`IIndexReads.liveManifestCopy`, docs INDEX-BUILD §3.5, §10): `abi.encode` of the reads contract's
///         `manifest()` with that contract's address and codehash, whose keccak is the index's `manifestHash()`. Read
///         from the reads contract itself (its manifest is static and does not depend on the caller), so it can be taken
///         from an index that no longer answers.
library ManifestCopy {
    function ofReads(address reads) internal view returns (bytes memory) {
        (
            bytes32 header,
            FamilyEntry[] memory families,
            Unit[] memory units,
            DigestSpec[] memory specs,
            WorkModel memory work,
            bytes32 physical,
            bytes32 callback
        ) = IIndexReads(reads).manifest();
        return
            abi.encode(
                header, families, units, specs, work, physical, callback, reads, reads.codehash
            );
    }

    /// The copy for a generation deployed on `ledger` now: of its live index, or empty when it has none.
    function ofLive(address ledger) internal view returns (bytes memory) {
        address live = ILedgerHot(ledger).index();
        if (live == address(0)) return "";
        (address reads,) = IIndexReads(live).readsContract();
        return ofReads(reads);
    }
}
