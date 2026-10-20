# EFS v2 contracts

The EFS v2 core contracts: the Ledger kernel, its delegates, the Type registry, the required
index, the control plane, the read facets and the consumer closure, built from
[docs/DESIGN.md](docs/DESIGN.md) in the order of [docs/IMPLEMENTATION-PLAN.md](docs/IMPLEMENTATION-PLAN.md).
The product choices the design leaves open are in [docs/QUESTIONS-FOR-JAMES.md](docs/QUESTIONS-FOR-JAMES.md).
Implementation started on 2026-10-20 (stage S0); there is no deployment or release bundle yet.

## Run the foundation

Use Node **24.21.0**, pnpm **12.6.0**, Foundry **1.8.3** and solc **0.8.37**.
Solc is selected/downloaded by Foundry. Install the pinned Foundry release with
`foundryup --install v1.8.3`; install pnpm with `npm install --global pnpm@12.6.0`.
See [Foundry installation](https://getfoundry.sh/introduction/installation).

Run every command below from this repository's root:

```sh
pnpm install --frozen-lockfile
forge soldeer install
pnpm check
forge fmt --check
forge build --sizes
FOUNDRY_PROFILE=ci forge test
```

The Solidity build and tests need Foundry alone. Node/pnpm run the separate contributor
policy check. Smoke tests prove the tooling executes; they do not prove EFS semantics.
CI runs these commands on PRs and pushes to main.

## Layout

`src/` holds the production Solidity in the layers the design names and `tools/checks.mjs`
enforces (`interfaces` ← `lib` ← `core`/`types`/`index`/`control` ← `readers` ← `profiles` ←
`periphery`); `test/` the suites of design §16 with committed snapshots under `test/snapshots/`;
`tools/` the Node tooling ([tools/README.md](tools/README.md)); `schemas/` the reviewed release
formats; `docs/` the design, the plan, the build-identity and gas-schedule policies and the
one-way doors. No sibling checkout is required to build or test.

The SDK consumes a pinned, reviewed release bundle (design §13); canonical deployed identities
come from this repository's exact release build ([docs/BUILD-IDENTITY.md](docs/BUILD-IDENTITY.md)).

Original software is MIT-licensed. This license does not license user content stored
through EFS. Test dependencies keep their own licenses; see [notices](THIRD_PARTY_NOTICES.md).
