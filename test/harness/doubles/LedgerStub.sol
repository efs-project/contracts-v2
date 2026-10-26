// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @notice The hot reads the stores and the registry consult (`index()`, `phase()`, `counts()`, `controller()`,
///         `control()`), settable by the test. Nothing else: a unit that reaches for any other ledger read
///         fails loudly here.
contract LedgerStub {
    address public index;
    address public controller;
    uint8 public phaseValue;
    uint64 public admissions;
    uint64 public publications;
    uint32 public revision;
    bool public frozen;

    function set(address index_, uint8 phase_, uint64 admissions_, uint64 publications_) external {
        index = index_;
        phaseValue = phase_;
        admissions = admissions_;
        publications = publications_;
    }

    function setController(address controller_) external {
        controller = controller_;
    }

    function setFrozen(bool frozen_) external {
        frozen = frozen_;
    }

    function setPhase(uint8 phase_) external {
        phaseValue = phase_;
    }

    function phase() external view returns (uint8, uint64, uint64, uint32) {
        return (phaseValue, publications, admissions, revision);
    }

    function counts() external view returns (uint64, uint64, uint64, uint64) {
        return (admissions, 0, 0, publications);
    }

    function control() external view returns (uint64, uint64, uint32, bool) {
        return (uint64(block.chainid), uint64(block.chainid), revision, frozen);
    }
}
