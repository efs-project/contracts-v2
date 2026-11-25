// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {KernelDeploy} from "../harness/KernelDeploy.sol";
import {IndexDeploy} from "../harness/IndexDeploy.sol";
import {Factory} from "../harness/doubles/Factory.sol";
import {TypeRegistry} from "../../src/types/TypeRegistry.sol";
import {DescriptorStore} from "../../src/types/DescriptorStore.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {Purpose} from "../../src/interfaces/Actions.sol";
import {ILedger} from "../../src/interfaces/ILedger.sol";
import {ILedgerHot} from "../../src/interfaces/ILedgerHot.sol";
import {ILedgerControl} from "../../src/interfaces/ILedgerControl.sol";
import {ITypeRegistry} from "../../src/interfaces/ITypeRegistry.sol";
import {DigestSpec, Unit} from "../../src/interfaces/Index.sol";
import {FilesTypes} from "../../src/profiles/FilesTypes.sol";
import {FilesRootRule} from "../../src/profiles/FilesRootRule.sol";
import {FilesChildRule} from "../../src/profiles/FilesChildRule.sol";
import {FilesDirectoryRule} from "../../src/profiles/FilesDirectoryRule.sol";
import {FilesNameRule} from "../../src/profiles/FilesNameRule.sol";
import {FilesBytesRule} from "../../src/profiles/FilesBytesRule.sol";
import {FilesSpanRule} from "../../src/profiles/FilesSpanRule.sol";
import {FilesContentRule} from "../../src/profiles/FilesContentRule.sol";
import {FilesExternalContentRule} from "../../src/profiles/FilesExternalContentRule.sol";
import {DirectoryAliasRule} from "../../src/profiles/DirectoryAliasRule.sol";
import {RealmNoticeRule} from "../../src/profiles/RealmNoticeRule.sol";
import {RefuseAllPolicy} from "../../src/profiles/RefuseAllPolicy.sol";
import {FilesFinalValidator} from "../../src/profiles/FilesFinalValidator.sol";
import {TopicTypes} from "../../src/profiles/TopicTypes.sol";
import {TopicWordRule} from "../../src/profiles/TopicWordRule.sol";
import {TopicRule} from "../../src/profiles/TopicRule.sol";
import {TextRule} from "../../src/profiles/TextRule.sol";
import {EfsTopics} from "../../src/lib/EfsTopics.sol";

/// @notice The Files profile on a real Realm: the thirteen rule instances (the ten Files Types, then the Topics
///         Types `topic-word/1`, `topic/1`, `text/1`), `RefuseAllPolicy` and `FilesFinalValidator`
///         at their deterministic CREATE2(0x4e59…956C, salt 0, initcode) addresses (design §8.2 G10/G12), the
///         descriptors and Type ids from `FilesTypes` under one declaration key, and a Realm builder: kernel, real
///         registry proxy, real generation-1 index with the validator pinned as its one unit (`purposeFilter =
///         FOLDER`) and the two Files digest specs (word 5, sha256) in the manifest, then the genesis ceremony.
abstract contract FilesFixture is Test {
    /// The fixture principal's declaration key (a test key; the release names its own).
    uint256 internal constant DECLARATION_PK = 0xF11E5;
    uint8 internal constant SHA256 = 1;
    uint8 internal constant T_ROOT = 0;
    uint8 internal constant T_CHILD = 1;
    uint8 internal constant T_DIRECTORY = 2;
    uint8 internal constant T_NAME = 3;
    uint8 internal constant T_BYTES = 4;
    uint8 internal constant T_CONTENT = 5;
    uint8 internal constant T_EXTERNAL = 6;
    uint8 internal constant T_ALIAS = 7;
    uint8 internal constant T_NOTICE = 8;
    uint8 internal constant T_SPAN = 9;
    uint8 internal constant T_TOPIC_WORD = 10;
    uint8 internal constant T_TOPIC = 11;
    uint8 internal constant T_TEXT = 12;
    uint8 internal constant TYPE_COUNT = 13;

    struct Realm {
        KernelDeploy.Kernel k;
        IndexDeploy.Gen1 g;
        DescriptorStore store;
        TypeRegistry registryImpl;
        TypeRegistry registry;
        ILedger ledger;
        ILedgerHot hot;
        bytes32 principal;
    }

    address internal declarationKey;
    /// Rule instances by Type index (T_*), the descriptor bytes, initcode hashes and Type ids.
    address[13] internal instances;
    bytes[13] internal initcodes;
    bytes32[13] internal initcodeHashes;
    bytes[13] internal descriptors;
    bytes32[13] internal typeIds;
    address internal refuseAll;
    FilesFinalValidator internal validator;

    function _deployProfile() internal {
        declarationKey = vm.addr(DECLARATION_PK);
        // dependency order (FilesTypes): a rule whose constructor state names a sibling Type id is deployed after
        // that Type's id is derived (the ids are pinned by the initcode hash, design §9.3)
        _deploy(T_BYTES, type(FilesBytesRule).creationCode);
        _deploy(
            T_SPAN, abi.encodePacked(type(FilesSpanRule).creationCode, abi.encode(typeIds[T_BYTES]))
        );
        _deploy(
            T_CONTENT,
            abi.encodePacked(
                type(FilesContentRule).creationCode, abi.encode(typeIds[T_BYTES], typeIds[T_SPAN])
            )
        );
        _deploy(T_EXTERNAL, type(FilesExternalContentRule).creationCode);
        _deploy(
            T_ROOT,
            abi.encodePacked(
                type(FilesRootRule).creationCode,
                abi.encode(typeIds[T_CONTENT], typeIds[T_EXTERNAL])
            )
        );
        _deploy(
            T_CHILD,
            abi.encodePacked(
                type(FilesChildRule).creationCode,
                abi.encode(typeIds[T_ROOT], typeIds[T_CONTENT], typeIds[T_EXTERNAL])
            )
        );
        _deploy(T_DIRECTORY, type(FilesDirectoryRule).creationCode);
        _deploy(T_NAME, type(FilesNameRule).creationCode);
        _deploy(T_NOTICE, type(RealmNoticeRule).creationCode);
        _deploy(
            T_ALIAS,
            abi.encodePacked(
                type(DirectoryAliasRule).creationCode, abi.encode(typeIds[T_DIRECTORY])
            )
        );
        // the Topics Types (TopicTypes): the word Type first (the topic descriptor and rule name its id), then text
        _deploy(T_TOPIC_WORD, type(TopicWordRule).creationCode);
        _deploy(
            T_TOPIC,
            abi.encodePacked(type(TopicRule).creationCode, abi.encode(typeIds[T_TOPIC_WORD]))
        );
        _deploy(T_TEXT, type(TextRule).creationCode);
        refuseAll = Factory.deploy(type(RefuseAllPolicy).creationCode);
        validator = FilesFinalValidator(
            Factory.deploy(
                abi.encodePacked(
                    type(FilesFinalValidator).creationCode,
                    abi.encode(
                        typeIds[T_NAME],
                        typeIds[T_DIRECTORY],
                        typeIds[T_ROOT],
                        typeIds[T_CHILD],
                        typeIds[T_TOPIC],
                        typeIds[T_TOPIC_WORD]
                    )
                )
            )
        );
    }

    /// The Topics Type ids for the `EfsTopics` builders.
    function _topicTypes() internal view returns (EfsTopics.Types memory) {
        return EfsTopics.Types(typeIds[T_TOPIC_WORD], typeIds[T_TOPIC], typeIds[T_TEXT]);
    }

    function _deploy(uint8 t, bytes memory initcode) internal {
        address instance = Factory.deploy(initcode);
        bytes32 h = keccak256(initcode);
        instances[t] = instance;
        initcodes[t] = initcode;
        initcodeHashes[t] = h;
        bytes memory d = _descriptor(t, declarationKey, instance, h);
        descriptors[t] = d;
        typeIds[t] = FilesTypes.typeIdOf(d);
    }

    function _descriptor(uint8 t, address key, address instance, bytes32 h)
        internal
        view
        returns (bytes memory)
    {
        if (t == T_ROOT) return FilesTypes.filesRoot(key, instance, h);
        if (t == T_CHILD) return FilesTypes.filesChild(key, instance, h);
        if (t == T_DIRECTORY) return FilesTypes.filesDirectory(key, instance, h);
        if (t == T_NAME) return FilesTypes.filesName(key, instance, h);
        if (t == T_BYTES) return FilesTypes.filesBytes(key, instance, h);
        if (t == T_CONTENT) return FilesTypes.filesContent(key, instance, h);
        if (t == T_EXTERNAL) return FilesTypes.filesExternal(key, instance, h, typeIds[T_BYTES]);
        if (t == T_ALIAS) return FilesTypes.directoryAlias(key, instance, h);
        if (t == T_SPAN) return FilesTypes.filesSpan(key, instance, h);
        if (t == T_TOPIC_WORD) return TopicTypes.topicWord(key, instance, h);
        if (t == T_TOPIC) return TopicTypes.topic(key, instance, h, typeIds[T_TOPIC_WORD]);
        if (t == T_TEXT) return TopicTypes.text(key, instance, h);
        return FilesTypes.realmNotice(key, instance, h);
    }

    /// When set before `_realm`, the Realm's index pins no unit, so nothing judges its binds: the suites that show
    /// a reader still refusing state the validator would refuse at admission (a bad HEAD already on chain).
    bool internal withoutValidator;

    /// The manifest unit of design §10.7: no fold hook, the validator as the final hook, FOLDER only (none when
    /// `withoutValidator`).
    function _units() internal view returns (Unit[] memory units) {
        if (withoutValidator) return new Unit[](0);
        units = new Unit[](1);
        units[0] = Unit({
            foldHook: address(0),
            foldCodehash: 0,
            finalHook: address(validator),
            finalCodehash: address(validator).codehash,
            familyIds: new bytes32[](0),
            purposeFilter: Purpose.FOLDER,
            hotAbiId: KernelDeploy.HOT_ABI_ID,
            identity: validator.identity()
        });
    }

    /// The two gen-1 digest specs (design §8.2 G19): `files-content/1` and `files-external/1`, word 5, sha256.
    function _specs() internal view returns (DigestSpec[] memory specs) {
        specs = new DigestSpec[](2);
        specs[0] = DigestSpec({typeId: typeIds[T_CONTENT], wordIndex: 5, algorithm: SHA256});
        specs[1] = DigestSpec({typeId: typeIds[T_EXTERNAL], wordIndex: 5, algorithm: SHA256});
    }

    /// A Realm with the Files unit and specs at genesis; `address(this)` is its controller.
    function _realm(bytes32 realmSalt) internal returns (Realm memory r) {
        r.store = new DescriptorStore();
        r.registryImpl = new TypeRegistry(address(r.store));
        // the registry proxy names the ledger proxy before it exists: one creation for the registry proxy,
        // four kernel implementations, then the ledger proxy
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 5);
        r.registry = TypeRegistry(
            address(
                new TransparentUpgradeableProxy(
                    address(r.registryImpl),
                    address(this),
                    abi.encodeCall(ITypeRegistry.initialize, (predicted, address(0)))
                )
            )
        );
        r.k = KernelDeploy.deploy(address(this), address(r.registry), realmSalt);
        require(r.k.proxy == predicted, "ledger proxy prediction");
        r.ledger = ILedger(r.k.proxy);
        r.hot = ILedgerHot(r.k.proxy);
        r.g = IndexDeploy.deploy(r.k.proxy, KernelDeploy.HOT_ABI_ID, _units(), _specs());
        r.registry.activate(1);
        ILedgerControl(r.k.proxy)
            .activate(
                KernelDeploy.genesisSet(
                    r.k,
                    address(this),
                    address(r.registryImpl),
                    address(r.g.index),
                    r.g.index.manifestHash()
                )
            );
        r.principal = Keys.principalFor(address(this), r.hot.realmOrigin());
    }

    /// §8.2 G11 + G21: the thirteen blobs, then permissionless registration (by a stranger) of the thirteen Types.
    function _register(Realm memory r) internal {
        for (uint8 t; t < TYPE_COUNT; ++t) {
            bytes memory sig = _declare(r.registry, typeIds[t]);
            r.store.put(descriptors[t], sig);
            vm.prank(address(0xCAFE));
            (bytes32 got,) = r.registry.registerDescribed(descriptors[t], sig, instances[t], "");
            require(got == typeIds[t], "registered id");
        }
    }

    function _declare(TypeRegistry registry, bytes32 typeId) internal pure returns (bytes memory) {
        (uint8 v, bytes32 rr, bytes32 s) =
            vm.sign(DECLARATION_PK, registry.declarationDigest(typeId));
        return abi.encodePacked(rr, s, v);
    }
}
