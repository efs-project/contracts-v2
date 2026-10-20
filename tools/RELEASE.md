# Release, deploy plan and local fixture (design slice S1b.3)

This is the release and deployment surface the SDK consumes (design §13, §8.2, §12.3 "deploy locally", "cold pin",
"root and home"). It is a **local fixture release**: it has not been reviewed or published, and the fixture key is
public. Run everything from the repository root under Node 24.21.0 (`eval "$(fnm env)" && fnm use 24.21.0`).

## Commands

```sh
# 1. the identity build (default profile: prague, via-IR, bytecode_hash = "none") and the double build with ASTs
perl -e 'alarm 600; exec @ARGV' forge build
FOUNDRY_OUT=out/release-ast FOUNDRY_CACHE_PATH=cache/release-ast perl -e 'alarm 900; exec @ARGV' forge build --ast

# 2. the release manifest, error catalog and artifacts/ (runs `forge script script/Genesis.s.sol` as a cross-check)
node tools/release.mjs

# 3. the offline genesis plan
node tools/deploy-plan.mjs            # [--chain-id 31337] [--realm-salt 0x…] [--out deploy/plan.json]

# 4. the fixture: an owned anvil, genesis, registration, seed; then the checks; then stop it
node tools/efs-fixture.mjs up         # [--port 8560] [--chain-id 31337] [--realm-salt 0x…] [--ttl 900]
node tools/efs-fixture.mjs verify     # exit 1 on any mismatch
node tools/gas-report.mjs             # [--skip-amsterdam 1]; reads the fixture's receipts if it ran
node tools/efs-fixture.mjs down
```

The order matters: `up` copies `sha256(release/release.json)` into the deployment document and `verify` re-hashes
the file, so regenerating `release.json` after `up` makes `verify` fail until the next `up`.

`package.json` is unchanged: `tools/README.md` documents tools that have pnpm scripts but does not state a rule for
adding one. If wanted, the obvious names are `release`, `deploy:plan`, `fixture:up`, `fixture:verify`,
`fixture:down` and `gas:report`.

### Process rules

- `up` refuses port 60742 (another agent's anvil) and any port that is already listening, and refuses to start
  while `release/.anvil.pid` names a live process. It runs `perl -e 'alarm <ttl>; exec @ARGV' anvil --port … --chain-id
  … --hardfork prague --disable-default-create2-deployer`, so the pid file holds anvil's own pid and the watchdog kills
  it after `--ttl` seconds (default 900) even if `down` never runs.
- `down` kills only the pid in `release/.anvil.pid`, and only after `ps` confirms that the process is `anvil`.
- `release.mjs` and `gas-report.mjs` run forge through `perl -e 'alarm 900; exec @ARGV'` with a Node timeout as well.
  The amsterdam run writes `out/amsterdam` and `cache/amsterdam` and never touches the identity `out/`, because
  `[profile.amsterdam]` does not set its own `out`.

### The fixture key

The fixture key is anvil's default account 0 (`0xf39F…2266`; its private key is printed by every `anvil`). It is the
controller owner, the declaration key of the nine Files Types and the seed principal. Never use it with value.
`~/.env` is never read.

### The factory

`up` starts anvil with `--disable-default-create2-deployer`. It then funds `0x3fab…5362` and submits the public
presigned pre-EIP-155 transaction of Arachnid's deterministic-deployment proxy. That transaction creates
`0x4e59b44847b379578588920cA78FbF26c0B4956C` with codehash
`0x2fa86add0aed31f33a762c9d88e807c475bd51d0f52bd0955754b2608f7e4989`, and the deployment document records
`factory.method = "presigned-tx"`. If a node refuses an unprotected transaction, `up` falls back to `anvil_setCode`
with the same runtime and records `"anvil_setCode"`. The runtime is read from the presigned transaction itself
(14-byte prologue, then 69 bytes), not from `test/harness/doubles/Factory.sol`, whose constant is wrong (see
HARNESS-BUG below).

## Files

| Path | What it is |
|---|---|
| `tools/deploy-plan.mjs` | Library and CLI. Computes the whole §8.2 plan offline from `out/`: every CREATE2 address from its initcode, `RealmGenesis` and its nonce-1/2/3 creations, the ProxyAdmins (`CREATE(proxy, 1)`) and every runtime codehash, with immutables filled at their offsets. It also holds a JS twin of `src/profiles/FilesTypes.sol` (descriptors, Type ids, EIP-712 declaration signatures), the index manifest hash, `limitsProfileId`, `domainSeparator`, the execution set, the seed actions and a small schema validator. |
| `tools/efs-fixture.mjs` | `up` / `verify` / `down` (above). |
| `tools/release.mjs` | Writes `release/release.json`, `release/errors.json` and `artifacts/`. |
| `tools/gas-report.mjs` | Writes `gas/report.json`. |
| `script/Genesis.s.sol` | Simulation only, never broadcast. `profile(address key)` deploys the nine rules, `RefuseAllPolicy` and `FilesFinalValidator` through the factory in forge's EVM and returns `FilesTypes`' descriptors and ids. `release.mjs` requires the JS twin to match it byte for byte. |
| `deploy/plan.json` | `efs-deploy-plan/1`: 49 steps (F0, G1–G22), each with kind, contract, address, initcode hash, constructor arguments, runtime codehash, calldata hash and post-check, plus the predicted addresses, realm ids, the genesis activation set with `expectedExecutionSet`, the index manifest, the nine Type ids and descriptors, the seed and `planHash`. |
| `release/release.json` | `efs-contracts-release/1` (design §13). It records the source commit, tree and dirty count; toolchain pins (`bytecode_hash = "none"`, CBOR trailer kept); the build platform; double-build reproducibility (28/28 units with identical runtime and creation code across `out/` and `out/release-ast`); sha256 of all 79 source files the units compile from; and, per unit, `runtimeHash` (immutables zero), `deployedBytecodeHash` (planned immutables), `initcodeHash`, `initcodeWithArgsHash`, address, named immutable offsets (empty for every `profiles/` contract, which is asserted), sizes and budgets. It also covers the profile (nine Types with shape, descriptor, ruleId, instance, blob and declaration signature; `RefuseAllPolicy`; the index manifest, families, units, digest specs, work model and stores), `limits`, `layoutId`, `hotAbiId`, `statusVocabularyId`, store ABI ids, index profile ids, the consumer pragma floor, privileged roles, the error-catalog pointer and hash, the ABI pointers and the vector hashes. Digest = `sha256(file)`. |
| `release/errors.json` | `efs-errors/1`: 104 file-level errors from `src/`, each with selector, signature, args, source, retry class (the first word of the trailing comment) and meaning. Every selector in `test/snapshots/abi/Errors.json` is reproduced. |
| `artifacts/<Unit>.json` | `efs-artifact/1` per deployable unit: ABI, method identifiers, creation and runtime bytecode, named immutable offsets. `LedgerCore.json`'s ABI is the union of the kernel ABI with the events and errors of `LedgerApply`, `LedgerIngress` and `LedgerControl`. Interface ABIs are not copied: `abi.interfaces` points at `test/snapshots/abi/` (tools/abi-snapshot.mjs), and storage layouts at `test/snapshots/layout/`. |
| `release/efs-deployment.json` | `efs-deployment/1` (design §13). It records the release digest, plan hash, chain id, `realmId`/`realmOrigin`/`realmSalt`, the factory and how it was deployed, the genesis address, nonces and tx/block, the activation (revision 1, execution set, tx, full set), the layout and hot-ABI ids, the profile id, limits and `limitsProfileId`, the domain separator and `noticePrincipal`. It covers the controller (owner, pending owner, frozen); both proxies (live implementation slot, ERC-1967 admin, `ProxyAdmin.owner()`, the `_admin` immutable offsets, the initializer calldata); every contract with address, runtime hash, step and tx; the index (generation, manifest, obligations, stores, families, units, digest specs, work model); the Type ids and profile rows; privileged roles; readers (none listed); the seed (version and the three transactions with their actions and bodies); `root {directoryRecordId, subjectId, principalId}`; `defaultLensPrincipals`; the actors; an RPC hint; and the evidence grade `local-fixture`. |
| `release/expected.json` | `efs-fixture-expected/1`: the seed's post-checks (root, folder, file ids and binding keys, counts 11/5/3/3, the three heads, five records, catalog count 9). |
| `release/.fixture.json`, `.anvil.pid`, `.anvil.log` | Fixture runtime state: rpc, pid, ttl, factory method, and the journal of all 50 transactions (hash, block, gasUsed). |
| `gas/report.json` | `efs-gas-report/1` (below). |
| `schemas/*.schema.json` | JSON Schemas (draft 2020-12) for the six documents above. `verify` validates every document present against them, using the subset in `deploy-plan.mjs validate`. They are drafts: `schemas/README.md` says release schemas land after review. |

## What `verify` reproduces

263 checks against the chain, recomputed from `out/` (and `release/release.json`'s immutable names when the AST
build is absent). Exit 1 on any mismatch; a tampered `expected.json` was tested and fails.

1. **Documents.** `planHash` (recomputed, and equal to `deploy/plan.json`), the ledger address, the execution set, the
   root, and `releaseDigest` against `sha256(release/release.json)`. All six documents are validated against
   `schemas/`.
2. **Code, byte for byte.** The factory runtime and its codehash. For the 25 units the plan deploys, the runtime is
   compared byte for byte with the artifact plus the planned immutables. Codehashes are checked for those 25, the 5
   `RealmGenesis` creations (controller, both proxies, both ProxyAdmins) and the 9 descriptor blobs.
3. **Genesis.** `controller()`, `registryProxy()` and `ledgerProxy()` equal the plan, `predict()` equals the plan,
   and a second `run()` reverts with exactly `E_GENESIS(0)` (checked by `eth_call`).
4. **Proxies and ownership.** Both ERC-1967 implementation and admin slots; both `ProxyAdmin.owner() == controller`;
   `controller.owner()`, `admins()` and `NOTICE_TYPE`; the registry's `ledger()`, `implementation()` and
   `activeRevision() == 1`.
5. **`describe()`.** Every field of `Description`, 68 comparisons including all 17 limits.
6. **`executionSet()`.** It equals the offline `expectedExecutionSet`, and a JS recomputation from the live revision
   row's `ComponentSet` (`LedgerReads.revisionAt`) equals it too. `domainSeparator` and `limitsProfileId` equal
   `describe()`.
7. **The index.** `manifestHash()` equals the offline manifest hash; `replayReadiness()` is ready, with families and
   units equal to the plan; `progress().lastProcessed` equals 11.
8. **The nine Types.** The catalog equals the offline id set. For each Type, `typeInfo` mandatory, ruleId, shape and
   blob; `descriptorBytes` equals the JS descriptor; `refTypes`; `declaration` (key and installed); and the published
   id.
9. **The seed.** Five record headers, three heads (state, revision, target), three subjects created, the fixture
   principal's nonce of 3, and both folder scopes (1 entry, 1 live).
10. **Cold pin.** What an SDK holding only `release.json` and `efs-deployment.json` does on first contact.

### Cold-pin call count (observed)

**7 logical calls in 2 HTTP envelopes**: `eth_chainId`, `eth_getBlockByNumber`, `eth_call LedgerReads.describe`,
`eth_getStorageAt(ledgerProxy, ERC-1967 implementation slot)`, then `eth_getCode` ×3 (implementation,
`LedgerReads`, `LedgerViews`). The design bound is ≤ 9 calls and ≤ 2 envelopes. It counts five `eth_getCode`; the
two readers (`LensReader`, `FilesPageReader`) are not in this tree, so 7 is 9 minus those two. `verify` checks the
chain id, the implementation, and each codehash against `describe()` and the release.

## The `executionSet()` offline equality proof

- **How it is computed.** `tools/deploy-plan.mjs executionSet(set, ledger)` hashes
  `keccak256(abi.encode(DOM_EXECUTION_SET, layoutId, domainSeparator(acceptedChainId, ledger), ComponentSet, uint256
  revision, executionProfileId, capabilities, acceptedChainId, keccak256(abi.encode(Limits))))` with viem's
  `encodeAbiParameters`. The `ComponentSet` and `Limits` tuple types come from the compiled ABI
  (`RealmController.activate`, `RealmGenesis.run`), not from hand-written types. This is the formula of
  `LedgerControl._activate` and `test/harness/ExecutionSets.sol`.
- **Inputs.** Every component codehash is computed offline from the artifact runtime with immutables filled. That
  covers the ledger implementation, the registry implementation, the index (whose manifest hash is also computed
  offline), ingress, apply and the controller (whose immutables are the nonce-derived proxy and admin addresses).
- **Where it is asserted.** First, on chain: G20 passes `expectedExecutionSet` into `RealmController.activate`, and
  both `LedgerControl` and the controller revert with `E_EXPECTED_SET` on any difference, so the genesis activation
  landing is itself the proof. Second, in `up`: `ledger.executionSet()` must equal the plan. Third, in `verify`: the
  live value must equal the plan, and a recomputation from the on-chain revision row's components must equal the
  live value. On the default fixture (chain 31337, salt `keccak256("efs2/fixture/realm/1")`) the value is
  `0x673d4b45…912b6d`.

## Gas rows written (`gas/report.json`)

`test/integration/FilesRecipes.t.sol` logs `<label> gas` (the `gasleft()` delta around `execute`, so no intrinsic
cost), `<label> frame gas` and, under amsterdam, `<label> frame state gas`. These are machine-readable through
`forge test --json -vv` (`decoded_logs`). The runner executes the suite under the default (prague) profile and under
`--profile amsterdam` (`out/amsterdam`). The rows below are prague and amsterdam gas, then amsterdam state gas:

| §14 row | prague | amsterdam (state) |
|---|---:|---:|
| Root seed (CREATE + PUBLISH directory) | 769,256 | 2,710,108 (2,154,240) |
| Native 1-leaf PUBLISH (32 B directory body, steady author) | 578,120 | 1,769,958 (1,272,960) |
| M1 create folder (first placement in root, fresh scope) | 1,391,205 | 4,864,205 (3,818,880) |
| M1 create file (5 leaves, fresh folder) | 1,669,939 | 5,854,065 (4,602,240) |
| Edit | 890,351 | 2,801,025 (2,056,320) |
| Rename / move | 1,079,612 | 3,378,054 (2,448,000) |
| Remove | 445,671 | 1,197,698 (783,360) |
| Restore (masked → same target) | 487,069 | 1,253,629 (783,360) |
| RELEASE from mask | 409,249 | 1,073,389 (685,440) |
| RELEASE from BOUND (not a §14 row) | 428,836 | 1,100,176 (685,440) |
| Restore a released placement (Move-back analog) | 501,935 | 1,349,182 (881,280) |
| WITHDRAW | 409,230 | 1,160,902 (783,360) |

The report also carries 27 supplementary recipe steps and the fixture's 50 transaction receipts, which are prague
only and include intrinsic cost:

- Genesis code deposit: 43.3M over 26 transactions.
- The nine descriptor blobs: 1.23M.
- **Genesis activation: 4.15M**, against the design estimate of ≈ 1.1–1.9M (a finding, not a failure).
- `registerDescribed`: 0.24–0.27M each (design ≈ 0.30M).
- Seed: root 0.76M, folder 1.39M, file 1.66M.

## KERNEL-BUG

None found in `src/`. Genesis, activation, registration and seed all ran as specified, and every predicted address
and runtime hash matched the chain.

**HARNESS-BUG (test/, not src/).** `test/harness/doubles/Factory.sol` `RUNTIME` is 70 bytes; the canonical runtime is
69. The constant has one extra `ff` inside the leading `PUSH32` (32 `ff` bytes, then `e0`, where the canonical form
is 31 `ff` bytes then `e0`). Etched, the code would push `2^256−1` and then execute `0xe0`, an undefined opcode in
legacy code, so every factory call would revert.

The suites pass anyway because Foundry's test EVM pre-deploys the canonical factory at `0x4e59…956C`, so
`Factory.ensure()` never etches. It would surface in any environment without that default: a forked chain without
the factory, `anvil --disable-default-create2-deployer`, or a non-Foundry runner.

- **Reproduction.** `node tools/efs-fixture.mjs up && node tools/efs-fixture.mjs verify` prints
  `Factory.sol RUNTIME differs (70 bytes vs 69)`. The runtime the presigned transaction actually deploys hashes to
  the well-known `0x2fa86add…4989`.
- **Fix (for test/'s owner).** Delete one `ff`.

## DESIGN-DIVERGENCE

Where §8.2/§13 and the code disagree. The code is followed in every case.

1. **G1–G2: there are four kernel units, not three.** `LedgerCore(ingress, apply, control, hotAbiId)` needs a
   `LedgerControl(ingress, apply, predecessorLayoutId = 0)` delegate, which §8.2 does not list. The plan adds step
   **G2c**.
2. **G6: `DescribedTypeRule/1` is not deployed.** The file is untracked and still being written by another agent.
   Genesis passes `wrapperV1 = 0`, as `test/control/RealmController.t.sol` does, and the nine Files Types are all
   NATIVE, so no wrapper is needed. A later `controller.activateWrapper(1, wrapper)` adds it.
3. **G9: `IndexBuild/1` does not exist.** `RealmIndex` takes no build, `Readiness.build` is 0, and the plan has no G9.
4. **G13.** `LAYOUT_ID` is a compiled constant, not an immutable. `PREDECESSOR_LAYOUT_ID` is on `LedgerControl`.
   `SUPPORTED_HOT_ABI_IDS` is computed as `[HOT_ABI_ID]`. `LedgerCore` has no `SELF` immutable.
5. **HOT_ABI_ID.** §5.3 names a derivation (`keccak("efs2/ledger-hot/1" ‖ sorted selectors ‖ return layouts)`), but
   neither `src/` nor `vectors/` commits one. The release uses the suites' `keccak256("efs2/ledger-hot/1:test")`
   from `test/harness/KernelDeploy.sol` rather than inventing an identity. This needs a decision before any real
   release.
6. **G15: `RealmGenesis`' constructor differs from the design.** It is `(owner, ledgerImpl, registryImpl, realmSalt,
   executionProfileId, limitsHash, readerDirectory, wrapperV1, noticeType, controllerInitcodeHash, proxyInitcodeHash)`.
   It reads the implementation codehashes itself, takes the limits only as a hash, and receives the controller and
   proxy creation codes in `run(limits, controllerInitcode, proxyInitcode)`, pinned by hash. The plan follows this.
7. **G17: `BitmapStore` gets three families, not two.** The design lists `[scope, live-scope]`; the code and
   `test/harness/IndexDeploy.sol` use `[scope, roster, live-scope]` (roster is `NOT_MAINTAINED`). The plan follows
   the code.
8. **G19: `RealmIndex`' constructor differs from the design.** It is `(ledger, hotAbiId, decoder, posting, bitmap,
   units, specs, work)`, with no `layoutId` (a constant) and no build arguments, and it reads nothing from the ledger
   (§8.2 says it reads `counts()` and `layoutId()`). The plan passes the real G7 decoder; the suites pass
   `address(0)`.
9. **Work model.** `src/` has no release work model, so the index uses
   `test/harness/doubles/IndexDoubles.sol IndexDoubleDefaults.workModel()`. Limits come from `KernelDeploy.s1Limits()`
   (the §4.2 values).
10. **G3/G4/G7 take no arguments.** `LedgerReads`, `LedgerViews` and `IndexReplayDecoder` have the layout compiled in;
    they are not "generated for layoutId" by argument.
11. **Readers.** `LensReader` and `FilesPageReader` are absent, so the cold pin needs 3 `eth_getCode` calls, not 5.
    `ReaderDirectory` lists nothing: `LedgerReads` and `LedgerViews` are facets, not `IReader`s.
12. **§13 `fixture/`.** There is no `fixture/` directory, no forge-script-encoded seed transactions, no
    `EfsFixture.sol` and no Multicall3 etch, and there are no `--state-dir` or `--hardfork` options. The seed is
    encoded in JS (`EfsNative`-equivalent: both expectations bound through `executionSet()` and the ingress's
    `acceptanceProfileOf`) and recorded in `efs-deployment.json` `seed.transactions` and `expected.json`.
13. **Placement of `release.json`.** `schemas/` named no path, so the manifest is `release/release.json`. The six
    schemas are new, unreviewed drafts.
14. **Seed counts.** The seed produces 11 admissions, **5 records**, 3 bindings and 3 publications (the directory,
    name and root records; the CREATE leaves are subjects, not records).

## Not covered, and why

- **The §16.6 reproducible-build attestation ("two clean-rebuild hash sets").** The double build covers runtime and
  creation-code identity across two independent full compiles. `standardJsonInputHash` is `null` because the default
  profile emits no `build_info`.
- **`dependencyRoot`.** It is null: the freeze checklist that defines it does not exist yet.
- **§14 slot columns and `tx.gas` cases.** Fresh, rewritten and cleared slot counts, code bytes and accounts per row
  need a state-diff pass. `tx.gas` below and above 2^24 is not varied, and there are no amsterdam fixture receipts:
  release bytes under `anvil --hardfork amsterdam` would need the reservoir and `tx.gas` above 2^24 for the genesis
  code deposit.
- **Read rows** (pages, file reads, recovery, the 1,000-entry traversal). They need the absent readers.
- **`vectors/execution-set.json`, `manifest.json`, `hot-abi.json`, `names.json` and the other §13 vectors.** These are
  generator work for `tools/vectors.mjs`'s owner. `release.json` hashes the two vector files that exist.
- **The wrapper, the signed lane, guards, freeze and upgrades.** Out of S1b.3.
