# Agent and contributor instructions

The contracts are being implemented from [docs/DESIGN.md](docs/DESIGN.md) in the order of
[docs/IMPLEMENTATION-PLAN.md](docs/IMPLEMENTATION-PLAN.md) under James's 2026-10-13 mandate; the
foundation-only scope and its "no production Solidity" rule were retired on 2026-10-20 when
the design was adopted. The design is the specification: do not invent module names, ABIs,
storage layouts, identity derivations, release schemas or deployment policy that it does not
state; propose a design revision instead, with the measurement or finding that motivates it.

Use the pins and root-directory commands in [README](README.md); the release and fixture tools are
described in [tools/README.md](tools/README.md) and [tools/RELEASE.md](tools/RELEASE.md). Before committing, run frozen
install, Soldeer install, `pnpm check`, `forge fmt --check`, `forge build --sizes` and
`FOUNDRY_PROFILE=ci forge test`; a change under `src/core/` also prints its attribution delta
(`node tools/attrib.mjs out/<File>.sol/<Contract>.json --diff <previous report>`). Run `forge`,
`solc` and `anvil` under a watchdog and leave no process of yours behind. Keep actual failures
and tool versions in the receipt.

Use Foundry/Soldeer for Solidity. Tools use Node built-ins only, except the vector generator's
pinned viem; add a dependency only with an exact pin and a reason. Keep dependency licenses
intact and original source files marked `SPDX-License-Identifier: MIT`. Ignore generated
output, installed dependencies and local evidence.

Do not publish, deploy, change repository settings or add credentials without explicit
authorization. Product questions belong in
[docs/QUESTIONS-FOR-JAMES.md](docs/QUESTIONS-FOR-JAMES.md), never resolved by code.

## Pushing to `main` during the MVP push

James authorized direct pushes to `main` on 2026-11-25, for the MVP push only (recorded in the
planning vault's `Decisions.md` under that date, and confirmed to the contracts session the same
day): "Yes you may push to main during this MVP push. We are iterating fast and I don't want
that to eat up PR numbers and waste GitHub resources. Use PRs where it makes sense. But once MVP
is finished we should go back to the industry standard model."

- Low-risk work (docs, tests, tooling) goes to `main` once the local gates above pass.
- Kernel changes, anything that moves the release surface and anything the SDK vendors go to a
  branch first. The integration owner reviews the head, and the branch is then merged into `main`
  without a pull request.
- Never force-push `main` or rewrite pushed history. Fixes go forward as new commits.
- Open a pull request where it makes sense: something really big, such as a release about to be
  deployed somewhere public.
- When the MVP is finished this section lapses: changes reach `main` through reviewed pull
  requests again, and pushing to any other shared branch still needs explicit authorization.
