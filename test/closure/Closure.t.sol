// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

// The consumer-closure compile probe (design §5; `FOUNDRY_PROFILE=closure` compiles it with solc 0.8.27 and
// without via-IR). It imports every consumer-closure file: src/interfaces/ outside internal/, and src/lib/Keys.sol.
// It must never import src/interfaces/internal/ (kernel-internal, outside the closure).

import {ActionKind} from "../../src/interfaces/Actions.sol";
import {E_RESERVED} from "../../src/interfaces/Errors.sol";
import {ClosureConstants} from "../../src/interfaces/Limits.sol";
import {STATUS_VOCABULARY_ID} from "../../src/interfaces/Results.sol";
import {Head} from "../../src/interfaces/Views.sol";
import {Effect} from "../../src/interfaces/Index.sol";
import {EXHAUSTED, IAcceptor} from "../../src/interfaces/IAcceptor.sol";
import {IBitmapStore} from "../../src/interfaces/IBitmapStore.sol";
import {IIndexHook} from "../../src/interfaces/IIndexHook.sol";
import {IIndexReads} from "../../src/interfaces/IIndexReads.sol";
import {ILedger} from "../../src/interfaces/ILedger.sol";
import {ILedgerCommitments} from "../../src/interfaces/ILedgerCommitments.sol";
import {ILedgerControl} from "../../src/interfaces/ILedgerControl.sol";
import {ILedgerHot} from "../../src/interfaces/ILedgerHot.sol";
import {ILedgerReads} from "../../src/interfaces/ILedgerReads.sol";
import {ILedgerViews} from "../../src/interfaces/ILedgerViews.sol";
import {IPostingStore} from "../../src/interfaces/IPostingStore.sol";
import {IRealmController} from "../../src/interfaces/IRealmController.sol";
import {IRealmIndex} from "../../src/interfaces/IRealmIndex.sol";
import {ITypeRegistry} from "../../src/interfaces/ITypeRegistry.sol";
import {
    IFilesPageReader,
    ILensReader,
    IReader,
    IReaderDirectory
} from "../../src/interfaces/Readers.sol";
import {Keys} from "../../src/lib/Keys.sol";

/// @notice Trivial by design: it exists so the closure profile has a test root that pulls in every closure file.
contract ClosureTest {
    function testClosureCompilesAtPragmaFloor() public pure {
        bytes4[19] memory ids = [
            type(ILedger).interfaceId,
            type(ILedgerHot).interfaceId,
            type(ILedgerControl).interfaceId,
            type(ILedgerReads).interfaceId,
            type(ILedgerViews).interfaceId,
            type(ILedgerCommitments).interfaceId,
            type(ITypeRegistry).interfaceId,
            type(IAcceptor).interfaceId,
            type(IRealmIndex).interfaceId,
            type(IIndexHook).interfaceId,
            type(IIndexReads).interfaceId,
            type(IPostingStore).interfaceId,
            type(IBitmapStore).interfaceId,
            type(IRealmController).interfaceId,
            type(IReader).interfaceId,
            type(ILensReader).interfaceId,
            type(IFilesPageReader).interfaceId,
            type(IReaderDirectory).interfaceId,
            E_RESERVED.selector
        ];
        for (uint256 i; i < ids.length; ++i) {
            require(ids[i] != bytes4(0), "zero interface id");
        }
        Effect memory effect;
        require(abi.encode(effect).length == 768, "Effect/3 is 24 static words");
        Head memory head;
        require(abi.encode(head).length == 8 * 32, "Head is 8 static words");
        require(EXHAUSTED == keccak256("efs2/acceptor/2/exhausted"), "EXHAUSTED");
        require(STATUS_VOCABULARY_ID == keccak256("efs2/status-vocabulary/1"), "vocabulary");
        require(Keys.DOM_RECORD == keccak256("efs2/record/1"), "DOM_RECORD");
        require(ActionKind.RELEASE == 7, "RELEASE");
        require(ClosureConstants.DESCRIPTOR_MAX == 4_096, "DESCRIPTOR_MAX");
    }
}
