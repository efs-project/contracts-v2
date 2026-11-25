// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FilesRecipesBase} from "./FilesRecipesBase.sol";
import {IndexDeploy} from "../harness/IndexDeploy.sol";
import {KernelDeploy} from "../harness/KernelDeploy.sol";
import {IndexDoubleDefaults} from "../harness/doubles/IndexDoubles.sol";
import {IndexDeployer} from "../../src/control/IndexDeployer.sol";
import {IndexReplayDecoder} from "../../src/index/IndexReplayDecoder.sol";
import {PostingStore} from "../../src/index/PostingStore.sol";
import {BitmapStore} from "../../src/index/BitmapStore.sol";
import {RealmIndex} from "../../src/index/RealmIndex.sol";
import {OpenScopeReader} from "../../src/readers/OpenScopeReader.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {Action, ActionKind, PostingKey, Purpose, ScopeKey} from "../../src/interfaces/Actions.sol";
import {IPostingStore} from "../../src/interfaces/IPostingStore.sol";
import {IBitmapStore} from "../../src/interfaces/IBitmapStore.sol";

/// @notice SPIKE (tags integration): the topic lists on the INTEGRATED Files Realm — the real `topic-word/1` and
///         `topic/1` Types, `FilesFinalValidator` (code 7: a first tag stands on a topic first admitted strictly
///         before it, or on a home) and the index built with `trustRegistered` on (the harness default). Proves the
///         guarantee end to end (every admitted first tag has every roll-up entry), rebuild equals live over a mixed
///         history, that every statement is reachable from its thing (family 21 role-places -> family 20), and the
///         targeted-spam bound of `byName` on a FOLDER position at a home.
contract TopicListsIntegratedTest is FilesRecipesBase {
    OpenScopeReader internal reader;
    address internal alice = makeAddr("integrated/alice");
    address internal bob = makeAddr("integrated/bob");
    address internal carol = makeAddr("integrated/carol");
    bytes32[] internal things; // CREATE subjects of this contract

    function setUp() public override {
        super.setUp();
        reader = new OpenScopeReader();
        Action[] memory a = new Action[](12);
        for (uint256 i; i < 12; ++i) {
            a[i] = _create(keccak256(abi.encode("integrated/thing", i)));
            things.push(Keys.subject(p, a[i].salt));
        }
        _execAs(address(this), a, new bytes[](12));
    }

    // ---- helpers ----------------------------------------------------------------------------------------------

    function _pid(address who) internal view returns (bytes32) {
        return who == address(this) ? p : Keys.principal(who);
    }

    function _one(Action memory x) internal pure returns (Action[] memory a) {
        a = new Action[](1);
        a[0] = x;
    }

    function _tag(address who, bytes32 topic, bytes32 thing) internal {
        _execAs(who, _one(_bind(Purpose.TAG, topic, thing, thing, 0)), new bytes[](1));
    }

    function _deny(address who, bytes32 topic, bytes32 thing) internal {
        _execAs(
            who, _one(_bindKind(ActionKind.UNBIND, Purpose.TAG, topic, thing, 0, 0)), new bytes[](1)
        );
    }

    function _act(
        address who,
        uint8 kind,
        bytes32 topic,
        bytes32 thing,
        uint64 rev,
        uint16 strength
    ) internal {
        Action memory x = _bindKind(
            kind, Purpose.TAG, topic, thing, kind == ActionKind.BIND ? thing : bytes32(0), rev
        );
        x.salt = bytes32(uint256(strength));
        _execAs(who, _one(x), new bytes[](1));
    }

    function _words(string memory name, uint256 n) internal pure returns (bytes[] memory w) {
        w = new bytes[](n);
        for (uint256 i; i < n; ++i) {
            w[i] = bytes(string.concat(name, "-", vm.toString(i)));
        }
    }

    /// Registers the path `name-0/.../name-(n-1)` (pages first, then records) and returns every prefix's id.
    function _regPath(string memory name, uint256 n) internal returns (bytes32[] memory t) {
        bytes[] memory w = _words(name, n);
        (Action[] memory a, bytes[] memory b,) = _pathActions(w, true);
        for (uint256 from; from < a.length; from += 64) {
            uint256 m = a.length - from < 64 ? a.length - from : 64;
            Action[] memory x = new Action[](m);
            bytes[] memory y = new bytes[](m);
            for (uint256 i; i < m; ++i) {
                (x[i], y[i]) = (a[from + i], b[from + i]);
            }
            _execAs(address(this), x, y);
        }
        t = new bytes32[](n);
        t[0] = _wordId(w[0]);
        for (uint256 i = 1; i < n; ++i) {
            bytes[] memory prefix = new bytes[](i + 1);
            for (uint256 j; j <= i; ++j) {
                prefix[j] = w[j];
            }
            t[i] = _pathId(prefix);
        }
    }

    function _pk(uint8 kind, bytes32 value) internal pure returns (PostingKey) {
        return PostingKey.wrap(Keys.posting(0, kind, 0, value));
    }

    function _mineBelow(bytes32 principal, bytes32 ancestor) internal pure returns (PostingKey) {
        return _pk(19, Keys.scopeBelow(principal, Purpose.TAG, ancestor));
    }

    function _allBelow(bytes32 ancestor) internal pure returns (PostingKey) {
        return _pk(7, Keys.openScope(Purpose.TAG, ancestor));
    }

    function _rolePlaces(bytes32 purpose, bytes32 role) internal pure returns (PostingKey) {
        return _pk(21, Keys.rolePlaces(purpose, role));
    }

    function _authors(bytes32 position) internal pure returns (PostingKey) {
        return _pk(20, position);
    }

    function _count(PostingKey k_) internal view returns (uint64 n) {
        (n,,,) = r.g.posting.postingHead(k_);
    }

    function _last(PostingKey k_) internal view returns (uint64 x) {
        (,, x,) = r.g.posting.postingHead(k_);
    }

    function _ordinal(address who, bytes32 topic, bytes32 thing) internal view returns (uint64 o) {
        (,,,,, o,) = r.hot.head(Keys.binding(_pid(who), Keys.position(Purpose.TAG, topic, thing)));
    }

    // =============================================================================================
    // the guarantee: every admitted first tag has every roll-up entry
    // =============================================================================================

    /// For each n, three authors make first statements (asserts, lone negatives, a second author on an existing
    /// position, a batch with the registration first in the same publication) on the deepest topic; after each, every
    /// proper ancestor's per-author list ends with the statement's binding ordinal, and the all-authors list does
    /// exactly when the position was fresh.
    function test_every_admitted_first_tag_has_every_rollup_entry() public {
        uint256[5] memory ns = [uint256(1), 2, 3, 8, 64];
        address[3] memory who = [address(this), alice, bob];
        for (uint256 d; d < ns.length; ++d) {
            uint256 n = ns[d];
            bytes32[] memory t = _regPath(string.concat("guarantee-", vm.toString(n)), n);
            bytes32 topic = t[n - 1];
            for (uint256 j; j < 6; ++j) {
                address author = who[j % 3];
                bytes32 thing = things[j / 2]; // two authors per thing: the second meets an existing position
                bool fresh = _count(_authors(Keys.position(Purpose.TAG, topic, thing))) == 0;
                uint64[] memory allBefore = new uint64[](n);
                for (uint256 i; i + 1 < n; ++i) {
                    allBefore[i] = _count(_allBelow(t[i]));
                }
                if (j % 2 == 0) _tag(author, topic, thing);
                else _deny(author, topic, thing);
                uint64 o = _ordinal(author, topic, thing);
                assertGt(o, 0, "admitted");
                for (uint256 i; i + 1 < n; ++i) {
                    assertEq(_last(_mineBelow(_pid(author), t[i])), o, "per-author roll-up entry");
                    if (fresh) {
                        assertEq(_last(_allBelow(t[i])), o, "all-authors roll-up entry");
                        assertEq(_count(_allBelow(t[i])), allBefore[i] + 1);
                    } else {
                        assertEq(_count(_allBelow(t[i])), allBefore[i], "existing position: none");
                    }
                }
                assertEq(_count(_mineBelow(_pid(author), topic)), 0, "the topic itself is exact");
            }
        }
        // registrations first, then the tag, in ONE publication: a fresh 5-word path
        bytes[] memory w = _words("same-pub", 5);
        (Action[] memory reg, bytes[] memory rb, bytes32 leaf) = _pathActions(w, true);
        Action[] memory a = new Action[](reg.length + 1);
        bytes[] memory b = new bytes[](reg.length + 1);
        for (uint256 i; i < reg.length; ++i) {
            (a[i], b[i]) = (reg[i], rb[i]);
        }
        a[reg.length] = _bind(Purpose.TAG, leaf, things[9], things[9], 0);
        _execAs(address(this), a, b);
        uint64 o2 = _ordinal(address(this), leaf, things[9]);
        bytes32 cur = _wordId(w[0]);
        for (uint256 i = 1; i <= 4; ++i) {
            assertEq(_last(_mineBelow(p, cur)), o2, "same-publication registration: per-author");
            assertEq(_last(_allBelow(cur)), o2, "same-publication registration: all-authors");
            bytes[] memory prefix = new bytes[](i + 1);
            for (uint256 j; j <= i; ++j) {
                prefix[j] = w[j];
            }
            cur = _pathId(prefix);
        }
    }

    // =============================================================================================
    // every statement is reachable from its thing (family 21 -> family 20)
    // =============================================================================================

    function _aboutQ(bytes32 thing) internal pure returns (OpenScopeReader.EveryoneQuery memory q) {
        q.purpose = Purpose.TAG;
        q.topic = thing;
        q.count = 16;
        q.raw = true;
    }

    /// On `thing`: alice's lone negative on topic x, bob's assert on topic y, carol's lone negative on y. From the
    /// thing alone, `about` lists both positions and `byName` lists every author of each, whatever the sign.
    function _reachable(bytes32 thing, bytes32 x, bytes32 y, uint8 targetKind) internal {
        _deny(alice, x, thing);
        _tag(bob, y, thing);
        _deny(carol, y, thing);
        (,,, uint8 kind,,,) =
            r.hot.head(Keys.binding(_pid(bob), Keys.position(Purpose.TAG, y, thing)));
        assertEq(kind, targetKind, "the assert's target kind");
        (uint64 len,, OpenScopeReader.PlaceRow[] memory rows) =
            reader.about(address(r.ledger), _aboutQ(thing));
        assertEq(len, 2, "two positions about the thing");
        assertEq(rows.length, 2);
        // newest first: y (bob) then x (alice)
        assertEq(rows[0].topic, y);
        assertEq(rows[0].thing, thing);
        assertEq(rows[0].authors, 2);
        assertEq(rows[1].topic, x);
        assertEq(rows[1].authors, 1);
        assertEq(rows[1].number, -1, "alice's lone negative is visible");
        (, OpenScopeReader.AuthorRow[] memory ax) =
            reader.byName(address(r.ledger), rows[1].position, 0, 8);
        assertEq(ax.length, 1);
        assertEq(ax[0].principalId, _pid(alice));
        assertEq(ax[0].number, -1);
        (, OpenScopeReader.AuthorRow[] memory ay) =
            reader.byName(address(r.ledger), rows[0].position, 0, 8);
        assertEq(ay.length, 2);
        assertEq(ay[0].principalId, _pid(carol));
        assertEq(ay[0].number, -1);
        assertEq(ay[1].principalId, _pid(bob));
        assertEq(ay[1].number, 0);
    }

    function test_every_statement_is_reachable_from_its_thing() public {
        bytes32 x = _regPath("reach-x", 2)[1];
        bytes32 y = _regPath("reach-y", 1)[0];
        // a file subject (kind 2)
        _reachable(things[0], x, y, 2);
        // a directory record (kind 1): the Realm root directory
        _reachable(rootDir, x, y, 1);
        // a topic record (kind 1)
        bytes32 topicThing = _regPath("reach-thing", 2)[1];
        _reachable(topicThing, x, y, 1);
        // a revision record (kind 1)
        bytes32 file = Keys.subject(p, keccak256("integrated/revision-file"));
        Action[] memory a = new Action[](2);
        bytes[] memory b = new bytes[](2);
        a[0] = _create(keccak256("integrated/revision-file"));
        (a[1], b[1]) = _publish(T_ROOT, bytes.concat(abi.encode(file, uint256(0)), "v1"));
        _execAs(address(this), a, b);
        _reachable(_id(T_ROOT, b[1]), x, y, 1);
        // an address with no history (kind 3)
        _reachable(bytes32(uint256(uint160(makeAddr("integrated/never-transacted")))), x, y, 3);
        // the backlink list of a thing never shows a lone negative (no target): the gap this family closes
        (uint64 bl,) = _posting(F_BACKLINK, 0, things[0]);
        assertEq(bl, 1, "backlinks: bob's assert only");
    }

    function test_role_places_remove_and_add_back_appends_nothing() public {
        bytes32 x = _regPath("rp-law", 1)[0];
        bytes32 thing = things[1];
        _tag(alice, x, thing);
        PostingKey rp = _rolePlaces(Purpose.TAG, thing);
        assertEq(_count(rp), 1);
        _act(alice, ActionKind.RELEASE, x, thing, 1, 0);
        _act(alice, ActionKind.BIND, x, thing, 2, 3);
        _act(alice, ActionKind.UNBIND, x, thing, 3, 0);
        _act(alice, ActionKind.BIND, x, thing, 4, 0);
        _tag(bob, x, thing); // a second author on the same position
        _deny(carol, x, thing);
        assertEq(_count(rp), 1, "one entry per distinct position");
        assertEq(_count(_authors(Keys.position(Purpose.TAG, x, thing))), 3);
        // a FOLDER position is listed under its name (role = the name hash)
        (Action memory nm, bytes memory nb) = _name("rp-name.txt");
        Action[] memory a = new Action[](2);
        bytes[] memory b = new bytes[](2);
        (a[0], b[0]) = (nm, nb);
        a[1] = _bind(Purpose.FOLDER, rootDir, keccak256("rp-name.txt"), things[2], 0);
        _execAs(address(this), a, b);
        assertEq(_count(_rolePlaces(Purpose.FOLDER, keccak256("rp-name.txt"))), 1);
    }

    // =============================================================================================
    // rebuild equals live, integrated
    // =============================================================================================

    PostingKey[] internal touched;
    ScopeKey[] internal touchedScopes;

    function _file(address who, bytes32 salt) internal returns (bytes32 f) {
        _execAs(who, _one(_create(salt)), new bytes[](1));
        f = Keys.subject(_pid(who), salt);
    }

    function _folder(address who, bytes32 parent, string memory name, bytes32 target) internal {
        (Action memory nm, bytes memory nb) = _name(bytes(name));
        Action[] memory a = new Action[](2);
        bytes[] memory b = new bytes[](2);
        (a[0], b[0]) = (nm, nb);
        a[1] = _bind(Purpose.FOLDER, parent, keccak256(bytes(name)), target, 0);
        _execAs(who, a, b);
    }

    function _mixedHistory() internal returns (bytes32[] memory topics, bytes32[] memory roles) {
        bytes32[] memory deep = _regPath("mix", 5); // registrations at several depths
        bytes32[] memory other = _regPath("mix-other", 2);
        bytes32 home = bytes32(uint256(uint160(makeAddr("integrated/home"))));
        bytes32 addr = bytes32(uint256(uint160(makeAddr("integrated/address-target"))));
        _tag(address(this), deep[4], things[0]);
        _tag(alice, deep[4], things[0]); // second author on an existing position
        _tag(alice, deep[4], things[1]);
        _tag(bob, deep[2], things[2]);
        _deny(bob, deep[4], things[3]); // lone negative
        _deny(carol, deep[1], things[4]); // lone negative on a middle topic
        _tag(carol, other[1], things[5]);
        _tag(bob, home, things[6]); // a home subject
        _tag(alice, deep[3], addr); // an address target (role = target = the address word)
        _act(alice, ActionKind.BIND, deep[4], things[0], 1, 75); // number change, positive
        _act(bob, ActionKind.UNBIND, deep[4], things[3], 1, 4); // number change, negative
        _act(alice, ActionKind.UNBIND, deep[4], things[1], 1, 0); // mask
        _act(alice, ActionKind.BIND, deep[4], things[1], 2, 9); // restore
        _act(bob, ActionKind.RELEASE, deep[2], things[2], 1, 0); // release
        _act(bob, ActionKind.BIND, deep[2], things[2], 2, 0); // remove and add back
        _act(bob, ActionKind.BIND, deep[4], things[3], 2, 1); // negative to positive over a first mask
        // a batch: one publication, a registration then several first statements
        {
            bytes[] memory w = _words("mix-batch", 2);
            (Action[] memory reg, bytes[] memory rb,) = _pathActions(w, true);
            Action[] memory a = new Action[](reg.length + 3);
            bytes[] memory b = new bytes[](reg.length + 3);
            for (uint256 i; i < reg.length; ++i) {
                (a[i], b[i]) = (reg[i], rb[i]);
            }
            for (uint256 i; i < 3; ++i) {
                a[reg.length + i] = _bind(Purpose.TAG, deep[3], things[7 + i], things[7 + i], 0);
            }
            _execAs(carol, a, b);
        }
        // a FOLDER position with several authors (each its own file) and a file at a home
        bytes32 fa = _file(alice, "mix/fa");
        bytes32 fb = _file(bob, "mix/fb");
        bytes32 fc = _file(carol, "mix/fc");
        _folder(alice, rootDir, "shared.txt", fa);
        _folder(bob, rootDir, "shared.txt", fb);
        _folder(carol, rootDir, "shared.txt", fc);
        _folder(alice, home, "at-home.txt", fa);
        topics = new bytes32[](10);
        for (uint256 i; i < 5; ++i) {
            topics[i] = deep[i];
        }
        (topics[5], topics[6], topics[7]) = (other[0], other[1], home);
        (topics[8], topics[9]) = (_wordId("mix-batch-0"), rootDir);
        roles = new bytes32[](16);
        for (uint256 i; i < 10; ++i) {
            roles[i] = things[i];
        }
        (roles[10], roles[11], roles[12], roles[13]) = (addr, fa, fb, fc);
        (roles[14], roles[15]) = (keccak256("shared.txt"), keccak256("at-home.txt"));
    }

    function _collect(bytes32[] memory topics, bytes32[] memory roles) internal {
        address[4] memory who = [address(this), alice, bob, carol];
        bytes32[2] memory purposes = [Purpose.TAG, Purpose.FOLDER];
        for (uint256 i; i < topics.length; ++i) {
            for (uint256 q; q < 2; ++q) {
                touched.push(_pk(6, Keys.openScope(purposes[q], topics[i])));
            }
            touched.push(_allBelow(topics[i]));
            touched.push(PostingKey.wrap(Keys.referenceList(topicTypeIds[TT_PATH], 0, topics[i])));
            touched.push(PostingKey.wrap(Keys.referenceList(topicTypeIds[TT_PATH], 1, topics[i])));
            for (uint256 j; j < who.length; ++j) {
                bytes32 pr = _pid(who[j]);
                touched.push(_mineBelow(pr, topics[i]));
                for (uint256 q; q < 2; ++q) {
                    touchedScopes.push(ScopeKey.wrap(Keys.scope(pr, purposes[q], topics[i])));
                }
                for (uint256 th; th < roles.length; ++th) {
                    for (uint256 q; q < 2; ++q) {
                        bytes32 pos = Keys.position(purposes[q], topics[i], roles[th]);
                        if (j == 0) touched.push(_authors(pos));
                        touched.push(PostingKey.wrap(Keys.historyList(Keys.binding(pr, pos))));
                    }
                }
            }
        }
        for (uint256 th; th < roles.length; ++th) {
            touched.push(PostingKey.wrap(Keys.backlinkList(roles[th])));
            for (uint256 q; q < 2; ++q) {
                touched.push(_rolePlaces(purposes[q], roles[th]));
            }
        }
    }

    function _same(IPostingStore x, IPostingStore y, PostingKey pk) internal view {
        (uint64 c1, uint64 l1, uint64 x1, uint16 f1) = x.postingHead(pk);
        (uint64 c2, uint64 l2, uint64 x2, uint16 f2) = y.postingHead(pk);
        assertEq(abi.encode(c1, l1, x1, f1), abi.encode(c2, l2, x2, f2), "posting head");
        assertEq(
            keccak256(abi.encode(x.postingSlice(pk, 0, 512))),
            keccak256(abi.encode(y.postingSlice(pk, 0, 512))),
            "posting entries"
        );
    }

    function test_rebuild_equals_live_integrated() public {
        (bytes32[] memory topics, bytes32[] memory roles) = _mixedHistory();
        _collect(topics, roles);
        IndexDeployer.Plan memory plan;
        plan.hotAbiId = KernelDeploy.HOT_ABI_ID;
        plan.decoder = address(new IndexReplayDecoder());
        plan.postingInitcode = type(PostingStore).creationCode;
        plan.postingFamilies = IndexDeploy.postingFamilies();
        plan.bitmapInitcode = type(BitmapStore).creationCode;
        plan.bitmapFamilies = IndexDeploy.bitmapFamilies();
        plan.generationInitcode = type(RealmIndex).creationCode;
        plan.units = _units();
        plan.specs = _specs();
        plan.work = IndexDoubleDefaults.workModel();
        plan.os = _openScope();
        IndexDeployer d = new IndexDeployer(r.k.proxy, keccak256(abi.encode(plan)));
        RealmIndex ix = RealmIndex(d.run(plan));
        while (ix.replayNextPublication(64) != 0) {}
        assertTrue(ix.replayReadiness().ready);
        IPostingStore p2 = IPostingStore(d.postingStore());
        IBitmapStore b2 = IBitmapStore(d.bitmapStore());
        uint256[22] memory nonEmpty;
        for (uint256 i; i < touched.length; ++i) {
            _same(r.g.posting, p2, touched[i]);
            (uint64 c,,,) = r.g.posting.postingHead(touched[i]);
            if (c != 0) ++nonEmpty[0];
        }
        uint256 scopes;
        for (uint256 i; i < touchedScopes.length; ++i) {
            ScopeKey s_ = touchedScopes[i];
            (uint64 c1, uint64 l1, uint64 m1, uint48 x1,, uint64 e1) = r.g.bitmap.scopeHead(s_);
            (uint64 c2, uint64 l2, uint64 m2, uint48 x2,, uint64 e2) = b2.scopeHead(s_);
            assertEq(abi.encode(c1, l1, m1, x1, e1), abi.encode(c2, l2, m2, x2, e2), "scope head");
            assertEq(
                abi.encode(r.g.bitmap.scopeSlice(s_, 0, 64)), abi.encode(b2.scopeSlice(s_, 0, 64))
            );
            if (c1 != 0) ++scopes;
        }
        assertGt(nonEmpty[0], 60, "the history touched the lists");
        assertGt(scopes, 10, "and the exact scope lists");
        // every family of the spike is non-empty somewhere in the comparison
        assertGt(_count(_allBelow(topics[0])), 0, "family 7");
        assertGt(_count(_mineBelow(_pid(alice), topics[0])), 0, "family 19");
        assertEq(
            _count(_authors(Keys.position(Purpose.FOLDER, rootDir, roles[14]))), 3, "family 20"
        );
        assertEq(_count(_pk(6, Keys.openScope(Purpose.FOLDER, topics[7]))), 1, "family 6 at a home");
        assertEq(_count(_rolePlaces(Purpose.TAG, things[0])), 1, "family 21");
        assertEq(_count(_rolePlaces(Purpose.TAG, roles[10])), 1, "family 21, address");
        assertGt(
            _count(PostingKey.wrap(Keys.referenceList(topicTypeIds[TT_PATH], 0, topics[0]))),
            0,
            "family 11"
        );
    }

    // =============================================================================================
    // targeted spam on a FOLDER position at a home
    // =============================================================================================

    function _byNameGas(bytes32 position, uint16 count)
        internal
        returns (uint256 used, uint256 rows)
    {
        vm.cool(address(r.k.proxy));
        vm.cool(address(r.k.implementation));
        vm.cool(address(r.g.posting));
        vm.cool(address(r.g.index));
        vm.cool(address(reader));
        uint256 before = gasleft();
        (, OpenScopeReader.AuthorRow[] memory a) =
            reader.byName(address(r.ledger), position, 0, count);
        used = before - gasleft();
        rows = a.length;
    }

    /// 300 authors each attach their own `pet.jpg` at one address (its home); `byName` page 1 costs what it costs
    /// with 3 authors.
    function test_targeted_spam_byName_on_a_home_folder() public {
        bytes32 small = bytes32(uint256(uint160(makeAddr("integrated/home-small"))));
        bytes32 big = bytes32(uint256(uint160(makeAddr("integrated/home-big"))));
        bytes32 role = keccak256("pet.jpg");
        (Action memory nm, bytes memory nb) = _name("pet.jpg");
        _execAs(address(this), _one(nm), _oneBody(nb));
        for (uint256 i; i < 303; ++i) {
            address who = address(uint160(0xD0000 + i));
            bytes32 salt = keccak256(abi.encode("pet", i));
            Action[] memory a = new Action[](2);
            a[0] = _create(salt);
            a[1] =
                _bind(Purpose.FOLDER, i < 3 ? small : big, role, Keys.subject(_pid(who), salt), 0);
            _execAs(who, a, new bytes[](2));
        }
        bytes32 ps = Keys.position(Purpose.FOLDER, small, role);
        bytes32 pb = Keys.position(Purpose.FOLDER, big, role);
        assertEq(_count(_authors(ps)), 3);
        assertEq(_count(_authors(pb)), 300);
        (uint256 g3, uint256 r3) = _byNameGas(ps, 3);
        (uint256 g300, uint256 r300) = _byNameGas(pb, 3);
        emit log_named_uint("spam byName FOLDER home 3 authors page 3 gas", g3);
        emit log_named_uint("spam byName FOLDER home 300 authors page 3 gas", g300);
        (uint256 g300p10,) = _byNameGas(pb, 10);
        emit log_named_uint("spam byName FOLDER home 300 authors page 10 gas", g300p10);
        assertEq(abi.encode(r3, r300), abi.encode(uint256(3), uint256(3)));
        // page 1 is independent of the list length: at most one extra posting word (5 entries per word) apart
        uint256 diff = g300 > g3 ? g300 - g3 : g3 - g300;
        assertLt(diff, 2_500, "page 1 cost does not grow with the authors");
    }

    function _oneBody(bytes memory b0) internal pure returns (bytes[] memory b) {
        b = new bytes[](1);
        b[0] = b0;
    }
}
