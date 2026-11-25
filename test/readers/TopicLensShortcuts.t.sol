// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {TopicReadersBase} from "./TopicReadersBase.sol";
import {EfsTopics} from "../../src/lib/EfsTopics.sol";
import {EfsFiles} from "../../src/lib/EfsFiles.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {Action, BindingNumber, Purpose} from "../../src/interfaces/Actions.sol";
import {Head} from "../../src/interfaces/Views.sol";
import {MineRow, PlaceRow, TopicPageInfo} from "../../src/interfaces/Readers.sol";

/// @notice The viewed-place shortcuts of both topic views (an empty author list at the viewed position; in `mine`, a
///         lens author whose exact scope list at the place is all live) change no result: over a mixed fixture
///         (six authors, fourteen things, a four-topic tree, some viewed positions nobody stated anything at and one
///         author who never stated anything at the root place, yes, no, released and silent heads, with "not this"
///         at the viewed places by lens authors at every lens position), every page of every query equals a reference
///         computed here from the kernel's heads alone by the plain rule of design §11: iT = the first lens author
///         with any stance at the filed position, kV = the first lens author whose head at the viewed place is MASKED;
///         hidden when kV <= iT or iT says no.
contract TopicLensShortcutsTest is TopicReadersBase {
    uint256 internal constant AUTHORS = 6;
    uint256 internal constant PLACES = 4;
    uint256 internal constant THINGS = 14;

    address[AUTHORS] internal au;
    bytes32[PLACES] internal pl; // cars, cars/tesla, cars/ford, cars/tesla/model3
    uint256[PLACES] internal parent; // parent place index (type(uint256).max at the root)
    bytes32[] internal xs;

    // the kernel's heads, read once: author × place × thing
    uint8[THINGS][PLACES][AUTHORS] internal st;
    uint16[THINGS][PLACES][AUTHORS] internal sg;
    uint64[THINGS][PLACES][AUTHORS] internal ord;

    function setUp() public override {
        super.setUp();
        pl[0] = _regPath("eq", 1)[0];
        pl[1] = _child(pl[0], "tesla", true);
        pl[2] = _child(pl[0], "ford", true);
        pl[3] = _child(pl[1], "model3", true);
        parent[0] = type(uint256).max;
        parent[1] = 0;
        parent[2] = 0;
        parent[3] = 1;
        for (uint256 i; i < AUTHORS; ++i) {
            au[i] = makeAddr(string.concat("eq/author-", vm.toString(i)));
        }
        xs = _things(THINGS);
        // each (author, place, thing): 0..2 silent, 3..4 yes of that strength, 5 no, 6 yes then released
        for (uint256 i; i < AUTHORS; ++i) {
            for (uint256 k; k < PLACES; ++k) {
                Action[] memory a = new Action[](THINGS);
                Action[] memory rel = new Action[](THINGS);
                uint256 n;
                uint256 nr;
                for (uint256 j; j < THINGS; ++j) {
                    // the last author never states anything at /cars (its exact list there is empty: all live), and
                    // nobody states the last four things there (their viewed positions' author lists are empty)
                    if (k == 0 && (i == AUTHORS - 1 || j >= 10)) continue;
                    uint256 v = uint256(keccak256(abi.encode("eq/mix", i, k, j))) % 7;
                    if (v == 3 || v == 4 || v == 6) {
                        a[n++] = EfsTopics.tag(pl[k], xs[j], 0, uint16(v));
                    } else if (v == 5) {
                        a[n++] = EfsTopics.deny(pl[k], xs[j], 0, 1);
                    }
                    if (v == 6) rel[nr++] = EfsFiles.release(Purpose.TAG, pl[k], xs[j], 1);
                }
                if (n != 0) _execAs(au[i], _prefix(a, n), new bytes[](n));
                if (nr != 0) _execAs(au[i], _prefix(rel, nr), new bytes[](nr));
            }
        }
        // deterministic "not this" at the viewed places by authors at different lens positions
        _act(au[0], EfsTopics.deny(pl[0], xs[0], _rev(au[0], Purpose.TAG, pl[0], xs[0]), 0));
        _act(au[2], EfsTopics.deny(pl[0], xs[1], _rev(au[2], Purpose.TAG, pl[0], xs[1]), 0));
        _act(au[3], EfsTopics.deny(pl[1], xs[2], _rev(au[3], Purpose.TAG, pl[1], xs[2]), 0));
        _act(au[1], EfsTopics.tag(pl[3], xs[2], _rev(au[1], Purpose.TAG, pl[3], xs[2]), 2));
        _act(au[1], EfsTopics.tag(pl[1], xs[0], _rev(au[1], Purpose.TAG, pl[1], xs[0]), 1));
        _snapshotHeads();
    }

    function _prefix(Action[] memory a, uint256 n) internal pure returns (Action[] memory) {
        assembly ("memory-safe") {
            mstore(a, n)
        }
        return a;
    }

    function _snapshotHeads() internal {
        for (uint256 i; i < AUTHORS; ++i) {
            for (uint256 k; k < PLACES; ++k) {
                bytes32[] memory keys = new bytes32[](THINGS);
                for (uint256 j; j < THINGS; ++j) {
                    keys[j] = Keys.binding(_pid(au[i]), Keys.position(Purpose.TAG, pl[k], xs[j]));
                }
                (Head[] memory hs,) = views.heads(address(r.ledger), keys);
                for (uint256 j; j < THINGS; ++j) {
                    st[i][k][j] = hs[j].state;
                    sg[i][k][j] = hs[j].strength;
                    ord[i][k][j] = hs[j].bindingOrdinal;
                }
            }
        }
    }

    // ---- the plain rule ------------------------------------------------------------------------------------------

    /// True when `q` is a proper descendant of `p`.
    function _under(uint256 q, uint256 p) internal view returns (bool) {
        for (uint256 c = parent[q]; c != type(uint256).max; c = parent[c]) {
            if (c == p) return true;
        }
        return false;
    }

    /// iT at (k, j): the first lens index with a stance (255 none).
    function _iT(uint256[] memory lens, uint256 k, uint256 j) internal view returns (uint256) {
        for (uint256 a; a < lens.length; ++a) {
            uint8 s = st[lens[a]][k][j];
            if (s == 1 || s == 2) return a;
        }
        return 255;
    }

    /// kV at the viewed place p: the first of lens[0 .. upto] (inclusive) whose head at (p, j) is MASKED (255 none).
    function _kV(uint256[] memory lens, uint256 p, uint256 j, uint256 upto)
        internal
        view
        returns (uint256)
    {
        for (uint256 a; a < lens.length && a <= upto; ++a) {
            if (st[lens[a]][p][j] == 2) return a;
        }
        return 255;
    }

    struct Want {
        bool shown;
        uint256 topic;
        uint256 decider;
        int32 number;
        uint64 ordinal;
    }

    /// The reference `mine` rows: per thing, the newest (by the decider's binding ordinal) filing the lens shows.
    function _wantMine(uint256[] memory lens, uint256 p, bool below)
        internal
        view
        returns (Want[THINGS] memory w)
    {
        for (uint256 j; j < THINGS; ++j) {
            for (uint256 k; k < PLACES; ++k) {
                if (k != p && !(below && _under(k, p))) continue;
                uint256 iT = _iT(lens, k, j);
                if (iT == 255) continue;
                uint256 a = lens[iT];
                if (st[a][k][j] != 1) continue; // iT says no
                if (k != p && _kV(lens, p, j, iT) != 255) continue; // kV <= iT
                if (w[j].shown && w[j].ordinal > ord[a][k][j]) continue;
                (, int32 number) = BindingNumber.numberOf(1, sg[a][k][j]);
                w[j] = Want(true, k, iT, number, ord[a][k][j]);
            }
        }
    }

    /// Whether `everyone` shows the position (k, j) at the viewed place p, and its decider and number.
    function _everyoneShows(uint256[] memory lens, uint256 p, uint256 k, uint256 j)
        internal
        view
        returns (bool shown, uint256 decider, int32 number)
    {
        bool stated;
        bool yes;
        for (uint256 i; i < AUTHORS; ++i) {
            if (st[i][k][j] != 0) stated = true;
            if (st[i][k][j] == 1) yes = true;
        }
        if (!stated || !yes) return (false, 255, 0); // not listed, or nobody says yes
        uint256 iT = _iT(lens, k, j);
        if (iT != 255 && st[lens[iT]][k][j] == 2) return (false, 255, 0);
        if (k != p && _kV(lens, p, j, iT == 255 ? lens.length : iT) != 255) {
            return (false, 255, 0);
        }
        if (iT != 255) (, number) = BindingNumber.numberOf(1, sg[lens[iT]][k][j]);
        return (true, iT, number);
    }

    // ---- the equivalence --------------------------------------------------------------------------------------

    function _lensIx(uint256 a0, uint256 a1, uint256 a2, uint256 a3, uint256 a4, uint256 n)
        internal
        pure
        returns (uint256[] memory l)
    {
        uint256[5] memory x = [a0, a1, a2, a3, a4];
        l = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            l[i] = x[i];
        }
    }

    function _pids(uint256[] memory lens) internal view returns (bytes32[] memory l) {
        l = new bytes32[](lens.length);
        for (uint256 i; i < lens.length; ++i) {
            l[i] = _pid(au[lens[i]]);
        }
    }

    function _thingIndex(bytes32 thing) internal view returns (uint256) {
        for (uint256 j; j < THINGS; ++j) {
            if (xs[j] == thing) return j;
        }
        revert("not a fixture thing");
    }

    function test_every_query_equals_the_plain_rule() public view {
        uint256[][] memory lenses = new uint256[][](9);
        lenses[0] = _lensIx(0, 1, 2, 3, 0, 4);
        lenses[1] = _lensIx(3, 2, 1, 0, 0, 4);
        lenses[2] = _lensIx(1, 0, 0, 0, 0, 1);
        lenses[3] = _lensIx(2, 4, 0, 0, 0, 3);
        lenses[4] = _lensIx(4, 3, 1, 2, 0, 5);
        lenses[5] = _lensIx(0, 2, 0, 0, 0, 2);
        lenses[6] = _lensIx(3, 0, 0, 0, 0, 1);
        lenses[7] = _lensIx(5, 0, 1, 2, 3, 5); // the quiet author first
        lenses[8] = _lensIx(0, 1, 2, 3, 5, 5); // and last
        uint256 rowsSeen;
        uint256 hiddenByViewed;
        for (uint256 l; l < lenses.length; ++l) {
            for (uint256 p; p < PLACES; ++p) {
                for (uint256 b; b < 2; ++b) {
                    rowsSeen += _checkMine(lenses[l], p, b == 1);
                    rowsSeen += _checkEveryone(lenses[l], p, b == 1);
                    if (b == 1) hiddenByViewed += _viewedHides(lenses[l], p);
                }
            }
        }
        assertGt(rowsSeen, 150, "the fixture exercises the views");
        assertGt(hiddenByViewed, 10, "the viewed-place check decides rows");
    }

    function _checkMine(uint256[] memory lens, uint256 p, bool below)
        internal
        view
        returns (uint256)
    {
        (TopicPageInfo memory info, MineRow[] memory rows) =
            miner.mine(_pids(lens), pl[p], below, _unbound(), "", 0, 0, 0);
        _ok(info);
        assertEq(info.scanStatus, SCAN_EXHAUSTED);
        Want[THINGS] memory w = _wantMine(lens, p, below);
        uint256 want;
        for (uint256 j; j < THINGS; ++j) {
            if (w[j].shown) ++want;
        }
        assertEq(rows.length, want, "mine: exactly the things the plain rule shows");
        for (uint256 i; i < rows.length; ++i) {
            uint256 j = _thingIndex(rows[i].thing);
            assertTrue(w[j].shown, "mine: a row the plain rule hides");
            assertEq(rows[i].topic, pl[w[j].topic], "mine: through the newest shown filing");
            assertEq(rows[i].decider, w[j].decider, "mine: the decider");
            assertEq(rows[i].number, w[j].number, "mine: the number");
            assertEq(rows[i].bindingOrdinal, w[j].ordinal, "mine: the decider's own entry");
        }
        return rows.length;
    }

    function _checkEveryone(uint256[] memory lens, uint256 p, bool below)
        internal
        view
        returns (uint256)
    {
        (TopicPageInfo memory info, PlaceRow[] memory rows) =
            _everyone(pl[p], below, _pids(lens), false, 0, "", 0);
        _ok(info);
        assertEq(info.scanStatus, SCAN_EXHAUSTED);
        uint256 want;
        for (uint256 j; j < THINGS; ++j) {
            for (uint256 k; k < PLACES; ++k) {
                if (k != p && !(below && _under(k, p))) continue;
                (bool s,,) = _everyoneShows(lens, p, k, j);
                if (s) {
                    ++want;
                    break;
                }
            }
        }
        assertEq(rows.length, want, "everyone: exactly the things the plain rule shows");
        for (uint256 i; i < rows.length; ++i) {
            uint256 j = _thingIndex(rows[i].thing);
            uint256 k = PLACES;
            for (uint256 q; q < PLACES; ++q) {
                if (rows[i].topic == pl[q]) k = q;
            }
            assertTrue(k == p || (below && k < PLACES && _under(k, p)), "everyone: a listed place");
            (bool s, uint256 d, int32 n) = _everyoneShows(lens, p, k, j);
            assertTrue(s, "everyone: a row the plain rule hides");
            assertEq(rows[i].decider, d, "everyone: the decider");
            assertEq(rows[i].number, n, "everyone: the number");
        }
        return rows.length;
    }

    /// Filings below `p` that the filed position alone would show and the viewed-place check hides (coverage).
    function _viewedHides(uint256[] memory lens, uint256 p) internal view returns (uint256 n) {
        for (uint256 j; j < THINGS; ++j) {
            for (uint256 k; k < PLACES; ++k) {
                if (!_under(k, p)) continue;
                uint256 iT = _iT(lens, k, j);
                if (iT != 255 && st[lens[iT]][k][j] == 1 && _kV(lens, p, j, iT) != 255) ++n;
            }
        }
    }
}
