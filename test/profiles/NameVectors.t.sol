// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Keys} from "../../src/lib/Keys.sol";
import {FilesName, FilesNameRule} from "../../src/profiles/FilesNameRule.sol";
import {Genesis} from "../../script/Genesis.s.sol";
import {FilesUnitBase} from "./FilesUnitBase.sol";

/// @notice `test/vectors/names.json` (`tools/name-vectors.mjs`, computed in JS from the NatSpec) against the contracts:
///         every name's verdict against `FilesName.valid` and `FilesNameRule` (accepted, or `E_FILES_REFUSED(2)`),
///         every role (`keccak256(name)`) and every admitted name's record id against `Keys`; and the release Type id
///         against `Genesis.profile`.
contract NameVectorsTest is FilesUnitBase {
    string internal json;
    FilesNameRule internal rule;

    function setUp() public override {
        super.setUp();
        json = vm.readFile("test/vectors/names.json");
        rule = new FilesNameRule();
    }

    function valid(bytes calldata d) external pure returns (bool) {
        return FilesName.valid(d);
    }

    function test_every_name_vector() public {
        // one parse per field: a parse per row costs the file's whole length in memory
        bytes[] memory names = vm.parseJsonBytesArray(json, ".flat.hex");
        bool[] memory verdicts = vm.parseJsonBoolArray(json, ".flat.valid");
        bytes32[] memory records = vm.parseJsonBytes32Array(json, ".flat.recordId");
        bytes32 nameType = vm.parseJsonBytes32(json, '.typeIds["files-name/3"]');
        assertEq(verdicts.length, names.length);
        assertGt(names.length, 500, "the whole file");
        uint256 k;
        uint256 refused;
        for (uint256 i; i < names.length; ++i) {
            bytes memory name = names[i];
            assertEq(this.valid(name), verdicts[i], string.concat("name vector ", vm.toString(i)));
            if (verdicts[i]) {
                _accepts(rule, _ctx(), name, _none(), _noHeaders());
                assertEq(records[k++], Keys.record(nameType, name), "record id");
            } else {
                _refuses(rule, _ctx(), name, _none(), _noHeaders(), 2);
                ++refused;
            }
        }
        assertEq(k, records.length, "one record id per admitted name");
        assertGt(refused, 0);
    }

    /// Each row's role is `keccak256(name)` (spot rows: the parse of every role is the same cost as the names).
    function test_roles() public view {
        uint256 n = vm.parseJsonBytesArray(json, ".flat.hex").length;
        for (uint256 i; i < n; i += 37) {
            string memory at = string.concat(".names[", vm.toString(i), "]");
            bytes memory name = vm.parseJsonBytes(json, string.concat(at, ".hex"));
            assertEq(vm.parseJsonBytes32(json, string.concat(at, ".role")), keccak256(name));
        }
    }

    /// The vectors' Type id is the release's (see `FilesMediaType.t.sol`); the amsterdam profile skips it.
    function test_name_vectors_name_the_release_type_id() public {
        if (
            keccak256(bytes(vm.envOr("FOUNDRY_PROFILE", string("default"))))
                == keccak256("amsterdam")
        ) {
            return;
        }
        address key = vm.parseJsonAddress(json, ".declarationKey");
        (,,, bytes32[13] memory typeIds,,,) = new Genesis().profile(key);
        assertEq(typeIds[3], vm.parseJsonBytes32(json, '.typeIds["files-name/3"]'));
    }
}
