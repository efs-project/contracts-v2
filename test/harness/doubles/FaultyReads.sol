// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ILedgerHot} from "../../../src/interfaces/ILedgerHot.sol";

/// @notice A read wrapper over a real contract (normally a ledger proxy) that forwards every read faithfully
///         until a fault is armed for a selector, then corrupts that selector's reply (design §2.2 S13, §16
///         preamble: "`FaultyReads` generalized over every reader interface"). Use it as `ILedgerHot(faulty)`:
///         its fallback forwards every selector it does not define, so every Etched hot getter (including
///         any a later `HOT_ABI_ID` adds) passes through it, and one instance in front of a facet
///         (`ILedgerReads`/`ILedgerViews`), an index (`IIndexReads`) or a store serves the same table.
///         Reads only: replies come from `STATICCALL`; a state-changing selector fails as the target would
///         under a static context. Its own selectors (`setFault`, `setMode`, `clear`, `setRevertData`,
///         `setBasis`, `capture`, `faultOf`, `real`, `basis` and the mode constants) are not forwarded.
/// @dev The generalization of the prototype's 22 fixed fault modes (`lab-b/test/FaultyReads.sol`) into
///      per-selector primitives over the raw reply words (word i = bytes [32i, 32i + 32) of the ABI reply):
///
///      | mode             | reply                                                           | prototype modes   |
///      |------------------|-----------------------------------------------------------------|-------------------|
///      | NONE             | the real reply                                                  | 0                 |
///      | REVERT           | reverts with `setRevertData` bytes (empty by default)           | (new)             |
///      | SHORT            | the first `value` bytes of the real reply                       | 5 SHORT_EVIDENCE  |
///      | EXTRA            | the real reply followed by `value` zero bytes                   | (new)             |
///      | SET_WORD         | word `word` := `value`                                          | 2, 3, 4, 6, 8, 10, 12, 14, 16, 17, 20–22 |
///      | ADD_WORD         | word `word` += `value` (wrapping, so `type(uint256).max` is −1) | 7, 15, 18, 19     |
///      | ZERO             | a reply of the same length, all zero                            | 1 MISSING_PAIR    |
///      | STALE            | the reply captured by `capture(query)` for this exact query     | (new: stale basis)|
///      | FUTURE_ADMISSION | word `word` := `counts().admissions` of `basis` + `value`       | 9, 11, 13         |
///      | EXHAUST          | consumes all forwarded gas (`INVALID`), empty returndata        | (new)             |
///      | EMPTY            | succeeds with zero bytes                                        | (new)             |
///
///      A fault can be filtered to calls whose first argument word equals `arg0` (the prototype's
///      `record(target)` pattern); other calls of that selector stay faithful. A real revert is bubbled
///      unchanged in every mode but STALE, REVERT, EXHAUST and EMPTY, which never call the target.
contract FaultyReads {
    uint8 public constant NONE = 0;
    uint8 public constant REVERT = 1;
    uint8 public constant SHORT = 2;
    uint8 public constant EXTRA = 3;
    uint8 public constant SET_WORD = 4;
    uint8 public constant ADD_WORD = 5;
    uint8 public constant ZERO = 6;
    uint8 public constant STALE = 7;
    uint8 public constant FUTURE_ADMISSION = 8;
    uint8 public constant EXHAUST = 9;
    uint8 public constant EMPTY = 10;

    struct Fault {
        uint8 mode;
        uint16 word;
        bool filtered;
        bytes32 arg0;
        uint256 value;
    }

    error FaultyNoCapture(bytes4 selector, bytes32 queryHash);
    error FaultyWord(bytes4 selector, uint256 word, uint256 replyLength);

    address public immutable real;
    /// The ledger whose `counts()` defines "future" for FUTURE_ADMISSION (initially `real`).
    address public basis;
    mapping(bytes4 => Fault) internal _faults;
    mapping(bytes4 => bytes) internal _revertData;
    mapping(bytes32 => bytes) internal _stale;
    mapping(bytes32 => bool) internal _captured;

    constructor(address real_) {
        real = real_;
        basis = real_;
    }

    // ---- configuration ----------------------------------------------------------------------------------------

    function setFault(bytes4 selector, Fault calldata f) external {
        _faults[selector] = f;
    }

    /// Arms `mode` for every call of `selector`, with word 0 and value 0.
    function setMode(bytes4 selector, uint8 mode) external {
        _faults[selector] = Fault(mode, 0, false, bytes32(0), 0);
    }

    function clear(bytes4 selector) external {
        delete _faults[selector];
    }

    function setRevertData(bytes4 selector, bytes calldata data) external {
        _revertData[selector] = data;
    }

    function setBasis(address basis_) external {
        basis = basis_;
    }

    /// Records the real reply to `query` (full calldata) for STALE mode, and returns it.
    function capture(bytes calldata query) external returns (bytes memory reply) {
        bool ok;
        (ok, reply) = real.staticcall(query);
        if (!ok) _bubble(reply);
        bytes32 q = keccak256(query);
        _stale[q] = reply;
        _captured[q] = true;
    }

    function faultOf(bytes4 selector) external view returns (Fault memory) {
        return _faults[selector];
    }

    // ---- every read selector of `real` (all of ILedgerHot, and any other read interface) ---------------------

    fallback() external {
        _relay();
    }

    // ---- the relay -----------------------------------------------------------------------------------------------

    function _relay() internal view {
        Fault memory f = _faults[msg.sig];
        uint8 mode = f.mode;
        if (mode != NONE && f.filtered && _arg0() != f.arg0) mode = NONE;
        if (mode == EXHAUST) {
            assembly {
                invalid()
            }
        }
        if (mode == REVERT) _bubble(_revertData[msg.sig]);
        if (mode == EMPTY) {
            assembly {
                return(0, 0)
            }
        }
        bytes memory reply;
        if (mode == STALE) {
            bytes32 q = keccak256(msg.data);
            if (!_captured[q]) revert FaultyNoCapture(msg.sig, q);
            reply = _stale[q];
        } else {
            bool ok;
            (ok, reply) = real.staticcall(msg.data);
            if (!ok) _bubble(reply);
            if (mode == SHORT) {
                uint256 n = f.value;
                if (n < reply.length) {
                    assembly ("memory-safe") {
                        mstore(reply, n)
                    }
                }
            } else if (mode == EXTRA) {
                reply = bytes.concat(reply, new bytes(f.value));
            } else if (mode == ZERO) {
                reply = new bytes(reply.length);
            } else if (mode == SET_WORD) {
                _setWord(reply, f.word, f.value);
            } else if (mode == ADD_WORD) {
                unchecked {
                    _setWord(reply, f.word, uint256(_word(reply, f.word)) + f.value);
                }
            } else if (mode == FUTURE_ADMISSION) {
                (uint64 admissions,,,) = ILedgerHot(basis).counts();
                _setWord(reply, f.word, uint256(admissions) + f.value);
            }
        }
        assembly ("memory-safe") {
            return(add(reply, 0x20), mload(reply))
        }
    }

    function _arg0() private pure returns (bytes32 a) {
        if (msg.data.length < 36) return bytes32(0);
        assembly ("memory-safe") {
            a := calldataload(4)
        }
    }

    function _word(bytes memory reply, uint256 i) private pure returns (bytes32 w) {
        if ((i + 1) * 32 > reply.length) revert FaultyWord(msg.sig, i, reply.length);
        assembly ("memory-safe") {
            w := mload(add(add(reply, 0x20), mul(i, 0x20)))
        }
    }

    function _setWord(bytes memory reply, uint256 i, uint256 value) private pure {
        if ((i + 1) * 32 > reply.length) revert FaultyWord(msg.sig, i, reply.length);
        assembly ("memory-safe") {
            mstore(add(add(reply, 0x20), mul(i, 0x20)), value)
        }
    }

    function _bubble(bytes memory data) private pure {
        assembly ("memory-safe") {
            revert(add(data, 0x20), mload(data))
        }
    }
}
