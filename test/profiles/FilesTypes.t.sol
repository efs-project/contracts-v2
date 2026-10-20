// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {DescribedCodec} from "../../src/types/DescribedCodec.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {CodeScan} from "../../src/lib/CodeScan.sol";
import {FilesTypes} from "../../src/profiles/FilesTypes.sol";
import {FilesChildRule} from "../../src/profiles/FilesChildRule.sol";
import {Factory} from "../harness/doubles/Factory.sol";
import {FilesFixture} from "./FilesFixture.sol";

/// @notice The nine descriptors from `FilesTypes`: they parse under codec `efs2/described/1` exactly as the
///         registry parses them, their headers name the deterministic instances, their REF32 projections are the
///         ones design §12.1 lists, `typeIdOf` is the registry's derivation, and every instance is a plain runtime.
contract FilesTypesTest is FilesFixture {
    string[9] internal names = [
        "files-root/1",
        "files-child/1",
        "files-directory/1",
        "files-name/2",
        "files-bytes/1",
        "files-content/1",
        "files-external/1",
        "directory-alias/1",
        "realm-notice/1"
    ];
    uint8[9] internal refHeaderWords = [1, 2, 1, 1, 1, 3, 1, 1, 1];
    uint8[9] internal dependencyClass = [2, 1, 2, 1, 1, 1, 1, 2, 2];

    function setUp() public {
        _deployProfile();
    }

    function parse(bytes calldata d)
        external
        pure
        returns (DescribedCodec.Header memory h, bytes32[] memory refs, bytes memory name)
    {
        (h, refs) = DescribedCodec.parse(d);
        name = DescribedCodec.name(d, h);
    }

    function test_descriptors_parse_as_the_registry_parses_them() public view {
        for (uint8 t; t < 9; ++t) {
            bytes memory d = descriptors[t];
            (DescribedCodec.Header memory h, bytes32[] memory refs, bytes memory name) =
                this.parse(d);
            assertEq(string(name), names[t]);
            assertEq(h.grade, DescribedCodec.GRADE_NATIVE);
            assertEq(h.ruleMode, 1);
            assertEq(h.dependencyClass, dependencyClass[t]);
            assertEq(h.textProfile, 1);
            assertEq(h.validationGas, 0);
            assertEq(h.declarationKey, declarationKey);
            assertEq(h.namespace, keccak256("efs2/files/1"));
            assertEq(
                h.ruleCodehash, instances[t].codehash, "ruleCodehash names the instance's runtime"
            );
            assertEq(h.auxHash, initcodeHashes[t], "ruleInitcodeHash");
            assertEq(Factory.predict(initcodes[t]), instances[t], "CREATE2(factory, 0, initcode)");
            assertEq(h.refHeaderWords, refHeaderWords[t]);
            // the registry's derivation (TypeRegistry._retain) equals FilesTypes.typeIdOf
            assertEq(
                Keys.typeId(
                    keccak256(abi.encode(Keys.DOM_DESCRIBED_SHAPE, d)), refs, h.ruleCodehash
                ),
                typeIds[t]
            );
            bytes32[] memory projected = FilesTypes.refTypesOf(d);
            assertEq(projected.length, refs.length);
            for (uint256 i; i < refs.length; ++i) {
                assertEq(projected[i], refs[i]);
            }
            assertLe(d.length, 4096);
        }
    }

    function test_ref_projections_are_the_design_rows() public view {
        (, bytes32[] memory refs,) = this.parse(descriptors[T_CHILD]);
        assertEq(refs.length, 1);
        assertEq(refs[0], bytes32(0), "files-child/1 refs [0 = ANY]");
        (, refs,) = this.parse(descriptors[T_CONTENT]);
        assertEq(refs.length, 1);
        assertEq(refs[0], typeIds[T_BYTES], "files-content/1 refs [files-bytes/1]");
        (, refs,) = this.parse(descriptors[T_EXTERNAL]);
        assertEq(refs.length, 1);
        assertEq(refs[0], typeIds[T_BYTES], "files-external/1 refs [files-bytes/1]");
        uint8[6] memory none = [T_ROOT, T_DIRECTORY, T_NAME, T_BYTES, T_ALIAS, T_NOTICE];
        for (uint256 i; i < none.length; ++i) {
            (, refs,) = this.parse(descriptors[none[i]]);
            assertEq(refs.length, 0);
        }
    }

    function test_ids_are_distinct_and_commit_to_key_rule_and_constructor_state() public {
        for (uint256 i; i < 9; ++i) {
            for (uint256 j = i + 1; j < 9; ++j) {
                assertTrue(typeIds[i] != typeIds[j], "distinct Types");
            }
            assertGe(uint256(typeIds[i]), 1 << 16, "never a ref sentinel");
        }
        // another declaration key: every id changes
        address other = vm.addr(0xBEEF);
        for (uint8 t; t < 9; ++t) {
            bytes memory d = _descriptor(t, other, instances[t], initcodeHashes[t]);
            assertTrue(FilesTypes.typeIdOf(d) != typeIds[t], "the key is identity-bearing");
        }
        // the child rule pinned to another root Type: same runtime, another instance and another Type id
        bytes memory initcode = abi.encodePacked(
            type(FilesChildRule).creationCode, abi.encode(keccak256("another root"))
        );
        address instance = Factory.deploy(initcode);
        assertEq(instance.codehash, instances[T_CHILD].codehash);
        assertTrue(instance != instances[T_CHILD]);
        assertTrue(
            FilesTypes.typeIdOf(
                    FilesTypes.filesChild(declarationKey, instance, keccak256(initcode))
                ) != typeIds[T_CHILD]
        );
        assertEq(FilesChildRule(instances[T_CHILD]).rootTypeId(), typeIds[T_ROOT]);
        assertEq(validator.nameTypeId(), typeIds[T_NAME]);
        assertEq(validator.directoryTypeId(), typeIds[T_DIRECTORY]);
    }

    function test_every_profile_runtime_is_plain_and_sized() public {
        for (uint8 t; t < 9; ++t) {
            assertEq(CodeScan.scan(instances[t].code), 0, names[t]);
            emit log_named_uint(
                string.concat(names[t], " rule runtime bytes"), instances[t].code.length
            );
        }
        assertEq(CodeScan.scan(refuseAll.code), 0);
        assertEq(CodeScan.scan(address(validator).code), 0);
        emit log_named_uint("RefuseAllPolicy runtime bytes", refuseAll.code.length);
        emit log_named_uint("FilesFinalValidator runtime bytes", address(validator).code.length);
        for (uint8 t; t < 9; ++t) {
            emit log_named_uint(string.concat(names[t], " descriptor bytes"), descriptors[t].length);
            emit log_named_bytes32(string.concat(names[t], " type id (test key)"), typeIds[t]);
        }
    }
}
