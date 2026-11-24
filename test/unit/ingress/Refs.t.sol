// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {stdError} from "forge-std/StdError.sol";
import {KernelFixture} from "../../harness/KernelFixture.sol";
import {AcceptAll, ContextAssertingAcceptor} from "../../harness/doubles/Acceptors.sol";
import {Action} from "../../../src/interfaces/Actions.sol";
import {TypeInfo} from "../../../src/interfaces/ITypeRegistry.sol";
import {AcceptContext, RefHeader} from "../../../src/interfaces/IAcceptor.sol";
import {Effect} from "../../../src/interfaces/Index.sol";
import {E_REF, E_REJECTED} from "../../../src/interfaces/Errors.sol";

/// @notice `validateLeaf`'s reference resolution (design §6.4, §9.2 refTypes sentinels): the leading `refCount`
///         body words must name existing records of the expected Types (0 ANY, 1 SELF, exact ids ≥ 2^16; every
///         other value below 2^16 reserved), and the acceptor receives exactly the `AcceptContext`, body, refs
///         and `RefHeader[]` the ingress built (§16.3 unit/ingress, vectored through the digest double).
/// @dev Per ref the code checks, in order (src/core/LedgerIngress.sol:546-558): body long enough (code 1),
///      word ≥ 2^16 (code 3), record exists (code 1), refTypes entry not a reserved sentinel (code 4), Type
///      matches (code 2). A reserved sentinel is therefore only reported once the word names a real record.
contract RefsTest is KernelFixture {
    bytes32[8] internal targets; // TYPE_OK records at admissions 1..8
    bytes[8] internal targetBodies;

    function setUp() public override {
        super.setUp();
        Action[] memory a = new Action[](8);
        bytes[] memory b = new bytes[](8);
        for (uint256 i; i < 8; ++i) {
            b[i] = abi.encode(keccak256(abi.encode("refs/target", i)), i, "tail");
            a[i] = _publish(TYPE_OK, b[i]);
            targets[i] = _rid(TYPE_OK, b[i]);
            targetBodies[i] = b[i];
        }
        _exec(a, b);
    }

    function _refType(bytes32 id, uint8 n, bytes32[] memory refTypes, address rule, uint8 words)
        internal
    {
        TypeInfo memory info = _nativeType(rule);
        info.refCount = n;
        info.refHeaderWords = words;
        _registerType(id, info, refTypes);
    }

    function _any(uint256 n) internal pure returns (bytes32[] memory) {
        return new bytes32[](n);
    }

    function _one(bytes32 v) internal pure returns (bytes32[] memory l) {
        l = new bytes32[](1);
        l[0] = v;
    }

    /// The first `n` targets as body words, with word `bad` (if < n) replaced by `badWord`, then a payload.
    function _body(uint256 n, uint256 bad, bytes32 badWord)
        internal
        view
        returns (bytes memory body)
    {
        for (uint256 i; i < n; ++i) {
            body = bytes.concat(body, i == bad ? badWord : targets[i]);
        }
        body = bytes.concat(body, "payload");
    }

    function _ref(uint256 refIndex, uint8 code) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(E_REF.selector, uint8(0), uint8(refIndex), code);
    }

    function _refuse(bytes32 typeId, bytes memory body, bytes memory err) internal {
        _expectNoChange(_acts(_publish(typeId, body)), _bodies(1, 0, body), err);
    }

    // ---- refCount 1..8 ---------------------------------------------------------------------------------------

    function test_refcount_1_to_8_any_resolve_and_reach_the_index() public {
        for (uint8 n = 1; n <= 8; ++n) {
            bytes32 t = keccak256(abi.encode("refs/any", n));
            _refType(t, n, _any(n), address(acceptAll), 1);
            bytes memory body = _body(n, 8, 0);
            vm.recordLogs();
            _exec(_acts(_publish(t, body)), _bodies(1, 0, body));
            (Effect[] memory e, bytes32[] memory refs) = _effects(vm.getRecordedLogs());
            assertEq(e[0].refCount, n, "Effect.refCount");
            assertEq(refs.length, n, "refs reach the index");
            for (uint256 i; i < n; ++i) {
                assertEq(refs[i], targets[i]);
            }
        }
    }

    function test_missing_record_is_code_1_at_every_index() public {
        for (uint8 n = 1; n <= 8; ++n) {
            bytes32 t = keccak256(abi.encode("refs/missing", n));
            _refType(t, n, _any(n), address(acceptAll), 1);
            _refuse(t, _body(n, n - 1, keccak256("refs/nowhere")), _ref(n - 1, 1));
            bytes memory short;
            for (uint256 i; i + 1 < n; ++i) {
                short = bytes.concat(short, targets[i]);
            }
            _refuse(t, short, _ref(n - 1, 1)); // the body is one word short
        }
    }

    function test_exact_type_mismatch_is_code_2() public {
        bytes32 t = keccak256("refs/exact");
        bytes32[] memory types = new bytes32[](3);
        (types[0], types[1], types[2]) = (0, TYPE_OK, TYPE_OK2);
        _refType(t, 3, types, address(acceptAll), 1);
        _refuse(t, _body(3, 8, 0), _ref(2, 2));
        types[2] = TYPE_OK;
        _refType(t, 3, types, address(acceptAll), 1);
        bytes memory body = _body(3, 8, 0);
        _exec(_acts(_publish(t, body)), _bodies(1, 0, body));
    }

    function test_self_ref_resolves_to_the_leafs_own_type() public {
        bytes32 s = keccak256("refs/self");
        _refType(s, 0, _any(0), address(acceptAll), 1);
        bytes memory seed = "refs/self/seed";
        _exec(_acts(_publish(s, seed)), _bodies(1, 0, seed));
        _refType(s, 1, _one(bytes32(uint256(1))), address(acceptAll), 1);
        bytes memory body = bytes.concat(_rid(s, seed), "child");
        _exec(_acts(_publish(s, body)), _bodies(1, 0, body));
        _refuse(s, _body(1, 8, 0), _ref(0, 2)); // a TYPE_OK record is not SELF
    }

    function test_sentinel_word_in_body_is_code_3() public {
        bytes32 t = keccak256("refs/sentinel-word");
        _refType(t, 3, _any(3), address(acceptAll), 1);
        uint256[5] memory words = [uint256(0), 1, 2, 0x1ff, 0xffff];
        for (uint256 i; i < words.length; ++i) {
            _refuse(t, _body(3, i % 3, bytes32(words[i])), _ref(i % 3, 3));
        }
        _refuse(t, _body(3, 1, bytes32(uint256(1 << 16))), _ref(1, 1)); // 2^16 is an id, not a sentinel
    }

    // The code refuses every refTypes value in [2, 2^16) (src/core/LedgerIngress.sol:557); §9.2 names 2..0xFF
    // and 0x100..0x1FF reserved and ids ≥ 2^16 exact, and is silent on 0x200..0xFFFF (stricter, not divergent).
    function test_reserved_sentinel_in_refTypes_is_code_4() public {
        bytes32 t = keccak256("refs/reserved");
        uint256[6] memory sentinels = [uint256(2), 0xff, 0x100, 0x1ff, 0x200, 0xffff];
        for (uint256 i; i < sentinels.length; ++i) {
            _refType(t, 1, _one(bytes32(sentinels[i])), address(acceptAll), 1);
            _refuse(t, _body(1, 8, 0), _ref(0, 4));
            _refuse(t, _body(1, 0, keccak256("refs/nowhere")), _ref(0, 1)); // missing precedes reserved
        }
    }

    // ---- AcceptContext, body, refs and RefHeader[] reach the acceptor exactly ---------------------------------

    function _headers(uint8 words) internal view returns (RefHeader[] memory h) {
        h = new RefHeader[](3);
        for (uint256 i; i < 3; ++i) {
            (bytes32 w0, uint256 w1, uint256 w2) =
                abi.decode(targetBodies[i], (bytes32, uint256, uint256));
            h[i] = RefHeader({
                typeId: TYPE_OK,
                firstAdmission: uint64(i + 1),
                length: uint32(targetBodies[i].length),
                word0: w0,
                word1: words >= 2 ? bytes32(w1) : bytes32(0),
                word2: words >= 3 ? bytes32(w2) : bytes32(0)
            });
        }
    }

    function _ctx(bytes32 t, uint8 leaf, TypeInfo memory info)
        internal
        view
        returns (AcceptContext memory c)
    {
        (uint64 admissions,,,) = _counts();
        c = AcceptContext({
            typeId: t,
            realmId: hot.realmId(),
            principalId: principal,
            admission: admissions + 1 + leaf,
            revision: hot.revision(),
            grade: info.grade,
            leaf: leaf,
            ledger: k.proxy,
            index: index,
            registry: address(registry),
            descriptorBlob: info.descriptorBlob,
            customPredicate: info.custom,
            bindingId: info.bindingId
        });
    }

    function test_context_body_refs_and_headers_1_to_3_words_reach_the_acceptor() public {
        for (uint8 words = 1; words <= 3; ++words) {
            bytes32 t = keccak256(abi.encode("refs/context", words));
            bytes memory body = _body(3, 8, 0);
            TypeInfo memory info = _nativeType(address(acceptAll));
            (info.refCount, info.refHeaderWords, info.descriptorBlob) = (3, words, address(0xB10B));
            (info.custom, info.bindingId) = (address(0xC0DE), keccak256("refs/binding"));
            bytes32[] memory refs = new bytes32[](3);
            (refs[0], refs[1], refs[2]) = (targets[0], targets[1], targets[2]);
            bytes32 want = keccak256(abi.encode(_ctx(t, 1, info), body, refs, _headers(words)));
            // negative control first: a digest for leaf 0 refuses the same publication
            bytes32 wrong = keccak256(abi.encode(_ctx(t, 0, info), body, refs, _headers(words)));
            ContextAssertingAcceptor bad = new ContextAssertingAcceptor(t, wrong);
            (info.mandatory, info.ruleId) = (address(bad), address(bad).codehash);
            _registerType(t, info, _any(3));
            Action[] memory a = _acts(_create(bytes32(uint256(words))), _publish(t, body));
            _expectNoChange(
                a, _bodies(2, 1, body), abi.encodeWithSelector(E_REJECTED.selector, uint8(1), t)
            );
            ContextAssertingAcceptor good = new ContextAssertingAcceptor(t, want);
            (info.mandatory, info.ruleId) = (address(good), address(good).codehash);
            _registerType(t, info, _any(3));
            _exec(a, _bodies(2, 1, body));
        }
    }

    function test_reuse_resolves_refs_from_the_stored_words() public {
        bytes32 t = keccak256("refs/reuse");
        _refType(t, 2, _any(2), address(acceptAll), 2);
        bytes memory body = _body(2, 8, 0);
        bytes32 rid = _rid(t, body);
        _exec(_acts(_publish(t, body)), _bodies(1, 0, body));
        vm.recordLogs();
        _exec(_acts(_reuse(t, rid)), _bodies(1));
        (Effect[] memory e, bytes32[] memory refs) = _effects(vm.getRecordedLogs());
        assertEq(
            abi.encode(e[0].refCount, refs), abi.encode(uint8(2), _pair(targets[0], targets[1]))
        );
    }

    function _pair(bytes32 a, bytes32 b) internal pure returns (bytes32[] memory l) {
        l = new bytes32[](2);
        (l[0], l[1]) = (a, b);
    }

    // The kernel never compares TypeInfo.refCount with limits.maxRefs (8): it trusts the registry's row. A row
    // with refCount 9 validates, then overruns the apply delegate's bytes32[8] refs buffer
    // (src/core/LedgerApply.sol:157-160) and the publication reverts Panic(0x32). Only a misbehaving registry
    // reaches this; recorded so a registry-side bound is not assumed to be a kernel one.
    function test_refcount_above_maxRefs_reverts_in_apply() public {
        bytes32 t = keccak256("refs/nine");
        _refType(t, 9, _any(9), address(acceptAll), 1);
        bytes memory body;
        for (uint256 i; i < 9; ++i) {
            body = bytes.concat(body, targets[i % 8]);
        }
        vm.expectRevert(stdError.indexOOBError);
        ledger.execute(_acts(_publish(t, body)), _bodies(1, 0, body), _native(1), "");
    }
}
