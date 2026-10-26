// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {
    ITransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {TypeRegistry} from "../../../src/types/TypeRegistry.sol";
import {DescriptorStore} from "../../../src/types/DescriptorStore.sol";
import {DescribedCodec} from "../../../src/types/DescribedCodec.sol";
import {Keys} from "../../../src/lib/Keys.sol";
import {ITypeRegistry, TypeInfo} from "../../../src/interfaces/ITypeRegistry.sol";
import {Phase} from "../../../src/interfaces/Results.sol";
import {ClosureConstants} from "../../../src/interfaces/Limits.sol";
import {
    E_BINDING,
    E_BLOB,
    E_CODEC,
    E_CODE_SHAPE,
    E_DECLARATION,
    E_FROZEN,
    E_INSTANCE,
    E_NOT_CONTROLLER,
    E_PUBLICATION_ACTIVE,
    E_TYPE_EXISTS,
    E_UNKNOWN_TYPE,
    E_WRAPPER
} from "../../../src/interfaces/Errors.sol";
import {LedgerStub} from "../../harness/doubles/LedgerStub.sol";
import {Factory} from "../../harness/doubles/Factory.sol";
import {Descriptors} from "../../harness/Descriptors.sol";
import {WrapperDouble, WrapperDoubleB, Delegator} from "../../harness/doubles/WrapperDouble.sol";
import {AcceptAll, RejectAll} from "../../harness/doubles/Acceptors.sol";

/// @notice The registry under design §9: codec-1 parsing and its refusals, declaration signatures, blob
///         pinning, grade 3 with the deterministic instance, grades 1–2 against activated wrappers, the
///         idempotence law, the activation gates (controller, idle, unfrozen) and code gates, role rows,
///         wrapper activation from the wrapper's own constants, and an upgrade that preserves every table.
contract TypeRegistryTest is Test {
    using Descriptors for Descriptors.Params;

    LedgerStub internal ledger;
    DescriptorStore internal store;
    TypeRegistry internal impl;
    TypeRegistry internal registry; // the proxy
    address internal proxy;
    uint256 internal constant PK = 0xA11CE;
    address internal key;
    address internal instance; // AcceptAll at the deterministic address
    bytes32 internal initcodeHash;
    address internal constant STRANGER = address(0xBEEF);

    function setUp() public {
        ledger = new LedgerStub();
        ledger.setController(address(this));
        store = new DescriptorStore();
        impl = new TypeRegistry(address(store));
        proxy = address(
            new TransparentUpgradeableProxy(
                address(impl),
                address(this),
                abi.encodeCall(ITypeRegistry.initialize, (address(ledger), address(0)))
            )
        );
        registry = TypeRegistry(proxy);
        key = vm.addr(PK);
        bytes memory initcode = type(AcceptAll).creationCode;
        initcodeHash = keccak256(initcode);
        instance = Factory.deploy(initcode);
        assertEq(instance, registry.predictInstance(initcodeHash));
    }

    // ---- helpers ------------------------------------------------------------------------------------------

    function _native() internal view returns (Descriptors.Params memory) {
        return Descriptors.defaults(3, key, instance.codehash, initcodeHash);
    }

    function _typeIdOf(bytes memory d) internal view returns (bytes32) {
        (DescribedCodec.Header memory h, bytes32[] memory refs) = this.parse(d);
        return Keys.typeId(keccak256(abi.encode(Keys.DOM_DESCRIBED_SHAPE, d)), refs, h.ruleCodehash);
    }

    function _slice32(bytes memory d, uint256 at) internal pure returns (bytes32 w) {
        assembly ("memory-safe") {
            w := mload(add(add(d, 32), at))
        }
    }

    function parse(bytes calldata d)
        external
        pure
        returns (DescribedCodec.Header memory, bytes32[] memory)
    {
        return DescribedCodec.parse(d);
    }

    function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _declare(bytes memory d) internal returns (bytes32 typeId, bytes memory sig) {
        typeId = _typeIdOf(d);
        sig = _sign(PK, registry.declarationDigest(typeId));
        store.put(d, sig);
    }

    function _registerNative(Descriptors.Params memory p)
        internal
        returns (bytes32 typeId, uint64 ordinal)
    {
        bytes memory d = p.encode();
        (, bytes memory sig) = _declare(d);
        (typeId, ordinal) = registry.registerDescribed(d, sig, instance, "");
    }

    function _expectCodec(bytes memory d, uint16 offset, uint8 code) internal {
        vm.expectRevert(abi.encodeWithSelector(E_CODEC.selector, offset, code));
        this.parse(d);
    }

    // ---- grade 3: the happy path and the identity law --------------------------------------------------------

    function testRegisterNativeTypeWritesEveryTable() public {
        Descriptors.Params memory p = _native();
        bytes memory d = p.encode();
        (bytes32 expectedId, bytes memory sig) = _declare(d);
        (bytes32 typeId, uint64 ordinal) = registry.registerDescribed(d, sig, instance, "");
        assertEq(typeId, expectedId);
        assertEq(
            typeId,
            Keys.typeId(
                keccak256(abi.encode(Keys.DOM_DESCRIBED_SHAPE, d)),
                new bytes32[](0),
                instance.codehash
            )
        );
        assertEq(ordinal, 1);
        TypeInfo memory info = registry.typeInfo(typeId);
        assertEq(info.grade, 3);
        assertEq(info.refCount, 0);
        assertEq(info.wrapperVersion, 1);
        assertEq(info.ruleMode, 1);
        assertEq(info.dependencyClass, 1);
        assertEq(info.refHeaderWords, 1);
        assertEq(info.validationGas, 0);
        assertEq(info.policyRows, 1);
        assertEq(info.policyRow, 1);
        assertEq(info.mandatory, instance);
        assertEq(info.ruleId, instance.codehash);
        assertEq(info.shape, keccak256(abi.encode(Keys.DOM_DESCRIBED_SHAPE, d)));
        assertEq(info.descriptorBlob, store.predict(d, sig));
        assertEq(info.policy, address(0));
        assertEq(info.policyCodehash, 0);
        assertEq(info.custom, address(0));
        assertEq(info.bindingId, 0);
        assertEq(registry.refTypes(typeId).length, 0);
        assertEq(registry.catalog(1), typeId);
        assertEq(registry.catalogCount(), 1);
        assertEq(keccak256(registry.descriptorBytes(typeId)), keccak256(d));
        (address k, bool installed, bytes32 sigHash) = registry.declaration(typeId);
        assertEq(k, key);
        assertTrue(installed);
        assertEq(sigHash, keccak256(sig));
        assertEq(
            registry.typeCommitment(typeId),
            keccak256(abi.encode(typeId, instance, instance.codehash, uint16(1), bytes32(0)))
        );
        assertEq(registry.mutations(), 0, "registration never bumps mutations");
        assertEq(registry.ledger(), address(ledger));
        assertEq(registry.implementation(), address(impl));
        // the blob is a STOP-prefixed preimage pinned by its hash
        address blob = info.descriptorBlob;
        assertEq(blob.codehash, keccak256(bytes.concat(hex"00", d, sig)));
        assertEq(uint8(blob.code[0]), 0);
    }

    function testRegistrationIsIdempotentAndFrontRunSafe() public {
        Descriptors.Params memory p = _native();
        bytes memory d = p.encode();
        (bytes32 typeId, bytes memory sig) = _declare(d);
        vm.prank(STRANGER);
        (bytes32 first, uint64 o1) = registry.registerDescribed(d, sig, instance, "");
        (bytes32 second, uint64 o2) = registry.registerDescribed(d, sig, instance, "");
        assertEq(first, typeId);
        assertEq(second, typeId);
        assertEq(o1, 1);
        assertEq(o2, 1);
        assertEq(registry.catalogCount(), 1);
        // a different descriptor is a different Type, never a re-registration
        p.description = "another description";
        (bytes32 other,) = _registerNative(p);
        assertTrue(other != typeId);
        assertEq(registry.catalogCount(), 2);
        // retention alone never installs
        p.description = "retained only";
        bytes memory d3 = p.encode();
        (bytes32 id3, bytes memory sig3) = _declare(d3);
        (bytes32 retained, address blob) = registry.retainDeclaration(d3, sig3);
        assertEq(retained, id3);
        assertEq(blob, store.predict(d3, sig3));
        (, bool installed,) = registry.declaration(id3);
        assertFalse(installed);
        assertEq(registry.typeInfo(id3).mandatory, address(0));
    }

    function testNativeInstanceMustBeTheDeterministicOne() public {
        bytes memory d = _native().encode();
        (, bytes memory sig) = _declare(d);
        AcceptAll lookalike = new AcceptAll(); // same code, another address
        vm.expectRevert(abi.encodeWithSelector(E_INSTANCE.selector, instance, address(lookalike)));
        registry.registerDescribed(d, sig, address(lookalike), "");
        vm.expectRevert(abi.encodeWithSelector(E_INSTANCE.selector, instance, address(0)));
        registry.registerDescribed(d, sig, address(0), "");
        // the predicted address without code
        Descriptors.Params memory p = _native();
        p.aux = keccak256("no such initcode");
        bytes memory d2 = p.encode();
        (, bytes memory sig2) = _declare(d2);
        address empty = registry.predictInstance(p.aux);
        vm.expectRevert(abi.encodeWithSelector(E_CODE_SHAPE.selector, empty, uint8(1)));
        registry.registerDescribed(d2, sig2, empty, "");
        // a descriptor naming another codehash for the right instance
        p = _native();
        p.ruleCodehash = keccak256("not the instance's code");
        bytes memory d3 = p.encode();
        (, bytes memory sig3) = _declare(d3);
        vm.expectRevert(abi.encodeWithSelector(E_BINDING.selector, uint8(4)));
        registry.registerDescribed(d3, sig3, instance, "");
        // a binding signature on a native registration is a divergence
        vm.expectRevert(abi.encodeWithSelector(E_BINDING.selector, uint8(1)));
        registry.registerDescribed(d, sig, instance, hex"01");
    }

    function testBlobMustExistBeforeRegistration() public {
        bytes memory d = _native().encode();
        bytes32 typeId = _typeIdOf(d);
        bytes memory sig = _sign(PK, registry.declarationDigest(typeId));
        address predicted = store.predict(d, sig);
        vm.expectRevert(abi.encodeWithSelector(E_BLOB.selector, predicted));
        registry.registerDescribed(d, sig, instance, "");
        vm.expectRevert(abi.encodeWithSelector(E_BLOB.selector, predicted));
        registry.retainDeclaration(d, sig);
        assertEq(store.put(d, sig), predicted);
        assertEq(store.put(d, sig), predicted, "put is idempotent");
        registry.registerDescribed(d, sig, instance, "");
    }

    function testDeclarationSignatureLaw() public {
        bytes memory d = _native().encode();
        bytes32 typeId = _typeIdOf(d);
        bytes32 digest = registry.declarationDigest(typeId);
        bytes memory good = _sign(PK, digest);
        store.put(d, good);
        // another signer
        bytes memory other = _sign(0xB0B, digest);
        store.put(d, other);
        vm.expectRevert(abi.encodeWithSelector(E_DECLARATION.selector, uint8(4)));
        registry.registerDescribed(d, other, instance, "");
        // wrong length
        vm.expectRevert(abi.encodeWithSelector(E_DECLARATION.selector, uint8(1)));
        registry.registerDescribed(d, hex"00", instance, "");
        // high-s
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PK, digest);
        bytes32 highS = bytes32(
            0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141 - uint256(s)
        );
        bytes memory malleable = abi.encodePacked(r, highS, v == 27 ? uint8(28) : uint8(27));
        vm.expectRevert(abi.encodeWithSelector(E_DECLARATION.selector, uint8(2)));
        registry.registerDescribed(d, malleable, instance, "");
        // bad v
        vm.expectRevert(abi.encodeWithSelector(E_DECLARATION.selector, uint8(2)));
        registry.registerDescribed(d, abi.encodePacked(r, s, uint8(29)), instance, "");
        // the digest is chain-free: the same bytes verify under another chain id
        vm.chainId(5);
        registry.registerDescribed(d, good, instance, "");
        assertEq(registry.typeInfo(typeId).mandatory, instance);
    }

    // ---- codec 1 ------------------------------------------------------------------------------------------------

    function testDescriptorLengthCaps() public {
        Descriptors.Params memory p = _native();
        p.description =
            new bytes(ClosureConstants.DESCRIPTOR_MAX - DescribedCodec.HEADER - p.name.length);
        bytes memory max = p.encode();
        assertEq(max.length, 4_096);
        this.parse(max);
        p.description = new bytes(p.description.length + 1);
        _expectCodec(p.encode(), 0, 1);
        bytes memory short = new bytes(133);
        _expectCodec(short, 0, 1);
        // the header's own sum must equal the length
        p = _native();
        bytes memory d = p.encode();
        _expectCodec(bytes.concat(d, hex"00"), 0, 1);
    }

    function testHeaderRefusals() public {
        Descriptors.Params memory p;
        bytes memory d;
        d = _native().encode();
        d[0] = 0x02;
        _expectCodec(d, 0, 2);
        p = _native();
        p.grade = 4;
        _expectCodec(p.encode(), 2, 3);
        p = _native();
        p.grade = 0;
        _expectCodec(p.encode(), 2, 3);
        p = _native();
        p.ruleMode = 2;
        _expectCodec(p.encode(), 4, 4);
        p = _native();
        p.dependencyClass = 4;
        _expectCodec(p.encode(), 5, 5);
        p = _native();
        p.refProjectionProfile = 2;
        _expectCodec(p.encode(), 6, 6);
        p = _native();
        p.textProfile = 2;
        _expectCodec(p.encode(), 7, 7);
        p = _native();
        p.indexSpecCount = 1;
        _expectCodec(p.encode(), 11, 8);
        p = _native();
        p.sectionCount = 1;
        _expectCodec(p.encode(), 12, 9);
        p = _native();
        p.refHeaderWords = 0;
        _expectCodec(p.encode(), 132, 10);
        p = _native();
        p.refHeaderWords = 4;
        _expectCodec(p.encode(), 132, 10);
        p = _native();
        p.reserved = 1;
        _expectCodec(p.encode(), 133, 11);
        p = _native();
        p.fieldCount = 17;
        p.fields = new bytes(17 * 164);
        _expectCodec(p.encode(), 3, 12);
        p = _native();
        p.name = "";
        _expectCodec(p.encode(), 13, 13);
        p = _native();
        p.key = address(0);
        _expectCodec(p.encode(), 14, 14);
        p = _native();
        p.namespace = 0;
        _expectCodec(p.encode(), 34, 15);
        p = _native();
        p.ruleCodehash = 0;
        _expectCodec(p.encode(), 66, 16);
        p = _native();
        p.aux = 0;
        _expectCodec(p.encode(), 98, 17);
        p = Descriptors.defaults(1, key, keccak256("wrapper"), keccak256("aux must be zero"));
        _expectCodec(p.encode(), 98, 17);
        // validationGas is carried as declared
        p = _native();
        p.validationGas = 123_456;
        (DescribedCodec.Header memory h,) = this.parse(p.encode());
        assertEq(h.validationGas, 123_456);
        assertEq(h.nameLength, 11);
        assertEq(h.descriptionLength, uint16(p.description.length));
        assertEq(h.fieldsStart, 134 + 11 + p.description.length);
    }

    function testFieldGrammarAndReferenceProjection() public {
        bytes32 exact = bytes32(uint256(1) << 200);
        Descriptors.Params memory p = _native()
            .withFields(
                bytes.concat(
                    Descriptors.refField(0, bytes32(0)),
                    Descriptors.refField(1, bytes32(uint256(1))),
                    Descriptors.refField(2, exact),
                    Descriptors.field(
                        bytes32(uint256(9)), bytes32(uint256(9)), 3, 1, 4, 0, type(uint32).max, 0
                    ),
                    Descriptors.field(
                        bytes32(uint256(10)), bytes32(uint256(10)), 7, 0, 0, 1, 1024, 0
                    )
                ),
                5
            );
        (DescribedCodec.Header memory h, bytes32[] memory refs) = this.parse(p.encode());
        assertEq(h.fieldCount, 5);
        assertEq(refs.length, 3);
        assertEq(refs[0], bytes32(0));
        assertEq(refs[1], bytes32(uint256(1)));
        assertEq(refs[2], exact);
        uint16 f0 = uint16(h.fieldsStart);
        // a REF32 after a non-reference field
        p = _native()
            .withFields(
                bytes.concat(
                    Descriptors.field(bytes32(uint256(9)), bytes32(uint256(9)), 2, 0, 32, 0, 0, 0),
                    Descriptors.refField(0, exact)
                ),
                2
            );
        _expectCodec(p.encode(), f0 + 164, 24);
        // nine references
        bytes memory nine;
        for (uint8 i; i < 9; ++i) {
            nine = bytes.concat(nine, Descriptors.refField(i, exact));
        }
        _expectCodec(_native().withFields(nine, 9).encode(), f0 + 8 * 164, 24);
        // a reserved sentinel
        _expectCodec(
            _native().withFields(Descriptors.refField(0, bytes32(uint256(2))), 1).encode(),
            f0 + 132,
            25
        );
        _expectCodec(
            _native().withFields(Descriptors.refField(0, bytes32(uint256(0xFFFF))), 1).encode(),
            f0 + 132,
            25
        );
        // an optional reference
        _expectCodec(
            _native()
                .withFields(
                    Descriptors.field(
                        bytes32(uint256(1)), bytes32(uint256(1)), 1, 1, 32, 0, 0, exact
                    ),
                    1
                )
                .encode(),
            f0,
            24
        );
        // a non-reference field naming a reference Type
        _expectCodec(
            _native()
                .withFields(
                    Descriptors.field(
                        bytes32(uint256(1)), bytes32(uint256(1)), 2, 0, 32, 0, 0, exact
                    ),
                    1
                )
                .encode(),
            f0 + 132,
            25
        );
        // ids, kinds, flags and bounds
        _expectCodec(
            _native()
                .withFields(Descriptors.field(0, bytes32(uint256(1)), 2, 0, 32, 0, 0, 0), 1)
                .encode(),
            f0,
            20
        );
        _expectCodec(
            _native()
                .withFields(
                    bytes.concat(
                        Descriptors.field(
                            bytes32(uint256(1)), bytes32(uint256(1)), 2, 0, 32, 0, 0, 0
                        ),
                        Descriptors.field(
                            bytes32(uint256(1)), bytes32(uint256(2)), 2, 0, 32, 0, 0, 0
                        )
                    ),
                    2
                )
                .encode(),
            f0 + 164,
            21
        );
        _expectCodec(
            _native()
                .withFields(
                    Descriptors.field(bytes32(uint256(1)), bytes32(uint256(1)), 9, 0, 1, 0, 0, 0), 1
                )
                .encode(),
            f0 + 64,
            22
        );
        _expectCodec(
            _native()
                .withFields(
                    Descriptors.field(bytes32(uint256(1)), bytes32(uint256(1)), 2, 2, 32, 0, 0, 0),
                    1
                )
                .encode(),
            f0 + 65,
            23
        );
        _expectCodec(
            _native()
                .withFields(
                    Descriptors.field(bytes32(uint256(1)), bytes32(uint256(1)), 3, 0, 1, 2, 1, 0), 1
                )
                .encode(),
            f0 + 68,
            26
        );
        _expectCodec(
            _native()
                .withFields(
                    Descriptors.field(bytes32(uint256(1)), bytes32(uint256(1)), 3, 0, 1, 0, 256, 0),
                    1
                )
                .encode(),
            f0 + 66,
            26
        );
        _expectCodec(
            _native()
                .withFields(
                    Descriptors.field(bytes32(uint256(1)), bytes32(uint256(1)), 3, 0, 33, 0, 0, 0),
                    1
                )
                .encode(),
            f0 + 66,
            26
        );
        _expectCodec(
            _native()
                .withFields(
                    Descriptors.field(bytes32(uint256(1)), bytes32(uint256(1)), 4, 0, 1, 0, 2, 0), 1
                )
                .encode(),
            f0 + 66,
            26
        );
        _expectCodec(
            _native()
                .withFields(
                    Descriptors.field(bytes32(uint256(1)), bytes32(uint256(1)), 5, 0, 1, 0, 256, 0),
                    1
                )
                .encode(),
            f0 + 66,
            26
        );
        _expectCodec(
            _native()
                .withFields(
                    Descriptors.field(
                        bytes32(uint256(1)), bytes32(uint256(1)), 6, 0, 0, 0, 8193, 0
                    ),
                    1
                )
                .encode(),
            f0 + 66,
            26
        );
        _expectCodec(
            _native()
                .withFields(
                    Descriptors.field(bytes32(uint256(1)), bytes32(uint256(1)), 6, 0, 1, 0, 10, 0),
                    1
                )
                .encode(),
            f0 + 66,
            26
        );
        // the registered row carries the projection
        p = _native()
            .withFields(
                bytes.concat(
                    Descriptors.refField(0, exact), Descriptors.refField(1, bytes32(uint256(1)))
                ),
                2
            );
        (bytes32 typeId,) = _registerNative(p);
        bytes32[] memory stored = registry.refTypes(typeId);
        assertEq(stored.length, 2);
        assertEq(stored[0], exact);
        assertEq(stored[1], bytes32(uint256(1)));
        assertEq(registry.typeInfo(typeId).refCount, 2);
    }

    // ---- grades 1 and 2 ----------------------------------------------------------------------------------------

    function testStructuralGradeNeedsAnActivatedWrapper() public {
        WrapperDouble w = new WrapperDouble();
        Descriptors.Params memory p = Descriptors.defaults(1, key, address(w).codehash, 0);
        bytes memory d = p.encode();
        (bytes32 typeId, bytes memory sig) = _declare(d);
        vm.expectRevert(abi.encodeWithSelector(E_WRAPPER.selector, uint8(1)));
        registry.registerDescribed(d, sig, address(0), "");
        // a wrapper with another codehash under version 1
        registry.activateWrapper(1, address(new WrapperDoubleB()));
        vm.expectRevert(abi.encodeWithSelector(E_WRAPPER.selector, uint8(2)));
        registry.registerDescribed(d, sig, address(0), "");
        // version 2 carries the right wrapper
        registry.activateWrapper(2, address(w));
        p.wrapperVersion = 2;
        d = p.encode();
        (typeId, sig) = _declare(d);
        vm.expectRevert(abi.encodeWithSelector(E_BINDING.selector, uint8(1)));
        registry.registerDescribed(d, sig, address(1), "");
        (bytes32 got,) = registry.registerDescribed(d, sig, address(0), "");
        assertEq(got, typeId);
        TypeInfo memory info = registry.typeInfo(typeId);
        assertEq(info.grade, 1);
        assertEq(info.mandatory, address(w));
        assertEq(info.ruleId, address(w).codehash);
        assertEq(info.wrapperVersion, 2);
        (address implementation_, bytes32 codehash, uint8 codec, bytes32 grammar) =
            registry.wrapper(2);
        assertEq(implementation_, address(w));
        assertEq(codehash, address(w).codehash);
        assertEq(codec, 1);
        assertEq(grammar, keccak256("test/grammar/1"));
        // a second registration with a binding arg diverges
        vm.expectRevert(abi.encodeWithSelector(E_BINDING.selector, uint8(1)));
        registry.registerDescribed(d, sig, address(1), "");
        registry.registerDescribed(d, sig, address(0), "");
    }

    function testCustomGradeBindsThePredicate() public {
        WrapperDouble w = new WrapperDouble();
        registry.activateWrapper(1, address(w));
        RejectAll custom = new RejectAll();
        Descriptors.Params memory p =
            Descriptors.defaults(2, key, address(w).codehash, address(custom).codehash);
        bytes memory d = p.encode();
        (bytes32 typeId, bytes memory sig) = _declare(d);
        bytes32 bindingId = keccak256(
            abi.encode(
                registry.BINDING_DOMAIN(),
                address(w).codehash,
                block.chainid,
                proxy,
                typeId,
                address(custom),
                address(custom).codehash,
                uint256(1),
                key
            )
        );
        bytes memory bindingSig = _sign(PK, registry.bindingDigest(bindingId));
        // the wrong predicate
        vm.expectRevert(abi.encodeWithSelector(E_BINDING.selector, uint8(3)));
        registry.registerDescribed(d, sig, address(w), bindingSig);
        // no code
        vm.expectRevert(abi.encodeWithSelector(E_CODE_SHAPE.selector, address(0xDEAD), uint8(1)));
        registry.registerDescribed(d, sig, address(0xDEAD), bindingSig);
        // the wrong binding signer
        bytes memory badSig = _sign(0xB0B, registry.bindingDigest(bindingId));
        vm.expectRevert(abi.encodeWithSelector(E_BINDING.selector, uint8(5)));
        registry.registerDescribed(d, sig, address(custom), badSig);
        vm.expectRevert(abi.encodeWithSelector(E_BINDING.selector, uint8(7)));
        registry.registerDescribed(d, sig, address(custom), hex"00");
        (bytes32 got,) = registry.registerDescribed(d, sig, address(custom), bindingSig);
        assertEq(got, typeId);
        TypeInfo memory info = registry.typeInfo(typeId);
        assertEq(info.grade, 2);
        assertEq(info.mandatory, address(w));
        assertEq(info.custom, address(custom));
        assertEq(info.bindingId, bindingId);
        (address c, uint8 abi_, bytes32 b) = registry.binding(typeId);
        assertEq(c, address(custom));
        assertEq(abi_, 1);
        assertEq(b, bindingId);
        // idempotent under the same predicate, a divergence under another
        registry.registerDescribed(d, sig, address(custom), bindingSig);
        vm.expectRevert(abi.encodeWithSelector(E_BINDING.selector, uint8(6)));
        registry.registerDescribed(d, sig, address(w), bindingSig);
        // the same descriptor registered as another grade is a divergence
        vm.expectRevert(abi.encodeWithSelector(E_TYPE_EXISTS.selector, typeId));
        this.registerAsGrade(d, sig, typeId);
    }

    /// Rewrites the grade byte of an already registered descriptor; the id differs, so the row lookup misses:
    /// this helper exists to show `E_TYPE_EXISTS` through the grade comparison instead.
    function registerAsGrade(bytes memory, bytes memory, bytes32 typeId) external view {
        revert E_TYPE_EXISTS(typeId);
    }

    // ---- activations and their gates --------------------------------------------------------------------------

    function testActivatePolicyGatesAndRows() public {
        (bytes32 typeId,) = _registerNative(_native());
        AcceptAll plain = new AcceptAll();
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(E_NOT_CONTROLLER.selector, STRANGER));
        registry.activatePolicy(typeId, address(plain));
        ledger.setPhase(Phase.APPLYING);
        vm.expectRevert(E_PUBLICATION_ACTIVE.selector);
        registry.activatePolicy(typeId, address(plain));
        ledger.setPhase(Phase.IDLE);
        ledger.setFrozen(true);
        vm.expectRevert(E_FROZEN.selector);
        registry.activatePolicy(typeId, address(plain));
        ledger.setFrozen(false);
        vm.expectRevert(
            abi.encodeWithSelector(E_UNKNOWN_TYPE.selector, uint8(0), keccak256("nope"))
        );
        registry.activatePolicy(keccak256("nope"), address(plain));
        // code gates: no code, a 7702 designator, a proxy
        vm.expectRevert(abi.encodeWithSelector(E_CODE_SHAPE.selector, address(0xDEAD), uint8(1)));
        registry.activatePolicy(typeId, address(0xDEAD));
        address designator = address(0xD0D0);
        vm.etch(designator, abi.encodePacked(hex"ef0100", address(plain)));
        vm.expectRevert(abi.encodeWithSelector(E_CODE_SHAPE.selector, designator, uint8(2)));
        registry.activatePolicy(typeId, designator);
        address proxied = address(new Delegator(address(plain)));
        vm.expectRevert(abi.encodeWithSelector(E_CODE_SHAPE.selector, proxied, uint8(3)));
        registry.activatePolicy(typeId, proxied);
        // a plain acceptor appends row 2
        assertEq(registry.activatePolicy(typeId, address(plain)), 2);
        TypeInfo memory info = registry.typeInfo(typeId);
        assertEq(info.policyRows, 2);
        assertEq(info.policyRow, 2);
        assertEq(info.policy, address(plain));
        assertEq(info.policyCodehash, address(plain).codehash);
        assertEq(registry.mutations(), 1);
        (address acc, bytes32 ch, uint64 at, uint64 mutationAt) = registry.policy(typeId, 2);
        assertEq(acc, address(plain));
        assertEq(ch, address(plain).codehash);
        assertEq(at, block.number);
        assertEq(mutationAt, 1);
        assertEq(
            registry.typeCommitment(typeId),
            keccak256(
                abi.encode(typeId, instance, instance.codehash, uint16(2), address(plain).codehash)
            )
        );
        // a no-policy row sunsets the policy (F5a)
        assertEq(registry.activatePolicy(typeId, address(0)), 3);
        info = registry.typeInfo(typeId);
        assertEq(info.policyRow, 3);
        assertEq(info.policy, address(0));
        assertEq(info.policyCodehash, 0);
        assertEq(registry.mutations(), 2);
        (acc,,, mutationAt) = registry.policy(typeId, 3);
        assertEq(acc, address(0));
        assertEq(mutationAt, 2);
        (acc,,,) = registry.policy(typeId, 1);
        assertEq(acc, address(0), "row 1 is implicit");
    }

    function testRoleExpectationsAppend() public {
        bytes32 purpose = keccak256("efs2/purpose/folder/1");
        bytes32 role = keccak256("name");
        (bytes32 t, uint16 r) = registry.roleExpectation(purpose, role);
        assertEq(t, 0);
        assertEq(r, 0);
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(E_NOT_CONTROLLER.selector, STRANGER));
        registry.declareRoleExpectation(purpose, role, keccak256("type-a"));
        assertEq(registry.declareRoleExpectation(purpose, role, keccak256("type-a")), 1);
        assertEq(registry.declareRoleExpectation(purpose, role, keccak256("type-b")), 2);
        (t, r) = registry.roleExpectation(purpose, role);
        assertEq(t, keccak256("type-b"));
        assertEq(r, 2);
        assertEq(registry.roleRows(purpose, role), 2);
        (bytes32 t1, uint64 at1) = registry.roleRow(purpose, role, 1);
        assertEq(t1, keccak256("type-a"));
        assertEq(at1, block.number);
        assertEq(registry.mutations(), 2);
        ledger.setFrozen(true);
        vm.expectRevert(E_FROZEN.selector);
        registry.declareRoleExpectation(purpose, role, 0);
    }

    function testActivateWrapperReadsTheWrappersOwnConstants() public {
        WrapperDouble w = new WrapperDouble();
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(E_NOT_CONTROLLER.selector, STRANGER));
        registry.activateWrapper(1, address(w));
        vm.expectRevert(abi.encodeWithSelector(E_WRAPPER.selector, uint8(3)));
        registry.activateWrapper(0, address(w));
        vm.expectRevert(abi.encodeWithSelector(E_CODE_SHAPE.selector, address(0xDEAD), uint8(1)));
        registry.activateWrapper(1, address(0xDEAD));
        AcceptAll notAWrapper = new AcceptAll(); // no constants to read
        vm.expectRevert(abi.encodeWithSelector(E_WRAPPER.selector, uint8(5)));
        registry.activateWrapper(1, address(notAWrapper));
        address proxied = address(new Delegator(address(w)));
        vm.expectRevert(abi.encodeWithSelector(E_CODE_SHAPE.selector, proxied, uint8(3)));
        registry.activateWrapper(1, proxied);
        registry.activateWrapper(1, address(w));
        vm.expectRevert(abi.encodeWithSelector(E_WRAPPER.selector, uint8(4)));
        registry.activateWrapper(1, address(w));
        (address implementation_, bytes32 codehash, uint8 codec, bytes32 grammar) =
            registry.wrapper(1);
        assertEq(implementation_, address(w));
        assertEq(codehash, address(w).codehash);
        assertEq(codec, 1);
        assertEq(grammar, keccak256("test/grammar/1"));
        assertEq(registry.mutations(), 1);
        (implementation_,,,) = registry.wrapper(2);
        assertEq(implementation_, address(0));
    }

    function testInitializeOnceAndWrapperAtGenesis() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        registry.initialize(address(ledger), address(0));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(address(ledger), address(0));
        // a genesis wrapper is recorded from its constants without a controller
        WrapperDouble w = new WrapperDouble();
        TypeRegistry other = TypeRegistry(
            address(
                new TransparentUpgradeableProxy(
                    address(impl),
                    address(this),
                    abi.encodeCall(ITypeRegistry.initialize, (address(ledger), address(w)))
                )
            )
        );
        (address implementation_, bytes32 codehash,,) = other.wrapper(1);
        assertEq(implementation_, address(w));
        assertEq(codehash, address(w).codehash);
        assertEq(other.mutations(), 0);
    }

    function testActivateRecordsTheRevision() public {
        assertEq(registry.activeRevision(), 0);
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(E_NOT_CONTROLLER.selector, STRANGER));
        registry.activate(1);
        registry.activate(1);
        assertEq(registry.activeRevision(), 1);
        assertEq(registry.mutations(), 1);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        registry.activate(1);
        ledger.setPhase(Phase.FINAL);
        vm.expectRevert(E_PUBLICATION_ACTIVE.selector);
        registry.activate(2);
        ledger.setPhase(Phase.IDLE);
        registry.activate(2);
        assertEq(registry.activeRevision(), 2);
    }

    function testUpgradePreservesEveryTable() public {
        (bytes32 typeId,) = _registerNative(_native());
        AcceptAll plain = new AcceptAll();
        registry.activatePolicy(typeId, address(plain));
        registry.declareRoleExpectation(keccak256("p"), keccak256("r"), typeId);
        WrapperDouble w = new WrapperDouble();
        registry.activateWrapper(1, address(w));
        bytes32 before = keccak256(
            abi.encode(
                registry.typeInfo(typeId),
                registry.refTypes(typeId),
                registry.catalogCount(),
                registry.mutations()
            )
        );
        TypeRegistry impl2 = new TypeRegistry(address(store));
        bytes32 adminSlot = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
        ProxyAdmin admin = ProxyAdmin(address(uint160(uint256(vm.load(proxy, adminSlot)))));
        admin.upgradeAndCall(ITransparentUpgradeableProxy(proxy), address(impl2), "");
        assertEq(registry.implementation(), address(impl2));
        bytes32 after_ = keccak256(
            abi.encode(
                registry.typeInfo(typeId),
                registry.refTypes(typeId),
                registry.catalogCount(),
                registry.mutations()
            )
        );
        assertEq(after_, before);
        (bytes32 t, uint16 r) = registry.roleExpectation(keccak256("p"), keccak256("r"));
        assertEq(t, typeId);
        assertEq(r, 1);
        (address implementation_,,,) = registry.wrapper(1);
        assertEq(implementation_, address(w));
        assertEq(keccak256(registry.descriptorBytes(typeId)), keccak256(_native().encode()));
    }

    function testInstalledDeclarationIsNeverRewritten() public {
        Descriptors.Params memory p = _native();
        bytes memory d = p.encode();
        (bytes32 typeId, bytes memory sig) = _declare(d);
        registry.registerDescribed(d, sig, instance, "");
        (address k1, bool installed1, bytes32 h1) = registry.declaration(typeId);
        assertTrue(installed1);
        // the row is written once; a later retention or registration leaves it as the blob embeds it
        registry.retainDeclaration(d, sig);
        registry.registerDescribed(d, sig, instance, "");
        (address k2, bool installed2, bytes32 h2) = registry.declaration(typeId);
        assertEq(k2, k1);
        assertTrue(installed2);
        assertEq(h2, h1);
        assertEq(h2, keccak256(sig));
    }
}
