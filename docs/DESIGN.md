# EFS v2 core contracts — design

**Standing.** The implementation design for `contracts-v2`, adopted by the contracts engineer on 2026-10-20 as revision 3 of the design panel's unified design. It is the document the first slice is built from; `docs/IMPLEMENTATION-PLAN.md` says in what order, and `docs/QUESTIONS-FOR-JAMES.md` lists the product choices it leaves open. Nothing here is an owner ruling. Every byte and gas figure is marked *measured* (a retained prototype receipt or artifact byte count, cited), *inferred* (arithmetic from measured parts, basis stated) or *estimate* (this document's own, basis stated); no build tool was run to produce it, and the C1 checkpoint replaces every estimate with a measurement.

**Provenance.** Five independent architecture proposals (size-first, evolution-first, consumer-first, security-and-upgrade-first, gas-and-economics-first) over a sixteen-reader analysis of the prototype and the v2 designs; three judges; one synthesis (revision 1); six adversarial reviews whose 66 findings were adjudicated by independent verifiers (§23 lists every disposition); a repair (revision 2); two independent checks for consistency and completeness whose 48 issues are closed in §24 (revision 3). The complete record — analysis reports, proposals, judgments, reviews, checks and every revision — is in the planning vault at `planning/Reviews/2026-10-20-contracts-v2-design-record/`.

**Engineer's adoption notes (2026-10-20).** (1) The S1 unit list is built in the order of `docs/IMPLEMENTATION-PLAN.md`, with the kernel, apply delegate and ingress measured first; nothing in this document changes. (2) `CodeScan.requirePlainRuntime` skips push data; the CBOR trailer named by the runtime's last two bytes is still walked for opcodes that execution could reach (fall-through from the code region or a `JUMPDEST` inside it before a halting opcode), so a hand-built runtime cannot hide a forbidden opcode in a declared trailer, while the solc version trailer can never be a false positive. (3) Every "C1 decides" item is a measurement with a pre-stated decision rule, never a redesign; if a measurement contradicts an estimate here, the number in the next revision of this document is the measured one and the rule is applied as written. (4) Packed storage words use byte-aligned typed fields that the compiler packs (`docs/STORAGE.md`): the sub-byte fields of §4.3 (`kind u4`, `withdrawn u1`, `frozen u1`, `proofKind u4`, `principalKind u4`) are `uint8` in the implementation and the reserved bits shrink accordingly; the generated `Layout` is derived from the compiler's layout, not hand-written. (5) The shared closure types live in `src/interfaces/{Actions,Results,Limits,Errors}.sol` rather than `src/lib/`, so the interfaces can import them under the repository's import-direction gate; `Retention` is numbered as §4.2 reads it (1 LOG_ONLY, 2 STATE). (7) The S1 kernel shape is `LedgerCore` + three pinned delegates: `LedgerApply` (per-leaf writers), `LedgerIngress` (zero-write preparation, validation, dispatch) and `LedgerControl` (genesis, activation with readiness and code scans, freeze, transition; the §3.2 ladder's second writing delegate, taken from the first measurement rather than held in reserve). `CONTROL`/`CONTROL_CODEHASH` are implementation immutables, so `ledgerImplCodehash` in the execution set commits to the control delegate; `ComponentSet` is unchanged. The kernel-internal calling convention is raw forwarding (`prepareNative`/`prepareSigned` take the lane's own calldata; `applyLeaf` returns a static 33-word blob the kernel never decodes; index callbacks are assembled from blobs), because the first draft measured 40,414 B with ABI struct encoders at every delegate boundary and the optimizer specializing shared functions per literal argument. Measured on 2026-10-20 (prague, via-IR, 200 runs, full ABI including both lanes and the import stub): `LedgerCore` 14,400 B, `LedgerApply` 5,391 B, `LedgerIngress` 19,581 B, `LedgerControl` 16,558 B; every unit under the 19,660 B budget, the kernel under the 17,500 B warning line. (6) §5.11's `IIndexReads.build()` getter is `buildDelegate()` so the generation carries no overload with `IRealmIndex.build(familyId, maxFacts)`; `postingHeadOf`/`postingSliceOf` take a `uint8 ordinal`, the width `Keys.posting` and `postingKey` use; the kernel events of §5.5 are declared on `ILedger` (write path) and `ILedgerControl` (activation path); `ILensReader` inherits `ledger()` and `supportedProfiles()` from `IReader` without redeclaring them.

**Engineer's adoption notes (2026-10-20, S1 build).** (8) `CodeScan` applies its reachability rule in the code region as well as the trailer: a forbidden opcode refuses only where execution can reach it (pc 0, after a `JUMPDEST`, or by fall-through from a live instruction; dead after `STOP`/`JUMP`/`RETURN`/`REVERT`/`INVALID`). The strict rule of §2.2 S6 ("every forbidden opcode in the code region refuses", the "fail-closed residue" of note 2) refused `BitmapStore` at genesis because via-IR places 32-byte constants (the ERC-7201 roots) after the final `INVALID` and they contain `f0`/`f2` bytes; the EVM's own jump-destination analysis cannot execute them, and the walk follows that analysis exactly. `tools/checks.mjs` applies the same rule off chain. (9) Index stores: entries are five `u48` ordinals per word after an inline singleton (`PHYSICAL_PROFILE` "five-u48"), so the backlink family carries no per-entry `roleTag u16` (§10.2 row 5); readers take the role from the history or binding row. The digest family key is `Keys.digestList(bytes32(alg), word) = posting(0, 15, 0, keccak(abi.encode(alg, word)))`, the vectored form, not the `(0,15,alg,digest)` spelling of the table. A store attaches lazily at its first live write, so the first writers range opens at that admission (a genesis range may start at 2 when admission 1 is a CREATE); `provenFrom == 1` is a family-coverage statement, writers ranges are contiguous by construction, and the first live write attaches the store even when the live generation is the one that built it. The scalar family (14) is declared from admission 1 with zero specs at S1 and is vacuously `COMPLETE`. (10) Generation 1 is a plain runtime: no `DELEGATECALL`, no `IndexBuild` delegate. Replay runs through a pinned per-layout `IndexReplayDecoder` by `STATICCALL` and the generation's own fold (`replayFold`, callable only by itself), so the live fold code is the replay fold code and the stores see the generation as their `INITIAL_WRITER`; `build()` and `backfill()` revert because generation 1 declares no later family. Replay never re-judges a publication through its final hooks (the §10.6 tolerance rule is not implemented); fold hooks run. The contradiction between §10.6's delegate and §2.2 S6's plain scan is Q34. (11) Control delegate measured after the first draft: `LedgerControl` 16,558 B and later 16,615 B; `_closeTransition` judges expiry before "activated"; `abortTransition` carries the idle and frozen gates; the index-readiness check reads the tuple's phase (reason 7). Recorded, not changed: a repeated or lower revision is refused by OZ's `InvalidInitialization` before `E_REVISION`; the activation set names no expected `ProxyAdmin` (Q35); freeze pre-check 8 compares eleven of the seventeen limits (Q36); `E_PIN` reason 4 is the controller codehash and a zero admin slot reports `E_PIN(0, 9)`. (12) Bind-kind admission rows carry `bindingOrdinal` and `expectedRevision` as §4.3 says (the first draft omitted them); `UNBIND`/`RELEASE` rows also write their second slot (a zero over a zero). Refusal precedence as built: an unknown Type is caught in preparation on every lane (`E_UNKNOWN_TYPE` before `E_SHAPE`), a zero `CREATE` salt is `E_SHAPE(leaf, 1)` (`E_SALT` is unreachable), the role expectation is checked before head state, CAS and target existence, a callback that returns without the exact acknowledgement is `E_INDEX_ACK(phase)` (`E_INDEX_FINAL` is the index's own refusal of a hook), a write under the final `STATICCALL` is `E_INDEX_GAS(0, 0)`, `phase().admissionFrontier` lags during `APPLYING` while `counts()` shows the staged frontier, `refTypes` values in `0x200..0xFFFF` are refused as reserved. (13) Readers: views without a `Status` revert `E_LAYOUT` on a foreign layout; `heads`/`principalsOf` bound with `E_RESERVED(31, n)`; `headsAt` reports `ABSENT_PROVEN` with `selectedIndex = 255`; native evidence rows keep `acceptanceProfile = 0` (the §4.4 re-fold is not implemented; Q38); the facets follow the generated `Layout` where §4.3's bit offsets differ from it (admission meta `kind u8@0 | leaf u8@8`; realm word 13 `maxWitness` at bit 80); `publication()` costs 118k–225k gas. (14) Registry: declarations are EIP-712 `TypeDeclaration(bytes32 typeId)` under the chain-free domain `("EFS Type Declaration", "1")`, custom bindings `TypeBinding(bytes32 bindingId)` under the same domain over the chain- and registry-bound preimage of §9.3; `activateWrapper` reads the wrapper's constants through bounded `STATICCALL`s (`E_WRAPPER(5)` for a non-wrapper); `initialize(ledger, wrapperV1 = 0)` is allowed at S1 and grades 1–2 refuse `E_WRAPPER(1)` until a wrapper is activated; `activate(revision)` bumps `mutations`; the registry's activation precedes the ledger's in every ceremony (`E_REGISTRY(1)` otherwise). (15) Genesis and control: `RealmGenesis.run(limits, controllerInitcode, proxyInitcode)` takes the creation codes in the call pinned by immutable hashes (embedding them put the runtime at 21,952 B); the controller's `NOTICE_TYPE` is a constructor immutable because the realm-notice/1 id is deterministic before genesis; the frozen and retired gates precede the owner gate; the freeze canary body is `abi.encode(NOTICE_FROZEN, uint256(revision), bytes(""))` and a failed canary reverts the ceremony as `E_CANARY(lane)` with the inner error discarded (operators simulate); `IndexDeployer.run(plan)` takes the store and generation initcodes in the call pinned by `PLAN_HASH`. Purposes `HEAD`/`FOLDER`/`TAG` and the notice kinds are closure constants. (16) Measured runtimes on 2026-10-20 (prague, via-IR, 200 runs): `LedgerCore` 14,452, `LedgerApply` 5,457, `LedgerIngress` 19,581, `LedgerControl` 16,615, `LedgerReads` 17,479, `LedgerViews` 14,857, `TypeRegistry` 15,621, `DescriptorStore` 757, `PostingStore` 5,449, `BitmapStore` 7,569, `RealmIndex` 18,810, `IndexReplayDecoder` 5,320, `RealmController` 14,183, `RealmGenesis` 5,121, `IndexDeployer` 4,629, `ReaderDirectory` 1,495 — every unit under 19,660 B; `LedgerIngress`, `RealmIndex`, `LedgerReads` sit above the 17,500 B warning line and head the C1 cut ladder; the §15 table is rewritten with these numbers at C1. (17) Files profile as built: the nine rules, `RefuseAllPolicy` and `FilesFinalValidator` carry no immutables (the gate), but the child rule, the alias rule and the validator need sibling Type ids, which are constructor-written storage never rewritten (the runtime has no reachable `SSTORE`; §9.3 anticipates constructor state pinned by the initcode hash; §3.1 row 14's "State: none" becomes "constructor state"). The validator reads `ledger()` from its caller (the index) because `IIndexHook` carries no ledger, judges `BIND`-kind FOLDER effects only (UNBIND and RELEASE are never refused, so a placement can always be removed), and filters FOLDER itself because the index applies `purposeFilter` to fold hooks only — final hooks receive the whole effects array, with all remaining gas under the kernel's final reserve (the "bounded STATICCALL" of §10.3 is the phase's bound, not a per-hook stipend). It accepts only file subjects and directory records as FOLDER targets, so `directory-alias/1` records cannot be placed in a folder in generation 1 (Q39). Body laws fixed by the build: `directory-alias/1` = `(kind, target)` with kind 1 → an existing directory record and kind 2 → an existing file subject; `files-external/1` locators 1..512 bytes; `files-directory/1` bodies exactly 32 bytes; `realm-notice/1` = canonical `abi.encode(bytes32 kind, uint256 revision, bytes note)` with the kinds `keccak("efs2/notice/{frozen,successor,migration}/1")`; descriptors use `refHeaderWords = 1` for ref-less Types (the codec forbids 0), `wrapperVersion = 0`, `validationGas = 0`, dependency class 2 for ledger-reading rules and 1 otherwise, and only REF32 field rows. The content and external rules rely on the kernel's exact-ref check instead of re-checking the bytes Type; the child rule drops the prototype's "file subject exists" check (implied by the parent-word law). `[profile.closure]` is the consumer-closure profile (0.8.27, no via-IR, interfaces only), not a `runs = 1` profile; the rules are built under the identity profile. `files-name/2` measures 1,683 B (the experiment's 1,477 B plus the IAcceptor/2 context decode) and 3,400 / 43,580 / 113,077 gas for a 10-byte, a 255-byte ASCII and a 255-byte CJK name. (18) `DescribedTypeRule/1` as built: 6,652 B (the codec alone is 4,230 B bare, so the 5,200 B estimate was not reachable); it reuses the calldata-only codec through a `STATICCALL` to its own `check(ctx, body, refs, refHeaders)` with the descriptor appended after the arguments — a public dry-run entry the SDK can call, ≈ 7–8k gas per acceptance; the `extcodehash(blob)` check of §5.10 is dropped because the descriptor is read out of the blob itself (binding is by the recomputed Type id); the wrapper additionally re-checks every `refHeaders[i].typeId` against the descriptor's own projection, so a registry row that diverges from the descriptor cannot let a wrong-Type reference through; a predicate's own `EXHAUSTED` reply is a refusal (Q40) while the self-call's exhaustion is reported as `EXHAUSTED` (the same 1/64 blind spot); refusals revert with catalog errors (`E_BINDING(10)` is the recomputed binding id). The codec's text scan runs in assembly (the Solidity loop cost ≈ 285 gas per byte and put a 1,024-byte text at the 300k floor); a maximal 8,190-byte text body validates under the default floor. SELF references cannot bootstrap in codec 1 (only required leading references). (19) Consumer surface as built: `EfsNative.currentBind` binds the live execution set and the acceptance profile from `ILedgerCommitments(ledger.ingress()).acceptanceProfileOf(ledger, actions)` (principal-independent, the same fold `prepareNative` checks); the kernel's refusal of a bound native expectation is `E_EXECUTION_SET` (§5.6), `E_EXPECTED_SET` is the activation's own check; a proxy's initializer cannot write (`E_NATIVE_AMBIGUOUS`: no code during construction) — apps register in the initializer and write later; `ITypeRegistry` carries `FACTORY`, `DESCRIPTOR_STORE`, `predictInstance`, `declarationDigest` and `bindingDigest` so an outside app registers a NATIVE Type without importing the concrete registry; the `ReaderDirectory` implements `IReaderDirectory` of `Readers.sol` (`list`, paged `readers`, `count`; `E_READER` codes 1 listed, 2 another ledger, 3 malformed reply, 4 full). (20) Upgrade proof at the Files level: `test/upgrade/PopulatedUpgrade.t.sol` activates a new `LedgerCore` with a new ingress and apply pin over a seeded Realm and proves the §16.5 #12 invariant with `StateDigest.rowsOnly` (the row digest without the realm words), identical reads through both facets and the index, the stale bound plan refused with its nonce intact, the exact retry `AlreadyAdmitted`, and a new write under the new pins.

**Path shorthand.** `L/` = the prototype (lab-b at revision `4fbea63a`, archived under the planning vault's `Reviews/2026-09-12-efs-path-decision/`); `AN/` = `planning/Reviews/2026-10-20-contracts-v2-design-record/analysis/`; `D/` = `planning/Reviews/2026-10-20-contracts-v2-design-record/design/`; `REPO` = this repository; `OZ` = `dependencies/@openzeppelin-contracts-5.6.1`; `OR` = `planning/Designs/efsv2/owner-rulings.md`; `PTA` = `planning/Designs/efsv2/programmable-type-acceptance.md`.
---

## 0. Thesis

**Every path that can change what an admitted publication means is a numbered, idle-gated, controller-executed activation that the kernel records as a revision; every other path is permissionless; the terminal activation removes the controller without changing the Realm's identity, and nothing the terminal state depends on is a number the chain can reprice out of existence.** The kernel (`LedgerCore`, behind an OpenZeppelin 5.6.1 Transparent proxy) owns every canonical row and runs the ordered single-pass admission the prototype proved with 485 tests, keeping only the invariants it must enforce at the one guarded commit boundary. Its writes are split across two codehash-pinned delegates it alone can reach: `LedgerApply` (the per-action writers, executing under the kernel's lock in the kernel's storage) and `LedgerIngress` (zero-write: lanes, codecs, acceptor validation, commitments, allowance, index dispatch, activation readiness). Everything that grows — authorship lanes and verifier suites, Type codecs and wrappers, index generations and families, readers, profiles, limits — lives behind codehash-pinned, replaceable units installed only by activation: immutable versioned read facets (`LedgerReads`, `LedgerViews`) at their own addresses, a proxied append-only `TypeRegistry` with external factories, one immutable `RealmIndex` dispatcher per generation writing into per-Realm storage-owning family stores that outlive generations, immutable readers found through an advisory `ReaderDirectory`, and a hand-rolled replaceable `RealmController` that is the sole owner of both `ProxyAdmin`s and exposes no raw upgrade or ownership path.

Four consequences. First, **upgrade-without-activation is impossible by construction**: the only call sites of `ProxyAdmin.upgradeAndCall` are inside `RealmController.activate`, the controller's own code is pinned by codehash and opcode-scanned at migration, and the revision row is written before any write can land under new code; the kernel's per-write live-implementation and registry-revision compares are tripwires, not the guarantee. Second, **the kernel never grows**: its ABI is three calldata-only write selectors (the third, `importPublication`, reserved and stubbed from S1 so the size budget sees it), five control selectors and an Etched set of one-word reads; adding a lane, a verifier, a reader, a family or a Files Type changes no kernel byte. Third, **"upgradeable on testnet" and "immutable later" are one design**: `freeze()` activates the terminal revision (registry first, then ledger) after liveness pre-checks, publishes one canary record per enabled lane, renounces both `ProxyAdmin`s and the controller in one transaction, and `describe().frozen` reports it; writes, reads and permissionless Type registration continue forever at the same addresses. Fourth, **no frozen constant is a liveness ceiling**: the index allowance, acceptor gas and the ERC-1271 wallet call are availability floors the submitter satisfies with `tx.gas`, never post-call caps, so a gas repricing after the freeze changes what a write costs, never whether it can land.

---

## 1. What this document settles

### 1.1 Fatal flaws fixed (from the three judgments and the six reviews)

| Flaw | Fix here | Section |
|---|---|---|
| Winner: `RealmController` not replaceable | `migrate(successor, set)` is an activation; the successor's codehash is a component of the execution set; both `ProxyAdmin`s move inside the activation; the registry obeys whoever the ledger names as controller, so a migrated Realm keeps activating and can freeze | §8.5 |
| Winner: kernel budget 20.5 KiB after S2 | Budget 19,660 B per unit measured against the *full* kernel ABI (signed lane and import stub included at C1); writing delegate `LedgerApply` is the S1 shape, not a contingency; attribution snapshot per PR; cut ladder pre-decided | §3.2, §15 |
| Winner: native lane has no deadline | `Native.deadline` (0 = none), enforced when nonzero, stored at full width in evidence `w1` | §6.2, §7.3 |
| Winner: acceptors do not receive the publishing principal | `IAcceptor.accept(AcceptContext, body, refs, RefHeader[])` with `principalId`, `admission`, `revision`, `realmId`, `ledger`, `index`, `registry`, descriptor blob, predicate, `bindingId`, grade | §5.10, §6.4 |
| Winner: controller-owner change recorded, not an activation | Owner change is an activation; `controllerOwner` is a component; no inherited no-arg `acceptOwnership` or `renounceOwnership` exists | §8.4 |
| Size-first: acceptors read kernel storage through `extsloadBatch` + `Layout` | Refused. `Layout` lives in `core/layout/`, outside the consumer closure; acceptors read only the Etched `ILedgerHot` getters on `ctx.ledger` and the three header words of each reference | §5.10, §16.6 |
| Consumer-first: fallback-routed facet; format-1 `publicationId`; derived `intentDigest` | Facets at their own addresses, never in the execution set; `publicationId = keccak(DOM_PUBLICATION, principalId, intentDigest)`; `intentDigest` is pure over plan-intrinsic fields on every lane and is the retry key | §5.3, §6.3, §7.3 |
| Gas-first: proxied index; unmaterialized history | Immutable generations as dispatchers over storage-owning family stores; history materialized plus free `prevAdmission` chains; adding a family builds one store, never re-materializes the rest | §10 |
| Evolution-first: 8–9 fresh evidence slots per native publication | Native publication = 5 cell words + `publicationAt` = 6 fresh | §4.3 |
| Review: retry identity unstable across activations and after the deadline | Digest pure over caller inputs; `publicationAt` compare runs before every time- or state-dependent check; §6.6 recovery law restated at one block hash | §6.1–6.3, §6.6 |
| Review: index work model a hard cap in an immutable manifest; schedule-blind | Availability floor from a slot-count model converted with activation-set schedule constants; `E_ALLOWANCE` deleted; callbacks receive all available gas above the final reserve | §10.4, §6.4 |
| Review: genesis CREATE2 address cycle | One immutable `RealmGenesis` contract creates controller and both proxies by its own nonces; a later index generation that needs fresh stores is created together with them by a single-use `IndexDeployer` the same way, and `IndexBuild` holds no generation address | §8.2, §10.1 |
| Review: `reinitializer(set.revision)` collides with `initializer` | `reinitializer(uint64(set.revision) + 1)` on both proxied contracts | §5.4, §5.9 |
| Review: `Effect/2` packs sub-fields into a `uint8` | `Effect/3`: 24 explicit static words plus a shared `refs` array; vectored encoder | §5.11 |
| Review: NATIVE grade has no instance authority | Grade-3 descriptors carry the rule's initcode hash; the instance must be the CREATE2 address under the public factory with salt 0 | §9.3 |

### 1.2 Judge questions resolved here

| # | Question | Decision | Reason |
|---|---|---|---|
| 1 | Kernel read floor | An **Etched** `ILedgerHot` (§5.3): twenty-two one-word reads plus `extsload`/`extsloadBatch`/`exttload`; selectors and return layouts frozen at genesis with snapshot tests; no struct encoder on the kernel | Acceptors and pinned units call it; a kernel upgrade may add selectors, never change or remove one; each implementation lists the hot-ABI ids it serves (`SUPPORTED_HOT_ABI_IDS`) and activation checks membership, never a relation between hashes |
| 2 | Where `LedgerReads` lives | Separate immutable facets (`LedgerReads` exact rows + `describe`; `LedgerViews` composites); **not** in the execution set, not in the realm namespace, not in `AcceptContext`; discovered through `release.json` and the advisory `ReaderDirectory` | A reader fix is a redeploy that voids no plan and no cursor; acceptor validity cannot depend on a replaceable facet |
| 3 | Evidence closure | `principalId`, packed author/kind word, `nonce/deadline(u64)/basisBlock/revision/verifierProfile`, `intentDigest`, `actionsHash` on every lane; signed commitments for signed lanes; `readSetHash` when guarded; typed witness pair; flag bits record which native expectations were bound | `intentDigest` is the retry key and recovery anchor; native digests are recomputable from the row plus the two bound bits |
| 4 | Retry/exclusion map | `publicationAt[principalId][nonce] → ordinal`; equal stored digest → `AlreadyAdmitted(ordinal)`; different → `E_NONCE`; compared first, before deadline, expectation, read-set or signature checks | One slot serves retry identity, exclusion and recovery; a retry is never reclassified by what happened to the Realm since |
| 5 | Native-lane deadline | Optional, timestamp, `0 = none`, stored as `uint64` | FU5-R11 |
| 6 | Per-leaf basis re-check | Kept: `registry.mutations()` + ERC-1967 implementation word after every callback; `registry.activeRevision()` on entry | Ruling 3 as tested; ≈ 1k per leaf |
| 7 | Index generation model | Immutable dispatcher per generation; constructor-fixed manifest naming the family stores it writes; stores are per-Realm immutable storage contracts that accept writes only from `ledger.index()` once attached and, before attachment, only from the generation their constructor names; a later append-ordered family is built ascending from admission 1 into a fresh store before attachment; predicate families are order-free bitmaps hooked at declaration with per-scope coverage only for pre-declaration scopes | Decision 10 made true; backfill never runs against the strictly-increasing law |
| 8 | Freeze mechanics | Distinct `freeze(set)` entries on controller and ledger; terminal flag reachable only there; liveness pre-checks; canary publication; renounce both admins and the controller in one transaction | Half-freezes and dead-on-arrival terminal sets are unreachable |
| 9 | Controller replaceability and owner changes | Both activations, with `set.components.controller == address(this)` (successor in `migrate`) and `controllerOwner == owner()` checked after the ownership update | §1.1 |
| 10 | Structural-grade `ruleId` | The wrapper codehash named in the descriptor header; the Type row stores `grammarProfile` and the pinned wrapper | A Realm-local version table cannot make the same descriptor derive two ids |
| 11 | Scope stamps and live lists | `lastMutation` and the first 48 live bits in the scope head word of the `BitmapStore`; stamped on **every** bind-kind transition including REBIND and RESTORE | Measured CQ-10 kept; a rebind between pages refuses relaxed continuation |
| 12 | Realm-origin preimage | `realmOrigin = keccak(abi.encode(DOM_REALM_ORIGIN, genesisChainId, coreAddress, realmSalt))` (Q13) | The genesis chain id and the core address qualify contract principals, and `realmSalt` lets one deployer create several Realms on one chain without changing the derivation |
| 13 | `Effect` wire format | `Effect/3`: 24 static words (`target`, `oldTarget`, `targetKind`, `oldTargetKind`, `refCount`, `freshRecord`, withdrawn coordinate) + refs array | Folds need no head, position or body reads except the declared digest word |
| 14 | Body carrier at S1 | Inline words; `carrierKind` reserved | Inline words are the measured carrier; a code-blob carrier stays reserved behind capability b6 until Q4 and the C1 body row decide |
| 15 | Baseline families | Ruled set plus role-scope (16) and live-scope (18); roster (17) reserved; by-record virtual with a preimage-keyed read that synthesizes; digest (15) fed from genesis by the manifest's digest-spec table | Honest reads for virtual and digest families |
| 16 | Size line | 19,660 B per unit after the full kernel ABI; 17,500 warning; +15 % | 20 % under EIP-170 against the full ABI the kernel will ever carry; the warning line triggers the cut ladder before the budget does (the kernel's nominal estimate sits 1.1 KB under it, §3.2) |
| 17 | Signed-lane kernel ABI | Typed `Intent` (now with `author`) + opaque `guard` | Profile 2 binds the wallet to the principal |
| 18 | Native rows: store or derive commitments | Derive; two flag bits say what was bound | Question 3 |
| 19 | History physical form | Materialized family 8 plus `prevAdmission` chains; no shadow heads | Replay derives transitions from admission rows |
| 20 | Reference cap | 8 in codec 1 | Eight references cover every Files Type (each uses at most one) with room for S3 Types; a larger cap is a codec-2 question, never a kernel change |
| 21 | Transition deadline bound | `≤ limits.maxTransitionBlocks`; a target revision can be begun once, ever (`lastTarget` is written at `beginTransition`); cooldown after expiry or abort before the next target | A live controller cannot renew the pause and cannot pause more than half the time |
| 22 | S1 novelties | Measured mechanisms plus zero-semantic-risk packings; family stores and the apply delegate are structural, decided here, measured at C1 | Systems judge Q13 |
| 23 | Singleton wrapper vs clones | Singleton with `AcceptContext`; hostile-calldata suite at C1 | One wrapper instance per codec version serves every structural and custom Type; per-Type clones would multiply code deposits without adding isolation that the `ctx` checks do not already give |
| 24 | Chain acceptance | Activation only; refused after freeze; a terminal set must name `block.chainid` | §8.9, §8.10 |
| 25 | Registry drift residual | Proxied registry; implementation pinned per revision through `registry.implementation()`; `activeRevision()` compared on entry | §8.11 |
| 26 | Who implements | Q15 to James, with a recommendation | §21 |

---

## 2. Invariants and the privileged-path register

### 2.1 Invariants (each has a named test in §16)

- **I1 Single commit boundary.** All canonical writes happen inside `execute`/`executeSigned` under the transient lock — in `LedgerCore` or in `LedgerApply` running by `DELEGATECALL` in the kernel's context — or inside `activate`/`freeze` from the controller, or (the transition word only) inside `beginTransition`/`abortTransition`; `initialize` writes the realm namespace once, in the genesis creation transaction. No other code writes `efs.ledger.v2.*`; `LedgerApply`'s codehash is an implementation immutable re-verified on entry and inside `ledgerImplCodehash`'s build identity.
- **I2 Ordered single pass.** Per leaf: shape → mandatory rule → Realm policy (when a nonzero acceptor is active) → write → `_checkpoint` → index prefix `CALL` → basis re-check; then the final index `STATICCALL`; any failure reverts the publication and the enclosing application call.
- **I3 Zero-write helper.** `LedgerIngress` runtime contains no `SSTORE`, `TSTORE`, `CREATE`, `CREATE2`, `DELEGATECALL`, `CALLCODE`, `SELFDESTRUCT`; its delegate-only selectors revert when `address(this) == SELF`. The one external write it ever causes is `SignatureStore.put` under the STATE retention profile (§7.4), into the store's own namespace keyed by the calling proxy; the state-diff test allows exactly that target and nothing else.
- **I4 Exact retry.** For every lane, an identical resubmission reverts `AlreadyAdmitted(ordinal)` with no state change at any later block, whatever activations (chain-acceptance changes included: the signed retry key is chain-free, §6.1), policy activations, index replacements, head changes, deadline expiries or wallet key rotations happened in between; a different plan under a consumed nonce reverts `E_NONCE`.
- **I5 Activation is the only semantic change.** The set of paths that change an implementation, the apply delegate, the ingress, the index generation, the controller, its code, its owner, the accepted chain, the limits or a registry policy/role/wrapper row is exactly `{RealmController.activate, acceptOwnershipAndActivate(set), migrate(successor, set), freeze(set, canaries), activatePolicy, declareRoleExpectation, activateWrapper}`; the first four write a revision row, the last three append registry rows recorded per admission. The selector-surface test (§16.6) asserts that the only other state-changing externals of the ledger, the registry and the controller are the write lanes (and the import stub), `beginTransition`/`abortTransition`, `transferOwnership` (pending only), permissionless registration and `initialize`.
- **I6 Revision inside consent.** `executionSet` includes the revision ordinal; same-code reactivation and rollback refuse every pending signed plan, every bound native plan and every cursor.
- **I7 Identity discipline.** `Keys.sol` derivations with golden vectors; no proxy address, implementation codehash, chain id, compiler metadata or Realm-local table in any permanent id except the genesis `realmOrigin` that qualifies contract principals; `bytecode_hash = "none"`.
- **I8 Reserved means refused.** Every reserved enum value, sentinel, bit, action kind and namespace reverts with a typed error and leaves the raw-slot digest unchanged.
- **I9 Honest coverage.** `coverage(family, scope)` returns `COMPLETE` only when the family is declared, `from == 1`, `through == counts().admissions` (the staged frontier inside a publication) and not gapped; the returned `phase` says whether that completeness is committed (`IDLE`) or an ordered prefix inside the active publication (`APPLYING`/`FINAL`). Readiness and committed-state readers require `phase == IDLE`; developer rules may consume prefix-`COMPLETE` (ruling 21). `UNKNOWN`/`PARTIAL` never render as empty.
- **I10 Readable in the same block.** Every admitted publication is readable in full through the facets at the admission block.
- **I11 Floors, never ceilings.** No kernel refusal depends on a callback, acceptor or wallet having spent less than a stored number; refusals of the gas class name what was quoted and what was available and carry retry class `resubmit`.

### 2.2 Privileged-path register (threat → defense → test)

Attacker classes: **U** unprivileged author/relayer, **T** Type owner, **I** index/extension author, **A** controller owner or key, **R** reader/RPC.

| # | Surface | Attacker | Threat | Defense | Test (§16) |
|---|---|---|---|---|---|
| S1 | write entry | U | reentrancy from any callback | transient lock read through `phase()`; every write, activation, transition, policy/role/wrapper activation, replay, build and backfill requires `IDLE` | `AttackIndex` port; reader-in-final-phase sees `phase != IDLE` |
| S2 | native author | U | constructor-time impersonation; 7702 misclassification | `principalFor` exact 23-byte `ef0100` rule (`L/src/Keys.sol:72-84`); `E_NATIVE_AMBIGUOUS` for a code-less caller that is not `tx.origin` (a contract under construction) — the only read of `tx.origin` in the system, which never authorizes or attributes (the prototype's check, `L/src/Ledger.sol:457`) | `FoundationIdentity` port; real type-4 fixture at S2 |
| S3 | acceptor `STATICCALL` | T | returndata bomb; forged kernel errors; hostile Type burning gas; dependency drift | assembly `staticcall` with a 32-byte output buffer and `returndatasize() == 32`; revert data discarded; exhaustion classified `E_ACCEPTOR_GAS`; a hostile rule can burn only the submitter's own `tx.gas` (disclosed: relayers bound exposure by simulation and gas limit) | returndata bomb; two-Type batch with one hostile; mutable-dependency rule rolls back the app |
| S4 | index `CALL`/`STATICCALL` | I | prefix writes surviving a final refusal; oversized returndata; permissive fallback; final-phase starvation; config reentry | availability floor with a withheld `finalReserve`; exact 32-byte selector ack; 4,096-byte bound before copy; empty-returndata failure → `E_INDEX_GAS` (resubmit); attached stores accept writes only from `ledger.index()`, an unattached fresh store only from the generation its constructor names (§4.6); idle-gated config | `CoreOrderedAcceptance`, `MatchedRollback` ports; starvation fixture; floor fixture |
| S5 | `LedgerIngress`, `LedgerApply` | A, U | helper writes; open relay; substitution | codehashes pinned as implementation immutables and re-verified per publication; delegate-only guards; ingress zero-write by state-diff (the `SignatureStore` target excepted under STATE retention, §7.4) and opcode lint; apply delegate writes only `efs.ledger.v2.*` (state-diff) | direct call to every delegate selector reverts; etched helper → `E_HELPER_CODE` |
| S6 | code gates | T, I, A | 7702 designators, proxies, delegating runtimes behind a pinned codehash | `CodePins.requireRealCode` (nonzero code, not the designator shape) **and** `CodeScan.requirePlainRuntime` (no `DELEGATECALL`/`CALLCODE`/`SELFDESTRUCT`/`CREATE`/`CREATE2` outside push data; not ERC-1967/EIP-1167 shapes) at wrapper activation, policy activation, `activate` (apply, ingress, index, build, stores, units, steward), controller migration; the two proxied implementations are pinned by codehash and validated by `upgrades-core`, never opcode-scanned, because the ledger implementation must `DELEGATECALL` its two delegates; third-party NATIVE rules are pinned by deterministic instance and carry a declared, unverified dependency class | parametrized over every gate |
| S7 | `ProxyAdmin`/controller | A | swap without activation; admin-slot divergence; stuck or renewed transition; invisible owner change | both `ProxyAdmin`s owned by the controller with no passthrough; `upgradeAndCall` only inside `activate`; controller codehash in the execution set; ERC-1967 slot compared on entry; one bounded transition per target with cooldown; owner change, migration and freeze are activations with the owner/controller fields verified | upgrade matrix; freeze ceremony; migration then activation then freeze through the successor |
| S8 | registry implementation | A | upgraded without activation; lies about itself | only `activate` upgrades it; `registry.activeRevision()` compared on entry and at activation; `registry.implementation()` codehash pinned in the revision row; `mutations()` per callback; residual disclosed | registry-only activation; `test/security/RegistryDrift.t.sol::test_activeRevision_mismatch_halts_writes` |
| S9 | genesis | U | initializer front-running; salt squatting; address cycle | one `RealmGenesis` CREATE2 contract creates controller and proxies by its own nonces and initializes each in its creation; constructors derive no authority from `msg.sender`; a stranger's replay yields identical addresses or reverts | stranger replays `deploy/plan.json` |
| S10 | nonce / replay | U | cross-deployment replay; relay after deadline; griefing | chain-bound EIP-712 domain plus `realmId`, `realmOrigin`, `executionSet`, nonce, deadline in the struct; per-principal nonce namespace shared by lanes | second Realm same code; after deadline; double relay |
| S11 | bodies / identity | U | non-canonical tail; occurrence overflow | masked tail words; 48-bit guards fail closed | canonicalisation fuzz; saturation |
| S12 | withdrawal | U | withdraw another's occurrence; double withdraw | retained principal compared; withdrawn bit; checked subtraction | `test/unit/kernel/Withdraw.t.sol::test_codes_0_to_3` |
| S13 | reads | R, T | forged custom errors; helper-as-correctness; `UNKNOWN` collapsed to absence | `E_INDEX_CALL(bytes)` nesting; status enums with `UNSET = 0` and a basis echo; readers resolve the live index per call | `FaultyReads` over every reader |
| S14 | singleton wrapper | T | forged `AcceptContext` | the wrapper recomputes `typeId` from the blob, its own codehash and the predicate codehash and compares with `ctx.typeId`; requires `ctx.ledger == msg.sender`; the predicate authenticates `msg.sender.codehash == wrapperCodehash`; all calls `STATICCALL` | `test/security/WrapperContext.t.sol` (the hostile-calldata suite, C1) |
| S15 | controller migration | A | migrate to a hostile successor | an activation; successor codehash pinned in the set and opcode-scanned; owner disclosed | migration row |
| S16 | post-freeze residual through a pinned dependency | A | a proxy, allowlist-reading or 7702 policy acceptor, wrapper or unit keeps administrator power after `frozen == true` | `CodeScan` at every EFS code pin except the two proxied implementations (codehash-pinned, `upgrades-core`-validated); freeze checklist enumerates every write-path dependency with its codehash and dependency class in `release.json`; terminal revision row records `dependencyRoot`; third-party NATIVE rules disclosed per declared class | freeze rehearsal checklist; a 7702 or proxy acceptor refused at `activatePolicy` |
| S17 | 1271 lane | U | a magic-returning wallet claims a victim principal | `contractPrincipal(realmOrigin, intent.author) == intent.principalId`, real code, not key-classified, before the `isValidSignature` call | `1271 wallet != principal → E_SIGNATURE(6)` |
| S18 | fresh index store | I, U | a stranger pre-writes keys of a reserved or future family (for example roster 17, or a new principal's `by-author` key) before the real generation builds them, so the real build hits `E_ORDER` or squatted entries are later reported `COMPLETE` | attached stores refuse every writer but `ledger.index()`; an unattached store accepts only the generation its constructor names as `INITIAL_WRITER`, only for its constructor-fixed `FAMILY_IDS`, and that right lapses at attachment; a family's store is named by the manifest, so a stranger's store is never attached (§4.6) | `test/index/StoreWriter.t.sol::test_stranger_prewrite_of_reserved_family_refused`, `::test_attached_store_refuses_non_index_writer` |

---

## 3. Module map and size strategy

### 3.1 Physical units

Budgets: ≤ 19,660 B runtime per deployable (20 % under EIP-170) measured against the **full kernel ABI the kernel will ever carry before freeze** (both lanes, the `importPublication` stub, every control selector, the Etched hot reads); 17,500 B warning line; initcode-with-arguments ≤ 36,864 B; EIP-7954's 64 KiB (live on Sepolia since 2026-10-06, no mainnet date) is reserve, never budget (`REPO/docs/GAS-SCHEDULES.md`). Internal libraries inline and count as bytes in every caller. Estimates carry a +15 % pessimistic multiplier because every optimistic estimate in the record was wrong (`AN/proto-problems-ledger.md` P1). Where a measured analog exists, the estimate is **top-down from that analog**, never bottom-up from attribution rows (`D/judge-kernel-correctness.md:26`).

| # | Unit | Kind | Owns state | Calls out | Who may call | Runtime nominal / pessimistic (basis) | Upgradeable |
|---|---|---|---|---|---|---|---|
| 1 | `LedgerCore` | proxied implementation (OZ 5.6.1 Transparent) | every canonical row (§4); transient lock | `LedgerApply` (`DELEGATECALL` per leaf), `LedgerIngress` (`DELEGATECALL`: prepare, validateLeaf, dispatchIndex, checkActivation), registry (`STATICCALL` `typeInfo`, `roleExpectation`, `mutations`, `activeRevision`), index (through the ingress dispatcher) | anyone (write lanes); controller (control selectors) | **16,400 / 18,900** (§3.2; rungs 1–3 of the ladder give ≈ 15,000 / 17,250) | by activation only |
| 2 | `LedgerApply` | immutable writing delegate; codehash immutable of the implementation; executes only in kernel context | none of its own; writes `efs.ledger.v2.{records,subjects,admissions,bindings}` through `Layout` under delegatecall | none | ledger only (delegate-only guard) | **7,600 / 8,700** (measured apply arms 7,897 B − `_accept` 533 − `_checkRefs` 456 + Effect/3 building ≈ 700) | per release (new pin → activation) |
| 3 | `LedgerIngress` | immutable, stateless, zero-write delegate; codehash immutable of the implementation; its own address serves `ILedgerCommitments` | none; reads ledger storage through `Layout` under delegatecall | registry (profile fold, `typeInfo`, `refTypes`, `roleExpectation`), acceptors (bounded assembly `STATICCALL`), index (bounded `CALL` + final `STATICCALL`), verifier precompiles, `CodeScan` at activation | ledger only for delegate selectors; anyone for commitment views | **S1 11,500 / 13,200; S2 15,500 / 17,800** (measured `PublicationSupport` 12,884 B with six lanes; v2: two lanes + guard codec + validateLeaf + floor quoting + dispatch + readiness incl. opcode scan + commitments) | per release |
| 4 | `LedgerReads` | immutable, stateless, versioned by `layoutId`; reads the proxy by `extsloadBatch` through `Layout` | none | ledger `extsload*`/hot getters; registry views; index `coverage`/`manifestHash` | anyone | **12,000 / 13,800** (exact-row views: raw getters 1,659 measured-equivalent + struct encoders + `describe()` ≈ 1.5 KB + ≈ 405–450 B per forwarded read × 16, `AN/followup-3.md:104`) | redeploy; old versions stay valid |
| 5 | `LedgerViews` | immutable, stateless facet (composites) | none | `LedgerReads`, ledger, registry, index | anyone | **11,000 / 12,700** (`publication()` with Effect/3 reconstruction, `headsAt`, `heads`, `records`, `acceptanceBasis`, `historyAt`, `headSnapshots`) | redeploy |
| 6 | `TypeRegistry` | proxied implementation | types, refTypes, policy rows, role rows, bindings, wrappers, catalog, control (§4.5) | `DescriptorStore` (`extcodehash`), ledger `phase()`/`controller()`/`control()` (gates), `CodeScan` | anyone (registration); controller (activations); ledger/ingress (hot reads) | **12,500 / 14,400** (measured 14,914 B incl. ≈ 4.4 KiB embedded wrapper initcode → ≈ 10.5 KB logic; − opaque path/`CREATE` ≈ 0.8 KB; + grades, CREATE2 instance check, descriptor cap, wrapper codehash check, role rows, catalog, EIP-712 declaration verify, `Initializable`/7201, `implementation()` ≈ 2.8 KB) | by activation only |
| 7 | `DescribedTypeRule` v1 | immutable, stateless **singleton** wrapper | none | custom predicate (bounded nested `STATICCALL`), descriptor blob (`extcodecopy`) | ledger-context ingress via `IAcceptor.accept` | **5,200 / 6,000** (measured 4,380 B + codec-1 header extensions + context checks incl. `ctx.ledger`) | never; new version = new contract + `wrappers` row |
| 8 | `DescriptorStore` | immutable CREATE2 factory of STOP-prefixed blobs (`0x00 ‖ descriptor ‖ declarationSig`); refuses blobs > 24,576 B | none (blobs are code) | — | anyone | **1,000 / 1,200** (one CREATE2 + hash + length check) | never |
| 9 | `RealmIndex` gen *g* | immutable **dispatcher** per generation; no posting storage; constructor-fixed manifest naming families, stores, units, digest specs, work model, profiles | progress word and `buildFrontier` per family being built (`efs.index.v2.gen.<g>`; coverage slots live in `BitmapStore`) | `PostingStore`/`BitmapStore` (`CALL`), ledger hot getters, registry `typeInfo`, `IndexReplayDecoder`, `IndexBuild` (`DELEGATECALL` for `replayNextPublication`/`build`/`backfill`), fold hooks (bounded `CALL`), final hooks (bounded `STATICCALL`) | ledger-context dispatcher (`onAdmission`, `afterPublication`); anyone (reads, and the three idle-gated build entry points) | **12,500 / 14,400** (top-down: measured Files-capable index 20,981 B − posting/scope storage code moved to stores ≈ 5.5 KB − replay/build drivers moved to `IndexBuild` ≈ 4 KB + Effect/3 decode, unit iteration, digest specs, coverage ≈ 1 KB) | replaced by activation |
| 10 | `PostingStore` | immutable per Realm and family set (constructor-fixed `FAMILY_IDS`, `INITIAL_WRITER`); append-ordered posting lists for kinds 1, 4, 5, 8, 11, 12 (materialized part), 13, 14, 15, 16 | `postingHead`, `postingWord`, `writers`, `attached` | ledger `index()` (authorization), `phase()` | `ledger.index()` for live writes once attached; the constructor-named `INITIAL_WRITER` before attachment; anyone for reads | **5,500 / 6,300** (measured `_append`/`_release` + packed-word reads ≈ 2.5 KB + writer gate + `postingHeadOf` preimage reads + oracle getters) | never (a fresh store per new family set, built before attachment; a fresh replayed store is the heal path) |
| 11 | `BitmapStore` | immutable per Realm; the kind-10 scope lists (append-ordered binding ordinals, first entry inline in the head word) with their head words (`lastMutation`, 48 inline live bits); order-free bitmaps for live-scope (18) and later predicate families; coverage slots for pre-declaration scopes | `scopeHead`, `scopeEntry`, `bits`, `coverage`, `writers`, `attached` | ledger `index()`, `phase()` | same | **5,000 / 5,800** (scope-list append with packed words ≈ 1 KB, set/clear/stamp, `liveWords`, `liveAt` bisection, coverage slots) | never (replayed) |
| 12 | `IndexBuild` | immutable per `(layoutId, callbackProfile)`; the codehash-pinned delegate a generation `DELEGATECALL`s for `replayNextPublication`, `build(family)` and `backfill`; holds no generation address, so no address cycle | none of its own; in the generation's context it writes `efs.index.v2.gen.*` and calls the stores *as* the generation | decoder, stores, ledger, registry | the generation only (delegate-only guard) | **6,000 / 6,900** | per layout or callback-profile version |
| 13 | `IndexReplayDecoder` | immutable per `layoutId`; pinned by the generation | none | ledger `extsloadBatch` via `Layout` | index (directly or through the `IndexBuild` delegate) | **5,200 / 6,000** (measured 4,359 B + revision validation + Effect/3 reconstruction incl. `oldTarget` from the previous bind row) | per layout version |
| 14 | `FilesFinalValidator` | immutable extension unit (final hook), pinned in the gen-1 manifest; no caller pin (pure view over calldata + hot getters) | none | ledger hot getters (`subjectCreatedAt`, `recordHeader`), `Effect/3` calldata | anyone may call; only the index's call matters | **5,500 / 6,300** (measured 5,417 B) | per generation |
| 15 | `RealmController` | ordinary immutable contract; hand-rolled two-step ownership; `CodeScan` | owner, pending owner, `frozen` flag (set only by `freeze`), `retired` flag (set only by `migrate`) | `ProxyAdmin.upgradeAndCall` ×2, `transferOwnership` ×2 (migrate), `renounceOwnership` ×2 (freeze), ledger `activate/freeze/beginTransition/abortTransition`, registry `activate/activatePolicy/declareRoleExpectation/activateWrapper`, ledger `execute`/`executeSigned` (freeze canaries) | owner; anyone for `abortTransition` after the deadline | **6,000 / 6,900** (ownership ≈ 0.5 KB + sequencing + ceremony + scan ≈ 0.9 KB) | replaced by `migrate` |
| 16 | `RealmGenesis` | immutable, single-use CREATE2 contract | genesis journal (addresses) | `CREATE` ×3, `initialize` ×2 | anyone (one `run()`; idempotent) | **3,000 / 3,500** | never |
| 17 | `ReaderDirectory` | immutable, permissionless, append-only | `(ledger, kind) → [(reader, codehash, layoutId, physicalProfile)]` | `IReader(reader).ledger()` | anyone | **1,500 / 1,800** | never |
| 18 | `LensReader` v1 | immutable, stateless, versioned; resolves the live index per call | none | `LedgerViews.headsAt`, index `coverage`, store reads | anyone | **12,000 / 13,800** (measured 15,006 B − probe loop absorbed by `headsAt` ≈ 3 KB − address APIs ≈ 1 KB + `resolveRecord` + per-call index resolution) | redeploy; listed in `ReaderDirectory` |
| 19 | `FilesPageReader` v1 | immutable, stateless, versioned | none | `LedgerReads`, `LedgerViews`, index, stores, `LensReader` | anyone | **15,000 / 17,300** (measured 16,966 B − substring search − assembly name buffer + `Page` struct + continuation binding) | redeploy |
| 20 | Profile validators (`files-root/1`, `files-child/1`, `files-directory/1`, `files-name/2`, `files-bytes/1`, `files-content/1`, `files-external/1`, `directory-alias/1`, `realm-notice/1`, `RefuseAllPolicy`) | immutable, isolated compile closure, `runs = 1` profile | none | `ILedgerHot` on `ctx.ledger` only; no `extsload`; no immutables (release gate: empty `immutableReferences`) | ingress via `IAcceptor` | 0.4–1.5 KiB each (`files-name/2` measured 1,477 B) | never; a change is a new Type |
| 21 | `ProxyAdmin` ×2, `TransparentUpgradeableProxy` ×2 | OZ 5.6.1 stock | ERC-1967 slots | — | controller | 879 / 761 B (measured, `AN/followup-3.md` §4) | admins renounced at freeze |
| 22 | `SignatureStore` (S2b) | immutable write-once store for ERC-1271 bytes (≤ `limits.maxWitness`), namespaced by calling proxy | carriers | — | ingress (the S2b ingress build's `SIGNATURE_STORE` immutable; listed in `release.json` and `dependencyRoot`) | ≈ 2,000 (measured 1,824 B) | never |
| 23 | `BodyStore` (reserved; C1 alternative) | immutable CREATE2 factory of `0x00 ‖ body` blobs | blobs | — | anyone | ≈ 600 | never |
| 24 | `IndexDeployer` | immutable, single-use CREATE2 contract per later generation that needs fresh stores; creates the stores and then the generation by its own nonces (the `RealmGenesis` pattern, §10.1) | deployment journal | `CREATE` × (fresh stores + 1) | anyone (one `run()`; idempotent) | **2,500 / 2,900** | never |
| L1 | `Keys` | internal library (consumer closure) | — | — | everyone | inline ≈ 0.4 KB | tags are one-way doors |
| L2 | `Layout` | internal library generated from the committed `storageLayout` snapshot; lives in `src/core/layout/` | — | — | `core/`, `control/`, `index/`, `readers/LedgerReads`, `readers/LedgerViews`, tests; the SDK gets `vectors/layout.json` and a generated TypeScript twin (lint: `checks.mjs` allows `core/layout/` to be imported from `index/` and the two facets by a path allowlist, keeps every other `core/` import limited to `core/` and `control/`, and refuses any other importer of `Layout`; S0) | inline | re-versioned with `layoutId` |
| L3 | `Actions`, `Results`, `Errors`, `Limits` | internal libraries / interfaces (consumer closure) | — | — | everyone | inline | ABI snapshot in CI |
| L4 | `EfsNative`, `EfsFiles`, `FilesTypes` (generated, in `profiles/`) | consumer-closure builders; `EfsFiles` takes Type ids from `FilesTypes` or as arguments | — | `ILedger.execute`, `ILedgerHot.nonceOf` | applications | ≈ 1–2 KB in an app | versioned with the closure |
| L5 | `DescribedCodec` v1 | internal library | — | — | registry, wrapper | inline ≈ 2–3 KB | codec version in the header |
| L6 | `CodePins`, `CodeScan` | internal libraries (`requireRealCode`, `requireCodehash`, `requirePlainRuntime`) | — | — | kernel, ingress, registry, controller | inline ≈ 0.2 KB / ≈ 0.9 KB | — |

Trust-boundary summary: two proxied contracts (`LedgerCore`, `TypeRegistry`), one controller that is the sole owner of both `ProxyAdmin`s and the sole caller of every privileged function, two kernel delegates pinned by implementation immutables, everything else immutable and codehash-pinned from an activation record. Only `CALL`/`DELEGATECALL`/`STATICCALL` boundaries move bytes; internal libraries do not.

### 3.2 The kernel estimate, line by line (S1 shape: kernel + `LedgerApply`)

| Component | Bytes | Basis |
|---|---:|---|
| Loop and per-leaf glue (`_run`, `_begin`, dispatch to `LedgerApply`, `_checkpoint`, final, lock) | 2,200 | measured `_run` 929 + `_beginPublication` 1,155 (`AN/proto-ledger-kernel.md` §1.9) − apply arms moved out + delegate glue |
| Evidence writer (5 native words, sparse signed words), `publicationAt` compare, `viewMutationVersion` bump, flag bits | 600 | prototype `_writeEvidence` 457 B |
| Delegate/static glue (`_prepare`, `_validateLeaf`, `_applyLeaf`, `_notifyIndex`, `_checkActivation` DELEGATECALL, reply bounds) | 2,000 | measured 1,502 + two more delegate entries |
| Live-set tripwires (impl-slot compare, `extcodehash(APPLY)`, `extcodehash(INGRESS)`, `registry.activeRevision()`, `mutations()` per leaf) | 500 | replaces 1,039 B of recomputation |
| `TypeInfo` decode from the registry and re-encode into the `validateLeaf` payload (17 fields) | 500 | new line; the prototype's tuple had 7 values (`L/src/IndexModule.sol:255`) |
| `initialize`, `activate`, `freeze`, `beginTransition`, `abortTransition`, revision-row writer (25 words), lazy `TransitionEnded(3)`, migration-scope check | 1,700 | prototype admin 433 B did no readiness work |
| Dispatcher (≈ 30 selectors) | 400 | via-IR ≈ 11 B per selector + split |
| Shared codec pool (calldata bounds for `Action[]`/`bytes[]`, keccak/memory helpers, ≈ 40 error stubs) | 2,000 | prototype pool 7,300 B held memory decoders for four dynamic shapes; this design forwards intent/guard/witness undecoded |
| Per-selector wrappers: three lane wrappers (`execute`, `executeSigned`, `importPublication` stub that decodes then reverts `E_RESERVED`) ≈ 460 each; five control wrappers ≈ 150 | 2,300 | measured 150–460 B per wrapper |
| Lane bodies | 700 | measured 2,376 for six lanes + conveniences |
| Etched hot reads (22 typed one-word getters incl. `noticePrincipal`, `supportedHotAbiIds`, `extsload`, `extsloadBatch`, `exttload`) | 2,300 | one-word getters ≈ 80 B; `head`/`recordHeader` unpackers ≈ 200 B each; `extsloadBatch` ≈ 350 B; the constant-list getter ≈ 150 B |
| OZ `Initializable` + ERC-7201 accessors | 600 | OZ 5.6.1 |
| Transient lock + `phase` | 100 | `TSTORE`/`TLOAD` |
| Events (`Published`, `Admitted`, `Activated`, `TransitionBegun`, `TransitionEnded`, `ReadSetChecked`, `WitnessRetained`; `Frozen` is a controller event, §5.12) | 500 | prototype events ≈ 300 B |
| Trailer (`bytecode_hash = none`) | ≈ 10 | identity policy D1: `bytecode_hash = "none"` with `cbor_metadata = true` keeping only the 3-byte solc version trailer (`REPO/tools/checks.mjs:34-35`) |
| **Nominal** | **≈ 16,400** | the fifteen rows above sum to 16,410; 1.1 KB under the 17,500 warning line |
| **Pessimistic (+15 %)** | **≈ 18,900** | over the warning line, ≈ 760 B under the 19,660 budget; rungs 1–3 (≈ −1,400) give ≈ 15,000 / ≈ 17,250 |

`LedgerApply` (nominal ≈ 7,600): publish/reuse/bind/unbind/release/create/withdraw arms, `_admitRecord`, `_writeBinding`, body store/load with masked tail, head/position writes, Effect/3 construction (24 words into the kernel's effect buffer), 48-bit guards. It runs by `DELEGATECALL` once per leaf with `(leaf, Action, body calldata slice, typeInfo words, prepared principal)` and returns the Effect/3 record; cost ≈ 1–2k gas per leaf (calldata copy of nine words plus the body; estimate). Invariant I1 names both writers; the state-diff tests assert that no `SSTORE` outside `efs.ledger.v2.*` occurs in either.

**C1 decision rule (kernel).** Measured runtime ≤ 17,500 B: continue. 17,500–19,660: apply rungs 1–2, re-measure (the expected outcome if the measurement lands above nominal). > 19,660: rungs 1–3, re-measure (the expected outcome if it lands at pessimistic); never trim a check, never change the Etched hot ABI. The nominal estimate is 1.1 KB under the warning line and the pessimistic one is over it, so rung 1 is the expected C1 outcome, not a contingency. Ladder: (1) fold the ten rarest parameterised errors into code-carrying families (`E_SHAPE(leaf, code)` style) ≈ −300 B; (2) move the evidence writer and `_begin` into `LedgerApply` ≈ −700 B; (3) move the `TypeInfo` re-encoding into the ingress (`validateLeaf` takes `typeId` and refetches) ≈ −400 B. Registry rung: `DescribedCodec.parse/validate` to a pure `DescribedCodecV1` contract (≈ −2–3 KB). Index rung: digest-spec folding to a pinned unit. Readers rung: already split (`LedgerReads`/`LedgerViews`).

### 3.3 How sizes are measured and gated

1. `forge build --sizes` is the exit-1 gate on `src/`.
2. `test/snapshots/sizes.json` records runtime **and** initcode-with-arguments for every deployable with its budget; `test/size/Budgets.t.sol` deploys each unit through `vm.getCode` with real constructor arguments (the `RealmIndex` manifest inputs alone are ≈ 3.7 KB, so its initcode rule is runtime + manifest + ≤ 2 KB) and asserts both; CI diffs the snapshot.
3. `tools/attrib/` is the committed source-map attribution script; C1 and every release regenerate `test/snapshots/attribution.json`; `tools/checks.mjs` prints the per-function delta in every kernel-touching PR; error and event bytes are measured at S0 from a stub kernel carrying the whole catalog.
4. C1 compiles the **full kernel ABI**: `executeSigned` with real calldata decoding and the evidence arms (the verifier bodies may be stubs that revert after decoding), and the `importPublication` stub; the kernel number compared with the thresholds is that build's.
5. C1 runs twice: `evm_version = prague` for release bytes, `amsterdam` for the repriced gas report; the M1 rows run on `anvil --hardfork amsterdam` with `tx.gas` both below and above 2^24 and must give identical admission outcomes.
6. `forge inspect storageLayout` and `transientStorageLayout` snapshots are committed under `test/snapshots/layout/`; `@openzeppelin/upgrades-core` 1.46.0 `validate` runs against the previous release's build-info; a lint fails any shift or mask on a namespace word in `core/` that does not go through a generated `Layout` accessor; CI decodes a committed populated snapshot of the previous release through the new build's `Layout` and hot getters field by field.

---

## 4. Storage design

### 4.1 Namespaces and the layout manifest

ERC-7201 structs are declared in abstract storage contracts inside each implementation's inheritance chain so `upgrades-core` validates them. Root = `keccak256(keccak256(id) − 1) & ~0xff`. `Layout` (`src/core/layout/Layout.sol`) is **generated** from the committed snapshot and carries every root, mapping derivation and bit offset below; the kernel, the apply delegate, the ingress, the decoder and the facets pack and unpack through it (lint). `layoutId = keccak256("efs2/ledger-layout/1" ‖ canonical JSON of the layout manifest)` is an immutable of the implementation (`LAYOUT_ID`, with `PREDECESSOR_LAYOUT_ID` naming the one earlier layout the implementation can read), a word of the realm namespace rewritten by every activation, and a field of every revision row. Readers, the replay decoder and the SDK's slot codecs derive keys from `Layout` (`vectors/layout.json` is the SDK's copy); no contract outside `core/`, `control/`, `index/` and `readers/{LedgerReads,LedgerViews}` may import it (the `checks.mjs` path allowlist, S0). Widths: 48-bit admission, record, binding and publication ordinals and counters in storage (guards fail closed at 2^48 − 64, the one saturation threshold, with saturation tests), `uint64` in every ABI; revisions are `uint32` in storage and in every ABI; block numbers in the transition word are `uint48` in storage, in the two transition selectors and in `E_TRANSITION`; C1 measures one-versus-two `SSTORE` per hot row on both schedules and may re-version `layoutId` to 64-bit storage before genesis (pm R10) without touching any ABI.

| Namespace id | Contents | Written by |
|---|---|---|
| `efs.ledger.v2.realm` | realm identity, component pins, cached commitments, limits, transition, flags (§4.2) | `initialize`, `activate`, `freeze`; `beginTransition`/`abortTransition` (the transition word only) |
| `efs.ledger.v2.counters` | one packed word | every publication |
| `efs.ledger.v2.records` | `cell[recordId]`, `bodyWord[recordId][i]` | publish/reuse/withdraw (`LedgerApply`) |
| `efs.ledger.v2.subjects` | `subject[subjectId]` | create (`LedgerApply`) |
| `efs.ledger.v2.admissions` | `row[ordinal]` (2 slots; 1 for unbind/release) | every leaf (`LedgerApply`) |
| `efs.ledger.v2.publications` | `evidence[publication]` (sparse 13-word cell), `publicationAt[principalId][nonce]` | every publication (kernel) |
| `efs.ledger.v2.bindings` | `head[bindingKey]`, `bindingPosition[ordinal]`, `position[positionKey]` | bind kinds (`LedgerApply`) |
| `efs.ledger.v2.principals` | `principal[principalId]` (nonce ‖ viewMutationVersion) | every publication (kernel) |
| `efs.ledger.v2.revisions` | `row[revision]` (append-only, write-once, 25 words) | `activate`, `freeze` |
| `efs.ledger.v2.source` | reserved for `SourceEvidence` (S4); never written before | — |
| `efs.ledger.v2.staging` | reserved for stage-then-commit (action kinds 8/9); never written before | — |
| `efs.ledger.v2.lock` (**transient**) | `phase u8@0 \| stagedPublication u48@8 \| admissionFrontier u48@56 \| mutationsSnapshot u48@104 \| reserved` | every publication |
| `efs.registry.v2.*` | §4.5 | registry |
| `efs.index.v2.store.*` | §4.6 (per-Realm stores, coverage slots included) | `PostingStore`, `BitmapStore` (on behalf of their accepted writers) |
| `efs.index.v2.gen.*` | progress word, `buildFrontier` | the generation, in its own context (directly or through the `IndexBuild` delegate) |
| `openzeppelin.storage.Initializable` | both proxied contracts | initializers |

### 4.2 Realm namespace (`efs.ledger.v2.realm`, sequential slots from the root)

```text
+0  realmId            bytes32   keccak(DOM_REALM, realmOrigin, genesisExecutionProfileId)
+1  realmOrigin        bytes32   keccak(DOM_REALM_ORIGIN, genesisChainId, coreAddress, realmSalt)
+2  realmSalt          bytes32   genesis input, recorded in the deployment manifest
+3  control            genesisChainId u64@0 | acceptedChainId u64@64 | revision u32@128 | frozen u1@160 | reserved u95@161
+4  authority          controller u160@0 | executionProfileId u16@160 | capabilities u16@176 | genesisExecutionProfileId u16@192 | reserved u48@208
+5  registry           address u160@0 | reserved
+6  index              address u160@0 | indexGeneration u32@160 | reserved
+7  executionSet       bytes32   cached at activation
+8  layoutId           bytes32   := set.layoutId at every activation
+9  domainSeparator    bytes32   cached at activation (EIP-712, chain-bound; recomputed on chain-acceptance change)
+10 indexObligations   bytes32   cached at activation = keccak(index, indexCodehash, indexManifestHash)
+11 steward            address u160@0 | reserved   (zero at S1; freeze posture B seam)
+12 limitsProfileId    bytes32   = keccak(abi.encode(Limits))
+13 limits0            maxActions u16@0 | maxBody u32@16 | maxRefs u8@48 | maxReadSetPrincipals u16@56 | maxReadSetPositions u8@72
                       | maxWitness u16@88 | maxTransitionBlocks u32@104 | inlineWordMax u16@136 | witnessRetention u8@152 | reserved u96@160
                       (witnessRetention: 1 LOG_ONLY 2 STATE = the Retention enum; 0 and 3..255 refused)
+14 limits1            maxBindsPerPublication u16@0 | maxBodyBytesPerPublication u32@16 | maxFreshSlotsPerPublication u32@48
                       | maxReadIds u16@80 | maxReadCount u16@96 | floorFreshGas u32@112 | floorRewriteGas u32@144 | kernelTail u32@176 | reserved u48@208
+15 transition         target u32@0 | deadline u48@32 | lastTarget u32@80 | cooldownUntil u48@112 | reserved u96@160
                       (lastTarget is written by beginTransition; cooldownUntil by abortTransition and, lazily, by the first beginTransition/activate that observes an expiry; §8.8)
+16 readerDirectory    address u160@0 | reserved   (genesis constant; advisory discovery only)
+17 noticePrincipal    bytes32   := set.noticePrincipal at every activation; the only principal allowed to author realm-notice/1 {kind: successor} records; 0 = no successor path
```

The ingress and the apply delegate are **not** stored: they are immutables of the implementation (`INGRESS`, `INGRESS_CODEHASH`, `APPLY`, `APPLY_CODEHASH`), served by `ingress()`/`applyDelegate()` from the immutables, and the revision row records the values the activated implementation carries. `capabilities` bits: b0 `NATIVE_GUARD`, b1 `SIGNED_SECP256K1`, b2 `ERC1271`, b3 `P256_WEBAUTHN`, b4 `STATEFUL_RULES`, b5 `IMPORT`, b6 `CODE_BLOB_BODIES`, b7 `ROUTED_CONSENT`, b8 `KEL_AUTHORITY`, b9 `STAGED_PUBLICATION`; a clear bit means the corresponding input is refused with a typed error even if the build could serve it. S1 limits: `maxActions 64, maxBody 8,192, maxRefs 8, maxReadSetPrincipals 64, maxReadSetPositions 4, maxWitness 4,096, maxTransitionBlocks 7,200, inlineWordMax 256 (u16), witnessRetention 1 (LOG_ONLY), maxBindsPerPublication 64, maxBodyBytesPerPublication 16,384, maxFreshSlotsPerPublication 600 (advisory), maxReadIds 64, maxReadCount 256, floorFreshGas 22,100 (prague) / 110,020 (amsterdam profile), floorRewriteGas 5,000 / 12,100, kernelTail 20,000`; C1 may change any value by activation (a limits change sets revision flag b7 and advances the ordinal). Every S1 value is vector-checked against its field width (`vectors/limits.json`). Three numbers that look like limits are **closure constants, not Realm fields**, because they enter validity, identity or liveness: `ACCEPTOR_GAS_DEFAULT = 300,000` (§6.2, §9.2), `DESCRIPTOR_MAX = 4,096` (§9.2) and `WALLET_GAS_FLOOR = 300,000` (§6.2); no `acceptorGasDefault` or `maxDescriptorBytes` field exists.

### 4.3 Packed rows (bit offsets)

```text
counters (one word)
  admissions u48@0 | records u48@48 | bindings u48@96 | publications u48@144 | reserved u64@192

RecordCell { bytes32 typeId; uint256 meta }                       (2 slots per fresh record + body words)
  meta: firstAdmission u48@0 | length u32@48 | occurrences u48@80 | carrierKind u8@128 | reserved u120@136
  carrierKind: 0 INLINE_WORDS (bodyWord[id][i], tail masked); 1 CODE_BLOB reserved (refused until capability b6)
  bodyWord[id][i]: whole 32-byte words; length is the byte length; words beyond length are never written

SubjectCell (one word)
  createAdmission u48@0 | creatorKind u8@48 | reserved u200@56
  creatorKind: the principalKind of the creating principal (1 KEY 2 CONTRACT); 0 and 3..255 reserved

AdmissionRow { uint256 meta; bytes32 a }                           (2 slots; UNBIND/RELEASE write meta only)
  meta: kind u4@0 | leaf u8@4 | publication u48@12 | bindingOrdinal u48@60 | expectedRevision u48@108
      | prevAdmission u48@156 | withdrawn u1@204 | policyRow u16@205 | roleRow u16@221 | targetKind u8@237 | reserved u11@245
  a:    PUBLISH/REUSE = recordId; BIND = target; CREATE = salt; WITHDRAW = bytes32(targetAdmission)
  kind: 1 PUBLISH 2 REUSE 3 BIND 4 UNBIND 5 CREATE 6 WITHDRAW 7 RELEASE; 8 STAGE, 9 COMMIT reserved (refused until b9); 10..15 reserved
  The signed Action tuple is re-encodable: typeId from the record cell, bodyHash = keccak(body words),
  purpose/subject/role from position[bindingPosition[bindingOrdinal]], target from a, expectedRevision from meta.
  targetKind in BIND rows lets the replay decoder rebuild oldTarget/oldTargetKind from the prevAdmission chain (no shadow heads).

HeadRow { uint256 meta; bytes32 target }                           (2 slots per fresh binding)
  meta: state u8@0 | revision u48@8 | admission u48@56 | targetKind u8@104 | prevAdmission u48@112
      | bindingOrdinal u48@160 | notAfter u40@208 (reserved zero; "stale not dead" seam) | reserved u8@248
  state: 0 UNSET 1 BOUND 2 MASKED 3 RELEASED; 4..255 reserved (refused)
  targetKind: 0 NONE 1 RECORD 2 SUBJECT; 3..255 reserved
  The target word is KEPT on MASK and RELEASE (never cleared): a later RESTORE or re-bind to the same target
  rewrites instead of re-creating a fresh slot (5,000 / 12,100 instead of 22,100 / 110,020). The canonical target
  is defined as 0 whenever state != BOUND: Layout.canonicalTarget, ILedgerHot.head, LedgerReads.head, headSnapshotHash
  and the raw-slot digest's canonical projection all apply that rule; absent/masked/released reads touch meta only.

PositionCell { bytes32 purpose; bytes32 subject; bytes32 role }   (3 slots, write-once, shared by all authors;
                                                                    role == 0 is a zero write, not a slot)

PrincipalRow (one word)
  nonce u48@0 | viewMutationVersion u48@48 | reserved u160@96

EvidenceCell (per publication ordinal; sparse)
  w0  author u160@0 | proofKind u4@160 | principalKind u4@164 | v u8@168 | leafCount u8@176
      | firstAdmission u48@184 | flags u8@232 | reserved u16@240
      flags: b0 imported, b1 guarded, b2 externalEvidence, b3 executionBound (native: expectedExecutionSet was nonzero),
             b4 acceptanceBound (native: expectedAcceptanceProfile was nonzero), b5 witnessInState, b6..7 reserved
  w1  nonce u48@0 | deadline u64@48 (unix seconds; 0 = none; full width, never truncated) | basisBlock u48@112
      | revision u32@160 | verifierProfile u16@192 | reserved u48@208
  w2  principalId        full-width bytes32 (never derived from current account code)
  w3  intentDigest       every lane; plan-intrinsic (§6.2); the retry key
  w4  actionsHash        keccak(abi.encode(actions))
  w5  acceptanceProfile  signed lanes only (zero / unwritten for native; native rows re-fold from rows + registry history)
  w6  indexObligations   signed lanes only
  w7  readSetHash        only when guard != canonical-empty
  w8  witness0           secp256k1: r | ERC-1271: evidenceHash = keccak(signature bytes)
  w9  witness1           secp256k1: s | ERC-1271: store u160@0 (0 = log-only) | sigLength u16@160
  w10 submitter u160@0 | reserved u96@160   (signed lanes: msg.sender of executeSigned, the relayer, so author and submitter are distinct recorded roles;
                                            0 on the native lane, where author == submitter; the routed-consent actor attribution is a later lane's reserved bits)
  w11 authorityId        reserved (KEL)
  w12 authEpoch          reserved (KEL)
  proofKind: 1 NATIVE 2 SECP256K1_EIP712 3 ERC1271 4 P256_WEBAUTHN (reserved) 5..15 reserved
  principalKind: 1 KEY 2 CONTRACT (origin-qualified) 3..15 reserved (managed/KEL)
  Fresh slots: native 5 (+ publicationAt 1 = 6); secp256k1 10 (+1 guarded); ERC-1271 10 (+1 guarded).

publicationAt[principalId][nonce] -> uint48 publication          (1 fresh per publication)

RevisionRow (per activation; write-once; 25 slots, rare)
  w0  activationBlock u48@0 | admissionHigh u48@48 | publicationHigh u48@96 | activationTimestamp u40@144
      | flags u16@184 | executionProfileId u16@200 | capabilities u16@216 | reserved u24@232                 (232 bits used)
      flags: b0 frozenTerminal, b1 sameCodeReactivation, b2 chainAcceptanceChange, b3 controllerMigrated,
             b4 ownerChanged, b5 indexChanged, b6 layoutChanged, b7 limitsChanged, b8 migrationRan
  w1  executionSet
  w2  ledgerImpl u160@0 | acceptedChainId u64@160
  w3  ledgerImplCodehash
  w4  registryImpl u160@0 | reserved
  w5  registryImplCodehash
  w6  index u160@0 | indexGeneration u32@160 | reserved u64@192
  w7  indexCodehash
  w8  indexManifestHash
  w9  ingress u160@0 | reserved                 (the activated implementation's INGRESS immutable)
  w10 ingressCodehash
  w11 applyDelegate u160@0 | reserved           (the activated implementation's APPLY immutable)
  w12 applyCodehash
  w13 controller u160@0 | reserved
  w14 controllerCodehash
  w15 controllerOwner u160@0 | reserved
  w16 steward u160@0 | reserved
  w17 layoutId
  w18 verifierProfilesRoot        keccak(sorted verifier profile ids served by this ingress build)
  w19 migrationHash               keccak(set.migration) or 0
  w20 dependencyRoot              keccak(sorted (address, codehash) of every code the write path can call under this revision;
                                  a controller-supplied claim verified by verify-deployment against release.json)
  w21 limitsProfileId             = keccak(abi.encode(Limits)) of this revision: an executionSet input (§8.1), re-derivable from w22–w23
  w22 limits0                     the packed limits words of §4.2 as activated, so every past revision's floorFreshGas, floorRewriteGas, kernelTail
  w23 limits1                     and maxima are readable from state and verify-deployment can re-derive every historical executionSet
  w24 noticePrincipal             the principal allowed to author realm-notice/1 {kind: successor} records under this revision (0 = none)
```

Every width-bearing identity (`layoutId`, the head-snapshot profile, the read-set profile, the index physical profile, the manifest header guard, every fixed bit offset in the replay decoder) is re-versioned when a width changes and enumerated in `docs/STORAGE.md`. A valid publication never has an all-zero provable row: `w0` is nonzero for every lane.

### 4.4 Why the context row disappears

The prototype wrote a 5-slot `PublicationContext` beside a 5-slot evidence cell plus the ordinal map: 11 fresh slots per native publication (`AN/followup-6.md` §B.1). Here `principalId`, `principalKind`, `readSetHash` and `revision` are in the cell; `executionSet` is `revisions[w1.revision].executionSet`; `indexObligations` for native rows is the revision row's `keccak(index, indexCodehash, indexManifestHash)`; `acceptanceProfile` for native rows is re-folded from the admission rows' `policyRow`/`roleRow` and the registry's append-only history under the fold version named by the revision's `executionProfileId`; the native `intentDigest` is recomputed from `(realmId, principalId, nonce, deadline, executionBound ? executionSet : 0, acceptanceBound ? refolded profile : 0, guardHash, actionsHash)` where `guardHash = keccak("")` for unguarded rows and `w7` for guarded ones (`readSetHash == guardHash`, §5.8), so every native digest is recomputable from the row alone; the read-set *preimage* is needed only to re-check heads, lives in `ReadSetChecked` under the default retention profile, and is graded by `Evidence.retention`. The Reconstructor invariant (§16.5 #10) checks all of it.

### 4.5 Registry namespaces (`efs.registry.v2.*`)

```text
types.row[typeId]
  header: grade u8@0 | refCount u8@8 | wrapperVersion u8@16 | ruleMode u8@24 | dependencyClass u8@32 | refHeaderWords u8@40
        | validationGas u24@48 | policyRows u16@72 | registeredAt u40@88 | catalogOrdinal u48@128 | codecVersion u8@176 | textProfile u8@184 | reserved u64@192
  shape            bytes32
  ruleId           bytes32   (= the codehash named in the descriptor header: wrapper codehash for grades 1–2, developer rule codehash for grade 3)
  mandatory        address u160@0 | reserved
  descriptorBlob   address u160@0 | blobLength u16@160 | reserved
  grammarProfile   bytes32   (grades 1–2: the wrapper's pure constant; zero for native)
types.refTypes[typeId][i]      bytes32
declarations.row[typeId]       key u160@0 | installed u1@160 | reserved ; signatureHash bytes32      (2 slots; written by retainDeclaration/registerDescribed; read by declaration())
policy.row[typeId][row]         acceptor u160@0 | activatedAt u40@160 | mutationAt u48@200 ; codehash bytes32   (2 slots; row 1 implicit = no policy)
roles.row[roleKey][n]           expectedType bytes32 ; activatedAt u40@0 | mutationAt u48@40           (roleKey = keccak(DOM_ROLE_KEY, purpose, role))
roles.count[roleKey]            u16
bindings.row[typeId]            custom u160@0 | customAbi u8@160 | reserved ; bindingId bytes32         (grade 2 only; customAbi: 1 = the IAcceptor/2 nested-call shape; 0 and 2..255 reserved)
wrappers.row[version]           implementation u160@0 | codecVersion u8@160 | activatedAt u40@168 ; codehash bytes32 ; grammarProfile bytes32
catalog.typeAt[ordinal]         bytes32
control                         ledger u160@0 | activeRevision u32@160 | wrapperCount u16@192 | reserved
                                mutations u48@0 | catalogCount u48@48 | reserved
```

The registry stores **no controller and no frozen flag**: `onlyController` is `msg.sender == ILedgerHot(ledger).controller()` and the frozen gate reads `ILedgerHot(ledger).control().frozen`, so a controller migration or a freeze needs no registry write and can never strand it. `mandatoryCodehash` is not stored separately: it equals `ruleId`. `shape` is stored because the hot path must not `extcodecopy` the blob; `refTypes` are stored because `_checkRefs` is hot. The declaration signature lives inside the blob.

### 4.6 Index storage (`efs.index.v2.store.*` per Realm; `efs.index.v2.gen.*` per generation)

```text
PostingStore (one per family set; the genesis store holds every gen-1 APPEND family except kind 10)
  LEDGER, INITIAL_WRITER, FAMILY_IDS[]   constructor immutables (INITIAL_WRITER = 0 for the genesis stores: they need no generation address)
  postingHead[key]      count u48@0 | live u48@48 | last u48@96 | flags u16@144 (reserved zero) | reserved
  postingWord[key][i]   five u48 ordinals per word (inline singleton: the first append writes only the head)
  writers[g]            generation u160@0 | fromAdmission u48@160 | toAdmission u48@208     (append-only history of who wrote; entry 0 = INITIAL_WRITER's build range when nonzero)
  attached              u1  (set by the first live write; INITIAL_WRITER's right lapses when it is set)
BitmapStore (scope lists, bitmaps, coverage; same LEDGER / INITIAL_WRITER / FAMILY_IDS / writers / attached as PostingStore)
  scopeHead[scope]      count u48@0 | live u48@48 | lastMutation u48@96 | liveBits0 u48@144 | flags u16@192 (reserved zero) | entry0 u48@208
  scopeEntry[scope][w]  five u48 binding ordinals per word for entries e >= 1 (entry e at position (e − 1) % 5 of word (e − 1) / 5); entry 0 is inline in the head
  bits[scope][family][w] 256 bits per word; entry index e >= 48 of the scope list lives at bit (e − 48) % 256 of word (e − 48) / 256
  coverage[family][scope]  through u48@0 | liveFrom u48@48 | retiredAt u48@96 | state u8@144 (1 OPEN 2 COMPLETE 3 RETIRED; 0 reserved) | reserved
                           (exists only for scopes that predate the family's declaration ordinal d; absent = covered by construction)
Generation g (efs.index.v2.gen.<g>; written only in the generation's own context, by its code or by the IndexBuild delegate)
  progress              lastProcessed u48@0 | lastPublication u48@48 | gapped u1@96 | liveStarted u1@97 | replayStage u8@98 (1 FRESH 2 REPLAYING 3 CAUGHT_UP; 0 reserved) | reserved
  buildFrontier[family] through u48@0 | state u8@48 (1 BUILDING 2 BUILT; 0 reserved)      (ascending build of a later append-ordered family, before attachment)
```

**Store write authorization (the only rule a store enforces; `E_WRITER` otherwise).** Let `g = ILedgerHot(LEDGER).index()` and `phase = ILedgerHot(LEDGER).phase()`. (1) `msg.sender == g && phase != IDLE`: a live write to any family in `FAMILY_IDS` (`E_FAMILY` otherwise); if `writers` has no open entry for `g`, the store closes the previous entry at the current admission, opens `(g, fromAdmission = this effect's admission, toAdmission = 0)` and sets `attached` — lazy attachment, so no kernel call into the store exists and the attachment ordinal is the first live admission. (2) `msg.sender == g && phase == IDLE`: only `backfillOr`/`backfillSet` into a scope whose `coverage[family][scope].state == OPEN`, within `[through, liveFrom)`. (3) `msg.sender == INITIAL_WRITER && INITIAL_WRITER != 0 && !attached && phase == IDLE`: build or replay writes to any family in `FAMILY_IDS`; `writers[0]` records the builder and its range. Nothing else writes. Consequences: an attached store never accepts a writer that is not the live generation; a stranger's contract can write only into a store whose constructor named it, which no manifest will ever attach (S18); a later APPEND family is therefore always built into a **fresh** store (one store per new family set, its `FAMILY_IDS` fixed at construction) whose `INITIAL_WRITER` is the candidate generation, and the right lapses at attachment. Readiness (§8.3 step 5h) checks that every store's `writers` ranges are contiguous and that every family the manifest names is in its store's `FAMILY_IDS`. The write ABI and its `STORE_ABI_ID` are in §5.11. `lastMutation` is the per-scope mutation stamp (CQ-10), rewritten in the same `SSTORE` that appends a scope entry, sets or clears a bit, **or records a REBIND/RESTORE** (`stamp`); it never costs a fresh slot. `liveBits0` makes liveness free for scopes of up to 48 entries, and `entry0` makes a new scope one fresh slot (its head); the first `scopeEntry` word is a fresh slot when a scope passes 1 entry, the first `bits` word when it passes 48. The entry index of a binding ordinal within its scope list is found by bisection over the append-ordered, strictly increasing scope entries in this store (≤ 10 cold `SLOAD`s at 1,000 entries); no per-binding offset slot exists. No shadow heads: replay reconstructs transitions from admission rows (§10.6). The dense swap list is the C1 fallback recipe named by the manifest's `physicalProfile` behind the same read ABI.

---

## 5. External ABI

The consumer closure is `src/interfaces/` + `src/lib/{Keys,Actions,Results,Errors,Limits,EfsNative,EfsFiles}.sol`. It imports nothing from `core/`, `types/`, `index/`, `control/` or OpenZeppelin, uses no transient storage, compiles at the 0.8.27 pragma floor with and without via-IR, and its ABI/selector/error/event snapshot is diffed in CI (`REPO/tools/checks.mjs` enforces the import direction `interfaces ← lib ← {core,types,index,control} ← readers ← profiles ← periphery`). `Layout` is **not** in the closure (`src/core/layout/`): consumers get `vectors/layout.json`. No overloads; every revert is a custom error with arguments; no read returns a zero-valued tuple to mean absent.

### 5.1 Closure types (`Actions.sol`, `Results.sol`, `Limits.sol`)

```solidity
type TypeId is bytes32;  type ScopeKey is bytes32;  type PostingKey is bytes32;  type FamilyId is bytes32;

struct Action { uint8 kind; bytes32 typeId; bytes32 bodyHashOrRecordId; bytes32 purpose; bytes32 subject;
                bytes32 role; bytes32 target; uint64 expectedRevision; bytes32 salt; }   // nine-field tuple; per-kind zero-shape law
struct Native { uint64 nonce; uint64 deadline; bytes32 expectedExecutionSet; bytes32 expectedAcceptanceProfile; }
                // deadline 0 = none; expectedExecutionSet 0 = unbound; expectedAcceptanceProfile 0 = unbound (the SDK binds both by default)
struct Intent { bytes32 realmId; bytes32 realmOrigin; bytes32 executionSet; bytes32 principalId; address author; uint64 nonce; uint64 deadline;
                bytes32 acceptanceProfile; bytes32 indexObligations; bytes32 readSetHash; uint16 verifierProfile;
                bytes32 authorityId; uint64 authEpoch; }
                // author: profile 1 = 0 or the recovered address; profile 2 = the ERC-1271 wallet (required, bound to principalId)
struct ReadSet { bytes32[] principals; bytes32[] positions; bytes32[] expectedHeads; }    // decoded only by LedgerIngress; n ≤ 64, m ≤ 4, n·m heads position-major
struct BasisCommit { bytes32 executionSet; uint32 revision; uint32 indexGeneration; uint64 registryMutations; uint64 admissionHighWater; uint8 phase; }

enum Status   { UNSET, UNKNOWN, PRESENT, ABSENT_PROVEN, MASKED, RELEASED, CONFLICT, NOT_ON_PAGE, NOT_APPLICABLE, INVALID, UNSUPPORTED, BASIS_STALE, LIMIT_EXCEEDED }
enum Coverage { UNSET, UNKNOWN, PARTIAL, COMPLETE }
enum History  { UNSET, UNKNOWN, NONE, FOUND }
enum Retention { UNSET, STATE, LOG_ONLY }
struct Qualified { Status status; BasisCommit observed; }

struct Limits { uint16 maxActions; uint32 maxBody; uint8 maxRefs; uint16 maxReadSetPrincipals; uint8 maxReadSetPositions;
                uint16 maxWitness; uint32 maxTransitionBlocks; uint16 inlineWordMax; uint8 witnessRetention;   // witnessRetention = Retention (1 LOG_ONLY, 2 STATE)
                uint16 maxBindsPerPublication; uint32 maxBodyBytesPerPublication; uint32 maxFreshSlotsPerPublication;
                uint16 maxReadIds; uint16 maxReadCount; uint32 floorFreshGas; uint32 floorRewriteGas; uint32 kernelTail; }
```

Value 0 of every enum is reserved and never returned. `statusVocabularyId` in `describe()` versions the enums; additions are append-only. Kinds: `1 PUBLISH 2 REUSE 3 BIND 4 UNBIND 5 CREATE 6 WITHDRAW 7 RELEASE`; `8 STAGE`, `9 COMMIT` reserved for stage-then-commit (FU5-R15) with their namespace reserved (§4.1). `BasisCommit` comparison law: **plans** compare `executionSet` and the acceptance profile (native: `Native.expectedAcceptanceProfile`; signed: `Intent.acceptanceProfile`) and never `registryMutations`, which is echoed only, so permissionless registration and unrelated activations void no plan (TR-03); **readers and cursors** compare `(executionSet, indexGeneration)` exactly (both pin `layoutId` and the index manifest through the execution set), treat `admissionHighWater` as the origin under the per-scope continuation law (§11), and echo `registryMutations` without comparing it. The joint-envelope fields (`maxBindsPerPublication`, `maxBodyBytesPerPublication`, `maxFreshSlotsPerPublication`) and the read maxima (`maxReadIds` for id arrays, `maxReadCount` for counts and slices) are the values C1 executes at the 2^24 cap and publishes; `maxFreshSlotsPerPublication` is advisory (the SDK's estimator), not a refusal.

### 5.2 `ILedger` (write lanes; calldata-only; three selectors forever)

```solidity
function execute(Action[] calldata actions, bytes[] calldata bodies, Native calldata ctx, bytes calldata guard)
    external returns (uint64 publication, uint64 firstAdmission);
function executeSigned(Intent calldata intent, Action[] calldata actions, bytes[] calldata bodies, bytes calldata guard, bytes calldata witness)
    external returns (uint64 publication, uint64 firstAdmission);
function importPublication(bytes calldata packet, bytes calldata witness) external returns (uint64 publication, uint64 firstAdmission);
    // S4 behind capability b5; from S1 a stub that decodes `packet`'s header and reverts E_RESERVED(5, 0), so the dispatcher, wrapper and error bytes are in the measured kernel
```

`guard` is the ABI encoding of a `ReadSet` or empty (canonical-empty read set); the kernel never decodes it. `intent.verifierProfile` selects `1` secp256k1-EIP-712 (S2), `2` ERC-1271 (S2b), `3` P-256/WebAuthn (reserved), `4+` reserved; `actionsHash` is appended to the typed data at hashing. The ABI snapshot test asserts no other write selector exists.

### 5.3 `ILedgerHot` (Etched kernel reads: one `SLOAD` each, no stipends, no struct encoders)

`HOT_ABI_ID = keccak("efs2/ledger-hot/1" ‖ sorted selectors ‖ return layouts)` is an implementation immutable, exposed by `hotAbiId()`, snapshot-tested across releases like `IAcceptor/2`. A kernel upgrade may **add** selectors (a new `HOT_ABI_ID`) and never changes or removes one. Because no superset relation can be decided from two hashes, each implementation also carries the constant list `SUPPORTED_HOT_ABI_IDS` — its own id plus every predecessor id whose selector-and-layout table it still serves, each snapshot-tested in CI against the retained tables in `vectors/hot-abi.json` — exposed by `supportedHotAbiIds()`. Every pinned unit declares the hot-ABI id it was built against (`Unit.hotAbiId`, §5.11); activation step 5g refuses a unit whose id is not in the new implementation's list and refuses an implementation whose list omits any id the current implementation's list contains. Acceptors and units may call these getters on `ctx.ledger`/`LEDGER` forever.

```solidity
function counts() external view returns (uint64 admissions, uint64 records, uint64 bindings, uint64 publications);
function phase() external view returns (uint8 phase, uint64 stagedPublication, uint64 admissionFrontier, uint32 revision);  // 0 IDLE 1 PREPARING 2 APPLYING 3 FINAL
function executionSet() external view returns (bytes32);
function revision() external view returns (uint32);
function control() external view returns (uint64 genesisChainId, uint64 acceptedChainId, uint32 revision, bool frozen);
function realmId() external view returns (bytes32);
function realmOrigin() external view returns (bytes32);
function layoutId() external view returns (bytes32);
function hotAbiId() external view returns (bytes32);
function supportedHotAbiIds() external view returns (bytes32[] memory);   // the constant list; no SLOAD
function registry() external view returns (address);
function index() external view returns (address);
function indexGeneration() external view returns (uint32);
function ingress() external view returns (address);          // the implementation immutable
function applyDelegate() external view returns (address);    // the implementation immutable
function controller() external view returns (address);
function noticePrincipal() external view returns (bytes32);   // realm +17; read by RealmNoticeRule (§12.1)
function readerDirectory() external view returns (address); // advisory
function nonceOf(bytes32 principalId) external view returns (uint64 nonce, uint64 viewMutationVersion);
function subjectCreatedAt(bytes32 subjectId) external view returns (uint64);
function head(bytes32 bindingKey) external view returns (uint8 state, uint64 revision, uint64 admission, uint8 targetKind, uint64 prevAdmission, uint64 bindingOrdinal, bytes32 target);   // target is the canonical target: loaded only when BOUND, else 0
function recordHeader(bytes32 recordId) external view returns (bytes32 typeId, uint64 firstAdmission, uint32 length, uint64 occurrences, uint8 carrierKind);
function publicationAt(bytes32 principalId, uint64 nonce) external view returns (uint64 publication, bytes32 intentDigest);  // (0, 0) when none; two SLOADs (the ordinal map, then evidence w3); the only two-SLOAD read here
function extsload(bytes32 slot) external view returns (bytes32);
function extsloadBatch(bytes32[] calldata slots) external view returns (bytes32[] memory);   // ≤ 256 slots
function exttload(bytes32 slot) external view returns (bytes32);
```

`extsload*` are the proof-able raw floor for the facets, the index, the replay decoder, the SDK and the oracle; they are forbidden in `profiles/` and in readers other than the two facets (lint). `describe()`, `revisionAt(n)`, every struct view and every composite is on the facets (§5.7).

### 5.4 `ILedgerControl` (controller-only; idle-gated)

```solidity
struct RealmInit { bytes32 realmSalt; address controller; address registry; address readerDirectory; uint16 executionProfileId; Limits limits; }
struct ComponentSet { address ledgerImpl; bytes32 ledgerImplCodehash; address registryImpl; bytes32 registryImplCodehash;
                      address index; bytes32 indexCodehash; bytes32 indexManifestHash;
                      address ingress; bytes32 ingressCodehash; address applyDelegate; bytes32 applyCodehash;
                      address controller; bytes32 controllerCodehash; address controllerOwner; address steward; bytes32 verifierProfilesRoot; }
struct ActivationSet { uint32 revision; ComponentSet components; bytes32 layoutId; uint16 executionProfileId; uint16 capabilities;
                       uint64 acceptedChainId; Limits limits; bytes32 expectedExecutionSet; bytes32 dependencyRoot; bytes32 noticePrincipal;
                       bytes32[] migrationScope; bytes migration; }
                       // no terminal flag: the terminal activation is a distinct selector

function initialize(RealmInit calldata init) external;                 // initializer; genesis creation transaction only
function activate(ActivationSet calldata set) external;                // reinitializer(uint64(set.revision) + 1); onlyController; phase IDLE
function freeze(ActivationSet calldata set) external;                  // reinitializer(uint64(set.revision) + 1); onlyController; terminal; pre-checks of §8.10
function beginTransition(uint32 targetRevision, uint48 deadlineBlock) external;   // onlyController; a target can be begun once, ever; cooldown; deadline − block.number ≤ limits.maxTransitionBlocks (§8.8)
function abortTransition() external;                                   // onlyController before the deadline; anyone after it
```

The `+ 1` offset exists because OZ's `initializer` sets `_initialized = 1` (`OZ/proxy/utils/Initializable.sol:123`) and `reinitializer(v)` reverts when `_initialized >= v` (`:156`); revision `n` therefore runs under initializer version `n + 1`, documented in `docs/STORAGE.md` and asserted by the genesis test (`_getInitializedVersion() == revision + 1`).

### 5.5 Kernel events (acceleration for receipts and indexers; **state is sufficient for every canonical fact except the two log-only carriers named here**)

```solidity
event Published(uint64 indexed publication, bytes32 indexed publicationId, bytes32 indexed principalId, uint8 proofKind, uint64 firstAdmission, uint8 leafCount, bytes32 effectsHash, uint32 revision);
event Admitted(uint64 indexed admission, uint8 indexed kind, bytes32 indexed scopeOrType, bytes32 id, bytes32 principalId);   // topic 3: typeId for PUBLISH/REUSE/WITHDRAW, scopeKey for BIND/UNBIND/RELEASE, subjectId for CREATE
event ReadSetChecked(uint64 indexed publication, bytes32 indexed readSetHash, bytes readSet);                                 // guarded publications: the preimage lives only here under the default retention profile
event WitnessRetained(uint64 indexed publication, bytes32 indexed evidenceHash, uint16 verifierProfile, bytes witness);       // ERC-1271 bytes under the log-only retention profile (w9.store == 0)
event Activated(uint32 indexed revision, bytes32 indexed executionSet, uint64 activationBlock, uint64 admissionHigh, uint16 flags);
event TransitionBegun(uint32 indexed targetRevision, uint48 deadlineBlock);
event TransitionEnded(uint32 indexed targetRevision, uint8 how);                                                             // 1 activated 2 aborted 3 expired (3 is emitted lazily by the first beginTransition or activate that observes the expiry, §8.8)
```

`effectsHash = keccak256(abi.encode(Effect[]))` over the `Effect/3` records of the publication is emitted only (never stored); `LedgerViews.publication()` recomputes it from state so a receipt matches a plan. Read-set preimages and log-only ERC-1271 witnesses are **not** reconstructible from state: `Evidence.retention` reports `LOG_ONLY` for such rows and readers grade their portability `UNKNOWN` (§7.4); the static client's gateway allowlist does not require `eth_getLogs` history for any read.

### 5.6 Error catalog (`Errors.sol`; the bundle ships `errors.json` with selector, meaning and retry class ∈ {reprepare, resubmit, wait, none})

| Error | Args | Thrown by | Retry |
|---|---|---|---|
| `AlreadyAdmitted` | `(uint64 publication)` | entry, right after digest derivation | none (committed) |
| `E_NONCE` | `(bytes32 principalId, uint64 nonce, uint64 publication)` | entry (`publication != 0`: consumed by a different plan; `0`: not the next nonce) | reprepare |
| `E_PUBLICATION_ACTIVE` | `()` | every write entry | wait |
| `E_TRANSITION` | `(uint32 target, uint48 deadline)` | entry | wait |
| `E_CHAIN` | `(uint64 accepted, uint64 actual)` | entry | none |
| `E_NO_INDEX` | `()` | entry | wait |
| `E_EXECUTION_DRIFT` | `(address live, address activated)` | entry, per-callback re-check | wait |
| `E_REGISTRY_DRIFT` | `(uint64 expected, uint64 have)` | entry (`activeRevision`), per-callback (`mutations`) | resubmit |
| `E_HELPER_CODE` | `(address helper)` | entry (`extcodehash(INGRESS/APPLY)`) | wait |
| `E_EXECUTION_SET` | `(bytes32 expected, bytes32 live)` | native bound expectation | reprepare |
| `E_ACCEPTANCE_PROFILE` | `(bytes32 expected, bytes32 live)` | native bound expectation | reprepare |
| `E_NATIVE_AMBIGUOUS` | `()` | native author | none |
| `E_BATCH_SHAPE` | `(uint16 actions, uint16 bodies)` | bounds | none |
| `E_COUNTER_SATURATED` | `(uint8 counter)` | bounds | none |
| `E_EXPIRED` | `(uint64 deadline, uint64 now)` | ingress (after the retry compare) | reprepare |
| `E_INTENT` | `(uint8 field)` 1 realm 2 execution 3 profile 4 index 5 readset | ingress (signed) | reprepare |
| `E_SIGNATURE` | `(uint8 reason)` 0 unknown profile 1 length 2 malleable 3 recover 4 wallet refused 5 code-less or key-classified author 6 author does not derive principalId | ingress | reprepare |
| `E_WALLET_GAS` | `(uint32 forwarded)` | ingress profile 2: `isValidSignature` failed with empty returndata having consumed ≥ forwarded − 2,000 | resubmit |
| `E_READSET_SHAPE` | `(uint8 reason)` | ingress | none |
| `E_READSET_STALE` | `(bytes32 position, bytes32 principalId)` | ingress | reprepare |
| `E_UNSUPPORTED_GUARD` | `()` | ingress (capability b0 clear) | none |
| `E_VERIFIER_PROFILE` | `(uint16 profile)` | ingress | none |
| `E_UNKNOWN_TYPE` | `(uint8 leaf, bytes32 typeId)` | ingress (acceptance-profile fold); kernel (`typeInfo` load of an unbound native leaf) | none |
| `E_SHAPE` | `(uint8 leaf, uint8 code)` | apply | none |
| `E_KIND` | `(uint8 leaf, uint8 kind)` | apply | none |
| `E_BODY` | `(uint8 leaf, uint8 code)` 1 too long 2 hash mismatch 3 carrier refused | kernel, before `validateLeaf` | none |
| `E_MISSING_RECORD` | `(uint8 leaf, bytes32 recordId)` | kernel (reuse) | reprepare |
| `E_TYPE_MISMATCH` | `(uint8 leaf, bytes32 expected, bytes32 have)` | kernel (reuse) | none |
| `E_REF` | `(uint8 leaf, uint8 refIndex, uint8 code)` 1 missing 2 type 3 sentinel-in-body 4 reserved sentinel | validateLeaf | reprepare |
| `E_ACCEPTOR_CODE` | `(uint8 leaf, address acceptor)` | validateLeaf | wait |
| `E_GAS` | `(uint8 leaf, uint32 needed, uint32 available)` | validateLeaf (available < validationGas); ingress profile 2 with leaf 0 (available < WALLET_GAS_FLOOR) | resubmit |
| `E_ACCEPTOR_GAS` | `(uint8 leaf, bytes32 typeId, uint32 forwarded)` | validateLeaf: the acceptor failed with empty returndata having consumed ≥ forwarded − 2,000, or returned the 32-byte `EXHAUSTED` word (§5.10: a grade-2 wrapper whose nested predicate exhausted) | resubmit |
| `E_REJECTED` | `(uint8 leaf, bytes32 typeId)` | mandatory rule | none |
| `E_POLICY_REJECTED` | `(uint8 leaf, bytes32 typeId, uint16 policyRow)` | Realm policy | none |
| `E_NOT_LIVE` | `(uint8 leaf, bytes32 bindingKey, uint8 state)` | bind kinds | reprepare |
| `E_CAS` | `(bytes32 bindingKey, uint64 expected, uint64 have)` | bind kinds | reprepare |
| `E_TARGET_MISSING` | `(uint8 leaf, bytes32 target)` | bind | reprepare |
| `E_TARGET_TYPE` | `(uint8 leaf, bytes32 expected, bytes32 have, uint16 roleRow)` | bind | none |
| `E_SUBJECT_EXISTS` | `(uint8 leaf, bytes32 subjectId)` | create | none |
| `E_SALT` | `(uint8 leaf)` | create | none |
| `E_WITHDRAW` | `(uint8 leaf, uint8 code)` 0 range 1 not publish 2 already 3 not author | withdraw | none |
| `E_INGRESS` | `(uint256 replySize)` | kernel glue | wait |
| `E_INDEX_CALL` | `(bytes inner)` | dispatcher (callback reverted **with data**; inner ≤ 4,096 B nested verbatim) | none |
| `E_INDEX_GAS` | `(uint32 quoted, uint32 available)` | dispatcher: before a prefix callback when `available < remaining floor`, before the final call when `available < finalReserve`, or after any callback that failed **with empty returndata** | resubmit |
| `E_INDEX_RETURNDATA` | `(uint256 size)` | dispatcher | none |
| `E_INDEX_FINAL` | `()` | final phase (ack mismatch) | none |
| `E_DELEGATE_ONLY` | `()` | every ingress/apply delegate selector called directly | none |
| `E_REVISION`, `E_IMPLEMENTATION`, `E_LAYOUT`, `E_REGISTRY`, `E_PIN`, `E_INDEX_NOT_READY`, `E_EXPECTED_SET`, `E_FROZEN`, `E_NOT_CONTROLLER`, `E_DEADLINE_BOUND`, `E_TRANSITION_COOLDOWN`, `E_TRANSITION_TARGET(uint32)`, `E_MIGRATION_SCOPE`, `E_HOT_ABI(address unit)`, `E_CODE_SHAPE(address, uint8 reason)`, `E_CONTROLLER(uint8 field)`, `E_FREEZE_PRECHECK(uint8 check)` | activation args as named | `activate`/`freeze`/controller | none |
| `E_RESERVED` | `(uint8 field, uint256 value)` | every reserved value | none |
| `E_UNSUPPORTED_ROW` | `(uint8 row)` | facets on a reserved bit set | none |

Registry errors: `E_TYPE_EXISTS(typeId)`, `E_BINDING(code)`, `E_DECLARATION(code)`, `E_CODEC(byteOffset, code)`, `E_DESIGNATOR(addr)`, `E_BLOB(addr)`, `E_GRADE(grade)`, `E_INSTANCE(expected, have)`, `E_WRAPPER(code)`, `E_ROLE_ROWS`, `E_FROZEN`, `E_CODE_SHAPE`. Index and store errors: `E_LEDGER`, `E_WRITER`, `E_ORDER(expected, have)`, `E_STAGED`, `E_FAMILY(familyId)`, `E_UNIT(index)`, `E_REPLAY(code)`, `E_BUILD(code)`, `E_BACKFILL(code)`, `E_COVERAGE(code)`. Controller errors: `E_NOT_OWNER`, `E_PENDING`, `E_NOT_IDLE`, `E_SUCCESSOR(code)`, `E_RETIRED` (a controller replaced by `migrate`), `E_CANARY(uint8 lane)`. Acceptor revert data is always discarded (S3); index revert data is always nested inside `E_INDEX_CALL` (S13); the SDK decodes the outer selector first. **No error has the shape "spent more than allowed": `E_ALLOWANCE` does not exist (I11).**

### 5.7 `ILedgerReads` and `ILedgerViews` (immutable facets at their own addresses; every function takes `address ledger`; statuses, never zero sentinels; basis echoed)

```solidity
struct Description {
    bytes32 realmId; bytes32 realmOrigin; bytes32 realmSalt; uint64 genesisChainId; uint64 acceptedChainId; bytes8 chainNamespace; bytes32 chainReference;
    bytes32 executionSet; uint32 revision; uint64 revisionBlock; uint64 revisionAdmissionHigh; bytes32 layoutId; bytes32 hotAbiId; uint16 executionProfileId; uint16 capabilities;
    address ledgerImpl; bytes32 ledgerImplCodehash; address ingress; bytes32 ingressCodehash; address applyDelegate; bytes32 applyCodehash;
    address registry; address registryImpl; bytes32 registryImplCodehash; uint64 registryMutations; uint64 catalogCount;
    address index; bytes32 indexCodehash; uint32 indexGeneration; bytes32 indexManifestHash; bytes32 indexObligations;
    address controller; bytes32 controllerCodehash; address controllerOwner; address steward; bool frozen; uint8 phase;
    address readerDirectory; address thisFacet; bytes32 thisFacetCodehash; uint16 facetVersion;
    uint64 admissions; uint64 records; uint64 bindings; uint64 publications;
    bytes32 domainSeparator; bytes32 limitsProfileId; bytes32 statusVocabularyId; bytes32 verifierProfilesRoot; bytes32 dependencyRoot; Limits limits; bytes32 noticePrincipal;
}
struct Revision { uint32 ordinal; uint64 activationBlock; uint64 admissionHigh; uint64 publicationHigh; uint64 activationTimestamp; uint16 flags;
                  bytes32 executionSet; ComponentSet components; bytes32 layoutId; uint16 executionProfileId; uint16 capabilities; uint64 acceptedChainId;
                  uint32 indexGeneration; bytes32 migrationHash; bytes32 dependencyRoot; bytes32 limitsProfileId; Limits limits; bytes32 noticePrincipal; }
struct RecordHeader { bytes32 typeId; uint64 firstAdmission; uint32 length; uint64 occurrences; uint8 carrierKind; bytes32 word0; }
struct Head { uint8 state; uint64 revision; uint64 admission; uint8 targetKind; uint64 prevAdmission; uint64 bindingOrdinal; uint40 notAfter; bytes32 target; }   // target canonical: 0 unless BOUND
struct AdmissionRow { uint8 kind; uint8 leaf; uint64 publication; uint64 bindingOrdinal; uint64 expectedRevision; uint64 prevAdmission; bool withdrawn; uint16 policyRow; uint16 roleRow; uint8 targetKind; bytes32 a; }
struct Evidence { bytes32 principalId; address author; address submitter; uint8 proofKind; uint8 principalKind; uint16 verifierProfile; uint8 leafCount; uint64 firstAdmission;
                  uint64 nonce; uint64 deadline; uint64 basisBlock; uint32 revision; bytes32 executionSet; bytes32 intentDigest; bytes32 actionsHash;
                  bytes32 acceptanceProfile; bytes32 indexObligations; bytes32 readSetHash; bytes32 witness0; bytes32 witness1; uint8 v;
                  bool imported; bool guarded; bool executionBound; bool acceptanceBound; Retention retention; bytes32 publicationId; }
struct PublicationView { uint64 ordinal; Evidence evidence; AdmissionRow[] admissions; bytes32 effectsHash; uint64 admissionBlock; BasisCommit observed; }
struct AcceptanceBasis { bytes32 typeId; uint16 policyRow; address mandatory; bytes32 ruleId; address policy; bytes32 policyCodehash; uint64 activatedAt; uint16 roleRow; uint32 revision; uint32 validationGas; }
struct Coordinate { bytes32 purpose; bytes32 subject; bytes32 role; }

// LedgerReads (exact rows)
function describe(address ledger) external view returns (Description memory);
function revisionAt(address ledger, uint32 n) external view returns (Status, Revision memory);
function basis(address ledger) external view returns (BasisCommit memory);
function record(address ledger, bytes32 id) external view returns (Status, RecordHeader memory, bytes memory body, BasisCommit memory);
function recordHeader(address ledger, bytes32 id) external view returns (Status, RecordHeader memory);
function bodyWords(address ledger, bytes32 id, uint32 fromWord, uint16 count) external view returns (Status, bytes32[] memory);      // count ≤ limits.maxReadCount
function bodySlice(address ledger, bytes32 id, uint32 offset, uint32 length) external view returns (Status, bytes memory);          // length ≤ limits.maxBody
function subjectInfo(address ledger, bytes32 subjectId) external view returns (Status, uint64 createdAt, bytes32 creatorPrincipal);
function head(address ledger, bytes32 bindingKey) external view returns (Status, Head memory);
function positionCell(address ledger, bytes32 position) external view returns (Status, bytes32 purpose, bytes32 subject, bytes32 role);
function bindingPosition(address ledger, uint64 bindingOrdinal) external view returns (Status, bytes32 position);
function admission(address ledger, uint64 ordinal) external view returns (Status, AdmissionRow memory);
function admissions(address ledger, uint64 from, uint16 count) external view returns (AdmissionRow[] memory, uint64 next, BasisCommit memory);   // count ≤ maxReadCount
function evidence(address ledger, uint64 publication) external view returns (Status, Evidence memory);
function publicationAt(address ledger, bytes32 principalId, uint64 nonce) external view returns (Status, uint64 publication, bytes32 intentDigest);
function principalsOf(address ledger, address[] calldata accounts) external view returns (bytes32[] memory);   // ≤ maxReadIds

// LedgerViews (composites)
function publication(address ledger, bytes32 principalId, uint64 nonce) external view returns (Status, PublicationView memory);   // effectsHash recomputed through Effect/3 reconstruction
function records(address ledger, bytes32[] calldata ids) external view returns (Status[] memory, RecordHeader[] memory, BasisCommit memory);   // ≤ maxReadIds
function heads(address ledger, bytes32[] calldata keys) external view returns (Head[] memory, BasisCommit memory);
function headsAt(address ledger, bytes32[] calldata principals, bytes32 position) external view returns (Status, Head memory selected, uint8 selectedIndex, Head[] memory all, BasisCommit memory);   // ordered first-touch: BOUND or MASKED wins; UNSET/RELEASED fall through
function headSnapshots(address ledger, bytes32[] calldata principals, bytes32[] calldata positions) external view returns (bytes32[] memory);   // n·m, position-major; the read-set preflight
function acceptanceBasis(address ledger, uint64 ordinal) external view returns (Status, AcceptanceBasis memory);
function historyAt(address ledger, bytes32 bindingKey, uint64 asOf, uint16 maxHops) external view returns (History, Head memory);   // prev-chain walk; UNKNOWN beyond maxHops
```

`publication()` is keyed by `(principalId, nonce)` because that is the only retained id→ordinal map; `Evidence.publicationId` is recomputed for the caller. `describe()` reads the realm namespace (limits included), the current revision row, the ERC-1967 implementation slot and the counters through one `extsloadBatch`; its `thisFacet`/`thisFacetCodehash` fields describe the facet the caller is talking to; the SDK trusts nothing it says about code until it compares the proxy's implementation slot and `keccak(eth_getCode)` with `release.json`. Every facet checks `ILedgerHot(ledger).layoutId()` against the layouts it was generated for and returns `UNSUPPORTED` otherwise (the facet-layout rule).

### 5.8 `ILedgerCommitments` (on the ingress address; pure/view encoders the SDK proves equivalent in CI from `vectors/`, never on the hot path)

```solidity
function actionsHash(Action[] calldata actions) external pure returns (bytes32);
function intentDigest(Intent calldata intent, bytes32 actionsHash) external pure returns (bytes32);
    // the signed lanes' retry key, chain-free: keccak(abi.encode(DOM_SIGNED_INTENT, hashStruct(intent), actionsHash)); Intent already binds realmId, realmOrigin and executionSet
function signingDigest(bytes32 domainSeparator, Intent calldata intent, bytes32 actionsHash) external pure returns (bytes32);
    // the EIP-712 digest the key or wallet signs: keccak(0x1901 ‖ domainSeparator ‖ hashStruct(IntentWithActions{intent, actionsHash})); verified in prepare, never stored
function nativeIntentDigest(bytes32 realmId, bytes32 principalId, Native calldata ctx, bytes32 actionsHash, bytes32 guardHash) external pure returns (bytes32);
    // = keccak(abi.encode(DOM_NATIVE_INTENT, realmId, principalId, ctx.nonce, ctx.deadline, ctx.expectedExecutionSet, ctx.expectedAcceptanceProfile, guardHash, actionsHash)); guardHash = keccak(raw guard bytes)
function publicationIdOf(bytes32 principalId, bytes32 intentDigest) external pure returns (bytes32);
function readSetHash(ReadSet calldata rs) external pure returns (bytes32);
    // = keccak(abi.encode(rs)); equal to guardHash = keccak(raw guard bytes) for every accepted guarded publication, because the ingress requires the raw bytes
    // to be the canonical encoding; evidence w7 stores it, so native guarded digests are recomputable from the row without the preimage
function headSnapshotHash(uint8 state, uint64 revision, uint64 admission, bytes32 canonicalTarget) external pure returns (bytes32);
function acceptanceProfileOf(address ledger, Action[] calldata actions) external view returns (bytes32);
function indexObligationsOf(address ledger) external view returns (bytes32);
function indexFloor(address ledger, Action[] calldata actions) external view returns (uint32 prefixFloor, uint32 finalReserve, uint32 freshSlots, uint32 rewrites);   // estimation; the floor the dispatcher will demand
function recordId(bytes32 typeId, bytes32 bodyHash) external pure returns (bytes32);
function subjectId(bytes32 principalId, bytes32 salt) external pure returns (bytes32);
function positionKey(bytes32 purpose, bytes32 subject, bytes32 role) external pure returns (bytes32);
function bindingKey(bytes32 principalId, bytes32 position) external pure returns (bytes32);
function scopeKey(bytes32 principalId, bytes32 purpose, bytes32 subject) external pure returns (bytes32);
function roleScopeKey(bytes32 principalId, bytes32 purpose, bytes32 role) external pure returns (bytes32);
function postingKey(FamilyId family, TypeId typeId, uint8 ordinal, bytes32 value) external pure returns (PostingKey);
    // = Keys.posting(typeId, kindOf(family), ordinal, value), kindOf = the §10.2 kind number (FamilyEntry.kind); the committed Keys.posting(bytes32, uint8, uint8, bytes32)
    // (REPO/src/lib/Keys.sol:122) is the preimage, the §10.2 tuples (T, kind, ordinal, value) are this call, and ids.json vectors every gen-1 family
function typeIdOf(bytes32 shape, bytes32[] calldata refTypes, bytes32 ruleId) external pure returns (bytes32);
```

### 5.9 `ITypeRegistry`

```solidity
struct TypeInfo { uint8 grade; uint8 refCount; uint8 wrapperVersion; uint8 ruleMode; uint8 dependencyClass; uint8 refHeaderWords; uint32 validationGas; uint16 policyRows;
                  address mandatory; bytes32 ruleId; bytes32 shape; address descriptorBlob; address policy; bytes32 policyCodehash; uint16 policyRow;
                  address custom; bytes32 bindingId; }   // 17 fields; custom/bindingId are nonzero only for grade 2, so validateLeaf fills AcceptContext without a binding() call
// hot path (the only registry reads during a publication)
function typeInfo(bytes32 typeId) external view returns (TypeInfo memory);                 // one packed header word + pins; the active policy row read only when policyRows > 1
function refTypes(bytes32 typeId) external view returns (bytes32[] memory);
function roleExpectation(bytes32 purpose, bytes32 role) external view returns (bytes32 expectedType, uint16 row);   // (0, 0) when no row
function mutations() external view returns (uint64);
function activeRevision() external view returns (uint32);
// registration (permissionless, atomic, idempotent)
function retainDeclaration(bytes calldata descriptor, bytes calldata declarationSig) external returns (bytes32 typeId, address blob);
function registerDescribed(bytes calldata descriptor, bytes calldata declarationSig, address nativeOrCustom, bytes calldata bindingSig) external returns (bytes32 typeId, uint64 catalogOrdinal);
// activations (controller = ILedgerHot(ledger).controller(); idle-gated through ledger.phase(); refused when ledger.control().frozen; append-only; bump mutations)
function activatePolicy(bytes32 typeId, address acceptor) external returns (uint16 row);   // acceptor == 0 appends a no-policy row; otherwise requireRealCode + requirePlainRuntime
function declareRoleExpectation(bytes32 purpose, bytes32 role, bytes32 expectedType) external returns (uint16 row);
function activateWrapper(uint8 version, address implementation) external;                 // codehash and grammarProfile read from the wrapper's own pure constants; requirePlainRuntime
function initialize(address ledger, address wrapperV1) external;                            // initializer; genesis creation transaction only (§8.2 G18); records wrappers[1] from the wrapper's own constants
function activate(uint32 revision) external;                                              // reinitializer(uint64(revision) + 1); onlyController; records activeRevision
// enumeration and discovery
function implementation() external view returns (address);                                // ERC-1967 implementation slot, one SLOAD; pinned per revision
function ledger() external view returns (address);
function catalog(uint64 ordinal) external view returns (bytes32 typeId);
function catalogCount() external view returns (uint64);
function descriptorBytes(bytes32 typeId) external view returns (bytes memory);             // bounded EXTCODECOPY of the blob (descriptor part only, ≤ DESCRIPTOR_MAX = 4,096)
function declaration(bytes32 typeId) external view returns (address key, bool installed, bytes32 signatureHash);
function policy(bytes32 typeId, uint16 row) external view returns (address acceptor, bytes32 codehash, uint64 activatedAt, uint64 mutationAt);
function roleRow(bytes32 purpose, bytes32 role, uint16 n) external view returns (bytes32 expectedType, uint64 activatedAt);
function roleRows(bytes32 purpose, bytes32 role) external view returns (uint16);
function wrapper(uint8 version) external view returns (address implementation, bytes32 codehash, uint8 codecVersion, bytes32 grammarProfile);
function binding(bytes32 typeId) external view returns (address custom, uint8 customAbi, bytes32 bindingId);
function typeCommitment(bytes32 typeId) external view returns (bytes32);                  // keccak(typeId, mandatory, ruleId, policyRows, policyCodehash) for the SDK's per-Type pin
```

### 5.10 `IAcceptor/2` (frozen before the first Files Type is registered; it is inside every native-grade `ruleId`)

```solidity
struct RefHeader { bytes32 typeId; uint64 firstAdmission; uint32 length; bytes32 word0; bytes32 word1; bytes32 word2; }
    // word1/word2 are loaded only up to the Type's declared refHeaderWords (1..3); undeclared words are zero
struct AcceptContext { bytes32 typeId; bytes32 realmId; bytes32 principalId; uint64 admission; uint32 revision; uint8 grade; uint8 leaf;
                       address ledger; address index; address registry; address descriptorBlob; address customPredicate; bytes32 bindingId; }
interface IAcceptor {
    function accept(AcceptContext calldata ctx, bytes calldata body, bytes32[] calldata refs, RefHeader[] calldata refHeaders) external view returns (bytes4);
}
bytes32 constant EXHAUSTED = keccak256("efs2/acceptor/2/exhausted");   // the one reserved 32-byte reply that is neither success nor refusal: nested exhaustion
```

Success is exactly 32 bytes of returndata equal to `bytes32(IAcceptor.accept.selector)` (left-aligned). The caller is the ledger proxy (the ingress in ledger context) and `ctx.ledger == address(this)`; every acceptor **must** require `ctx.ledger == msg.sender` (a forged context from a direct call or a lookalike coordinator then fails, PTA "supplied context alone is not authentication"). Read law for acceptors: `ILedgerHot(ctx.ledger)` getters (Etched, §5.3), `IIndexReads(ctx.index)` coverage and posting reads (prefix-`COMPLETE` inside the publication, ruling 21), `ITypeRegistry(ctx.registry)` role and policy rows; refs are pre-verified to exist with the declared Types; `refHeaders[i]` carries the words the kernel already loaded so the Files rules are pure over calldata (no parent body loads, IX-13). Never `extsload`, never a replaceable facet, never an immutable ledger address (release gate: `immutableReferences` empty for every `profiles/` contract, so Files Type ids are identical across Realms and chains). The wrapper's own rules: recompute `typeId` from `(keccak(SHAPE_DOMAIN, descriptor), refTypes projected from the descriptor, ruleId = own codehash)` and compare with `ctx.typeId`; require `extcodehash(ctx.descriptorBlob) == keccak(0x00 ‖ descriptor ‖ sig)`; for grade 2 require `ctx.customPredicate.codehash == descriptor.customHash` and nest the predicate call under the 63/64 rule — and when that nested call fails with empty returndata having consumed at least its forward − 2,000, return the reserved 32-byte word `EXHAUSTED` instead of refusing, which the kernel maps to `E_ACCEPTOR_GAS` (resubmit) rather than `E_REJECTED` (none), because the outer wrapper keeps 1/64 of its gas and the kernel's own exhaustion test cannot see the nested failure; any other 32-byte word is a refusal; the predicate authenticates `msg.sender.codehash == wrapperCodehash` and receives `ctx` unchanged, so it compares a wrapper-attested `ctx.ledger` with the ledger it is bound to.

### 5.11 `IRealmIndex`, `IIndexHook`, `IIndexReads`, `IPostingStore`, `IBitmapStore`

```solidity
struct Effect {   // Effect/3 — 24 static words (768 B); callbackProfile = keccak("efs2/index-callback/3:ordered-prefix:static-final:effect-24:refs")
    uint8 kind; uint8 leaf; uint64 admission; uint64 publication; bytes32 principalId; bytes32 typeId; bytes32 recordId; bytes32 subjectId;
    uint64 bindingOrdinal; bytes32 position; bytes32 purpose; bytes32 subject; bytes32 role; uint64 revision; uint64 prevAdmission;
    uint8 transitionKind; uint8 targetKind; uint8 oldTargetKind; uint8 refCount; bool freshRecord;
    bytes32 target; bytes32 oldTarget; uint64 withdrawnAdmission; bytes32 withdrawnPrincipal; }
// transitionKind: 0 none (publish/reuse/create/withdraw) 1 FIRST_BIND 2 REBIND 3 MASK 4 RELEASE 5 RESTORE (BIND from MASKED/RELEASED)
// freshRecord: first admission of recordId (unique-by-type, reference-position, digest folds); refCount: how many entries of `refs` belong to this effect, in order
// WITHDRAW: recordId/typeId of the withdrawn record, withdrawnAdmission = target admission, withdrawnPrincipal = its retained principal
struct WorkModel { uint8 formulaVersion; uint16 freshPerPublication; uint16 rwPerPublication; uint16 freshPerPublishFresh; uint16 rwPerPublish;
                   uint16 freshPerBindFresh; uint16 rwPerBind; uint16 freshPerRef; uint16 freshPerDigestSpec; uint32 computeBase; uint32 computePerAction;
                   uint32 computePerHookEffect; uint32 finalComputeBase; uint32 finalComputePerBind; }   // slot counts and compute; converted with limits.floor* at quote time
struct DigestSpec { bytes32 typeId; uint8 wordIndex; uint8 algorithm; }   // constructor-fixed; the core folds family 15 from body word `wordIndex` (one cold SLOAD, priced)
struct Unit { address foldHook; bytes32 foldCodehash; address finalHook; bytes32 finalCodehash; bytes32[] familyIds; bytes32 purposeFilter; bytes32 hotAbiId; bytes32 identity; }
struct FamilyEntry { bytes32 familyId; uint8 kind; uint8 universe; uint8 shape; bool mandatory; uint8 liveSemantics; bytes32 recipe; uint64 fromAdmission; address store; bytes32 storeCodehash; }
    // kind: the §10.2 kind number (0 reserved); universe: 1 TYPE 2 PRINCIPAL 3 SCOPE 4 TARGET 5 GLOBAL; shape: 1 APPEND_ORDERED 2 BITMAP
    // liveSemantics, read by shape — APPEND: 1 RETAINED (never releases) 2 OCCURRENCE (releases on WITHDRAW) 3 HEADS (releases on REBIND/MASK/RELEASE of the entry's head);
    //                                BITMAP: 1 MONOTONE (set-only; backfill ORs from write-once rows) 2 CURRENT_STATE (set and clear; backfill reads the current head, §10.6); 0 reserved
    // fromAdmission NOT_MAINTAINED = 2^64-1
struct Readiness { uint8 version; address ledger; bytes32 layoutId; bytes32 hotAbiId; bytes32 physicalProfile; bytes32 callbackProfile; bytes32 manifestHash; uint64 provenFrom;
                   uint64 completedAdmission; uint64 completedPublication; uint8 phase; bool ready; Unit[] units; FamilyEntry[] families; address build; bytes32 buildCodehash; }
    // phase echoes ILedgerHot(ledger).phase() (0 IDLE 1 PREPARING 2 APPLYING 3 FINAL); ready is the §10.5 predicate, which checkActivation re-derives from the tuple and the stores and never trusts

interface IRealmIndex {
    function onAdmission(uint64 publication, Effect[] calldata effects, bytes32[] calldata refs) external returns (bytes4);        // prefix; CALL from ledger context; msg.sender == ledger
    function afterPublication(uint64 publication, Effect[] calldata effects, bytes32[] calldata refs) external view returns (bytes4);   // final; STATICCALL; exact selector ack
    function replayReadiness() external view returns (Readiness memory);
    // idle-gated build entry points; each DELEGATECALLs the pinned IndexBuild (BUILD, with BUILD_CODEHASH re-verified per call) in the generation's own context
    function replayNextPublication(uint16 maxFacts) external returns (uint64 processed);                 // permissionless; fresh stores only (INITIAL_WRITER == this, !attached); refused once live
    function build(bytes32 familyId, uint16 maxFacts) external returns (uint64 through);                 // ascending from admission 1 into this generation's fresh store for a later APPEND_ORDERED family, before attachment
    function backfill(bytes32 familyId, ScopeKey scope, uint64 expectedThrough, uint16 maxEntries) external returns (uint64 through);   // BITMAP families; pre-declaration scopes only; this generation must be ledger.index()
}
interface IIndexBuild {   // the delegate behind the three entry points above: one per (layoutId, callbackProfile); holds no generation address; every selector reverts E_DELEGATE_ONLY when address(this) == SELF
    function replayNextPublication(uint16 maxFacts) external returns (uint64 processed);
    function build(bytes32 familyId, uint16 maxFacts) external returns (uint64 through);
    function backfill(bytes32 familyId, ScopeKey scope, uint64 expectedThrough, uint16 maxEntries) external returns (uint64 through);
}
interface IIndexHook {
    function fold(Effect calldata effect, bytes32[] calldata refs, uint64 publication) external returns (bytes4);   // bounded CALL; may write only its declared companion store
    function validate(uint64 publication, Effect[] calldata effects, bytes32[] calldata refs) external view returns (bytes4);   // bounded STATICCALL; exact selector ack; reads only write-once facts
}
interface IIndexReads {
    function manifestHash() external view returns (bytes32);
    function manifest() external view returns (bytes32 header, FamilyEntry[] memory families, Unit[] memory units, DigestSpec[] memory specs, WorkModel memory work, bytes32 physicalProfile, bytes32 callbackProfile);
    function workModel() external view returns (WorkModel memory);
    function coverage(FamilyId family, ScopeKey scope) external view returns (Coverage, uint64 fromAdmission, uint64 throughAdmission, uint8 phase);
    function coverageOfType(FamilyId family, TypeId typeId) external view returns (Coverage, uint64 fromAdmission, uint64 throughAdmission, uint8 phase);
    function coverageOfSpec(FamilyId family, TypeId typeId, uint8 specIndex) external view returns (Coverage, uint64, uint64, uint8);   // UNKNOWN for an undeclared spec
    function coverageOfDigest(uint8 algorithm) external view returns (Coverage, uint64, uint64, uint8);                                 // UNKNOWN for an undeclared algorithm
    function provenFrom() external view returns (uint64);
    function progress() external view returns (uint64 lastProcessed, uint64 lastPublication, bool gapped);
    function postingHeadOf(FamilyId family, TypeId typeId, uint64 ordinal, bytes32 value) external view returns (Coverage, uint64 count, uint64 live, uint64 last, bool synthesized);
    function postingSliceOf(FamilyId family, TypeId typeId, uint64 ordinal, bytes32 value, uint64 from, uint16 n) external view returns (Coverage, uint64[] memory, bool synthesized);   // n ≤ maxReadCount
    function occurrencesOf(bytes32 recordId) external view returns (Coverage, uint64 count, uint64 live, uint64[] memory entries);   // the by-record read; synthesizes the virtual first entry
    function ledger() external view returns (address);  function postingStore() external view returns (address);  function bitmapStore() external view returns (address);  function build() external view returns (address);
}
interface IPostingStore {   // STORE_ABI_ID = keccak("efs2/posting-store/1" ‖ sorted selectors ‖ return layouts): an immutable exposed by storeAbiId(), snapshot-tested like ILedgerHot; stores outlive generations, so this ABI is Etched
    // writes (authorization per §4.6; E_WRITER / E_FAMILY / E_ORDER)
    function append(FamilyId family, PostingKey key, uint64 ordinal, uint16 flagsOr) external returns (uint64 count);     // strictly increasing per key; the first append of a key writes only the head
    function release(FamilyId family, PostingKey key, uint64 n) external returns (uint64 live);                          // live −= n, checked
    function appendBatch(FamilyId[] calldata families, PostingKey[] calldata keys, uint64[] calldata ordinals) external;    // one CALL per publication if C1 decides to batch (risk 3)
    // reads: raw storage getters for the oracle (CQ-16): not family reads; the index derives keys
    function postingHead(PostingKey key) external view returns (uint64 count, uint64 live, uint64 last, uint16 flags);
    function postingAt(PostingKey key, uint64 i) external view returns (uint64);
    function postingSlice(PostingKey key, uint64 from, uint16 n) external view returns (uint64[] memory);
    function postingWords(PostingKey key, uint64 fromWord, uint16 n) external view returns (uint256[] memory);
    function writers() external view returns (address[] memory generations, uint64[] memory from, uint64[] memory to);
    function familyIds() external view returns (bytes32[] memory);  function initialWriter() external view returns (address);  function attached() external view returns (bool);
    function storeAbiId() external view returns (bytes32);  function ledger() external view returns (address);
}
interface IBitmapStore {   // same discipline: STORE_ABI_ID = keccak("efs2/bitmap-store/1" ‖ …)
    // writes
    function appendScopeEntry(FamilyId family, ScopeKey scope, uint64 bindingOrdinal) external returns (uint64 entryIndex);   // the kind-10 list: head (count, live, lastMutation, liveBits0, entry0) and entry word in one call on FIRST_BIND
    function setBit(FamilyId family, ScopeKey scope, uint64 entryIndex, bool value) external;                                   // a BITMAP family's live hook; stamps lastMutation in the same SSTORE
    function stamp(ScopeKey scope) external;                                                                                      // REBIND/RESTORE without a bit change: lastMutation only
    function openCoverage(FamilyId family, ScopeKey scope, uint64 liveFrom) external;                                            // a later BITMAP family's first live touch of a pre-declaration scope
    function backfillOr(FamilyId family, ScopeKey scope, uint64 wordIndex, uint256 orMask, uint64 through) external;              // IDLE only; MONOTONE families; within [through, liveFrom)
    function backfillSet(FamilyId family, ScopeKey scope, uint64 entryIndex, bool value, uint64 through) external;               // IDLE only; CURRENT_STATE families; value read from the current head
    function retireCoverage(FamilyId family, ScopeKey scope) external;
    // reads
    function scopeHead(ScopeKey scope) external view returns (uint64 count, uint64 live, uint64 lastMutation, uint48 liveBits0, uint16 flags, uint64 entry0);
    function scopeEntry(ScopeKey scope, uint64 i) external view returns (uint64 bindingOrdinal);
    function scopeSlice(ScopeKey scope, uint64 from, uint16 n) external view returns (uint64[] memory);
    function liveCount(ScopeKey scope) external view returns (uint64);
    function liveWords(ScopeKey scope, FamilyId family, uint64 fromWord, uint16 n) external view returns (uint256[] memory);
    function liveAt(ScopeKey scope, uint64 i) external view returns (uint64 bindingOrdinal);
    function lastMutation(ScopeKey scope) external view returns (uint64);
    function scopeCoverage(FamilyId family, ScopeKey scope) external view returns (uint64 through, uint64 liveFrom, uint64 retiredAt, uint8 state);
    function writers() external view returns (address[] memory generations, uint64[] memory from, uint64[] memory to);
    function familyIds() external view returns (bytes32[] memory);  function initialWriter() external view returns (address);  function attached() external view returns (bool);
    function storeAbiId() external view returns (bytes32);  function ledger() external view returns (address);
}
```

`FamilyId`, `ScopeKey`, `TypeId` and `PostingKey` are distinct value types so a posting key can never be passed as a coverage scope. `ScopeKey = keccak(DOM_SCOPE, principalId, purpose, subject)`; role-scope keys are `keccak(DOM_ROLE_SCOPE, principalId, purpose, role)` with `DOM_ROLE_SCOPE = keccak("efs2/vk/role-scope/1")`; family ids are `keccak("efs2/family/<name>/1")` with the names enumerated in §10.2 and vectored. Kind-10 scope lists are keyed by `ScopeKey` and live in `BitmapStore`; every `PostingStore` key is a `PostingKey` from `postingKey` (§5.8), including kind 16, whose value word is the `roleScopeKey`.

### 5.12 `IRealmController` (hand-rolled ownership; no OZ `Ownable`)

```solidity
function activate(ActivationSet calldata set) external;                        // onlyOwner, notFrozen
function beginTransition(uint32 targetRevision, uint48 deadlineBlock) external; // onlyOwner, notFrozen
function abortTransition() external;                                            // onlyOwner before the deadline; anyone after it
function transferOwnership(address pending) external;                           // onlyOwner; pending only; no effect until accepted
function acceptOwnershipAndActivate(ActivationSet calldata set) external;      // pendingOwner; the activation and the owner change are one transaction
function migrate(address successor, ActivationSet calldata set) external;      // onlyOwner; transfers both ProxyAdmin ownerships inside the activation
function freeze(ActivationSet calldata finalSet, bytes[] calldata laneCanaries) external;   // onlyOwner; §8.10: registry activation, terminal ledger activation, one canary per enabled lane (laneCanaries = pre-signed executeSigned calldata for b1/b2), renounce everything
function activatePolicy(bytes32 typeId, address acceptor) external;             // onlyOwner, notFrozen → registry (idle-gated)
function declareRoleExpectation(bytes32 purpose, bytes32 role, bytes32 expectedType) external;
function activateWrapper(uint8 version, address implementation) external;
function owner() external view returns (address);  function pendingOwner() external view returns (address);  function frozen() external view returns (bool);  function retired() external view returns (bool);
function ledger() external view returns (address);  function registryProxy() external view returns (address);  function admins() external view returns (address ledgerAdmin, address registryAdmin);
event OwnershipActivated(address indexed previous, address indexed current, uint32 revision);
event ControllerMigrated(address indexed successor, uint32 revision);
event Frozen(uint32 indexed terminalRevision, bytes32 executionSet, uint64 admissionHigh, uint64[] canaryPublications);   // emitted here, after the canaries (the kernel emitted Activated inside ledger.freeze)
```

There is no no-argument `acceptOwnership()` and no public `renounceOwnership()`: ownership can change only through an activation, and the owner is zeroed only inside `freeze`. `frozen()` is true only after `freeze`; a controller replaced by `migrate` reports `retired() == true` and `frozen() == false`. The controller exposes no `ProxyAdmin` passthrough: its only calls into the `ProxyAdmin`s are `upgradeAndCall` inside `activate`, `transferOwnership` inside `migrate` and `renounceOwnership` inside `freeze`.

### 5.13 Readers (`ILensReader`, `IFilesPageReader`, `IReaderDirectory`)

```solidity
struct Cursor { BasisCommit basis; ScopeKey scope; bytes32 lensHash; uint64 lensIndex; uint64 rawIndex; uint64 selectedSoFar; bytes32 queryHash; }   // lensHash = keccak(abi.encode(principals)); never msg.sender
struct Selection { Status status; bytes32 target; uint8 targetKind; uint64 revision; bytes32 principalId; uint64 admission; uint8 selectedIndex; }
struct Entry { bytes32 position; bytes32 role; Selection selection; }
struct Page { Qualified q; Entry[] rows; Cursor next; uint64 scanned; uint64 rawTotal; uint64 observedCurrent; uint64 selectedSoFar; bytes32 inventoryPin;
              uint8 scanStatus; bool startsAtOrigin; bool completeFromOrigin; Coverage listingCoverage; }
    // scanStatus (both page structs): 1 EXHAUSTED (the scope list ended) 2 LIMIT (row limit reached) 3 GAS (gasReserve early stop); 0 and 4..255 reserved

interface IReader {   // every reader listed in the directory implements it
    function ledger() external view returns (address);  function layoutId() external view returns (bytes32);
    function supportedProfiles() external view returns (bytes32[] memory callbackProfiles, bytes32[] memory physicalProfiles);
}
interface ILensReader is IReader {
    function resolve(bytes32[] calldata principals, Coordinate calldata c, BasisCommit calldata expected) external view returns (Qualified memory, Selection memory);
    function resolveRecord(bytes32[] calldata principals, Coordinate calldata c, uint32 maxBytes, BasisCommit calldata expected) external view returns (Qualified memory, Selection memory, RecordHeader memory, bytes memory body);   // one call: resolve + header + body
    function resolveNoTiebreak(bytes32[] calldata principals, Coordinate calldata c, BasisCommit calldata expected) external view returns (Qualified memory, Selection[] memory candidates);
    function resolveAt(bytes32[] calldata principals, Coordinate calldata c, uint64 asOf, BasisCommit calldata expected) external view returns (Qualified memory, Selection memory);
    function resolveManyAt(bytes32[] calldata principals, Coordinate[] calldata coords, uint64 asOf, BasisCommit calldata expected) external view returns (Qualified memory, Selection[] memory);
    function list(bytes32[] calldata principals, bytes32 purpose, bytes32 subject, Cursor calldata cursor, uint32 budget, uint8 fallThroughPolicy, BasisCommit calldata expected) external view returns (Page memory);
    function ledger() external view returns (address);  function supportedProfiles() external view returns (bytes32[] memory callbackProfiles, bytes32[] memory physicalProfiles);
}
interface IFilesPageReader is IReader {
    struct Query { uint32 fields; bytes32 tagConcept; uint8 kinds; }   // fields: F_NAME 1, F_HEADER 2, F_KIND 4, F_TAGS 8
    struct Row { bytes32 position; bytes name; uint8 targetKind; bytes32 target; bytes32 headRecord; uint64 headRevision; uint64 admission; bytes32 headerWord0; uint8 rowKind; }
        // headRecord/headRevision/headerWord0: the resolved HEAD record of a file row under F_HEADER (so a file read after a page is one `record()` call); rowKind: 1 ENTRY 2 ALIAS 3 WHITEOUT
    struct DirectoryPage { Qualified q; Row[] rows; Coverage listingCoverage; uint64 frontier; bytes next; uint64 scanned; uint64 rawTotal; uint64 observedCurrent;
                           uint64 selectedSoFar; bytes32 inventoryPin; uint8 scanStatus; bool startsAtOrigin; bool completeFromOrigin; }
    function listDirectory(bytes32 folderSubject, bytes32[] calldata principals, Query calldata q, BasisCommit calldata expected, bytes calldata continuation, uint32 limit, uint256 gasReserve)
        external view returns (DirectoryPage memory);
    function lookupName(bytes32 folderSubject, bytes32 nameRole, bytes32[] calldata principals, BasisCommit calldata expected) external view returns (Qualified memory, Row memory);
}
interface IReaderDirectory {   // permissionless, append-only, advisory
    function list(address ledger, bytes32 kind, address reader) external;   // requires real code and IReader(reader).ledger() == ledger; records codehash, layoutId, physicalProfile
    function readers(address ledger, bytes32 kind, uint16 from, uint16 count) external view returns (address[] memory, bytes32[] memory codehashes, bytes32[] memory layoutIds, bytes32[] memory physicalProfiles, uint16 next);   // physicalProfiles[i] = the reader's first listed physical profile at listing time
}
```

`fallThroughPolicy`: `1 MASK_BEATS_FALLTHROUGH` (FOLDER, HEAD) or `2 SILENCE_FALLS_THROUGH` (tag stances) — a reader parameter per purpose, not a kernel law. Readers resolve the live index per call (`ILedgerHot(ledger).index()`), serve any generation whose `callbackProfile`/`physicalProfile` they list in `supportedProfiles()` and return `UNSUPPORTED` otherwise; they pin `layoutId` through `BasisCommit.executionSet` and return `BASIS_STALE`/`UNSUPPORTED` as data so `Multicall3.aggregate3` degrades per item. **Listing-coverage law:** the `coverage` a paged reader returns is the listing's, `COMPLETE` only when `completeFromOrigin` (origin-started, exhausted, every selected scope genesis-complete); a page produced from a continuation is at most `PARTIAL`, and a terminal page from a continuation is never `COMPLETE` or `ABSENT_PROVEN`. Continuations are bound to `(queryHash, basis)` and refused otherwise; the domain hash is not a MAC, so paid completeness over several calls is the `QueryAccumulator` pattern (§11).

### 5.14 Consumer library (`EfsNative`, `EfsFiles`, `Keys`)

```solidity
library EfsNative {   // every call carries an explicit nonce so each lane has AlreadyAdmitted retry identity; every call binds both expectations by default
    struct Bind { bytes32 executionSet; bytes32 acceptanceProfile; }   // zero fields = unbound
    function publish(ILedger l, uint64 nonce, Bind memory b, bytes32 typeId, bytes memory body) internal returns (uint64 publication, bytes32 recordId);
    function create(ILedger l, uint64 nonce, Bind memory b, bytes32 salt) internal returns (uint64 publication, bytes32 subjectId);
    function bind(ILedger l, uint64 nonce, Bind memory b, Coordinate memory c, bytes32 target, uint64 expectedRevision) internal returns (uint64 publication);
    function unbind(ILedger l, uint64 nonce, Bind memory b, Coordinate memory c, uint64 expectedRevision) internal returns (uint64 publication);
    function release(ILedger l, uint64 nonce, Bind memory b, Coordinate memory c, uint64 expectedRevision) internal returns (uint64 publication);
    function withdraw(ILedger l, uint64 nonce, Bind memory b, uint64 admission) internal returns (uint64 publication);
    function batch(ILedger l, uint64 nonce, Bind memory b, Action[] memory actions, bytes[] memory bodies) internal returns (uint64 publication, uint64 firstAdmission);
    function myPrincipal(ILedger l) internal view returns (bytes32);          // Keys.principalFor(address(this), l.realmOrigin())
    function nextNonce(ILedger l) internal view returns (uint64);             // ILedgerHot(address(l)).nonceOf(myPrincipal(l)).nonce
    function currentBind(ILedger l, Action[] memory actions) internal view returns (Bind memory);   // executionSet() + ILedgerCommitments(l.ingress()).acceptanceProfileOf
}
library EfsFiles {   // Action[] builders for the measured recipes (§12.2); Type ids come from `profiles/FilesTypes.sol` (generated from the release) or the caller
}
library Keys {       // DOM_RECORD "efs2/record/1", DOM_SUBJECT "efs2/subject/1", DOM_POSITION "efs2/position/1", DOM_BINDING "efs2/binding/1",
                     // DOM_SCOPE "efs2/vk/binding-scope/1", DOM_ROLE_SCOPE "efs2/vk/role-scope/1", DOM_POSTING "efs2/pk/1", DOM_PRINCIPAL "efs2/principal/1",
                     // DOM_TYPE "efs2/type/1", DOM_REALM "efs2/realm/1", DOM_REALM_ORIGIN "efs2/realm-origin/1", DOM_PUBLICATION "efs2/publication/1",
                     // DOM_NATIVE_INTENT "efs2/native-intent/1", DOM_SIGNED_INTENT "efs2/signed-intent/1", DOM_PROFILE "efs2/acceptance-profile/1", DOM_DESCRIBED_SHAPE "efs2/described-shape/1",
                     // DOM_ROLE_KEY "efs2/role-key/1", DOM_EXECUTION_SET "efs2/execution-set/1", DOM_FAMILY "efs2/family/<name>/1";
                     // principalFor with the exact 23-byte ef0100 rule (L/src/Keys.sol:72-84). Derivations that changed from the prototype (realmOrigin gains realmSalt;
                     // publication domain "efs2/publication/1"; role-scope key gains a domain) are listed as changes in docs/ONE-WAY-DOORS.md with golden vectors, never called "verbatim".
}
```

### 5.15 Kernel-internal and factory interfaces (declared so the ABI union in `artifacts/` is complete; the delegate interfaces are not in the consumer closure)

```solidity
struct Prepared { bytes32 principalId; uint8 principalKind; uint8 proofKind; uint16 verifierProfile; uint8 v; address author; bytes32 witness0; bytes32 witness1;
                  uint64 nonce; uint64 deadline; bytes32 actionsHash; bytes32 acceptanceProfile; bytes32 indexObligations; bytes32 readSetHash; bytes32 intentDigest;
                  uint32 prefixFloor; uint32 finalReserve; uint32 freshSlots; uint32 rewrites; uint8 leafCount; uint8 flags; }   // 21 words, 672 B (§6.2)
interface ILedgerIngress {   // every selector reverts E_DELEGATE_ONLY unless running by DELEGATECALL in the ledger's context (address(this) != SELF)
    function prepare(uint8 lane, bytes calldata laneInput, Action[] calldata actions, bytes[] calldata bodies, bytes calldata guard, bytes calldata witness) external returns (Prepared memory);
        // lane 1 native (laneInput = abi.encode(Native)), 2 signed (abi.encode(Intent)); not `view` only because of the SignatureStore CALL under STATE retention (§7.4)
    function validateLeaf(uint8 leaf, TypeInfo calldata info, bytes32 recordId, bytes calldata body, uint64 admission, bytes32 principalId) external view returns (bytes32[] memory refs);
    function dispatchIndex(uint64 publication, Effect calldata effect, bytes32[] calldata refs, uint32 remainingPrefixFloor) external returns (uint32 spent);
    function checkActivation(ActivationSet calldata set) external view;
    function signatureStore() external view returns (address);   // the SIGNATURE_STORE immutable; 0 until the S2b build
}
interface ILedgerApply {     // same delegate-only guard; executes under the kernel's lock in the kernel's storage; makes no external call
    function applyLeaf(uint8 leaf, uint64 admission, Action calldata action, bytes calldata body, TypeInfo calldata info, bytes32 principalId, uint8 principalKind, uint16 policyRow, uint16 roleRow)
        external returns (Effect memory effect, bytes32[] memory refs);
}
interface IDescriptorStore {
    function predict(bytes calldata descriptor, bytes calldata declarationSig) external view returns (address);
    function put(bytes calldata descriptor, bytes calldata declarationSig) external returns (address blob);   // CREATE2 of 0x00 ‖ descriptor ‖ sig; idempotent; refuses > 24,576 B
}
interface IDescribedWrapper is IAcceptor { function codecVersion() external pure returns (uint8); function grammarProfile() external pure returns (bytes32); }
interface ISignatureStore { function put(uint64 publication, bytes calldata witness) external; function get(address ledger, uint64 publication) external view returns (bytes memory); }   // namespaced by msg.sender (the calling proxy); write-once
```

---

## 6. The write pipeline

Both lanes produce one fixed-size `Prepared` struct and run one private `_run`. Every check is a port of a measured prototype check (`L/src/Ledger.sol:450-800`, `L/src/PublicationSupport.sol`) unless marked *new*; the order is load-bearing: the falsifier suites assert refusal precedence, and the retry compare precedes every check whose outcome can change with time or Realm state.

### 6.1 Entry (kernel, before any write)

1. `phase() == IDLE` else `E_PUBLICATION_ACTIVE`; `TSTORE` the lock word `(PREPARING, publications + 1, admissions, 0)`.
2. Principal and digest (*reordered*): native — `msg.sender`, `Keys.principalFor(msg.sender, realmOrigin)` (EOA and exact 23-byte `ef0100` designator → key namespace; any other code → `contractPrincipal(realmOrigin, addr)`; code-less non-origin caller → `E_NATIVE_AMBIGUOUS`); `actionsHash = keccak(abi.encode(actions))`; `guardHash = keccak(guard)` (the raw bytes; `keccak("")` for the canonical-empty read set), so the kernel never decodes the guard; `intentDigest = nativeIntentDigest(realmId, principalId, ctx, actionsHash, guardHash)` — pure over calldata and two Realm constants. Signed — `principalId = intent.principalId`; `intentDigest = keccak(abi.encode(DOM_SIGNED_INTENT, hashStruct(intent), actionsHash))` — chain-free and pure over calldata (`Intent` already binds `realmId`, `realmOrigin` and `executionSet`); the chain-bound EIP-712 `signingDigest` over the cached domain is computed later, in `prepare`, only to verify the witness, and is never stored.
3. **Retry compare** (*reordered*): `ordinal = publicationAt[principalId][nonce]`, `stored = evidence[ordinal].w3`; `ordinal != 0 && stored == intentDigest` → `AlreadyAdmitted(ordinal)`; `ordinal != 0 && stored != intentDigest` → `E_NONCE(principalId, nonce, ordinal)`; `ordinal == 0 && nonce != principal.nonce` → `E_NONCE(principalId, nonce, 0)`. Nothing before this step depends on time, on the revision, on registry rows, on heads, on wallet code or on the chain id; an exact retry therefore reaches `AlreadyAdmitted` at any later block, including after a chain-acceptance change that recomputed the domain separator (I4).
4. `block.chainid == realm.acceptedChainId` else `E_CHAIN`.
5. Transition gate: if `transition.deadline >= block.number && revision < transition.target` revert `E_TRANSITION`; past the deadline writes resume with no call.
6. `realm.index != 0` else `E_NO_INDEX`. Frozen Realms accept writes.
7. Live-set tripwires: `sload(IMPLEMENTATION_SLOT) == revisions[revision].ledgerImpl` (`E_EXECUTION_DRIFT`); `extcodehash(INGRESS) == INGRESS_CODEHASH && extcodehash(APPLY) == APPLY_CODEHASH` (`E_HELPER_CODE`); `registry.activeRevision() == revision` (`E_REGISTRY_DRIFT`, *new*: the check §8.11 relies on).
8. Bounds: `1 ≤ n ≤ limits.maxActions`, `bodies.length == n`, bind kinds ≤ `maxBindsPerPublication`, Σ body bytes ≤ `maxBodyBytesPerPublication`, else `E_BATCH_SHAPE`.
9. Snapshot `registry.mutations()` into the lock word.
10. `DELEGATECALL LedgerIngress.prepare` (§6.2).

### 6.2 Preparation (`DELEGATECALL LedgerIngress.prepare`, fixed 672-byte output, bounded error copy ≤ 4,164 B; the delegate receives all remaining gas, there is no ceiling)

The ingress, in ledger context, reads `realm.*` and `principal[...]` through `Layout` and returns `Prepared{ principalId, principalKind, proofKind, verifierProfile, v, author, witness0, witness1, nonce, deadline, actionsHash, acceptanceProfile, indexObligations, readSetHash, intentDigest, prefixFloor, finalReserve, freshSlots, rewrites, leafCount, flags }` (21 words, 672 B; §5.15).

- **Native:** `ctx.deadline == 0 || block.timestamp <= ctx.deadline` (`E_EXPIRED`); `ctx.expectedExecutionSet == 0 || == realm.executionSet` (`E_EXECUTION_SET`; flag b3 when bound); if `ctx.expectedAcceptanceProfile != 0`, fold the acceptance profile (below) and require equality (`E_ACCEPTANCE_PROFILE`; flag b4 when bound; the fold is skipped when unbound); if `guard` is non-empty, capability b0 must be set (`E_UNSUPPORTED_GUARD`) and the read set is decoded, shape-checked, required to equal its canonical re-encoding (`E_READSET_SHAPE`, so `guardHash` is reproducible) and compared against live head snapshots (`E_READSET_STALE`); `acceptanceProfile`/`indexObligations` are returned zero for storage.
- **Signed:** `deadline != 0 && block.timestamp <= deadline` (`E_EXPIRED`); `realmId`/`realmOrigin` (`E_INTENT(1)`); `executionSet` (`E_INTENT(2)`); `acceptanceProfile` recomputed (`E_INTENT(3)`); `indexObligations == realm.indexObligations` (`E_INTENT(4)`); `readSetHash == readSetHash(guard)` (`E_INTENT(5)`); `authorityId == 0 && authEpoch == 0` unless capability b8 (`E_RESERVED`); head snapshots (`E_READSET_STALE`); then the witness under `verifierProfile`: **1** = exactly 65 bytes, low-s, `v ∈ {27, 28}`, `ecrecover(signingDigest) == principalId` as padded address and `intent.author ∈ {0, recovered}` (`E_SIGNATURE`); **2** = `intent.author` has real code, is not key-classified (not an EOA, not the 23-byte designator) and `Keys.contractPrincipal(realmOrigin, intent.author) == intent.principalId` (`E_SIGNATURE(5)`/`(6)`, *new*, before any call), `witness.length ≤ limits.maxWitness`; `available = (gasleft() − limits.kernelTail) × 63/64` must be ≥ `WALLET_GAS_FLOOR` (300,000, a closure constant; `E_GAS(0, needed, available)`, resubmit) and is forwarded whole: bounded assembly `STATICCALL isValidSignature(signingDigest, witness)` with a 32-byte output buffer, magic exact (`E_SIGNATURE(4)`); a failure with empty returndata having consumed ≥ available − 2,000 is `E_WALLET_GAS(available)` (resubmit), so a wallet whose check grows under a repricing is never permanently refused (I11); `evidenceHash = keccak(witness)`; the bytes go to `WitnessRetained` (`limits.witnessRetention == LOG_ONLY`, `w9.store = 0`) or, by one `CALL`, to the ingress build's pinned `SIGNATURE_STORE` (`STATE`, `w9.store = SIGNATURE_STORE`, flag b5) — the only external write the ingress ever causes, landing in the store's own namespace keyed by the calling proxy, which the S5 zero-write state-diff test allows exactly and nothing else; `author` := the wallet; unknown profile → `E_VERIFIER_PROFILE`.
- **Both:** when the acceptance fold runs (signed lanes always; native only when `expectedAcceptanceProfile != 0`) it refuses unknown Types before any callback (`E_UNKNOWN_TYPE`), and an unbound native call meets an unknown Type at the kernel's per-leaf `typeInfo` load instead; `(prefixFloor, finalReserve, freshSlots, rewrites) = indexFloor(realm.index.workModel, actions, limits)` (§10.4).

Acceptance profile: `keccak(DOM_PROFILE, executionSet)` folded per PUBLISH/REUSE leaf with `(typeId, mandatory, ruleId, policyRow, policyCodehash, effectiveValidationGas)` and per BIND leaf with `(purpose, role, roleRow, expectedType)`; no global epoch, so permissionless registration and unrelated activations never void a plan (TR-03). `effectiveValidationGas = header.validationGas == 0 ? ACCEPTOR_GAS_DEFAULT (300,000, a closure constant) : header.validationGas`; no Realm `Limits` field enters this value (§9.5(ii)).

### 6.3 Begin (first writes)

Counters below `2^48 − 64` else `E_COUNTER_SATURATED`. Then: `principal[principalId] = (nonce + 1, viewMutationVersion + (hasBindKind ? 1 : 0))` (one rewrite; fresh on the first publication); `publicationAt[principalId][nonce] = publication` (the digest is evidence `w3`); evidence words per §4.3 (`basisBlock = block.number`, `revision = realm.revision`, `deadline` at full width, `w10.submitter = msg.sender` on signed lanes, flags b3/b4/b5 as prepared); `ReadSetChecked` when guarded; `TSTORE phase = APPLYING`. Any later failure reverts all of it.

### 6.4 Per action, in signed order (`_applyOne`)

For leaf `i`: `++admission`; `kind` dispatch with the per-kind zero-shape law (`E_SHAPE`; unknown or reserved kind → `E_KIND`/`E_RESERVED`).

- **PUBLISH/REUSE.** *Kernel:* `typeInfo` (one registry `STATICCALL`; `E_UNKNOWN_TYPE`); PUBLISH: `body.length ≤ limits.maxBody`, `keccak(body) == bodyHash` (`E_BODY`); REUSE: the record header exists with the same Type (`E_MISSING_RECORD`, `E_TYPE_MISMATCH`). *Ingress:* `DELEGATECALL LedgerIngress.validateLeaf(leaf, typeInfo, recordId, body, admission, principalId)` (zero-write; for REUSE it loads the body words through `Layout`): resolves the leading `refCount` body words as existing records of the expected Types (`0 = ANY`, `1 = SELF` by one compare; other sentinels refused, `E_REF`), builds `RefHeader[]` with `refHeaderWords` words each, builds `AcceptContext{…, ledger = address(this), index = realm.index, registry}`, re-verifies `extcodehash(mandatory) == ruleId` (`E_ACCEPTOR_CODE`), computes `available = (gasleft() − limits.kernelTail) × 63/64` and requires `available ≥ effectiveValidationGas` (`E_GAS(leaf, needed, available)`), calls the mandatory rule by assembly `staticcall{gas: available}` into a 32-byte output buffer; success is `returndatasize() == 32 && word == selector`; on failure, empty returndata with `gasUsed ≥ available − 2,000`, or a 32-byte `EXHAUSTED` word (§5.10), → `E_ACCEPTOR_GAS(leaf, typeId, available)` (resubmit), anything else → `E_REJECTED(leaf, typeId)`; then, **only when the Type's active policy row names a nonzero acceptor**, the policy acceptor the same way (`E_POLICY_REJECTED`); the policy row (possibly a no-policy row) is recorded in the admission row either way. *Apply:* `DELEGATECALL LedgerApply.applyLeaf(...)` writes a fresh cell + body words or bumps `occurrences`; the admission row `{meta, a = recordId}` with `policyRow`; returns the Effect/3 with `freshRecord`, `refCount` (refs appended to the publication's `refs` buffer).
- **BIND.** `position = Keys.position(purpose, subject, role)`, `key = Keys.binding(principalId, position)`; `head.state ≤ 3` (`E_NOT_LIVE`); CAS on `revision == expectedRevision` (`E_CAS`); target exists as a record or subject (`E_TARGET_MISSING`); the *kernel* calls `roleExpectation(purpose, role)` (one registry `STATICCALL`) and requires a match when a row exists (`E_TARGET_TYPE`), passing `roleRow` to the apply delegate, which makes no external call; a fresh key mints `bindingOrdinal`, writes `bindingPosition` and the write-once position cell; head meta rewritten `(BOUND, revision + 1, admission, targetKind, prevAdmission = old admission, bindingOrdinal)`; the target word is rewritten only when it differs; admission row with `prevAdmission` and `targetKind`; Effect/3 carries `transitionKind` (FIRST_BIND / REBIND / RESTORE), `oldTarget`, `oldTargetKind`.
- **UNBIND (mask) / RELEASE.** live (RELEASE also from MASKED); CAS; state → 2 / 3; **the target word is kept**; admission row (meta only); Effect/3 with `oldTarget` = the canonical target before the transition.
- **CREATE.** `salt != 0` (`E_SALT`); `subjectId = Keys.subject(principalId, salt)` unseen (`E_SUBJECT_EXISTS`); subject cell; admission row `{meta, a = salt}`.
- **WITHDRAW.** `target ∈ (0, admission)`, a PUBLISH/REUSE, not withdrawn, retained principal equals the author (`E_WITHDRAW`); target row `withdrawn = 1`; `occurrences − 1` by checked subtraction; bytes never erased; heads untouched; Effect/3 carries the withdrawn coordinate.

After every leaf: `_checkpoint` (counters word, dirty after the first write, so the staged frontier is visible through `counts()`/`phase()`); the index prefix callback for this one effect (`DELEGATECALL LedgerIngress.dispatchIndex`, §10.3) under the **availability floor**: `available = (gasleft() − finalReserve − limits.kernelTail) × 63/64`; `available < remainingPrefixFloor` → `E_INDEX_GAS(remaining, available)` before the call; the call receives `available`; after it `remainingPrefixFloor −= min(spent, remainingPrefixFloor)` (bookkeeping for the next leaf's check only, never a refusal); then the **basis re-check**: `registry.mutations() == snapshot` (`E_REGISTRY_DRIFT`) and `sload(IMPLEMENTATION_SLOT) == revisions[revision].ledgerImpl` (`E_EXECUTION_DRIFT`) — one warm `STATICCALL` + one warm `SLOAD`.

**Memory discipline (a C1 row).** Solidity never frees memory, and the prototype's memory-only change cut a create from 14.21M to 8.68M (`AN/followup-3.md:94`). The kernel therefore allocates once per publication — one scratch region reused for the three delegate payloads (the apply input, the `validateLeaf` input with its `TypeInfo` and `RefHeader[]`, the `dispatchIndex` input with one `Effect/3`) and preallocated `Effect[]`/`refs` buffers sized from `n` and `limits.maxRefs` — and rewrites them per leaf instead of growing the free-memory pointer; C1 adds a memory-expansion row at 64 leaves, and the joint envelope at the 2^24 cap is measured with this discipline in place.

### 6.5 Final

`TSTORE phase = FINAL`; require `(gasleft() − kernelTail) × 63/64 ≥ finalReserve` (`E_INDEX_GAS`); `afterPublication(publication, Effect[], refs)` by `STATICCALL` with everything available, exact 32-byte selector acknowledgement (`E_INDEX_FINAL`); basis re-check; counters final write; clear the lock; emit `Published(..., effectsHash, revision)`; return `(publication, firstAdmission)`.

### 6.6 Rollback law and recovery law

Any failure anywhere reverts the whole publication and the enclosing application call; the transient lock clears with the frame; tests hash a `Layout`-derived raw-slot digest before and after every refused call. An exact retry on any lane reverts `AlreadyAdmitted(ordinal)` with no writes at any later block; a different plan under a consumed nonce reverts `E_NONCE(principal, nonce, ordinal)`; upgrades and the freeze never reset nonces.

**Recovery classifier** (the SDK's law, published in `docs/RECOVERY.md` and vectored): read `publicationAt(principalId, plan.nonce)` and the block header **at one finalized block hash `H`** (EIP-1898 `requireCanonical`, SC-R1). `COMMITTED` iff `ordinal != 0 ∧ storedDigest == plan.intentDigest`; `NOT_COMMITTED_PROVEN` iff `(ordinal != 0 ∧ storedDigest != plan.intentDigest)` (the nonce was consumed by another plan: the second-device case) `∨ (ordinal == 0 ∧ plan.deadline != 0 ∧ timestamp(H) > plan.deadline)`; otherwise `UNKNOWN` (keep waiting or rebroadcast the identical bytes; an identical rebroadcast can only land once). `nonceOf` is not part of the classifier (it is implied by `publicationAt`); it serves the next nonce. The plan's `intentDigest` is computed offline from plan-intrinsic inputs only, so no activation, policy change, index replacement, head change or key rotation between preparation and recovery can make the classifier lie.

---

## 7. Authorship lanes and the evidence schema

### 7.1 Lanes

| Lane | Stage | Author / principal | proofKind / verifierProfile | Deadline | Fresh evidence slots | Notes |
|---|---|---|---|---|---|---|
| Native call | S1 | `msg.sender`; `principalFor` | 1 / 0 | optional | 5 + `publicationAt` | the first-class contract lane; `expectedExecutionSet`/`expectedAcceptanceProfile` optional, bound by the SDK by default; CAS on heads is the Files stale-revision precondition without guards |
| Native guarded | S2 (b0) | same | 1 / 0 | optional | + `readSetHash` | guard decoded by the ingress |
| secp256k1 EIP-712 | S2 (b1) | `ecrecover` → padded address; `intent.author` 0 or equal | 2 / 1 | required | 10 (+1 guarded) | chain-bound signing domain, chain-free retry key; relayable, the relayer recorded as `submitter` (`w10`) |
| ERC-1271 | S2b (b2) | `intent.author` (deployed wallet) with `contractPrincipal(realmOrigin, author) == principalId`; EOA/7702 refused | 3 / 2 | required | 10 (+1 guarded) + optional store row | `STATICCALL` with a 300k floor forwarded whole (`E_WALLET_GAS` on exhaustion); bytes in `WitnessRetained` or the pinned `SignatureStore` per `limits.witnessRetention`; never re-validated against current wallet code; relayer recorded as `submitter` |
| P-256/WebAuthn | reserved (b3) | passkey | 4 / 3 | required | as signed | EIP-7951 live at 6,900 gas |
| Import | S4 (b5) | source author; destination authority separate | native/signed + `imported` | — | + `efs.ledger.v2.source` | verified under the source domain; packet decoding and verification in the ingress, writes through `LedgerApply`; native-source packets refused until a witness format exists; import of a `LOG_ONLY` ERC-1271 row requires the witness bytes in the packet |
| Routed consent | reserved (b7) | executor-pinned | high nibble of `verifierProfile` | — | `actor` word | later |
| KEL-managed | reserved (b8) | `authorityId`, `authEpoch` | principalKind 3+ | — | `authorityId`, `authEpoch` | zero-enforced until activation |

### 7.2 Signing domain (engineering decision; James confirms as Q2)

`EIP712Domain(name = "EFS", version = "2", chainId, verifyingContract = ledgerProxy)`. The guarded struct binds `realmOrigin` and `executionSet`; portability is the import lane's job with its own witness. The domain separator is cached at activation and recomputed on a chain-acceptance change; it enters only the `signingDigest` the key or wallet signs, while the stored retry key (`w3`) is the chain-free `intentDigest` (§5.8), so a plan admitted before a chain-acceptance change still retries as `AlreadyAdmitted` after it, and an as-yet-unsent plan prepared before the change dies by domain. Declaration signatures (§9.3) are the one deliberately chain-free signature: they authorize no effects. The `Intent` typehash (with `author`) freezes at S2.

### 7.3 Evidence stable from day one

Per §4.3: `proofKind` with reserved values, `principalKind`, `verifierProfile`, full-width `principalId`, `nonce`/`deadline`/`basisBlock`/`revision`, plan-intrinsic `intentDigest` and `actionsHash` on every lane, signed-lane commitments for signed lanes only, the submitter (relayer) address for signed lanes (`w10`: author and submitter are distinct recorded roles; the payer is the transaction's `from` and is not recorded), the two bound bits for native rows, typed non-ECDSA pair, reserved `actor`/`authorityId`/`authEpoch`. `publicationId = keccak(abi.encode(DOM_PUBLICATION, principalId, intentDigest))` on every lane (the prototype's format-2 shape under the `efs2/publication/1` domain; its format-1 `(author, nonce, actionsHash)` id is not used). `WITHDRAW.target` stays the local admission ordinal in the Action; `LedgerViews.publication` reports the portable coordinate `(principalId, nonce, leaf)`.

### 7.4 Retention profiles (default: hash in state, bytes in logs; portability graded honestly)

`limits.witnessRetention` (a `Limits` field, hence inside `limitsProfileId` and changed only by activation; 1 LOG_ONLY, 2 STATE) names the retention profile: read-set preimages are hashed into `w7` and emitted in `ReadSetChecked`; under LOG_ONLY, ERC-1271 witnesses are hashed into `w8` and emitted in `WitnessRetained` with `w9.store = 0`; under STATE the bytes are retained in the S2b ingress build's `SIGNATURE_STORE` immutable (listed in `release.json` and `dependencyRoot`; `w9.store` nonzero, flag b5), paid by the submitter — the ingress's one external write, allowed by name in the zero-write state-diff test (I3). A per-intent opt-in instead of a Realm-wide profile is the second half of Q5, to be decided before the S2 `Intent` typehash freezes. `Evidence.retention` reports `STATE` or `LOG_ONLY`; readers and the import lane treat a `LOG_ONLY` row's authorship evidence as `UNKNOWN` for portability (state alone cannot re-verify it) while the admission itself remains canonical state. A fresh 64×4 guard carrier would cost ≈ 16.5M under EIP-8037 (`AN/followup-6.md` §B.4); hash + log ≈ 85k of log data plus the 256 head reads. James Q5 decides whether import-eligible plans must use state retention.

---

## 8. Activation, upgrade, transition, migration and freeze

### 8.1 The execution-set commitment

```text
executionSet = keccak256(abi.encode(DOM_EXECUTION_SET, layoutId, domainSeparator, ComponentSet, revisionOrdinal, executionProfileId, capabilities, acceptedChainId, limitsProfileId))
ComponentSet = (ledgerImpl, ledgerImplCodehash, registryImpl, registryImplCodehash, index, indexCodehash, indexManifestHash,
                ingress, ingressCodehash, applyDelegate, applyCodehash, controller, controllerCodehash, controllerOwner, steward, verifierProfilesRoot)
```

Block, timestamp and high-water marks are recorded and emitted, never hashed, so an operator precomputes `expectedExecutionSet` offline from `(components, current + 1)`. The **revision ordinal is inside the hash** (UF-3): same-code reactivation and rollback invalidate every pending signed plan, bound native plan and cursor. **The read facets are not components**: a facet fix is a redeploy plus a `ReaderDirectory` listing, it changes no execution set, voids no plan and no cursor, and acceptors cannot depend on one (§5.10). The hash is computed once at activation and cached.

### 8.2 Genesis (one deploy plan, journaled deployer, every step idempotent; CREATE2 through the EIP-7997 factory `0x4e59b44847b379578588920cA78FbF26c0B4956C`)

Every address is computed offline before anything is deployed: CREATE2 addresses from initcode hashes, the three `RealmGenesis` creations from its nonces. The plan lists each step with its post-check; the order below is dependency order for constructors that read code.

```text
G1   LedgerIngress/1 (immutables: SELF, SIGNATURE_STORE = 0 at S1)                                              CREATE2
G2   LedgerApply/1 (SELF)                                                                                       CREATE2
G3   LedgerReads/1;  G4  LedgerViews/1 (both generated for layoutId)                                             CREATE2
G5   DescriptorStore;  G6  DescribedTypeRule/1;  G7  IndexReplayDecoder(layoutId);  G8  ReaderDirectory          CREATE2
G9   IndexBuild/1 (per layoutId and callbackProfile; SELF; holds no generation address)                         CREATE2
G10  the nine NATIVE rule instances of §12.1 at CREATE2(FACTORY, salt 0, ruleInitcode): FilesRootRule, FilesChildRule, FilesDirectoryRule,
     FilesNameRule (files-name/2), FilesBytesRule, FilesContentRule, FilesExternalContentRule, DirectoryAliasRule, RealmNoticeRule; plus RefuseAllPolicy
     post-check: each address equals the descriptor header's ruleInitcodeHash prediction and extcodehash == header.ruleCodehash
G11  the nine descriptor blobs through DescriptorStore.put (CREATE2 by the store; idempotent)
G12  FilesFinalValidator (no caller pin)                                                                         CREATE2
G13  LedgerCore implementation (immutables: INGRESS, INGRESS_CODEHASH, APPLY, APPLY_CODEHASH, LAYOUT_ID, PREDECESSOR_LAYOUT_ID = 0, HOT_ABI_ID,
     SUPPORTED_HOT_ABI_IDS = [HOT_ABI_ID], SELF; constructor calls _disableInitializers)                        CREATE2
G14  TypeRegistry implementation (SELF; _disableInitializers)                                                   CREATE2
G15  RealmGenesis by CREATE2 with initcode embedding (owner, ledgerImpl, registryImpl, their codehashes, realmSalt, executionProfileId, Limits,
     readerDirectory, wrapper v1). Its address G is known before anything below exists, so every CREATE address below is f(G, nonce):
     controller = CREATE(G, 1), registryProxy = CREATE(G, 2), ledgerProxy = CREATE(G, 3) — computed by the plan and embedded in G16–G17 and G19.
G16  PostingStore(ledgerProxyPredicted, INITIAL_WRITER = 0, FAMILY_IDS = the gen-1 APPEND families except kind 10)                      CREATE2
G17  BitmapStore(ledgerProxyPredicted, INITIAL_WRITER = 0, FAMILY_IDS = [scope (10), live-scope (18)])                                CREATE2
G18  RealmGenesis.run():
       1. new RealmController(owner, ledgerProxyPredicted, registryProxyPredicted)                       // nonce 1; asserts == predicted
       2. new TransparentUpgradeableProxy(registryImpl, controller, initialize(ledgerProxyPredicted, wrapper v1))   // nonce 2; OZ creates its ProxyAdmin owned by controller (§5.9 initialize)
       3. new TransparentUpgradeableProxy(ledgerImpl, controller, initialize(RealmInit{realmSalt, controller, registryProxy, readerDirectory, profile, limits}))   // nonce 3
          -> genesisChainId = acceptedChainId = block.chainid; coreAddress = address(this); realmOrigin, realmId derived; revision = 0; index = 0;
             transition := (target 1, deadline type(uint48).max, lastTarget 0, cooldownUntil 0) => WRITES DISABLED until the genesis activation
       4. asserts registry.ledger() == ledgerProxy, ledger.registry() == registryProxy, ledger.controller() == controller, both ProxyAdmin.owner() == controller;
          journals the three addresses; a second run() reverts
G19  RealmIndex/1(ledgerProxy, layoutId, decoder, [postingStore], bitmapStore, build, buildCodehash, manifestInputs) by CREATE2, with FilesFinalValidator pinned
     and the two Files digest specs (files-content/1 word 5 and files-external/1 word 5, sha256) in the manifest; the constructor reads counts() (== 0) and layoutId()
     and does not read the stores (readiness does, at G20)
G20  controller.activate(genesisSet{revision 1, components, capabilities = 0, acceptedChainId = genesis, limits, noticePrincipal, expected})
       -> fresh-genesis readiness (frontier 0 == admissions 0; stores empty; every manifest family in its store's FAMILY_IDS), installs the index, records
          revision 1, clears the transition (lastTarget stays 0), caches executionSet; post-check: ledger.executionSet() == plan.expectedExecutionSet
G21  permissionless registerDescribed for the nine §12.1 Types (idempotent by construction: NATIVE instances are deterministic, §9.3)
G22  the seed (§12.2 Root, then the sample folder and file) by the fixture principal; post-check: expected.json
```

No window accepts a write without a ready index; no proxy has an unauthenticated initialization step (initialized in its creation transaction inside `run()`); constructors read no `msg.sender` for authority; there is no address cycle anywhere: the controller's immutables are nonce-derived predictions of contracts the same call creates next, the proxies' initcode embeds the controller's actual address, the genesis stores name no generation (`INITIAL_WRITER = 0`) and `IndexBuild` names no generation; a stranger replaying `deploy/plan.json` produces identical addresses and state or reverts (S9). G21's registrations are idempotent **by construction** because NATIVE instances are deterministic (§9.3): a front-run deploys the same bytes at the same address and the deployer's call returns the same id. No role expectation rows are declared at genesis (§12.1).

### 8.3 Ordinary activation (one transaction, controller-only)

```text
RealmController.activate(ActivationSet set) onlyOwner notFrozen:
  0. require set.components.controller == address(this) && set.components.controllerCodehash == address(this).codehash
       && set.components.controllerOwner == owner()                                                                   E_CONTROLLER(field)
  1. require ledger.phase().phase == IDLE                                                                              (STATICCALL)
  2. if set.components.ledgerImpl != current:   ledgerAdmin.upgradeAndCall(ledgerProxy, set.components.ledgerImpl, "")
  3. if set.components.registryImpl != current: registryAdmin.upgradeAndCall(registryProxy, set.components.registryImpl, "")
  4. registry.activate(set.revision)              // reinitializer(revision + 1); msg.sender == ledger.controller(); records activeRevision
  5. ledger.activate(set)                         // reinitializer(revision + 1); onlyController (msg.sender == realm.controller):
       a. set.revision == revision + 1                                                                               E_REVISION
       b. run set.migration FIRST, bounded, with every SSTORE confined to set.migrationScope (namespace roots listed; state-diff asserted in tests;
          on-chain: the migration routine is the new implementation's own, so the scope is a declared claim recorded as migrationHash)     E_MIGRATION_SCOPE
       c. sload(IMPLEMENTATION_SLOT) == set.components.ledgerImpl && extcodehash == set.components.ledgerImplCodehash     E_IMPLEMENTATION
       d. set.layoutId == LAYOUT_ID (immutable of the new implementation) && (realm.layoutId == LAYOUT_ID || realm.layoutId == PREDECESSOR_LAYOUT_ID)   E_LAYOUT
       e. registry.activeRevision() == set.revision && registry.ledger() == address(this)
          && registry.implementation() == set.components.registryImpl && extcodehash(registryImpl) == set.components.registryImplCodehash   E_REGISTRY
       f. set.components.ingress == INGRESS && ingressCodehash == INGRESS_CODEHASH && applyDelegate == APPLY && applyCodehash == APPLY_CODEHASH
          (the new implementation's immutables; the set cannot name a helper the kernel does not run)                   E_PIN
       g. CodePins.requireRealCode + CodeScan.requirePlainRuntime + codehash equality for index, steward (if nonzero), every unit, store and build
          contract the index enumerates (the two proxied implementations are codehash-pinned at 5c/5e, never scanned: the ledger must DELEGATECALL);
          every unit's hotAbiId ∈ the new implementation's SUPPORTED_HOT_ABI_IDS, and that list ⊇ the current implementation's list   E_PIN / E_CODE_SHAPE / E_HOT_ABI
       h. DELEGATECALL LedgerIngress.checkActivation(set) (ledger context; zero-write):
            if set.components.index == realm.index: require indexCodehash and indexManifestHash equal the current revision row's and
               IRealmIndex(index).replayReadiness().phase == IDLE                                                      (unchanged index: no readiness tuple)
            else: Readiness => ledger == this, layoutId == LAYOUT_ID, hotAbiId ∈ SUPPORTED_HOT_ABI_IDS, manifestHash == set.components.indexManifestHash,
               the §10.5 ready predicate re-derived (phase IDLE, completedAdmission == counts().admissions, completedPublication == counts().publications,
               every APPEND_ORDERED family from == 1 (built or carried), every store's writers ranges contiguous and every manifest family in its store's
               FAMILY_IDS), stores and units pinned by codehash; the tuple's own `ready` flag is never trusted                        E_INDEX_NOT_READY
            ERC-1967 admin slot == the expected ProxyAdmin; ProxyAdmin(admin).owner() == msg.sender (the executing controller)          E_PIN
       i. write revisions[set.revision] (25 words, §4.3; flags; indexGeneration := set.revision when the index changed, else carried; limits words and noticePrincipal)
       j. realm.{index, indexGeneration, controller, steward, capabilities, acceptedChainId, layoutId, limits*, limitsProfileId, noticePrincipal} := set; revision := set.revision;
          clear transition.target/deadline (lastTarget is untouched: beginTransition writes it); if a transition to set.revision was open emit TransitionEnded(target, 1),
          if one had expired unobserved emit TransitionEnded(target, 3) and set cooldownUntil := deadline + maxTransitionBlocks;
          recompute and cache domainSeparator, indexObligations, executionSet
       k. emit Activated(revision, executionSet, block, admissionHigh, flags)
  6. require ledger.executionSet() == set.expectedExecutionSet                                                           E_EXPECTED_SET
```

Between steps 2/3 and step 5 the only external calls are step 4 into the registry (which runs the registry's own migration under its reinitializer) and the readiness reads; nothing can write ledger rows under new code before the revision row exists because the entry tripwire (§6.1 step 7) refuses writes whose implementation slot differs from the current revision row's. `upgradeAndCall` data is empty because OZ v5 runs that data as the `ProxyAdmin`; migrations run inside the `reinitializer` bodies. Same-code reactivation advances the ordinal and sets flag b1. Rollback is an activation to the previous implementation with a new ordinal. The §16.5 invariant #12 reads: the raw-slot digest of every row outside the declared migration scope is unchanged by any activation.

### 8.4 Owner change (an activation)

```text
tx 1  controller.transferOwnership(safe)                             // pending only; nothing changes
tx 2  safe -> controller.acceptOwnershipAndActivate(set)              // owner := safe, then §8.3 steps 0–6 with flag b4; step 0 sees controllerOwner == safe
```

Between tx 1 and tx 2 nothing changes and the old owner may still activate; there is no other way for the owner to change.

### 8.5 Controller migration (an activation)

```text
tx 1  controller.migrate(successor, set) onlyOwner notFrozen:
        require CodePins.requireRealCode(successor) && CodeScan.requirePlainRuntime(successor)
             && successor.codehash == set.components.controllerCodehash && set.components.controller == successor
             && set.components.controllerOwner == IRealmController(successor).owner()                                   E_SUCCESSOR
        steps 1 and 4–6 of §8.3 with flag b3 (step 0's controller equality is replaced by the successor equality above; step 5h's
        ProxyAdmin.owner() == msg.sender still holds because the admins move afterwards)
        ledgerAdmin.transferOwnership(successor); registryAdmin.transferOwnership(successor)     (OZ Ownable: immediate for ProxyAdmin)
        require ledgerAdmin.owner() == successor && registryAdmin.owner() == successor
        controller.retired = true                                                                 (the old controller is dead: every onlyOwner path reverts E_RETIRED; frozen() stays false)
```

After tx 1 the ledger's `realm.controller` is the successor, the registry obeys `ledger.controller()`, and the successor can activate, activate policies and freeze; the must-pass S1 test is *migrate → activate → activatePolicy → freeze* through the successor. A successor with a defect is replaced the same way.

### 8.6 Why upgrade-without-activation cannot happen

Both `ProxyAdmin`s are owned by the controller, whose runtime is pinned by `controllerCodehash` in the execution set and refused at `migrate` if it contains `DELEGATECALL`/`CALLCODE`/`SELFDESTRUCT`/`CREATE`/`CREATE2` or has a proxy or designator shape. `ProxyAdmin.upgradeAndCall`, `transferOwnership` and `renounceOwnership` are `onlyOwner`; the controller exposes none of them as a passthrough. Therefore the set of paths that change an implementation is exactly the activation family, each writing a revision row before returning. The residual is a malicious implementation installed by a legitimate activation — the disclosed power of the testnet administrator (`describe().controllerOwner`). The per-write checks (implementation slot, helper codehashes, `registry.activeRevision()`) are tripwires; the c0 tests "ProxyAdmin ownership drift blocks writes" and "configuration drift behind unchanged code blocks writes" are **retired as per-write checks** (reason: the drift they model is unreachable without the pinned controller, and a per-write `ProxyAdmin.owner()` pair costs ≈ 10k) and rebuilt as *drift is detected at the next activation (step 5h) and visible in `describe()` and `verify-deployment`*.

### 8.7 Basis-stability gating table

| Mutation path | Gate |
|---|---|
| `LedgerCore.activate`, `freeze`, `beginTransition`, `abortTransition` | onlyController; `phase == IDLE` |
| `TypeRegistry.activatePolicy`, `declareRoleExpectation`, `activateWrapper`, `activate` | `msg.sender == ledger.controller()`; `!ledger.control().frozen`; `ledger.phase() == IDLE`; bumps `mutations` |
| `TypeRegistry.registerDescribed`, `retainDeclaration` (permissionless) | allowed mid-publication; registration is append-only and never changes an existing Type, policy or role row |
| `RealmIndex.replayNextPublication`, `build`, `backfill` (`DELEGATECALL` into the pinned `IndexBuild`) | permissionless; `ledger.phase() == IDLE`; replay/build write only this generation's fresh unattached stores (as their `INITIAL_WRITER`); backfill writes only coverage-gapped pre-declaration scope ranges and only while this generation is `ledger.index()`; never a live family's current postings |
| `PostingStore`/`BitmapStore` writes | §4.6: `msg.sender == ledger.index()` (live while `phase != IDLE`; backfill while `IDLE`), or `msg.sender == INITIAL_WRITER` of a fresh store before its first live write (build/replay) |
| `ProxyAdmin.upgradeAndCall` | owner = controller; unreachable without `activate` |
| `DescriptorStore.put`, `ReaderDirectory.list` | permissionless, content-addressed / advisory |

### 8.8 Transition (busy Realm) and index replacement

A new generation is deployed (together with any fresh stores, through `IndexDeployer`, §10.1), caught up by permissionless `replayNextPublication()` (fresh stores) or by `build()` of only its new families (re-pinned stores carry the rest) while the old one stays live. If writes keep landing: `controller.beginTransition(targetRevision, deadlineBlock)` requires `targetRevision == revision + 1`, `targetRevision != transition.lastTarget` (`E_TRANSITION_TARGET`: a target, once begun, can never be begun again — an aborted or expired transition is spent, and the next pause needs a later target, hence an activation in between, which is disclosed), `block.number ≥ transition.cooldownUntil` (`E_TRANSITION_COOLDOWN`) and `deadlineBlock − block.number ≤ limits.maxTransitionBlocks` (`E_DEADLINE_BOUND`); it writes `lastTarget := targetRevision`, `target` and `deadline`, and if the previous transition expired unobserved it first emits `TransitionEnded(previous, 3)` and sets `cooldownUntil := previousDeadline + maxTransitionBlocks`, so the gate is effectively `block.number ≥ max(cooldownUntil, previousDeadline + maxTransitionBlocks)`. Ordinary writes revert `E_TRANSITION` while `block.number ≤ deadline`; the operator drives the last steps and calls `activate`, which clears `target`/`deadline` and emits `TransitionEnded(target, 1)`. `abortTransition()` reopens early (controller) or after the deadline (anyone), emits `TransitionEnded(target, 2)` and sets `cooldownUntil = block.number + maxTransitionBlocks`; expiry reopens writes with no call. A lost key costs at most `maxTransitionBlocks` once; a live controller cannot renew the pause without an activation (which is disclosed) and cannot pause more than half of any period (cooldown). Index replacement advances the revision, so plans and cursors bound to the old set are refused (Q11).

### 8.9 Chain-acceptance change (an activation)

`activate(set)` with `set.acceptedChainId != current` sets flag b2, recomputes the domain separator (old signed plans die by domain) and reopens writes after a fork or renumbering. `realmOrigin` keeps the genesis chain id forever. Refused after the freeze (a frozen Realm is read-only on a fork; James Q10).

### 8.10 Freeze ceremony (one-way, one transaction)

```text
RealmController.freeze(ActivationSet finalSet, bytes[] laneCanaries) onlyOwner notFrozen notRetired:
  1. pre-checks (E_FREEZE_PRECHECK(n)): (1) finalSet.acceptedChainId == block.chainid; (2) finalSet.components.index == ledger.index(), or its
     readiness tuple satisfies the step-5h predicate; (3) ledger.phase() == IDLE; (4) no open transition; (5) finalSet.components.steward == 0 unless
     posture B is ruled; (6) finalSet.dependencyRoot != 0; (7) finalSet.capabilities ⊇ the current revision's capabilities (a terminal set cannot
     silently retire a lane); (8) every maximum in finalSet.limits ≥ the current revision's (the published envelope stays admissible);
     (9) laneCanaries has exactly one entry per set bit among b1/b2 of finalSet.capabilities
  2. §8.3 step 0 (controller, codehash and owner fields)                                                                 E_CONTROLLER
  3. §8.3 steps 1–3 (idle; optional final implementation upgrades)
  4. registry.activate(finalSet.revision)                        // §8.3 step 4 — BEFORE ledger.freeze, because step 5e requires registry.activeRevision() == set.revision
                                                                 // and the registry refuses every activation once ledger.control().frozen; this is the registry's last activation
  5. ledger.freeze(finalSet)                                     // §8.3 steps 5a–5j with flag b0, then realm.control.frozen := 1, then 5k (Activated); the only path that sets the flag
  6. §8.3 step 6: ledger.executionSet() == finalSet.expectedExecutionSet                                                   E_EXPECTED_SET
  7. canaries, one per enabled lane, each a real publication through every write-path dependency (ingress, apply, index, stores, the Files-independent
     validator), each failure reverting the whole ceremony (E_CANARY(lane)):
       native: controller.execute(PUBLISH realm-notice/1 {kind: frozen, revision}) as the controller's contract principal — carrying a one-entry read set over
               its own UNSET head when b0 is set, so the guard codec is exercised;
       b1 / b2: ledger.executeSigned(laneCanaries[i]): intents the owner (b1) or a wallet (b2) pre-signed offline under the terminal executionSet
               (= finalSet.expectedExecutionSet, computable in advance, §8.1), each publishing a realm-notice/1 {kind: frozen} record
     every canary therefore lands only after registry.activeRevision() == finalSet.revision (entry tripwire, §6.1 step 7)
  8. ledgerAdmin.renounceOwnership(); registryAdmin.renounceOwnership()
  9. owner := 0; pendingOwner := 0; controller.frozen = true
 10. emit Frozen(revision, executionSet, admissionHigh, canaryPublications)        // a controller event (§5.12)
```

After the freeze: `ledger.activate/freeze/beginTransition/abortTransition` and every registry activation revert `E_FROZEN` (the registry reads the ledger's flag); no `reinitializer` can run (admins renounced, controller dead); writes, reads, permissionless Type registration, `backfill` of the frozen generation's BITMAP families (per-scope coverage of pre-declaration scopes), reader deployment and `ReaderDirectory` listing continue; `build` of a later family is impossible, because it needs a generation activation; `describe().frozen == true`; Realm id and proxy addresses survive. Successor evidence after the freeze is a `realm-notice/1 {kind: successor}` record authored by the principal the terminal row names as `noticePrincipal` (`w24`; `RealmNoticeRule` refuses any other author for that kind, and refuses the `frozen`/`migration` kinds from anyone but the controller's contract principal, §12.1), never a pre-wired address; a terminal set with `noticePrincipal == 0` has no successor path, which the freeze rehearsal checklist flags. A gas repricing after the freeze changes costs only: floors are satisfied by `tx.gas` (I11). If James chooses posture B (Q3), `finalSet.components.steward` names an append-only steward able to call only `activate` for a replayed index generation and the registry's three append-only activations, never an implementation change, itself renounceable; at S1 `steward == 0`.

### 8.11 Drift detection summary

| What could drift | Where detected | Cost |
|---|---|---|
| Ledger implementation vs activated | entry tripwire; per-callback `SLOAD` | 1 warm `SLOAD` |
| Ingress / apply helper code | immutable codehash vs `extcodehash` on entry | 2 `EXTCODEHASH` |
| Registry implementation | `activeRevision()` on entry; `mutations()` per callback; `implementation()` codehash at activation | 1 warm `STATICCALL` each |
| Registry policy / role / wrapper rows | `mutations()` per callback | 1 warm `STATICCALL` |
| Index / stores | cannot change while locked; attached stores accept only `ledger.index()` | 0 |
| Controller / owner / steward / controller code | components of the execution set; `migrate` scan | 0 on the write path |
| Admin slot vs actual `ProxyAdmin`; admin ownership | `activate` step 5h; `verify-deployment` opens the proxy's immutable `_admin` from runtime bytes | once per activation |

---

## 9. Type registry

### 9.1 Identity

`typeId = keccak256(abi.encode(DOM_TYPE, shape, keccak256(abi.encode(refTypes)), ruleId))` (`L/src/Keys.sol:88-90` shape), `shape = keccak256(abi.encode(DOM_DESCRIBED_SHAPE, descriptorBytes))`, `refTypes` projected from the leading REF fields. `ruleId` is **the codehash named in the descriptor header** under `bytecode_hash = "none"`: for grades 1–2 `header.wrapperCodehash` (the wrapper build the creator wrote the descriptor for), for grade 3 `header.developerRuleCodehash`. The registry verifies at registration that the pinned instance has that codehash; no Realm-local version table feeds identity, so the same descriptor derives the same id in every Realm and a relayed declaration verifies on any destination that has activated a wrapper with that codehash. The Type row also stores `grammarProfile` (grades 1–2) and the pinned wrapper `(address, version)`. **One-way door (Q1):** if James prefers grammar-profile identity, the change is which stored word feeds `Keys.typeId` **only until the first grade-1/2 Type is registered on a persistent Realm** (S3 tag tokens are grade 1); after that, switching re-ids every structural/custom Type and every Record under them. `docs/ONE-WAY-DOORS.md` lists Q1 with that deadline.

### 9.2 Descriptor header (codec `efs2/described/1`; identity-bearing; total descriptor ≤ 4,096 B)

Byte offsets: `0 codecVersion (=1)`, `1 wrapperVersion (u8; a hint for `wrappers[version]`, not identity)`, `2 grade (1 STRUCTURAL | 2 CUSTOM | 3 NATIVE)`, `3 fieldCount (0..16)`, `4 ruleMode (1 STATICCALL; 2 CALL reserved, refused until capability b4)`, `5 dependencyClass (1 pure | 2 realm-reads | 3 external-reads | 4 stateful reserved | 5 delegating reserved)` — **the creator's unverified claim**, disclosed as such in `SECURITY.md` and the SDK (the prototype refused a self-declared "stateless" flag for this reason, `L/src/TypeRegistry.sol:33-43`; this design keeps the field as disclosure, never as proof), `6 refProjectionProfile (1 leading words; 2 reserved)`, `7 textProfile (1 ASCII; 2 UTF-8 reserved for codec 2)`, `8..10 validationGas u24 (0 = ACCEPTOR_GAS_DEFAULT 300,000, a closure constant; the declared **minimum** the rule needs, never a cap)`, `11 indexSpecCount (0 in codec 1)`, `12 sectionCount (0 in codec 1)`, `13 nameLength`, `14..33 declarationKey (address)`, `34..65 namespace`, `66..97 ruleCodehash (grade 1–2: wrapper codehash | grade 3: developerRuleCodehash)`, `98..129 customHash (grade 2) | ruleInitcodeHash (grade 3) | 0`, `130..131 descriptionLength`, `132 refHeaderWords (1..3)`, `133 reserved (0)`, then name bytes, description bytes, `fieldCount × 164`-byte field rows exactly as the prototype's WIRE.md grammar (kinds 1–8), then `indexSpecCount × 64`-byte index specs (codec 2), then extension sections (none in codec 1). Refusals (`E_CODEC(offset, code)`): unknown `codecVersion`, `grade`, `ruleMode ≠ 1`, `dependencyClass ∉ {1,2,3}`, `refProjectionProfile ≠ 1`, `textProfile ≠ 1`, `indexSpecCount ≠ 0`, `sectionCount ≠ 0`, `refHeaderWords ∉ 1..3`, byte 133 ≠ 0, **total length > 4,096 or < 134** (the measured prototype cap, `L/src/DescribedTypeProfile.sol:25`; negative vector at 4,097; both the registry and the wrapper refuse). `refTypes` sentinels: `0 = ANY`, `1 = SELF`, `2..0xFF` and `0x0100..0x01FF` reserved, `≥ 2^16` exact ids; only `0`, `1` and exact ids are accepted in codec 1 (`E_REF(leaf, i, 4)`); sentinel values in body words are refused (`E_REF(leaf, i, 3)`). The first Files Name Type is native-grade (`files-name/2`, measured 1,477 B), so codec 1 needs no UTF-8 kind for M1. Repricing exposure: `validationGas` is a floor, so a fork that reprices reads makes tightly declared Types cost more, never unpublishable (recorded in `ONE-WAY-DOORS.md`).

### 9.3 Registration (permissionless, atomic, idempotent)

- `retainDeclaration(descriptor, declarationSig)`: derives `typeId`; verifies the creator's EIP-712 declaration signature under the chain-free domain `(name = "EFS Type Declaration", version = "1")` over `(DECLARATION_DOMAIN, typeId)` (ERC-1271 declarations for Safe creators are a later profile, Q6); the blob must already exist at `DescriptorStore.predict(descriptor, sig)` with `extcodehash == keccak(0x00 ‖ descriptor ‖ sig)` (`E_BLOB`); writes the declaration row; retention never installs.
- `registerDescribed(descriptor, declarationSig, nativeOrCustom, bindingSig)`: as above, then by grade — **STRUCTURAL**: `wrappers[header.wrapperVersion].codehash == header.ruleCodehash` (`E_WRAPPER`), `mandatory = that wrapper`; **CUSTOM**: as STRUCTURAL for the wrapper, plus `nativeOrCustom` has real code and `codehash == customHash` (designators refused, `E_DESIGNATOR`), the creator's binding signature over `(BINDING_DOMAIN, "efs2/described-binding/1", wrapperCodehash, chainid, registry, typeId, custom, customHash, customAbi, key)`, `bindingId = keccak(preimage)` stored with `custom`; **NATIVE**: `nativeOrCustom == address(uint160(uint256(keccak256(abi.encodePacked(0xff, FACTORY, bytes32(0), header.ruleInitcodeHash)))))` (`E_INSTANCE(expected, have)`), real code, `codehash == header.ruleCodehash`, `mandatory = nativeOrCustom`. The deterministic instance means every chain has exactly one admissible instance per grade-3 descriptor, its constructor state is pinned by the initcode hash, a lookalike instance with the same runtime but different state cannot be bound, and a front-run of the deployer is an identical registration (idempotent). Then the Type row, `refTypes`, `catalog[++catalogCount]`, no `mutations` bump. Identical descriptor + identical binding → idempotent return; any divergence → `E_BINDING`/`E_TYPE_EXISTS`. What NATIVE pinning does **not** prove: that a rule with `dependencyClass ≥ 2` behaves the same tomorrow; a proxied rule (its proxy is the deterministic instance) remains behaviour-mutable by its admin, exactly as the declared class discloses (PTA: "a top-level codehash alone is insufficient for proxies or mutable dependencies").

### 9.4 Activations and role expectations (controller; idle-gated; append-only; recorded per admission)

`activatePolicy(typeId, acceptor)`: `acceptor == 0` appends a no-policy row (row 1 is implicit); otherwise `requireRealCode` and `requirePlainRuntime` (`E_DESIGNATOR`/`E_CODE_SHAPE`), then append `policy.row[typeId][++policyRows] = (acceptor, codehash, activatedAt, mutations + 1)`; rewrites the header's `policyRows` and the control word's `mutations` (two rewrites, §14). The hot path calls the policy only when the active row's acceptor is nonzero and always records the row. `declareRoleExpectation(purpose, role, expectedType)` appends `roles.row[roleKey][++count]`. `activateWrapper(version, implementation)`: `requireRealCode`, `requirePlainRuntime`, reads `IDescribedWrapper(implementation).codecVersion()` and `.grammarProfile()` (pure constants of the wrapper build, so the controller cannot invent them), appends `wrappers[version]`; old Types keep theirs forever. `typeInfo(typeId)` is the only registry read on the publish hot path (plus `refTypes` when `refCount > 0` and `roleExpectation` on binds).

### 9.5 Evolution law (NatSpec + tests)

(i) new codec ⇒ new wrapper build ⇒ new Type ids; old wrappers stay deployed; (ii) any validity change ⇒ new Type (so no Realm limit may enter validity: the acceptor gas floor is a closure constant or the Type's own declaration, never a Realm field); (iii) profile upgrade = register new Types + activate `RefuseAllPolicy` (an explicit refusing contract shipped in `profiles/`, never `address(0)`) on old Types + a supersession Record + readers accepting several exact Types; (iv) a registry implementation upgrade never touches `types`, `refTypes`, `policy`, `roles`, `bindings`, `wrappers`, `catalog`; (v) `IAcceptor/2` and `ILedgerHot` are frozen with selector-and-return-layout snapshot tests; (vi) Types-as-Records is a later profile convention over the registry id.

---

## 10. Required index

### 10.1 Generation = immutable dispatcher over per-Realm family stores

`RealmIndex` has no admin, no `declareOptional`, no `bumpGeneration`, no `setIndexModule`. Its constructor takes `(ledger, layoutId, decoder, postingStores[], bitmapStore, build, buildCodehash, manifestInputs)` and freezes the family table (each family naming its shape and store), the digest-spec table, the unit list, the work model and the physical/callback profile ids; `manifestHash()` folds all of it and excludes progress and deployment time. **Storage belongs to the Realm, not the generation:** `PostingStore` and `BitmapStore` are immutable per-Realm contracts, and an attached store accepts writes only from `ILedgerHot(LEDGER).index()` (§4.6). A new generation re-pins unchanged stores by codehash (their postings survive), **adds a fresh store for any new family set** (its `FAMILY_IDS` fixed at construction, its `INITIAL_WRITER` the new generation) and builds only its new families into that store before attachment. Full replay into fresh stores is the heal path for a corrupted store and the freeze rehearsal, never the lever for adding a family (decision 10 is now true). The generation number is the ledger revision that activated it; idle checks read `ledger.phase()`. **No address cycle:** `IndexBuild` holds no generation address — it is a codehash-pinned delegate the generation `DELEGATECALL`s, so it writes `efs.index.v2.gen.*` and calls the stores *as* the generation; the genesis stores take `INITIAL_WRITER = 0` and need no generation address; a later generation that needs fresh stores is created together with them by a single-use `IndexDeployer` (CREATE2; the `RealmGenesis` pattern): its `run()` creates each fresh store by its own nonces with `INITIAL_WRITER` = the nonce-predicted generation address, then the generation with the stores' addresses, asserts the prediction and journals; a generation that only re-pins stores is a plain CREATE2. The generation (live, or as a fresh store's `INITIAL_WRITER` before attachment) is the only writer a store accepts, authorized through `ledger.index()`, the constructor immutable and the store's `writers` history.

### 10.2 Families (generation 1; family ids `keccak("efs2/family/<name>/1")`; names as listed)

| Kind | Family (`<name>`) | Key | Entry | Universe | Shape / store | Fresh-slot shape | Note |
|---|---|---|---|---|---|---|---|
| 1 | `by-type` | `(T,1,0,0)` | admission of each PUBLISH/REUSE | TYPE | APPEND / Posting | head once per Type, 0.2/append | ruled |
| 4 | `by-author` | `(0,4,0,principal)` | same | PRINCIPAL | APPEND / Posting | head once per author | ruled |
| 5 | `backlink` | `(0,5,0,target)` | bind admissions; entry word = `admission u48 ‖ roleTag u16`; `live` = current heads | TARGET | APPEND / Posting | 1 fresh per distinct target | ruled; REBIND/MASK release `oldTarget`'s live count from `Effect.oldTarget` |
| 8 | `history` | `(0,8,0,bindingKey)` | every bind-kind admission on the key | SCOPE | APPEND / Posting | 1 fresh per fresh binding | ruled; `prevAdmission` chains accelerate point reads |
| 10 | `scope` | `ScopeKey` | binding-key ordinals, appended on UNSET transitions (K10); entry 0 inline in the scope head | SCOPE | APPEND / **Bitmap** (the scope list lives beside its bitmaps, so one store `CALL` per FIRST_BIND appends, sets the live bit and stamps `lastMutation`) | 1 fresh per new scope (its head); 0.2 per further entry | genesis obligation |
| 11 | `reference-position` | `(T,11,ordinal,target)` | first admission of the source record; targets from the `refs` array | TYPE | APPEND / Posting | 1 fresh per distinct `(T, ordinal, target)` | no body reads |
| 12 | `by-record` | `(0,12,0,recordId)` | PUBLISH/REUSE admissions | GLOBAL | APPEND / Posting, **virtual until the second occurrence** | −1 fresh per fresh record | read only through `occurrencesOf`/`postingHeadOf` (synthesis: `count == 0 && cell.firstAdmission != 0 ⇒ [cell.firstAdmission]`, `live = cell.occurrences`, valid only when coverage is genesis-`COMPLETE` and `phase == IDLE`, else `PARTIAL`) |
| 13 | `unique-by-type` | `(T,13,0,0)` | first admission of each retained record (`freshRecord`) | TYPE | APPEND / Posting | head once per Type | ruled |
| 14 | `scalar` | descriptor-declared specs | first admission | TYPE | APPEND / Posting | 1 fresh per distinct value | codec 2; zero at S1 |
| 15 | `digest` | `(0,15,alg,digest)` | first admission; value = body word `spec.wordIndex` of a Type in the manifest's `DigestSpec[]` (gen 1: `files-content/1`, word 5, sha256) | GLOBAL | APPEND / Posting | 1 fresh per distinct digest + 1 cold `SLOAD` per spec'd record | ruled (`OR:63`); `coverageOfDigest(alg)` is `UNKNOWN` for undeclared algorithms; gen 1 declares two specs (`files-content/1` and `files-external/1`, both word 5); a spec added by a later generation rebuilds the family ascending into a fresh store (§10.6) |
| 16 | `role-scope` | `roleScopeKey(principal, purpose, role)` | binding ordinals, appended once per fresh coordinate | SCOPE | APPEND / Posting | 1 fresh per fresh coordinate | the generic tag inverse; from genesis |
| 17 | `roster` | `(principal, directory)` | reserved | SCOPE | BITMAP / Bitmap | — | `NOT_MAINTAINED`; CURRENT_STATE semantics; declared by a later generation, hooked at its declaration ordinal, backfilled per scope from current heads (§10.6) |
| 18 | `live-scope` | `ScopeKey` → bits over scope entries | bit set on FIRST_BIND/RESTORE, cleared on MASK/RELEASE; `lastMutation` stamped on every bind-kind transition incl. REBIND | SCOPE | BITMAP / Bitmap | 0 for ≤ 48 entries; 1 per 256 beyond | §4.6; CURRENT_STATE; a genesis family, never backfilled |

Kinds 2, 3, 6, 7, 9 keep the prototype's numbering reserved. Posting entries of APPEND families are admission ordinals (binding ordinals for 10/16) in strictly increasing order (CQ-1; `_append` reverts `E_ORDER` on `ordinal ≤ last`, `L/src/IndexModule.sol:499`). `liveSemantics` per family is a manifest field (§5.11: OCCURRENCE families release on withdraw, HEADS families track current heads, RETAINED families never release; BITMAP families are MONOTONE or CURRENT_STATE, which decides how they are backfilled, §10.6).

### 10.3 Callback protocol (`Effect/3`)

Per effect: `onAdmission(publication, Effect[1], refsSlice)` by `CALL` from ledger context through `LedgerIngress.dispatchIndex` (selector prepended; the call receives all available gas above the final reserve and kernel tail, §6.4; 4,096-byte returndata bound before copy; a failure with returndata is nested in `E_INDEX_CALL`, with empty returndata is `E_INDEX_GAS`); the index checks `msg.sender == ledger`, contiguity against `counts()` (`E_ORDER`), `publication == stagedPublication` (`E_STAGED`). Final: `afterPublication(publication, Effect[n], refs)` by `STATICCALL`, exact 32-byte selector ack. The generic core folds the families of §10.2 from the `Effect/3` fields and the `refs` slice alone, plus one body-word read per matching digest spec (priced in the work model); it never reads heads, positions or admission rows. Then it iterates the unit list: each `foldHook` whose `purposeFilter` matches (or is zero) gets a bounded `CALL`; at the final phase each `finalHook` gets a bounded `STATICCALL` and must echo its selector. An ordinary record write pays no hook calls. A new action kind or a new `Effect` field is a new callback profile and a new generation (IX-15).

### 10.4 Work model: a slot-count quote converted to an availability floor

`WorkModel` (§5.11) is a manifest field expressed in **slot counts and compute**, never in gas tied to one schedule. The ingress computes, per publication, `freshSlots = freshPerPublication + Σ_publish(freshRecord ? freshPerPublishFresh : 0) + Σ_bind(freshBinding ? freshPerBindFresh : 0) + Σ refs·freshPerRef + Σ specs·freshPerDigestSpec`, `rewrites` likewise, `compute = computeBase + n·computePerAction + matchingEffects·computePerHookEffect`, and converts: `prefixFloor = compute + freshSlots·limits.floorFreshGas + rewrites·limits.floorRewriteGas`, `finalReserve = finalComputeBase + binds·finalComputePerBind`. The floor is what the dispatcher **demands to be available** before each callback (§6.4) and what the SDK uses for `eth_estimateGas` sanity; it is never a post-call cap (I11; `E_ALLOWANCE` does not exist). The conversion constants live in `Limits` (activation-set, recorded in the revision row), so a schedule change is absorbed by an activation before freeze and, after freeze, only shifts the pre-call floor: a floor that is too low lets a callback run out of gas (`E_INDEX_GAS`, resubmit with more gas), a floor that is too high is satisfied by attaching more gas up to the execution cap; neither refuses a class of writes permanently. Whether EIP-8037's state-gas reservoir is visible to `GAS` is unverified; the C1 row runs every M1 recipe on `amsterdam` with `tx.gas` below and above 2^24 and must admit both, and picks `floor*` values that do. Initial coefficients to be measured at C1 (slot counts from §14's model): `freshPerPublication 0.2 (progress), rwPerPublication 1, freshPerPublishFresh 1 (unique/reference heads amortized), rwPerPublish 5, freshPerBindFresh 3, rwPerBind 4, freshPerRef 1, freshPerDigestSpec 1, computeBase 60k, computePerAction 25k, computePerHookEffect 60k, finalComputeBase 60k, finalComputePerBind 120k` (fractional counts are stored ×10). A new extension cannot change admission economics without changing `manifestHash`, hence `indexObligations`, hence every signed plan's commitment.

### 10.5 Coverage, frontiers, readiness

`coverage(family, scope) → (Coverage, from, through, phase)`: for APPEND families and genesis BITMAP families `(provenFrom, lastProcessed)`, where inside a publication `through` is the staged frontier and `phase ≠ IDLE` marks prefix-`COMPLETE` (ruling 21; the EquipmentRule pattern of `L/test/CoreOrderedAcceptance.t.sol:19-36` is ported); for later BITMAP families the per-scope coverage slot when the scope predates the declaration ordinal `d`, else `COMPLETE` from `d` by construction; `coverageOfType` for Type-universe families (a nonzero scope must be a registered Type, else `UNKNOWN`); `coverageOfSpec`/`coverageOfDigest` `UNKNOWN` for undeclared specs and algorithms; `UNKNOWN` for undeclared families, unregistered Types, `NOT_MAINTAINED`; `COMPLETE` only when `from == 1`, `through == admissions` and not gapped. `replayReadiness()` returns the versioned tuple with families, stores, units and the build contract — no `attachedRevision`, no `FILES_SPLIT` special case; its `ready` flag is the predicate `phase == IDLE ∧ completedAdmission == counts().admissions ∧ completedPublication == counts().publications ∧ every APPEND family from == 1 ∧ every store's writers ranges contiguous ∧ every manifest family in its store's FAMILY_IDS`, and `checkActivation` re-derives it from the tuple and the stores rather than trusting the flag (§8.3 step 5h).

### 10.6 Replay, build and backfill (by family shape)

`RealmIndex.replayNextPublication(maxFacts ≤ 64)` (a `DELEGATECALL` into the pinned `IndexBuild`, running in the generation's context): permissionless, idle-gated, allowed only for a generation whose stores are fresh (`INITIAL_WRITER == this`, `!attached`); decodes each publication through the pinned per-layout `IndexReplayDecoder`, which validates the evidence cell's `revision` against `revisions[n]` (`ledgerImplCodehash`, `layoutId`, `indexManifestHash` of that era) and rebuilds `Effect/3` from admission rows: `oldTarget`/`oldTargetKind` from the previous bind row named by `prevAdmission` (its `a` and `targetKind`), `freshRecord` from `cell.firstAdmission == admission`, withdrawals from the `withdrawn` bit, refs from the leading body words of the Type's `refCount`. **Tolerance rule (part of the callback profile):** during replay, final hooks re-validate a publication only when the revision row in force at that publication names a manifest whose unit list contains the same `finalCodehash`; every other publication is folded on its recorded obligations and never re-judged; fold hooks must be total over any admitted history; final hooks may read only write-once facts (record, subject and position cells, admission rows), enforced by a lint on `profiles/` and a replay-equals-live fuzz. A stricter later validator therefore never stalls readiness; it governs admissions after its own activation.

`build(familyId, maxFacts)`: for a later APPEND family, walks admissions ascending from 1 into the family's fresh (unattached) store, so entries stay strictly increasing; activation requires `from == 1`. A `DigestSpec` added by a later generation is the same operation on family 15: the family is rebuilt ascending into a fresh store with every spec, old and new, folded in one walk — a GLOBAL key may already hold earlier admissions, so a new spec's entries cannot be appended to the attached store without breaking the order law; the cost is family 15's posting count at the fresh-slot price (estimate), and `coverageOfSpec` reports the build frontier until attachment. `backfill(familyId, scope, expectedThrough, maxEntries)`: for a BITMAP family hooked from `d`, walks the scope's entries in `[through, liveFrom)` of that scope's coverage slot, advancing `through`; a scope born after `d` has no slot and no cost; retirement (`retiredAt`) freezes coverage and never clears words. **Backfill derives bits by the family's `liveSemantics`, so both interleavings are correct:** a MONOTONE family ORs bits derived from write-once rows (never from calldata); a CURRENT_STATE family derives each pre-`d` entry's bit from the *current* head (`ILedgerHot.head`, canonical-target rule) at backfill time, never from the historical BIND row — an entry masked after `d` but before backfill, which the live hook could not clear because no bit existed yet, therefore stays clear, and an entry masked after backfill is cleared by the hook; backfill and live writes are serialized by the `IDLE` gate. Both interleavings (mask-before-backfill, mask-after-backfill) are named tests in §16.3. Whole-generation fresh replay (≈ 110k per re-materialized posting under EIP-8037) remains the heal path. A gap is terminal for a store and healed only by a replayed store (R12/R13).

### 10.7 Physical composition and the honest-coverage law

Generic core + a constructor-fixed list of codehash-pinned units `{foldHook, finalHook, familyIds[], purposeFilter, hotAbiId, identity}`; no inheritance across units; split trigger: any unit over 17.5 KB. Generation 1 ships one unit, `FilesFinalValidator` (`purposeFilter = FOLDER`, no fold hook), plus the Files digest spec in the manifest. A later family reports `PARTIAL` (APPEND, during build) or per-scope coverage (BITMAP) until proven. The manifest is reproducible off-chain from `profiles/index.json`.

---

## 11. Readers and Lens

`LensReader/1` (immutable, stateless, listed in `ReaderDirectory` and `release.json`) keeps the prototype's measured flat-ordered semantics for M1 — ordered first-touch wins, mask beats fall-through, release falls through, no-tiebreak returns all live candidates and reports `CONFLICT`, `UNKNOWN` never falls through — implemented over one `LedgerViews.headsAt` call per position for up to 64 principals. It resolves `index()` from the ledger per call and supports the profiles it lists. Principal-id APIs only; cursors are data bound to a `BasisCommit` and `queryHash`; a stale basis returns `BASIS_STALE`; continuation at an older origin is allowed when every selected scope's `lastMutation ≤ origin` (checked over the full selector list including consumed, empty and terminal scopes, CQ-9) — and because `lastMutation` moves on REBIND and RESTORE too, a rebind between pages refuses relaxed continuation; the strict law (`observedCurrent == origin`) is a caller flag. `resolveRecord` returns the selected head's record header and body in one call. `PlanV1` tiers are a later reader over the same `headsAt`.

`FilesPageReader/1`: candidates from `liveWords` over the scope list (stable order), masks from higher principals via `headsAt`, rows carry only the masked fields (`F_HEADER` fills `headRecord`/`headRevision`/`headerWord0` from the file's HEAD so a subsequent `record()` is one call), name bytes via `bodySlice`, `gasReserve` early stop returning `PARTIAL` + continuation, the `DirectoryPage` flags of §5.13 (`startsAtOrigin`, `completeFromOrigin`, `selectedSoFar`, `inventoryPin`, `scanStatus`), `listingCoverage` = the listing's; a terminal page from a continuation is never `COMPLETE`. Paid multi-transaction completeness is `lib/QueryAccumulator.sol` (owned accumulators; Q14). Every reader is run through the `FaultyReads` port (22 fault modes).

---

## 12. Files profile and the first-milestone cut

### 12.1 Types (all described, permissionless; native-grade rules from `profiles/`, deterministic instances)

| Type | Grade | Body | Refs (`refHeaderWords`) | Mandatory rule (reads only `ILedgerHot(ctx.ledger)` + `refHeaders`) |
|---|---|---|---|---|
| `files-root/1` | NATIVE | `abi.encode(fileSubject) ‖ document` (≥ 32 B) | none | `FilesRootRule` (ported from `L/test/FilesJoinedProfile.sol:31`): `refs == 0`, `file != 0`, `subjectCreatedAt(file) != 0` |
| `files-child/1` | NATIVE | `abi.encode(parentRecord, fileSubject) ‖ document` (≥ 64 B) | `[0 = ANY]` (2) | `FilesChildRule` (ported from `L/test/FilesJoinedProfile.sol:39`): `parent == refs[0]`; from `refHeaders[0]`: root → `length ≥ 32 && word0 == file`; child → `length ≥ 64 && word1 == file`; never loads the parent body |
| `files-directory/1` | NATIVE | `abi.encode(seedSubject)` | none | `FilesDirectoryRule` (ported from `L/test/FilesDirectoryProfile.sol:32`): `subjectCreatedAt(seed) ≤ ctx.admission` and nonzero |
| `files-name/2` | NATIVE | raw UTF-8, 1–255 B, well-formed, byte-exact, case-sensitive, `~efs` reserved | none | the measured 1,477-byte validator (naming reconciliation `planning/Reviews/2026-09-26-efs-v2-naming-reconciliation/README.md:15, :76`, experiment `NameV2F`, 4–14k gas for ordinary names; the prototype's ASCII `FilesNameRule` at `L/test/FilesNamesProfile.sol:73` is the structural analog); pending N1/N2 (Q7) |
| `files-bytes/1` | NATIVE | `sha256(payload) ‖ payload` | none | `FilesBytesRule` (ported from `L/test/FilesCarrierProfile.sol:15`): hashes calldata once |
| `files-content/1` | NATIVE | 11 words `[bytesRef, version, carrier, hashAlg, length, sha256, media(2), cipher, nonce12, plaintextLength, plaintextSHA256OrZero]` | `[files-bytes/1]` (3) | `FilesContentRule` as measured (`L/test/FilesCarrierProfile.sol:22`); word 5 feeds the digest family |
| `files-external/1` | NATIVE | 7 words `[bytesRef, version (= 2), carrier (2 ar \| 3 ipfs), hashAlg (1 sha256), length (≤ 2^24), sha256, locatorLength]` ‖ ASCII locator (`ar://` + 43 base64url chars; `ipfs://` CIDv0 `Qm…` or CIDv1 base32) | `[files-bytes/1]` (1) | `FilesExternalContentRule`: `refs[0]` is the empty-sentinel bytes record (`refHeaders[0]`: `length == 32 && word0 == sha256("")`), locator grammar as the prototype's (`L/test/FilesExternalContentProfile.sol:11-40`), no remote proof at admission; word 5 feeds the digest family through the second gen-1 `DigestSpec` |
| `directory-alias/1` | NATIVE | `abi.encode(targetObjectId, kind)` | none | id-targeted alias |
| `realm-notice/1` | NATIVE | `abi.encode(kind, revision, note)` | none | `RealmNoticeRule`: `kind ∈ {frozen, successor, migration}`; `frozen`/`migration` require `ctx.principalId == Keys.contractPrincipal(realmOrigin(), controller())`, `successor` requires `ctx.principalId == noticePrincipal() != 0` (all hot reads on `ctx.ledger`); the freeze canaries and the only successor evidence |

Purposes `HEAD`, `FOLDER`, `TAG` are closure constants. No role expectation rows exist at genesis: a `→ ANY` row is the same as no row, and `roleKey = keccak(DOM_ROLE_KEY, purpose, role)` cannot express a wildcard. FOLDER target validity is enforced by `FilesFinalValidator`; HEAD target validity (the target is a `files-root/1` or `files-child/1` record whose file word is the HEAD's subject) is enforced reader-side — `FilesPageReader` and `LensReader.resolveRecord` report such a head `INVALID` — because the gen-1 validator's `purposeFilter` is FOLDER. Directories are records derived from CREATE subjects; placement validity is a final-hook check; names are a profile obligation enforced by `FilesFinalValidator` on every FOLDER bind, signed or native.

### 12.2 Operations as action sequences (the measured recipes)

- **Root (the seed, once per Realm):** `CREATE(rootSalt)`, `PUBLISH(files-directory/1, rootSubject)` by the fixture principal; the root has no FOLDER bind (no parent); `efs-deployment/1.root` and `expected.json` record `{directoryRecordId, subjectId, principalId}` (§13), which is how the SDK and the static client find it.
- **Create folder:** `CREATE(salt)`, `PUBLISH(files-directory/1)`, `PUBLISH(files-name/2, name)` if absent, `BIND(FOLDER, parent, keccak(name) → directoryRecordId, exp 0)`.
- **Create file:** `CREATE(salt)`, `PUBLISH(files-root/1, …)`, `PUBLISH(files-name/2, name)` if absent, `BIND(HEAD, file, 0 → root, exp 0)`, `BIND(FOLDER, folder, keccak(name) → file, exp own)`.
- **Edit:** `PUBLISH(files-child/1, …)`, `BIND(HEAD, file, 0 → child, exp current)`.
- **Rename / move:** `PUBLISH(name)?`, `UNBIND(FOLDER, old, oldName, exp)`, `BIND(FOLDER, new, newName → file, exp)`: atomic by the rollback law.
- **Remove:** `UNBIND`. **Restore:** `BIND` (the kept target word makes a same-target restore a rewrite). **Stop claiming:** `RELEASE`.
- **Staged save:** one publication of ≤ `maxActions` leaves with CAS per head; the M1 supported maximum is published in `limits` after C1 — estimate ≈ 20 edits (≈ 8.3M today for the batch, ≈ 0.40M marginal per edit after the first, since the per-publication overhead inside the single-edit row's ≈ 0.76M is paid once; §14) or ≈ 9 file creates per publication, conservative against the 2^24 execution cap; larger saves are split by the SDK and **labelled non-atomic**; stage-then-commit (kinds 8/9, capability b9) is reserved for a later kernel upgrade.

`FilesFinalValidator` (gen 1, `purposeFilter = FOLDER`): for every FOLDER bind, a valid `files-name/2` record whose id is `recordFromHash(nameType, role)` is admitted at or before the terminal admission, the parent is a validated directory record, the target (`Effect.target`/`targetKind`) is a file subject or directory record, no self-link; it reads only `recordHeader`/`subjectCreatedAt` on the ledger and the effects (write-once facts).

### 12.3 The PM's first milestone, mapped, with acceptance rows

| Step | Contracts deliverable | Acceptance row (seeded fixture, measured into `gas/report.json`) |
|---|---|---|
| deploy locally | genesis plan (§8.2), `efs-deployment/1`, `efs-fixture.mjs up/verify/down` | `verify` reproduces every address, runtime hash and `describe()` field; a second `run()` reverts |
| cold pin | `LedgerReads.describe(ledger)` | ≤ 9 logical calls on the first pin of a release digest, ≤ 2 HTTP envelopes (`eth_chainId`, `eth_getBlockByNumber`, `describe`, `eth_getStorageAt(proxy, impl slot)`, five `eth_getCode`: impl, reads, views, the two readers); ≤ 4 on later pins, the code hashes being cached per release digest |
| create folder + small file | native `execute` from an EOA with **both expectations bound** (`EfsNative.currentBind`), recipes above, inline body | gas rows §14 on both schedules; `E_CAS` leaves the digest unchanged; a `activatePolicy` on a plan Type between preparation and landing → `E_ACCEPTANCE_PROFILE`, nonce intact |
| read verified contents | `FilesPageReader.listDirectory` (`listingCoverage COMPLETE` on an origin-started exhausted scan); `LedgerReads.record` + `bodySlice`; `LensReader.resolveRecord` | 1 call per directory page; 1 call per file read after a page (2 dependent calls cold) |
| update | edit recipe with CAS on HEAD | stale plan refused whole; nonce intact |
| reload and recover | `publicationAt` at a finalized block hash + `LedgerViews.publication` | `COMMITTED` in 2 calls; lost response classified in 2 calls (`publicationAt`, header) as `COMMITTED` / `NOT_COMMITTED_PROVEN` / `UNKNOWN`; exact retry after an activation, a policy activation, an index replacement and after the deadline → `AlreadyAdmitted` |
| tiny external Solidity consumer | `examples/NativeApp.sol`: registers a NATIVE Type at its deterministic instance, publishes, binds, reads back, reverts its own state on `E_REJECTED` | atomicity both directions; forwarding writer becomes the author; proxy-hosted app; two composing apps |
| then: AR/IPFS reference | `files-external/1` (§12.1; S1b, inside C2) with its gen-1 `DigestSpec` | 1 call per descriptor read; `coverageOfDigest(sha256)` `COMPLETE`; `occurrencesOf`/digest lookup finds the file by sha256 whether its bytes are inline (`files-content/1`) or external |
| two-author Lens fallback | `LensReader` ordered principals | `headsAt` 64 principals in one call |
| tags | **deferred to S3, outside C2:** the concept Type (D-B folding), the stance carrier (D-C) and a tag family shape priced against D-E are not designed here (Q32) | — |
| populated upgrade (behavior 5) | the C2 subset of §16.4 | seed the Files fixture; activate a new `LedgerCore` with a new ingress/apply pin; the `StateDigest` outside the migration scope is unchanged; directory and file reads are identical through both readers before and after; a bound stale plan is refused with its nonce intact; a new write lands; the pre-upgrade publication retried → `AlreadyAdmitted` |
| large directory | `FilesPageReader.listDirectory` over a 1,000-entry filtered folder | pages, calls, gas per page and returndata bytes recorded as a regression bound (the prototype needed 199 calls); cold versus warm |
| root and home | the seed root (§12.2), `efs-deployment/1.root`, `defaultLensPrincipals` | a cold client lists the root `COMPLETE` from the manifest alone, with no prompt |
| staged save | one publication of ≤ the published maximum | joint envelope executed at the 2^24 cap on both schedules |

### 12.4 Deferred from M1 and why

Signed lanes and guards (S2); ERC-1271 (S2b); tags (S3: the concept Type, the stance carrier and the D-E budget, Q32); `PlanV1` tiers; stateful rules (b4); import (S4); codec-2 specs; `ROSTER` writes; `BodyStore`; stage-then-commit (b9); substring search; the lease library and the six-command fixture CLI. AR/IPFS references are **not** deferred: `files-external/1` is an S1b Type.

---

## 13. Release, fixture and deployment surface the SDK consumes

- **`release.json`** (`efs-contracts-release/1`): schema, version, source commit + tree hash + standard-JSON input hash, toolchain pins **including `bytecode_hash = "none"`**, a `BuildPlatformDescriptor` and the reproducible-build attestation (the two clean-rebuild hash sets of §16.6), `files{path → sha256}`, per contract `{runtimeHash, deployedBytecodeHash, initcodeHash, immutableReferences (must be empty for every `profiles/` contract), sizes, budget, dependencyClass}`, `profiles{typeIds with shape preimages and descriptor bytes, ruleIds, instance addresses (deterministic), acceptor codehashes, wrapper versions and codehashes, index manifest + hash + work model + digest specs, families with store addresses, limits, layoutId, hotAbiId, statusVocabularyId}`, `consumer{pragmaFloor, tested solc×EVM, remapping}`, `privilegedRoles`, `errors{selector → name, args, meaning, retryClass}`, `dependencyRoot` (the write-path closure the freeze checklist enumerates). Digest = `sha256(release.json)`.
- **`artifacts/<Name>.json`**: ABI incl. errors/events (the union of kernel + apply + ingress fragments), bytecode, immutable refs, storage and transient layouts, method identifiers.
- **`interfaces/` + `lib/`**: the consumer closure, `examples/NativeApp.sol`, `lib/QueryAccumulator.sol`; `profiles/FilesTypes.sol` generated.
- **`vectors/`**: `ids.json` (every `Keys` derivation at a fixed mock address, every domain string, every family name and id), `layout.json`, `intent.json` (S2), `native-intent.json` (digest preimages incl. bound and unbound cases and the recovery classifier cases), `effects.json` (an `Effect/3` with every field nonzero, its ABI encoding and `effectsHash`), `names.json`, `described-v1.json` (incl. the 4,097-byte negative), `execution-set.json`, `manifest.json`, `hot-abi.json`, one matched rollback control with exact error bytes. Generated by a forge script and checked by a pinned Node verifier that imports no contract code.
- **`deploy/plan.json`**: ordered steps, CREATE2 factory + salts, `RealmGenesis` initcode hash and nonce-derived addresses, post-checks; the deployer journals and resumes idempotently.
- **`fixture/`**: seed version; the fixture principal (an EOA key published with the fixture; a sealed code-governed seed principal is Q29); pre-encoded seed transactions — the root `CREATE` + `files-directory/1`, then the sample folder and file — produced by a forge script using `EfsNative`/`EfsFiles`; `expected.json` (incl. `root`); `EfsFixture.sol`; `efs-fixture.mjs up / verify / down` with `--chain-id --realm-salt --state-dir --hardfork`; `Multicall3` etched; only owned `--anvil` runs.
- **`efs-deployment/1`** manifest: release digest, chain id, `realmId`/`realmOrigin`/`realmSalt`, factory, genesis address and nonces, every address with runtime hash, proxy implementation + actual `ProxyAdmin` + `owner()` + immutable-reference offsets, initializer data, tx/block hashes, execution set + revision, index manifest + generation + stores, capabilities, limits, `noticePrincipal`, privileged roles, readers listed, seed version, `root {directoryRecordId, subjectId, principalId}`, `defaultLensPrincipals[]`, actor addresses, RPC hints, evidence grade.
- **`gas/report.json`**: per supported operation on both hardforks: gas, `gasStateUsed`, fresh / rewritten / cleared slots, code bytes deployed, accounts created, with `tx.gas` below and above 2^24 on `amsterdam`, plus, per read, RPC-call counts, returndata bytes and cold-versus-warm gas (first call in a block versus repeated) for cold pin, page, file read, confirm, recovery and the 1,000-entry traversal.
- **`docs/`**: `ONE-WAY-DOORS.md` (every preimage, domain, layout id, hot-ABI id, codec cap, the Q1 deadline, the validationGas repricing exposure), `STORAGE.md` (incl. the reinitializer offset), `EVOLUTION.md` (§19), `RECOVERY.md` (§6.6), `SECURITY.md` (residuals: administrator power before freeze, declared dependency classes, relayer gas exposure, log-only retention portability).

---

## 14. Gas table (per operation; today = Prague; Glamsterdam = EIP-8037/8038)

Method: the slot model of `AN/followup-6.md` Part B applied to this design's rows, regenerated for this revision (the committed `tools/gasmodel/` script reproduces every row from the §4 layouts and the §10.2 family shapes). Pricing: fresh slot 22,100 → 110,020; cold rewrite 5,000 → 12,100; clear 5,000 − 4,800 refund → 12,100 − 11,616 (refunds capped at 20 % and ignored for block accounting, EIP-7778); code 200 → 1,530/byte + 183,600 per new account; cold `SLOAD` 2,100 unchanged; cold account 2,600 → 3,000; compute unchanged. Index maintenance per steady append = 0.2 fresh + 1.8 rewrites (`AN/followup-6.md` §B.3). "Non-state" is the measured prototype receipt minus its state estimate carried unchanged, plus the proxy hop (+5k), the apply delegate (+1.5k per leaf), the live checks (+5k incl. `activeRevision`) minus the transient lock (−2k). Conditions: "steady" = the author has published before, the Type has records, the folder scope exists. All v2 figures are **estimates**; C1 measures them, and the C1 gate is the slot counts, not "±10k of the prototype".

| Operation | Fresh | Rewrites (clears) | Code | v2 today (est.) | Prototype measured | v2 EIP-8037/8038 (est.) |
|---|---:|---:|---:|---:|---:|---:|
| Native 1-leaf PUBLISH, 41 B (2 words), steady (kernel 12 fresh; index 0.6 fresh + 5.4 rw) | 12.6 | 7.4 | 0 | ≈ 0.50M | — (`AN/followup-6.md` row 1 ≈ 445k state, 18 fresh) | ≈ 1.66M |
| M1 create folder (CREATE, PUBLISH dir, PUBLISH name, BIND FOLDER), native, steady (kernel 27; index ≈ 4.4) | ≈ 31 | ≈ 17 | 0 | ≈ 1.2M | — | ≈ 4.0M |
| M1 create file (5 leaves), native, no guard, steady (kernel 35; index ≈ 8.4) | ≈ 43 | ≈ 17 | 0 | ≈ 1.5M | 2,169,867 (guarded 2×1, 385 B carrier, 56 fresh) | ≈ 5.4M |
| Edit (PUBLISH child 4 w + BIND HEAD rebind; incl. the REBIND stamp rewrite) | ≈ 18 | ≈ 14 | 0 | ≈ 0.76M | 1,327,787 (guarded 1×1, 29 fresh) | ≈ 2.45M |
| Rename / move (PUBLISH name + UNBIND + BIND), native | ≈ 23 | ≈ 19 | 0 | ≈ 1.0M | 1,535,870 (guarded 2×2, 35 fresh) | ≈ 3.2M |
| Remove (UNBIND; target word kept, no clear) | ≈ 7 | ≈ 8 | 0 | ≈ 0.38M | 869,189 (guarded 1×1, 16 fresh) | ≈ 1.07M |
| Restore (BIND to a masked key, same target) | ≈ 8 | ≈ 8 | 0 | ≈ 0.40M | — | ≈ 1.18M (would be +110k if the target word were cleared on mask) |
| Move-back (BIND a released key to its old target) | ≈ 8 | ≈ 9 | 0 | ≈ 0.41M | — | ≈ 1.2M |
| RELEASE from mask, native | 7 | ≈ 8 | 0 | ≈ 0.38M | — | ≈ 1.07M |
| WITHDRAW, native | 8 | ≈ 8 | 0 | ≈ 0.40M | — | ≈ 1.1M |
| 20-edit staged save (40 leaves), native (evidence and principal paid once: 6 + 20 × 12 fresh) | ≈ 246 | ≈ 242 | 0 | ≈ 8.3M (≈ 0.40M marginal per edit) | 32 two-word records admitted at 8,086,295; 64 reverted at 14,979,409 | ≈ 32M total (≈ 2M execution + ≈ 30M state gas from the reservoir) |
| Signed secp256k1 (S2) over the native row (incl. the `submitter` word) | +5 | +0 | 0 | +≈ 120k | — | +≈ 570k |
| Fresh 64×4 guard, hash + log (S2) | +1 | 0 | 0 | +≈ 1.25M (256 head reads + 10.6 KB log) | 5,539,847 (carrier 10,593 B) | +≈ 1.35M (carrier would be ≈ 16.5M) |
| Described registration, STRUCTURAL/NATIVE, 295 B descriptor, 0 refs | 7 | 1 | 361 B blob + account | ≈ 0.30M | ≈ 332k | ≈ 1.55M (+183.6k account) |
| Described registration, CUSTOM (singleton wrapper) | 9 | 1 | 361 B | ≈ 0.35M | 1,729,348 (per-binding instance) | ≈ 1.8M |
| Policy activation (incl. `requirePlainRuntime` scan of a 2 KB acceptor ≈ 60k) | 2 | 2 (header `policyRows`, control `mutations`) | 0 | ≈ 115k | — | ≈ 315k |
| Activation (two `upgradeAndCall` + registry + ledger `activate` + 25-word revision row + 2 limits words + readiness + scans of index/units/stores ≈ 0.4–1.2M compute) | ≈ 27 | ≈ 12 | 0 | ≈ 1.1–1.9M | 689,859 (c0 experiment, no scans) | ≈ 3.5–4.3M |
| Freeze (activation + native canary publication ≈ 0.5M + 3 ownership writes; + ≈ 0.6M per signed-lane canary at S2+) | as activation + 12 | +3 | 0 | ≈ 1.7–2.5M | — | ≈ 5.1–5.9M |
| Index steady maintenance per publish (3 appends: by-type, by-author, unique-by-type) | 0.6 | 5.4 | 0 | ≈ 40k | ≈ 62k (4 lists, by-record fresh) | ≈ 131k |
| Index per fresh placement in an existing folder (history, backlink, role-scope fresh in `PostingStore`; one `BitmapStore` call appends the scope entry and stamps the head) | 3.2 | 1.8 | 0 | ≈ 80k | ≈ 133k (6 fresh incl. companions) | ≈ 374k (prototype ≈ 660k) |
| Index per new scope (first placement in a fresh folder) | +1 | — | 0 | +22k | — | +110k |
| Read: `headsAt` 64 principals, all unbound/masked / all BOUND | — | — | — | ≈ 0.15M / ≈ 0.30M | up to 256 single calls | unchanged |
| Read: directory page, limit 32, one principal | — | — | — | ≈ 0.45M | 682,637 | unchanged |
| Read: `publication()` view, 5 leaves, with Effect/3 reconstruction and `effectsHash` | — | — | — | ≈ 0.12M | 15–25 RPCs | unchanged |
| 8,192-byte inline body (256 words) | 256 | — | 0 | ≈ 5.7M | — | ≈ 28.2M state gas (sendable only with `tx.gas` > 2^24; Q4) |
| Same body as a code blob (`carrierKind 1`, reserved) | 1 + account | — | 8,193 B | ≈ 1.7M | — | ≈ 12.75M |
| Genesis code deposit (kernel 16.4 + apply 7.6 + ingress 11.5 + reads 12 + views 11 + registry 12.5 + index 12.5 + posting store 5.5 + bitmap store 5 + build 6 + decoder 5.2 + wrapper 5.2 + validator 5.5 + controller 6 + genesis 3 + descriptor store 1 + directory 1.5 + lens 12 + page 15 + 2 proxies 1.5 + 2 admins 1.8 + 10 profile validators ≈ 9 + 9 blobs ≈ 3.5 ≈ 170 KB; 42 accounts) | — | — | 170 KB | ≈ 34M + setup | — | ≈ 260M state gas + 7.7M accounts |
| Per kernel upgrade (new ≈ 16.4 KB implementation + activation) | — | — | 16.4 KB | ≈ 4.4–5.2M | — | ≈ 28.8–29.6M |

Where the design saves relative to the prototype's measured create: the evidence/context fold (−5 fresh), 2-slot admission rows (−3 fresh), the by-record virtual first entry (−2 fresh), the Files companions retired by stamp/bits-in-head (−3 fresh), no read-set carrier on the native lane (−109k), the cheaper per-leaf re-check. Joint supported envelope: 64 leaves × 8 KiB × 8 refs is **not** a supported operation; `describe().limits` names the joint maxima (`maxBindsPerPublication`, `maxBodyBytesPerPublication`, `maxFreshSlotsPerPublication`) that C1 executes at the 2^24 cap on both schedules and that the SDK's splitter obeys.

---

## 15. Size table (runtime bytes; budgets gate CI; §3.2 for the kernel line items)

| Unit | Prototype measured | v2 nominal | v2 pessimistic (+15 %) | Budget | Headroom at pessimistic vs EIP-170 | Cut if over the warning line |
|---|---:|---:|---:|---:|---:|---|
| `LedgerCore` (full ABI incl. signed lane and import stub) | 24,524 | 16,400 | 18,900 | 19,660 | 23.1 % (pessimistic is over the 17,500 warning line; rungs 1–3 give 15,000 / 17,250) | §3.2 ladder; rung 1 expected at C1 |
| `LedgerApply` | — (7,897 inside the Ledger) | 7,600 | 8,700 | 19,660 | 64.6 % | — |
| `LedgerIngress` S1 / S2 | 12,884 (six lanes) | 11,500 / 15,500 | 13,200 / 17,800 | 19,660 | 27.6 % at S2 | read-set codec to a pure helper |
| `LedgerReads` | — | 12,000 | 13,800 | 19,660 | 43.9 % | — |
| `LedgerViews` | — | 11,000 | 12,700 | 19,660 | 48.3 % | `historyAt`/`acceptanceBasis` to a third facet |
| `TypeRegistry` | 14,914 (incl. 4.4 KB initcode) | 12,500 | 14,400 | 19,660 | 41.4 % | `DescribedCodecV1` pure contract |
| `DescribedTypeRule` v1 | 4,380 | 5,200 | 6,000 | 19,660 | 75.6 % | — |
| `RealmIndex` gen 1 (dispatcher) | 20,981 (Files-capable, storage inside) | 12,500 | 14,400 | 19,660 | 41.4 % | digest-spec fold to a unit |
| `PostingStore` / `BitmapStore` | — | 5,500 / 5,000 | 6,300 / 5,800 | 19,660 | > 74 % | — |
| `IndexBuild` | — | 6,000 | 6,900 | 19,660 | 71.9 % | — |
| `IndexReplayDecoder` | 4,359 | 5,200 | 6,000 | 19,660 | 75.6 % | — |
| `FilesFinalValidator` | 5,417 | 5,500 | 6,300 | 19,660 | 74.4 % | — |
| `RealmController` / `RealmGenesis` / `IndexDeployer` | — | 6,000 / 3,000 / 2,500 | 6,900 / 3,500 / 2,900 | 19,660 | > 71 % | — |
| `LensReader` | 15,006 | 12,000 | 13,800 | 19,660 | 43.9 % | `PlanV1` as a second reader |
| `FilesPageReader` | 16,966 | 15,000 | 17,300 | 19,660 | 29.6 % | row-kind split |
| `files-name/2` | 1,477 | 1,477 | 1,700 | 19,660 | 93 % | — |
| Every initcode-with-arguments | Ledger 40,243 (embedded helpers) | runtime + args (+ ≤ 2 KB; `RealmIndex` + ≈ 3.7 KB manifest) | — | 36,864 | ≥ 25 % | no constructor `CREATE` except `RealmGenesis.run()`, `IndexDeployer.run()` and the OZ 5.6.1 `TransparentUpgradeableProxy` constructor (it creates its `ProxyAdmin`) |

C1 (end of the first S1 week) compiles the partitioned skeleton with the complete storage layout, the native lane, the signed-lane wrapper and evidence arms (verifier stubs), the import stub, all apply arms in `LedgerApply`, `validateLeaf`, activation and freeze paths, `phase`, the Etched hot reads, `LedgerReads.describe`, and measures runtime and initcode of every unit under `prague`; whole-operation gas and `gasStateUsed` for the §14 rows under `prague` and `amsterdam` with `tx.gas` below and above 2^24; the ingress zero-write and validator-context tests; the 48-bit packing saving; the live-bits bisection cost versus the dense list; the singleton wrapper's hostile-calldata suite; the `requirePlainRuntime` scan cost on every release unit; the memory-expansion row at 64 leaves (§6.4). Outcomes are decisions: the §3.2 rule; `layoutId` re-versioned before genesis if 64-bit storage wins; the live-scope recipe named in the manifest; the floor constants and the joint envelope published in `limits`.

---

## 16. Test plan

Directories: `test/{unit,integration,invariant,upgrade,index,security,readers,consumers,evolution,gas,size,harness,snapshots}`. Harness: `EfsTest is Test` (forge-std 1.17.0) deploying through the same deployer library the tools use (every test exercises `RealmGenesis.run()` and `activate`, never bare constructors); fixtures are abstract contracts; exact-bytes revert helpers; `StateDigest` over every `Layout` row kind (canonical projection for head targets) plus every facet getter; `ZeroWrite` via `vm.startStateDiffRecording` filtered by target; the prototype doubles ported to `test/harness/` (`MockAcceptor` as policy-only, the ten index doubles, `FaultyReads` generalized over every reader interface, `NativeCounterfeit`, `ContractSignatureWallet`, `MagicWallet` (returns the magic value for any hash), `Scoped7702Delegate`, `ProxyAcceptor`, `PassthroughController`).

### 16.1 Ported canaries (first, verbatim semantics)

`RecordOccurrenceBounds`, `CoreOrderedAcceptance` (prefix/final rollback, floor semantics, returndata bound, re-entry from both phases, drift rollback, helper pins, the EquipmentRule prefix-`COMPLETE` consumer), `FoundationUpgrade`, `Falsify` F1–F5 + R3 (F5a: a compliant publish succeeds after `activatePolicy(T, 0)`), `MatchedRollback`, `CoreAcceptanceAudit`, `FoundationGuard`, `FoundationIdentity`, `IdentityTransition`, `BindingRelease`, `PublicationPreparation` (refusal precedence with the retry compare first), `CoreIndexReplay` + cutover (incl. a stricter gen-2 validator that does not stall readiness), `IndexConfigExpectation` rewritten for activation-only declarations, `CoreIndexMaterialization`, the twenty `DescribedTypeProfile` cases by name (incl. `test_custom_signature_scope_and_same_code_different_state_squatting` generalized to a lookalike NATIVE instance and an `ERC1967Proxy` lookalike, and `test_direct_forged_context_and_fake_ledger_cannot_impersonate` rewritten against `ctx.ledger`), `DescribedTypeParticipation`, the Name255 cold bind, the 8-ref/4-scalar/digest refusal, the 64×4 guard (S2), `Guarded1271` proxy cases (S2b), `FilesWithdrawal`, `LensReview`, `PublicProfileVectors`, `IndexDigestVectors`, `JoinedConsumer`.

### 16.2 The PM's five difficult behaviors plus native-caller authorship, each with named proving tests (the S1 cells gate C2; S2/S2b sub-cases are tagged)

1. **Failed required validation rolls back the write, including the enclosing app.** `test/consumers/Attribution.t.sol::test_native_app_atomic_both_directions`, `::test_late_leaf_refusal_leaves_no_record_binding_posting_or_evidence`, `::test_validator_callback_cannot_activate_replay_build_or_backfill`, `::test_exhaustion_is_E_ACCEPTOR_GAS_not_E_REJECTED` (incl. the grade-2 nested `EXHAUSTED` word).
2. **Failed required indexing rolls back the write; indexing cannot be bypassed.** `test/integration/atomicity/IndexRollback.t.sol::test_prefix_revert_restores_StateDigest`, `::test_final_refusal_restores_StateDigest`; `test/index/StoreWriter.t.sol::test_attached_store_refuses_non_index_writer`, `::test_stranger_prewrite_of_reserved_family_refused` (S18); `test/upgrade/Readiness.t.sol::test_activate_refuses_unready_or_zero_index`, `::test_15_self_reported_readiness_variants_refused` (wrong frontier, manifest, layout, hot-ABI, store or unit pin, `writers` gap, family outside `FAMILY_IDS`, `ready` flag set with a false predicate).
3. **Incomplete reads never become empty directories.** `test/readers/Honesty.t.sol::test_filtered_empty_page_is_PARTIAL`, `::test_terminal_continued_page_never_COMPLETE_or_ABSENT_PROVEN`, `::test_UNKNOWN_NOT_ON_PAGE_ABSENT_PROVEN_distinct`, `::test_reader_inside_callback_sees_phase_not_IDLE`, `::test_rebind_between_pages_refuses_relaxed_continuation`; `test/index/Synthesis.t.sol::test_occurrencesOf_synthesizes_first_entry_while_raw_head_is_zero`; `test/index/Digest.t.sol::test_coverageOfDigest_sha256_COMPLETE_finds_inline_and_external_content`, `::test_undeclared_algorithm_UNKNOWN`.
4. **Retry after a lost response never duplicates.** `test/integration/Retry.t.sol::test_exact_retry_AlreadyAdmitted_after_activation`, `::_after_policy_activation_on_plan_type`, `::_after_index_replacement`, `::_after_deadline`, `::_after_chain_acceptance_change` (S2: the chain-free signed key), `::_after_self_changed_guarded_head` (S2), `::_after_1271_key_rotation` (S2b); `test/recovery/Classifier.t.sol::test_COMMITTED_at_finalized_block_hash`, `::test_second_device_NOT_COMMITTED_PROVEN`, `::test_deadline_uint64_max_round_trips`; `test/vectors/NativeIntent.t.sol::test_offline_vector_equals_stored_w3`; `test/deploy/Journal.t.sol::test_deployer_crash_before_and_after_journal_write` (`anvil --no-mining`).
5. **Upgrades preserve populated data and reject stale execution assumptions.** The C2 subset of §16.4 (`test/upgrade/Matrix.t.sol`, named there) with the M1 lane bound by default; the c0 tests rebuilt on `LedgerCore`: `test/upgrade/Populated.t.sol::test_same_block_old_write_activation_new_write`, `::test_initializer_misuse_refused`, `::test_pair_bootstraps_once_initialized_version_is_revision_plus_1`, `::test_admin_ownership_and_config_drift_detected_at_next_activation_and_in_describe` (replacing c0 tests 7/8 as recorded in §8.6); `test/integration/Retry.t.sol::test_bound_native_across_activatePolicy_refused_nonce_intact`, `::_across_declareRoleExpectation`.
6. **Native contract callers are first-class.** `test/consumers/NativeApp.t.sol::test_forwarding_writer_becomes_author`, `::test_constructor_time_caller_refused`, `::test_proxy_hosted_app`, `::test_two_composing_apps`, `::test_create2_factory_deployed_app_authors_after_deployment`, `::test_7702_delegated_account_authors_natively` (real type-4, S2).

### 16.3 Unit and integration suites (named)

- `unit/kernel`: apply functions per kind through the delegate; shape law fuzz; CAS; reserved kinds 8/9; bounds and 2^48 saturation; body tail canonicalisation; `head()` canonical-target parity with raw storage (target kept on mask); `publicationAt` compare law first; `viewMutationVersion`; `prevAdmission` chains; the Etched hot-ABI snapshot.
- `unit/ingress`: lanes parametrized over native / guarded / signed / 1271; `ZeroWrite` + opcode lint; delegate-only guards; refusal precedence; read-set bounds; deadline on both lanes after the retry compare; `E_NATIVE_AMBIGUOUS`; `validateLeaf` builds `RefHeader[]` (1..3 words) and `AcceptContext` exactly (vectored); acceptor returndata bomb; maximum legal body validates within the declared floor or fails `E_ACCEPTOR_GAS` (R-SEC-05); a grade-2 wrapper whose nested predicate exhausts returns `EXHAUSTED` and the kernel reports `E_ACCEPTOR_GAS`, never `E_REJECTED`; profile 2 `MagicWallet` claiming a victim principal → `E_SIGNATURE(6)`; profile 2 below `WALLET_GAS_FLOOR` → `E_GAS(0, …)`, a wallet that exhausts → `E_WALLET_GAS` (S2b).
- `unit/registry`: F3/F4/F5a–d; the twenty `DescribedTypeProfile` cases (five of them custom-grade: `L/test/DescribedTypeProfile.t.sol:72, 88, 120, 213, 265`); grades 1, 2 and 3; deterministic NATIVE instance (`E_INSTANCE`); idempotent front-run; 4,096/4,097 descriptor cap; wrapper codehash mismatch `E_WRAPPER`; `activateWrapper` reads the wrapper's constants; `activatePolicy` with a 7702 designator, a code-less address and a proxy refused; `RefuseAllPolicy` sunset; upgrade preserves all tables; `implementation()`; registry obeys `ledger.controller()` after a migration.
- `integration/atomicity`: `MatchedRollback`, `CoreAcceptanceAudit`, `CoreOrderedAcceptance`; forged inner `E_NONCE` inside an index revert decodes as `E_INDEX_CALL`; gas just below the floor → `E_INDEX_GAS` before the call; callback OOG → `E_INDEX_GAS` after the call; final-starvation fixture (prefix spends everything it is given; final still runs from `finalReserve`); two Types in one batch with one hostile; `register`-from-callback succeeds.
- `index`: coverage honesty with per-scope slots for a later BITMAP family (pre-declaration scopes `PARTIAL` until backfilled; post-declaration scopes `COMPLETE`); **both interleavings for a CURRENT_STATE later family** (`test/index/Backfill.t.sol::test_mask_before_backfill_entry_stays_clear`, `::test_mask_after_backfill_hook_clears`) and the MONOTONE OR path; `build` of a later APPEND family ascending to `from == 1` into a fresh store; a later `DigestSpec` rebuilding family 15 into a fresh store with `coverageOfSpec` tracking the frontier; store writer gate incl. S18 (`StoreWriter.t.sol`); `writers` contiguity and lazy attachment; `test/index/Build.t.sol::test_unrelated_activation_during_candidate_build_does_not_invalidate_it`; materialization vectors; replay/cutover incl. "upgrade first, then replay from genesis" and the tolerance rule; `lastMutation` on FIRST_BIND/REBIND/MASK/RELEASE/RESTORE; live bits incl. the 48-entry boundary; by-record synthesis equals a materialized control; digest spec fold; `postingSlice`/`postingWords` equal per-element reads; `E_ORDER`/`E_STAGED`; `Effect/3` round-trip through a Solidity hook and the SDK encoder with every field nonzero (`effects.json`).
- `readers`: `headsAt` parity across live/mask/release/conflict with canonical targets; `LensReader` law incl. both fall-through policies and `resolveRecord`; `resolveManyAt` equals per-coordinate reads; page reader through `FaultyReads`; forged or stale continuation refused (`queryHash`, basis); terminal continued page never `COMPLETE`; gas-aware early `PARTIAL`; stable order under 32 renames; a reader after an index generation change serves the new generation or returns `UNSUPPORTED`, never a stale answer.
- `consumers`: `NativeApp`; the closure compiled at 0.8.27/0.8.30/0.8.37 × cancun/prague with and without via-IR; a paid page consumer with zero writes; `QueryAccumulator` session controls; `immutableReferences` empty for every `profiles/` contract; identical Files Type ids across fixtures with different `--chain-id` and `--realm-salt`.
- `evolution`: the reserved-value refusal suite (every reserved `verifierProfile`, `codecVersion`, `grade`, `ruleMode`, `dependencyClass`, `carrierKind`, `targetKind`, head state ≥ 4, action kind ≥ 8, `refTypes` sentinel, capability bit, `authorityId`/`authEpoch` nonzero); version attribution; later-family honesty; grammar-profile stability (register T under wrapper v1; activate v2; T unchanged); chain acceptance; freeze (every path reverts after; writes/reads/registration/backfill/listing continue; the canary records exist, one per enabled lane; a terminal set with the wrong chain id, a narrower capability set or a smaller limit is refused by the pre-checks; a `successor` notice from anyone but `noticePrincipal` is refused; only if Q3 rules posture B: a steward can activate a replayed generation but not code); a kernel upgrade whose `SUPPORTED_HOT_ABI_IDS` omits a served id, or a unit whose `hotAbiId` is not in the list, is refused (`E_HOT_ABI`).

### 16.4 Upgrade matrix (`test/upgrade/`; `vm.snapshotState/revertToState` over a populated fixture containing every row kind)

Component changed × {ledger implementation (with a new ingress/apply pin), registry implementation, index generation (new families only; full replay), controller (migrate), controller owner, accepted chain, limits, layout (additive, with a second decoder)} × path × {activate with matching set; mismatching expected set; unauthorized; wrong layout id; a set naming an ingress the implementation does not carry (refused); a set whose `controller` is not the caller (refused); same-code reactivation; rollback; registry-only; index-only via build + cutover; combined; `beginTransition` → writes refused → `abortTransition` → the same target cannot be re-begun (`E_TRANSITION_TARGET`) → activate → the next target waits the cooldown (`E_TRANSITION_COOLDOWN`), then succeeds; deadline passes → writes resume with no call, and the next `beginTransition`/`activate` emits `TransitionEnded(3)`; `migrate` → activate → activatePolicy → freeze through the successor; `freeze` with each pre-check failing; `freeze` succeeding (`test/upgrade/Freeze.t.sol::test_canaries_land_only_after_registry_activeRevision_advanced`, `::test_registry_activeRevision_equals_ledger_revision_after_freeze`, `::test_describe_frozen_and_every_activation_E_FROZEN`)} × pending artifact × {signed plan bound to the old set (refused, nonce intact), unbound native call (proceeds), bound native call (refused), bound native call across `activatePolicy` (refused), old cursor (`BASIS_STALE`), guard with unchanged heads (valid), 1271 evidence pointer (old store retained), **already-admitted plan retried after the activation (`AlreadyAdmitted`)**, already-admitted signed plan retried after a chain-acceptance change (`AlreadyAdmitted`, the chain-free key)}. **C2 gate (M1):** the cells {ledger implementation with new ingress/apply pins, registry implementation, limits} × {activate with matching set, mismatching expected set, unauthorized, same-code reactivation, rollback} × {bound native call refused with nonce intact, unbound native call proceeds, already-admitted plan retried}; the full matrix is C3. Post-conditions always: layout-derived raw-slot digest of every row outside the declared migration scope unchanged; `realmOrigin`, every id, every evidence cell, as-of history and masks unchanged; `executionSet` changed iff a component or the ordinal changed; revision +1; `replay(genesis) == live` per family; pre/post `eth_call` parity through independent interfaces.

### 16.5 Invariants (`StdInvariant`; handler drives both lanes, both authors, a mutable policy, activations, upgrades, builds, backfills)

1. `counts().admissions == Σ leafCount`; `publicationAt` injective and write-once. 2. Per record: `occurrences == |{live publish/reuse admissions}|`; body bytes never change. 3. Per binding key: revision strictly increases; `prevAdmission` chains to 0; history family and chain agree; a RESTORE to the same target never creates a fresh slot. 4. `replay(genesis) == live` per family after any sequence incl. upgrades; `build` to 1 and `backfill` to `liveFrom` equal the materialized control; store `live` counts never drift after withdrawals interleaved with builds. 5. Revision strictly monotonic; rows write-once; every evidence cell's revision was live at its `basisBlock`. 6. Coverage monotone; `COMPLETE ⇒ from == 1 ∧ through == admissions`; `phase == IDLE` whenever a reader outside a publication sees `COMPLETE`. 7. No slot outside the declared namespaces is ever written. 8. Every admitted publication is readable in full through the facets in the same block. 9. No reader returns an empty listing with `COMPLETE` when a live member exists; `liveCount == popcount(bits) == scopeHead.live`. 10. The Reconstructor: a clean reader recomputes every digest (native digests from the row plus the bound bits and `w7`), every native `acceptanceProfile`/`indexObligations` from rows + registry history + revision row, and recovers every ECDSA signer from state alone; recomputed signed commitments equal the stored ones; `LOG_ONLY` rows are reported as such. 11. Lock idle after every handler call. 12. Raw-slot digest unchanged by any refused call and, outside the declared migration scope, by any activation. 13. The principal of an address changes only on the exact 7702 marker transition. 14. Reserved bits always zero. 15. An exact retry of any admitted publication reverts `AlreadyAdmitted` at every later handler step. Fuzz: action shape, guard shape, saturation, callback returndata around 4,096/4,164, ingress reply sizes around 672, EIP-712 digests vs an independent vector, readiness inputs, bisection over scope lists of 1..1,024 entries, opcode-scan inputs (push-data containing forbidden bytes must pass; a real `DELEGATECALL` must fail).

**Invariant ids → tests.** I1: `test/security/Surface.t.sol::test_writers_are_kernel_apply_activate_freeze_and_transition` + `test/unit/ingress/ZeroWrite.t.sol` + handler invariants #7 and #11. I2: the `CoreOrderedAcceptance` port (`test/integration/atomicity/Ordered.t.sol::test_shape_rule_policy_write_checkpoint_index_recheck_final_order`). I3: `test/unit/ingress/ZeroWrite.t.sol::test_opcode_lint_and_state_diff_allow_only_SignatureStore`. I4: handler invariant #15 + `test/integration/Retry.t.sol`. I5: `test/security/Surface.t.sol::test_mutating_externals_are_exactly_the_I5_set_plus_lanes_transition_and_registration`. I6: `test/upgrade/Matrix.t.sol::test_same_code_reactivation_refuses_bound_plans_and_cursors` + handler #5. I7: `test/vectors/Ids.t.sol` + the `immutableReferences` gate. I8: `test/evolution/Reserved.t.sol` + handler #14. I9: handler #6 + `test/index/Coverage.t.sol::test_COMPLETE_requires_from_1_through_admissions_not_gapped`. I10: handler #8. I11: `test/integration/atomicity/Floors.t.sol::test_no_refusal_depends_on_callback_acceptor_or_wallet_spend` + the C4 repricing drill. The handler's #12 is the activation-scope digest law cited by §8.3.

### 16.6 Security suite (`test/security/`; one test per register row in §2.2) and CI gates

Reentrancy from acceptor/index/wallet into every entrypoint and configuration function (S1); 7702 fixtures, proxy lookalikes and passthrough runtimes at every code gate (S6, S16); relay on a second Realm fails on domain and `realmOrigin`; after deadline; double relay (S10); etched helpers → `E_HELPER_CODE`; direct calls to every delegate selector; a stranger replays `deploy/plan.json`; a `STATICCALL`ed reader during the final phase cannot claim committed completeness; migration to a code-less, proxied or passthrough successor refused (S15); half-freeze unreachable (no activation path sets the frozen flag except `freeze`); the `MagicWallet` principal claim (S17); the fresh-store squat (S18); the selector-surface test (`test/security/Surface.t.sol`: the only state-changing externals of the ledger, the registry and the controller are the I5 set, the two write lanes and the import stub, `beginTransition`/`abortTransition`, `transferOwnership` (pending only), permissionless registration and `initialize`). CI: `forge build --sizes` with per-unit budgets; `Budgets.t.sol`; storage and transient layout snapshots; `upgrades-core validate`; the populated previous-release snapshot decoded through the new `Layout`; ABI/selector/error/event snapshots incl. the Etched hot ABI and `IAcceptor/2`; `forge lint --deny warnings`; the ingress opcode lint; the `extsload`/`Layout` import lints; the `immutableReferences` gate for `profiles/`; the write-once-facts lint for final hooks; gas snapshots in isolate mode with `gasStateUsed` on an `anvil --hardfork amsterdam` job at `tx.gas` 2^24 − 1 and 2^24 + 1; the joint envelope at `--gas-limit 16777216`; `forge test --mutate` on `core/` before each release candidate; **reproducible build:** two clean, network-disabled rebuilds from the retained standard-JSON input (one of them on a fresh runner image) compare every runtime and initcode hash of every deployable and every `profiles/` rule with `release.json`, and a mismatch fails the release and blocks S1b registration (FU5-R8, `AN/followup-5.md:266`: a clean wrapper rebuild once changed every described Type id; `AN/critique.md:138` item 10).

### 16.7 Constitution traces → mechanism → test (a freeze precondition)

The design authority says the design cannot freeze until its architecture-level traces pass (`system-constitution.md:309-331`). Each trace is mapped here to what this repository provides; the C4 rehearsal and the C5 freeze checklist require every row at or before its stage to be green and every later-stage row to be green or explicitly waived by James for that Realm (Q33).

| Trace | Mechanism here | Test | Stage |
|---|---|---|---|
| Fresh qualifying L3 | genesis plan (§8.2), `efs-fixture.mjs`, a static client over `release.json` and `efs-deployment/1.root` | §12.3 deploy and root rows | S1b |
| Type and admission validation | the ordered pass (§6.4), `RefuseAllPolicy`, `acceptanceBasis()` exposing rule/activation/context | §16.1 ports, §16.2 #1 | S1 |
| Developer workflow and recovery | generated `FilesTypes.sol`, `Evidence.retention`, listing/content/authority coverage reported separately | §16.2 #3, #4 | S1b |
| One-transaction graph | offline ids (`Keys`), one publication per graph, `AlreadyAdmitted` | §16.2 #4, §16.5 #15 | S1 |
| Independent rebuild | `replay(genesis) == live`, `IndexReplayDecoder`, `vectors/` for a second (SDK) implementation | §16.5 #4; §16.4 "upgrade first, then replay from genesis" | S1 / S4 |
| Honest query | statuses with `UNSET = 0`, the listing-coverage law, `Page` flags | §16.2 #3, §16.3 readers | S1b |
| Authority history | evidence rows: author (`w0`), submitter (`w10`), basis (`revision`, `basisBlock`); the payer is the transaction's `from` and is not recorded; rows are write-once | `test/evolution/AuthorityHistory.t.sol::test_author_submitter_separation_survives_account_and_core_upgrade` | S2 |
| Contract Lens | `LedgerViews.headsAt` at 1/8/32/64 principals in bounded gas (§14); a consumer resolves only through a plan it stores itself | `test/consumers/ContractLens.t.sol::test_1_8_32_64_principals_bounded_gas`, `::test_beneficiary_supplied_plan_cannot_authorize_beneficiary` | S1b |
| Arcade, Git/Markdown, EAP, Nanda | profile conventions over the generic Types and families, no Core primitive (E7) | later profiles | S3+ |
| Large content | `files-external/1` is the locator (S1b); chunk trees, ranges and resume are a later carrier profile (E8) | §12.3 AR/IPFS row; later | S1b / S3+ |
| Cross-Realm | the import lane (b5), `efs.ledger.v2.source`, portable Record ids | §17 S4 | S4 |
| Three-host mount; Files/Web/OS parity | client repositories over the facets; this repository contributes the canonical reads and `BasisCommit` | outside this repository | — |
| Privacy | opaque roles and bodies (E10); content-addressed ids reveal only what a profile hashes | `test/evolution/Privacy.t.sol::test_encrypted_body_under_two_nonces_yields_distinct_ids_and_opaque_role_resolves` | S3 |

---

## 17. Implementation sequence and checkpoints

| Stage | Builds | Checkpoint / acceptance |
|---|---|---|
| **S0 — foundation** | Amend the import gate in `checks.mjs` (`REPO/tools/checks.mjs:91` allows only `core/` and `control/` to import `core/`, and its comment at `:72` says readers and index never do): add a path allowlist so `core/layout/` may be imported from `index/` and `readers/{LedgerReads,LedgerViews}`, and keep every other `core/` import and the consumer-closure bans as they are (the src-empty and `bytecode_hash == ipfs` assertions are already retired: `:34` asserts `"none"`); keep OZ 5.6.1 / forge-std 1.17.0 / solc 0.8.37 / `evm_version = prague` with an `amsterdam` profile and a `runs = 1` validator profile; `docs/ONE-WAY-DOORS.md` (every preimage, domain, family name, layout id, hot-ABI id, codec cap, Q1 deadline, with golden vectors), `docs/STORAGE.md`, `docs/EVOLUTION.md`, `docs/RECOVERY.md`, `SECURITY.md`; `Keys`, `Layout` generator + parity test, `Results`, `Errors`, `Limits`, `CodePins`, `CodeScan`, deployer library, `EfsTest`, `StateDigest`, `ZeroWrite`, size/layout/ABI snapshot gates; error and event bytes measured from a stub kernel | **C0:** foundation CI green; vectors committed; implementer named (Q15). |
| **S1 — kernel vertical, native lane** | `LedgerCore` (native lane, signed-lane wrapper with verifier stubs, import stub, full evidence schema, activation/freeze/transition paths, Etched hot reads), `LedgerApply/1`, `LedgerIngress/1` (native prepare, `validateLeaf`, floor, dispatch, `checkActivation` with scans, commitments), `LedgerReads/1` + `LedgerViews/1`, `TypeRegistry` (grades 1, 2 and 3, wrapper v1, binding rows, policy/role rows, catalog, deterministic instances), `DescriptorStore`, `DescribedTypeRule/1`, `PostingStore`, `BitmapStore`, `RealmIndex/1` + the `IndexBuild/1` delegate (families of §10.2, both digest specs, unit list), `IndexDeployer`, `FilesFinalValidator` (gen 1; its Type ids are the deterministic §12.1 ids registered at S1b), `IndexReplayDecoder/1`, `RealmController`, `RealmGenesis`, `ReaderDirectory`, `EfsNative`, `examples/NativeApp.sol`, the canaries of §16.1, the c0 tests rebuilt, the security rows that apply | **C1 (end of week 1):** every unit's runtime and initcode measured on `prague` against the full ABI; gas and `gasStateUsed` for the §14 rows on both schedules with slot counts and both sides of 2^24; the §3.2 rule applied; 48-bit vs 64-bit decided; live-bits recipe decided; floor constants and joint envelope published in `limits`; wrapper hostile suite green; scan cost measured. |
| **S1b — Files on the native lane** | The nine Files/realm Types (§12.1, `files-external/1` included) registered at deterministic instances, gated by the reproducible-build job; `RefuseAllPolicy`; `LensReader/1`; `FilesPageReader/1`; `EfsFiles` + `FilesTypes`; `QueryAccumulator`; seed; `efs-fixture.mjs`; `release.json` + artifacts + closure + `vectors/` + `deploy/plan.json` + `efs-deployment/1` + `gas/report.json` | **C2 (= M1 acceptance):** the PM's workflow end to end through the packaged SDK in the static client with the §12.3 rows; reload-and-recover after a dropped response with zero new prompts, incl. the retry-after-activation case; `NativeApp` through the readers in bounded gas; the §16.2 S1 cells green, incl. the populated-upgrade row and the §16.4 C2 gate. |
| **S2 — signed lanes** | `executeSigned` with verifier profile 1 (b1), read sets (b0), `WitnessRetained`, the signed-lane profile vectors (`intent.json`), the real type-4 7702 test, the populated upgrade matrix complete, kernel re-measured | **C3:** matrix green; kernel within budget (no new bytes expected: the wrapper and arms were in the C1 build); `NOT_COMMITTED_PROVEN` proven on both lanes. |
| **S2b** | Verifier profile 2 (ERC-1271, b2) by ingress build + activation; optional `SignatureStore` retention profile; retention grading in readers | ingress within budget; kernel untouched. |
| **S3 — profiles** | Tags over role-scope 16 (the concept Type with D-B folding, the stance carrier per D-C, a tag family shape priced against D-E before the S3 manifest freezes, Q32); curated lists; staged save on the signed lane; codec 2 specs if D-D is ruled (a generation 2 that re-pins the stores and builds only the new families) | later-family honesty; `coverage(16, …)` `COMPLETE` from genesis; generation 2 without re-materialization measured. |
| **S4 — import and layout** | Import lane (b5) + PX verifier through the ingress and `LedgerApply`; `efs.ledger.v2.source`; "upgrade first, then replay from genesis"; a layout-addition upgrade with `PREDECESSOR_LAYOUT_ID` and a second decoder; `BodyStore` if Q4 and C1 say so | **C4:** freeze rehearsal on a throwaway Realm (ceremony, one canary per lane, posture A; posture B if ruled), every §16.7 trace at or before S4 green, **including a repricing drill**: every supported operation with fresh-slot and cold-access costs doubled under a patched anvil schedule, no refusal allowed. |
| **S5 — release** | Release rehearsal, public-testnet deployment manifest, `verify-deployment`, the oracle verifier shipped with the bundle, the freeze checklist with the enumerated dependency closure and every §16.7 trace green or waived (Q33) | **C5:** public testnet with `describe().controllerOwner` disclosed; Devcon write profile per Q9. |

Rule for every stage: no feature lands in the kernel if it can live elsewhere; every kernel PR prints its attribution delta; every C-checkpoint emits a receipt in the checklist's evidence shape.

---

## 18. Risks

1. **Kernel shape and size.** The S1 shape adds one `DELEGATECALL` per leaf (`LedgerApply`, ≈ 1–2k gas, estimate), and the kernel's nominal estimate (≈ 16,400 B) is only 1.1 KB under the warning line, with the pessimistic case (≈ 18,900 B) over it. Response: measured at C1; rung 1 of the ladder is the expected outcome and rungs 1–3 (≈ 15,000 / 17,250) are the pessimistic response. If the per-leaf cost exceeds 3k, the fallback is **not** moving the publish arm back into the kernel — at ≈ +2.8 KB that would put the nominal near 19.2 KB and the pessimistic over budget even with rungs 1–3 — but moving the per-leaf loop into `LedgerApply` (one `DELEGATECALL` per publication; the kernel keeps entry, evidence, lock and final; both writers still named by I1), which removes kernel bytes (≈ −2 KB) instead of adding them.
2. **Glamsterdam economics and the reservoir.** Whether state gas drawn from the reservoir is visible to `GAS` is unverified. Response: floors never refuse permanently; the C1 both-sides-of-2^24 row decides the `floor*` constants; `gas/report.json` records slot counts so either schedule can be re-applied.
3. **Index composition.** The dispatcher/store split is new mechanism (measured pieces: `_append`, bitmap words, readiness; new piece: the writer gate and `writers` history). Response: C1 measures the per-call authorization cost (≈ 400–800 gas warm per store call, estimate); if it exceeds 2k per effect the generation batches store writes per publication.
4. **Live-bits bisection cost.** ≈ 14 cold `SLOAD`s on a 10,000-entry scope. Response: C1 row; dense list behind the same read ABI.
5. **Singleton wrapper surface.** Forged context. Response: `ctx.ledger == msg.sender` plus recomputation; hostile suite at C1.
6. **Opcode scan false positives.** A legitimately compiled unit could contain a forbidden opcode in unreachable code. Response: the scan skips push data exactly; release units are scanned in CI before activation; a false positive is a build fix, never a runtime refusal of a write.
7. **Registry self-report residual.** A malicious registry implementation installed by activation can lie about `activeRevision`; disclosed; closed at freeze.
8. **Transient lock visibility.** `phase()` from `STATICCALL`ed validators and readers during a publication; tested from both callback contexts at S1.
9. **solc 0.8.37 via-IR deltas** vs the prototype's 0.8.30 shape; canaries first; attribution script.
10. **OZ 5.6.1 Transparent-proxy ordering.** Initialization inside `RealmGenesis.run()`; pinned and tested.
11. **Replay across layout versions.** `PREDECESSOR_LAYOUT_ID` chains one step; a two-step layout jump needs an intermediate activation (documented).
12. **Signed-plan invalidation on index replacement.** Accepted on testnet (Q11).
13. **Relayer exposure under full forwarding.** A hostile Type in a signed plan can burn the relayer's `tx.gas`. Response: disclosed in `SECURITY.md`; relayers simulate and bound `tx.gas`; the acceptance profile pins the rule so simulation is faithful for class-1 rules (Q21).
14. **D-D unresolved.** Codec-2 specs un-enforced until ruled; a generation 2 now builds only the new families.
15. **Vault reachability** of the side-branch evidence; snapshot before S1.
16. **Ownership ambiguity.** Who implements and who owns the M1 integration (Q15, now with a recommendation).

---

## 19. Evolution ledger (maintained as `docs/EVOLUTION.md`; one test per row in `test/evolution/`)

| # | Change class | Mechanism | Kernel ABI? | Layout? | Old rows re-read? | Who, before / after freeze |
|---|---|---|---|---|---|---|
| E1 | New lane or verifier suite | new `LedgerIngress` build + capability bit + activation; evidence rows carry `proofKind`/`verifierProfile` | no (import's selector exists from S1 as a stub) | no | no | controller / frozen (or steward B) |
| E2 | New descriptor codec or wrapper build | `codecVersion` and `ruleCodehash` in the header; `activateWrapper` appends; old Types keep their pinned wrapper | no | no | no | permissionless registration; controller activation |
| E3 | New developer predicate semantics | new Type; `RefuseAllPolicy` on the old; supersession evidence | no | no | no | anyone / controller |
| E4 | New index family or physical layout | new generation re-pinning the stores and adding a fresh store per new family set (created with it by `IndexDeployer`); APPEND families built ascending into it before attachment; BITMAP families hooked at declaration with per-scope backfill by `liveSemantics`; never a re-materialization of untouched families | no | no | no | controller / steward |
| E5 | New action kind (incl. stage-then-commit) | kernel upgrade + new callback profile + new generation; kinds 8/9 and `efs.ledger.v2.staging` reserved | implementation, not selector | no | no | controller / frozen |
| E6 | New reader or Lens algorithm | immutable contracts over the facets; listed in `ReaderDirectory`; never in the execution set; readers resolve the live index per call | no | no | no | anyone, before and after freeze |
| E7 | New profile (tags, lists, homes) | Types + a unit (new generation only if families change) + readers | no | no | no | anyone / controller |
| E8 | Larger bodies and carriers | `carrierKind`; `limits.maxBody`; `BodyStore` behind b6 | no | no | no | controller |
| E9 | Multichain portability of ids | `Keys` chain-free except the origin-qualified contract principal; NATIVE rule instances at the same address on every chain | no | no | no | one-way door |
| E10 | Privacy profiles | opaque roles and bodies | no | no | no | anyone |
| E11 | Chain fork or renumbering | `acceptedChainId` by activation; domain separator recomputed | no | no | no | controller; frozen = read-only on a fork |
| E12 | Counter widths beyond 48 bits | layout revision; `layoutId` re-versioned; `PREDECESSOR_LAYOUT_ID`; decoder per layout; hot ABI unchanged (`uint64`) | no | yes | no | controller / impossible after freeze |
| E13 | Controller, controller code or owner change | activation (`migrate`, `acceptOwnershipAndActivate`) | no | no | no | owner |
| E14 | Freeze | terminal activation + canary + renounce; steward optional | no | no | no | owner, once |
| E15 | Gas repricing | floors re-tuned by a limits activation before freeze; after freeze, satisfied by `tx.gas` | no | no | no | controller / nobody needed |
| E16 | Hot read additions | a new `HOT_ABI_ID`; `SUPPORTED_HOT_ABI_IDS` grows by one and never shrinks; existing selectors and layouts never change | additive | no | no | controller |

---

## 20. Engineering decisions made here (decision · alternative rejected · why)

1. **Spine = security-upgrade-first's partition and invariant** · the other four as base · fewest reversals; closed privileged paths; the only threat register.
2. **Etched `ILedgerHot` (21 one-word reads + `extsload*`); struct views on two separate immutable facets outside the execution set and outside `AcceptContext`** · reads inside the set or a fallback facet · acceptors and units bind to an ABI that never changes; a reader fix voids nothing.
3. **S1 kernel shape = kernel + `LedgerApply` (writing delegate) + `LedgerIngress` (zero-write)** · apply arms in the kernel with a contingency split · measured against the full ABI the kernel will carry; two pinned writers named by I1.
4. **`IAcceptor/2 = accept(AcceptContext{…ledger, index…}, body, refs, RefHeader[3 words])`; singleton wrapper; `ctx.ledger == msg.sender` required** · prototype `accept(typeId, data, refs) → bool`; no ledger in the context · rules read the Etched hot ABI without casts, immutables or facets; Files ids stay portable.
5. **Plan-intrinsic `intentDigest` on every lane, chain-free on the signed lanes (the EIP-712 signing digest is verified, never stored); `publicationAt` compared before every time- or state-dependent check** · live-state folded into native digests; compare after prepare · an exact retry is `AlreadyAdmitted` forever (PM behavior 4).
6. **`Native{nonce, deadline, expectedExecutionSet, expectedAcceptanceProfile}`, both bound by the SDK by default; two flag bits in `w0`** · unbound default; no acceptance field · the M1 lane rejects stale execution and acceptance assumptions by default (PM behavior 5) without a later selector change.
7. **Evidence: 5 words native, `deadline u64`, signed commitments only for signed lanes** · truncated deadline; store everything · write-once evidence must match what was signed.
8. **Chain-bound EIP-712 domain; `Intent.author`; profile 2 binds `author` to `principalId` before the wallet call** · author taken from the witness · no magic-wallet principal claim.
9. **Per-leaf basis re-check kept; `registry.activeRevision()` on entry; every mutation path idle-gated** · lock-gating only · ruling 3; the §8.11 claim is now a check.
10. **Immutable generations as dispatchers over per-Realm storage-owning stores; a fresh store per new family set with a constructor-named `INITIAL_WRITER`, created with its generation by `IndexDeployer`; `IndexBuild` a delegate with no generation address; APPEND families built ascending, BITMAP families hooked at declaration with per-scope backfill by `liveSemantics`** · per-generation storage with descending backfill; an unauthenticated candidate writer · adding a family never re-materializes untouched ones, backfill never fights the strictly-increasing law, no stranger can pre-write a live store, and no address cycle exists.
11. **Baseline = ruled families + role-scope + live-scope; digest fed by a manifest digest-spec table from genesis; by-record virtual with `occurrencesOf`/`postingHeadOf` synthesis** · fewer families; by-record materialized; digest unfed · the ruled lookup works at M1; virtual reads are honest.
12. **`lastMutation` and 48 live bits in the scope head word, stamped on every bind-kind transition incl. REBIND/RESTORE** · stamp only on append/clear · measured CQ-10; no spliced listings.
13. **`Effect/3` = 24 explicit static words + a shared `refs` array** · packed `uint8` sub-fields · ABI-valid, SDK-reproducible `effectsHash`, folds without ledger reads.
14. **2-slot admission rows with `targetKind`; no shadow heads** · 3-slot rows; shadow heads · the decoder rebuilds `oldTarget` from the chain.
15. **Head target word kept on MASK/RELEASE; canonical target = 0 unless BOUND** · clear on mask · restores and move-backs cost a rewrite, not a fresh slot.
16. **Execution set = components incl. `registryImpl`, `applyDelegate`, `controllerCodehash` and the ordinal; no reads; limits via `limitsProfileId`** · reads in the set; controller code unpinned · UF-3; upgrade-without-activation closed for the registry and the controller.
17. **Hand-rolled two-step ownership; owner change, migration and freeze are activations with the controller/owner fields verified; the registry obeys `ledger.controller()`** · OZ `Ownable2Step`; registry-stored controller · no bypass; migrated Realms keep activating and can freeze.
18. **Freeze = distinct `freeze` selectors with liveness pre-checks and a canary publication; no terminal flag in `ActivationSet`** · terminal flag on every set · no half-freeze, no dead-on-arrival terminal state.
19. **One transition per target, ever (`lastTarget` written at `beginTransition`), with cooldown; bound in `limits`** · renewable transitions · a live controller cannot pause indefinitely or more than half the time.
20. **Chain acceptance by activation; refused after freeze; the terminal set must name `block.chainid`** · `E_CHAIN` forever · forks do not brick a testnet; a freeze cannot brick a Realm.
21. **`realmOrigin = keccak(DOM, genesisChainId, coreAddress, realmSalt)`** · CAIP-2 preimage · unchanged (Q13).
22. **`ruleId` = the codehash named in the descriptor header; wrapper constants read from the wrapper; NATIVE instances deterministic via CREATE2 salt 0** · Realm-local version table; caller-chosen instance · one id per descriptor everywhere; no lookalike squat; idempotent genesis.
23. **Codec 1 descriptor ≤ 4,096 B; `maxWitness 4,096`; `DescriptorStore` ≤ 24,576 B** · unbounded · the measured prototype cap; same bytes deploy on every chain.
24. **Index allowance = availability floor from a slot-count model converted with activation-set constants; `finalReserve` withheld; acceptor gas = declared minimum, forwarded fully; the ERC-1271 wallet call a 300k floor forwarded whole; exhaustion typed at every level (incl. the wrapper's `EXHAUSTED` word)** · hard caps in an immutable manifest and in Type identity · no frozen number can refuse a class of writes after a repricing (I11).
25. **Read-set and ERC-1271 bytes: hash in state + bytes in logs by default; `Evidence.retention` reported; `LOG_ONLY` graded `UNKNOWN` for portability** · claim "state is sufficient" · honest; Q5 decides the import rule.
26. **Bodies inline at S1; `carrierKind` reserved** · blobs as default · Q4.
27. **48-bit storage / 64-bit ABI, measured at C1** · 64-bit now · pm R10.
28. **Reference cap 8 in codec 1** · 16 now · TagSet is S3.
29. **Budget 19,660 B against the full kernel ABI from C1; +15 %; ladder** · S1-only build at C1 · no post-S2 surprise.
30. **`Layout` in `core/layout/`, outside the closure; `extsload` forbidden in profiles and consumer readers** · `Layout` in the closure · the measured shortcut class cannot reach consumers.
31. **Distinct value types for keys; `ScopeKey` per-principal; `roleScopeKey` domain-separated** · `bytes32` everywhere · compile-time refusals; vectored preimages.
32. **Statuses with `UNSET = 0`; `BasisCommit` comparison law stated; listing coverage distinct from family coverage; `Page` flags on every paged reader** · reverts on staleness; bare coverage · Multicall3 degrades per item; no forged terminal `COMPLETE`.
33. **M1 = S1 + S1b on the native lane, bound by default** · signed lane first · PM's thin vertical with PM behaviors 4 and 5 exercised on the M1 lane.
34. **OZ 5.6.1, forge-std 1.17.0, solc 0.8.37, `prague` bytes with an `amsterdam` profile; EIP-7997 factory; `RealmGenesis` for the three cycle members** · plain CREATE2 for everything · no address cycle; stranger-replay determinism.
35. **`CodeScan.requirePlainRuntime` at every EFS code pin; `dependencyRoot` in the terminal row; declared dependency classes disclosed** · codehash-only pins · a freeze can be checked, not just claimed (S16).
36. **Retire c0 per-write admin-drift tests; detect drift at activation and in `describe()`** · ≈ 10k per write for two `owner()` calls · the drift is unreachable without the pinned controller; the structural guarantee is the design.

---

## 21. Product questions for James (with recommendations)

1. **Structural `ruleId`** — codehash named in the descriptor (this design) or a grammar-profile commitment? One-way door closing at the first grade-1/2 registration on a persistent Realm (before S3). *Recommend codehash.*
2. **Signing domain** — chain- and deployment-bound EIP-712 with import as the only portability path. *Recommend bind.*
3. **Freeze end state** — (A) one-way burn; (B) append-only steward for replayed generations and codec/verifier additions; (C) immutable code without proxies at S5. *Recommend A for testnets; decide B/C before S5.*
4. **Supported inline body maximum under repricing** — 8,192 B (≈ 28.2M state gas, reservoir-only) or ≈ 4 KiB inline with a blob carrier above. *Recommend: measure at C1, publish in `limits`, keep the seam.*
5. **Witness retention** — hash + log by default; must import-eligible plans use `SignatureStore` retention (otherwise their 1271 authorship is `UNKNOWN` for portability)? *Recommend: default hash + log; state retention required for import.*
6. **Declaration signature profile** — EIP-712 EOA declarations at launch; ERC-1271 creators later. *Recommend yes.*
7. **Names N1/N2** — `files-name/2` as the only Name Type; NFC and case policy in the client. *Recommend yes.*
8. **Controller-owner change** — an activation (this design) or a recorded-only transfer. *Recommend activation.*
9. **Static-client write profile for Devcon** — direct-EOA prompt first; relayed profiles later. *Recommend yes.*
10. **Chain-id pin after freeze** — read-only on a fork unless posture B. *Recommend read-only.*
11. **Index replacement and plan invalidation** — every replacement voids unsent signed plans (testnet) or scoped invalidation later. *Recommend accept now.*
12. **State-only `publicationId → ordinal` lookup** — no map (this design). *Recommend no map.*
13. **Realm-origin preimage** — confirm. *Recommend confirm.*
14. **Paid complete listings** — accumulators in the closure. *Recommend accumulators.*
15. **First-milestone owner and implementer** — blocks S1 start. *Recommend: Claude implements `contracts-v2` under the 2026-10-13 mandate, with one named integration owner for the SDK/client vertical (the PM's ask, `AN/pm-requirements-release.md:227` item 6).*
16. **D-D narrowed** — presence families total; predicate families declared by Type authors in codec 2 as BITMAP families with per-scope coverage; K10 Etched; ROSTER reserved. *Recommend ratify.*
17. **Withdraw semantics** — occurrence-only. *Recommend occurrence-only for S1.*
18. **Testnet upgrade authority (the initialization plan's D5)** — EOA while data is disposable; a pinned Safe before data worth keeping. *Recommend as stated.*
19. **Stateful (`CALL`-mode) rules** — later. *Recommend later.*
20. **Record two one-line rulings** — the EAS exclusion and the frozen-dependency policy for Etched code (now mechanized as S16: every EFS code pin is scanned, dependency classes are disclosed, the terminal row carries `dependencyRoot`). *Recommend yes.*
21. **Acceptor gas as a floor (new)** — rules receive all available gas above the kernel tail, so a hostile Type in a signed plan can burn a relayer's whole `tx.gas` (bounded by the relayer's own limit and simulation) in exchange for Types that a repricing can never brick. Alternative: a Realm-level multiplier cap re-tunable by activation before freeze. *Recommend the floor.*
22. **Native lane bound by default (new)** — the SDK binds `expectedExecutionSet` and `expectedAcceptanceProfile` on every native call, so an activation or a policy activation between preparation and landing refuses the call (reprepare) instead of landing under changed rules. *Recommend bind by default; an explicit unbound option for apps that want "land anyway".*
23. **Permissionless `ReaderDirectory` (new)** — anyone may list a reader that names the ledger; the SDK trusts `release.json`, the directory is discovery only (readers can be fixed after freeze). Alternative: owner-listed, dead after freeze. *Recommend permissionless.*
24. **Freeze canary Type (new)** — `realm-notice/1` is registered at genesis and the freeze publishes a `frozen` record from the controller's principal. *Recommend yes.*
25. **Descriptor cap 4,096 B (new)** — the measured prototype cap; larger Types are a codec-2 question. *Recommend keep.*
26. **Non-atomic saves above the envelope (new)** — the SDK splits a save above the published maximum into several publications and labels it non-atomic (§12.2), while pm R3 (`AN/pm-requirements-release.md:138`) says a retry "never leaves half a save". Options: (a) accept the label and let the client surface a partially landed save as a visible state (each part keeps its own `AlreadyAdmitted` retry identity, so no part is ever duplicated); (b) stage-then-commit (kinds 8/9, b9) in a later kernel upgrade; (c) a smaller supported document. *Recommend (a) for M1 with the maximum published in `limits`, and (b) scheduled after S2.*
27. **Cost envelope and venue (new)** — a create-file is ≈ 1.5M today and ≈ 5.4M under EIP-8037 (§14, estimates), and no first public chain is named. *Recommend: name the first public testnet chain before S5, take the envelope from the C1 measurement on that chain's schedule, and plan against EIP-8037 pricing.*
28. **Registry self-report residual (new)** — a malicious registry implementation installed by activation can lie about `activeRevision()` until the freeze (risk 7; `AN/followup-6.md:360`, Q-J2). Options: accept until freeze (this design) or an immutable registry replaced by activation like the index. *Recommend accept until freeze; revisit only if a Safe-held upgrade key is retained after testnet.*
29. **Lens defaults and the seed principal (new)** — the PM asks to surface the empty-principal-list default and the multi-lens merge rule (`AN/SUMMARY.txt:317-319`); the fixture seeds the root under an EOA fixture principal (§13). *Recommend: at the contract readers an empty principal list means "no lens", never "all data"; the client supplies its defaults from `efs-deployment/1.defaultLensPrincipals`; first-touch-wins merge for M1; keep the EOA seed principal for testnets.*
30. **Devcon scope (new)** — whether Lists and a public home (M3) must be in the first testnet release (`AN/pm-requirements-release.md:227` item 7). *Recommend: Files plus the Solidity consumer for the first testnet; Lists and the home as S3 profiles.*
31. **Types as registry rows or as Records (new)** — `AN/critique.md` C-2. This design keeps the registry (rows, pins, its own proxy) and leaves Types-as-Records as a later profile convention over the registry id (§9.5(vi)). *Recommend rows now; a `TypeDescriptor/1` Record profile later if wanted.*
32. **Tags and the D-E budget (new)** — D-B and D-E (`OR:341-360`) rule one global concept id per folded string and a target of ≈ 50k gas per tag today (≈ 220k under Glamsterdam); a tag through the generic BIND path would cost ≈ 0.25M today and ≈ 1.2M under EIP-8037 (inferred from the §14 slot model: head, position, `bindingPosition`, admission row, plus history, role-scope, scope and backlink appends), roughly five times D-E. Tags are therefore outside C2 (§12.3) and designed in S3 against D-E — a dedicated tag family shape (for example a per-concept stance bitmap over principals rather than a binding per tag). *Recommend: hold tags to D-E and accept the S3 schedule; if D-E cannot be met, re-rule the budget explicitly rather than let the design widen it silently.*
33. **Freeze-trace waivers (new)** — which §16.7 rows may be waived for a given Realm's freeze. *Recommend: none for a persistent Realm; any for a throwaway rehearsal.*

---

## 22. Sources

Panel: `D/proposal-security-upgrade-first.md` (spine), `D/proposal-consumer-first.md`, `D/proposal-evolution-first.md`, `D/proposal-size-first.md`, `D/proposal-gas-economics-first.md`; judgments `D/judge-kernel-correctness.md`, `D/judge-systems-architecture.md`, `D/judge-product-and-sdk.md`; reviews `D/attack-kernel-atomicity-reentrancy.md`, `D/attack-upgrade-storage-freeze.md`, `D/attack-size-gas-evm.md`, `D/attack-consumer-sdk-portability.md`, `D/attack-index-replay-coverage.md`, `D/attack-types-registry-rules.md` and their adjudications; the two checks `D/check-consistency.md` and `D/check-completeness.md` (§24); `D/designer-notes-v2.md` (P11–P18). Analysis: `AN/SUMMARY.txt`, `AN/critique.md`, `AN/followup-2.md` (CQ-1..24), `AN/followup-3.md` (the c0 tests, UF-1..24), `AN/followup-5.md` (FU5-R1..17), `AN/followup-6.md` (TR-01..22, Part B slot accounting), `AN/followup-profile-suites.md`, `AN/proto-ledger-kernel.md` §1.9, `AN/proto-index.md`, `AN/proto-types-registry.md`, `AN/proto-tests-upgrade-harness.md`, `AN/sdk-client-asks.md`, `AN/solidity-patterns-2026.md`, `AN/design-kernel-requirements.md`. Authority: `OR`, `PTA`, `system-constitution.md`, `core-architecture-candidate.md`, `core-closeout-engineering-choices-20260916.md` (ruling 21), the 2026-09-10 index-layer position. Prototype revision `4fbea63a`; foundation `REPO` (OZ 5.6.1, forge-std 1.17.0, `bytecode_hash = "none"`, `docs/GAS-SCHEDULES.md`). No build, compiler, chain or node tool was run.

---

## 23. Review record (every adjudicated finding and its disposition)

Dispositions: **fixed** (the design changed; section named), **rejected** (reason and evidence), **deferred** (to a checkpoint with the measurement that decides it). Verdicts are the verifiers'; where this document overrules, it says so with evidence.

| Finding | Verdict | Disposition |
|---|---|---|
| kernel-atomicity-reentrancy#1 | confirmed | **Fixed** §5.8, §6.1 steps 2–3, §6.2, §6.6, §4.3 (`w0` b3/b4): native digest pure over caller inputs; the signed retry key chain-free (`intentDigest` vs `signingDigest`), so no chain-change exception is needed; retry compare first; recovery law restated. Tests §16.2 #4, §16.4. |
| kernel-atomicity-reentrancy#2 | confirmed | **Fixed** §10.4, §6.4, §5.1 `Limits`: slot-count model converted with activation-set floor constants; floor not cap; `E_ALLOWANCE` deleted; C1 row both sides of 2^24 (§3.3 item 5, §15). The reservoir/`GAS` behaviour stays a C1 measurement. |
| kernel-atomicity-reentrancy#3 | confirmed | **Fixed** §5.4, §5.9: `reinitializer(uint64(revision) + 1)`; genesis test §16.2 #5. |
| kernel-atomicity-reentrancy#4 | confirmed | **Fixed** §5.11: `Effect/3` with explicit `targetKind`, `oldTargetKind`, `refCount` fields; new callback profile; `effects.json` vector and Solidity round-trip test. |
| kernel-atomicity-reentrancy#5 | confirmed | **Fixed** §6.4, §9.4, §9.5(iii): policy called only when the active row's acceptor is nonzero; row recorded regardless; `RefuseAllPolicy` is an explicit contract. |
| kernel-atomicity-reentrancy#6 | confirmed | **Fixed** §5.1 `Intent.author`, §6.2 profile 2, S17: `contractPrincipal(realmOrigin, author) == principalId` before the wallet call; `E_SIGNATURE(6)`; the address is in the signed struct (decided before the S2 typehash freeze). |
| kernel-atomicity-reentrancy#7 | confirmed | **Fixed** §5.10: `AcceptContext.ledger` (and `index`); `reads` removed from the context; acceptors read only the Etched hot ABI; facets outside the execution set (§8.1). |
| kernel-atomicity-reentrancy#8 | confirmed | **Fixed** §4.3 `w1`: `deadline u64@48`; stored at full width; Reconstructor and `type(uint64).max` round-trip tests (§16.2 #4). |
| kernel-atomicity-reentrancy#9 | confirmed | **Fixed** §8.1, §5.4, §4.2: reads removed from `ComponentSet` and the realm namespace; `ReaderDirectory` (advisory) for discovery. |
| kernel-atomicity-reentrancy#10 | confirmed | **Fixed** §4.2, §8.3 step 5f: ingress/apply served from the implementation immutables; realm slots removed; the set must name the immutables. |
| upgrade-storage-freeze#1 | confirmed | **Fixed** §4.5, §8.3, §8.5, §8.7: registry stores no controller or frozen flag; `onlyController = ledger.controller()`; 5h = `ProxyAdmin.owner() == msg.sender`; migrate postcondition; must-pass migrate→activate→activatePolicy→freeze test. |
| upgrade-storage-freeze#2 | confirmed | **Fixed** §10.4, §6.4, §9.2, §17 C4: floors not ceilings for both the index and acceptors; `validationGas` a declared minimum; `ceiling` removed; repricing drill at C4. |
| upgrade-storage-freeze#3 | confirmed | **Fixed** §8.2, §10.1: `RealmGenesis` creates controller and proxies by its own nonces; `IndexDeployer` does the same for a later generation and its fresh stores; `IndexBuild` holds no generation address; no cycle anywhere; S9 determinism kept. |
| upgrade-storage-freeze#4 | confirmed | **Fixed** (same as kernel#3) §5.4, §5.9. |
| upgrade-storage-freeze#5 | confirmed | **Fixed** §8.3 step 5h, §5.11 `Readiness`: `attachedRevision` removed; unchanged-index branch requires only codehash/manifest equality and `IDLE`; `indexGeneration := set.revision` on change. |
| upgrade-storage-freeze#6 | confirmed | **Fixed** §5.4 `ComponentSet.registryImpl`, §5.9 `implementation()`, §8.3 steps 5e–5f, §4.2. |
| upgrade-storage-freeze#7 | confirmed | **Fixed** §5.12, §8.3 step 0, §8.4, §8.5: hand-rolled ownership; no no-arg accept, no public renounce; controller/owner fields verified after the ownership update. |
| upgrade-storage-freeze#8 | confirmed | **Fixed** §5.4 `controllerCodehash`, §8.5 (`requirePlainRuntime` on the successor), §6.1 step 7 (`activeRevision()` on entry), §8.6 (c0 tests 7/8 retired as per-write checks with the recorded reason and rebuilt as activation-time detection). |
| upgrade-storage-freeze#9 | confirmed | **Fixed** §5.4 (no terminal flag in `ActivationSet`), §8.10 (distinct `freeze` entries; registry activated before `ledger.freeze`; pre-checks incl. `acceptedChainId == block.chainid`, capability and limit supersets; one canary per lane), §4.5 (registry reads frozen from the ledger). |
| upgrade-storage-freeze#10 | confirmed | **Fixed** S16, §9.4 (`requireRealCode` + scan at `activatePolicy`), §8.3 step 5g (scan at every pin), §4.3 `w20 dependencyRoot`, §13 freeze checklist, Q20. Third-party NATIVE rules stay a disclosed declared class. |
| upgrade-storage-freeze#11 | confirmed | **Fixed** (same mechanism as kernel#9) §8.1, §5.7 facets with `thisFacet`, F13 layout check, §19 E6. |
| upgrade-storage-freeze#12 | confirmed | **Fixed** §5.1 `Native.expectedAcceptanceProfile`, §6.2, §5.14 (`EfsNative.Bind` bound by default), §12.3 M1 row, §16.4 matrix row; Q22 records the product choice. |
| upgrade-storage-freeze#13 | confirmed | **Fixed** §4.1 (`LAYOUT_ID`/`PREDECESSOR_LAYOUT_ID`, kernel packs through `Layout`, lint), §8.3 step 5d, step 5j (`realm.layoutId := set.layoutId`), §5.3 `layoutId()`, §3.3 item 6 (populated-snapshot decode in CI). |
| upgrade-storage-freeze#14 | confirmed | **Fixed** §5.3 (Etched `ILedgerHot`, `HOT_ABI_ID`, `SUPPORTED_HOT_ABI_IDS` membership instead of an undecidable hash superset), §5.11 `Unit.hotAbiId`, §8.3 step 5g (`E_HOT_ABI`), §3.2 ladder (no getter removal), §19 E16. |
| upgrade-storage-freeze#15 | confirmed | **Fixed** §4.2 `transition` word, §8.8: one transition per target, ever (`lastTarget` written at `beginTransition`), cooldown of `maxTransitionBlocks` after abort or lazily observed expiry, bound in `limits`. |
| upgrade-storage-freeze#16 | confirmed | **Fixed** §8.3 step 5b (migration first, declared scope, `migrationHash`), §16.5 #12 restated, the inaccurate sentence replaced. |
| size-gas-evm#1 | confirmed | **Fixed** (same as kernel#2) §10.4, §6.4, §5.6 (`E_INDEX_GAS` for empty-returndata failures, retry `resubmit`). |
| size-gas-evm#2 | confirmed | **Fixed in part** §3.2: `TypeInfo` re-encode, Effect/3 build + `effectsHash`, readiness glue itemized; `checkActivation` is a `DELEGATECALL` (step 5h); `Limits` stored in the realm namespace. **Overruled in part, with evidence:** the headline (the fourth rung of the finding's own ladder, the writing delegate, is the landing point) is adopted structurally — `LedgerApply` is the S1 shape (decision 3) — so the kernel nominal is ≈ 16,400 B (pessimistic ≈ 18,900) rather than the finding's 19.8–20.8 KB; the per-leaf cost is a C1 row (risk 1); item 4 of its fix (one reused scratch region per leaf) is carried in §6.4. |
| size-gas-evm#3 | confirmed | **Fixed** §3.1 (budget against the full ABI), §3.3 item 4 (C1 compiles signed lane + import stub), §5.2 (import stub from S1), §15 (one set of figures; §0 no longer claims import adds no kernel byte), §17 C3. |
| size-gas-evm#4 | confirmed | **Fixed** §5.1 `Limits` joint-envelope fields, §4.2 S1 values, §12.2 (M1 staged-save maximum stated, non-atomic splits labelled), §4.3 (kinds 8/9 and `efs.ledger.v2.staging` reserved), §14 (20-edit row). |
| size-gas-evm#5 | confirmed | **Fixed** (same as kernel#4) §5.11. |
| size-gas-evm#6 | confirmed | **Fixed** §3.1 rows 4–5 and 9–12 (top-down from 20,981 B; split into dispatcher + stores + build decided before the gen-1 manifest; two facets from S1; `resolveManyAt` only on `LensReader`). |
| size-gas-evm#7 | confirmed | **Fixed** §10.1, §10.6, §4.6, §5.11: stores outlive generations; a fresh store per new family set with a closed writer rule; APPEND families built ascending from 1 before attachment; BITMAP families hooked at declaration with per-scope coverage only for pre-declaration scopes; genesis families have no per-scope slot; new-scope cost priced (§14). |
| size-gas-evm#8 | confirmed | **Fixed** §4.3 `HeadRow` (target kept; canonical target rule), §6.4, §14 Restore and move-back rows; decided before `layoutId` freezes. |
| size-gas-evm#9 | confirmed | **Fixed** §9.2 (≤ 4,096 B), §3.1 row 8 (`DescriptorStore` ≤ 24,576 B), §4.2 (`maxWitness 4,096`), vectors §13. |
| size-gas-evm#10 | confirmed | **Fixed** §14 regenerated (index maintenance 0.6/5.4, create folder ≈ 31 fresh, upgrade row incl. activation, genesis deposit incl. proxies/admins/validators/blobs, `headsAt` both cases, `publication()` with reconstruction, cold account 3,000), §3.3 item 2 (initcode rule for `RealmIndex`), §5.1 read maxima, §5.7 bounds. |
| consumer-sdk-portability#1 | confirmed | **Fixed** (same as kernel#1) §6.1–6.3, §6.6, §4.3, §12.3 (M1 bound by default). |
| consumer-sdk-portability#2 | confirmed | **Fixed** §6.6: classifier at one finalized block hash (EIP-1898 `requireCanonical`); the different-digest branch added; the unreachable `nonceOf` branch removed; second-device test §16.2 #4. |
| consumer-sdk-portability#3 | **refuted** | **Disposition recorded; refutation upheld.** The Files rules never needed a forbidden read path, and no immutable ledger address enters any rule (release gate: empty `immutableReferences`, §5.10, §16.3 consumers). The two real inconsistencies the verifier kept are fixed anyway: `ctx.ledger` is in the context (kernel#7) and `RefHeader` carries `word1`/`word2` per the Type's `refHeaderWords` (§5.10, §9.2, §12.1). Files Type ids are identical across `--chain-id`/`--realm-salt` fixtures (test §16.3). |
| consumer-sdk-portability#4 | confirmed | **Fixed** §8.1 (reads out of the set), §5.10 (reads out of the context), §5.1 (`BasisCommit` comparison law: readers compare `(executionSet, indexGeneration)`, origin = `admissionHighWater`, `registryMutations` echoed), §5.13. |
| consumer-sdk-portability#5 | confirmed | **Fixed** §5.13 (readers resolve `index()` per call; `supportedProfiles`; `IReaderDirectory`), §4.2 +16, §5.7 `Description.readerDirectory`, §12.3 cold-pin row (≤ 9 calls on the first pin of a release digest, ≤ 4 afterwards). |
| consumer-sdk-portability#6 | confirmed | **Fixed** §4.6, §10.2 row 18, §11, §14 Edit row (+1 rewrite): stamp on every bind-kind transition incl. REBIND; test §16.3 index. |
| consumer-sdk-portability#7 | confirmed | **Fixed** §5.11 `Effect/3` (`target`, `oldTarget`, `targetKind`, `oldTargetKind`, `refCount`, `freshRecord`, withdrawn coordinate; refs array), §10.3, `effects.json`. |
| consumer-sdk-portability#8 | confirmed | **Fixed** §8.2 (`RealmGenesis`; validator caller pin dropped, §3.1 row 14). |
| consumer-sdk-portability#9 | confirmed | **Fixed** (same as kernel#2) §10.4, §15 C1 on `amsterdam` both sides of 2^24, §13 `gas/report.json` fields. |
| consumer-sdk-portability#10 | confirmed | **Fixed** §5.5 (claim corrected), §5.1 `Retention` and `Limits.witnessRetention`, §5.7 `Evidence.retention`, §7.1 import row, §7.4 (`SIGNATURE_STORE` an ingress immutable; the zero-write exception named and tested), Q5 restated. |
| consumer-sdk-portability#11 | uncertain | **Fixed** §5.13 (`Row.headRecord`/`headRevision`/`headerWord0` defined; `LensReader.resolveRecord`), §12.3 row restated as one call after a page, two dependent calls cold. |
| consumer-sdk-portability#12 | confirmed | **Fixed** §3.1 L2/L4, §4.1, §5 preamble: `Layout` in `core/layout/` outside the closure; `vectors/layout.json` + TS twin; `FilesTypes.sol` generated in `profiles/`. |
| consumer-sdk-portability#13 | confirmed | **Fixed** §5.14 `Keys` (every domain enumerated; changed derivations named as changes), §5.8 `roleScopeKey`/`postingKey`, §10.2 family names, §4.2 limits words in state, §13 `ids.json`, S0 one-way-doors list. |
| index-replay-coverage#1 | confirmed | **Fixed** (same as kernel#2/upgrade#2) §10.4, §6.4–6.5, I11, §8.10 (repricing after freeze shifts floors only). |
| index-replay-coverage#2 | confirmed | **Fixed** §10.6 (APPEND families built ascending into fresh stores; BITMAP families `backfill(family, scope, expectedThrough, maxEntries)` over `[through, liveFrom)`, OR-only for MONOTONE families and current-head reads for CURRENT_STATE families; no per-scope slots after `d`; `writers` history), §10.2 rows 17–18, §8.7, §16.3 index (both mask/backfill interleavings), §16.5 #4 (interleaved withdrawals). |
| index-replay-coverage#3 | confirmed | **Fixed** §10.1, §3.1 rows 9–12, §4.6 (no shadow heads; `targetKind` in admission rows), §19 E4, decision 10 — the claims are now true by construction; heal path priced in §10.6. |
| index-replay-coverage#4 | confirmed | **Fixed** §5.11 (`occurrencesOf`, `postingHeadOf`/`postingSliceOf` keyed by preimage with `synthesized`; raw `postingHead` documented as an oracle getter), §10.2 row 12 (synthesis valid only at genesis-`COMPLETE` and `IDLE`). |
| index-replay-coverage#5 | confirmed | **Fixed** §5.11 `DigestSpec`, §10.2 row 15 (gen 1 feeds sha256 from `files-content/1` word 5), §10.5 `coverageOfSpec`/`coverageOfDigest`, §12.3 AR/IPFS row. |
| index-replay-coverage#6 | confirmed | **Fixed** §5.13 (`DirectoryPage` with `startsAtOrigin`, `completeFromOrigin`, `selectedSoFar`, `inventoryPin`, `scanStatus`; listing-coverage law; continuation bound to `(queryHash, basis)`), §11, §16.2 #3. |
| index-replay-coverage#7 | confirmed | **Fixed** §5.11 `Effect/3` + refs array; the digest word read is the only extra ledger read and is priced (§10.3, §10.4, §14). |
| index-replay-coverage#8 | confirmed | **Fixed** (same as upgrade#5) §8.3 step 5h, §5.11; `test/index/Build.t.sol::test_unrelated_activation_during_candidate_build_does_not_invalidate_it` in §16.3. |
| index-replay-coverage#9 | confirmed | **Fixed** §10.6 tolerance rule in the callback profile; final hooks limited to write-once facts (lint + fuzz); §16.1 `CoreIndexReplay` with a stricter gen-2 validator. |
| index-replay-coverage#10 | confirmed | **Fixed** (same as consumer#6) §4.6, §10.2 row 18, §11. |
| index-replay-coverage#11 | confirmed | **Fixed** I9 restated (§2.1), §10.5 (prefix-`COMPLETE` with phase; EquipmentRule ported), §5.10 (`ctx.ledger`, `ctx.index`). |
| types-registry-rules#1 | confirmed | **Fixed** §9.2 (`ruleInitcodeHash`), §9.3 (deterministic instance via CREATE2 salt 0; idempotent front-run; what pinning does not prove), §9.2 byte 5 (class 3 accepted; classes 4–5 reserved; disclosed as a claim), S6/S16 (`CodeScan` at every EFS pin), §16.1 squat tests generalized. The binding-signature alternative for grade 3 is not needed. |
| types-registry-rules#2 | confirmed | **Fixed** §5.10 (`ctx.ledger` required equal to `msg.sender`; `RefHeader` 3 words with `refHeaderWords`), §5.3 (Etched read profile), §3.2 ladder (no getter removal), §16.1 (twenty cases listed; fake-ledger test rewritten). |
| types-registry-rules#3 | confirmed | **Fixed** §6.4 (`E_ACCEPTOR_GAS` typed, incl. the wrapper's `EXHAUSTED` word for nested exhaustion, §5.10; `validationGas` a declared minimum, forwarded fully), §9.2 (0 = closure constant 300,000), §4.2/§5.1 (neither `acceptorGasMax` nor `acceptorGasDefault` exists in `Limits`), §6.2 (effective value folded), `ONE-WAY-DOORS.md` repricing exposure, Q21. |
| types-registry-rules#4 | confirmed | **Fixed** (same as size#9) §9.2, §3.1 row 8, §13 vectors. |
| types-registry-rules#5 | confirmed | **Fixed** §9.1–9.3 (byte 1 `wrapperVersion` u8 everywhere; `ruleId` = header `ruleCodehash`; `activateWrapper` reads the wrapper's own constants), §9.1 Q1 deadline in `ONE-WAY-DOORS.md`. |
| types-registry-rules#6 | confirmed | **Fixed** (same as kernel#5/upgrade#10) §9.4, S6, §16.3 registry. |

Counts: 66 findings — 64 confirmed (all fixed; one fixed in part with a recorded overrule on the headline, size#2), 1 uncertain (fixed), 1 refuted (refutation upheld, the residual inconsistencies fixed anyway), plus the verifier's own residual on consumer#3 recorded. No required behavior or ruling was weakened: the ruled families, mandatory indexing, the content-hash lookup, developer validation, ruling 3, ruling 21, K10, the Etched identity rules, PM behaviors 1–5 and the founder's "upgradeable until testing ends, then immutable" mandate are all carried, and three of them (content-hash lookup, ruling 21, retry identity) are satisfied by mechanism, not merely claimed.

---

## 24. Check record (every issue from the consistency and completeness checks, and what changed)

The two checks (`D/check-consistency.md`, `D/check-completeness.md`, both 2026-10-20) were run against the previous revision of this text. Dispositions: **fixed** (the text changed; sections named), **fixed by deferral** (the item is moved out of the stated scope and the gap is stated, never relabelled), **recorded** (a question for James). No required behavior was weakened and no prototype shortcut was promoted to a requirement.

| # | Issue (severity, source) | Disposition |
|---|---|---|
| 1 | Live index stores accept writes from an unauthenticated "candidate generation"; sections contradict each other (**blocking**, consistency B1; completeness #4) | **Fixed.** §4.6: three-clause writer rule — attached stores accept only `ledger.index()` (live while `phase != IDLE`; backfill while `IDLE`), an unattached fresh store only its constructor-named `INITIAL_WRITER` for its constructor-fixed `FAMILY_IDS`, the right lapsing at the first live write (lazy attachment appends to `writers`); the "no writers entry" clause deleted. §10.1: a fresh store for any new family set. §5.11: the store write ABI (`append`, `release`, `appendBatch`; `appendScopeEntry`, `setBit`, `stamp`, `openCoverage`, `backfillOr`, `backfillSet`, `retireCoverage`) under a snapshot-tested `STORE_ABI_ID`. §2.2 S4 and S18 (new row and test), §8.7, §1.2 Q7, §3.1 rows 10–12, §8.11, §16.2 #2, §16.3 index, §20 decision 10 aligned. |
| 2 | §3.2 kernel line items sum to 16,210 B, not 14,200 B (important, consistency I1) | **Fixed.** §3.2 restated: nominal ≈ 16,400 (16,410 with the hot-read and lazy-emit additions), pessimistic ≈ 18,900; rung 1 the expected C1 outcome; §3.1 row 1, §15 (23.1 % headroom), §14 genesis and per-upgrade rows, §18 risk 1 (fallback re-derived as moving the loop into `LedgerApply`, not the publish arm back) and §23 size#2 re-stated. |
| 3 | `RevisionRow.w0` overflows 256 bits (important, consistency I2) | **Fixed.** §4.3: `indexGeneration` moved to `w6` (`index u160@0 \| indexGeneration u32@160`); `w0` ends at bit 232 with `reserved u24@232`. |
| 4 | Revision row omits `limitsProfileId` although `executionSet` hashes it (important, consistency I3) | **Fixed.** §4.3: `w21 limitsProfileId`, `w22–w23 limits0/limits1` (historical floors and maxima readable from state), `w24 noticePrincipal`; the row is 25 words in §3.2, §4.1, §8.3 step 5i and §14; §5.7 `Revision` carries `limitsProfileId`, `limits`, `noticePrincipal`. |
| 5 | `inlineWordMax = 256` does not fit `u8` (important, consistency I4; completeness #15) | **Fixed.** §4.2 and §5.1: `uint16 inlineWordMax`; `limits0` repacked; every S1 value vector-checked against its width (`vectors/limits.json`). |
| 6 | `acceptorGasDefault` still a Realm `Limits` field (important, consistency I5; completeness #15) | **Fixed.** Deleted from `Limits` and `limits0` (§4.2, §5.1); `maxDescriptorBytes` deleted likewise, `DESCRIPTOR_MAX = 4,096` and `ACCEPTOR_GAS_DEFAULT` named as closure constants; §23 types#3 disposition says so. |
| 7 | Freeze ceremony omits `registry.activate`, so it always reverts (important, consistency I6; completeness #1) | **Fixed.** §8.10 rewritten in order: pre-checks (nine, incl. capability and limit supersets and the lane-canary count), §8.3 step 0, steps 1–3, `registry.activate(finalSet.revision)` **before** `ledger.freeze`, `ledger.freeze` (5a–5j, flag b0, `frozen := 1`, 5k), step 6, one canary per enabled lane, renounces, zero owner, `Frozen` from the controller. §16.4 names `Freeze.t.sol::test_canaries_land_only_after_registry_activeRevision_advanced` and the post-freeze equality test. `freeze` takes `laneCanaries` (§5.12). |
| 8 | Transition rules cannot be enforced as written (important, consistency I7) | **Fixed.** §8.8, §4.2 +15, §8.3 step 5j, §5.5: `beginTransition` writes `lastTarget := target` (`E_TRANSITION_TARGET`: a target can be begun once, ever; aborted or expired targets are spent); gate `block.number ≥ max(cooldownUntil, previousDeadline + maxTransitionBlocks)`; `TransitionEnded(3)` emitted lazily by the next `beginTransition`/`activate`, which also sets the cooldown; §1.2 Q21, §16.4 and §20 decision 19 aligned. |
| 9 | Hot-ABI "superset" check cannot be computed from a keccak id; step mis-cited (important, consistency I8) | **Fixed.** §5.3: `SUPPORTED_HOT_ABI_IDS` (own id plus every served predecessor, snapshot-tested), `supportedHotAbiIds()`; §8.3 step 5g checks unit membership and that the new list contains the current list; §5.3 now cites step 5g; §16.3 evolution, §19 E16, §1.2 Q1 aligned. |
| 10 | Index coverage slots in two places (important, consistency I9; completeness #20c) | **Fixed.** Coverage slots live only in `BitmapStore` (§4.6); the generation holds `progress` and `buildFrontier` (§3.1 row 9, §4.1). |
| 11 | Kind-10 scope list has two homes; the "same `SSTORE`" stamp claim (important, consistency I10) | **Fixed.** The kind-10 scope list and its head live in `BitmapStore` (`scopeHead` with inline `entry0`, `scopeEntry` words); kind 10 dropped from `PostingStore` (§3.1 rows 10–11, §4.6, §10.2 row 10, §5.11 `appendScopeEntry`/`scopeEntry`/`scopeSlice`); the §14 placement row counts three `PostingStore` appends and one `BitmapStore` call, unchanged slot counts; `BitmapStore` size raised to 5,000 / 5,800 (§3.1, §15). |
| 12 | Genesis plan omits deployments and leaves a RealmIndex/IndexBuild cycle (important, consistency I11; completeness #3) | **Fixed.** §8.2 renumbered G1–G22 with every deployment (`IndexBuild/1`, the nine NATIVE rule instances and blobs, `FilesFinalValidator`) and post-checks; `IndexBuild` is a codehash-pinned delegate with no generation address (§3.1 row 12, §5.11, §10.1); genesis stores take `INITIAL_WRITER = 0`; later generations with fresh stores come from `IndexDeployer` (§3.1 row 24, §10.1, §15); `TypeRegistry.initialize` added to §5.9; `FilesFinalValidator` built in S1 (§17). |
| 13 | `BasisCommit` law says plans compare `registryMutations`, contradicting TR-03 (important, consistency I12) | **Fixed.** §5.1: plans compare `executionSet` and the acceptance profile; `registryMutations` is echoed only. |
| 14 | Signed-lane retry key depends on the domain separator (important, consistency I13; completeness #13) | **Fixed.** §5.8 splits `intentDigest` (chain-free, stored, the retry key) from `signingDigest` (EIP-712 over the cached domain, verified, never stored); §6.1 step 2, §6.2, §7.2, §16.2 #4, §16.4 and §23 kernel#1 aligned; I4 needs no exception. |
| 15 | Fixed gas ceilings remain: ERC-1271 300k, `prepare` 12M, "fixed stipends" (important, consistency I14) | **Fixed.** §6.2: `WALLET_GAS_FLOOR` (300,000) is a floor forwarded whole, with `E_GAS(0, …)` below it and `E_WALLET_GAS` (resubmit) on exhaustion (§5.6, §7.1); the 12M ceiling deleted (§6.2 heading); "fixed stipends" → "no stipends" (§5.3); I11, §0 and §20 decision 24 aligned. |
| 16 | Evidence retention: profile selection, `SignatureStore` pin and zero-write undefined (important, consistency I15) | **Fixed.** `Limits.witnessRetention` (§4.2, §5.1, §7.4); `SIGNATURE_STORE` an ingress-build immutable listed in `release.json` and `dependencyRoot` (§3.1 row 22, §5.15, §7.4); the zero-write exception stated in I3, S5 and §6.2 and allowed by name in the state-diff test. Q5 keeps the per-intent opt-in question. |
| 17 | M1 acceptance includes tags, but no tags Type is defined (important, consistency I16; completeness #7) | **Fixed by deferral.** Tags moved out of C2 to S3 (§12.3, §12.4, §17 S3); the D-B/D-E gap and the ≈ 5× cost of the generic BIND path stated and put to James as Q32. |
| 18 | Grade 2 (CUSTOM) unscheduled; `AcceptContext` fields have no source (important, consistency I17) | **Fixed.** Grade 2 built in S1 (§17; the five custom-grade canaries cited in §16.3); `TypeInfo` gains `custom` and `bindingId` (17 fields, §5.9), so `validateLeaf` fills `AcceptContext` without a `binding()` call; `customAbi` enumerated (§4.5). |
| 19 | S6/S16 require the ledger implementation to have no `DELEGATECALL` (important, consistency I18) | **Fixed.** "implementation" removed from the S6 and S16 scan lists; the two proxied implementations are codehash-pinned and `upgrades-core`-validated, never scanned (§2.2, §8.3 step 5g). |
| 20 | `publicationAt` written as a pair but stored as one `u48` (minor, consistency M1; completeness #20b) | **Fixed.** §6.3 writes the ordinal only; §6.1 step 3 reads `w3`; §5.3 notes the two-`SLOAD` getter. |
| 21 | `Prepared` lists 22 fields but is 21 words / 672 B (minor, consistency M2) | **Fixed.** `reserved` dropped; the struct is declared in §5.15 (21 words, 672 B); §6.2 aligned. |
| 22 | `E_GAS` and `E_INDEX_GAS` both claim the final-reserve shortfall (minor, consistency M3) | **Fixed.** §5.6 `E_GAS` row no longer names the final phase. |
| 23 | `Frozen` cataloged as a kernel event but needs the canary ordinal (minor, consistency M4) | **Fixed.** `Frozen` is a controller event with `canaryPublications[]` (§5.12); removed from §5.5 and the §3.2 events row. |
| 24 | Enum-like fields with no value vocabulary (minor, consistency M5) | **Fixed.** `Readiness.ready` separate from `phase` (§5.11, §8.3 5h, §10.5); `creatorKind` (§4.3), `scanStatus` (§5.13), `FamilyEntry.kind`/`liveSemantics` (§5.11), `customAbi` (§4.5), `DigestSpec.algorithm` (1 = sha256; §10.2), `replayStage`, `coverage.state`, `buildFrontier.state` (§4.6) enumerated with 0 reserved. |
| 25 | Some §14 rows do not follow the §4 slot model (minor, consistency M6) | **Fixed.** Staged-save row regenerated (≈ 246 fresh / ≈ 242 rewrites, ≈ 8.3M, evidence paid once) and §12.2 reconciled (≈ 0.40M marginal per edit); genesis row recounted (≈ 170 KB, 42 accounts incl. the tenth validator and nine blobs); policy activation shows two rewrites; activation/freeze/upgrade rows re-priced for the 25-word row and the 16.4 KB kernel. |
| 26 | Invariant and register tests not traceable by id; some named tests missing (minor, consistency M7; completeness #17) | **Fixed.** I-id → test table in §16.5; S8, S12, S14 tests named in §2.2; the index#8 test named in §16.3 and §23; §16.2 retitled (six items, every one with `file::function` names, S2/S2b sub-cases tagged); the I5 selector-surface test added (§2.1, §16.6). |
| 27 | Stated widths and saturation thresholds disagree (minor, consistency M8) | **Fixed.** §4.1: ordinals 48-bit/`uint64`, revisions `uint32` everywhere, transition block numbers `uint48` in storage and ABI; one saturation threshold, 2^48 − 64. |
| 28 | I1 and §4.1 omit writers of the realm namespace (minor, consistency M9) | **Fixed.** `beginTransition`/`abortTransition` (transition word) and `initialize` added to I1 and the §4.1 table. |
| 29 | Name and ABI drift across sections (minor, consistency M10) | **Fixed.** `acceptOwnershipAndActivate` in I5; `principalsOf` only on `LedgerReads` (§3.1 row 5); `readers()` returns `physicalProfiles`; `IReader`, `IDescribedWrapper`, `IDescriptorStore`, `ISignatureStore`, `ILedgerIngress`, `ILedgerApply` declared (§5.13, §5.15); `EfsNative.nextNonce` via `ILedgerHot`; S2's `tx.origin` statement made exact (classification only, never authority); the declarations row added to §4.5; the genesis wildcard role rows deleted (§12.1); the `ScopeKey`/`PostingKey` split stated (§5.11) with `postingKey = Keys.posting(typeId, kindOf(family), uint8 ordinal, value)` (§5.8). |
| 30 | Which unit performs which per-leaf check is unclear (minor, consistency M11) | **Fixed.** §6.4 names the unit per check (kernel: `typeInfo`, body checks, REUSE header, `roleExpectation`; ingress: `validateLeaf`; apply: `applyLeaf`); §5.6 "thrown by" column corrected; the §6.2 "Both" bullet corrected. |
| 31 | `readSetHash` never defined (minor, consistency M12) | **Fixed.** §5.8: `readSetHash = keccak(abi.encode(rs)) = guardHash` for every accepted guarded publication; §4.4 and §16.5 #10 no longer need the preimage for digests. |
| 32 | Reasons and labels that need outside context (minor, consistency M13) | **Fixed.** §1.2 rows 12, 14, 16, 20, 23 state their reasons; F13, T2 and D1 expanded in place (§5.7, §8.7, §3.2); §23 size#2 names the finding's own ladder. |
| 33 | Posture-B test has no mechanism; a migrated controller reports itself frozen (minor, consistency M14) | **Fixed.** The posture-B test is conditional on Q3 (§16.3); only backfill continues after the freeze (§8.10); `migrate` sets `retired` (`E_RETIRED`), `frozen()` stays false (§5.12, §8.5, §3.1 row 15). |
| 34 | Genesis numbering and the constructor-`CREATE` claim (minor, consistency M15) | **Fixed.** §8.2 renumbered G1–G22; §15 names the three constructor `CREATE`s (`RealmGenesis.run()`, `IndexDeployer.run()`, the OZ proxy's `ProxyAdmin`). |
| 35 | Cold-pin row lists 9 calls but promises ≤ 8 (minor, consistency M16) | **Fixed.** §12.3: ≤ 9 on the first pin of a release digest, ≤ 4 afterwards (code hashes cached per release digest); §23 consumer#5 aligned. |
| 36 | Repository import gate forbids the design's `Layout` importers; S0 item stale (important, completeness #2) | **Fixed.** §17 S0 amends `checks.mjs` (`:91`) with a path allowlist for `core/layout/` from `index/` and the two facets; the stale src-empty/`ipfs` item replaced (`:34` already asserts `"none"`); §3.1 L2 and §4.1 state the allowlist. |
| 37 | OR-only backfill can resurrect bits a live hook cleared (important, completeness #5) | **Fixed.** `liveSemantics` for BITMAP families: MONOTONE (OR from write-once rows) or CURRENT_STATE (bits derived from the current head at backfill time; `backfillSet`); family 17 and 18 are CURRENT_STATE; both interleavings named tests in §16.3; §10.2, §10.6, §5.11, §23 index#2 aligned. |
| 38 | AR/IPFS row has no Type; a later digest spec cannot be added (important, completeness #6) | **Fixed.** `files-external/1` defined in §12.1 (the prototype's shape, `L/test/FilesExternalContentProfile.sol:11-40`) and its `DigestSpec` in the gen-1 manifest (§8.2 G19, §10.2 row 15); registered at S1b inside C2 (§12.3, §12.4, §17); a later spec rebuilds family 15 ascending into a fresh store (§10.6). |
| 39 | No reproducible-build gate although Type identity is a rule codehash (important, completeness #8) | **Fixed.** §16.6 CI gate (two clean, network-disabled rebuilds, every runtime and initcode hash compared with `release.json`); gates S1b registration (§17); `release.json` carries the attestation and a `BuildPlatformDescriptor` (§13). |
| 40 | Constitution freeze traces unmapped; signed lanes record no submitter (important, completeness #9) | **Fixed.** §16.7 trace → mechanism → test → stage table, a C4/C5 precondition (§17); evidence `w10 submitter` on signed lanes (§4.3, §5.7 `Evidence.submitter`, §6.3, §7.1, §7.3; +1 fresh slot in §14); the beneficiary-plan and 1/8/32/64-principal tests named; the Locator mapped to `files-external/1` with the large-content remainder staged. |
| 41 | Questions for James incomplete; Q15 has no recommendation (important, completeness #10) | **Recorded.** Q15 given a recommendation; Q26–Q33 added (non-atomic saves, cost envelope and venue, registry self-report residual, Lens defaults and seed principal, Devcon scope, Types as rows or Records, tags and D-E, freeze-trace waivers). |
| 42 | No populated upgrade in the M1 acceptance; C2's behavior-5 gate undefined (important, completeness #11) | **Fixed.** §12.3 populated-upgrade row; the C2 gate named as a §16.4 subset; §16.2 #5 and §17 C2 aligned. |
| 43 | M1 root directory, seed and home pointer unspecified (important, completeness #12) | **Fixed.** §12.2 Root recipe (the seed, by the fixture principal); `efs-deployment/1.root` and `defaultLensPrincipals` (§13); §8.2 G22; §12.3 root-and-home row with a cold client listing; the seed principal's future form is Q29. |
| 44 | `E_ACCEPTOR_GAS` cannot classify nested predicate exhaustion (minor, completeness #14) | **Fixed.** The wrapper's reserved `EXHAUSTED` word (§5.10), mapped by the kernel to `E_ACCEPTOR_GAS` (§5.6, §6.4); grade-2 test in §16.3 ingress and §16.2 #1; §23 types#3 aligned. |
| 45 | Post-freeze successor authority and terminal-set liveness for non-native lanes (minor, completeness #16) | **Fixed.** `noticePrincipal` (realm +17, `ActivationSet`, revision `w24`, hot read) checked by `RealmNoticeRule` for `successor` kinds, the controller's principal for `frozen`/`migration` (§12.1, §8.10); freeze pre-checks (7)–(9) require capability and limit supersets and one canary per enabled lane (§8.10). |
| 46 | Workflow measurement rows omit response sizes, cold/warm and large-directory traversal (minor, completeness #18) | **Fixed.** `gas/report.json` columns (§13) and the §12.3 large-directory row. |
| 47 | Per-leaf memory reuse (size#4 item 4) not carried (minor, completeness #19) | **Fixed.** §6.4 memory discipline (one reused scratch region per leaf, preallocated `Effect[]`/`refs`), a C1 memory-expansion row at 64 leaves (§15); §23 size#2 notes the carry. |
| 48 | Smaller contradictions: `postingKey` vs the committed `Keys.posting`, the `(FOLDER, *) → ANY` row, HEAD validity, uncited "as measured" rules (minor, completeness #20) | **Fixed.** `postingKey` defined as `Keys.posting(typeId, kindOf(family), uint8 ordinal, value)` with vectors (§5.8); the genesis role rows deleted and HEAD target validity stated as reader-side (§12.1); every "as measured" Files rule cites its prototype source, and the 1,477-byte validator cites the naming reconciliation (§12.1). |
