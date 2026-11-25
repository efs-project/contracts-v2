// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {WriterRange} from "./storage/StoreStorage.sol";
import {ILedgerHot} from "../interfaces/ILedgerHot.sol";
import {Phase} from "../interfaces/Results.sol";
import {E_FAMILY, E_ORDER, E_WRITER} from "../interfaces/Errors.sol";

/// @title StoreBase — the write authorization every per-Realm index store enforces (design §4.6)
/// @notice Let g = ledger.index() and phase = ledger.phase(). (1) msg.sender == g and phase != IDLE: a live
///         write (lazy attachment: the first live write opens g's writers range and sets `attached`);
///         (2) msg.sender == g and phase == IDLE: backfill only (BitmapStore); (3) msg.sender == INITIAL_WRITER
///         != 0, not attached, phase IDLE: build or replay writes. Nothing else writes. Family membership is
///         checked on every write (E_FAMILY).
abstract contract StoreBase {
    address public immutable LEDGER;
    address public immutable INITIAL_WRITER;

    // SPIKE (tags-index2): the first 16 family ids as immutables, so a membership check reads no storage. The
    // storage array (`familyIds()`) keeps the same ids in the same order and is scanned only beyond 16, so the
    // accepted set is exactly the constructor's (the old check scanned the array: one SLOAD per element, cold at
    // the first write of a transaction — 2,100 gas per element up to the family's index).
    uint256 private immutable FAMILY_COUNT;
    bytes32 private immutable FAM0;
    bytes32 private immutable FAM1;
    bytes32 private immutable FAM2;
    bytes32 private immutable FAM3;
    bytes32 private immutable FAM4;
    bytes32 private immutable FAM5;
    bytes32 private immutable FAM6;
    bytes32 private immutable FAM7;
    bytes32 private immutable FAM8;
    bytes32 private immutable FAM9;
    bytes32 private immutable FAM10;
    bytes32 private immutable FAM11;
    bytes32 private immutable FAM12;
    bytes32 private immutable FAM13;
    bytes32 private immutable FAM14;
    bytes32 private immutable FAM15;

    uint8 internal constant MODE_LIVE = 1;
    uint8 internal constant MODE_BACKFILL = 2;
    uint8 internal constant MODE_BUILD = 3;

    constructor(address ledger_, address initialWriter_, bytes32[] memory families) {
        LEDGER = ledger_;
        INITIAL_WRITER = initialWriter_;
        uint256 n = families.length;
        FAMILY_COUNT = n;
        FAM0 = _at(families, 0);
        FAM1 = _at(families, 1);
        FAM2 = _at(families, 2);
        FAM3 = _at(families, 3);
        FAM4 = _at(families, 4);
        FAM5 = _at(families, 5);
        FAM6 = _at(families, 6);
        FAM7 = _at(families, 7);
        FAM8 = _at(families, 8);
        FAM9 = _at(families, 9);
        FAM10 = _at(families, 10);
        FAM11 = _at(families, 11);
        FAM12 = _at(families, 12);
        FAM13 = _at(families, 13);
        FAM14 = _at(families, 14);
        FAM15 = _at(families, 15);
    }

    function _at(bytes32[] memory f, uint256 i) private pure returns (bytes32) {
        return i < f.length ? f[i] : bytes32(0);
    }

    function _familyIds() internal view virtual returns (bytes32[] storage);
    function _writers() internal view virtual returns (WriterRange[] storage);
    function _attached() internal view virtual returns (bool);
    function _setAttached() internal virtual;

    /// Returns the mode the caller is allowed to write in and the current admission frontier.
    function _authorize(bytes32 family) internal returns (uint8 mode, uint48 admission) {
        _requireFamily(family);
        ILedgerHot hot = ILedgerHot(LEDGER);
        address g = hot.index();
        (uint8 phase,,,) = hot.phase();
        (uint64 admissions,,,) = hot.counts();
        admission = uint48(admissions);
        if (msg.sender == g) {
            if (phase != Phase.IDLE) {
                _attach(g, admission);
                return (MODE_LIVE, admission);
            }
            return (MODE_BACKFILL, admission);
        }
        if (
            msg.sender == INITIAL_WRITER && INITIAL_WRITER != address(0) && !_attached()
                && phase == Phase.IDLE
        ) {
            WriterRange[] storage w = _writers();
            if (w.length == 0) w.push(WriterRange(INITIAL_WRITER, 1, 0));
            return (MODE_BUILD, admission);
        }
        revert E_WRITER(msg.sender);
    }

    function _attach(address g, uint48 admission) private {
        if (!_attached()) _setAttached(); // the first live write attaches, even when the builder is the same generation
        WriterRange[] storage w = _writers();
        uint256 n = w.length;
        if (n != 0 && w[n - 1].generation == g && w[n - 1].toAdmission == 0) return;
        if (n != 0 && w[n - 1].toAdmission == 0) {
            w[n - 1].toAdmission = admission == 0 ? 0 : admission - 1;
        }
        w.push(WriterRange(g, admission, 0));
    }

    /// The admission a write stamps: a live write stamps the frontier exactly; a build or replay write
    /// stamps the admission it is folding, never beyond the frontier.
    function _stampAdmission(uint8 mode, uint48 frontier, uint64 admission)
        internal
        pure
        returns (uint48)
    {
        if (mode == MODE_LIVE ? admission != frontier : admission > frontier) {
            revert E_ORDER(frontier, admission);
        }
        return uint48(admission);
    }

    function _requireFamily(bytes32 family) internal view {
        uint256 n = FAMILY_COUNT;
        // a zero id is a member only when the constructor listed it (the padding of a short set is zero)
        if (family != 0 || n >= 16) {
            if (
                family == FAM0 || family == FAM1 || family == FAM2 || family == FAM3
                    || family == FAM4 || family == FAM5 || family == FAM6 || family == FAM7
                    || family == FAM8 || family == FAM9 || family == FAM10 || family == FAM11
                    || family == FAM12 || family == FAM13 || family == FAM14 || family == FAM15
            ) return;
        } else {
            for (uint256 i; i < n; ++i) {
                if (_at16(i) == 0) return;
            }
        }
        if (n > 16) {
            bytes32[] storage ids = _familyIds();
            for (uint256 i = 16; i < n; ++i) {
                if (ids[i] == family) return;
            }
        }
        revert E_FAMILY(family);
    }

    function _at16(uint256 i) private view returns (bytes32) {
        bytes32[16] memory f = [
            FAM0,
            FAM1,
            FAM2,
            FAM3,
            FAM4,
            FAM5,
            FAM6,
            FAM7,
            FAM8,
            FAM9,
            FAM10,
            FAM11,
            FAM12,
            FAM13,
            FAM14,
            FAM15
        ];
        return f[i];
    }

    function _writersView()
        internal
        view
        returns (address[] memory generations, uint64[] memory from, uint64[] memory to)
    {
        WriterRange[] storage w = _writers();
        generations = new address[](w.length);
        from = new uint64[](w.length);
        to = new uint64[](w.length);
        for (uint256 i; i < w.length; ++i) {
            generations[i] = w[i].generation;
            from[i] = w[i].fromAdmission;
            to[i] = w[i].toAdmission;
        }
    }
}
