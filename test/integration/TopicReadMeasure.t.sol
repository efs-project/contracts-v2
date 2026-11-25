// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {TopicReadersBase} from "../readers/TopicReadersBase.sol";
import {EfsTopics} from "../../src/lib/EfsTopics.sol";
import {EfsFiles} from "../../src/lib/EfsFiles.sol";
import {Action, Purpose} from "../../src/interfaces/Actions.sol";
import {Status} from "../../src/interfaces/Results.sol";
import {
    AuthorRow,
    ITopicEveryoneReader,
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
            miner.mine(lens, place, true, _unbound(), "", limit, 0, 0);
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

    /// The worst case of the viewed-place check: the `mine` fixture at depth 8, where every row DOES read the heads
    /// at the viewed place. Before the filings, the last lens author says yes to every thing at the place itself
    /// (so the viewed position's author list is not empty) and every lens author says "not this" about one other
    /// thing there (so no lens author's exact scope list at the place is all live). Those entries are older than
    /// every filing, so a page of 50 reads only the 50 roll-up rows, and every row still shows: no lens author
    /// masks the row's own thing at the place. Rows log as `tr mine worst lens=L depth=8 page=P`.
    function _mineWorstCase(uint256 lensSize) internal {
        vm.pauseGasMetering();
        string memory k = string.concat("w", vm.toString(lensSize));
        address[] memory a = _authorsN(k, lensSize);
        bytes32[] memory t = _regPath(string.concat("dw", vm.toString(lensSize)), 8);
        bytes32[] memory xs = _things(THINGS);
        bytes32 decoy = _things(1)[0];
        for (uint256 i; i < lensSize; ++i) {
            _act(a[i], EfsTopics.deny(t[0], decoy, 0, 0));
        }
        Action[] memory yes = new Action[](THINGS);
        for (uint256 i; i < THINGS; ++i) {
            yes[i] = EfsTopics.tag(t[0], xs[i], 0, 0);
        }
        _execAs(a[lensSize - 1], yes, new bytes[](THINGS));
        for (uint256 i; i < THINGS; ++i) {
            _act(a[i % lensSize], EfsTopics.tag(t[7], xs[i], 0, 0));
        }
        vm.resumeGasMetering();
        bytes32[] memory lens = _lensOf(a);
        string memory key = string.concat("mine worst lens=", vm.toString(lensSize), " depth=8");
        _log(string.concat(key, " page=10"), _mineGas(lens, t[0], 10));
        _log(string.concat(key, " page=50"), _mineGas(lens, t[0], 50));
    }

    function test_mine_worst_lens1() public {
        _mineWorstCase(1);
    }

    function test_mine_worst_lens8() public {
        _mineWorstCase(8);
    }

    function test_mine_worst_lens32() public {
        _mineWorstCase(32);
    }

    function test_mine_worst_lens64() public {
        _mineWorstCase(64);
    }

    // ---- everyone, raw, about --------------------------------------------------------------------------------

    function _everyoneGas(bytes32 place, bool below, bytes32[] memory lens, bool raw, uint32 limit)
        internal
        returns (uint256 g)
    {
        _cool();
        (TopicPageInfo memory info, PlaceRow[] memory rows) = pager.everyone(
            ITopicEveryoneReader.PlaceQuery(Purpose.TAG, place, below, raw, 0),
            lens,
            _unbound(),
            "",
            limit,
            0,
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

    /// The worst case of `everyone` below: the same 60 things filed at the place and then under its child, so every
    /// row (a child filing, the newest) has a statement at the viewed place (the viewed position's author list is
    /// not empty) and every one of the 8 silent lens authors is asked there. Rows log as
    /// `tr everyone worst below lens=8 page=P`.
    function test_everyone_worst_below() public {
        vm.pauseGasMetering();
        bytes32 top = _regPath("evw", 1)[0];
        bytes32 kid = _child(top, "kid", true);
        bytes32[] memory xs = _things(60);
        _tagMany(alice, top, xs);
        _tagMany(alice, kid, xs);
        address[] memory a = _authorsN("evwlens", 8);
        vm.resumeGasMetering();
        bytes32[] memory lens = _lensOf(a);
        for (uint32 n = 10; n <= 50; n += 40) {
            _log(
                string.concat("everyone worst below lens=8 page=", vm.toString(n)),
                _everyoneGas(top, true, lens, false, n)
            );
        }
    }

    // ---- a padded stretch: entries nobody says yes to -----------------------------------------------------------

    /// A page that reads `limit` entries of which none is a row (`rows.length == 0`).
    function _skipGas(bytes32 place, bool below, bytes32[] memory lens, uint32 limit)
        internal
        returns (uint256 g)
    {
        _cool();
        (TopicPageInfo memory info, PlaceRow[] memory rows) = pager.everyone(
            ITopicEveryoneReader.PlaceQuery(Purpose.TAG, place, below, false, 0),
            lens,
            _unbound(),
            "",
            limit,
            0,
            0
        );
        g = vm.lastCallGas().gasTotalUsed;
        assertEq(uint8(info.q.status), uint8(Status.PRESENT));
        assertEq(info.scanned, limit, "every entry read");
        assertEq(rows.length, 0, "no row: every entry is skipped");
    }

    /// 60 lone negatives by one stranger at a place's child (the place list of the child, the roll-up of the
    /// place): `everyone` reads them all and shows nothing. A lens of L silent authors; the cost of one skipped
    /// entry is the page-60 minus page-20 difference over 40 entries.
    function _paddedCase(uint256 lensSize) internal {
        vm.pauseGasMetering();
        string memory k = string.concat("pad", vm.toString(lensSize));
        bytes32 top = _regPath(k, 1)[0];
        bytes32 kid = _child(top, "kid", true);
        bytes32[] memory xs = _things(60);
        address stranger = makeAddr(string.concat(k, "-stranger"));
        Action[] memory a = new Action[](60);
        for (uint256 i; i < 60; ++i) {
            a[i] = EfsTopics.deny(kid, xs[i], 0, 0);
        }
        _execAs(stranger, a, new bytes[](60));
        bytes32[] memory lens = _lensOf(_authorsN(string.concat(k, "-lens"), lensSize));
        vm.resumeGasMetering();
        string memory n = string.concat(" lens=", vm.toString(lensSize));
        uint256 e20 = _skipGas(kid, false, lens, 20);
        uint256 e60 = _skipGas(kid, false, lens, 60);
        _log(string.concat("skip exact", n, " page=60"), e60);
        _log(string.concat("skip exact", n, " per entry"), (e60 - e20) / 40);
        uint256 b20 = _skipGas(top, true, lens, 20);
        uint256 b60 = _skipGas(top, true, lens, 60);
        _log(string.concat("skip below", n, " page=60"), b60);
        _log(string.concat("skip below", n, " per entry"), (b60 - b20) / 40);
    }

    function test_padded_lens1() public {
        _paddedCase(1);
    }

    function test_padded_lens8() public {
        _paddedCase(8);
    }

    function test_padded_lens64() public {
        _paddedCase(64);
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
