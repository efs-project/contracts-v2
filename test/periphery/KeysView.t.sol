// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {KeysView} from "../../src/periphery/KeysView.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {FamilyId, PostingKey, TypeId} from "../../src/interfaces/Actions.sol";
import {E_RESERVED} from "../../src/interfaces/Errors.sol";

/// @notice The standalone key view answers exactly as the `Keys` library (fuzzed), and knows the thirteen
///         generation-1 families by id.
contract KeysViewTest is Test {
    KeysView internal view_;

    function setUp() public {
        view_ = new KeysView();
    }

    function testFuzz_derivationsEqualKeys(bytes32 a, bytes32 b, bytes32 c, uint8 ordinal)
        public
        view
    {
        assertEq(view_.recordId(a, b), Keys.recordFromHash(a, b));
        assertEq(view_.subjectId(a, b), Keys.subject(a, b));
        assertEq(view_.positionKey(a, b, c), Keys.position(a, b, c));
        assertEq(view_.bindingKey(a, b), Keys.binding(a, b));
        assertEq(view_.scopeKey(a, b, c), Keys.scope(a, b, c));
        assertEq(view_.roleScopeKey(a, b, c), Keys.roleScope(a, b, c));
        bytes32[] memory refs = new bytes32[](2);
        refs[0] = b;
        refs[1] = c;
        assertEq(view_.typeIdOf(a, refs, c), Keys.typeId(a, refs, c));
        assertEq(
            PostingKey.unwrap(
                view_.postingKey(
                    FamilyId.wrap(Keys.familyId("by-type")), TypeId.wrap(a), ordinal, b
                )
            ),
            Keys.posting(a, 1, ordinal, b)
        );
    }

    function test_everyFamilyMapsToItsKind() public view {
        string[13] memory names = [
            "by-type",
            "by-author",
            "backlink",
            "history",
            "scope",
            "reference-position",
            "by-record",
            "unique-by-type",
            "scalar",
            "digest",
            "role-scope",
            "roster",
            "live-scope"
        ];
        uint8[13] memory kinds = [1, 4, 5, 8, 10, 11, 12, 13, 14, 15, 16, 17, 18];
        for (uint256 i; i < 13; ++i) {
            assertEq(
                PostingKey.unwrap(
                    view_.postingKey(FamilyId.wrap(Keys.familyId(names[i])), TypeId.wrap(0), 0, 0)
                ),
                Keys.posting(0, kinds[i], 0, 0),
                names[i]
            );
        }
    }

    function test_unknownFamilyRefused() public {
        bytes32 unknown = keccak256("no-such-family");
        vm.expectRevert(abi.encodeWithSelector(E_RESERVED.selector, uint8(20), uint256(unknown)));
        view_.postingKey(FamilyId.wrap(unknown), TypeId.wrap(0), 0, 0);
    }
}
