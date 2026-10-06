# EFS v2 contracts

Repository foundation for Fable's EFS v2 contract design and implementation.
The current checkout contains pinned contributor tools, a test-only Foundry smoke fixture,
locked test dependencies and CI. It contains no EFS contracts, interfaces, deployment or
consumer release bundle.

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

## Layout and next work

`src/` is reserved for production Solidity; `test/` contains the tooling fixture;
`tools/` contains Node built-in-only checks; `schemas/` reserves future reviewed formats;
`docs/` records contributor choices. No sibling checkout is required.

Contracts owns future contract artifacts and consumer Solidity interfaces; the SDK will
consume a pinned, reviewed release. Contract/link architecture, storage, proxies, identity,
security policy and release formats remain Fable's design work. The scaffold's Prague,
optimizer and via-IR settings are provisional; see [foundation scope](docs/foundation.md).

Original software is MIT-licensed. This license does not license user content stored
through EFS. Test dependencies keep their own licenses; see [notices](THIRD_PARTY_NOTICES.md).
