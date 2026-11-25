// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {TopicReadersBase} from "../readers/TopicReadersBase.sol";
import {EfsTopics} from "../../src/lib/EfsTopics.sol";
import {EfsFiles} from "../../src/lib/EfsFiles.sol";
import {Action, Purpose} from "../../src/interfaces/Actions.sol";
import {Status} from "../../src/interfaces/Results.sol";
import {
    AuthorRow,
    ITopicPageReader,
    MineRow,
    PlaceCount,
    PlaceRow,
    TopicPageInfo
} from "../../src/interfaces/Readers.sol";

/// @notice What each topic read costs a caller (docs/TAG-NUMBERS.md "Reads"): one cold `view` call per row (every
///         account it can touch is cooled), the call frame's gas (`vm.lastCallGas`, no intrinsic 21,000). Setups run
///         with gas metering paused. Rows log as `tr <view> <parameters>: <gas>`.
///
///         `mine` (exact plus below): lens sizes 1, 8, 32, 64; 50 things filed by the lens round-robin (thing i by
///         lens author i mod L, newest first-stated by the last author), at depth 1 (the place itself), 8 and 64
///         (filed under the path's deepest topic, read from its first word); pages of 10 and 50.
contract TopicReadMeasureTest is TopicReadersBase {
    uint256 internal constant THINGS = 50;

    function _log(string memory row, uint256 gas) internal {
        emit log_named_uint(string.concat("tr ", row), gas);
    }

    function _mineGas(bytes32[] memory lens, bytes32 place, uint32 limit)
        internal
        returns (uint256 g)
    {
        _cool();
        (TopicPageInfo memory info, MineRow[] memory rows) =
            pager.mine(lens, place, true, _unbound(), "", limit, 0);
        g = vm.lastCallGas().gasTotalUsed;
        assertEq(uint8(info.q.status), uint8(Status.PRESENT));
        assertEq(rows.length, limit, "a full page");
    }

    function _mineCase(uint256 lensSize, uint256 depth) internal {
        vm.pauseGasMetering();
        address[] memory a = _authorsN(string.concat("m", vm.toString(lensSize)), lensSize);
        bytes32[] memory t = _regPath(string.concat("d", vm.toString(lensSize)), depth);
        bytes32[] memory xs = _things(THINGS);
        for (uint256 i; i < THINGS; ++i) {
            _act(a[i % lensSize], EfsTopics.tag(t[depth - 1], xs[i], 0, 0));
        }
        vm.resumeGasMetering();
        bytes32[] memory lens = _lensOf(a);
        string memory k =
            string.concat("mine lens=", vm.toString(lensSize), " depth=", vm.toString(depth));
        _log(string.concat(k, " page=10"), _mineGas(lens, t[0], 10));
        _log(string.concat(k, " page=50"), _mineGas(lens, t[0], 50));
    }

    function test_mine_lens1_depth1() public {
        _mineCase(1, 1);
    }

    function test_mine_lens1_depth8() public {
        _mineCase(1, 8);
    }

    function test_mine_lens1_depth64() public {
        _mineCase(1, 64);
    }

    function test_mine_lens8_depth1() public {
        _mineCase(8, 1);
    }

    function test_mine_lens8_depth8() public {
        _mineCase(8, 8);
    }

    function test_mine_lens8_depth64() public {
        _mineCase(8, 64);
    }

    function test_mine_lens32_depth1() public {
        _mineCase(32, 1);
    }

    function test_mine_lens32_depth8() public {
        _mineCase(32, 8);
    }

    function test_mine_lens32_depth64() public {
        _mineCase(32, 64);
    }

    function test_mine_lens64_depth1() public {
        _mineCase(64, 1);
    }

    function test_mine_lens64_depth8() public {
        _mineCase(64, 8);
    }

    function test_mine_lens64_depth64() public {
        _mineCase(64, 64);
    }

    // ---- everyone, raw, about --------------------------------------------------------------------------------

    function _everyoneGas(bytes32 place, bool below, bytes32[] memory lens, bool raw, uint32 limit)
        internal
        returns (uint256 g)
    {
        _cool();
        (TopicPageInfo memory info, PlaceRow[] memory rows) = pager.everyone(
            ITopicPageReader.PlaceQuery(Purpose.TAG, place, below, raw, 0),
            lens,
            _unbound(),
            "",
            limit,
            0
        );
        g = vm.lastCallGas().gasTotalUsed;
        assertEq(uint8(info.q.status), uint8(Status.PRESENT));
        assertEq(rows.length, limit, "a full page");
    }

    /// 60 things filed at a one-word place (exact) and under its child (below) by one author; a lens of 8 authors
    /// none of whom said anything (every lens head is read), and raw.
    function test_everyone_and_raw() public {
        vm.pauseGasMetering();
        bytes32 top = _regPath("ev", 1)[0];
        bytes32 kid = _child(top, "kid", true);
        _tagMany(alice, top, _things(60));
        _tagMany(alice, kid, _things(60));
        address[] memory a = _authorsN("evlens", 8);
        vm.resumeGasMetering();
        bytes32[] memory lens = _lensOf(a);
        for (uint32 n = 10; n <= 50; n += 40) {
            string memory k = string.concat(" page=", vm.toString(n));
            _log(
                string.concat("everyone exact lens=8", k), _everyoneGas(kid, false, lens, false, n)
            );
            _log(string.concat("everyone below lens=8", k), _everyoneGas(top, true, lens, false, n));
            _log(string.concat("raw exact", k), _everyoneGas(kid, false, new bytes32[](0), true, n));
            _log(string.concat("raw below", k), _everyoneGas(top, true, new bytes32[](0), true, n));
        }
    }

    function test_about() public {
        vm.pauseGasMetering();
        bytes32 thing = things[0];
        for (uint256 i; i < 20; ++i) {
            bytes32 place = _regPath(string.concat("ab", vm.toString(i)), 1)[0];
            _tag(alice, place, thing);
        }
        vm.resumeGasMetering();
        for (uint16 n = 10; n <= 20; n += 10) {
            _cool();
            (TopicPageInfo memory info, PlaceRow[] memory rows) =
                lookup.about(thing, 0, _unbound(), "", n);
            _log(string.concat("about page=", vm.toString(n)), vm.lastCallGas().gasTotalUsed);
            assertEq(uint8(info.q.status), uint8(Status.PRESENT));
            assertEq(rows.length, n);
        }
        _cool();
        lookup.about(thing, 4, _unbound(), "", 10);
        _log("about page=10 sample=4", vm.lastCallGas().gasTotalUsed);
    }

    // ---- byName, counts ---------------------------------------------------------------------------------------

    function test_by_name_and_counts() public {
        vm.pauseGasMetering();
        bytes32 home = bytes32(uint256(uint160(_homeOwner())));
        address[] memory a = _authorsN("bn", 300);
        for (uint256 i; i < 300; ++i) {
            _attach(a[i], home, "pet.jpg");
        }
        bytes32[] memory t = _regPath("cnt", 1);
        _tagMany(alice, t[0], _things(2_000));
        vm.resumeGasMetering();
        bytes32 pos = EfsFiles.folderPosition(home, "pet.jpg");
        for (uint16 n = 10; n <= 50; n += 40) {
            _cool();
            (TopicPageInfo memory info, AuthorRow[] memory rows) =
                lookup.byName(pos, _unbound(), "", n);
            _log(
                string.concat("byName 300 authors page=", vm.toString(n)),
                vm.lastCallGas().gasTotalUsed
            );
            assertEq(uint8(info.q.status), uint8(Status.PRESENT));
            assertEq(rows.length, n);
        }
        _cool();
        lookup.placeCount(Purpose.TAG, t[0], false, _unbound());
        _log("placeCount 2000 positions", vm.lastCallGas().gasTotalUsed);
        _cool();
        lookup.authorCount(pos, _unbound());
        _log("authorCount 300 authors", vm.lastCallGas().gasTotalUsed);
        _cool();
        lookup.entryCount(_pid(alice), Purpose.TAG, t[0], false, _unbound());
        _log("entryCount exact 2000 entries", vm.lastCallGas().gasTotalUsed);
    }

    function _homeOwner() internal returns (address) {
        return makeAddr("measure/home-owner");
    }

    // ---- word pages, children ---------------------------------------------------------------------------------

    function _wordCase(uint256 places) internal {
        vm.pauseGasMetering();
        string memory w = string.concat("wp", vm.toString(places));
        bytes32 page = EfsTopics.wordPageId(typeIds[T_TOPIC_WORD], bytes(w));
        (Action[] memory a, bytes[] memory b,) = EfsTopics.registerWord(_topicTypes(), bytes(w));
        _execAs(address(this), a, b);
        _tag(alice, page, things[0]);
        for (uint256 i = 1; i < places; ++i) {
            bytes32 parent = _regPath(string.concat(w, "-p", vm.toString(i)), 1)[0];
            bytes32 place = _child(parent, bytes(w), false);
            _tag(alice, place, things[0]);
        }
        vm.resumeGasMetering();
        _cool();
        (TopicPageInfo memory info, PlaceCount[] memory rows) =
            lookup.wordPage(page, _unbound(), "", 0);
        _log(string.concat("wordPage places=", vm.toString(places)), vm.lastCallGas().gasTotalUsed);
        assertEq(uint8(info.q.status), uint8(Status.PRESENT));
        assertEq(rows.length, places, "one page");
    }

    function test_word_page_1() public {
        _wordCase(1);
    }

    function test_word_page_5() public {
        _wordCase(5);
    }

    function test_word_page_20() public {
        _wordCase(20);
    }

    function test_children_16() public {
        vm.pauseGasMetering();
        bytes32 parent = _regPath("kids", 1)[0];
        for (uint256 i; i < 16; ++i) {
            bytes32 c = _child(parent, bytes(string.concat("kid", vm.toString(i))), true);
            _tag(alice, c, things[0]);
        }
        vm.resumeGasMetering();
        _cool();
        (TopicPageInfo memory info, PlaceCount[] memory rows) =
            lookup.children(parent, _unbound(), "", 0);
        _log("children 16", vm.lastCallGas().gasTotalUsed);
        assertEq(uint8(info.q.status), uint8(Status.PRESENT));
        assertEq(rows.length, 16);
        _cool();
        (info, rows) = lookup.children(parent, _unbound(), "", 1);
        _log("children page=1", vm.lastCallGas().gasTotalUsed);
    }
}
