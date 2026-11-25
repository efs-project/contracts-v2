// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {PostingStore} from "../../src/index/PostingStore.sol";
import {BitmapStore} from "../../src/index/BitmapStore.sol";
import {RealmIndex} from "../../src/index/RealmIndex.sol";
import {IndexReads} from "../../src/index/IndexReads.sol";
import {IRealmIndex} from "../../src/interfaces/IRealmIndex.sol";
import {IIndexReads} from "../../src/interfaces/IIndexReads.sol";
import {Effect} from "../../src/interfaces/Index.sol";

/// Everything a test calls on a generation-1 index: the two interfaces answered at its address (part of them by
/// its reads contract, through the fallback) and the generation's own getters.
interface IGeneration1 is IRealmIndex, IIndexReads {
    function decoder() external view returns (address);
    function replayFold(uint64 publication, Effect[] calldata effects, bytes32[] calldata refs)
        external
        returns (uint64);
    function PHYSICAL_PROFILE() external view returns (bytes32);
    function CALLBACK_PROFILE() external view returns (bytes32);
    function MANIFEST_HEADER() external view returns (bytes32);
    function READS() external view returns (address);
    function READS_CODEHASH() external view returns (bytes32);
}
import {Keys} from "../../src/lib/Keys.sol";
import {DigestSpec, Unit, WorkModel} from "../../src/interfaces/Index.sol";
import {IndexDoubleDefaults} from "./doubles/IndexDoubles.sol";

/// @notice Deploys a generation-1 index with its two stores for a ledger: the posting families of design
///         §10.2 in one `PostingStore`, the scope, roster and live-scope families in one `BitmapStore`,
///         the generation's `IndexReads` over them with the units and digest specs of the test's choice, and a
///         `RealmIndex` built from it.
library IndexDeploy {
    struct Gen1 {
        PostingStore posting;
        BitmapStore bitmap;
        IGeneration1 index;
        IndexReads reads;
    }

    function postingFamilies() internal pure returns (bytes32[] memory f) {
        f = new bytes32[](10);
        f[0] = Keys.familyId("by-type");
        f[1] = Keys.familyId("by-author");
        f[2] = Keys.familyId("backlink");
        f[3] = Keys.familyId("history");
        f[4] = Keys.familyId("reference-position");
        f[5] = Keys.familyId("by-record");
        f[6] = Keys.familyId("unique-by-type");
        f[7] = Keys.familyId("scalar");
        f[8] = Keys.familyId("digest");
        f[9] = Keys.familyId("role-scope");
    }

    function bitmapFamilies() internal pure returns (bytes32[] memory f) {
        f = new bytes32[](3);
        f[0] = Keys.familyId("scope");
        f[1] = Keys.familyId("roster");
        f[2] = Keys.familyId("live-scope");
    }

    function deploy(
        address ledger,
        bytes32 hotAbiId,
        Unit[] memory units,
        DigestSpec[] memory specs
    ) internal returns (Gen1 memory g) {
        g.posting = new PostingStore(ledger, address(0), postingFamilies());
        g.bitmap = new BitmapStore(ledger, address(0), bitmapFamilies());
        g.reads = new IndexReads(
            ledger,
            hotAbiId,
            address(g.posting),
            address(g.bitmap),
            units,
            specs,
            IndexDoubleDefaults.workModel()
        );
        g.index = IGeneration1(address(new RealmIndex(ledger, address(0), address(g.reads))));
    }

    function deploy(address ledger, bytes32 hotAbiId) internal returns (Gen1 memory g) {
        return deploy(ledger, hotAbiId, new Unit[](0), new DigestSpec[](0));
    }
}
