// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {TopicListsHistory} from "./TopicListsHistory.sol";
import {IGeneration1} from "../harness/IndexDeploy.sol";
import {IndexDeployer} from "../../src/control/IndexDeployer.sol";
import {IPostingStore} from "../../src/interfaces/IPostingStore.sol";
import {IBitmapStore} from "../../src/interfaces/IBitmapStore.sol";

/// @notice Rebuild equals live for the first-statement lists (design §10.6; docs/TAG-DESIGN.md §4): a mixed history
///         on the real Files Realm is folded live, then replayed through the repository's replay path (a fresh
///         generation with fresh stores from `IndexDeployer`, `replayNextPublication` through the pinned decoder),
///         and every list of families 5, 6, 7, 8, 10, 11, 16, 19, 20 and 21 is compared: head (count, live, last,
///         flags) and every entry. The index reads only write-once records, and the validator guarantees each tagged
///         topic predates its tag, so the replayed walk is the live walk. The history and the comparison are
///         `TopicListsHistory`'s (shared with `test/index/BuildWalk.t.sol`).
contract TopicListsReplayTest is TopicListsHistory {
    function _replayed() internal returns (IndexDeployer d, IGeneration1 ix) {
        (d, ix) = _generation(address(0), address(0));
        while (ix.replayNextPublication(64) != 0) {}
        (uint64 processed,,) = ix.progress();
        (uint64 admissions,,,) = r.hot.counts();
        assertEq(processed, admissions, "caught up");
    }

    function test_rebuild_equals_live_for_every_list() public {
        _mixedHistory();
        (IndexDeployer d,) = _replayed();
        IPostingStore live = IPostingStore(address(r.g.posting));
        (uint256 nonEmpty, uint256 entries) = _assertSameStores(
            live,
            IBitmapStore(address(r.g.bitmap)),
            IPostingStore(d.postingStore()),
            IBitmapStore(d.bitmapStore()),
            "replayed"
        );
        // the history exercised every new list (not a comparison of empty lists)
        _assertCountersMoved(live);
        assertGt(nonEmpty, 60, "many non-empty lists compared");
        assertGt(entries, 100, "many entries compared");
    }
}
