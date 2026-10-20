// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ControlFixture} from "../harness/ControlFixture.sol";
import {LedgerReads} from "../../src/readers/LedgerReads.sol";
import {Description} from "../../src/interfaces/Views.sol";
import {Status} from "../../src/interfaces/Results.sol";
import {Action, Intent} from "../../src/interfaces/Actions.sol";
import {ActivationSet} from "../../src/interfaces/ILedgerControl.sol";
import {E_REGISTRY, E_REGISTRY_DRIFT} from "../../src/interfaces/Errors.sol";

/// @notice §2.2 S8 — the registry implementation lies about itself or moves without an activation. The ledger
///         compares `registry.activeRevision()` with its own revision on entry to every write
///         (`LedgerCore._tripwires`, src/core/LedgerCore.sol:287-288) and at activation (§8.3 step 4,
///         `E_REGISTRY(1)`): a mismatch in either direction halts both write lanes with
///         `E_REGISTRY_DRIFT(ledgerRevision, registryRevision)` and leaves every retained row untouched, while
///         every read keeps answering. Healing is an activation (or the registry coming back into agreement).
contract RegistryDriftTest is ControlFixture {
    LedgerReads internal reads;

    function setUp() public override {
        super.setUp();
        reads = new LedgerReads();
    }

    function _signedCreate(bytes32 salt)
        internal
        view
        returns (Intent memory intent, Action[] memory actions, bytes[] memory bodies)
    {
        (actions, bodies) = createActions(salt);
        intent.realmId = hot.realmId();
        intent.realmOrigin = hot.realmOrigin();
        intent.executionSet = hot.executionSet();
        intent.principalId = keccak256("efs2/test/security/drift/signed-principal");
        intent.verifierProfile = 1;
    }

    function test_activeRevision_mismatch_halts_writes() public {
        (, bytes32 marker) = publishMarker("drift/before");
        bytes32 digest = fullDigest(1);
        uint64 nonce = nextNonce();
        (uint64 admissions,,, uint64 publications) = hot.counts();

        uint32[3] memory lies = [uint32(2), 0, type(uint32).max]; // ahead, behind, absurd
        for (uint256 i; i < lies.length; ++i) {
            registry.setActiveRevision(lies[i]);
            bytes memory drift =
                abi.encodeWithSelector(E_REGISTRY_DRIFT.selector, uint32(1), lies[i]);
            // the native lane
            expectWriteRevert("drift/native", drift);
            // the signed lane reaches the same tripwire before any verifier runs
            (Intent memory intent, Action[] memory a, bytes[] memory b) =
                _signedCreate("drift/signed");
            vm.expectRevert(drift);
            ledger.executeSigned(intent, a, b, "", "");
            // an activation whose set the registry has not recorded is refused (§8.3 step 4); a registry
            // already at the next ordinal is the heal case below
            ActivationSet memory set = nextSet();
            if (lies[i] != set.revision) {
                vm.expectRevert(abi.encodeWithSelector(E_REGISTRY.selector, uint8(1)));
                ctl.activate(set);
            }

            // nothing moved: retained rows, counters, nonce
            assertEq(fullDigest(1), digest, "a refused write changed retained state");
            assertEq(nextNonce(), nonce, "nonce intact");
            (uint64 a1,,, uint64 p1) = hot.counts();
            assertEq(abi.encode(a1, p1), abi.encode(admissions, publications));

            // reads keep working: hot getters, the facet, the existing rows
            assertEq(hot.revision(), 1);
            assertEq(hot.subjectCreatedAt(marker), admissions);
            Description memory d = reads.describe(k.proxy);
            assertEq(d.revision, 1);
            assertEq(d.realmId, hot.realmId());
            (Status st,,) = reads.subjectInfo(k.proxy, marker);
            assertEq(uint8(st), uint8(Status.PRESENT), "subjectInfo still answers");
        }

        // heal 1: the registry comes back into agreement, writes resume at the intact nonce
        registry.setActiveRevision(1);
        publishMarker("drift/healed");
        // heal 2: the registry runs ahead, and the next activation (which records revision 2 on both) heals it
        registry.setActiveRevision(2);
        expectWriteRevert(
            "drift/ahead", abi.encodeWithSelector(E_REGISTRY_DRIFT.selector, uint32(1), uint32(2))
        );
        ctl.activate(nextSet());
        assertEq(hot.revision(), 2);
        publishMarker("drift/after-activation");
    }
}
