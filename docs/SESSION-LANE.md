# The session lane: approve once, then write with no prompts

**Status: proposal (2026-11-24). Nothing here is implemented.** It answers the PM's ask C13 and James's bar of the
same day: an ordinary user action takes zero, one or at most two wallet prompts, "or else we could just keep v1".
It names the candidates, what each does to the `Intent` typehash, what it costs per write, and the rulings needed
before S2 freezes that typehash.

## The problem in one example

Alice opens the file browser, connects her wallet and edits files for an hour.

- **Today (S1, native lane):** every save is one transaction from her wallet, so one prompt per save. A save may
  batch up to 64 actions, 16,384 body bytes and about 16.7M gas, so "one prompt per user action" already holds for
  ordinary edits (create a file is one prompt, a staged save of about 20 edits is one prompt).
- **Where that breaks:** anything that needs many publications. A 100 KB on-chain file is 7 publications, 1 MB is
  about 64 (`docs/LARGE-FILES.md`), an autosaving editor or a game writes continuously, and "zero prompts" is not
  reachable at all.

A prompt is any wallet interaction: a transaction or a signature. The existing signed lane (EIP-712, relayable) does
not help by itself, because it needs one signature per publication.

What is wanted: **one approval, then any number of publications with no prompt, recorded as Alice's own writes**
(same `principalId`, so every lens that already includes Alice sees them), limited in what they may do, expiring, and
revocable.

## What is already ruled

James ruled the direction on 2026-09-03 (planning vault, `Designs/efsv2/owner-rulings.md`, "Disposable MVP-C0 and
wallet-approval direction"): *"Smart/session wallets target zero routine prompts after permission. One initial
bounded, expiring, and revocable grant may authorize a session key to sign routine in-scope WritePlans."* The same
file lists session keys and personas on the key-event-log upgrade path. So a session-key grant with zero routine
prompts is the owner's direction, and this document does not reopen it.

An earlier client design document (2026-07-07, `Designs/clientv2/wallet-and-actions.md`) framed promptless writing
as personas "without protocol session keys". That framing is superseded by the ruling above; personas remain a
useful mechanism and are candidate A below.

What the ruling leaves open is **who checks the grant**: the wallet (a smart account, an ERC-7715 permission, an
ERC-1271 wallet), or the EFS kernel (a protocol session key). That is the question this document is about.

## What exists that a session can build on

| Piece | State |
|---|---|
| Native lane (`execute`): `msg.sender` is the author | built, the only activated lane |
| secp256k1 signed lane (`executeSigned`, verifier profile 1, capability b1): the author's key signs each publication, anyone may submit, the submitter is recorded | signature check is in the S1 ingress; not activated, not measured end to end (S2) |
| ERC-1271 lane (profile 2, b2): a contract wallet signs | removed from the S1 ingress as unreachable; ships with the S2 ingress |
| `Intent.authorityId`, `Intent.authEpoch` and the evidence words `w11`, `w12` | present in the typehash and the evidence row since S1, required to be zero ("reserved, KEL") |
| `Keys.principalFor`: an EOA and an EIP-7702 account are the same key principal; any other code is a contract principal of this Realm | built |

Two facts shape everything below. The `Intent` typehash **freezes at S2** (design §7.2). And `LedgerIngress` is at
18,993 of 19,660 bytes, so any new verification is a separate pinned unit, not more ingress code.

## The candidates

| | A. Personas | B. Protocol session key | C. Wallet permissions (EIP-7702 / ERC-7715 / ERC-4337) | D. ERC-1271 wallet |
|---|---|---|---|---|
| How | the client holds a hot key that is its own principal; Alice publishes "this key is mine" once | Alice signs one grant naming a session key, a scope and an expiry; the session key signs publications; the kernel checks both | Alice's account is smart-account code with a session module; the session key drives the account, the account calls `execute` | Alice's contract wallet validates signatures; its own session module says yes |
| Prompts | 1 (the link record) + funding | 1 signature (+1 to fund the key, or 0 with a relayer) | 1 permission grant, if the wallet offers it | 1, if the wallet offers it |
| Who is the author | **the persona, not Alice**; readers must put the persona in their lens | **Alice** (`principalId` = hers); the session key is recorded as the actor | **Alice** (`msg.sender` is her address) | Alice's wallet (a contract principal, Realm-qualified) |
| Works with a plain MetaMask EOA today | yes | yes: one `eth_signTypedData_v4` | no (see below) | no (needs a smart wallet) |
| Kernel change | none; works on S1 now | a verifier profile, a pinned verifier unit, a revocation word | **none**; works on S1 now | the S2b lane as designed |
| `Intent` typehash | untouched | **no new field**; `authorityId` and `authEpoch` get their first meaning | untouched (native lane, no Intent) | untouched |
| Limits on what the session may do | none on chain; a persona can write anything as itself | enforced by the kernel's verifier: expiry, Types, purposes | enforced by the account's code, invisible to EFS | enforced by the wallet's code, invisible to EFS |
| Revocation | Alice publishes "not mine any more"; readers drop it; the key can still write as itself | Alice bumps one epoch word (one prompt), or the grant expires | in the wallet | in the wallet |
| Extra gas per write over a native write | 0 | ≈ +0.17M today, ≈ +0.8M after Glamsterdam (estimate) | ≈ +0.05–0.1M (account validation; estimate) | ≈ +0.15–0.2M (estimate) |

Notes on each.

**A. Personas.** The July client design's mechanism (client-held hot keys, one per app). It is the only zero-prompt
path that needs nothing built, so it is the right bridge for the MVP. Its cost is the one the requirement names: authorship is not Alice's. Every reader has to know the personas
(a lens is at most 64 principals, and each one costs gas on every read: a head read measured 67k gas with one
principal and 131k with eight), a rename or delete by a second persona is a different author's fact, and "is this
persona really Alice's" becomes a rule every client must implement the same way.

**B. Protocol session key.** The only candidate that gives Alice's own authorship to any wallet that can sign typed
data, which is every wallet. Detailed below. Its cost is new kernel surface that must be right the first time.

**C. Wallet permissions.** If Alice's EOA is an EIP-7702 account with a session module, a session key can make
her account call `execute`; EFS sees `msg.sender` = Alice and treats it as a normal native write. Nothing to build
and the cheapest write. The limit is the wallet: a dapp cannot ask an ordinary wallet to delegate to code of the
dapp's choosing, and the permission a wallet offers must cover "call this contract". As read today, production
MetaMask offers ERC-7715 permissions for token spending (periodic and streaming allowances), not for arbitrary
contract calls; I found no production wallet permission that would cover an EFS write. That may change, and when it
does EFS supports it with no change. **It cannot be the plan EFS depends on.** (Sources at the end; the wallet
facts are from documentation pages, not from testing.)

**D. ERC-1271.** Serves people who already use a contract wallet. Their writes are authored by the wallet as a
contract principal, whose id depends on the Realm, and their authorship cannot be re-checked on another chain unless
the signature bytes are retained (Q5). Worth shipping at S2b for those users; not a general answer.

Not candidates: batching alone (already the S1 behaviour; it is "one prompt", never zero), EIP-5792 `wallet_sendCalls`
(one prompt for several calls, but still one transaction under the 16.7M cap, so it does not help many publications),
and a passkey lane (a biometric prompt per write is still a prompt).

## Recommendation

1. **MVP, now:** personas (A) where zero prompts are needed, the native lane everywhere else. No contract work.
2. **S2:** build the protocol session lane (B) as its own verifier profile, with the signed lane it rides on.
3. **Always:** C keeps working for wallets that grow the feature, D ships at S2b as designed. Neither is depended on.

The reason for B: the ruled direction is a session-key grant, and B is the only place to check that grant where
the hard requirement (few prompts) and the core doctrine (the author is the identity lenses key on) both hold for a
user with an ordinary wallet. Checking it in the wallet (C, D) is cheaper and needs no kernel work, but depends on
wallet features that do not cover contract calls today.

## B in detail

### The grant (what Alice signs once)

An EIP-712 struct under the ledger's existing signing domain, shown by the wallet field by field:

```
SessionGrant(
  bytes32 realmId,          // this Realm only
  bytes32 principalId,      // Alice
  address sessionKey,       // the key the client just generated
  uint64  notBefore,
  uint64  expiry,           // capped by a Realm limit, e.g. 30 days
  uint64  epoch,            // Alice's session epoch when she signed; a bump revokes every earlier grant
  bytes32 typeSetHash,      // the Type ids the session may PUBLISH (e.g. the ten Files Types minus notices)
  bytes32 purposeSetHash,   // the purposes it may BIND / UNBIND / RELEASE (e.g. HEAD and FOLDER)
  uint16  maxActions,       // per publication
  uint32  maxBodyBytes      // per publication
)
```

`authorityId = hashStruct(SessionGrant)`. The scope is deliberately coarse: time, Types, purposes and size. It does
not say "only this folder", because a folder is a set of bindings that changes; a subject allowlist can be added as a
later grant version. Dangerous Types (the Realm notice Type) and `WITHDRAW` are outside the default scope.

### A session write

The session key signs an ordinary `Intent` with three fields set differently:

| Field | Own-key write (profile 1) | Session write (new profile) |
|---|---|---|
| `principalId` | Alice | Alice |
| `author` | 0 or Alice's key | the session key |
| `verifierProfile` | 1 | the session profile number |
| `authorityId` | 0 | `hashStruct(SessionGrant)` |
| `authEpoch` | 0 | the grant's epoch |

The witness carries the session signature, the grant and Alice's signature over the grant. The ingress hands them to
a pinned `SessionVerifier` by `STATICCALL` (so the ingress stays zero-write and inside its size budget). The verifier:

1. recovers the session key from the Intent signature and checks it is the grant's `sessionKey`;
2. recovers Alice's key from the grant signature and checks it derives `principalId`;
3. checks `notBefore ≤ now ≤ expiry`, the Realm cap on session length, and `epoch == sessionEpoch[principalId]`
   (one storage read);
4. walks the actions against the Type set, the purpose set and the two size bounds.

The publication is admitted as Alice's. Evidence records what happened: `author` is the session key, `principalId`
is Alice, `w11 authorityId` and `w12 authEpoch` are the grant and its epoch, `w10` is whoever submitted the
transaction. A reader can always tell a session write from a wallet write, and can list or ignore everything one
grant produced.

**Revocation.** Alice bumps her epoch with one transaction (one prompt); every outstanding grant dies. Otherwise a
grant ends at its expiry. Nothing a session wrote is erased (EFS is append-only); Alice undoes it the way she undoes
her own writes.

**The contract-wallet case.** A contract principal cannot sign a grant with a key. It registers the same grant by
calling the verifier itself (`msg.sender` proves the authority). That row is chain-local, so its portability is the
Q5 question, the same as for ERC-1271.

### Who submits and who pays

The signed lane is relayable, so three options, all with Alice as author:

| | Prompts in total | Needs |
|---|---|---|
| the session key pays its own gas, Alice funds it | 2 (sign the grant, send it gas money) | nothing |
| a relayer or paymaster pays | 1 (sign the grant) | infrastructure; the relayer is the recorded submitter, never the author |
| a faucet funds the session key (testnets, the devnet) | 1 | a faucet |

A one-prompt variant for the first row is possible: one transaction to the verifier that registers the grant and
forwards gas money to the session key in the same call. It is a later convenience, not part of the first build.

### What it does to the typehash

Nothing is added or removed. `authorityId` and `authEpoch` are already in the frozen-at-S2 `Intent` string and the
evidence row; today they must be zero. The proposal gives them a general meaning that also fits the later
key-event-log work they were reserved for: **"`authorityId` names the authority that lets `author` write as
`principalId`; `authEpoch` is that authority's epoch; zero means the principal's own key."** A session grant is the
first authority kind. What must be decided before S2 is exactly that sentence, because after S2 the fields' meaning
is signed by every user.

One thing in the neighbourhood is not free: **nonces.** A principal has one strictly increasing nonce. Alice's
wallet, her laptop session and her phone session would all compete for "the next nonce" and keep re-preparing. The
fix is a nonce sequence per `(principalId, authorityId)`, which changes the kernel's nonce rule and adds a lookup
for the reconcile path (`publicationAt` is keyed by principal and nonce today). The retry key is already the intent
digest, so idempotency is unaffected. This is the largest kernel change in the proposal and the one most worth an
early ruling.

### Gas per write

Measured rows are from `gas/report.json`; the others are estimates from storage-slot counts (a fresh slot is 22,100
gas today and about 110,020 after Glamsterdam) and are marked.

| Write | Today (prague) | After Glamsterdam (amsterdam) |
|---|---:|---:|
| Edit a file, native lane (measured) | 0.89M | 2.81M |
| Create a file, native lane (measured) | 1.68M | 5.86M |
| Signed lane, own key, per publication over native (estimate: 5 more evidence words) | +0.12M | +0.56M |
| **Session lane, per publication over native** (estimate: 7 more evidence words, two signature recoveries, the verifier call) | **+0.17M** | **+0.8M** |
| Session lane, trimmed evidence (estimate: store only the session-specific words) | +0.10M | +0.45M |
| Wallet-permission path C over native (estimate; depends on the account) | +0.05–0.1M | +0.05–0.1M |
| Persona path A over native | 0 | 0 |

So a session edit is about 1.06M today instead of 0.89M: roughly 20% more per write for zero prompts. For a large
file the overhead is noise next to the bytes (12.6M per two-chunk publication).

### What a session does not change

A session removes prompts. It does not make publications bigger or cheaper: a transaction still fits about 16 KB of
on-chain bytes today, so a 1 MB on-chain file is still about 64 transactions and about 0.8 billion gas, sent in the
background instead of approved one by one.

### Risks

- **A stolen session key writes as Alice** within the scope until expiry or revocation. Mitigations: short default
  expiry, coarse scope without notices or withdrawals, the Realm cap on session length, the evidence tag that lets a
  client show and bulk-undo one grant's writes.
- **Grant phishing.** A hostile site can ask Alice to sign a grant for the site's key. The wallet shows the fields,
  the domain is the EFS ledger, and the cap bounds the damage in time; it is still a new thing users can be tricked
  into, and personas do not have it.
- **New surface in the execution set.** The verifier decides who may write as whom, so it is pinned by codehash and
  changes only by activation, like the ingress.
- **Review cost.** This is authority code. It gets the adversarial review the kernel got before any Realm enables it.

## What James has to rule before S2

1. **S-1. Who checks the session grant?** The grant itself is ruled (2026-09-03). Either the wallet checks it (a
   smart account, an ERC-7715 permission, ERC-1271), which needs no kernel work but cannot be depended on today for
   contract calls and leaves plain-EOA users with personas; or the EFS kernel checks it (a protocol session key),
   which works with every wallet and keeps the user as the author, at the cost of new authority code in the
   execution set. *Recommend the kernel, with the wallet paths left working for whoever has them.*
2. **S-2. The meaning of `authorityId` and `authEpoch`** (the sentence above). *Recommend adopt it*; it costs no
   typehash change and keeps the key-event-log option.
3. **S-3. Concurrent writers for one principal** (nonce per authority). *Recommend yes*; without it two devices
   fight over one nonce.
4. **S-4. Default scope and the cap on session length.** *Recommend Files Types and the HEAD and FOLDER purposes,
   no notices, no withdrawals, 24 hours by default, 30 days at most.*
5. **S-5. Who pays in the MVP after S2:** the funded session key (two prompts) or a relayer (one prompt, needs a
   service). *Recommend the funded key first; it needs nothing run by anyone.* This is Q9 again.
6. **Q5 (witness retention)** decides whether contract wallets' session grants and ERC-1271 writes can be verified
   on another chain. Signed grants from key principals are portable either way.
7. **Q2 (the signing domain)** and **Q43 (the `efs2` strings, and whether the EIP-712 version stays "2")** both
   enter what Alice's wallet shows when she signs a grant. They must be settled before the first grant is signed.

Q6 (declaration signatures) is not on this path.

## Sources for the wallet facts

- [MetaMask Smart Accounts Kit: Advanced Permissions (ERC-7715)](https://docs.metamask.io/smart-accounts-kit/concepts/advanced-permissions/)
- [MetaMask: supported advanced permissions](https://docs.metamask.io/smart-accounts-kit/get-started/supported-advanced-permissions/)
- [ethereum.org: EIP-7702 guidance for dapps and wallets](https://ethereum.org/en/roadmap/pectra/7702/)
