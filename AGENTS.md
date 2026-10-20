# Agent and contributor instructions

The contracts are being implemented from [docs/DESIGN.md](docs/DESIGN.md) in the order of
[docs/IMPLEMENTATION-PLAN.md](docs/IMPLEMENTATION-PLAN.md) under James's 2026-10-13 mandate; the
foundation-only scope and its "no production Solidity" rule were retired on 2026-10-20 when
the design was adopted. The design is the specification: do not invent module names, ABIs,
storage layouts, identity derivations, release schemas or deployment policy that it does not
state; propose a design revision instead, with the measurement or finding that motivates it.

Use the pins and root-directory commands in [README](README.md). Before committing, run frozen
install, Soldeer install, `pnpm check`, `forge fmt --check`, `forge build --sizes` and
`FOUNDRY_PROFILE=ci forge test`; a change under `src/core/` also prints its attribution delta
(`node tools/attrib.mjs out/<File>.sol/<Contract>.json --diff <previous report>`). Run `forge`,
`solc` and `anvil` under a watchdog and leave no process of yours behind. Keep actual failures
and tool versions in the receipt.

Use Foundry/Soldeer for Solidity. Tools use Node built-ins only, except the vector generator's
pinned viem; add a dependency only with an exact pin and a reason. Keep dependency licenses
intact and original source files marked `SPDX-License-Identifier: MIT`. Ignore generated
output, installed dependencies and local evidence.

Do not publish, deploy, push to shared branches, change repository settings or add credentials
without explicit authorization. Product questions belong in
[docs/QUESTIONS-FOR-JAMES.md](docs/QUESTIONS-FOR-JAMES.md), never resolved by code.
