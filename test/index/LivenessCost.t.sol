// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test, Vm} from "forge-std/Test.sol";
import {KernelDeploy} from "../harness/KernelDeploy.sol";
import {ManifestCopy} from "../harness/ManifestCopy.sol";
import {IndexDoubleDefaults} from "../harness/doubles/IndexDoubles.sol";
import {PostingStore} from "../../src/index/PostingStore.sol";
import {BitmapStore} from "../../src/index/BitmapStore.sol";
import {IndexReads} from "../../src/index/IndexReads.sol";
import {IndexDeploy} from "../harness/IndexDeploy.sol";
import {Purpose} from "../../src/interfaces/Actions.sol";
import {DigestSpec, Unit} from "../../src/interfaces/Index.sol";

/// The two forms measured for the copy of the live index's manifest (docs INDEX-BUILD §10): (a) a `bytes` value in
/// the reads contract's storage, (b) the code of a data contract (one STOP byte, then the copy) bound by address and
/// codehash, as `IndexReads` now holds it. Each holder does only what that form adds to the reads contract.
contract CopyInStorage {
    bytes internal _copy;

    constructor(bytes memory copy_) {
        _copy = copy_;
    }

    function copy() external view returns (bytes memory) {
        return _copy;
    }
}

contract CopyInCode {
    address public immutable DATA;
    bytes32 public immutable CODEHASH;

    constructor(bytes memory c) {
        address data;
        if (c.length != 0) {
            bytes memory init = abi.encodePacked(
                hex"61", uint16(c.length + 1), hex"80600c6000396000f3", hex"00", c
            );
            assembly ("memory-safe") {
                data := create(0, add(init, 32), mload(init))
            }
            require(data != address(0));
        }
        DATA = data;
        CODEHASH = data.codehash;
    }

    function copy() external view returns (bytes memory out) {
        address data = DATA;
        if (data == address(0) || data.codehash != CODEHASH) return out;
        uint256 n = data.code.length - 1;
        out = new bytes(n);
        assembly ("memory-safe") {
            extcodecopy(data, add(out, 32), 1, n)
        }
    }
}

/// Creates from initcode, so each deployment is one call frame (`vm.lastFrameGas`).
contract Creator {
    function create(bytes memory initcode) external returns (address a) {
        assembly ("memory-safe") {
            a := create(0, add(initcode, 32), mload(initcode))
        }
        require(a != address(0), "create");
    }
}

/// @notice Logs the gas of both forms on the running schedule (run once on the default profile and once on
///         amsterdam): deployment (execution and state gas, as `vm.lastFrameGas` reports them) of the copy alone (the
///         holder with the copy minus the holder with an empty one) and the cold read of the copy, for a copy of the
///         shape of the release's generation 1 (19 families, one final-hook unit with no family ids, two digest specs)
///         for a plausible later generation (40 families, 6 units) and for 58 families. Also the real `IndexReads` with and without the copy.
contract LivenessCostTest is Test {
    Creator internal creator;

    function setUp() public {
        creator = new Creator();
    }

    function _copy(uint256 extraFamilies) internal returns (bytes memory c) {
        return _copy(extraFamilies, 1);
    }

    /// A copy with `nUnits` final-hook units (each with one family id when more than one) and 18 + `extraFamilies`
    /// families (generation 1 declares 18).
    function _copy(uint256 extraFamilies, uint256 nUnits) internal returns (bytes memory c) {
        address ledger = address(0x1ED6E);
        PostingStore p = new PostingStore(ledger, address(0), IndexDeploy.postingFamilies());
        BitmapStore bm = new BitmapStore(ledger, address(0), IndexDeploy.bitmapFamilies());
        Unit[] memory units = new Unit[](nUnits);
        for (uint256 i; i < nUnits; ++i) {
            units[i] = Unit({
                foldHook: address(0),
                foldCodehash: 0,
                finalHook: address(0xF1),
                finalCodehash: keccak256("final"),
                familyIds: new bytes32[](nUnits == 1 ? 0 : 1),
                purposeFilter: Purpose.FOLDER,
                hotAbiId: KernelDeploy.HOT_ABI_ID,
                identity: keccak256("validator")
            });
        }
        DigestSpec[] memory specs = new DigestSpec[](2);
        specs[0] = DigestSpec({typeId: keccak256("content"), wordIndex: 5, algorithm: 1});
        specs[1] = DigestSpec({typeId: keccak256("external"), wordIndex: 5, algorithm: 1});
        IndexReads r = new IndexReads(
            ledger,
            KernelDeploy.HOT_ABI_ID,
            address(p),
            address(bm),
            units,
            specs,
            IndexDoubleDefaults.workModel(),
            0,
            0,
            ""
        );
        c = ManifestCopy.ofReads(address(r));
        // more families: the ABI growth is exact (320 B a family, 10 words), so the larger copy is padded to that
        // length rather than re-encoded; these measure size and gas, not decoding
        if (extraFamilies != 0) {
            // nonzero padding: a family entry's words are nonzero (ids, hashes, a store address), and a zero word
            // would cost storage nothing
            bytes memory pad = new bytes(320 * extraFamilies);
            for (uint256 i; i < pad.length; ++i) {
                pad[i] = 0x5a;
            }
            c = bytes.concat(c, pad);
        }
    }

    function _deploy(bytes memory initcode) internal returns (address a, uint256 exec, int256 st) {
        a = creator.create(initcode);
        Vm.Gas memory g = vm.lastFrameGas();
        exec = g.gasTotalUsed;
        st = g.gasStateUsed;
    }

    function _read(address holder, address data) internal returns (uint256) {
        vm.cool(holder);
        if (data != address(0)) vm.cool(data);
        CopyInStorage(holder).copy();
        return vm.lastFrameGas().gasTotalUsed;
    }

    function _measure(string memory label, bytes memory c) internal {
        emit log_named_uint(string.concat(label, " copy bytes"), c.length);
        (address s0, uint256 se0, int256 ss0) =
            _deploy(bytes.concat(type(CopyInStorage).creationCode, abi.encode(bytes(""))));
        (address s1, uint256 se1, int256 ss1) =
            _deploy(bytes.concat(type(CopyInStorage).creationCode, abi.encode(c)));
        (address c0, uint256 ce0, int256 cs0) =
            _deploy(bytes.concat(type(CopyInCode).creationCode, abi.encode(bytes(""))));
        (address c1, uint256 ce1, int256 cs1) =
            _deploy(bytes.concat(type(CopyInCode).creationCode, abi.encode(c)));
        emit log_named_uint(string.concat(label, " (a) storage deploy exec gas"), se1 - se0);
        emit log_named_int(string.concat(label, " (a) storage deploy state gas"), ss1 - ss0);
        emit log_named_uint(string.concat(label, " (b) code deploy exec gas"), ce1 - ce0);
        emit log_named_int(string.concat(label, " (b) code deploy state gas"), cs1 - cs0);
        uint256 rs1 = _read(s1, address(0));
        uint256 rs0 = _read(s0, address(0));
        uint256 rc1 = _read(c1, CopyInCode(c1).DATA());
        uint256 rc0 = _read(c0, address(0));
        emit log_named_uint(string.concat(label, " (a) storage cold read gas"), rs1);
        emit log_named_uint(string.concat(label, " (a) storage cold read, empty"), rs0);
        emit log_named_uint(string.concat(label, " (b) code cold read gas"), rc1);
        emit log_named_uint(string.concat(label, " (b) code cold read, empty"), rc0);
        assertEq(keccak256(CopyInStorage(s1).copy()), keccak256(c));
        assertEq(keccak256(CopyInCode(c1).copy()), keccak256(c));
        emit log_named_uint(
            string.concat(label, " (a) holder runtime bytes"), address(s1).code.length
        );
        emit log_named_uint(
            string.concat(label, " (b) holder runtime bytes"), address(c1).code.length
        );
    }

    function test_log_the_cost_of_both_forms() public {
        _measure("gen1-shaped", _copy(0));
        _measure("40 families, 6 units", _copy(22, 6));
        _measure("58 families, 1 unit", _copy(40));
    }

    /// The real `IndexReads` (form (b)) with and without a copy of the release-shaped manifest.
    function test_log_the_real_reads_contract_with_a_copy() public {
        bytes memory c = _copy(0);
        address ledger = address(0x1ED6E);
        IndexDeploy.ReadsArgs memory x;
        x.ledger = ledger;
        x.hotAbiId = KernelDeploy.HOT_ABI_ID;
        x.posting = address(new PostingStore(ledger, address(0), IndexDeploy.postingFamilies()));
        x.bitmap = address(new BitmapStore(ledger, address(0), IndexDeploy.bitmapFamilies()));
        x.units = new Unit[](0);
        x.specs = new DigestSpec[](0);
        x.work = IndexDoubleDefaults.workModel();
        (, uint256 e0, int256 s0) = _deploy(_readsInit(x));
        x.liveManifest = c;
        (address r1, uint256 e1, int256 s1) = _deploy(_readsInit(x));
        emit log_named_uint("IndexReads + copy deploy exec gas (delta)", e1 - e0);
        emit log_named_int("IndexReads + copy deploy state gas (delta)", s1 - s0);
        vm.cool(r1);
        vm.cool(IndexReads(r1).LIVE_COPY());
        IndexReads(r1).liveManifestCopy();
        emit log_named_uint("IndexReads.liveManifestCopy cold", vm.lastFrameGas().gasTotalUsed);
    }

    function _readsInit(IndexDeploy.ReadsArgs memory x) internal pure returns (bytes memory code) {
        bytes memory encoded = abi.encode(x);
        bytes memory init = type(IndexReads).creationCode;
        code = new bytes(init.length + encoded.length - 32);
        assembly ("memory-safe") {
            mcopy(add(code, 32), add(init, 32), mload(init))
            mcopy(add(add(code, 32), mload(init)), add(encoded, 64), sub(mload(encoded), 32))
        }
    }
}
