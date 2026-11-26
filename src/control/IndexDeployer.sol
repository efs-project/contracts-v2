// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {DigestSpec, Unit, WorkModel} from "../interfaces/Index.sol";
import {IRealmIndex} from "../interfaces/IRealmIndex.sol";
import {E_DEPLOYER} from "../interfaces/Errors.sol";

/// @title IndexDeployer — a later generation with its fresh stores, created by one contract's nonces (design §10.1, §8.2)
/// @notice The `RealmGenesis` pattern for an index generation that needs fresh stores: `run()` creates each fresh
///         store with `INITIAL_WRITER` = the nonce-predicted generation address, then the generation's
///         `IndexReads` (its manifest and read side) with the stores' addresses, then the generation with the reads
///         contract's address, asserts every prediction and journals. The initcodes arrive in the call and are
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
        /// The `IndexReads` creation code; its arguments (ledger, hotAbiId, posting, bitmap, units, specs, work,
        /// topicTypeId, topicWordTypeId, liveManifest) are appended here.
        bytes readsInitcode;
        /// The generation's creation code without constructor arguments (ledger, decoder, reads); they are appended
        /// here.
        bytes generationInitcode;
        Unit[] units;
        DigestSpec[] specs;
        WorkModel work;
        /// The `IndexReads` topic Type ids (both zero for a generation without topic lists).
        bytes32 topicTypeId;
        bytes32 topicWordTypeId;
        /// The copy of the live index's manifest preimage (`IIndexReads.liveManifestCopy`): the bytes whose keccak is
        /// the `indexManifestHash` of the Realm's current revision row. Taken from the live index's reads contract
        /// (its `manifest()` with its address and codehash), never from a call the live index must answer; a copy
        /// that is stale by activation time refuses the generation (kernel reason 14).
        bytes liveManifest;
    }

    address public immutable LEDGER;
    bytes32 public immutable PLAN_HASH;

    address public generation;
    address public postingStore;
    address public bitmapStore;
    address public readsContract;

    event IndexDeployed(
        address indexed generation, address postingStore, address bitmapStore, address reads
    );

    constructor(address ledger, bytes32 planHash) {
        LEDGER = ledger;
        PLAN_HASH = planHash;
    }

    function planHash(Plan calldata plan) public pure returns (bytes32) {
        return keccak256(abi.encode(plan));
    }

    /// The generation's address: after the fresh stores and the reads contract, by this contract's nonces.
    function predictGeneration(Plan calldata plan) public view returns (address) {
        uint8 fresh =
            (plan.postingInitcode.length != 0 ? 1 : 0) + (plan.bitmapInitcode.length != 0 ? 1 : 0);
        return _creation(fresh + 2);
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
        address reads = _createReads(plan, posting, bitmap);
        if (reads != _creation(nonce)) revert E_DEPLOYER(2);
        gen =
            _create(bytes.concat(plan.generationInitcode, abi.encode(LEDGER, plan.decoder, reads)));
        if (gen != predicted) revert E_DEPLOYER(3);
        if (IRealmIndex(gen).replayReadiness().ledger != LEDGER) revert E_DEPLOYER(4);
        generation = gen;
        postingStore = posting;
        bitmapStore = bitmap;
        readsContract = reads;
        emit IndexDeployed(gen, posting, bitmap, reads);
    }

    /// The `IndexReads` constructor arguments as one tuple: `abi.encode` of it minus its leading offset word is the
    /// constructor's argument encoding (the ten separate arguments, with the nested unit arrays, are too deep for the
    /// encoder under via-IR).
    struct ReadsArgs {
        address ledger;
        bytes32 hotAbiId;
        address posting;
        address bitmap;
        Unit[] units;
        DigestSpec[] specs;
        WorkModel work;
        bytes32 topicTypeId;
        bytes32 topicWordTypeId;
        bytes liveManifest;
    }

    /// The reads contract over the plan's stores.
    function _createReads(Plan calldata plan, address posting, address bitmap)
        private
        returns (address)
    {
        ReadsArgs memory x = ReadsArgs({
            ledger: LEDGER,
            hotAbiId: plan.hotAbiId,
            posting: posting,
            bitmap: bitmap,
            units: plan.units,
            specs: plan.specs,
            work: plan.work,
            topicTypeId: plan.topicTypeId,
            topicWordTypeId: plan.topicWordTypeId,
            liveManifest: plan.liveManifest
        });
        bytes memory encoded = abi.encode(x);
        bytes memory init = plan.readsInitcode;
        bytes memory code = new bytes(init.length + encoded.length - 32);
        assembly ("memory-safe") {
            mcopy(add(code, 32), add(init, 32), mload(init))
            mcopy(add(add(code, 32), mload(init)), add(encoded, 64), sub(mload(encoded), 32))
        }
        return _create(code);
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
