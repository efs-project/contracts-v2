// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {TopicListsHistory} from "../integration/TopicListsHistory.sol";
import {IGeneration1, IndexDeploy} from "../harness/IndexDeploy.sol";
import {KernelDeploy} from "../harness/KernelDeploy.sol";
import {MockRegistry} from "../harness/doubles/MockRegistry.sol";
import {StandInTypes} from "../harness/doubles/StandInTypes.sol";
import {AcceptAll} from "../harness/doubles/Acceptors.sol";
import {Factory} from "../harness/doubles/Factory.sol";
import {IndexReplayDecoder} from "../../src/index/IndexReplayDecoder.sol";
import {DescribedCodec} from "../../src/types/DescribedCodec.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {Action, ActionKind, Native} from "../../src/interfaces/Actions.sol";
import {Effect, DigestSpec, Unit} from "../../src/interfaces/Index.sol";
import {ILedger} from "../../src/interfaces/ILedger.sol";
import {ILedgerControl} from "../../src/interfaces/ILedgerControl.sol";
import {ITypeRegistry, TypeInfo} from "../../src/interfaces/ITypeRegistry.sol";
import {E_REPLAY} from "../../src/interfaces/Errors.sol";

/// The decoder's count path, exposed for the tests (the same code `decode` runs for every PUBLISH and REUSE leaf).
contract ProvedCountProbe is IndexReplayDecoder {
    function refCountOf(address registry, bytes32 typeId) external view returns (uint8) {
        return _refCount(registry, typeId);
    }
}

/// A NATIVE rule that is never called: the 4,096-byte Type below needs a real instance to be registered.
contract InertRule {
    function f() external pure returns (uint256) {
        return 1;
    }
}

/// @notice Docs INDEX-BUILD §4.3 row 19b: the decoder PROVES a Type's reference count from the Type's descriptor
///         instead of reading the registry's stored count. Trusted: the registry answers `descriptorBytes` with some
///         bytes. Proved: they are the registered descriptor and the count is its number of references, because the
///         Type id commits to both. On the real Files Realm of `TopicListsHistory` (the thirteen release Types, the
///         mixed history), with registry answers replaced by `vm.mockCall` where a test needs a registry that lies.
contract ProvedRefCountTest is TopicListsHistory {
    ProvedCountProbe internal probe;

    /// The registry's stored counts of the thirteen release Types, by `T_*` index (FilesTypes, TopicTypes).
    uint8[13] internal pinned = [0, 1, 0, 0, 0, 1, 1, 0, 0, 2, 0, 2, 0];

    function setUp() public virtual override {
        super.setUp();
        probe = new ProvedCountProbe();
    }

    function _registry() internal view returns (address) {
        return address(r.registry);
    }

    function _notProved() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(E_REPLAY.selector, uint8(10));
    }

    /// Every publication of the Realm decoded by `dec`, hashed one by one (the payload `build` folds).
    function _decodeAll(IndexReplayDecoder dec) internal view returns (bytes32[] memory h) {
        (,,, uint64 publications) = r.hot.counts();
        h = new bytes32[](publications);
        for (uint64 n = 1; n <= publications; ++n) {
            h[n - 1] = keccak256(dec.payload(address(r.ledger), n));
        }
    }

    function _fresh() internal returns (IGeneration1 ix) {
        (, ix) = _generation(address(0), address(0));
    }

    // ---- (1) the thirteen release Types ----------------------------------------------------------------------------

    function test_every_release_type_is_proved_and_equals_its_stored_count() public view {
        for (uint8 t; t < TYPE_COUNT; ++t) {
            TypeInfo memory info = r.registry.typeInfo(typeIds[t]);
            assertEq(info.refCount, pinned[t], "the stored count, pinned");
            assertEq(probe.refCountOf(_registry(), typeIds[t]), pinned[t], "proved == stored");
            assertTrue(info.descriptorBlob != address(0), "every release Type has a blob");
        }
    }

    // ---- (2) a wrong stored count changes nothing ------------------------------------------------------------------

    /// The registry's `typeInfo` answers a wrong count (7) for every Type and the decoder never asks it: every
    /// publication decodes to the same payload, and a full replay builds to its end.
    function test_a_wrong_stored_count_changes_nothing() public {
        _mixedHistory();
        IndexReplayDecoder dec = new IndexReplayDecoder();
        bytes32[] memory before = _decodeAll(dec);
        bool refs;
        for (uint64 n = 1; n <= before.length; ++n) {
            (Effect[] memory e,) = dec.decode(address(r.ledger), n);
            for (uint256 i; i < e.length; ++i) {
                if (e[i].refCount != 0) refs = true;
            }
        }
        assertTrue(refs, "the history has leaves with references");
        IGeneration1 ix = _fresh();
        TypeInfo memory lie;
        lie.grade = 3;
        lie.refCount = 7;
        vm.mockCall(
            _registry(), abi.encodeWithSelector(ITypeRegistry.typeInfo.selector), abi.encode(lie)
        );
        vm.expectCall(_registry(), abi.encodeWithSelector(ITypeRegistry.typeInfo.selector), 0);
        bytes32[] memory afterLie = _decodeAll(dec);
        assertEq(keccak256(abi.encode(afterLie)), keccak256(abi.encode(before)), "same payloads");
        (uint64 admissions,,,) = r.hot.counts();
        while (ix.build(bytes32(0), 64) != admissions) {}
        vm.clearMockedCalls();
    }

    // ---- (3) a registry that answers other bytes ----------------------------------------------------------------

    function _mockDescriptor(bytes32 id, bytes memory d) internal {
        vm.mockCall(_registry(), abi.encodeCall(ITypeRegistry.descriptorBytes, (id)), abi.encode(d));
    }

    /// Each wrong answer for `files-name/2`'s descriptor is refused `E_REPLAY(10)`: a byte of the name altered, a byte
    /// of the rule id altered, the last byte cut, cut below the 134-byte header, another Type's descriptor (one with
    /// two references, `topic/1`), and empty bytes.
    function test_other_bytes_are_refused_10() public {
        bytes32 id = typeIds[T_NAME];
        bytes memory good = r.registry.descriptorBytes(id);
        bytes memory nameByte = bytes.concat(good);
        nameByte[134] = bytes1(uint8(nameByte[134]) ^ 1);
        bytes memory ruleByte = bytes.concat(good);
        ruleByte[70] = bytes1(uint8(ruleByte[70]) ^ 1);
        bytes memory cut = new bytes(good.length - 1);
        bytes memory belowHeader = new bytes(100);
        for (uint256 i; i < cut.length; ++i) {
            cut[i] = good[i];
            if (i < 100) belowHeader[i] = good[i];
        }
        bytes[6] memory wrong = [
            nameByte,
            ruleByte,
            cut,
            belowHeader,
            r.registry.descriptorBytes(typeIds[T_TOPIC]),
            bytes("")
        ];
        for (uint256 i; i < wrong.length; ++i) {
            _mockDescriptor(id, wrong[i]);
            vm.expectRevert(_notProved());
            probe.refCountOf(_registry(), id);
        }
        vm.clearMockedCalls();
        assertEq(probe.refCountOf(_registry(), id), 0, "the true bytes prove it");
    }

    /// A `build` over a registry that answers another Type's descriptor for a Type the history uses refuses
    /// `E_REPLAY(10)` and changes nothing: the frontier and the stores are as before the call.
    function test_a_build_over_a_lying_registry_refuses_and_changes_nothing() public {
        _mixedHistory();
        IGeneration1 ix = _fresh();
        _mockDescriptor(typeIds[T_NAME], r.registry.descriptorBytes(typeIds[T_TOPIC]));
        _mockDescriptor(typeIds[T_TOPIC], "");
        (uint64 before,,) = ix.progress();
        vm.expectRevert(_notProved());
        ix.build(bytes32(0), 64);
        (uint64 afterRefusal,,) = ix.progress();
        assertEq(afterRefusal, before, "the frontier did not move");
        vm.clearMockedCalls();
        (uint64 admissions,,,) = r.hot.counts();
        while (ix.build(bytes32(0), 64) != admissions) {}
    }

    // ---- (4) a registry whose descriptorBytes reverts ----------------------------------------------------------

    /// The decoder bubbles the registry's own revert (no catch: a registry that withholds a descriptor makes the
    /// decode and the build refuse with its error), and the build changes nothing.
    function test_a_registry_that_reverts_is_bubbled_and_the_build_changes_nothing() public {
        _mixedHistory();
        IGeneration1 ix = _fresh();
        bytes memory gone = abi.encodeWithSignature("E_GONE()");
        vm.mockCallRevert(
            _registry(), abi.encodeWithSelector(ITypeRegistry.descriptorBytes.selector), gone
        );
        vm.expectRevert(gone);
        probe.refCountOf(_registry(), typeIds[T_NAME]);
        (uint64 before,,) = ix.progress();
        vm.expectRevert(gone);
        ix.build(bytes32(0), 64);
        (uint64 afterRefusal,,) = ix.progress();
        assertEq(afterRefusal, before);
        vm.clearMockedCalls();
    }

    // ---- (5) the largest descriptor the codec admits -------------------------------------------------------------

    function parse(bytes calldata d) external pure returns (bytes32[] memory refs) {
        (, refs) = DescribedCodec.parse(d);
    }

    function shapeOf(bytes calldata d) external pure returns (bytes32) {
        return Keys.shape(d);
    }

    /// A 4,096-byte descriptor (16 fields, the leading 8 references), registered as a real NATIVE Type: the decoder's
    /// count path proves 8, the stored count.
    function test_the_largest_descriptor_is_proved() public {
        bytes memory initcode = type(InertRule).creationCode;
        address instance = Factory.deploy(initcode);
        bytes memory d = _maxDescriptor(declarationKey, instance.codehash, keccak256(initcode));
        assertEq(d.length, 4096);
        bytes32 id = Keys.typeId(this.shapeOf(d), this.parse(d), instance.codehash);
        bytes memory sig = _declare(r.registry, id);
        r.store.put(d, sig);
        (bytes32 got,) = r.registry.registerDescribed(d, sig, instance, "");
        assertEq(got, id);
        assertEq(r.registry.typeInfo(id).refCount, 8);
        assertEq(probe.refCountOf(_registry(), id), 8);
    }

    function _maxDescriptor(address key, bytes32 ruleCodehash, bytes32 aux)
        internal
        pure
        returns (bytes memory d)
    {
        uint256 nameLen = 255;
        uint256 descLen = 4096 - 134 - nameLen - 16 * 164;
        d = new bytes(4096);
        d[0] = 0x01;
        d[2] = 0x03; // NATIVE
        d[3] = bytes1(uint8(16));
        d[4] = 0x01;
        d[5] = 0x01;
        d[6] = 0x01;
        d[7] = 0x01;
        d[13] = bytes1(uint8(nameLen));
        for (uint256 i; i < 20; ++i) {
            d[14 + i] = bytes20(key)[i];
        }
        _word(d, 34, keccak256("efs/test/largest/namespace"));
        _word(d, 66, ruleCodehash);
        _word(d, 98, aux);
        d[130] = bytes1(uint8(descLen >> 8));
        d[131] = bytes1(uint8(descLen));
        d[132] = 0x01;
        for (uint256 i = 134; i < 134 + nameLen + descLen; ++i) {
            d[i] = 0x61;
        }
        uint256 start = 134 + nameLen + descLen;
        for (uint256 f; f < 16; ++f) {
            uint256 p_ = start + f * 164;
            _word(d, p_, bytes32(f + 1));
            _word(d, p_ + 32, bytes32(uint256(7)));
            d[p_ + 64] = f < 8 ? bytes1(0x01) : bytes1(0x02);
            d[p_ + 67] = 0x20; // width 32
            if (f < 8) _word(d, p_ + 132, keccak256(abi.encode("efs/test/largest/ref", f)));
        }
    }

    function _word(bytes memory d, uint256 at, bytes32 w) internal pure {
        assembly ("memory-safe") {
            mstore(add(add(d, 32), at), w)
        }
    }
}

/// @notice The property the stand-in Types exposed: a record whose Type id no descriptor derives cannot be decoded.
///         It cannot occur on a real Realm, because the registry registers a Type only under the id derived from its
///         descriptor (`TypeRegistry._retain`: `Keys.typeId(Keys.shape(descriptor), refs, h.ruleCodehash)`), and the
///         kernel admits a record only of a registered Type (`E_UNKNOWN_TYPE`). A `MockRegistry` can name any id:
///         here `test/type/made-up`, served the stand-in `test/type/ok` descriptor, which derives another id.
contract UnderivedTypeTest is Test {
    bytes32 internal constant MADE_UP = keccak256("test/type/made-up");

    function test_a_type_id_no_descriptor_derives_cannot_be_decoded() public {
        MockRegistry registry = new MockRegistry();
        KernelDeploy.Kernel memory k =
            KernelDeploy.deploy(address(this), address(registry), keccak256("underived"));
        registry.setLedger(k.proxy);
        registry.setImplementation(address(registry));
        registry.setActiveRevision(1);
        IndexDeploy.Gen1 memory g = IndexDeploy.deploy(
            k.proxy, KernelDeploy.HOT_ABI_ID, new Unit[](0), new DigestSpec[](0)
        );
        ILedgerControl(k.proxy)
            .activate(
                KernelDeploy.genesisSet(
                    k, address(this), address(registry), address(g.index), g.index.manifestHash()
                )
            );
        AcceptAll acceptAll = new AcceptAll();
        TypeInfo memory info;
        info.grade = 3;
        info.refHeaderWords = 1;
        info.mandatory = address(acceptAll);
        info.ruleId = address(acceptAll).codehash;
        info.policyRows = 1;
        info.policyRow = 1;
        registry.setType(MADE_UP, info, new bytes32[](0));
        vm.expectRevert("MockRegistry: descriptor does not derive the id");
        registry.setDescriptor(MADE_UP, StandInTypes.ok());
        registry.setRawDescriptor(MADE_UP, StandInTypes.ok());
        bytes memory body = "0123456789abcdef0123456789abcdef-tail";
        Action[] memory actions = new Action[](1);
        actions[0].kind = ActionKind.PUBLISH;
        actions[0].typeId = MADE_UP;
        actions[0].bodyHashOrRecordId = keccak256(body);
        bytes[] memory bodies = new bytes[](1);
        bodies[0] = body;
        Native memory ctx;
        (uint64 pub,) = ILedger(k.proxy).execute(actions, bodies, ctx, "");
        IndexReplayDecoder dec = new IndexReplayDecoder();
        vm.expectRevert(abi.encodeWithSelector(E_REPLAY.selector, uint8(10)));
        dec.decode(k.proxy, pub);
    }
}
