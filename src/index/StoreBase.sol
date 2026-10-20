// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {WriterRange} from "./storage/StoreStorage.sol";
import {ILedgerHot} from "../interfaces/ILedgerHot.sol";
import {Phase} from "../interfaces/Results.sol";
import {E_FAMILY, E_WRITER} from "../interfaces/Errors.sol";

/// @title StoreBase — the write authorization every per-Realm index store enforces (design §4.6)
/// @notice Let g = ledger.index() and phase = ledger.phase(). (1) msg.sender == g and phase != IDLE: a live
///         write (lazy attachment: the first live write opens g's writers range and sets `attached`);
///         (2) msg.sender == g and phase == IDLE: backfill only (BitmapStore); (3) msg.sender == INITIAL_WRITER
///         != 0, not attached, phase IDLE: build or replay writes. Nothing else writes. Family membership is
///         checked on every write (E_FAMILY).
abstract contract StoreBase {
    address public immutable LEDGER;
    address public immutable INITIAL_WRITER;

    uint8 internal constant MODE_LIVE = 1;
    uint8 internal constant MODE_BACKFILL = 2;
    uint8 internal constant MODE_BUILD = 3;

    constructor(address ledger_, address initialWriter_) {
        LEDGER = ledger_;
        INITIAL_WRITER = initialWriter_;
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
        WriterRange[] storage w = _writers();
        uint256 n = w.length;
        if (n != 0 && w[n - 1].generation == g && w[n - 1].toAdmission == 0) return;
        if (n != 0 && w[n - 1].toAdmission == 0) {
            w[n - 1].toAdmission = admission == 0 ? 0 : admission - 1;
        }
        w.push(WriterRange(g, admission, 0));
        if (!_attached()) _setAttached();
    }

    function _requireFamily(bytes32 family) internal view {
        bytes32[] storage ids = _familyIds();
        for (uint256 i; i < ids.length; ++i) {
            if (ids[i] == family) return;
        }
        revert E_FAMILY(family);
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
