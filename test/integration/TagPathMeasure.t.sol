// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {FilesRecipesBase} from "./FilesRecipesBase.sol";
import {Keys} from "../../src/lib/Keys.sol";
import {Action, ActionKind, FamilyId, Purpose, TypeId} from "../../src/interfaces/Actions.sol";
import {BasisCommit, Status} from "../../src/interfaces/Results.sol";
import {Cursor, Page} from "../../src/interfaces/Readers.sol";
import {LedgerReads} from "../../src/readers/LedgerReads.sol";
import {LedgerViews} from "../../src/readers/LedgerViews.sol";
import {LensReader} from "../../src/readers/LensReader.sol";

/// @notice Measurements for docs/TAG-OPTIONS.md, option (a): what the generic binding path that exists today costs
///         when it carries a tag. Nothing here defines a tag: the TAG purpose is an ordinary purpose to the kernel
///         and the generation-1 index, with no Type, rule or validator of its own. The shape measured is one
///         binding per (concept, target) pair: position `(TAG, concept, role = target)`, target = the tagged
///         subject. `concept` is an arbitrary 32-byte id (a position's subject need not exist; a target must).
///         Writes are cooled like `GasModel.t.sol`, so each publication pays what a transaction of its own pays.
///         Logs: `tag <key> gas` (and `frame state gas` under the amsterdam profile).
contract TagPathMeasureTest is FilesRecipesBase {
    uint256 internal constant N = 60;
    bytes32 internal constant X = keccak256("measure/concept/x");
    bytes32 internal constant Y = keccak256("measure/concept/y");

    address[] internal cold;
    bytes32[N] internal s; // CREATE subjects of p: the tagged things
    LensReader internal lens;

    function setUp() public override {
        super.setUp();
        lens = new LensReader(
            address(r.ledger), address(new LedgerViews()), address(new LedgerReads())
        );
        for (uint256 i; i < 10; ++i) {
            _remember(instances[i]);
        }
        _remember(address(validator));
        _remember(address(r.k.ingress));
        _remember(address(r.k.applyDelegate));
        _remember(address(r.k.control));
        _remember(address(r.k.implementation));
        _remember(r.k.proxy);
        _remember(address(r.g.posting));
        _remember(address(r.g.bitmap));
        _remember(address(r.g.index));
        _remember(address(r.registryImpl));
        _remember(address(r.registry));
        for (uint256 from; from < N; from += 20) {
            Action[] memory a = new Action[](20);
            for (uint256 i; i < 20; ++i) {
                a[i] = _create(keccak256(abi.encode("tagged", from + i)));
                s[from + i] = Keys.subject(p, a[i].salt);
            }
            r.ledger.execute(a, new bytes[](20), _ctx(a), "");
        }
    }

    function _remember(address a) internal {
        cold.push(a);
    }

    function _cool() internal {
        for (uint256 i; i < cold.length; ++i) {
            vm.cool(cold[i]);
        }
        vm.cool(address(lens));
    }

    function _beforeExecute() internal override {
        _cool();
    }

    function _tags(bytes32 concept, uint256 from, uint256 n)
        internal
        view
        returns (Action[] memory a)
    {
        a = new Action[](n);
        for (uint256 i; i < n; ++i) {
            a[i] = _bind(Purpose.TAG, concept, s[from + i], s[from + i], 0);
        }
    }

    function _run(string memory key, Action[] memory a) internal {
        _exec(string.concat("tag ", key), a, new bytes[](a.length));
    }

    function _silent(Action[] memory a) internal {
        r.ledger.execute(a, new bytes[](a.length), _ctx(a), "");
    }

    function _one(Action memory x) internal pure returns (Action[] memory a) {
        a = new Action[](1);
        a[0] = x;
    }

    // ---- writes -----------------------------------------------------------------------------------------------

    /// One tag alone, two in one publication, ten in one publication (the first members of a concept).
    function test_assert() public {
        _run("assert k1", _tags(X, 0, 1));
        _run("assert k2", _tags(X, 1, 2));
        _run("assert k10", _tags(X, 3, 10));
        _run("assert k40", _tags(X, 13, 40));
    }

    /// The other key order: position (TAG, target, role = concept). Same kernel work, other lists.
    function test_assert_keyed_by_target() public {
        Action[] memory a = new Action[](1);
        a[0] = _bind(Purpose.TAG, s[0], X, s[0], 0);
        _run("assert by-target k1", a);
        a = new Action[](2);
        a[0] = _bind(Purpose.TAG, s[1], X, s[1], 0);
        a[1] = _bind(Purpose.TAG, s[2], X, s[2], 0);
        _run("assert by-target k2", a);
    }

    /// Deny after an assertion (UNBIND = mask), assert again, deny, then back to silent (RELEASE).
    function test_deny_reassert_silent() public {
        _silent(_tags(X, 0, 3));
        bytes32 key = Keys.binding(p, Keys.position(Purpose.TAG, X, s[0]));
        (, uint64 rev,,,,,) = r.hot.head(key);
        _run(
            "deny (mask an assertion)",
            _one(_bindKind(ActionKind.UNBIND, Purpose.TAG, X, s[0], 0, rev))
        );
        (, rev,,,,,) = r.hot.head(key);
        _run("re-assert a denied tag", _one(_bind(Purpose.TAG, X, s[0], s[0], rev)));
        (, rev,,,,,) = r.hot.head(key);
        _silent(_one(_bindKind(ActionKind.UNBIND, Purpose.TAG, X, s[0], 0, rev)));
        (, rev,,,,,) = r.hot.head(key);
        _run(
            "silent again (release a denial)",
            _one(_bindKind(ActionKind.RELEASE, Purpose.TAG, X, s[0], 0, rev))
        );
    }

    /// A denial of something this author never asserted: the kernel masks only a BOUND head, so it is refused
    /// alone and costs an assertion plus a mask (measured in one publication if the kernel takes both, else two).
    function test_deny_without_a_prior_assertion() public {
        Action[] memory a = _one(_bindKind(ActionKind.UNBIND, Purpose.TAG, X, s[5], 0, 0));
        bytes[] memory b = new bytes[](1);
        try r.ledger.execute(a, b, _ctx(a), "") {
            emit log_named_uint("tag deny from silent: accepted alone", 1);
        } catch {
            emit log_named_uint("tag deny from silent: accepted alone", 0);
        }
        a = new Action[](2);
        a[0] = _bind(Purpose.TAG, X, s[5], s[5], 0);
        a[1] = _bindKind(ActionKind.UNBIND, Purpose.TAG, X, s[5], 0, 1);
        b = new bytes[](2);
        try this.both(a, b) {
            emit log_named_uint("tag deny from silent: one publication of two actions", 1);
        } catch {
            emit log_named_uint("tag deny from silent: one publication of two actions", 0);
            _run("deny from silent, step 1 (assert)", _one(a[0]));
            (, uint64 rev,,,,,) = r.hot.head(Keys.binding(p, Keys.position(Purpose.TAG, X, s[5])));
            _run(
                "deny from silent, step 2 (mask)",
                _one(_bindKind(ActionKind.UNBIND, Purpose.TAG, X, s[5], 0, rev))
            );
        }
    }

    function both(Action[] calldata a, bytes[] calldata b) external {
        require(msg.sender == address(this));
        _exec("tag deny from silent (assert + mask in one publication)", a, b);
    }

    // ---- reads ------------------------------------------------------------------------------------------------

    function _members(uint32 budget)
        internal
        returns (uint256 gasUsed, uint256 rows, uint8 scanStatus)
    {
        bytes32[] memory l = new bytes32[](1);
        l[0] = p;
        Cursor memory c;
        BasisCommit memory b;
        _cool();
        uint256 before = gasleft();
        Page memory page = lens.list(l, Purpose.TAG, X, c, budget, 1, b);
        gasUsed = before - gasleft();
        assertEq(uint8(page.q.status), uint8(Status.PRESENT));
        return (gasUsed, page.rows.length, page.scanStatus);
    }

    /// "Everything tagged X by this author", one lens principal, in pages of 10 and 50, 53 members with 3 denied.
    function test_read_members_of_a_concept() public {
        _silent(_tags(X, 0, 20));
        _silent(_tags(X, 20, 20));
        _silent(_tags(X, 40, 13));
        for (uint256 i; i < 3; ++i) {
            _silent(_one(_bindKind(ActionKind.UNBIND, Purpose.TAG, X, s[i * 7], 0, 1)));
        }
        (uint256 g, uint256 rows, uint8 scan) = _members(10);
        emit log_named_uint("tag read members: page of 10, gas", g);
        emit log_named_uint("tag read members: page of 10, rows", rows);
        (g, rows, scan) = _members(50);
        emit log_named_uint("tag read members: page of 50, gas", g);
        emit log_named_uint("tag read members: page of 50, rows", rows);
        emit log_named_uint("tag read members: page of 50, scan status", scan);
    }

    /// "Which concepts did this author put on this target": the role-scope list of (author, TAG, role = target),
    /// then one head read per entry to see whether it is still asserted.
    function test_read_concepts_on_a_target() public {
        bytes32 target = s[0];
        Action[] memory a = new Action[](8);
        for (uint256 i; i < 8; ++i) {
            a[i] = _bind(Purpose.TAG, keccak256(abi.encode("concept", i)), target, target, 0);
        }
        _silent(a);
        _cool();
        uint256 before = gasleft();
        (, uint64[] memory entries,) = r.g.index
            .postingSliceOf(
                FamilyId.wrap(Keys.familyId("role-scope")),
                TypeId.wrap(0),
                0,
                Keys.roleScope(p, Purpose.TAG, target),
                0,
                16
            );
        uint256 listGas = before - gasleft();
        emit log_named_uint("tag read concepts on a target: role-scope entries", entries.length);
        emit log_named_uint("tag read concepts on a target: list gas", listGas);
        before = gasleft();
        for (uint256 i; i < 8; ++i) {
            bytes32 key = Keys.binding(
                p, Keys.position(Purpose.TAG, keccak256(abi.encode("concept", i)), target)
            );
            (uint8 state,,,,,,) = r.hot.head(key);
            assertEq(state, 1);
        }
        emit log_named_uint("tag read concepts on a target: 8 head reads gas", before - gasleft());
    }

    /// "Is this target tagged X" for one author: one head read, cold.
    function test_read_one_membership() public {
        _silent(_tags(X, 0, 1));
        bytes32 key = Keys.binding(p, Keys.position(Purpose.TAG, X, s[0]));
        _cool();
        uint256 before = gasleft();
        (uint8 state,,,,,,) = r.hot.head(key);
        emit log_named_uint("tag read one membership: head gas", before - gasleft());
        assertEq(state, 1);
        Y; // the second concept id is reserved for a later row
    }
}
