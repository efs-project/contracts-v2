// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ActionKind, Purpose} from "../interfaces/Actions.sol";
import {Effect} from "../interfaces/Index.sol";
import {IIndexHook} from "../interfaces/IIndexHook.sol";
import {IIndexReads} from "../interfaces/IIndexReads.sol";
import {ILedgerHot} from "../interfaces/ILedgerHot.sol";
import {Keys} from "../lib/Keys.sol";
import {FilesProfile, E_FILES_FINAL} from "./FilesProfile.sol";

/// @title FilesFinalValidator — generation 1's one index unit: the FOLDER final hook (design §10.7, §12.2)
/// @notice §12.2: "`FilesFinalValidator` (gen 1, `purposeFilter = FOLDER`): for every FOLDER bind, a valid
///         `files-name/2` record whose id is `recordFromHash(nameType, role)` is admitted at or before the terminal
///         admission, the parent is a validated directory record, the target (`Effect.target`/`targetKind`) is a
///         file subject or directory record, no self-link; it reads only `recordHeader`/`subjectCreatedAt` on the
///         ledger and the effects (write-once facts)."
///         Pinned in the manifest as `Unit{foldHook: 0, finalHook: this, finalCodehash, familyIds: [],
///         purposeFilter: FOLDER, hotAbiId, identity: identity()}`. The index STATICCALLs `validate` with every
///         effect of the publication at the final phase (the unit's `purposeFilter` selects fold hooks only), so the
///         FOLDER filter is applied here. "Every FOLDER bind" is every `BIND`-kind effect (FIRST_BIND, REBIND,
///         RESTORE) whose purpose is FOLDER: UNBIND (mask) and RELEASE remove an entry and are never refused, so a
///         placement can always be withdrawn. The parent being "a validated directory record" covers the Realm root:
///         the seed root is itself a `files-directory/1` record (§12.2 Root) with no FOLDER bind of its own.
///         The terminal admission is the last effect's; every fact read is write-once (a record header's Type and
///         first admission, a subject's creation admission), so replay re-validation agrees with the live verdict.
/// @dev No caller pin: anyone may call; only the index's call matters. The ledger is the calling index's
///      `IIndexReads.ledger()` (an immutable of the generation), so one validator serves every Realm whose Files
///      Types are this profile's. The two Type ids are constructor STATE, not immutables (the profile immutables gate
///      keeps `immutableReferences` empty): the runtime has no `SSTORE`, the instance is CREATE2(factory, 0,
///      initcode ‖ ids) and the manifest pins its address and codehash, so the configuration is fixed by the
///      manifest hash. Two cold `SLOAD`s per publication with a FOLDER bind, none otherwise.
///      Refusal codes (`E_FILES_FINAL(code, leaf)`): 1 no `files-name/2` record for the role at or before the
///      terminal admission, 2 the parent is neither a directory record admitted by then nor (SPIKE, T-5) an
///      address-shaped home word, 3 self-link (target ==
///      parent), 4 a subject target not created by then, 5 a record target that is not a directory record admitted
///      by then, 6 an unknown target kind.
///      SPIKE (tags/topics): 7 a TAG effect whose `transitionKind` is FIRST_BIND (1) or FIRST_MASK (6) has a subject
///      that is neither address-shaped (a home) nor a `topic/1` or `topic-word/1` record first admitted strictly
///      BEFORE that effect's own admission (the index walks the topic's ancestors at the tag's admission, so a
///      topic registered later in the same publication is refused: registrations come first). 8 a BIND whose
///      `targetKind` is 3 (ADDRESS) and whose purpose is neither TAG nor FOLDER (FOLDER refuses it with 6): an
///      address is a target for tags only. Later transitions on an existing TAG binding (REBIND, MASK, RELEASE, RESTORE) are never
///      refused, so a tag can always be changed or withdrawn. A topic's admission is write-once (a WITHDRAW of its
///      registrant's admission decrements occurrences and keeps `firstAdmission`), so a withdrawn registration
///      still registers the topic. Two more cold `SLOAD`s (the topic Type ids) per publication with a first TAG.
///      SPIKE (T-5 homes): a FOLDER parent whose top 96 bits are zero is the home of that address
///      (`bytes32(uint256(uint160(addr)))`, equal to `Keys.principal(addr)` for a key account). Nothing about the
///      address is checked (no code, balance or admission needed); a precompile address 0x1..0xff is just an unowned
///      home. The zero address is never a home: the kernel's shape law refuses `subject == 0` on every bind kind
///      (`E_SHAPE(leaf, 1)`) before this hook runs. A directory record id and a minted subject id are keccak-256
///      outputs (`Keys.record*`, `Keys.subject`), so producing one that is address-shaped (12 leading zero bytes)
///      takes about 2^96 hash evaluations: the two parent forms cannot collide in practice.
contract FilesFinalValidator is IIndexHook {
    /// The exact `files-name/2` Type id of the profile (constructor state, never rewritten).
    bytes32 public nameTypeId;
    /// The exact `files-directory/1` Type id of the profile (constructor state, never rewritten).
    bytes32 public directoryTypeId;
    /// SPIKE (tags/topics): the exact `topic/1` and `topic-word/1` Type ids (constructor state, never rewritten).
    bytes32 public topicTypeId;
    bytes32 public topicWordTypeId;

    uint8 private constant T_FIRST_BIND = 1;
    uint8 private constant T_FIRST_MASK = 6;
    uint8 private constant TARGET_ADDRESS = 3;

    constructor(
        bytes32 nameTypeId_,
        bytes32 directoryTypeId_,
        bytes32 topicTypeId_,
        bytes32 topicWordTypeId_
    ) {
        nameTypeId = nameTypeId_;
        directoryTypeId = directoryTypeId_;
        topicTypeId = topicTypeId_;
        topicWordTypeId = topicWordTypeId_;
    }

    /// The manifest `Unit.identity` of this validator: its unit name and the four Type ids it enforces.
    function identity() external view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("efs/unit/files-final/1"),
                nameTypeId,
                directoryTypeId,
                topicTypeId,
                topicWordTypeId
            )
        );
    }

    /// @inheritdoc IIndexHook
    /// @dev No fold hook in generation 1 (`Unit.foldHook == 0`); acknowledges so a misconfigured unit still folds.
    function fold(Effect calldata, bytes32[] calldata, uint64) external pure returns (bytes4) {
        return IIndexHook.fold.selector;
    }

    /// @inheritdoc IIndexHook
    function validate(uint64, Effect[] calldata effects, bytes32[] calldata)
        external
        view
        returns (bytes4)
    {
        uint256 n = effects.length;
        if (n == 0) return IIndexHook.validate.selector;
        uint64 terminal = effects[n - 1].admission;
        ILedgerHot hot;
        bytes32 nameType;
        bytes32 directoryType;
        bytes32 topicType;
        bytes32 wordType;
        for (uint256 i; i < n; ++i) {
            Effect calldata e = effects[i];
            if (e.purpose == Purpose.TAG) {
                // SPIKE (tags/topics): a first tag stands on a registered topic or a home
                uint8 tk = e.transitionKind;
                if (tk != T_FIRST_BIND && tk != T_FIRST_MASK) continue;
                if (uint256(e.subject) >> 160 == 0) continue; // a home (the zero word is refused by the shape law)
                if (address(hot) == address(0)) {
                    hot = ILedgerHot(IIndexReads(msg.sender).ledger());
                }
                if (topicType == 0) {
                    topicType = topicTypeId;
                    wordType = topicWordTypeId;
                }
                (bytes32 t, uint64 first,,,) = hot.recordHeader(e.subject);
                // strictly BEFORE this statement: the index walks the topic's ancestors at the tag's own
                // admission, so a topic registered later in the same publication would leave the tag with no
                // roll-up entries for good
                if ((t != topicType && t != wordType) || first == 0 || first >= e.admission) {
                    revert E_FILES_FINAL(7, e.leaf);
                }
                continue;
            }
            // SPIKE (address targets): an ADDRESS target (kind 3) is for tags only; FOLDER keeps code 6 below
            if (
                e.kind == ActionKind.BIND && e.targetKind == TARGET_ADDRESS
                    && e.purpose != Purpose.FOLDER
            ) {
                revert E_FILES_FINAL(8, e.leaf);
            }
            if (e.kind != ActionKind.BIND || e.purpose != Purpose.FOLDER) continue;
            if (address(hot) == address(0)) {
                hot = ILedgerHot(IIndexReads(msg.sender).ledger());
            }
            if (nameType == 0) {
                nameType = nameTypeId;
                directoryType = directoryTypeId;
            }
            // the name: a files-name/2 record whose body hash is the role
            if (!_record(hot, Keys.recordFromHash(nameType, e.role), nameType, terminal)) {
                revert E_FILES_FINAL(1, e.leaf);
            }
            // the parent: a directory record (the seed root is one) or, SPIKE (T-5 homes), an address-shaped word
            // (top 96 bits zero: the address's home; nothing about the address is checked)
            if (uint256(e.subject) >> 160 != 0 && !_record(hot, e.subject, directoryType, terminal))
            {
                revert E_FILES_FINAL(2, e.leaf);
            }
            // the target: a file subject or another directory record, never the parent itself
            bytes32 target = e.target;
            if (target == e.subject) revert E_FILES_FINAL(3, e.leaf);
            if (e.targetKind == FilesProfile.TARGET_SUBJECT) {
                uint64 created = hot.subjectCreatedAt(target);
                if (created == 0 || created > terminal) revert E_FILES_FINAL(4, e.leaf);
            } else if (e.targetKind == FilesProfile.TARGET_RECORD) {
                if (!_record(hot, target, directoryType, terminal)) {
                    revert E_FILES_FINAL(5, e.leaf);
                }
            } else {
                revert E_FILES_FINAL(6, e.leaf);
            }
        }
        return IIndexHook.validate.selector;
    }

    function _record(ILedgerHot hot, bytes32 recordId, bytes32 typeId, uint64 terminal)
        private
        view
        returns (bool)
    {
        (bytes32 t, uint64 first,,,) = hot.recordHeader(recordId);
        return t == typeId && first != 0 && first <= terminal;
    }
}
