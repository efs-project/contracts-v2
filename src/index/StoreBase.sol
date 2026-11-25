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
///         checked on every write and every batch entry (E_FAMILY) against the store's constructor-fixed family
///         set, held as immutables by the concrete store (`_isFamily`), so the check reads no storage.
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
    /// Whether `family` is in the constructor's family set (exact; never true for 0). The concrete store answers
    /// from immutables.
    function _isFamily(bytes32 family) internal view virtual returns (bool);
    function _writers() internal view virtual returns (WriterRange[] storage);
    function _attached() internal view virtual returns (bool);
    function _setAttached() internal virtual;

    /// Returns the mode the caller is allowed to write in and the current admission frontier.
    function _authorize(bytes32 family) internal returns (uint8 mode, uint48 admission) {
        _requireFamily(family);
        return _authorizeWriter();
    }

    /// The writer rule alone (no family): three hot reads of the ledger, and the lazy attachment of a live writer.
    /// Within one call none of its inputs changes after the first answer (the ledger is not re-entered and the
    /// attachment is idempotent), so a batch asks it once.
    function _authorizeWriter() internal returns (uint8 mode, uint48 admission) {
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
        if (!_isFamily(family)) revert E_FAMILY(family);
    }

    /// The constructor's family list as the store holds it: at most `capacity` ids, none zero (`E_FAMILY`), so
    /// the zero padding of unused immutables never matches a family.
    function _checkFamilies(bytes32[] memory families, uint256 capacity) internal pure {
        if (families.length > capacity) revert E_FAMILY(bytes32(families.length));
        for (uint256 i; i < families.length; ++i) {
            if (families[i] == 0) revert E_FAMILY(0);
        }
    }

    function _familyAt(bytes32[] memory families, uint256 i) internal pure returns (bytes32) {
        return i < families.length ? families[i] : bytes32(0);
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
