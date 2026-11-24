// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @notice Builders for codec `efs2/described/1` descriptors (design §9.2) used by the registry suites.
library Descriptors {
    struct Params {
        uint8 wrapperVersion;
        uint8 grade;
        uint8 fieldCount;
        uint8 ruleMode;
        uint8 dependencyClass;
        uint8 refProjectionProfile;
        uint8 textProfile;
        uint24 validationGas;
        uint8 indexSpecCount;
        uint8 sectionCount;
        address key;
        bytes32 namespace;
        bytes32 ruleCodehash;
        bytes32 aux;
        uint8 refHeaderWords;
        uint8 reserved;
        bytes name;
        bytes description;
        bytes fields;
    }

    function defaults(uint8 grade, address key, bytes32 ruleCodehash, bytes32 aux)
        internal
        pure
        returns (Params memory p)
    {
        p.wrapperVersion = 1;
        p.grade = grade;
        p.ruleMode = 1;
        p.dependencyClass = 1;
        p.refProjectionProfile = 1;
        p.textProfile = 1;
        p.key = key;
        p.namespace = keccak256("test/namespace");
        p.ruleCodehash = ruleCodehash;
        p.aux = aux;
        p.refHeaderWords = 1;
        p.name = "test-type/1";
        p.description = "a type for the registry suite";
    }

    function encode(Params memory p) internal pure returns (bytes memory) {
        return bytes.concat(
            abi.encodePacked(
                uint8(1),
                p.wrapperVersion,
                p.grade,
                p.fieldCount,
                p.ruleMode,
                p.dependencyClass,
                p.refProjectionProfile,
                p.textProfile,
                p.validationGas,
                p.indexSpecCount,
                p.sectionCount,
                uint8(p.name.length),
                p.key,
                p.namespace,
                p.ruleCodehash,
                p.aux,
                uint16(p.description.length),
                p.refHeaderWords,
                p.reserved
            ),
            p.name,
            p.description,
            p.fields
        );
    }

    function field(
        bytes32 id,
        bytes32 semantic,
        uint8 kind,
        uint8 optional,
        uint16 width,
        uint256 lo,
        uint256 hi,
        bytes32 ref
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(id, semantic, kind, optional, width, lo, hi, ref);
    }

    function refField(uint8 n, bytes32 ref) internal pure returns (bytes memory) {
        return field(bytes32(uint256(0x100 + n)), bytes32(uint256(0x200 + n)), 1, 0, 32, 0, 0, ref);
    }

    function withFields(Params memory p, bytes memory fields, uint8 count)
        internal
        pure
        returns (Params memory)
    {
        p.fields = fields;
        p.fieldCount = count;
        return p;
    }
}
