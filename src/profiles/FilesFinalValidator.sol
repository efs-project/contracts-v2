// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ActionKind, Purpose} from "../interfaces/Actions.sol";
import {Effect} from "../interfaces/Index.sol";
import {IIndexHook} from "../interfaces/IIndexHook.sol";
import {IIndexReads} from "../interfaces/IIndexReads.sol";
import {ILedgerHot} from "../interfaces/ILedgerHot.sol";
import {Keys} from "../lib/Keys.sol";
import {FilesProfile, E_FILES_FINAL} from "./FilesProfile.sol";

/// @title FilesFinalValidator — generation 1's one index unit: the profile's final hook (design §10.7, §12.2, §12.5)
/// @notice §12.2: "`FilesFinalValidator` (gen 1, `purposeFilter = FOLDER`): for every FOLDER bind, a valid
///         `files-name/2` record whose id is `recordFromHash(nameType, role)` is admitted at or before the terminal
///         admission, the parent is a validated directory record, the target (`Effect.target`/`targetKind`) is a
///         file subject or directory record, no self-link; it reads only `recordHeader`/`subjectCreatedAt` on the
///         ledger and the effects (write-once facts)." §12.5 adds the HEAD law, homes, and the subjects of tags and
///         of the two relations between topics.
///         Pinned in the manifest as `Unit{foldHook: 0, finalHook: this, finalCodehash, familyIds: [],
///         purposeFilter: FOLDER, hotAbiId, identity: identity()}`. The index STATICCALLs `validate` with every
///         effect of the publication at the final phase (the unit's `purposeFilter` selects fold hooks only), so the
///         purposes are told apart here.
///
///         What a validator may refuse. An author can always mask or release a binding of theirs that already
///         exists, and no validator may refuse that. A validator may refuse an action that asserts something (any
///         BIND) and an action that creates a new position for its author (a first statement of either sign). So
///         every check below runs on a BIND-kind effect (FIRST_BIND, REBIND, RESTORE) or on a first statement
///         (transition FIRST_BIND or FIRST_MASK), and never on a mask or a release of an existing binding.
///
///         The laws, by purpose:
///         - HEAD (every BIND): the target is a revision of this profile naming the bind's own subject: a
///           `files-root/1` record whose body word 0 is `e.subject` or a `files-child/1` record whose body word 1 is
///           `e.subject`, admitted at or before the terminal admission (the Type is checked before any body word is
///           read, and a zero file word never matches). So a HEAD never points at a subject, a record of another Type or another file's revision,
///           and a HEAD whose subject is a folder's record id is always refused (no revision can name one: a root
///           names a created subject and a child inherits its parent's file). An ADDRESS target is refused first.
///           The readers still check the HEAD law themselves (defence in depth, and for Realms without this unit).
///         - FOLDER (every BIND): the name, parent and target laws of §12.2 above. The parent is a directory record
///           (the seed root is one) or a HOME: an address-shaped word (top 96 bits zero), the left-padded address
///           `bytes32(uint256(uint160(addr)))`, which equals `Keys.principal(addr)` for a key account. Nothing about
///           the address is checked (no code, balance or history needed; a precompile 0x1..0xff is an ordinary
///           unowned home). The zero address is never a home: the kernel's shape law refuses a zero subject on
///           every bind kind before this hook runs. A directory record id and a minted subject id are keccak-256
///           outputs (`Keys.record*`, `Keys.subject`), so producing one that is address-shaped (12 leading zero
///           bytes) takes about 2^96 hash evaluations: the two parent forms cannot be confused in practice.
///         - TAG (first statements only): the subject is a home or a registered topic: a `topic/1` or `topic-word/1`
///           record first admitted STRICTLY BEFORE the statement's own admission (`first != 0 && first <
///           e.admission`). A topic registered later in the same publication is refused: the index walks a topic's
///           ancestors at the tag's own admission, so accepting it would silently drop the tag's list entries.
///           An earlier action of the same publication counts. Any record or subject of any Type, or an address,
///           may be the thing tagged; the target is not judged. A withdrawal by a topic's first registrant lowers an
///           occurrence count and keeps `firstAdmission`, so a withdrawn registration still registers the topic.
///         - SAME and BROADER: position (topic, role = other topic) → the other topic. On a first statement the
///           subject and the role are each a topic registered strictly before the statement, and differ. On every
///           BIND the target equals the role. Reading rule (design §12.5): `same` between two word pages is the
///           word-level synonym (it applies to every path that uses either word, and makes the two root places the
///           same); `same` between two path records joins those two places only; `same` between a word page and a
///           path record joins that root place and that one path and has no word-level effect. Cycles (in `same`
///           and in `broader`) cannot be prevented at admission and need not be: readers bound their hops.
///         - PROPERTY and every other purpose: not judged (any subject; the value may be a record, a file subject
///           or an address).
///
///         The terminal admission is the last effect's; every fact read is write-once (a record header's Type and
///         first admission, a record's body words, a subject's creation admission), so replay re-validation agrees
///         with the live verdict.
/// @dev No caller pin: anyone may call; only the index's call matters. The ledger is the calling index's
///      `IIndexReads.ledger()` (an immutable of the generation), so one validator serves every Realm whose Types
///      are this profile's. The six Type ids are constructor STATE, not immutables (the profile immutables gate
///      keeps `immutableReferences` empty): the runtime has no `SSTORE`, the instance is CREATE2(factory, 0,
///      initcode ‖ ids) and the manifest pins its address and codehash, so the configuration is fixed by the
///      manifest hash. Each pair of ids is loaded (two cold `SLOAD`s) the first time a publication needs it.
///      Refusal codes (`E_FILES_FINAL(code, leaf)`):
///       1 FOLDER: no `files-name/2` record for the role at or before the terminal admission;
///       2 FOLDER: the parent is neither a directory record admitted by then nor an address-shaped home;
///       3 FOLDER: self-link (target == parent);
///       4 FOLDER: a subject target not created by then;
///       5 FOLDER: a record target that is not a directory record admitted by then;
///       6 FOLDER: any other target kind (an ADDRESS target among them: a folder entry cannot name an address);
///       7 HEAD: an ADDRESS target (it would confirm and never be readable);
///       8 HEAD: the target is not a `files-root/1` or `files-child/1` record naming the bind's subject;
///       9 TAG first statement: the subject is neither a home nor a topic registered strictly before it;
///      10 SAME/BROADER first statement: the subject is not a topic registered strictly before it;
///      11 SAME/BROADER first statement: the role is not a topic registered strictly before it;
///      12 SAME/BROADER first statement: the subject and the role are the same topic;
///      13 SAME/BROADER BIND: the target is not the role.
contract FilesFinalValidator is IIndexHook {
    /// The exact Type ids of the profile (constructor state, never rewritten).
    bytes32 public nameTypeId;
    bytes32 public directoryTypeId;
    bytes32 public rootTypeId;
    bytes32 public childTypeId;
    bytes32 public topicTypeId;
    bytes32 public topicWordTypeId;

    uint8 private constant T_FIRST_BIND = 1;
    uint8 private constant T_FIRST_MASK = 6;

    /// The ledger and the Type ids one `validate` call has loaded (zero until first needed).
    struct Loaded {
        ILedgerHot hot;
        bytes32 name;
        bytes32 directory;
        bytes32 root;
        bytes32 child;
        bytes32 topic;
        bytes32 word;
    }

    constructor(
        bytes32 nameTypeId_,
        bytes32 directoryTypeId_,
        bytes32 rootTypeId_,
        bytes32 childTypeId_,
        bytes32 topicTypeId_,
        bytes32 topicWordTypeId_
    ) {
        nameTypeId = nameTypeId_;
        directoryTypeId = directoryTypeId_;
        rootTypeId = rootTypeId_;
        childTypeId = childTypeId_;
        topicTypeId = topicTypeId_;
        topicWordTypeId = topicWordTypeId_;
    }

    /// The manifest `Unit.identity` of this validator: its unit name and the six Type ids it enforces, in
    /// constructor order.
    function identity() external view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("efs/unit/files-final/1"),
                nameTypeId,
                directoryTypeId,
                rootTypeId,
                childTypeId,
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
        Loaded memory l;
        for (uint256 i; i < n; ++i) {
            Effect calldata e = effects[i];
            bytes32 purpose = e.purpose;
            if (purpose == Purpose.TAG) {
                if (
                    _first(e) && uint256(e.subject) >> 160 != 0
                        && !_topic(l, e.subject, e.admission)
                ) {
                    revert E_FILES_FINAL(9, e.leaf);
                }
            } else if (purpose == Purpose.SAME || purpose == Purpose.BROADER) {
                _relation(l, e);
            } else if (e.kind == ActionKind.BIND) {
                if (purpose == Purpose.HEAD) _head(l, e, terminal);
                else if (purpose == Purpose.FOLDER) _folder(l, e, terminal);
            }
        }
        return IIndexHook.validate.selector;
    }

    /// A first statement: FIRST_BIND or FIRST_MASK (a new position for its author, of either sign).
    function _first(Effect calldata e) private pure returns (bool) {
        uint8 tk = e.transitionKind;
        return tk == T_FIRST_BIND || tk == T_FIRST_MASK;
    }

    /// SAME / BROADER: (topic, role = other topic) → the other topic.
    function _relation(Loaded memory l, Effect calldata e) private view {
        if (_first(e)) {
            if (!_topic(l, e.subject, e.admission)) revert E_FILES_FINAL(10, e.leaf);
            if (!_topic(l, e.role, e.admission)) revert E_FILES_FINAL(11, e.leaf);
            if (e.subject == e.role) revert E_FILES_FINAL(12, e.leaf);
        }
        if (e.kind == ActionKind.BIND && e.target != e.role) revert E_FILES_FINAL(13, e.leaf);
    }

    /// HEAD: the target is a revision record naming the bind's own subject. The Type is checked first (exactly
    /// `files-root/1` or `files-child/1`, first admitted at or before the terminal admission); only then is the file
    /// word read (word 0 of a root, word 1 of a child). `bodyWord` answers zero for a missing record and for a word
    /// beyond the body, so a zero file word is a mismatch whatever the subject.
    function _head(Loaded memory l, Effect calldata e, uint64 terminal) private view {
        if (e.targetKind == FilesProfile.TARGET_ADDRESS) revert E_FILES_FINAL(7, e.leaf);
        if (e.targetKind == FilesProfile.TARGET_RECORD) {
            ILedgerHot hot = _hot(l);
            if (l.root == 0) {
                l.root = rootTypeId;
                l.child = childTypeId;
            }
            bytes32 target = e.target;
            (bytes32 t, uint64 first,,,) = hot.recordHeader(target);
            if (first != 0 && first <= terminal && (t == l.root || t == l.child)) {
                // files-root/1: abi.encode(fileSubject, form) ‖ rest; files-child/1: abi.encode(parent, fileSubject,
                // form) ‖ rest
                bytes32 fileWord = hot.bodyWord(target, t == l.root ? 0 : 1);
                if (fileWord != 0 && fileWord == e.subject) return;
            }
        }
        revert E_FILES_FINAL(8, e.leaf);
    }

    /// FOLDER: the §12.2 laws, with a home as a valid parent.
    function _folder(Loaded memory l, Effect calldata e, uint64 terminal) private view {
        ILedgerHot hot = _hot(l);
        if (l.name == 0) {
            l.name = nameTypeId;
            l.directory = directoryTypeId;
        }
        // the name: a files-name/2 record whose body hash is the role
        if (!_record(hot, Keys.recordFromHash(l.name, e.role), l.name, terminal)) {
            revert E_FILES_FINAL(1, e.leaf);
        }
        // the parent: a directory record (the seed root is one) or a home (an address-shaped word)
        if (uint256(e.subject) >> 160 != 0 && !_record(hot, e.subject, l.directory, terminal)) {
            revert E_FILES_FINAL(2, e.leaf);
        }
        // the target: a file subject or another directory record, never the parent itself
        bytes32 target = e.target;
        if (target == e.subject) revert E_FILES_FINAL(3, e.leaf);
        if (e.targetKind == FilesProfile.TARGET_SUBJECT) {
            uint64 created = hot.subjectCreatedAt(target);
            if (created == 0 || created > terminal) revert E_FILES_FINAL(4, e.leaf);
        } else if (e.targetKind == FilesProfile.TARGET_RECORD) {
            if (!_record(hot, target, l.directory, terminal)) revert E_FILES_FINAL(5, e.leaf);
        } else {
            revert E_FILES_FINAL(6, e.leaf);
        }
    }

    /// A `topic/1` or `topic-word/1` record first admitted strictly before `admission`.
    function _topic(Loaded memory l, bytes32 id, uint64 admission) private view returns (bool) {
        ILedgerHot hot = _hot(l);
        if (l.topic == 0) {
            l.topic = topicTypeId;
            l.word = topicWordTypeId;
        }
        (bytes32 t, uint64 first,,,) = hot.recordHeader(id);
        return (t == l.topic || t == l.word) && first != 0 && first < admission;
    }

    function _hot(Loaded memory l) private view returns (ILedgerHot hot) {
        hot = l.hot;
        if (address(hot) == address(0)) {
            hot = ILedgerHot(IIndexReads(msg.sender).ledger());
            l.hot = hot;
        }
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
