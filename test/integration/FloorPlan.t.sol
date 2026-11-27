// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FloorBase} from "./FloorBase.sol";
import {EfsFiles} from "../../src/lib/EfsFiles.sol";
import {EfsTopics} from "../../src/lib/EfsTopics.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {Action, Capability, Native, Purpose, ReadSet} from "../../src/interfaces/Actions.sol";
import {ILedgerCommitments} from "../../src/interfaces/ILedgerCommitments.sol";
import {Layout} from "../../src/core/layout/Layout.sol";
import {E_BATCH_SHAPE, E_INDEX_GAS, E_READSET_SHAPE} from "../../src/interfaces/Errors.sol";

/// @notice The planning rule of `gas/model.json` (design §10.4; `tools/gas-plan.mjs`, which reads only that file, wrote
///         `test/vectors/floor-plan.json`): for each shape, the largest publication the rule plans on this profile's
///         schedule is built here from the same state the rule assumed, and
///
///         - the kernel's own quote equals the rule's (`prefixFloor`, `finalReserve`, fresh slots, rewrites), so the
///           floor inputs the model publishes are the kernel's;
///         - it is admitted: its measured execution gas E and the floor's sufficient bound V (`FloorBase`) fit the
///           visible execution gas G = 2^24 − 21,000 − calldata; on prague it is also run with exactly G;
///         - one unit more is refused by the rule (the vectors' `next.refused`) and, on prague, run with G it is either
///           admitted (the headroom made the rule conservative) or refused with the named `E_INDEX_GAS` or by running
///           out of gas, never by another error; past the 64-action limit it is refused with `E_BATCH_SHAPE`.
///
///         Foundry's amsterdam profile has no state-gas reservoir and no 2^24 cap (state gas is drawn from the call's
///         own gas), so under `FOUNDRY_PROFILE=amsterdam` the publications run with ample gas and admission under the
///         cap is asserted by the arithmetic of `FloorBase` on the measured execution gas and the kernel's own quote
///         (run it with `FOUNDRY_GAS_LIMIT` raised, as for the measurement suites: docs/TAG-NUMBERS.md).
contract FloorPlanTest is FloorBase {
    EfsTopics.Types internal tt;
    bytes32 internal topic; // a registered one-word topic
    string internal json;
    address internal constant OTHER = address(0x0DD);

    /// b0 `NATIVE_GUARD` is ON: the Realm the model describes is the fixture's live set (revision 2 with b0,
    /// tools/deploy-plan.mjs G20b), as in `GasModel.t.sol`.
    function _capabilities() internal pure override returns (uint16) {
        return Capability.NATIVE_GUARD;
    }

    function setUp() public override {
        super.setUp();
        tt = _topicTypes();
        (Action[] memory a, bytes[] memory b, bytes32 id) =
            EfsTopics.registerWord(tt, bytes("floor-plan"));
        _execAs(address(this), a, b);
        topic = id;
        json = vm.readFile("test/vectors/floor-plan.json");
    }

    // ---- the vectors -------------------------------------------------------------------------------------------------

    function _key(string memory shape, string memory field) internal view returns (string memory) {
        return
            string.concat(
                ".schedules.", _amsterdam() ? "amsterdam" : "prague", ".", shape, ".", field
            );
    }

    function _u(string memory shape, string memory field) internal view returns (uint256) {
        return vm.parseJsonUint(json, _key(shape, field));
    }

    function _k(string memory shape) internal view returns (uint256) {
        return _u(shape, "k");
    }

    // ---- the proof ---------------------------------------------------------------------------------------------------

    /// `a`/`b`: the largest planned publication; `a1`/`b1`: one unit more (built only when it is within 64 actions;
    /// otherwise a 65-action publication). Both from the current state, by this contract's principal.
    /// What the floor quotes against what the index spends, for the planned publication: the callbacks' prefix
    /// spend (E − K − the final phase) and the final phase, with the ratios of the quote to them in thousandths.
    struct Spend {
        uint256 prefix;
        uint256 finalPhase;
        uint256 prefixRatio; // P / prefix × 1000
        uint256 finalRatio; // F / final phase × 1000
    }

    function _prove(
        string memory shape,
        Action[] memory a,
        bytes[] memory b,
        Action[] memory a1,
        bytes[] memory b1
    ) internal returns (Spend memory sp) {
        return _proveG(shape, a, b, "", a1, b1, "");
    }

    /// `_prove` for a guarded shape: `g` guards the planned publication and `g1` the one unit more (both empty for an
    /// unguarded shape).
    function _proveG(
        string memory shape,
        Action[] memory a,
        bytes[] memory b,
        bytes memory g,
        Action[] memory a1,
        bytes[] memory b1,
        bytes memory g1
    ) internal returns (Spend memory sp) {
        assertEq(a.length, _u(shape, "actions"), "the vectors' publication");
        Need memory w = _need(a, b, address(0), g);
        _log(shape, w);
        sp.finalPhase = _finalPhase(a, b, w.exec, g);
        sp.prefix = w.exec - w.kernel - sp.finalPhase;
        sp.prefixRatio = uint256(w.prefixFloor) * 1000 / sp.prefix;
        sp.finalRatio = uint256(w.finalReserve) * 1000 / sp.finalPhase;
        emit log_named_uint(string.concat("floor ", shape, " callbacks prefix"), sp.prefix);
        emit log_named_uint(string.concat("floor ", shape, " final phase"), sp.finalPhase);
        emit log_named_uint(string.concat("floor ", shape, " prefix ratio x1000"), sp.prefixRatio);
        emit log_named_uint(string.concat("floor ", shape, " final ratio x1000"), sp.finalRatio);
        emit log_named_uint(string.concat("floor ", shape, " k"), _k(shape));
        emit log_named_uint(string.concat("floor ", shape, " model E"), _u(shape, "E"));
        emit log_named_uint(string.concat("floor ", shape, " model K"), _u(shape, "K"));
        emit log_named_uint(string.concat("floor ", shape, " model V"), _u(shape, "V"));
        assertEq(w.prefixFloor, _u(shape, "prefixFloor"), "the rule's prefix floor is the kernel's");
        assertEq(
            w.finalReserve, _u(shape, "finalReserve"), "the rule's final reserve is the kernel's"
        );
        assertLe(w.exec, w.room, "the planned publication executes within the cap");
        assertLe(w.visible, w.room, "the floor admits the planned publication within the cap");
        if (!_amsterdam()) {
            uint256 snap = vm.snapshotState();
            Native memory c = _ctx(a);
            _coolRealm();
            r.ledger.execute{gas: w.room}(a, b, c, g);
            vm.revertToStateAndDelete(snap);
        }
        _next(shape, a1, b1, g1);
    }

    function _next(string memory shape, Action[] memory a1, bytes[] memory b1, bytes memory g1)
        internal
    {
        string memory refused = vm.parseJsonString(json, _key(shape, "next.refused"));
        // a shape fixed at its size (the vectors' `fixedK`) has no one unit more
        if (keccak256(bytes(refused)) == keccak256("fixedK")) return;
        Native memory c = _ctx(a1);
        // one unit more is past a read-set limit: the kernel refuses its guard (E_READSET_SHAPE 1, 2 or 5)
        if (keccak256(bytes(refused)) == keccak256("maxReadCount")) {
            uint256 snap0 = vm.snapshotState();
            vm.expectRevert(abi.encodeWithSelector(E_READSET_SHAPE.selector, uint8(5)));
            r.ledger.execute(a1, b1, c, g1);
            vm.revertToStateAndDelete(snap0);
            emit log_named_string(string.concat("floor ", shape, " next refused by"), refused);
            return;
        }
        if (a1.length > 64) {
            uint256 snap = vm.snapshotState();
            try r.ledger.execute(a1, b1, c, g1) {
                revert("a 65-action publication admitted");
            } catch (bytes memory err) {
                assertEq(bytes4(err), E_BATCH_SHAPE.selector, "past the action limit");
            }
            vm.revertToStateAndDelete(snap);
            return;
        }
        assertGt(bytes(refused).length, 0, "the rule refuses one unit more");
        emit log_named_string(string.concat("floor ", shape, " next refused by"), refused);
        Need memory w = _need(a1, b1, address(0), g1);
        assertEq(w.prefixFloor, _u(shape, "next.prefixFloor"), "the rule's prefix floor (k + 1)");
        assertEq(w.finalReserve, _u(shape, "next.finalReserve"), "the rule's final reserve (k + 1)");
        emit log_named_uint(string.concat("floor ", shape, " next exec"), w.exec);
        emit log_named_uint(string.concat("floor ", shape, " next visible needed"), w.visible);
        if (_amsterdam()) return;
        uint256 snap2 = vm.snapshotState();
        _coolRealm();
        try r.ledger.execute{gas: w.room}(a1, b1, c, g1) {
            emit log_named_string(string.concat("floor ", shape, " next on prague"), "admitted");
        } catch (bytes memory err) {
            assertTrue(
                err.length == 0 || bytes4(err) == E_INDEX_GAS.selector,
                "one more fails only with E_INDEX_GAS or out of gas"
            );
            emit log_named_string(
                string.concat("floor ", shape, " next on prague"),
                err.length == 0 ? "out of gas" : "E_INDEX_GAS"
            );
        }
        vm.revertToStateAndDelete(snap2);
    }

    // ---- builders ----------------------------------------------------------------------------------------------------

    function _thing(string memory seed, uint256 i) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(uint256(keccak256(abi.encode(seed, i))))));
    }

    function _bodies(uint256 n) internal pure returns (bytes[] memory) {
        return new bytes[](n);
    }

    function _send(address who, Action[] memory a, bytes[] memory b) internal {
        _execAs(who, a, b);
    }

    /// Publications of `a` in slices of at most `per` actions (setup only).
    function _sendSliced(address who, Action[] memory a, bytes[] memory b, uint256 per) internal {
        for (uint256 i; i < a.length; i += per) {
            uint256 n = a.length - i < per ? a.length - i : per;
            Action[] memory x = new Action[](n);
            bytes[] memory y = new bytes[](n);
            for (uint256 j; j < n; ++j) {
                (x[j], y[j]) = (a[i + j], b[i + j]);
            }
            _send(who, x, y);
        }
    }

    /// Registers the `depth`-word path `<name>-0/…` and returns its deepest topic.
    function _path(string memory name, uint256 depth) internal returns (bytes32 id) {
        name = _lower(name);
        bytes[] memory w = new bytes[](depth);
        for (uint256 i; i < depth; ++i) {
            w[i] = bytes(string.concat(name, "-", vm.toString(i)));
        }
        (Action[] memory a, bytes[] memory b, bytes32 got) = EfsTopics.registerPath(tt, w);
        _sendSliced(address(this), a, b, 32);
        id = got;
    }

    /// `topic-word/1` takes lowercase letters: the shape name with each capital lowered and digits spelled as letters.
    function _lower(string memory s) internal pure returns (string memory) {
        bytes memory x = bytes.concat(bytes(s));
        for (uint256 i; i < x.length; ++i) {
            uint8 ch = uint8(x[i]);
            if (ch >= 65 && ch <= 90) x[i] = bytes1(ch + 32);
            else if (ch >= 48 && ch <= 57) x[i] = bytes1(ch + 49);
        }
        return string(x);
    }

    function _tags(bytes32 t, string memory seed, uint256 from, uint256 n)
        internal
        pure
        returns (Action[] memory a)
    {
        a = new Action[](n);
        for (uint256 i; i < n; ++i) {
            a[i] = EfsTopics.tag(t, _thing(seed, from + i), 0, 0);
        }
    }

    function _prefix(Action[] memory a, uint256 n) internal pure returns (Action[] memory x) {
        x = new Action[](n);
        for (uint256 i; i < n; ++i) {
            x[i] = a[i];
        }
    }

    /// One more unit than `k` (an action at index k), or 65 actions when k is the action limit.
    function _more(Action[] memory all, uint256 k, uint256 units)
        internal
        pure
        returns (Action[] memory)
    {
        return _prefix(all, (k + 1) * units > 64 ? 65 : (k + 1) * units);
    }

    // ---- the shapes ----------------------------------------------------------------------------------------------------

    function test_plan_lone_negatives() public {
        uint256 k = _k("loneNegatives");
        Action[] memory all = new Action[](65);
        for (uint256 i; i < 65; ++i) {
            all[i] = EfsTopics.deny(topic, _thing("lone", i), 0, 0);
        }
        Action[] memory more = _more(all, k, 1);
        _covers(
            _prove("loneNegatives", _prefix(all, k), _bodies(k), more, _bodies(more.length)), true
        );
    }

    /// Case i: k first tags on the deepest topic of a new path, every position and every roll-up new.
    function _firstTagsNew(string memory shape, uint256 depth) internal {
        uint256 k = _k(shape);
        bytes32 t = _path(shape, depth);
        Action[] memory all = _tags(t, shape, 0, 65);
        Action[] memory more = _more(all, k, 1);
        _prove(shape, _prefix(all, k), _bodies(k), more, _bodies(more.length));
    }

    /// Cases iii and iv: another author first tags 64 things on the topic (`OTHER_FIRST_TAGS` of tools/gas-plan.mjs:
    /// the positions exist and the shared roll-ups hold 64 entries); in case iv this author first tags six other
    /// things, so its roll-ups at every ancestor hold six entries. Tag j is about the other author's thing j.
    function _firstTagsSecond(string memory shape, uint256 depth, uint256 mine0) internal {
        uint256 k = _k(shape);
        bytes32 t = _path(shape, depth);
        _sendSliced(OTHER, _tags(t, shape, 0, 64), _bodies(64), depth > 8 ? 4 : 16);
        if (mine0 > 0) _send(address(this), _tags(t, "mine", 0, mine0), _bodies(mine0));
        Action[] memory all = _tags(t, shape, 0, 65);
        Action[] memory more = _more(all, k, 1);
        _prove(shape, _prefix(all, k), _bodies(k), more, _bodies(more.length));
    }

    function test_plan_first_tags_depth8_new() public {
        _firstTagsNew("firstTagsDepth8New", 8);
    }

    function test_plan_first_tags_depth64_new() public {
        _firstTagsNew("firstTagsDepth64New", 64);
    }

    function test_plan_first_tags_depth8_existing() public {
        _firstTagsSecond("firstTagsDepth8Existing", 8, 6);
    }

    function test_plan_first_tags_depth64_existing() public {
        _firstTagsSecond("firstTagsDepth64Existing", 64, 6);
    }

    function test_plan_second_author_depth8() public {
        _firstTagsSecond("secondAuthorDepth8", 8, 0);
    }

    /// Masks, releases and restores of asserted tags on the one-word topic (the tags, and for restores the masks,
    /// are written first).
    function _tagTransitions(string memory shape, uint8 which) internal returns (Spend memory) {
        uint256 k = _k(shape);
        uint256 n = k + 1 > 64 ? 64 : k + 1;
        _send(address(this), _tags(topic, shape, 0, n), _bodies(n));
        Action[] memory all = new Action[](65);
        for (uint256 i; i < 65; ++i) {
            bytes32 thing = _thing(shape, i);
            if (which == 0) all[i] = EfsFiles.unbind(Purpose.TAG, topic, thing, 1);
            else if (which == 1) all[i] = EfsFiles.release(Purpose.TAG, topic, thing, 1);
            else all[i] = EfsTopics.tag(topic, thing, 2, 0);
        }
        if (which == 2) {
            Action[] memory masks = new Action[](n);
            for (uint256 i; i < n; ++i) {
                masks[i] = EfsFiles.unbind(Purpose.TAG, topic, _thing(shape, i), 1);
            }
            _send(address(this), masks, _bodies(n));
        }
        Action[] memory more = _more(all, k, 1);
        return _prove(shape, _prefix(all, k), _bodies(k), more, _bodies(more.length));
    }

    /// The quote covers the callbacks' prefix spend (and, when `final_`, the final phase) of the planned publication.
    function _covers(Spend memory sp, bool final_) internal view {
        assertGe(
            sp.prefixRatio,
            _minRatio(),
            "the prefix floor covers the callbacks' spend, with the margin"
        );
        if (final_) assertGe(sp.finalRatio, 1000, "the final reserve covers the final phase");
    }

    /// Number changes of asserted tags (a REBIND to the same target with a new number) and masks of masks (an UNBIND
    /// from MASKED with a new number; the lone negatives are written first).
    function _restatements(string memory shape, bool masks) internal returns (Spend memory) {
        uint256 k = _k(shape);
        uint256 n = k + 1 > 64 ? 64 : k + 1;
        Action[] memory first = new Action[](n);
        for (uint256 i; i < n; ++i) {
            first[i] = masks
                ? EfsTopics.deny(topic, _thing(shape, i), 0, 0)
                : EfsTopics.tag(topic, _thing(shape, i), 0, 0);
        }
        _send(address(this), first, _bodies(n));
        Action[] memory all = new Action[](65);
        for (uint256 i; i < 65; ++i) {
            all[i] = masks
                ? EfsTopics.deny(topic, _thing(shape, i), 1, 3)
                : EfsTopics.tag(topic, _thing(shape, i), 1, 7);
        }
        Action[] memory more = _more(all, k, 1);
        return _prove(shape, _prefix(all, k), _bodies(k), more, _bodies(more.length));
    }

    function test_plan_tag_number_changes() public {
        _covers(_restatements("tagNumberChanges", false), true);
    }

    function test_plan_masks_of_masks() public {
        _covers(_restatements("masksOfMasks", true), true);
    }

    function test_plan_tag_masks() public {
        _covers(_tagTransitions("tagMasks", 0), true);
    }

    function test_plan_tag_releases() public {
        _covers(_tagTransitions("tagReleases", 1), true);
    }

    function test_plan_tag_restores() public {
        _covers(_tagTransitions("tagRestores", 2), true);
    }

    /// A 12-byte word `floorplan` + three letters, distinct per i (< 26^3).
    function _word(uint256 i) internal pure returns (bytes memory w) {
        w = bytes.concat(
            "floorplan",
            bytes1(uint8(97 + (i / 676) % 26)),
            bytes1(uint8(97 + (i / 26) % 26)),
            bytes1(uint8(97 + i % 26))
        );
    }

    function test_plan_registration_chunk() public {
        uint256 k = _k("registrationChunk");
        Action[] memory all = new Action[](65);
        bytes[] memory bodies = new bytes[](65);
        for (uint256 i; i < 65; ++i) {
            (Action[] memory x, bytes[] memory y,) = EfsTopics.registerWord(tt, _word(i));
            (all[i], bodies[i]) = (x[0], y[0]);
            assertEq(bodies[i].length, 12);
        }
        uint256 m = (k + 1) > 64 ? 65 : k + 1;
        (Action[] memory a, bytes[] memory b) = _slice(all, bodies, k);
        (Action[] memory a1, bytes[] memory b1) = _slice(all, bodies, m);
        _covers(_prove("registrationChunk", a, b, a1, b1), true);
    }

    function _slice(Action[] memory a, bytes[] memory b, uint256 n)
        internal
        pure
        returns (Action[] memory x, bytes[] memory y)
    {
        x = new Action[](n);
        y = new bytes[](n);
        for (uint256 i; i < n; ++i) {
            (x[i], y[i]) = (a[i], b[i]);
        }
    }

    function _filesTypes() internal view returns (EfsFiles.Types memory t) {
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

    /// k create-file recipes into the root folder: a 10-byte name and an 18-byte document each.
    function test_plan_create_files() public {
        uint256 k = _k("createFiles");
        Action[] memory all = new Action[](70);
        bytes[] memory bodies = new bytes[](70);
        for (uint256 i; i < 14; ++i) {
            bytes memory name = bytes.concat(
                "f", bytes1(uint8(97 + (i / 26) % 26)), bytes1(uint8(97 + i % 26)), "-doc.md"
            );
            (Action[] memory x, bytes[] memory y,,) = EfsFiles.createFile(
                _filesTypes(),
                p,
                rootDir,
                keccak256(abi.encode("floor-plan file", i)),
                name,
                "Meeting at 10:00.\n",
                true
            );
            assertEq(x.length, 5);
            assertEq(y[1].length, 82);
            assertEq(y[2].length, 10);
            for (uint256 j; j < 5; ++j) {
                (all[i * 5 + j], bodies[i * 5 + j]) = (x[j], y[j]);
            }
        }
        uint256 m = (k + 1) * 5 > 64 ? 65 : (k + 1) * 5;
        (Action[] memory a, bytes[] memory b) = _slice(all, bodies, k * 5);
        (Action[] memory a1, bytes[] memory b1) = _slice(all, bodies, m);
        // the final phase of a create-file recipe is under-reserved by design (design §10.4: the Files validator's
        // final hook), so only the prefix quote is asserted
        _covers(_prove("createFiles", a, b, a1, b1), false);
    }

    // ---- re-binds and publishes (work-model formula 3) -----------------------------------------------------------

    /// A ten-byte name `<pre><3 letters>.txt` (pre is three bytes), distinct per i (< 26^3).
    function _nm(string memory pre, uint256 i) internal pure returns (bytes memory) {
        return bytes.concat(
            bytes(pre),
            bytes1(uint8(97 + (i / 676) % 26)),
            bytes1(uint8(97 + (i / 26) % 26)),
            bytes1(uint8(97 + i % 26)),
            ".txt"
        );
    }

    /// Creates `n` files `<pre>xyz.txt` in the root folder (five actions each, in publications of 50); returns them.
    function _filesIn(string memory pre, uint256 n) internal returns (bytes32[] memory f) {
        f = new bytes32[](n);
        Action[] memory a = new Action[](n * 5);
        bytes[] memory b = new bytes[](n * 5);
        for (uint256 i; i < n; ++i) {
            (Action[] memory x, bytes[] memory y, bytes32 file,) = EfsFiles.createFile(
                _filesTypes(),
                p,
                rootDir,
                keccak256(abi.encode("floor-plan rebind", pre, i)),
                _nm(pre, i),
                "Meeting at 10:00.\n",
                true
            );
            f[i] = file;
            for (uint256 j; j < 5; ++j) {
                (a[i * 5 + j], b[i * 5 + j]) = (x[j], y[j]);
            }
        }
        _sendSliced(address(this), a, b, 50);
    }

    /// k re-binds of root-folder entries (`fa-…`) from their files to other files (`fb-…`'s).
    function test_plan_folder_rebinds() public {
        uint256 k = _k("folderRebinds");
        uint256 n = k + 1 > 64 ? 64 : k + 1;
        _filesIn("fa-", n);
        bytes32[] memory other = _filesIn("fb-", n);
        Action[] memory all = new Action[](65);
        for (uint256 i; i < 65; ++i) {
            all[i] = EfsFiles.bind(
                Purpose.FOLDER, rootDir, keccak256(_nm("fa-", i)), i < n ? other[i] : bytes32(0), 1
            );
        }
        Action[] memory more = _more(all, k, 1);
        // the prefix is covered; the final phase of a folder re-bind (≈ 13k, the Files validator's reads) is above the
        // per-bind reserve, which is set from first tags on distinct topics (design §10.4): only the planner's E pays it
        _covers(
            _prove("folderRebinds", _prefix(all, k), _bodies(k), more, _bodies(more.length)), false
        );
    }

    /// 65 name records `<pre>xyz.txt` (10 bytes each).
    function _nameRecords(string memory pre)
        internal
        view
        returns (Action[] memory all, bytes[] memory bodies)
    {
        all = new Action[](65);
        bodies = new bytes[](65);
        for (uint256 i; i < 65; ++i) {
            (all[i], bodies[i]) = _name(_nm(pre, i));
            assertEq(bodies[i].length, 10);
        }
    }

    /// k repeat PUBLISHes of existing name records (the same bodies published once before).
    function test_plan_repeat_publishes() public {
        uint256 k = _k("repeatPublishes");
        uint256 n = k + 1 > 64 ? 64 : k + 1;
        (Action[] memory all, bytes[] memory bodies) = _nameRecords("rp-");
        (Action[] memory first, bytes[] memory fb) = _slice(all, bodies, n);
        _send(address(this), first, fb);
        uint256 m = (k + 1) > 64 ? 65 : k + 1;
        (Action[] memory a, bytes[] memory b) = _slice(all, bodies, k);
        (Action[] memory a1, bytes[] memory b1) = _slice(all, bodies, m);
        _covers(_prove("repeatPublishes", a, b, a1, b1), true);
    }

    /// k fresh name records (publish-heavy: the final phase's per-publish term).
    function test_plan_name_records() public {
        uint256 k = _k("nameRecords");
        (Action[] memory all, bytes[] memory bodies) = _nameRecords("nr-");
        uint256 m = (k + 1) > 64 ? 65 : k + 1;
        (Action[] memory a, bytes[] memory b) = _slice(all, bodies, k);
        (Action[] memory a1, bytes[] memory b1) = _slice(all, bodies, m);
        _covers(_prove("nameRecords", a, b, a1, b1), true);
    }

    /// k units of a fresh name record and a first tag on the one-word topic (2 actions each).
    function test_plan_publishes_and_tags() public {
        uint256 k = _k("publishesAndTags");
        (Action[] memory names, bytes[] memory nb) = _nameRecords("pt-");
        Action[] memory all = new Action[](66);
        bytes[] memory bodies = new bytes[](66);
        for (uint256 i; i < 33; ++i) {
            (all[2 * i], bodies[2 * i]) = (names[i], nb[i]);
            all[2 * i + 1] = EfsTopics.tag(topic, _thing("publishesAndTags", i), 0, 0);
        }
        uint256 m = (k + 1) * 2 > 64 ? 65 : (k + 1) * 2;
        (Action[] memory a, bytes[] memory b) = _slice(all, bodies, k * 2);
        (Action[] memory a1, bytes[] memory b1) = _slice(all, bodies, m);
        _covers(_prove("publishesAndTags", a, b, a1, b1), true);
    }

    // ---- the list release: a yes after a lone no, and files placed at names their author removed ------------------

    /// k yeses after lone noes on the one-word topic (a BIND on a head that never bound).
    function test_plan_tag_yeses_after_lone_noes() public {
        string memory shape = "tagYesesAfterLoneNoes";
        uint256 k = _k(shape);
        uint256 n = k + 1 > 64 ? 64 : k + 1;
        Action[] memory noes = new Action[](n);
        for (uint256 i; i < n; ++i) {
            noes[i] = EfsTopics.deny(topic, _thing(shape, i), 0, 0);
        }
        _send(address(this), noes, _bodies(n));
        Action[] memory all = new Action[](65);
        for (uint256 i; i < 65; ++i) {
            all[i] = EfsTopics.tag(topic, _thing(shape, i), 1, 0);
        }
        Action[] memory more = _more(all, k, 1);
        _covers(_prove(shape, _prefix(all, k), _bodies(k), more, _bodies(more.length)), true);
    }

    /// `n` files `<pre>xyz.txt` created in `folder` and then removed (RELEASE), so their names are removed names.
    function _removedIn(bytes32 folder, string memory pre, uint256 n) internal {
        Action[] memory a = new Action[](0);
        bytes[] memory b = new bytes[](0);
        for (uint256 i; i < n; ++i) {
            (Action[] memory x, bytes[] memory y,,) = EfsFiles.createFile(
                _filesTypes(),
                p,
                folder,
                keccak256(abi.encode("floor-plan old", pre, i)),
                _nm(pre, i),
                "Old notes here.\n",
                true
            );
            (a, b) = EfsFiles.concat(a, b, x, y);
        }
        _sendSliced(address(this), a, b, 60);
        Action[] memory rel = new Action[](n);
        for (uint256 i; i < n; ++i) {
            rel[i] = EfsFiles.release(Purpose.FOLDER, folder, keccak256(_nm(pre, i)), 1);
        }
        _send(address(this), rel, _bodies(n));
    }

    /// k create-file recipes at removed names of the root folder: the folder bind restores the RELEASED head to the new
    /// file; with `withName` the name PUBLISH is a repeat (as `EfsFiles.createFile` writes it), else it is left out.
    function _createAtRemoved(string memory shape, uint256 units, uint256 old, bool withName)
        internal
    {
        uint256 k = _k(shape);
        _removedIn(rootDir, "cr-", old);
        Action[] memory all = new Action[](0);
        bytes[] memory bodies = new bytes[](0);
        for (uint256 i; i < old; ++i) {
            (Action[] memory x, bytes[] memory y,,) = EfsFiles.createFile(
                _filesTypes(),
                p,
                rootDir,
                keccak256(abi.encode("floor-plan new", i)),
                _nm("cr-", i),
                "Meeting at 10:00.\n",
                withName
            );
            assertEq(x.length, units);
            x[x.length - 1].expectedRevision = 2;
            (all, bodies) = EfsFiles.concat(all, bodies, x, y);
        }
        uint256 m = (k + 1) * units > 64 ? 65 : (k + 1) * units;
        if (m > all.length) m = all.length; // 65 actions are never needed past the units built
        (Action[] memory a, bytes[] memory b) = _slice(all, bodies, k * units);
        (Action[] memory a1, bytes[] memory b1) = _slice(all, bodies, m);
        _covers(_prove(shape, a, b, a1, b1), false);
    }

    function test_plan_create_files_at_removed_names() public {
        _createAtRemoved("createFilesAtRemovedNames", 5, 13, true);
    }

    function test_plan_create_files_at_removed_names_no_name() public {
        _createAtRemoved("createFilesAtRemovedNamesNoName", 4, 17, false);
    }

    /// k moves of root-folder files into removed names of another folder: RELEASE at the root, restore at the other
    /// folder; with `withName` the name PUBLISH is a repeat.
    function _movesIntoRemoved(string memory shape, uint256 units, uint256 n, bool withName)
        internal
    {
        uint256 k = _k(shape);
        Action[] memory d = new Action[](1);
        bytes[] memory db = new bytes[](1);
        (d[0], db[0]) = _publish(
            T_DIRECTORY, EfsFiles.directoryBody(p, keccak256(abi.encode("floor-plan dest", shape)))
        );
        bytes32 dest = _id(T_DIRECTORY, db[0]);
        _send(address(this), d, db);
        _removedIn(dest, "mb-", n);
        Action[] memory a = new Action[](n * 5);
        bytes[] memory b = new bytes[](n * 5);
        bytes32[] memory file = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            (Action[] memory x, bytes[] memory y, bytes32 f,) = EfsFiles.createFile(
                _filesTypes(),
                p,
                rootDir,
                keccak256(abi.encode("floor-plan mover", i)),
                _nm("ma-", i),
                "Moving notes.\n",
                true
            );
            file[i] = f;
            for (uint256 j; j < 5; ++j) {
                (a[i * 5 + j], b[i * 5 + j]) = (x[j], y[j]);
            }
        }
        _sendSliced(address(this), a, b, 60);
        Action[] memory all = new Action[](0);
        bytes[] memory bodies = new bytes[](0);
        for (uint256 i; i < n; ++i) {
            (Action[] memory x, bytes[] memory y) = EfsFiles.move(
                _filesTypes(), file[i], rootDir, _nm("ma-", i), 1, dest, _nm("mb-", i), 2, withName
            );
            assertEq(x.length, units);
            (all, bodies) = EfsFiles.concat(all, bodies, x, y);
        }
        uint256 m = (k + 1) * units > 64 ? 65 : (k + 1) * units;
        if (m > all.length) m = all.length;
        (Action[] memory a0, bytes[] memory b0) = _slice(all, bodies, k * units);
        (Action[] memory a1, bytes[] memory b1) = _slice(all, bodies, m);
        _covers(_prove(shape, a0, b0, a1, b1), false);
    }

    function test_plan_moves_into_removed_names() public {
        _movesIntoRemoved("movesIntoRemovedNames", 3, 22, true);
    }

    function test_plan_moves_into_removed_names_no_name() public {
        _movesIntoRemoved("movesIntoRemovedNamesNoName", 2, 33, false);
    }

    // ---- guarded publications (design §5.1; gas/model.json profiles.<schedule>.guard) -----------------------------
    // Each guarded shape is built from the same state as its unguarded twin, and its guard names the heads the
    // vectors' `guard` describes, with expected heads as stored now (head-snapshot profile 2).

    /// The guard over `pr` × `pos` (position-major), expected heads as stored now, hashed as the ingress hashes them.
    function _guardOf(bytes32[] memory pr, bytes32[] memory pos)
        internal
        view
        returns (bytes memory)
    {
        uint256 n = pr.length;
        uint256 m = pos.length;
        bytes32[] memory h = new bytes32[](n * m);
        ILedgerCommitments cm = ILedgerCommitments(r.hot.ingress());
        for (uint256 j; j < m; ++j) {
            for (uint256 i; i < n; ++i) {
                uint256 slot = Layout.bindingsHeadsSlot(Keys.binding(pr[i], pos[j]));
                (uint8 st, uint48 rev, uint48 adm, uint8 tk,,,,) =
                    Layout.unpackHeadRowWord0(r.hot.extsload(bytes32(slot)));
                bytes32 t;
                if (tk != 0) t = r.hot.extsload(bytes32(slot + 1));
                h[j * n + i] = cm.headSnapshotHash(st, uint64(rev), uint64(adm), t);
            }
        }
        return abi.encode(ReadSet(pr, pos, h));
    }

    /// The vectors' read set of `shape` at `field` ("guard" or "next.guard") has `n` principals and `m` positions.
    function _assertGuardShape(string memory shape, string memory field, uint256 n, uint256 m)
        internal
        view
    {
        assertEq(_u(shape, string.concat(field, ".principals")), n, "the vectors' guard principals");
        assertEq(_u(shape, string.concat(field, ".positions")), m, "the vectors' guard positions");
    }

    function _mineOf(bytes32[] memory pos, uint256 n) internal view returns (bytes memory) {
        bytes32[] memory pr = new bytes32[](1);
        pr[0] = p;
        bytes32[] memory x = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            x[i] = pos[i];
        }
        return _guardOf(pr, x);
    }

    /// A guarded or unguarded shape whose guard is one principal (the author) over the first `perUnit`·k positions
    /// of `pos` (the heads the batch writes, in order); `a1`'s guard covers one unit more when it is within the limits.
    function _proveMine(
        string memory shape,
        bool guarded,
        Action[] memory all,
        bytes[] memory bodies,
        uint256 units,
        bytes32[] memory pos,
        uint256 perUnit
    ) internal returns (Spend memory) {
        uint256 k = _k(shape);
        uint256 m = (k + 1) * units > 64 ? 65 : (k + 1) * units;
        if (m > all.length) m = all.length;
        (Action[] memory a, bytes[] memory b) = _slice(all, bodies, k * units);
        (Action[] memory a1, bytes[] memory b1) = _slice(all, bodies, m);
        bytes memory g;
        bytes memory g1;
        if (guarded) {
            _assertGuardShape(shape, "guard", 1, perUnit * k);
            g = _mineOf(pos, perUnit * k);
            uint256 n1 = perUnit * (k + 1);
            if (m <= 64 && n1 <= pos.length) g1 = _mineOf(pos, n1);
        }
        return _proveG(shape, a, b, g, a1, b1, g1);
    }

    /// k moves of root-folder files to fresh names in another folder (the names published first, no name PUBLISH):
    /// RELEASE at the root and BIND FOLDER at the destination; guarded over both heads of every move.
    function _movesFresh(string memory shape, bool guarded) internal returns (Spend memory) {
        uint256 k = _k(shape);
        uint256 n = k + 1 > 32 ? 32 : k + 1;
        Action[] memory d = new Action[](1);
        bytes[] memory db = new bytes[](1);
        (d[0], db[0]) = _publish(
            T_DIRECTORY, EfsFiles.directoryBody(p, keccak256(abi.encode("floor-plan moves", shape)))
        );
        bytes32 dest = _id(T_DIRECTORY, db[0]);
        _send(address(this), d, db);
        bytes32[] memory file = _filesIn("mv-", n);
        Action[] memory names = new Action[](n);
        bytes[] memory nb = new bytes[](n);
        for (uint256 i; i < n; ++i) {
            (names[i], nb[i]) = _name(_nm("mw-", i));
        }
        _send(address(this), names, nb);
        Action[] memory all = new Action[](0);
        bytes[] memory bodies = new bytes[](0);
        bytes32[] memory pos = new bytes32[](2 * n);
        for (uint256 i; i < n; ++i) {
            (Action[] memory x, bytes[] memory y) = EfsFiles.move(
                _filesTypes(), file[i], rootDir, _nm("mv-", i), 1, dest, _nm("mw-", i), 0, false
            );
            (all, bodies) = EfsFiles.concat(all, bodies, x, y);
            pos[2 * i] = Keys.position(Purpose.FOLDER, rootDir, keccak256(_nm("mv-", i)));
            pos[2 * i + 1] = Keys.position(Purpose.FOLDER, dest, keccak256(_nm("mw-", i)));
        }
        return _proveMine(shape, guarded, all, bodies, 2, pos, 2);
    }

    function test_plan_moves_to_fresh() public {
        _covers(_movesFresh("movesToFresh", false), false);
    }

    function test_plan_moves_to_fresh_guarded() public {
        _covers(_movesFresh("movesToFreshGuarded", true), false);
    }

    /// k masks (`restores` false) or restores to the kept files (true) of root-folder entries; guarded over their heads.
    function _folderLater(string memory shape, bool restores, bool guarded)
        internal
        returns (Spend memory)
    {
        uint256 k = _k(shape);
        uint256 n = k + 1 > 64 ? 64 : k + 1;
        bytes32[] memory file = _filesIn("fm-", n);
        bytes32[] memory pos = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            pos[i] = Keys.position(Purpose.FOLDER, rootDir, keccak256(_nm("fm-", i)));
        }
        Action[] memory all = new Action[](65);
        for (uint256 i; i < 65; ++i) {
            all[i] = EfsFiles.unbind(Purpose.FOLDER, rootDir, keccak256(_nm("fm-", i)), 1);
        }
        if (restores) {
            _send(address(this), _prefix(all, n), _bodies(n));
            for (uint256 i; i < 65; ++i) {
                all[i] = EfsFiles.bind(
                    Purpose.FOLDER, rootDir, keccak256(_nm("fm-", i)), file[i % n], 2
                );
            }
        }
        return _proveMine(shape, guarded, all, _bodies(65), 1, pos, 1);
    }

    function test_plan_folder_masks() public {
        _covers(_folderLater("folderMasks", false, false), false);
    }

    function test_plan_folder_masks_guarded() public {
        _covers(_folderLater("folderMasksGuarded", false, true), false);
    }

    function test_plan_folder_restores() public {
        _covers(_folderLater("folderRestores", true, false), false);
    }

    function test_plan_folder_restores_guarded() public {
        _covers(_folderLater("folderRestoresGuarded", true, true), false);
    }

    /// Number changes of asserted tags on the one-word topic, guarded over their heads.
    function test_plan_tag_number_changes_guarded() public {
        string memory shape = "tagNumberChangesGuarded";
        uint256 k = _k(shape);
        uint256 n = k + 1 > 64 ? 64 : k + 1;
        Action[] memory first = new Action[](n);
        bytes32[] memory pos = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            first[i] = EfsTopics.tag(topic, _thing(shape, i), 0, 0);
            pos[i] = Keys.position(Purpose.TAG, topic, _thing(shape, i));
        }
        _send(address(this), first, _bodies(n));
        Action[] memory all = new Action[](65);
        for (uint256 i; i < 65; ++i) {
            all[i] = EfsTopics.tag(topic, _thing(shape, i), 1, 7);
        }
        _covers(_proveMine(shape, true, all, _bodies(65), 1, pos, 1), true);
    }

    /// `n` files `<pre>xyz.txt` in the root folder and their root records (as `_filesIn`).
    function _filesWithRoots(string memory pre, uint256 n)
        internal
        returns (bytes32[] memory f, bytes32[] memory root)
    {
        f = new bytes32[](n);
        root = new bytes32[](n);
        Action[] memory a = new Action[](n * 5);
        bytes[] memory b = new bytes[](n * 5);
        for (uint256 i; i < n; ++i) {
            (Action[] memory x, bytes[] memory y, bytes32 file, bytes32 rootRecord) = EfsFiles.createFile(
                _filesTypes(),
                p,
                rootDir,
                keccak256(abi.encode("floor-plan edit", pre, i)),
                _nm(pre, i),
                "Meeting at 10:00.\n",
                true
            );
            (f[i], root[i]) = (file, rootRecord);
            for (uint256 j; j < 5; ++j) {
                (a[i * 5 + j], b[i * 5 + j]) = (x[j], y[j]);
            }
        }
        _sendSliced(address(this), a, b, 50);
    }

    /// The lens's other authors (63 EOAs).
    function _lensAuthor(uint256 i) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encode("floor-plan lens", i)))));
    }

    /// k edits of the author's files (PUBLISH files-child/1 form 0, 114 bytes; BIND HEAD re-bind). With a lens, 63
    /// other authors first bind each file's HEAD to its root, and the guard is the 64 principals × the first `lensFiles`
    /// files' HEAD positions (k of them for the lens edits, 1 for the one-edit shape).
    function _edits(string memory shape, uint256 lens) internal returns (Spend memory) {
        uint256 k = _k(shape);
        uint256 n = k + 1 > 32 ? 32 : k + 1;
        (bytes32[] memory f, bytes32[] memory root) = _filesWithRoots("ed-", n);
        Action[] memory all = new Action[](0);
        bytes[] memory bodies = new bytes[](0);
        bytes32[] memory pos = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            (Action[] memory x, bytes[] memory y,) =
                EfsFiles.edit(_filesTypes(), f[i], root[i], "Meeting at 10:00.\n", 1);
            assertEq(y[0].length, 114);
            (all, bodies) = EfsFiles.concat(all, bodies, x, y);
            pos[i] = Keys.position(Purpose.HEAD, f[i], 0);
        }
        uint256 m = (k + 1) * 2 > 64 ? 65 : (k + 1) * 2;
        if (m > all.length) m = all.length;
        (Action[] memory a, bytes[] memory b) = _slice(all, bodies, k * 2);
        (Action[] memory a1, bytes[] memory b1) = _slice(all, bodies, m);
        if (lens == 0) return _proveG(shape, a, b, "", a1, b1, "");
        bytes32[] memory pr = new bytes32[](64);
        pr[0] = p;
        uint256 files = lens == 1 ? 1 : n;
        for (uint256 i = 1; i < 64; ++i) {
            address who = _lensAuthor(i);
            pr[i] = Keys.principal(who);
            Action[] memory h = new Action[](files);
            for (uint256 j; j < files; ++j) {
                h[j] = EfsFiles.bind(Purpose.HEAD, f[j], 0, root[j], 0);
            }
            _send(who, h, _bodies(files));
        }
        uint256 gk = lens == 1 ? 1 : k;
        _assertGuardShape(shape, "guard", 64, gk);
        bytes memory g = _guardOf(pr, _firstN(pos, gk));
        bytes memory g1 = lens == 1 ? bytes("") : _guardOf(pr, _firstN(pos, k + 1));
        return _proveG(shape, a, b, g, a1, b1, g1);
    }

    function _firstN(bytes32[] memory l, uint256 n) internal pure returns (bytes32[] memory x) {
        x = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            x[i] = l[i];
        }
    }

    function test_plan_edits() public {
        _covers(_edits("edits", 0), false);
    }

    function test_plan_edits_lens_guarded() public {
        _covers(_edits("editsLensGuarded", 2), false);
    }

    function test_plan_edit_lens_one_guarded() public {
        _covers(_edits("editsLensOneGuarded", 1), false);
    }

    /// k CREATEs, unguarded or guarded over `principals` × 128 BOUND TAG heads none of them writes (the author's tags
    /// on the one-word topic, and OTHER's at the same positions).
    function _creates(string memory shape, uint256 principals) internal returns (Spend memory) {
        uint256 k = _k(shape);
        Action[] memory all = new Action[](65);
        for (uint256 i; i < 65; ++i) {
            all[i] = _create(keccak256(abi.encode("floor-plan create", i)));
        }
        uint256 m = k + 1 > 64 ? 65 : k + 1;
        if (principals == 0) {
            return _proveG(shape, _prefix(all, k), _bodies(k), "", _prefix(all, m), _bodies(m), "");
        }
        Action[] memory t = new Action[](128);
        bytes32[] memory pos = new bytes32[](128);
        for (uint256 i; i < 128; ++i) {
            t[i] = EfsTopics.tag(topic, _thing("guard maxima", i), 0, 0);
            pos[i] = Keys.position(Purpose.TAG, topic, _thing("guard maxima", i));
        }
        _sendSliced(address(this), t, _bodies(128), 32);
        bytes32[] memory pr = new bytes32[](principals);
        pr[0] = p;
        if (principals == 2) {
            _sendSliced(OTHER, t, _bodies(128), 32);
            pr[1] = Keys.principal(OTHER);
        }
        _assertGuardShape(shape, "guard", principals, 128);
        bytes memory g = _guardOf(pr, pos);
        return _proveG(shape, _prefix(all, k), _bodies(k), g, _prefix(all, m), _bodies(m), g);
    }

    // The final phase of 64 CREATEs (the index's afterPublication over 64 new subjects) is above the final reserve,
    // which has terms for binds and publishes only (design §10.4; F covers 0.116 of it here): only the planner's E pays
    // it, as for create-file recipes and folder re-binds, so only the prefix quote is asserted.
    function test_plan_creates() public {
        _covers(_creates("creates", 0), false);
    }

    function test_plan_creates_guarded_1x128() public {
        _covers(_creates("createsGuarded1x128", 1), false);
    }

    function test_plan_creates_guarded_2x128() public {
        _covers(_creates("createsGuarded2x128", 2), false);
    }
}
