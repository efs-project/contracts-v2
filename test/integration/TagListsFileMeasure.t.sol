// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {FilesRecipesBase} from "./FilesRecipesBase.sol";
import {EfsFiles} from "../../src/lib/EfsFiles.sol";
import {Action, Native} from "../../src/interfaces/Actions.sol";

/// @notice docs/TAG-NUMBERS.md table B: what the first-statement lists add to ordinary file work. A first FOLDER
///         statement appends a `position-authors` entry and, on a fresh position, a `place` entry; an edit (a HEAD
///         re-bind) writes neither. Cooled publications by this contract's principal (it has written before), native
///         lane, logging `tlb <row> exec|state|all`. This suite uses only APIs that step 3a already had, so the same
///         file measures the step-3a build for the comparison (docs/TAG-NUMBERS.md says how).
contract TagListsFileMeasureTest is FilesRecipesBase {
    address[] internal cold;

    function setUp() public override {
        super.setUp();
        for (uint256 i; i < 13; ++i) {
            cold.push(instances[i]);
        }
        cold.push(refuseAll);
        cold.push(address(validator));
        cold.push(address(r.k.ingress));
        cold.push(address(r.k.applyDelegate));
        cold.push(address(r.k.control));
        cold.push(address(r.k.implementation));
        cold.push(r.k.proxy);
        cold.push(address(r.g.posting));
        cold.push(address(r.g.bitmap));
        cold.push(address(r.g.index));
        cold.push(address(r.g.reads));
        cold.push(address(r.registryImpl));
        cold.push(address(r.registry));
        cold.push(address(r.store));
    }

    function _measure(string memory row, Action[] memory a, bytes[] memory b) internal {
        Native memory c = _ctx(a);
        for (uint256 i; i < cold.length; ++i) {
            vm.cool(cold[i]);
        }
        r.ledger.execute(a, b, c, "");
        Vm.Gas memory f = vm.lastFrameGas();
        uint256 state = f.gasStateUsed > 0 ? uint256(int256(f.gasStateUsed)) : 0;
        emit log_named_uint(string.concat("tlb ", row, " exec"), f.gasTotalUsed);
        if (state != 0) emit log_named_uint(string.concat("tlb ", row, " state"), state);
        emit log_named_uint(string.concat("tlb ", row, " all"), f.gasTotalUsed + state);
    }

    function _types() internal view returns (EfsFiles.Types memory t) {
        t = EfsFiles.Types({
            root: typeIds[T_ROOT],
            child: typeIds[T_CHILD],
            directory: typeIds[T_DIRECTORY],
            name: typeIds[T_NAME],
            bytes_: typeIds[T_BYTES],
            content: typeIds[T_CONTENT],
            external_: typeIds[T_EXTERNAL],
            alias_: typeIds[T_ALIAS],
            notice: typeIds[T_NOTICE],
            span: typeIds[T_SPAN]
        });
    }

    function test_B_create_file_and_edit() public {
        EfsFiles.Types memory t = _types();
        bytes32 home = bytes32(uint256(uint160(makeAddr("measure/home"))));
        // a folder that already has a file (the place exists), unmeasured
        (Action[] memory a, bytes[] memory b,,) =
            EfsFiles.createFile(t, p, rootDir, keccak256("b/0"), "first.txt", "first\n", true);
        _execAs(address(this), a, b);
        // 1. create a file in a folder that has files: CREATE, root, name, HEAD, FOLDER
        bytes32 file;
        bytes32 rootRec;
        (a, b, file, rootRec) = EfsFiles.createFile(
            t, p, rootDir, keccak256("b/1"), "readme.txt", "Meeting at 10:00.\n", true
        );
        _measure("B create file in a folder with files", a, b);
        // 2. edit: PUBLISH child + HEAD re-bind
        (a, b,) = EfsFiles.edit(t, file, rootRec, "Meeting at 11:00.\n", 1);
        _measure("B edit", a, b);
        // 3. the first file attached to a home (a place with no entries)
        (a, b,,) = EfsFiles.createFile(
            t, p, home, keccak256("b/2"), "notes.txt", "Meeting at 12:00.\n", true
        );
        _measure("B create file in an empty home", a, b);
        // 4. a second file attached to the same home (the place exists)
        (a, b,,) = EfsFiles.createFile(
            t, p, home, keccak256("b/3"), "later.txt", "Meeting at 13:00.\n", true
        );
        _measure("B create file in a home with files", a, b);
    }
}
