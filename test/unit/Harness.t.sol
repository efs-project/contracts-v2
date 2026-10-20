// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test, Vm} from "forge-std/Test.sol";
import {StateDigest} from "../harness/StateDigest.sol";
import {ZeroWrite} from "../harness/ZeroWrite.sol";
import {LedgerStorage} from "../../src/core/storage/LedgerStorage.sol";

contract DigestFixture is LedgerStorage {
    function touchRecord(bytes32 id, uint32 len, bytes32 w0) external {
        RecordCell storage c = _records().cells[id];
        c.typeId = keccak256("t");
        c.length = len;
        _records().bodyWords[id][0] = w0;
    }

    function mask(bytes32 key) external {
        _bindings().heads[key].state = 2; // keep the target word
    }

    function bind(bytes32 key, bytes32 target) external {
        HeadRow storage h = _bindings().heads[key];
        h.state = 1;
        h.target = target;
    }

    function bumpCounter() external {
        _counters().admissions += 1;
    }
}

contract Writer {
    uint256 public x;

    function write(uint256 v) external {
        x = v;
    }

    function noop() external pure {}
}

contract Delegator {
    function go(address target, bytes calldata data) external returns (bytes memory r) {
        bool ok;
        (ok, r) = target.delegatecall(data);
        require(ok, "delegatecall failed");
    }
}

contract HarnessTest is Test {
    using StateDigest for address;

    DigestFixture internal f = new DigestFixture();

    function keysFor(bytes32 id, bytes32 key)
        internal
        pure
        returns (StateDigest.LedgerKeys memory k)
    {
        k.recordIds = new bytes32[](1);
        k.recordIds[0] = id;
        k.bindingKeys = new bytes32[](1);
        k.bindingKeys[0] = key;
    }

    function testDigestTracksOnlyTrackedRowsAndProjectsHeads() public {
        bytes32 id = keccak256("r");
        bytes32 key = keccak256("k");
        StateDigest.LedgerKeys memory k = keysFor(id, key);
        bytes32 d0 = StateDigest.ledger(address(f), k);
        f.touchRecord(id, 40, bytes32(uint256(1)));
        bytes32 d1 = StateDigest.ledger(address(f), k);
        assertTrue(d1 != d0, "record write changes the digest");
        f.touchRecord(keccak256("other"), 40, bytes32(uint256(1)));
        assertEq(StateDigest.ledger(address(f), k), d1, "untracked record does not");
        f.bind(key, bytes32(uint256(9)));
        bytes32 d2 = StateDigest.ledger(address(f), k);
        assertTrue(d2 != d1, "bind changes the digest");
        f.mask(key);
        bytes32 d3 = StateDigest.ledger(address(f), k);
        assertTrue(d3 != d2, "mask changes the digest");
        // canonical projection: a masked head with a kept target digests like a masked head with none
        DigestFixture g = new DigestFixture();
        g.touchRecord(id, 40, bytes32(uint256(1)));
        g.mask(key);
        assertEq(StateDigest.ledger(address(g), k), d3, "kept target word is projected away");
        f.bumpCounter();
        assertTrue(StateDigest.ledger(address(f), k) != d3, "counters are part of the realm digest");
    }

    function testZeroWriteCatchesDelegateWrites() public {
        Writer w = new Writer();
        Delegator d = new Delegator();
        vm.startStateDiffRecording();
        d.go(address(w), abi.encodeCall(Writer.noop, ()));
        Vm.AccountAccess[] memory clean = vm.stopAndReturnStateDiff();
        ZeroWrite.assertOnly(clean, address(0));
        assertEq(ZeroWrite.writesOn(clean, address(d)), 0);

        vm.startStateDiffRecording();
        d.go(address(w), abi.encodeCall(Writer.write, (7)));
        Vm.AccountAccess[] memory dirty = vm.stopAndReturnStateDiff();
        assertEq(
            ZeroWrite.writesOn(dirty, address(d)), 1, "the delegatecall wrote the caller's storage"
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                ZeroWrite.UnexpectedWrite.selector,
                address(d),
                bytes32(0),
                bytes32(0),
                bytes32(uint256(7))
            )
        );
        this.assertOnlyExternal(dirty, address(0));
        ZeroWrite.assertOnly(dirty, address(d)); // allowed target passes
        vm.expectRevert();
        this.assertNoneOnExternal(dirty, address(d));
    }

    function assertOnlyExternal(Vm.AccountAccess[] memory a, address allowed) external pure {
        ZeroWrite.assertOnly(a, allowed);
    }

    function assertNoneOnExternal(Vm.AccountAccess[] memory a, address forbidden) external pure {
        ZeroWrite.assertNoneOn(a, forbidden);
    }
}
