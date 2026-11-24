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
node tools/deploy-plan.mjs            # [--chain-id 31337] [--realm-salt 0x…] [--out deploy/plan.json] [--artifacts DIR]

# 4. a fixture instance: an owned anvil, genesis, registration, seed, every verify check; then stop it
node tools/efs-fixture.mjs up --json          # prints its name, port and rpcUrl; see "The fixture" below
node tools/efs-fixture.mjs verify --name <n>  # exit 1 on any mismatch
node tools/gas-report.mjs --fixture <n>       # [--skip-amsterdam 1]; reads that instance's receipts
node tools/efs-fixture.mjs down --name <n>

# the committed sample release/efs-deployment.json + release/expected.json (default configuration only)
node tools/efs-fixture.mjs up --name sample --write-release && node tools/efs-fixture.mjs down --name sample
```

**The snapshot rule.** `release/`, `artifacts/` and `deploy/plan.json` are regenerated in the same push as any source
change (steps 1–3). `node tools/release.mjs --check 1` (`pnpm release:check`) writes nothing and fails when a committed
document is not the one the current build produces: `release/errors.json`, `artifacts/*.json` and `deploy/plan.json`
byte for byte, and `release/release.json` without the facts of the machine and the moment (`source`, `buildPlatform`,
`reproducibility`, `toolchain.foundry`, `toolchain.node`, `profiles.crossCheck`). CI runs it after the suites. With
an AST build (`out/release-ast`, locally) immutable names are read from that build; without one (CI) the names are
the committed manifest's, their offsets are checked against the build, and the fixture tests that follow read every
named immutable from a deployed instance.

`up` copies `sha256(release/release.json)` into the deployment document and `verify` re-hashes the file, so
regenerating `release.json` after `up` makes `verify` fail until the next `up`.

pnpm scripts: `release`, `release:check`, `plan`, `fixture:up`, `fixture:verify`, `fixture:status`, `fixture:list`, `fixture:down`,
`fixture:reset`, `fixture:gc`, `fixture:snapshot`, `gas:report`, `gas:model` and `test:tools` (the tooling tests; pass options after
`--`, e.g. `pnpm fixture:up -- --name mine --json`).

## The fixture: many instances at once

Any number of agents, in any number of checkouts and worktrees of this repository, the SDK and the client, can run
fixture instances at the same time. Each instance has a **name**, its own **lease** in one machine-wide **registry**,
its own **port** and its own **state directory**. Nothing an instance writes is a tracked file. Only blank local
chains are supported: no fork mode, no RPC keys.

### CLI

```text
node tools/efs-fixture.mjs up      [--name N] [--port P | --port-range LO-HI] [--chain-id 31337]
                                   [--realm-salt 0x… | --fresh] [--ttl 900 | --ttl 0 | --keep] [--no-unlocked]
                                   [--hardfork osaka|prague]
                                   [--state-dir DIR] [--artifacts DIR] [--plan FILE] [--no-verify] [--keep-on-fail]
                                   [--write-release] [--json]
node tools/efs-fixture.mjs verify  [--name N] [--documents DIR | --release] [--json]
node tools/efs-fixture.mjs status  [--name N] [--json]          # without a name: the same as list
node tools/efs-fixture.mjs list    [--kind chain|gateway|ui] [--json]
node tools/efs-fixture.mjs down    [--name N] [--purge] [--json]
node tools/efs-fixture.mjs reset   [--name N] [--fresh] [--chain-id N] [--realm-salt 0x…] [--ttl S | --keep] [--json]
node tools/efs-fixture.mjs gc      [--purge] [--json]
every command: --home DIR (the registry; default below)
```

| Flag | Meaning |
|---|---|
| `--name N` | `[A-Za-z0-9][A-Za-z0-9._-]{0,63}`, unique machine-wide. Default for `up`: `$EFS_FIXTURE_NAME`, else `<checkout basename>-<4 random hex>`, printed. Default for the other commands: `$EFS_FIXTURE_NAME`, else the one chain instance this checkout has leased (exit 2 if several, 4 if none). |
| `--port P` | Use exactly P; exit 3 when it is leased by a live process, bound by anything, or 60742. |
| `--port-range LO-HI` | Search range when no port is given; default 8600–8999 (the client's proposed gateway range 8546–8599 stays free). |
| `--chain-id N` | Default 31337. |
| `--realm-salt 0x…` / `--fresh` | The Realm salt (default `keccak256("efs2/fixture/realm/1")`) or a random one, so the Realm id is fresh. The plan stays computable offline per `(chainId, realmSalt)`: both are in the lease, the documents and the `up` JSON. |
| `--ttl S` / `--ttl 0` / `--keep` | The watchdog: anvil runs as `perl -e 'alarm S; exec @ARGV' anvil …` and dies after S seconds (default 900) even if nobody calls `down`. `0` or `--keep` runs anvil without a watchdog, for a dev session; the lease then has `expiresAt: null`. |
| `--no-unlocked` | Start anvil with `--accounts 0 --fund-accounts <the ten default addresses>:10000`: no unlocked accounts, the same funded addresses (alias `--no-unlocked-accounts`). See "Signing". |
| `--state-dir DIR` | Where the instance's pid, log, journal and documents go (default `<home>/instances/<name>/`). Only the files listed below are written or removed there. |
| `--artifacts DIR` | The artifact source (default `$EFS_ARTIFACTS_DIR`, else `out/`): a Foundry build, a snapshot (`tools/artifacts-snapshot.mjs`) or a committed `artifacts/` directory. See "Artifact sources". |
| `--plan FILE` | A `deploy/plan.json` the computed plan must equal (its chain id and salt become the defaults); exit 1 when the `planHash` differs. |
| `--no-verify` | Skip the in-`up` verify (see "Readiness"). |
| `--keep-on-fail` | When the in-`up` verify fails, keep the instance (lease state `failed`) for inspection instead of tearing it down. |
| `--write-release` | Also write the committed sample `release/efs-deployment.json` and `release/expected.json`. Only on the default configuration (chain 31337, the default salt) and this checkout's artifacts, else exit 2. This is the only way anything under `release/` is written by the fixture. |
| `--documents DIR` / `--release` | `verify` compares the chain with the documents in DIR (default: the instance's own); `--release` = this checkout's committed sample, which verifies against any default-configuration instance. |
| `--purge` | `down`: also delete the instance's state files. `gc`: also delete state directories no lease names. |
| `--json` | Exactly one JSON object on stdout (logs go to stderr), success or failure. |

`reset` is `down` then `up` under the same name, port, chain id, salt, TTL, signing mode, state directory and
artifacts, with `generation + 1`; `--fresh` picks a new salt and `--chain-id` a new chain (the client's reset policy
of a new chain id per reset is the caller's choice).

### Exit codes

| Code | Meaning | `error.code` values |
|---:|---|---|
| 0 | ok | |
| 1 | verification mismatch (`verify`, the in-`up` verify, `--plan`) | `VERIFY_FAILED`, `PLAN_MISMATCH`, `DOCUMENTS_MISMATCH` (verify alone returns `ok: false` with `failures`) |
| 2 | usage | `USAGE`, `BAD_OPTION`, `BAD_NAME`, `BAD_RANGE`, `BAD_PORT`, `BAD_PLAN`, `NOT_DEFAULT`, `AMBIGUOUS`, `NOT_A_CHAIN` |
| 3 | port or lease conflict | `PORT_LEASED`, `PORT_BUSY`, `PORT_FOREIGN`, `NO_FREE_PORT`, `NAME_LEASED`, `NOT_ANVIL_YET`, `IDENTITY`, `FOREIGN_HOST` |
| 4 | instance not found or dead | `NO_INSTANCE`, `INSTANCE_DEAD`, `NO_DOCUMENTS` |
| 5 | any other failure | `ARTIFACTS` (the plan cannot be built, e.g. stale `out/`), `ANVIL_START`, `SIGNER`, `UP_FAILED`, `REGISTRY_UNWRITABLE`, `FAILURE` |

With `--json`, a failure prints `{"ok": false, "command": "...", "error": {"code", "message", "exitCode", "details"}}`.

### Readiness

`up` deploys and seeds, writes the instance's documents, then runs **every `verify` check** against the new chain
(lease state `verifying`). Only when all pass is the lease marked `ready` and the one JSON object printed, carrying the
actual `port` and `rpcUrl` (also when the port was allocated from the range) and `verified: {skipped: false, ok, checks,
failures, ms, coldPin}`. If a check fails, `up` tears the instance down (its own anvil, its lease) and exits 1 with an
error object listing the failures; with `--keep-on-fail` the instance stays leased in state `failed`. Measured cost of
the in-`up` verify: about 0.8 s for 370 checks (the big file is re-assembled node by node); a whole `up` takes about
4–5 s. `--no-verify` skips it (`verified: {skipped: true}`). Both failure paths were exercised by hand against a stale
`deploy/plan.json` (one mismatch): the default tore the instance down and removed its lease; `--keep-on-fail` left it
leased in state `failed`.

### The `up --json` object

```json
{
  "ok": true, "command": "up", "name": "contracts-v2-e4d3", "kind": "chain", "generation": 1,
  "rpcUrl": "http://127.0.0.1:8600", "host": "127.0.0.1", "port": 8600, "chainId": 31337,
  "realmSalt": "0x06e8…710f", "realmId": "0x8383…e741", "layoutId": "0x61a4…484a", "pid": 6683,
  "stateDir": "<home>/instances/<name>", "deployment": "<stateDir>/efs-deployment.json",
  "expected": "<stateDir>/expected.json", "journal": "<stateDir>/fixture.json", "log": "<stateDir>/anvil.log",
  "ledger": "0x984B…3373", "registry": "0x…", "controller": "0x…", "keysView": "0xc50e…2f30",
  "web3Gateway": "0xd658…ea81", "web3Url": "web3://0xd658…ea81:31337/0x0000…f39f…2266/",
  "readers": { "ledgerReads": "0x…", "ledgerViews": "0x…", "readerDirectory": "0x…", "lensReader": "0x…", "filesPageReader": "0x…", "keysView": "0xc50e…2f30", "web3Gateway": "0xd658…ea81" },
  "root": { "directoryRecordId": "0x4bca…36ce", "subjectId": "0xbf64…2b34", "principalId": "0x…f39f…2266" },
  "seed": {
    "version": "efs-fixture-seed/2", "root": { "…": "as above" },
    "folder": { "name": "docs", "directoryRecordId": "0xec08…104a", "subjectId": "0xedf5…35ff" },
    "file": { "name": "readme.txt", "subjectId": "0x3883…40d1", "headRecordId": "0x1957…ccd7", "headRevision": 1 },
    "files": [
      { "name": "readme.txt", "subjectId": "0x3883…40d1", "headRecordId": "0x1957…ccd7", "headRevision": 1, "form": 0, "length": 18, "sha256": "0x0e7b…6df6" },
      { "name": "big.bin", "subjectId": "0x266b…622e", "headRecordId": "0x26af…c554", "headRevision": 1, "form": 1, "length": 20000, "sha256": "0xda46…efc9",
        "contentRecordId": "0xd41a…5771", "spanRootId": "0x00a5…d92e", "chunkCount": 3, "spanCount": 2, "chunkPayload": 8160, "publications": 2 },
      { "name": "remote.txt", "subjectId": "0x1049…03cf", "headRecordId": "0x2a39…1c1d", "headRevision": 1, "form": 1, "length": 51, "sha256": "0xf380…a9cc",
        "externalRecordId": "0xbebd…e727", "sentinelRecordId": "0x810e…f6e7", "locator": "web3://0x0000000000000000000000000000000000000000:31337/remote.txt" }
    ]
  },
  "typeIds": { "files-root/1": "0x…", "…": "one per Files Type" },
  "signerCapable": true,
  "capabilities": { "filesSeed": "efs-fixture-seed/2", "filesTypes": 10, "seedFiles": ["readme.txt", "big.bin", "remote.txt"], "largeFiles": true, "externalLocations": true, "keysView": true, "web3Gateway": true, "readers": ["efs2/reader/lens/1", "efs2/reader/files-page/1"], "signerCapable": true, "unlockedAccounts": 10, "hardfork": "prague" },
  "ttl": 900, "startedAt": "…", "expiresAt": "…",
  "planHash": "0x8a60…8cfc", "plan": null, "checkout": "/path/to/checkout", "artifacts": "/path/to/out", "artifactsMode": "forge",
  "registryHome": "<home>", "lease": "<home>/leases/<name>.json", "releaseWritten": null,
  "verified": { "skipped": false, "ok": true, "checks": 370, "failures": 0, "ms": 694, "coldPin": { "calls": 9, "envelopes": 2 } }
}
```

`verify --json` prints `{ok, command, name, rpcUrl, chainId, documents, checks, byGroup, failures, uncheckedDescribe,
harnessFactory, coldPin}`; `list --json` prints `{ok, command, registryHome, leases: [lease + liveness + expired]}`;
`status --json` `{ok, command, lease, rpc: {chainId, blockNumber}}`; `down --json` `{ok, command, name, port, stopped,
wasLive, purged, stateDir}`; `gc --json` `{ok, command, registryHome, removed: {leases, ports, files, stateDirs}}`.

### The registry

`<home>` = `$EFS_FIXTURE_HOME`, else `${XDG_STATE_HOME:-~/.local/state}/efs/fixtures`. Agents that should see each
other share it; a sandbox that cannot write `~` sets `EFS_FIXTURE_HOME` to a shared writable path (a registry that
cannot be created is exit 5 `REGISTRY_UNWRITABLE`).

```text
<home>/leases/<name>.json     efs-fixture-lease/1 (schemas/efs-fixture-lease-1.schema.json), one per instance
<home>/ports/<port>.json      efs-fixture-port/1: the claim {port, name, kind, pid, startTime, command, hostname}
<home>/instances/<name>/      a chain's default state directory:
    anvil.pid  anvil.log  fixture.json (journal of every transaction, read estimates, rpc call counts)
    efs-deployment.json  expected.json  up.json (the up result)
```

- **Atomic creation.** A lease and a port claim are each created with `open(path, "wx")` (O_CREAT|O_EXCL), so two
  processes can never both hold one name or one port. Updates by the holder are write-then-rename.
- **Holders and liveness.** A record names its holder as `(pid, startTime, command)`, as `ps -o lstart= -o command=`
  prints them under `LC_ALL=C`. It is `live` while that pid still has that start time (and command, once recorded),
  `dead` otherwise (a reused pid does not count), and `foreign-host` when another host wrote it (never judged, never
  broken). A chain lease's holder is the `up` process until anvil is spawned, then anvil itself.
- **Breaking stale records.** A dead record may be removed by anyone, serialized by `<record>.break` (also `wx`); the
  breaker re-reads the record under that lock and removes it only if it is unchanged and still dead, so a fresh
  record is never removed by a breaker that saw an older stale one. A breaker that dies leaves a `.break` that ages out
  after 10 s.
- **Port allocation.** `--port`, or the first port of the range that (1) has no claim held by a live process and (2)
  passes sequential bind probes on `::`, `0.0.0.0` and `127.0.0.1`. The claim comes first, then the probe, so two
  agents starting at the same instant get different ports (tested with 12 processes). anvil's own bind is
  authoritative: if anvil reports the address in use, an allocated port is released and the next one tried (up to 5
  times); an explicit `--port` exits 3. Port 60742 is never allocated or touched.
- **Kill rule.** `down` signals only the pid its lease records, only when `ps` shows that pid with the recorded start
  time and the recorded command line, and only when that command is `anvil … --port <the lease's port> …`. SIGTERM,
  5 s grace, SIGKILL. A dead or reused pid is never signalled; its lease is simply removed. Nothing is ever killed by
  port, by process name or by a bare pid. `gc` never signals anything.
- **TTL.** `expiresAt = startedAt + ttl`; the watchdog ends anvil then, the lease becomes `dead` and `gc` (or the next
  allocation of that name or port) removes it.

**Lease schema (`efs-fixture-lease/1`, a stable contract).** Required: `schema`, `kind` (`chain` | `gateway` | `ui`),
`name`, `state`, `generation`, `pid`, `startTime`, `owner {pid, startTime, user}`, `hostname`, `host`, `port`, `url`,
`ttl`, `startedAt`, `expiresAt`. A chain lease adds `command`, `chainId`, `realmSalt`, `realmId`, `layoutId`, `ledger`,
`registry`, `checkout`, `artifacts`, `artifactsMode`, `plan`, `stateDir`, `unlocked`, `signerCapable`, `deployment`,
`expected`, `journal`, `log`, `planHash`, `seedVersion`, `root`, `seed`, `capabilities`, `verified`, `readyAt`. Chain
states: `allocating` → `allocated` → `deploying` → `verifying` → `ready` (or `failed` with `--keep-on-fail`). Readers
check `schema` and ignore fields they do not know; a breaking change gets a new schema id.

### Library API (`tools/fixture-registry.mjs`, Node built-ins only)

```js
import { allocate, update, lookup, list, release, gc, up, down, verify, registryHome, EXIT, FixtureError } from "<contracts checkout>/tools/fixture-registry.mjs";

const lease = await allocate({ kind: "gateway", name: "wt1-gateway", range: [8546, 8599], pid: process.pid, ttl: 0, meta: { chain: "wt1-chain" } });
update("wt1-gateway", { state: "ready" });          // the holder only; a changed pid/startTime moves the port claim too
lookup("wt1-chain");                                 // lease + {liveness: "live"|"dead"|"foreign-host", expired} | null
list({ kind: "chain" });                             // every lease, oldest first, with liveness
release("wt1-gateway");                              // remove lease + port claim (kills nothing)
gc({ purge: false });                                // {leases, ports, files, stateDirs} removed; signals nothing

const r = await up({ name: "wt1-chain", portRange: "8600-8999", chainId: 3133701, fresh: true, ttl: 0, unlocked: false, artifacts: "<checkout>/artifacts", stateDir: "/tmp/x" });
await verify("wt1-chain");                           // {ok, failures, …}
await down("wt1-chain", { purge: true });
```

Every function takes `home` (default `registryHome()`). Errors are `FixtureError {code, message, exitCode, details}`
with the exit codes above. `up`, `down` and `verify` load viem and the artifacts lazily (they are
`tools/efs-fixture.mjs`'s functions, which also exports `status`, `list`, `gc`, `reset` and re-exports the registry);
`allocate`, `update`, `lookup`, `list`, `release` and `gc` do not.

**For the SDK and the client.** Import `tools/fixture-registry.mjs` from a contracts checkout or release directory and
use one registry (`EFS_FIXTURE_HOME`). Start chains with `up` (or the CLI with `--json`) and read everything from its
result or `lookup(name)`; the deployment document is at `deployment`. The client supervisor takes `gateway` and `ui`
leases with `allocate` in the same registry (their own ranges), updates them as its processes change and `release`s
them on shutdown; it adopts a chain whose `lookup` is `live` and passes `verify`. Never parse `anvil.log`; never kill by
port.

### The chain's rules

The fixture's anvil runs `--hardfork osaka --enable-tx-gas-limit` by default, so the local chain enforces what
mainnet and Sepolia enforce since Fusaka: **a transaction whose gas limit exceeds 16,777,216 (2^24, EIP-7825) is
refused.** Measured on anvil 1.8.3: `--hardfork osaka` alone does not enforce it, and neither does
`--enable-tx-gas-limit` under prague; both are needed. The contracts are still compiled for prague and the addresses
do not change. `--hardfork prague` gives the old behaviour (no cap) for a measurement that needs it.

`efs-deployment/1` records the rules as `chain: { hardfork, txGasCap, txGasCapEnforced, blockGasLimit, atBlock }`.
It is a **snapshot taken at deployment, not live truth**: a block gas limit moves and a later fork changes what the
cap counts (after Glamsterdam it counts execution gas only), so a client reads the live block gas limit from the
chain and treats the document's values as defaults. `verify` compares the snapshot with the chain and proves the
cap by sending a signed transaction with gas limit cap + 1, which must be refused (a refusal changes no state).
`tools/test/fixture-gas-cap.test.mjs` shows the consequence: a publication inside every Realm limit (64 records,
16,384 body bytes, about 28M gas) is refused above the cap, runs out of gas at the cap and is admitted when split
into four; under `--hardfork prague` the same publication is admitted whole.

### Artifact sources

`--artifacts DIR` (or `EFS_ARTIFACTS_DIR`) selects where the plan reads its unit artifacts; the layout is detected:

| Layout | Detected by | Immutable names | Integrity |
|---|---|---|---|
| `forge` | anything else (`out/`) | `$EFS_AST_DIR` (default `DIR/release-ast`), else `release/release.json` | each artifact's metadata keccak256 of its compilation target against the source on disk |
| `snapshot` | `DIR/efs-artifacts-snapshot.json` | frozen in the manifest | the same, against the snapshot's own copy of the sources |
| `release` | `DIR/LedgerCore.json` with `schema: "efs-artifact/1"` | each unit's `immutables` | each unit's runtime and creation code against `DIR/../release/release.json` when present |

So a release directory or another checkout deploys with no forge build and no `out/`:
`up --artifacts <repo>/artifacts --plan <repo>/deploy/plan.json`. In the release layout, `vectors/layout.json` (or
`artifacts/index.json`'s `layoutId`), `release/` and `deploy/` are read from `DIR/..`. Verified: the committed
`artifacts/`, a copy of `artifacts/ release/ vectors/ deploy/` in an empty directory, and a snapshot of
`out/release-ast` each reproduce the committed `deploy/plan.json` hash (`0x38e9…891c`) and deploy and verify OK.
`release.mjs` now also writes `artifacts/index.json` (`efs-artifacts-index/1`: `layoutId`, `hotAbiId`,
`hotAbiIdString`, the unit list, the manifest path) so `artifacts/` alone carries the layout id; until the next
`pnpm release` it falls back to `vectors/layout.json`. The plan's ABIs travel with the plan (`plan.local`, not part of
`planHash`), so one process can run instances from several sources.

`tools/artifacts-snapshot.mjs --to DIR [--from out] [--ast out/release-ast] [--rev HEAD]` copies the release units'
artifacts, recovers every source they were compiled from by keccak256 (the working tree first, then `git show
<rev>:path`), freezes the immutable layouts and writes the manifest. It refuses unit artifacts that disagree about a
shared source (a half-finished incremental build) and any source it cannot recover byte for byte. Use it when `out/`
is being rebuilt under you: `EFS_ARTIFACTS_DIR=out-fixture-<x> node tools/efs-fixture.mjs up`. `out-fixture-*/` is
gitignored.

### Signing

Every transaction the fixture sends (genesis, registration, seed) is signed locally with the fixture key through a
viem local account and submitted with `eth_sendRawTransaction`; the fixture's RPC client refuses `eth_sendTransaction`,
`eth_sign*` and `personal_sign` outright, and `fixture.json` records the RPC methods used.

- **Default:** anvil's ten default accounts are unlocked and funded (10,000 ETH). `up` checks that `eth_accounts` is
  exactly those ten and records `signerCapable: true`.
- **`--no-unlocked`:** anvil 1.8.3 has no "no unlocked accounts" switch as such, but `--accounts 0` generates no dev
  accounts, and `--fund-accounts` funds the same ten addresses. `up` checks that `eth_accounts` is empty, that an
  unsigned `eth_sendTransaction` is refused (`No Signer available`) and that the tenth default address holds 10,000 ETH,
  and records `signerCapable: false`. Remaining exposure, stated plainly: anvil's admin methods
  (`anvil_impersonateAccount`, `anvil_autoImpersonateAccount`, `anvil_setBalance`, …) are still served to any local
  process; auto-impersonation is off unless someone turns it on.

`signerCapable` is in the lease, the `up` result, the deployment document (`signerCapable`, `signing`,
`capabilities`) and `verify` re-checks it against `eth_accounts`.

### Process rules

- `release.mjs` and `gas-report.mjs` run forge through `perl -e 'alarm 900; exec @ARGV'` with a Node timeout as well.
  The amsterdam run writes `out/amsterdam` and `cache/amsterdam` and never touches the identity `out/`, because
  `[profile.amsterdam]` does not set its own `out`.
- `node --test "tools/test/*.test.mjs"` (`pnpm test:tools`): `fixture-registry.test.mjs` (no anvil: 12 simultaneous
  allocations from 12 processes get 12 different ports; 8 contenders for 3 ports give exactly 3 winners and 5 exit-3
  refusals; a bound port is skipped and refused when explicit; stale leases are broken; gc removes only the dead; down
  refuses to signal a live non-anvil holder and never signals a reused pid) and `fixture-concurrency.test.mjs` (three
  `up --json` at once, one of them `--no-unlocked --fresh --chain-id 3133702`; three names, ports and anvils; each
  verified in `up` and again; `list`; `down`; no lease, claim, state directory or process left). The concurrency test
  skips, with the reason, when the plan cannot be built from the current artifacts. `vendored-tree.test.mjs` (no anvil)
  copies the three fixture tools with `schemas/`, `artifacts/`, `release/` and `deploy/` into an empty directory with
  no `out/` and reproduces the committed plan hash there: the tree a consumer's CI vendors. `fixture-gas-cap.test.mjs`
  is described under "The chain's rules".

### The hot-ABI id

The release hot-ABI id is **`keccak256("efs2/ledger-hot/1")`** =
`0x5e2699b8fb658570bf743780fa5efbfd4b40e49f5ff596c5b5f1300b1b8d3f0d` (`HOT_ABI_ID_STRING` in `tools/deploy-plan.mjs`).
It is `LedgerCore`'s `HOT_ABI_ID` constructor argument (so `supportedHotAbiIds() == [it]`), `RealmIndex`'s
`hotAbiId` constructor argument and the `FilesFinalValidator` unit's `hotAbiId`. The suites keep
`keccak256("efs2/ledger-hot/1:test")` (`test/harness/KernelDeploy.sol`). `release.json` records it as
`profiles.hotAbiId` with `hotAbiIdPreimage`, and `efs-deployment.json` as `hotAbiId` and `hotAbiIdString`.

### The readers

`LensReader(ledger, views, reads)` and `FilesPageReader(ledger, views, reads, files-name/2, files-root/1,
files-child/1)` are CREATE2 steps **R1** and **R2**. Their constructors read `layoutId()` from the ledger proxy, so
they follow G18; they run after the genesis activation (G20). **R3** and **R4** list them permissionlessly in the
`ReaderDirectory` under the kind labels `keccak256("efs2/reader/lens/1")` and
`keccak256("efs2/reader/files-page/1")` (the strings `test/periphery/ReaderDirectory.t.sol` uses; the directory does
not interpret them). Both readers are realm-specific, because their immutables name the ledger proxy.

### The fixture key

The fixture key is anvil's default account 0 (`0xf39F…2266`; its private key is printed by every `anvil`). It is the
controller owner, the declaration key of the ten Files Types and the seed principal. Never use it with value.
`~/.env` is never read.

### The factory

`up` starts anvil with `--disable-default-create2-deployer`. It then funds `0x3fab…5362` and submits the public
presigned pre-EIP-155 transaction of Arachnid's deterministic-deployment proxy. That transaction creates
`0x4e59b44847b379578588920cA78FbF26c0B4956C` with codehash
`0x2fa86add0aed31f33a762c9d88e807c475bd51d0f52bd0955754b2608f7e4989`, and the deployment document records
`factory.method = "presigned-tx"`. If a node refuses an unprotected transaction, `up` falls back to `anvil_setCode`
with the same runtime and records `"anvil_setCode"`. The runtime is read from the presigned transaction itself
(14-byte prologue, then 69 bytes). `verify` compares it with `test/harness/doubles/Factory.sol`'s `RUNTIME` (now
equal; see HARNESS-BUG below).

## Files

| Path | What it is |
|---|---|
| `tools/deploy-plan.mjs` | Library and CLI. Computes the whole §8.2 plan offline from `out/`: every CREATE2 address from its initcode, `RealmGenesis` and its nonce-1/2/3 creations, the ProxyAdmins (`CREATE(proxy, 1)`) and every runtime codehash, with immutables filled at their offsets. It also holds a JS twin of `src/profiles/FilesTypes.sol` (descriptors, Type ids, EIP-712 declaration signatures), the index manifest hash, `limitsProfileId`, `domainSeparator`, the execution set, the seed actions and a small schema validator. |
| `tools/efs-fixture.mjs` | `up` / `verify` / `status` / `list` / `down` / `reset` / `gc` (above); also a library (`up`, `verify`, `down`, `reset`, `status`, `list`, `gc`). |
| `tools/fixture-registry.mjs` | The machine-wide registry and lease library (above); Node built-ins only. |
| `tools/artifacts-snapshot.mjs` | A self-contained snapshot of the release units' artifacts and sources (above). |
| `tools/test/*.test.mjs` | The tooling tests (`pnpm test:tools`). |
| `tools/release.mjs` | Writes `release/release.json`, `release/errors.json` and `artifacts/`. |
| `tools/gas-report.mjs` | Writes `gas/report.json`. |
| `script/Genesis.s.sol` | Simulation only, never broadcast. `profile(address key)` deploys the ten rules, `RefuseAllPolicy` and `FilesFinalValidator` through the factory in forge's EVM and returns `FilesTypes`' descriptors and ids. `release.mjs` requires the JS twin to match it byte for byte. |
| `deploy/plan.json` | `efs-deploy-plan/1`: 61 steps (F0, G1–G20, R0–R4, G21, R5 the `web3://` gateway, and the six seed publications G22.root, G22.folder, G22.file, G22.big.0–1, G22.remote), each with kind, contract, address, initcode hash, constructor arguments, runtime codehash, calldata hash and post-check, plus the predicted addresses, realm ids, the genesis activation set with `expectedExecutionSet`, the index manifest, the ten Type ids and descriptors, the seed and `planHash`. |
| `release/release.json` | `efs-contracts-release/1` (design §13). It records the source commit, tree and dirty count; toolchain pins (`bytecode_hash = "none"`, CBOR trailer kept); the build platform; double-build reproducibility (33/33 units with identical runtime and creation code across `out/` and `out/release-ast`); sha256 of all 86 source files the units compile from; and, per unit, `runtimeHash` (immutables zero), `deployedBytecodeHash` (planned immutables), `initcodeHash`, `initcodeWithArgsHash`, address, named immutable offsets (empty for every `profiles/` contract, which is asserted), sizes and budgets. It also covers the profile (ten Types with shape, descriptor, ruleId, instance, blob and declaration signature; `RefuseAllPolicy`; the index manifest, families, units, digest specs, work model and stores), `limits`, `layoutId`, `hotAbiId` and its preimage, the readers (addresses, codehashes, kind labels, facets), `statusVocabularyId`, store ABI ids, index profile ids, `constants` (action kinds, capability bits, the three purpose ids with their preimages, the Status and Coverage codes, and the Files form, carrier, hash, alias and target-kind codes with the chunk payload: all parsed from the Solidity sources, so a consumer never types a protocol string), the consumer pragma floor, privileged roles, the error-catalog pointer and hash, the ABI pointers and the vector hashes. Digest = `sha256(file)`. |
| `release/errors.json` | `efs-errors/1`: 106 file-level errors from `src/`, each with selector, signature, args, source, retry class (the first word of the trailing comment; required, the generator refuses an error without one) and meaning (the rest of that comment, else the `///` lines above the error). Every selector in `test/snapshots/abi/Errors.json` is reproduced. |
| `artifacts/<Unit>.json` | `efs-artifact/1` per deployable unit: ABI, method identifiers, creation and runtime bytecode, named immutable offsets. `LedgerCore.json`'s ABI is the union of the kernel ABI with the events and errors of `LedgerApply`, `LedgerIngress` and `LedgerControl`. Interface ABIs are not copied: `abi.interfaces` points at `test/snapshots/abi/` (tools/abi-snapshot.mjs), and storage layouts at `test/snapshots/layout/`. |
| `release/efs-deployment.json` | `efs-deployment/1` (design §13). It records the release digest, plan hash, chain id, `realmId`/`realmOrigin`/`realmSalt`, the factory and how it was deployed, the genesis address, nonces and tx/block, the activation (revision 1, execution set, tx, full set), the layout and hot-ABI ids, the profile id, limits and `limitsProfileId`, the domain separator and `noticePrincipal`. It covers the controller (owner, pending owner, frozen); both proxies (live implementation slot, ERC-1967 admin, `ProxyAdmin.owner()`, the `_admin` immutable offsets, the initializer calldata); every contract with address, runtime hash, step and tx; the index (generation, manifest, obligations, stores, families, units, digest specs, work model); the Type ids and profile rows; privileged roles; the readers (`LedgerReads`, `LedgerViews`, `ReaderDirectory`, and `LensReader`/`FilesPageReader` with address, runtime codehash, kind, bound ledger, facets, layout and, for the page reader, the three Type ids, plus the directory's listing rows as read back from chain); the seed (version and the three transactions with their actions and bodies); `root {directoryRecordId, subjectId, principalId}`; `defaultLensPrincipals`; the actors; an RPC hint; and the evidence grade `local-fixture`. |
| `release/expected.json` | `efs-fixture-expected/1`: the seed's post-checks (root, folder, the three files with their ids, lengths, sha256 and, for big.bin and remote.txt, the descriptor, span-root and sentinel ids; counts 29 admissions / 17 records / 7 bindings / 6 publications; seven heads; thirteen records; catalog count 10). |
| `<home>/instances/<name>/` | One instance's runtime state (never tracked): `anvil.pid`, `anvil.log`, `fixture.json` (rpc, pid, ttl, factory method, signing, RPC method counts, the journal of all 61 transactions with hash, block and gasUsed, and the two read estimates), its own `efs-deployment.json` and `expected.json`, and `up.json`. `release/efs-deployment.json` and `release/expected.json` are the committed sample, written only by `up --write-release`. |
| `artifacts/index.json` | `efs-artifacts-index/1`: `layoutId`, `hotAbiId`, the unit list; lets `artifacts/` deploy alone. |
| `gas/report.json` | `efs-gas-report/1` (below). |
| `schemas/*.schema.json` | JSON Schemas (draft 2020-12) for the six documents above and the lease (`efs-fixture-lease-1`). `verify` validates every document present against them, using the subset in `deploy-plan.mjs validate`. They are drafts: `schemas/README.md` says release schemas land after review. |

## What `verify` reproduces

370 checks against the chain, recomputed from `out/` (and `release/release.json`'s immutable names when the AST
build is absent). Exit 1 on any mismatch; a tampered `expected.json` was tested and fails.

1. **Documents.** `planHash` (recomputed, and equal to `deploy/plan.json`), the ledger address, the execution set, the
   root, and `releaseDigest` against `sha256(release/release.json)`. All six documents are validated against
   `schemas/`.
2. **Code, byte for byte.** The factory runtime and its codehash. For the 29 units the plan deploys (the two readers
   and `KeysView` included), the runtime is compared byte for byte with the artifact plus the planned immutables.
   Codehashes are checked for those 29, the 5 `RealmGenesis` creations (controller, both proxies, both ProxyAdmins)
   and the 10 descriptor blobs.
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
   units equal to the plan; `progress().lastProcessed` equals 29; `digestSpecCount` is 1 for `files-content/1` and for
   `files-external/1`.
8. **The ten Types.** The catalog equals the offline id set. For each Type, `typeInfo` mandatory, ruleId, shape and
   blob; `descriptorBytes` equals the JS descriptor; `refTypes`; `declaration` (key and installed); and the published
   id.
9. **The seed.** Thirteen record headers, seven heads (state, revision, target), five subjects created, the fixture
   principal's nonce of 6 (one per publication), the root scope (1 entry, 1 live) and the `docs/` scope (3, 3).
   For each file, from its HEAD revision through `LedgerReads.record`: `readme.txt` (form 0) has the expected length
   and sha256; `big.bin` (form 1) names its `files-content/1` record (carrier 2, the span root, length, sha256), and
   its span tree is re-assembled node by node (each chunk against its own word-0 sha256, each span against its
   length) into 20,000 bytes with the descriptor's sha256, 3 chunks and 2 spans; `remote.txt` (form 1) names its
   `files-external/1` record (the empty sentinel, version 2, carrier 2, sha256, length, the locator byte for byte),
   and the sentinel is the empty `files-bytes/1` record. `KeysView` reproduces the readme's subject, root record,
   HEAD binding key and the `docs/` scope key.
10. **The readers.** `LensReader`'s `ledger()`, `VIEWS`, `READS` and `layoutId()`; `FilesPageReader`'s `LEDGER`,
    `VIEWS`, `READS`, `LAYOUT`, `NAME_TYPE`, `ROOT_TYPE` and `CHILD_TYPE`. For each kind label, the directory's
    `readers(ledger, kind)` must be exactly that reader with its codehash, `layoutId` and the generation-1 physical
    profile, and the deployment document must list it. One page of `docs/` through `listDirectory` must be PRESENT
    and `COMPLETE` with exactly three rows in bind order (`readme.txt`, `big.bin`, `remote.txt`, each → its file
    subject, HEAD → its root record). `LedgerReads.record`
    of that root record must return PRESENT with the right Type, word 0 and body.
11. **The `web3://` gateway.** `resolveMode()` is `"5219"` and its fourteen immutables are the planned ones. Then
    the seed is read through `request` the way a `web3://` client does it: `docs/readme.txt` by principal id and by
    account address (same bytes, sha256, `text/plain`); `docs/big.bin` chunk by chunk following `web3-next-chunk`
    until the header is absent (three chunks, 20,000 bytes, the seed's sha256); `docs/remote.txt` as `307` with the
    seed's locator; `docs` as a complete JSON listing of the three files; and `404`, `400` and `416` for a missing
    name, a malformed principal and an offset at the end.
12. **Cold pin.** What an SDK holding only `release.json` and `efs-deployment.json` does on first contact.

### Cold-pin call count (observed)

**9 logical calls in 2 HTTP envelopes**: `eth_chainId`, `eth_getBlockByNumber`, `eth_call LedgerReads.describe`,
`eth_getStorageAt(ledgerProxy, ERC-1967 implementation slot)`, then `eth_getCode` ×5 (implementation,
`LedgerReads`, `LedgerViews`, `LensReader`, `FilesPageReader`). That is exactly the design bound of ≤ 9 calls and
≤ 2 envelopes, and `verify` fails if it is exceeded. `verify` checks the chain id, the implementation, and each of the
five codehashes against `describe()` and the release.

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
  `0x863d4eb7487f3255978b9b38bbb4760b2147accc3fe7376610f3d60e4beb9baa`.

## The planning model (`gas/model.json`)

`pnpm gas:model` (`node tools/gas-model.mjs [--skip-amsterdam 1]`, forge under the same watchdog and `out/amsterdam`
rule) runs `test/integration/GasModel.t.sol` on both profiles and fits `gas = fixed + Σ cost(action)`, with `PUBLISH` new `= publishNew[shape] + perWord·ceil(n/32)
+ perByte·n` and one constant per other action kind and purpose, plus a once-per-principal first-write surcharge
(amsterdam constants are also split into execution and state gas, since the EIP-7825 cap counts execution only). It
is for planning: the SDK splits a large write into publications from it without one `eth_estimateGas` round trip per
guess, and `eth_estimateGas` stays the authority before sending. It excludes intrinsic, calldata and refunds. The
script predicts five composites it never fits (create file, edit, rename + move, two chunks, the last publication of
a 40 KB file) and exits 1 if a prague prediction is off by more than 15%. Regenerate and commit it whenever the
kernel, the index or a Files rule changes.

## Gas rows written (`gas/report.json`)

`test/integration/FilesRecipes.t.sol` logs `<label> gas` (the `gasleft()` delta around `execute`, so no intrinsic
cost), `<label> frame gas` and, under amsterdam, `<label> frame state gas`. These are machine-readable through
`forge test --json -vv` (`decoded_logs`). The runner executes the suite under the default (prague) profile and under
`--profile amsterdam` (`out/amsterdam`). The rows below are prague and amsterdam gas, then amsterdam state gas:

| §14 row | prague | amsterdam (state) |
|---|---:|---:|
| Root seed (CREATE + PUBLISH directory) | 770,658 | 2,711,511 (2,154,240) |
| Native 1-leaf PUBLISH (32 B directory body, steady author) | 579,580 | 1,771,418 (1,272,960) |
| M1 create folder (first placement in root, fresh scope) | 1,394,667 | 4,867,655 (3,818,880) |
| M1 create file (5 leaves, fresh folder) | 1,676,815 | 5,860,829 (4,602,240) |
| Edit | 894,824 | 2,805,410 (2,056,320) |
| Rename / move | 1,081,809 | 3,380,252 (2,448,000) |
| Remove | 445,794 | 1,197,821 (783,360) |
| Restore (masked → same target) | 487,148 | 1,253,709 (783,360) |
| RELEASE from mask | 409,372 | 1,073,512 (685,440) |
| RELEASE from BOUND (not a §14 row) | 428,959 | 1,100,300 (685,440) |
| Restore a released placement (Move-back analog) | 502,014 | 1,349,249 (881,280) |
| WITHDRAW | 457,508 | 1,297,166 (881,280) |

**Read rows** (`reads` in the report; prague). `eth_estimateGas` on the fixture includes the 21,000 intrinsic and
calldata cost, and each read is one `eth_call`:

- `FilesPageReader.listDirectory`, one page of `docs/` (now three rows; limit 32, one principal, unbound basis,
  F_NAME | F_HEADER | F_KIND): 573,832 gas, 548 B calldata, 1,856 B returndata.
- `LedgerReads.record` of `readme.txt`'s root record: 90,994 gas, 68 B calldata, 576 B returndata.

The 1,000-entry filtered folder comes from `test/readers/LargeDirectory.t.sol`, whose `console2.log` lines `forge test
--json -vv` exposes in `decoded_logs`. Each run lists all 1,000 live rows; per-page detail is in the report:

| Run | Calls | Max gas per page | Total gas | Max / total returndata |
|---|---:|---:|---:|---:|
| warm, 30M per call | 6 | 30.0M | 157.1M | 74,720 / 389,664 B |
| cold, 30M per call | 6 | 30.0M | 157.1M | 74,720 / 389,664 B |
| warm, 50M per call | 4 | 51.0M | 162.0M | 121,952 / 387,680 B |
| pages of 100 rows | 11 | 15.3M | 151.8M | 39,392 / 394,624 B |

The prototype needed 199 calls.

The report also carries 25 supplementary recipe steps and the fixture's 61 transaction receipts, which are prague
only and include intrinsic cost:

- Genesis code deposit: 44.6M over 27 transactions (the ten rules included).
- Readers and views (R0–R5): 11.17M (`KeysView` 0.38M, `LensReader` 3.76M, `FilesPageReader` 2.81M, each listing 0.16M, `EfsWeb3Gateway` 3.88M).
- The ten descriptor blobs: 1.54M.
- **Genesis activation: 4.21M**, against the design estimate of ≈ 1.1–1.9M (a finding, not a failure).
- `registerDescribed`: 0.24–0.27M each (design ≈ 0.30M).
- Seed: root 0.77M, folder 1.39M, `readme.txt` 1.67M; `big.bin` 12.60M (two 8 KB chunks, 16,384 body bytes) +
  5.87M (the last chunk, two spans, the descriptor, the revision, the name and both binds); `remote.txt` 2.41M.

## KERNEL-BUG

None found in `src/`. Genesis, activation, registration and seed all ran as specified, and every predicted address
and runtime hash matched the chain.

**HARNESS-BUG (fixed upstream in `be20323`).** `test/harness/doubles/Factory.sol` `RUNTIME` had one stray `ff`
(70 bytes; the canonical runtime is 69). `verify` now prints `Factory.sol RUNTIME matches`, and the deployment
document records `factory.harnessRuntimeMatches: true`.

## DESIGN-DIVERGENCE

Where §8.2/§13 and the code disagree. The code is followed in every case.

1. **G1–G2: there are four kernel units, not three.** `LedgerCore(ingress, apply, control, hotAbiId)` needs a
   `LedgerControl(ingress, apply, predecessorLayoutId = 0)` delegate, which §8.2 does not list. The plan adds step
   **G2c**.
2. **G6: `DescribedTypeRule/1` is not deployed.** The file is untracked and still being written by another agent.
   Genesis passes `wrapperV1 = 0`, as `test/control/RealmController.t.sol` does, and the ten Files Types are all
   NATIVE, so no wrapper is needed. A later `controller.activateWrapper(1, wrapper)` adds it.
3. **G9: `IndexBuild/1` does not exist.** `RealmIndex` takes no build, `Readiness.build` is 0, and the plan has no G9.
4. **G13.** `LAYOUT_ID` is a compiled constant, not an immutable. `PREDECESSOR_LAYOUT_ID` is on `LedgerControl`.
   `SUPPORTED_HOT_ABI_IDS` is computed as `[HOT_ABI_ID]`. `LedgerCore` has no `SELF` immutable.
5. **HOT_ABI_ID.** §5.3 names a derivation (`keccak("efs2/ledger-hot/1" ‖ sorted selectors ‖ return layouts)`), but
   neither `src/` nor `vectors/` commits one. On the coordinator's instruction the release uses the plain string id
   `keccak256("efs2/ledger-hot/1")`, not the selector-and-layout fold. No `vectors/hot-abi.json` table exists.
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
11. **Readers.** §8.2 has no reader step, so the plan adds R1–R4 after G20. The facets `LedgerReads` and
    `LedgerViews` are not `IReader`s and are not listed; only the two readers are. **R0** deploys `KeysView` (the
    pure `Keys` derivations as a view, outside the execution set; the eight key helpers left `ILedgerCommitments`); its
    address is `keysView` in the deployment document and the `up` result.
12. **§13 `fixture/`.** There is no `fixture/` directory, no forge-script-encoded seed transactions, no
    `EfsFixture.sol` and no Multicall3 etch. `--state-dir` exists (above). `--hardfork osaka|prague` chooses the local chain's rules only (default osaka); every planned codehash is a prague build either way, and both give the same addresses. The seed is
    encoded in JS (`EfsNative`-equivalent: both expectations bound through `executionSet()` and the ingress's
    `acceptanceProfileOf`) and recorded in `efs-deployment.json` `seed.transactions` and `expected.json`.
13. **Placement of `release.json`.** `schemas/` named no path, so the manifest is `release/release.json`. The six
    schemas are new, unreviewed drafts.
14. **Seed (`efs-fixture-seed/2`).** The root, `docs/`, and three files in `docs/`: `readme.txt` (form 0, the bytes
    inline after `abi.encode(file, 0)`), `big.bin` (20,000 deterministic bytes, word i = keccak256(abi.encode(
    keccak256("efs-fixture/big.bin"), i)), chunked by `efs2/chunking/1` into 8,160-byte chunks, chunks in order then
    spans in post-order, a `files-content/1` carrier-2 descriptor, a form-1 revision; split by `EfsFiles.split`'s
    greedy rule under 64 actions / 16,384 body bytes into two publications) and `remote.txt` (the empty
    `files-bytes/1` sentinel, a `files-external/1` record with locator
    `web3://0x0000000000000000000000000000000000000000:31337/remote.txt` and the length and sha256 of a 51-byte
    text, a form-1 revision). It produces 29 admissions, **17 records**, 7 bindings and 6 publications (CREATE leaves
    are subjects, not records). The JS seed encoder mirrors `EfsFiles` (`chunk`, `split`, `storeContent`,
    `createFileRef`, `externalBody`).

## Not covered, and why

- **The §16.6 reproducible-build attestation ("two clean-rebuild hash sets").** The double build covers runtime and
  creation-code identity across two independent full compiles. `standardJsonInputHash` is `null` because the default
  profile emits no `build_info`.
- **`dependencyRoot`.** It is null: the freeze checklist that defines it does not exist yet.
- **§14 slot columns and `tx.gas` cases.** Fresh, rewritten and cleared slot counts, code bytes and accounts per row
  need a state-diff pass. `tx.gas` below and above 2^24 is not varied, and there are no amsterdam fixture receipts:
  release bytes under `anvil --hardfork amsterdam` would need the reservoir and `tx.gas` above 2^24 for the genesis
  code deposit.
- **Remaining read rows.** Confirm/recovery reads, `LensReader.headsAt` at 64 principals, and read rows on
  amsterdam (reads are not repriced, so they are prague only).
- **`vectors/execution-set.json`, `manifest.json`, `hot-abi.json`, `names.json` and the other §13 vectors.** These are
  generator work for `tools/vectors.mjs`'s owner. `release.json` hashes the two vector files that exist.
- **The wrapper, the signed lane, guards, freeze and upgrades.** Out of S1b.3.
