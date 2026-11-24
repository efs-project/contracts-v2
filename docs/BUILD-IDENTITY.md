# Build identity

EFS v2 pins Types to the **compiled runtime bytes** of their validation rules, so what the compiler
emits is part of the protocol's identity. This document states the policy and what it implies.

## Policy

| Setting | Value | Why |
| --- | --- | --- |
| `solc_version` | `0.8.37` | fixes the via-IR stack-to-memory spill bugs the kernel's stack-discipline code is shaped to trigger; part of every rule's identity through the trailer |
| `evm_version` | `prague` | transient storage (EIP-1153) and EIP-7702 semantics; release bytes are not compiled for the experimental `amsterdam` target |
| `optimizer` / `via_ir` | on, 200 runs, via-IR | the measured prototype baseline; changing either changes every codehash |
| `bytecode_hash` | `none` | the runtime code carries **no** metadata hash, so comments, NatSpec, file paths, remappings and non-codegen edits to the source closure do not change a codehash |
| `cbor_metadata` | `true` | the 3-byte `solc` version trailer stays, so the compiler version remains identity-bearing |

What remains identity-bearing: the rule's semantics and everything inlined into it (libraries,
immutable values), the compiler version, optimizer settings, via-IR, the EVM target, the descriptor
bytes, the checked-reference Types and any custom predicate's codehash. Two different sources that
compile to identical bytes are the same rule; a compiler bump makes new rule ids for unchanged source,
on purpose.

## Consequences

- **Reproducibility is checkable.** A clean rebuild of a release must reproduce every runtime and
  creation hash before a bundle is packed; the release tooling performs a double build.
- **Verification services.** Etherscan-style standard-JSON verification is unaffected. Sourcify reports
  "match" rather than "exact match" because the on-chain trailer no longer commits to the metadata; the
  full metadata JSON is still published with every release.
- **Never relabel.** Old Types stay pinned to their old bytes forever. A refactor that changes generated
  code produces a new rule id and therefore a new Type; existing records keep their Type.
- **Retained artifacts** are keyed by codehash; several source closures may legitimately map to one
  codehash.

## Related gates

`tools/checks.mjs` asserts these settings on every run; `forge build --sizes` gates EIP-170 (24,576
runtime / 49,152 initcode) for every deployable unit even though EIP-7954 (64 KiB) is live on Sepolia,
because mainnet has no Glamsterdam date and other chains may never adopt it.
