// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {DigestSpec, Unit, WorkModel} from "../interfaces/Index.sol";
import {IRealmIndex} from "../interfaces/IRealmIndex.sol";
import {E_DEPLOYER} from "../interfaces/Errors.sol";

/// @title IndexDeployer — a later generation with its fresh stores, created by one contract's nonces (design §10.1, §8.2)
/// @notice The `RealmGenesis` pattern for an index generation that needs fresh stores: `run()` creates each fresh
///         store with `INITIAL_WRITER` = the nonce-predicted generation address, then the generation with the
///         stores' addresses, asserts every prediction and journals. The initcodes arrive in the call and are
///         pinned by `PLAN_HASH`, so this contract embeds no creation code (initcode budget) and a stranger's
///         run with the same plan yields the same addresses or reverts. A generation that only re-pins stores
///         needs no deployer: it is a plain CREATE2.
contract IndexDeployer {
    struct Plan {
        bytes32 hotAbiId;
        address decoder;
        /// A fresh PostingStore's creation code (constructor (ledger, initialWriter, families) appended here),
        /// or empty to reuse `posting`.
        bytes postingInitcode;
        bytes32[] postingFamilies;
        address posting;
        bytes bitmapInitcode;
        bytes32[] bitmapFamilies;
        address bitmap;
        /// The generation's creation code without constructor arguments; they are appended here.
        bytes generationInitcode;
        Unit[] units;
        DigestSpec[] specs;
        WorkModel work;
    }

    address public immutable LEDGER;
    bytes32 public immutable PLAN_HASH;

    address public generation;
    address public postingStore;
    address public bitmapStore;

    event IndexDeployed(address indexed generation, address postingStore, address bitmapStore);

    constructor(address ledger, bytes32 planHash) {
        LEDGER = ledger;
        PLAN_HASH = planHash;
    }

    function planHash(Plan calldata plan) public pure returns (bytes32) {
        return keccak256(abi.encode(plan));
    }

    /// The generation's address: after the fresh stores, by this contract's nonces.
    function predictGeneration(Plan calldata plan) public view returns (address) {
        uint8 fresh =
            (plan.postingInitcode.length != 0 ? 1 : 0) + (plan.bitmapInitcode.length != 0 ? 1 : 0);
        return _creation(fresh + 1);
    }

    function run(Plan calldata plan) external returns (address gen) {
        if (generation != address(0)) revert E_DEPLOYER(0);
        if (planHash(plan) != PLAN_HASH) revert E_DEPLOYER(1);
        address predicted = predictGeneration(plan);
        address posting = plan.posting;
        address bitmap = plan.bitmap;
        uint8 nonce = 1;
        if (plan.postingInitcode.length != 0) {
            posting = _create(
                bytes.concat(
                    plan.postingInitcode, abi.encode(LEDGER, predicted, plan.postingFamilies)
                )
            );
            if (posting != _creation(nonce++)) revert E_DEPLOYER(2);
        }
        if (plan.bitmapInitcode.length != 0) {
            bitmap = _create(
                bytes.concat(
                    plan.bitmapInitcode, abi.encode(LEDGER, predicted, plan.bitmapFamilies)
                )
            );
            if (bitmap != _creation(nonce++)) revert E_DEPLOYER(2);
        }
        gen = _create(
            bytes.concat(
                plan.generationInitcode,
                abi.encode(
                    LEDGER,
                    plan.hotAbiId,
                    plan.decoder,
                    posting,
                    bitmap,
                    plan.units,
                    plan.specs,
                    plan.work
                )
            )
        );
        if (gen != predicted) revert E_DEPLOYER(3);
        if (IRealmIndex(gen).replayReadiness().ledger != LEDGER) revert E_DEPLOYER(4);
        generation = gen;
        postingStore = posting;
        bitmapStore = bitmap;
        emit IndexDeployed(gen, posting, bitmap);
    }

    function _create(bytes memory initcode) private returns (address created) {
        assembly ("memory-safe") {
            created := create(0, add(initcode, 32), mload(initcode))
        }
        if (created == address(0)) revert E_DEPLOYER(2);
    }

    function _creation(uint8 nonce) private view returns (address) {
        return
            address(uint160(uint256(keccak256(abi.encodePacked(hex"d694", address(this), nonce)))));
    }
}
