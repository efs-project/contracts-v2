# Recovery

The SDK's law for classifying a publication after a lost response, copied from [DESIGN.md](DESIGN.md) §6.6; the vectors in `vectors/native-intent.json` (S1) carry the classifier cases.

Any failure anywhere reverts the whole publication and the enclosing application call; the transient lock clears with the frame; tests hash a `Layout`-derived raw-slot digest before and after every refused call. An exact retry on any lane reverts `AlreadyAdmitted(ordinal)` with no writes at any later block; a different plan under a consumed nonce reverts `E_NONCE(principal, nonce, ordinal)`; upgrades and the freeze never reset nonces.

**Recovery classifier** (the SDK's law, published in `docs/RECOVERY.md` and vectored): read `publicationAt(principalId, plan.nonce)` and the block header **at one finalized block hash `H`** (EIP-1898 `requireCanonical`, SC-R1). `COMMITTED` iff `ordinal != 0 ∧ storedDigest == plan.intentDigest`; `NOT_COMMITTED_PROVEN` iff `(ordinal != 0 ∧ storedDigest != plan.intentDigest)` (the nonce was consumed by another plan: the second-device case) `∨ (ordinal == 0 ∧ plan.deadline != 0 ∧ timestamp(H) > plan.deadline)`; otherwise `UNKNOWN` (keep waiting or rebroadcast the identical bytes; an identical rebroadcast can only land once). `nonceOf` is not part of the classifier (it is implied by `publicationAt`); it serves the next nonce. The plan's `intentDigest` is computed offline from plan-intrinsic inputs only, so no activation, policy change, index replacement, head change or key rotation between preparation and recovery can make the classifier lie.

---
