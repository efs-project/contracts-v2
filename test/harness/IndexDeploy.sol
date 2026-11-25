// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {PostingStore} from "../../src/index/PostingStore.sol";
import {BitmapStore} from "../../src/index/BitmapStore.sol";
import {RealmIndex} from "../../src/index/RealmIndex.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {Purpose} from "../../src/interfaces/Actions.sol";
import {DigestSpec, OpenScopeConfig, Unit, WorkModel} from "../../src/interfaces/Index.sol";
import {IndexDoubleDefaults} from "./doubles/IndexDoubles.sol";

/// @notice Deploys a generation-1 index with its two stores for a ledger: the posting families of design
///         §10.2 in one `PostingStore`, the scope, roster and live-scope families in one `BitmapStore`,
///         and a `RealmIndex` over them with the units and digest specs of the test's choice.
library IndexDeploy {
    struct Gen1 {
        PostingStore posting;
        BitmapStore bitmap;
        RealmIndex index;
    }

    function postingFamilies() internal pure returns (bytes32[] memory f) {
        f = new bytes32[](15);
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
        // SPIKE (tags-index2): after the generation-1 families
        f[10] = Keys.familyId("open-scope");
        f[11] = Keys.familyId("open-scope-below");
        f[12] = Keys.familyId("scope-below");
        f[13] = Keys.familyId("position-authors");
        f[14] = Keys.familyId("role-places");
    }

    function bitmapFamilies() internal pure returns (bytes32[] memory f) {
        f = new bytes32[](3);
        f[0] = Keys.familyId("scope");
        f[1] = Keys.familyId("roster");
        f[2] = Keys.familyId("live-scope");
    }

    /// SPIKE (tags-index2): the harness default: the two all-authors levels (families 6 and 20) and role-places
    /// (family 21) for TAG and FOLDER, no topic Types (families 7 and 19 unmaintained).
    function defaultOpenScope() internal pure returns (OpenScopeConfig memory os) {
        os.allAuthors = new bytes32[](2);
        os.allAuthors[0] = Purpose.TAG;
        os.allAuthors[1] = Purpose.FOLDER;
        os.rolePlaces = 2;
    }

    /// SPIKE (tags integration): every topic list on, over the given word-page and path Types. `trustRegistered` is
    /// on: in a Files Realm `FilesFinalValidator` (code 7) admits a first tag only on a topic first admitted
    /// strictly before it, which is exactly the check the index would otherwise repeat.
    function fullOpenScope(bytes32 wordTypeId, bytes32 pathTypeId, bool trusted)
        internal
        pure
        returns (OpenScopeConfig memory os)
    {
        os = defaultOpenScope();
        os.wordTypeId = wordTypeId;
        os.pathTypeId = pathTypeId;
        os.scopeBelow = true;
        os.allBelow = true;
        os.trustRegistered = trusted;
    }

    function deploy(
        address ledger,
        bytes32 hotAbiId,
        Unit[] memory units,
        DigestSpec[] memory specs
    ) internal returns (Gen1 memory g) {
        return deploy(ledger, hotAbiId, units, specs, defaultOpenScope());
    }

    function deploy(
        address ledger,
        bytes32 hotAbiId,
        Unit[] memory units,
        DigestSpec[] memory specs,
        OpenScopeConfig memory os
    ) internal returns (Gen1 memory g) {
        g.posting = new PostingStore(ledger, address(0), postingFamilies());
        g.bitmap = new BitmapStore(ledger, address(0), bitmapFamilies());
        g.index =
            _generation(ledger, hotAbiId, address(g.posting), address(g.bitmap), units, specs, os);
    }

    /// SPIKE (tags-index2): an external factory call keeps the constructor's argument encoding (the config's
    /// nested dynamic array) out of the callers' frames, which via-IR otherwise inlines past the stack limit.
    function _generation(
        address ledger,
        bytes32 hotAbiId,
        address posting,
        address bitmap,
        Unit[] memory units,
        DigestSpec[] memory specs,
        OpenScopeConfig memory os
    ) private returns (RealmIndex) {
        return new GenerationFactory().make(ledger, hotAbiId, posting, bitmap, units, specs, os);
    }

    function deploy(address ledger, bytes32 hotAbiId) internal returns (Gen1 memory g) {
        return deploy(ledger, hotAbiId, new Unit[](0), new DigestSpec[](0));
    }
}

/// SPIKE (tags-index2): see `IndexDeploy._generation`.
contract GenerationFactory {
    function make(
        address ledger,
        bytes32 hotAbiId,
        address posting,
        address bitmap,
        Unit[] calldata units,
        DigestSpec[] calldata specs,
        OpenScopeConfig calldata os
    ) external returns (RealmIndex) {
        return new RealmIndex(
            ledger,
            hotAbiId,
            address(0),
            posting,
            bitmap,
            units,
            specs,
            IndexDoubleDefaults.workModel(),
            os
        );
    }
}
