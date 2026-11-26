// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {Keys} from "../../src/lib/Keys.sol";

/// @notice Every `Keys` derivation against the golden vectors an independent implementation produced
///         (`tools/vectors.mjs`, viem), plus the EIP-7702 designator law of `principalFor`.
contract KeysTest is Test {
    string internal json;

    function setUp() public {
        json = vm.readFile("test/vectors/ids.json");
    }

    function b32(string memory path) internal view returns (bytes32) {
        return vm.parseJsonBytes32(json, path);
    }

    function addr(string memory path) internal view returns (address) {
        return vm.parseJsonAddress(json, path);
    }

    function testDomainTagsAreOneWayDoors() public view {
        assertEq(Keys.DOM_RECORD, b32(".domains.record"));
        assertEq(Keys.DOM_POSITION, b32(".domains.position"));
        assertEq(Keys.DOM_BINDING, b32(".domains.binding"));
        assertEq(Keys.DOM_SCOPE, b32(".domains.scope"));
        assertEq(Keys.DOM_POSTING, b32(".domains.posting"));
        assertEq(Keys.DOM_SUBJECT, b32(".domains.subject"));
        assertEq(Keys.DOM_PRINCIPAL, b32(".domains.principal"));
        assertEq(Keys.DOM_TYPE, b32(".domains.type"));
        assertEq(Keys.DOM_ROLE_SCOPE, b32(".domains.roleScope"));
        assertEq(Keys.DOM_SCOPE_BELOW, b32(".domains.scopeBelow"));
        assertEq(Keys.DOM_REALM_ORIGIN, b32(".domains.realmOrigin"));
        assertEq(Keys.DOM_REALM, b32(".domains.realm"));
        assertEq(Keys.DOM_PUBLICATION, b32(".domains.publication"));
        assertEq(Keys.DOM_NATIVE_INTENT, b32(".domains.nativeIntent"));
        assertEq(Keys.DOM_SIGNED_INTENT, b32(".domains.signedIntent"));
        assertEq(Keys.DOM_PROFILE, b32(".domains.profile"));
        assertEq(Keys.DOM_DESCRIBED_SHAPE, b32(".domains.describedShape"));
        assertEq(Keys.DOM_ROLE_KEY, b32(".domains.roleKey"));
        assertEq(Keys.DOM_EXECUTION_SET, b32(".domains.executionSet"));
        // The literal tags, so a change to the string shows up here and not only as a hash mismatch.
        assertEq(Keys.DOM_RECORD, keccak256("efs/record/1"));
        assertEq(Keys.DOM_SCOPE, keccak256("efs/vk/binding-scope/1"));
        assertEq(Keys.DOM_POSTING, keccak256("efs/pk/1"));
    }

    function testIdentityVectors() public view {
        address eoa = addr(".inputs.eoa");
        address contractAddress = addr(".inputs.contractAddress");
        bytes32 realmOrigin = b32(".inputs.realmOrigin");
        bytes32[] memory refTypes = vm.parseJsonBytes32Array(json, ".inputs.refTypes");
        bytes memory body = vm.parseJsonBytes(json, ".inputs.body");

        bytes32 eoaPrincipal = Keys.principal(eoa);
        assertEq(eoaPrincipal, b32(".outputs.eoaPrincipal"));
        assertEq(
            Keys.contractPrincipal(realmOrigin, contractAddress), b32(".outputs.contractPrincipal")
        );

        bytes32 typeId = Keys.typeId(b32(".inputs.shape"), refTypes, b32(".inputs.ruleId"));
        assertEq(typeId, b32(".outputs.typeId"));
        assertEq(
            Keys.typeId(b32(".inputs.shape"), new bytes32[](0), b32(".inputs.ruleId")),
            b32(".outputs.typeIdNoRefs")
        );

        bytes32 recordId = Keys.record(typeId, body);
        assertEq(recordId, b32(".outputs.recordId"));
        assertEq(
            Keys.recordFromHash(typeId, b32(".inputs.bodyHash")), b32(".outputs.recordFromHash")
        );
        assertEq(Keys.recordFromHash(typeId, keccak256(body)), recordId);

        bytes32 subjectId = Keys.subject(eoaPrincipal, b32(".inputs.salt"));
        assertEq(subjectId, b32(".outputs.subjectId"));
        bytes32 positionKey = Keys.position(b32(".inputs.purpose"), subjectId, b32(".inputs.role"));
        assertEq(positionKey, b32(".outputs.positionKey"));
        bytes32 bindingKey = Keys.binding(eoaPrincipal, positionKey);
        assertEq(bindingKey, b32(".outputs.bindingKey"));
        bytes32 scopeKey = Keys.scope(eoaPrincipal, b32(".inputs.purpose"), subjectId);
        assertEq(scopeKey, b32(".outputs.scopeKey"));

        uint8 ordinal = uint8(vm.parseJsonUint(json, ".inputs.ordinal"));
        uint8 spec = uint8(vm.parseJsonUint(json, ".inputs.spec"));
        uint8 scalarKind = uint8(vm.parseJsonUint(json, ".inputs.scalarKind"));
        assertEq(Keys.byTypeList(typeId), b32(".outputs.byTypeList"));
        assertEq(Keys.byAuthorList(eoaPrincipal), b32(".outputs.byAuthorList"));
        assertEq(Keys.backlinkList(b32(".inputs.purpose"), recordId), b32(".outputs.backlinkList"));
        assertEq(Keys.historyList(bindingKey), b32(".outputs.historyList"));
        assertEq(Keys.scopeList(scopeKey), b32(".outputs.scopeList"));
        assertEq(Keys.referenceList(typeId, ordinal, recordId), b32(".outputs.referenceList"));
        assertEq(Keys.byRecordList(recordId), b32(".outputs.byRecordList"));
        assertEq(Keys.uniqueByTypeList(typeId), b32(".outputs.uniqueByTypeList"));
        assertEq(
            Keys.scalarList(typeId, spec, scalarKind, b32(".inputs.value")),
            b32(".outputs.scalarList")
        );
        assertEq(
            Keys.digestList(b32(".inputs.algorithm"), b32(".inputs.value")),
            b32(".outputs.digestList")
        );
    }

    function testNewDerivationVectors() public view {
        address contractAddress = addr(".inputs.contractAddress");
        bytes32 eoaPrincipal = Keys.principal(addr(".inputs.eoa"));
        assertEq(
            Keys.roleScope(eoaPrincipal, b32(".inputs.purpose"), b32(".inputs.role")),
            b32(".outputs.roleScopeKey")
        );
        bytes32 origin = Keys.realmOrigin(11155111, contractAddress, b32(".inputs.salt"));
        assertEq(origin, b32(".outputs.realmOrigin"));
        assertEq(Keys.realmId(origin, 1), b32(".outputs.realmId"));
        assertEq(
            Keys.contractPrincipal(origin, contractAddress),
            b32(".outputs.contractPrincipalOfOrigin")
        );
        assertEq(
            Keys.publicationId(eoaPrincipal, b32(".inputs.bodyHash")), b32(".outputs.publicationId")
        );
        assertEq(Keys.roleKey(b32(".inputs.purpose"), b32(".inputs.role")), b32(".outputs.roleKey"));
    }

    /// The keys of the five first-statement lists (design §10.2 kinds 6, 7, 19, 20, 21).
    function testTagListKeyVectors() public view {
        bytes32 eoaPrincipal = Keys.principal(addr(".inputs.eoa"));
        bytes32 tag = b32(".inputs.tagPurpose");
        bytes32 ancestor = b32(".inputs.ancestor");
        bytes32 subjectId = Keys.subject(eoaPrincipal, b32(".inputs.salt"));
        bytes32 positionKey = Keys.position(b32(".inputs.purpose"), subjectId, b32(".inputs.role"));
        assertEq(Keys.scopeBelow(eoaPrincipal, tag, ancestor), b32(".outputs.scopeBelowKey"));
        assertEq(Keys.placeList(tag, subjectId), b32(".outputs.placeList"));
        assertEq(Keys.placeBelowList(tag, ancestor), b32(".outputs.placeBelowList"));
        assertEq(Keys.scopeBelowList(eoaPrincipal, tag, ancestor), b32(".outputs.scopeBelowList"));
        assertEq(Keys.positionAuthorsList(positionKey), b32(".outputs.positionAuthorsList"));
        assertEq(Keys.rolePlacesList(tag, b32(".inputs.role")), b32(".outputs.rolePlacesList"));
        assertEq(this.shapeOf(vm.parseJsonBytes(json, ".inputs.body")), b32(".outputs.shape"));
    }

    function shapeOf(bytes calldata d) external pure returns (bytes32) {
        return Keys.shape(d);
    }

    function testFamilyIds() public view {
        string[19] memory names = [
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
            "live-scope",
            "place",
            "place-below",
            "scope-below",
            "position-authors",
            "role-places",
            "head-authors"
        ];
        for (uint256 i; i < names.length; ++i) {
            assertEq(Keys.familyId(names[i]), b32(string.concat(".families.", names[i])), names[i]);
            assertEq(
                Keys.familyId(names[i]), keccak256(abi.encodePacked("efs/family/", names[i], "/1"))
            );
        }
    }

    /// Posting kinds 2, 3 and 9 are reserved: no list helper mints them.
    function testPostingKindsAreDistinctAndReservedOnesUnused() public pure {
        uint8[16] memory kinds = [
            Keys.KIND_BY_TYPE,
            Keys.KIND_BY_AUTHOR,
            Keys.KIND_BACKLINK,
            Keys.KIND_HISTORY,
            Keys.KIND_SCOPE,
            Keys.KIND_REFERENCE_POSITION,
            Keys.KIND_BY_RECORD,
            Keys.KIND_UNIQUE_BY_TYPE,
            Keys.KIND_SCALAR,
            Keys.KIND_DIGEST,
            Keys.KIND_PLACE,
            Keys.KIND_PLACE_BELOW,
            Keys.KIND_SCOPE_BELOW,
            Keys.KIND_POSITION_AUTHORS,
            Keys.KIND_ROLE_PLACES,
            Keys.KIND_HEAD_AUTHORS
        ];
        uint256 seen;
        for (uint256 i; i < kinds.length; ++i) {
            assertEq(seen & (1 << kinds[i]), 0, "duplicate kind");
            seen |= 1 << kinds[i];
        }
        assertEq(
            seen,
            (1 << 1) | (1 << 4) | (1 << 5) | (1 << 8) | (1 << 10) | (1 << 11) | (1 << 12)
                | (1 << 13) | (1 << 14) | (1 << 15) | (1 << 6) | (1 << 7) | (1 << 19) | (1 << 20)
                | (1 << 21) | (1 << 22)
        );
    }

    /// `principalFor`: a code-less account and an exact EIP-7702 designator are key principals (the
    /// padded address); every other code shape is a contract principal qualified by the Realm.
    function testPrincipalForDesignatorLaw() public {
        bytes32 realmOrigin = keccak256("test/realm-origin");
        address account = address(0xBEEF);
        bytes32 asKey = bytes32(uint256(uint160(account)));
        bytes32 asContract = Keys.contractPrincipal(realmOrigin, account);

        assertEq(Keys.principalFor(account, realmOrigin), asKey, "code-less account");

        vm.etch(account, abi.encodePacked(hex"ef0100", address(0xCAFE)));
        assertEq(account.code.length, 23);
        assertEq(Keys.principalFor(account, realmOrigin), asKey, "exact 7702 designator");

        // Code starting with 0xEF other than the exact designator cannot exist on chain (EIP-3541) and
        // the EVM refuses to etch it, so the only 23-byte shape that matters is ordinary code.
        bytes memory ordinary23 = new bytes(23);
        for (uint256 i; i < 23; ++i) {
            ordinary23[i] = 0x5b; // JUMPDEST
        }
        vm.etch(account, ordinary23);
        assertEq(account.code.length, 23);
        assertEq(Keys.principalFor(account, realmOrigin), asContract, "23 bytes of ordinary code");

        vm.etch(account, hex"6000");
        assertEq(Keys.principalFor(account, realmOrigin), asContract, "ordinary code");

        // The derivation never depends on which Realm reads it for keys, and always does for contracts.
        assertEq(
            Keys.principalFor(address(0xD00D), keccak256("other")),
            bytes32(uint256(uint160(address(0xD00D))))
        );
        assertTrue(
            Keys.contractPrincipal(keccak256("a"), account)
                != Keys.contractPrincipal(keccak256("b"), account)
        );
    }

    function testFuzzRecordDerivationsAgree(bytes32 typeId, bytes memory body) public pure {
        assertEq(Keys.record(typeId, body), Keys.recordFromHash(typeId, keccak256(body)));
    }

    /// Record ids (`Keys.record`, domain `efs/record/1`) and subject ids (`Keys.subject`, domain `efs/subject/1`)
    /// are keccak outputs of three-word preimages whose first word is a different domain tag, so no id is both a
    /// record and a subject short of a keccak collision. That is what makes the Files routing rule sound: a folder
    /// is a `files-directory/1` record, a file is a created subject, and the kind of a target is a property of its
    /// id ("a directory record of this profile's Type, else a created subject, else absent").
    function testRecordAndSubjectIdsAreSeparateDomains() public pure {
        assertEq(Keys.DOM_RECORD, keccak256("efs/record/1"));
        assertEq(Keys.DOM_SUBJECT, keccak256("efs/subject/1"));
        assertTrue(Keys.DOM_RECORD != Keys.DOM_SUBJECT);
        // the same two trailing words under the two domains: different preimages, different ids
        bytes32 x = keccak256("creator");
        bytes32 y = keccak256("salt");
        assertTrue(Keys.recordFromHash(x, y) != Keys.subject(x, y));
        assertEq(Keys.recordFromHash(x, y), keccak256(abi.encode(Keys.DOM_RECORD, x, y)));
        assertEq(Keys.subject(x, y), keccak256(abi.encode(Keys.DOM_SUBJECT, x, y)));
    }

    function testFuzzRecordAndSubjectIdsNeverCoincide(bytes32 a, bytes32 b, bytes32 c, bytes32 d)
        public
        pure
    {
        assertTrue(Keys.recordFromHash(a, b) != Keys.subject(a, b));
        assertTrue(Keys.recordFromHash(a, b) != Keys.subject(c, d));
        // a folder record (creator, salt) is never the subject the same creator mints with the same salt
        bytes32 dirType = keccak256("test/files/directory-type");
        assertTrue(Keys.record(dirType, abi.encode(a, b)) != Keys.subject(a, b));
    }
}
