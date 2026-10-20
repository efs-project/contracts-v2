// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Script} from "forge-std/Script.sol";
import {Factory} from "../test/harness/doubles/Factory.sol";
import {FilesTypes} from "../src/profiles/FilesTypes.sol";
import {FilesRootRule} from "../src/profiles/FilesRootRule.sol";
import {FilesChildRule} from "../src/profiles/FilesChildRule.sol";
import {FilesDirectoryRule} from "../src/profiles/FilesDirectoryRule.sol";
import {FilesNameRule} from "../src/profiles/FilesNameRule.sol";
import {FilesBytesRule} from "../src/profiles/FilesBytesRule.sol";
import {FilesContentRule} from "../src/profiles/FilesContentRule.sol";
import {FilesExternalContentRule} from "../src/profiles/FilesExternalContentRule.sol";
import {DirectoryAliasRule} from "../src/profiles/DirectoryAliasRule.sol";
import {RealmNoticeRule} from "../src/profiles/RealmNoticeRule.sol";
import {RefuseAllPolicy} from "../src/profiles/RefuseAllPolicy.sol";
import {FilesFinalValidator} from "../src/profiles/FilesFinalValidator.sol";

/// @notice The Solidity side of the release's profile facts (design §8.2 G10–G12, §13): the nine NATIVE rule
///         instances at CREATE2(0x4e59…956C, salt 0, initcode), their `FilesTypes` descriptors and Type ids for a
///         declaration key, `RefuseAllPolicy` and `FilesFinalValidator` with its manifest identity. Simulation only
///         (never broadcast): `tools/release.mjs` runs `forge script script/Genesis.s.sol --sig "profile(address)"
///         <key> --json` and requires the JS twin in `tools/deploy-plan.mjs` to produce the same bytes and ids.
contract Genesis is Script {
    uint8 internal constant T_ROOT = 0;
    uint8 internal constant T_CHILD = 1;
    uint8 internal constant T_DIRECTORY = 2;
    uint8 internal constant T_NAME = 3;
    uint8 internal constant T_BYTES = 4;
    uint8 internal constant T_CONTENT = 5;
    uint8 internal constant T_EXTERNAL = 6;
    uint8 internal constant T_ALIAS = 7;
    uint8 internal constant T_NOTICE = 8;

    address[9] internal instances;
    bytes32[9] internal initcodeHashes;
    bytes[9] internal descriptors;
    bytes32[9] internal typeIds;

    function profile(address key)
        external
        returns (
            address[9] memory,
            bytes32[9] memory,
            bytes[9] memory,
            bytes32[9] memory,
            address refuseAll,
            address validator,
            bytes32 validatorIdentity
        )
    {
        _deploy(key, T_BYTES, type(FilesBytesRule).creationCode);
        _deploy(key, T_ROOT, type(FilesRootRule).creationCode);
        _deploy(key, T_DIRECTORY, type(FilesDirectoryRule).creationCode);
        _deploy(key, T_NAME, type(FilesNameRule).creationCode);
        _deploy(key, T_NOTICE, type(RealmNoticeRule).creationCode);
        _deploy(key, T_CONTENT, type(FilesContentRule).creationCode);
        _deploy(key, T_EXTERNAL, type(FilesExternalContentRule).creationCode);
        _deploy(
            key,
            T_CHILD,
            abi.encodePacked(type(FilesChildRule).creationCode, abi.encode(typeIds[T_ROOT]))
        );
        _deploy(
            key,
            T_ALIAS,
            abi.encodePacked(
                type(DirectoryAliasRule).creationCode, abi.encode(typeIds[T_DIRECTORY])
            )
        );
        refuseAll = Factory.deploy(type(RefuseAllPolicy).creationCode);
        validator = Factory.deploy(
            abi.encodePacked(
                type(FilesFinalValidator).creationCode,
                abi.encode(typeIds[T_NAME], typeIds[T_DIRECTORY])
            )
        );
        validatorIdentity = FilesFinalValidator(validator).identity();
        return
            (
                instances,
                initcodeHashes,
                descriptors,
                typeIds,
                refuseAll,
                validator,
                validatorIdentity
            );
    }

    function _deploy(address key, uint8 t, bytes memory initcode) internal {
        address instance = Factory.deploy(initcode);
        bytes32 h = keccak256(initcode);
        instances[t] = instance;
        initcodeHashes[t] = h;
        bytes memory d = _descriptor(t, key, instance, h);
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
        if (t == T_CONTENT) return FilesTypes.filesContent(key, instance, h, typeIds[T_BYTES]);
        if (t == T_EXTERNAL) return FilesTypes.filesExternal(key, instance, h, typeIds[T_BYTES]);
        if (t == T_ALIAS) return FilesTypes.directoryAlias(key, instance, h);
        return FilesTypes.realmNotice(key, instance, h);
    }
}
