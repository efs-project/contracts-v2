// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {KernelFixture} from "../../harness/KernelFixture.sol";
import {KernelDeploy} from "../../harness/KernelDeploy.sol";
import {NativeCounterfeit} from "../../harness/doubles/Signers.sol";
import {IndexDoubleCore} from "../../harness/doubles/IndexDoubles.sol";
import {Keys} from "../../../src/lib/Keys.sol";
import {Layout} from "../../../src/core/layout/Layout.sol";
import {Action, Native} from "../../../src/interfaces/Actions.sol";
import {ClosureConstants, Limits} from "../../../src/interfaces/Limits.sol";
import {Effect} from "../../../src/interfaces/Index.sol";
import {
    E_BATCH_SHAPE,
    E_COUNTER_SATURATED,
    E_NATIVE_AMBIGUOUS
} from "../../../src/interfaces/Errors.sol";

/// @notice Entry bounds (design §6.1 step 8), native-author ambiguity (§2.2 S2), the 48-bit saturation guards
///         (§6.3, §2.2 S11; port of RecordOccurrenceBounds) and the `Published` event's fields (§5.5).
contract BoundsTest is KernelFixture {
    uint48 internal constant SAT = uint48(ClosureConstants.SATURATION);

    function _creates(uint256 n) internal pure returns (Action[] memory l) {
        l = new Action[](n);
        for (uint256 i; i < n; ++i) {
            l[i] = _create(keccak256(abi.encode("bounds/create", i)));
        }
    }

    function _filled(uint256 len, uint8 b) internal pure returns (bytes memory out) {
        out = new bytes(len);
        for (uint256 i; i < len; ++i) {
            out[i] = bytes1(b);
        }
    }

    function _setCounters(uint48 adm, uint48 rec, uint48 bnd, uint48 pubs) internal {
        uint256 w =
            uint256(adm) | (uint256(rec) << 48) | (uint256(bnd) << 96) | (uint256(pubs) << 144);
        vm.store(k.proxy, Layout.LEDGER_COUNTERS_ROOT, bytes32(w));
    }

    function _shape(uint256 n, uint256 m) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(E_BATCH_SHAPE.selector, uint16(n), uint16(m));
    }

    // ---- E_BATCH_SHAPE -------------------------------------------------------------------------------------

    function test_zero_actions() public {
        _expectNoChange(new Action[](0), new bytes[](0), _shape(0, 0));
    }

    function test_65_actions_refused_64_land() public {
        _expectNoChange(_creates(65), _bodies(65), _shape(65, 65));
        _exec(_creates(64), _bodies(64));
        (uint64 admissions,,,) = _counts();
        assertEq(admissions, 64);
    }

    function test_bodies_length_must_equal_actions_length() public {
        _expectNoChange(_creates(2), _bodies(1), _shape(2, 1));
        _expectNoChange(_creates(1), _bodies(2), _shape(1, 2));
    }

    function test_binds_above_maxBindsPerPublication() public {
        Limits memory l = KernelDeploy.s1Limits();
        l.maxBindsPerPublication = 2;
        _activateNext(index, l);
        bytes32 r = _rid(TYPE_OK, "b");
        _exec(_acts(_publish(TYPE_OK, "b")), _bodies(1, 0, "b"));
        // BIND, UNBIND and RELEASE all count; the bound precedes every per-leaf check
        Action[] memory three = _acts(
            _bind(FOLDER, "s1", ROLE, r, 0),
            _unbind(FOLDER, "s2", ROLE, 0),
            _release(FOLDER, "s3", ROLE, 0)
        );
        _expectNoChange(three, _bodies(3), _shape(3, 3));
        _exec(
            _acts(_bind(FOLDER, "s1", ROLE, r, 0), _bind(FOLDER, "s2", ROLE, r, 0), _create("c")),
            _bodies(3)
        );
    }

    function test_body_bytes_above_maxBodyBytesPerPublication() public {
        bytes memory a = _filled(8_192, 0x11);
        bytes memory b = _filled(8_192, 0x22);
        bytes[] memory bodies = new bytes[](3);
        (bodies[0], bodies[1], bodies[2]) = (a, b, hex"00");
        // 16,385 bytes: refused before the CREATE leaf's own E_SHAPE(2, 3)
        _expectNoChange(
            _acts(_publish(TYPE_OK, a), _publish(TYPE_OK, b), _create("c")), bodies, _shape(3, 3)
        );
        bytes[] memory exact = new bytes[](2);
        (exact[0], exact[1]) = (a, b);
        _exec(_acts(_publish(TYPE_OK, a), _publish(TYPE_OK, b)), exact); // 16,384 is the limit itself
        (, uint64 records,,) = _counts();
        assertEq(records, 2);
    }

    // ---- E_NATIVE_AMBIGUOUS --------------------------------------------------------------------------------

    function test_constructor_time_caller_is_E_NATIVE_AMBIGUOUS() public {
        bytes32 salt = keccak256("bounds/counterfeit");
        NativeCounterfeit c = new NativeCounterfeit(k.proxy, salt);
        assertTrue(c.constructorReverted());
        assertEq(c.constructorReturndata(), abi.encodeWithSelector(E_NATIVE_AMBIGUOUS.selector));
        (uint64 admissions,,, uint64 publications) = _counts();
        assertEq(admissions + publications, 0, "nothing landed");
        (bool ok,) = c.attempt(0, salt);
        assertTrue(ok, "the same contract authors once it has code");
        bytes32 author = Keys.contractPrincipal(hot.realmOrigin(), address(c));
        assertEq(hot.subjectCreatedAt(Keys.subject(author, salt)), 1);
    }

    // ---- 48-bit saturation (S11) ---------------------------------------------------------------------------

    function test_publication_and_admission_counters_saturate_closed() public {
        _setCounters(0, 0, 0, SAT);
        vm.expectRevert(abi.encodeWithSelector(E_COUNTER_SATURATED.selector, uint8(0)));
        ledger.execute(_creates(1), _bodies(1), _native(0), "");
        _setCounters(0, 0, 0, SAT - 1);
        ledger.execute(_creates(1), _bodies(1), _native(0), ""); // lands as publication SAT
        (,,, uint64 publications) = _counts();
        assertEq(publications, SAT);

        _setCounters(SAT - 1, 0, 0, 1);
        IndexDoubleCore(index).setProgress(SAT - 1, 1);
        vm.expectRevert(abi.encodeWithSelector(E_COUNTER_SATURATED.selector, uint8(0)));
        ledger.execute(_creates(2), _bodies(2), _native(1), "");
        ledger.execute(_acts(_create("late")), _bodies(1), _native(1), ""); // admission SAT is the last
        (uint64 admissions,,,) = _counts();
        assertEq(admissions, SAT);
        (uint64 nonce,) = hot.nonceOf(principal);
        assertEq(nonce, 2);
    }

    function test_record_and_binding_counters_saturate_closed() public {
        _setCounters(0, SAT, 0, 0);
        _expectNoChange(
            _acts(_publish(TYPE_OK, "fresh")),
            _bodies(1, 0, "fresh"),
            abi.encodeWithSelector(E_COUNTER_SATURATED.selector, uint8(1))
        );
        _setCounters(0, 0, 0, 0);
        bytes32 r = _rid(TYPE_OK, "fresh");
        _exec(_acts(_publish(TYPE_OK, "fresh")), _bodies(1, 0, "fresh"));
        _setCounters(1, 1, SAT, 1);
        bytes32 key = _key(principal, FOLDER, "s", ROLE);
        vm.expectRevert(abi.encodeWithSelector(E_COUNTER_SATURATED.selector, uint8(2)));
        ledger.execute(_acts(_bind(FOLDER, "s", ROLE, r, 0)), _bodies(1), _native(1), "");
        (uint8 state,,,,,,) = hot.head(key);
        assertEq(state, 0, "no head row");
    }

    function _setOccurrences(bytes32 rid, uint48 occ) internal {
        uint256 s = Layout.recordsCellsSlot(rid) + 1;
        uint256 w = uint256(_raw(s));
        w = (w & ~(uint256(type(uint48).max) << 80)) | (uint256(occ) << 80);
        vm.store(k.proxy, bytes32(s), bytes32(w));
    }

    /// RecordOccurrenceBounds: max − 1 allows exactly one more occurrence by either kind; at max both refuse;
    /// a refusal at the second leaf rolls back the first leaf's prefix.
    function test_occurrences_saturate_closed_and_roll_back_the_prefix() public {
        bytes memory body = "bounds/occ";
        bytes32 rid = _rid(TYPE_OK, body);
        _exec(_acts(_publish(TYPE_OK, body)), _bodies(1, 0, body));
        bytes memory sat = abi.encodeWithSelector(E_COUNTER_SATURATED.selector, uint8(1));
        bytes[] memory two = new bytes[](2);
        two[1] = body;
        for (uint256 order; order < 2; ++order) {
            _setOccurrences(rid, SAT - 1);
            Action[] memory pair = order == 0
                ? _acts(_reuse(TYPE_OK, rid), _publish(TYPE_OK, body))
                : _acts(_publish(TYPE_OK, body), _reuse(TYPE_OK, rid));
            if (order == 0) (two[0], two[1]) = (bytes(""), body);
            else (two[0], two[1]) = (body, bytes(""));
            _expectNoChange(pair, two, sat);
        }
        _exec(_acts(_publish(TYPE_OK, body)), _bodies(1, 0, body));
        (,,, uint64 occ,) = hot.recordHeader(rid);
        assertEq(occ, SAT);
        _expectNoChange(_acts(_publish(TYPE_OK, body)), _bodies(1, 0, body), sat);
        _expectNoChange(_acts(_reuse(TYPE_OK, rid)), _bodies(1), sat);
        _setOccurrences(rid, SAT - 1);
        _exec(_acts(_reuse(TYPE_OK, rid)), _bodies(1));
        (,,, occ,) = hot.recordHeader(rid);
        assertEq(occ, SAT);
    }

    // ---- the Published event (§5.5) ------------------------------------------------------------------------

    function test_published_event_fields() public {
        bytes memory body = "bounds/published";
        bytes32 rid = _rid(TYPE_OK, body);
        bytes32 sid = _sid(principal, "p");
        Action[] memory actions =
            _acts(_create("p"), _publish(TYPE_OK, body), _bind(FOLDER, sid, ROLE, rid, 0));
        vm.roll(block.number + 3);
        vm.recordLogs();
        (uint64 publication, uint64 first) = _exec(actions, _bodies(3, 1, body));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        PublishedLog memory p = _published(logs);
        (Effect[] memory effects,) = _effects(logs);
        (uint64 stored, bytes32 intentDigest) = hot.publicationAt(principal, 0);
        Native memory ctx = _native(0);
        bytes32 offline = keccak256(
            abi.encode(
                Keys.DOM_NATIVE_INTENT,
                hot.realmId(),
                principal,
                ctx.nonce,
                ctx.deadline,
                ctx.expectedExecutionSet,
                ctx.expectedAcceptanceProfile,
                keccak256(""),
                keccak256(abi.encode(actions))
            )
        );
        assertTrue(p.found);
        assertEq(intentDigest, offline, "stored w3 equals the offline native digest");
        assertEq(abi.encode(stored, p.publication, first), abi.encode(publication, publication, 1));
        assertEq(p.publicationId, Keys.publicationId(principal, intentDigest));
        assertEq(p.publicationId, commitments.publicationIdOf(principal, intentDigest));
        assertEq(p.principalId, principal);
        assertEq(abi.encode(p.proofKind, p.firstAdmission, p.leafCount), abi.encode(1, first, 3));
        assertEq(p.revision, hot.revision());
        assertEq(effects.length, 3);
        assertEq(
            p.effectsHash,
            keccak256(abi.encode(effects)),
            "effectsHash = keccak(abi.encode(Effect[]))"
        );
    }
}
