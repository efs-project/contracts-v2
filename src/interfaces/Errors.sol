// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

// @title Errors — the EFS v2 error catalog (design §5.6)
// @notice Every revert is a custom error with arguments; the release bundle ships `errors.json`
//         with selector, meaning and retry class. The design names the arguments of every write-path
//         error; where it lists an activation, registry, index or controller error by name only, the
//         argument list was chosen here and is recorded in `docs/ONE-WAY-DOORS.md` before the first
//         release. Acceptor revert data is always discarded; index revert data is always nested inside
//         `E_INDEX_CALL`; nothing has the shape "spent more than allowed" (invariant I11).

// ---- kernel entry and preparation (retry class in the trailing comment) -------------------------------
error AlreadyAdmitted(uint64 publication); // none (committed)
error E_NONCE(bytes32 principalId, uint64 nonce, uint64 publication); // reprepare
error E_PUBLICATION_ACTIVE(); // wait
error E_TRANSITION(uint32 target, uint48 deadline); // wait
error E_CHAIN(uint64 accepted, uint64 actual); // none
error E_NO_INDEX(); // wait
error E_EXECUTION_DRIFT(address live, address activated); // wait
error E_REGISTRY_DRIFT(uint64 expected, uint64 have); // resubmit
error E_HELPER_CODE(address helper); // wait
error E_EXECUTION_SET(bytes32 expected, bytes32 live); // reprepare
error E_ACCEPTANCE_PROFILE(bytes32 expected, bytes32 live); // reprepare
error E_NATIVE_AMBIGUOUS(); // none
error E_BATCH_SHAPE(uint16 actions, uint16 bodies); // none
error E_COUNTER_SATURATED(uint8 counter); // none
error E_EXPIRED(uint64 deadline, uint64 now); // reprepare
error E_INTENT(uint8 field); // reprepare: 1 realm 2 execution 3 profile 4 index 5 readset
error E_SIGNATURE(uint8 reason); // reprepare: 0 unknown profile 1 length 2 malleable 3 recover 4 wallet refused 5 code-less/key-classified author 6 author does not derive principalId
error E_WALLET_GAS(uint32 forwarded); // resubmit
error E_READSET_SHAPE(uint8 reason); // none
error E_READSET_STALE(bytes32 position, bytes32 principalId); // reprepare
error E_UNSUPPORTED_GUARD(); // none
error E_VERIFIER_PROFILE(uint16 profile); // none
error E_UNKNOWN_TYPE(uint8 leaf, bytes32 typeId); // none

// ---- per-leaf apply and validation ----------------------------------------------------------------------
error E_SHAPE(uint8 leaf, uint8 code); // none
error E_KIND(uint8 leaf, uint8 kind); // none
error E_BODY(uint8 leaf, uint8 code); // none: 1 too long 2 hash mismatch 3 carrier refused
error E_MISSING_RECORD(uint8 leaf, bytes32 recordId); // reprepare
error E_TYPE_MISMATCH(uint8 leaf, bytes32 expected, bytes32 have); // none
error E_REF(uint8 leaf, uint8 refIndex, uint8 code); // reprepare: 1 missing 2 type 3 sentinel-in-body 4 reserved sentinel
error E_ACCEPTOR_CODE(uint8 leaf, address acceptor); // wait
error E_GAS(uint8 leaf, uint32 needed, uint32 available); // resubmit
error E_ACCEPTOR_GAS(uint8 leaf, bytes32 typeId, uint32 forwarded); // resubmit
error E_REJECTED(uint8 leaf, bytes32 typeId); // none
error E_POLICY_REJECTED(uint8 leaf, bytes32 typeId, uint16 policyRow); // none
error E_NOT_LIVE(uint8 leaf, bytes32 bindingKey, uint8 state); // reprepare
error E_CAS(bytes32 bindingKey, uint64 expected, uint64 have); // reprepare
error E_TARGET_MISSING(uint8 leaf, bytes32 target); // reprepare
error E_TARGET_TYPE(uint8 leaf, bytes32 expected, bytes32 have, uint16 roleRow); // none
error E_SUBJECT_EXISTS(uint8 leaf, bytes32 subjectId); // none
error E_SALT(uint8 leaf); // none
error E_WITHDRAW(uint8 leaf, uint8 code); // none: 0 range 1 not publish 2 already 3 not author

// ---- delegates and the index dispatcher ------------------------------------------------------------------
error E_INGRESS(uint256 replySize); // wait
error E_INDEX_CALL(bytes inner); // none (the callback reverted with data; inner ≤ 4,096 B)
error E_INDEX_GAS(uint32 quoted, uint32 available); // resubmit
error E_INDEX_RETURNDATA(uint256 size); // none
error E_INDEX_FINAL(); // none
error E_DELEGATE_ONLY(); // none

// ---- activation, transition, freeze and the controller (design §8) ---------------------------------------
error E_REVISION(uint32 expected, uint32 have);
error E_IMPLEMENTATION(address expected, address live);
error E_LAYOUT(bytes32 expected, bytes32 have);
error E_REGISTRY(uint8 field); // 1 activeRevision 2 ledger 3 implementation 4 codehash
error E_PIN(address target, uint8 which); // 1 ingress 2 apply 3 index 4 steward 5 unit 6 store 7 build 8 admin slot 9 admin owner
error E_INDEX_NOT_READY(uint8 reason);
error E_EXPECTED_SET(bytes32 expected, bytes32 live);
error E_FROZEN();
error E_NOT_CONTROLLER(address caller);
error E_DEADLINE_BOUND(uint48 deadline, uint32 maxBlocks);
error E_TRANSITION_COOLDOWN(uint48 until);
error E_TRANSITION_TARGET(uint32 target);
error E_MIGRATION_SCOPE(bytes32 root);
error E_HOT_ABI(address unit);
error E_CODE_SHAPE(address target, uint8 reason); // 1 no code 2 designator 3 forbidden opcode 4 trailer malformed 5 proxy shape
error E_CONTROLLER(uint8 field); // 1 controller 2 codehash 3 owner
error E_FREEZE_PRECHECK(uint8 check);
error E_RESERVED(uint8 field, uint256 value);
error E_UNSUPPORTED_ROW(uint8 row);

// ---- registry (design §9) ----------------------------------------------------------------------------------
error E_TYPE_EXISTS(bytes32 typeId);
error E_BINDING(uint8 code);
error E_DECLARATION(uint8 code);
error E_CODEC(uint16 byteOffset, uint8 code);
error E_DESIGNATOR(address target);
error E_BLOB(address blob);
error E_GRADE(uint8 grade);
error E_INSTANCE(address expected, address have);
error E_WRAPPER(uint8 code);
error E_ROLE_ROWS();

// ---- index and stores (design §10, §4.6) ----------------------------------------------------------------
error E_LEDGER();
error E_WRITER(address caller);
error E_ORDER(uint64 expected, uint64 have);
error E_STAGED(uint64 expected, uint64 have);
error E_FAMILY(bytes32 familyId);
error E_UNIT(uint8 index);
error E_REPLAY(uint8 code);
error E_BUILD(uint8 code);
error E_BACKFILL(uint8 code);
error E_COVERAGE(uint8 code);

// ---- controller (design §5.12) ----------------------------------------------------------------------------
error E_NOT_OWNER(address caller);
error E_PENDING(address pending);
error E_NOT_IDLE();
error E_SUCCESSOR(uint8 code);
error E_RETIRED();
error E_CANARY(uint8 lane);
