// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @notice The three hot reads the stores consult (`index()`, `phase()`, `counts()`), settable by the test.
///         Nothing else: a store that reaches for any other ledger read fails loudly here.
contract LedgerStub {
    address public index;
    uint8 public phaseValue;
    uint64 public admissions;
    uint64 public publications;

    function set(address index_, uint8 phase_, uint64 admissions_, uint64 publications_) external {
        index = index_;
        phaseValue = phase_;
        admissions = admissions_;
        publications = publications_;
    }

    function phase() external view returns (uint8, uint64, uint64, uint32) {
        return (phaseValue, publications, admissions, 1);
    }

    function counts() external view returns (uint64, uint64, uint64, uint64) {
        return (admissions, 0, 0, publications);
    }
}
