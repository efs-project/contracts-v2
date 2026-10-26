// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ControlFixture} from "../harness/ControlFixture.sol";
import {KernelDeploy} from "../harness/KernelDeploy.sol";
import {PrefixAgreement} from "../harness/doubles/IndexDoubles.sol";
import {AcceptAll} from "../harness/doubles/Acceptors.sol";
import {Delegator} from "../harness/doubles/WrapperDouble.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {ActivationSet} from "../../src/interfaces/ILedgerControl.sol";
import {FamilyEntry, Readiness, Unit} from "../../src/interfaces/Index.sol";
import {E_CODE_SHAPE} from "../../src/interfaces/Errors.sol";

/// @notice §2.2 S6 — the ledger's activation code gates parametrized over hostile code shapes: a code-less
///         address (`E_CODE_SHAPE` reason 1), an EIP-7702 designator (2), a `DELEGATECALL` passthrough (3) and
///         an EIP-1167 clone (5), each at the index, the steward, the build delegate, a unit's fold and final
///         hooks, and a family store (`LedgerControl._checkIndex`, src/core/LedgerControl.sol:247-320). Every
///         hostile pin is named by a codehash that matches it, so only `CodePins`/`CodeScan` can refuse it.
///         The registry's gates are `test/unit/registry/TypeRegistry.t.sol::testActivatePolicyGatesAndRows`
///         (policy) and `::testActivateWrapperReadsTheWrappersOwnConstants` (wrapper); the controller
///         migration gate is `test/security/MigrationSuccessor.t.sol`; the reader directory's is
///         `test/periphery/ReaderDirectory.t.sol::testCodelessAndDesignatorRefused`.
contract CodeGatesTest is ControlFixture {
    struct Hostile {
        address account;
        uint8 reason;
    }

    bytes32 internal constant MANIFEST = keccak256("efs2/test/security/code-gates/manifest");

    function _hostiles() internal returns (Hostile[4] memory h) {
        address target = address(new AcceptAll());
        h[0] = Hostile(makeAddr("code-gates/code-less"), 1);
        address designator = makeAddr("code-gates/designator");
        vm.etch(designator, abi.encodePacked(hex"ef0100", target));
        h[1] = Hostile(designator, 2);
        h[2] = Hostile(address(new Delegator(target)), 3);
        h[3] = Hostile(Clones.clone(target), 5);
    }

    function _err(Hostile memory h) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(E_CODE_SHAPE.selector, h.account, h.reason);
    }

    /// A caught-up candidate index whose readiness tuple is honest except for `r`'s edits.
    function _candidate(Readiness memory r) internal returns (ActivationSet memory) {
        PrefixAgreement idx = newIndexDouble(MANIFEST);
        r.ledger = k.proxy;
        r.manifestHash = MANIFEST;
        idx.setReadiness(r);
        return withIndex(nextSet(), address(idx));
    }

    function _honest() internal view returns (Readiness memory r) {
        (uint64 admissions,,, uint64 publications) = hot.counts();
        return readiness(index, admissions, publications);
    }

    function _unit(address fold, address fin) internal view returns (Unit[] memory u) {
        u = new Unit[](1);
        u[0].foldHook = fold;
        u[0].foldCodehash = fold == address(0) ? bytes32(0) : fold.codehash;
        u[0].finalHook = fin;
        u[0].finalCodehash = fin == address(0) ? bytes32(0) : fin.codehash;
        u[0].familyIds = new bytes32[](0);
        u[0].hotAbiId = KernelDeploy.HOT_ABI_ID;
        u[0].identity = keccak256("efs2/test/security/code-gates/unit");
    }

    function test_every_activation_code_gate_refuses_every_hostile_shape() public {
        publishMarker("code-gates/populated");
        bytes32 digest = fullDigest(1);
        Hostile[4] memory hs = _hostiles();
        for (uint256 i; i < hs.length; ++i) {
            Hostile memory h = hs[i];
            ActivationSet memory set;

            // the index itself (a new generation)
            set = nextSet();
            set.components.index = h.account;
            set.components.indexCodehash = h.account.codehash;
            set.components.indexManifestHash = MANIFEST;
            expectActivateRevert(seal(set), _err(h));

            // the steward
            set = nextSet();
            set.components.steward = h.account;
            expectActivateRevert(seal(set), _err(h));

            // the build delegate a candidate generation names
            Readiness memory r = _honest();
            r.build = h.account;
            r.buildCodehash = h.account.codehash;
            expectActivateRevert(_candidate(r), _err(h));

            // a unit's fold hook, then its final hook
            r = _honest();
            r.units = _unit(h.account, address(0));
            expectActivateRevert(_candidate(r), _err(h));
            r = _honest();
            r.units = _unit(address(0), h.account);
            expectActivateRevert(_candidate(r), _err(h));

            // a family store (a BITMAP family, so the APPEND from-1 rule does not fire first)
            r = _honest();
            r.families = new FamilyEntry[](1);
            r.families[0] = FamilyEntry({
                familyId: Keys.familyId("scope"),
                kind: 4,
                universe: 3,
                shape: 2,
                mandatory: true,
                liveSemantics: 2,
                recipe: 0,
                fromAdmission: 1,
                store: h.account,
                storeCodehash: h.account.codehash
            });
            expectActivateRevert(_candidate(r), _err(h));
        }
        // nothing moved, and the honest next set still activates
        assertEq(fullDigest(1), digest, "a refused activation changed retained state");
        assertEq(hot.revision(), 1);
        activate(nextSet());
        assertEq(hot.revision(), 2);
    }
}
