// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Keys} from "../../../src/lib/Keys.sol";

/// @notice Real descriptors for the stand-in Types of the `MockRegistry` suites. The decoder proves a Type's
///         reference count from its descriptor (`IndexReplayDecoder._refCount`: the bytes must hash to the record's
///         Type id), so a suite that decodes a record needs a Type id some descriptor derives, as every Type id on a
///         real Realm is (`TypeRegistry._retain`: `Keys.typeId(Keys.shape(descriptor), refs, h.ruleCodehash)`).
///         `ok()` is a codec `efs/described/1` descriptor (`DescribedCodec.parse` accepts it): grade NATIVE, no
///         fields, so no references, as the suites' `TYPE_OK` always had. `OK_ID` is its id, written out so the
///         suites keep a `constant`; `MockRegistry.setDescriptor` refuses a descriptor that does not derive the id.
library StandInTypes {
    /// `typeIdOf(ok())`.
    bytes32 internal constant OK_ID =
        0xf40974a38288ddbf5d45f20b4bad4a37379f681922fd7132157c2796746301fa;
    bytes32 internal constant RULE_ID = keccak256("efs/test/stand-in/rule");
    bytes32 internal constant AUX = keccak256("efs/test/stand-in/initcode");

    /// The stand-in `test/type/ok`: header (134 bytes) and the name, no description, no fields.
    function ok() internal pure returns (bytes memory) {
        return descriptor("test/type/ok");
    }

    function descriptor(string memory name) internal pure returns (bytes memory) {
        bytes memory n = bytes(name);
        return bytes.concat(
            bytes8(0x0100030001010101), // codec 1, wrapper 0, NATIVE, 0 fields, STATICCALL, pure, refProfile 1, text 1
            bytes3(0), // validationGas 0
            bytes2(0), // indexSpecCount, sectionCount
            bytes1(uint8(n.length)),
            bytes20(address(0xEF5)), // declarationKey
            keccak256("efs/test/stand-in/namespace"),
            RULE_ID,
            AUX, // ruleInitcodeHash (NATIVE)
            bytes2(0), // descriptionLength
            bytes1(0x01), // refHeaderWords
            bytes1(0x00), // flags
            n
        );
    }

    /// The registry's derivation over memory bytes (`Keys.shape` takes calldata): the leading REF32 fields are
    /// none here, so the reference Types are the empty list.
    function typeIdOf(bytes memory d) internal pure returns (bytes32) {
        bytes32 rule;
        assembly ("memory-safe") {
            rule := mload(add(d, 98)) // bytes 66..98
        }
        return
            Keys.typeId(keccak256(abi.encode(Keys.DOM_DESCRIBED_SHAPE, d)), new bytes32[](0), rule);
    }
}
