# Agent and contributor instructions

Current scope is repository foundations only. Fable owns the pending contract/link design
and implementation. Keep `src/` free of protocol contracts or interface shells until that
work is explicitly authorized. The smoke fixture is tooling evidence only.

Use the pins and root-directory commands in [README](README.md). Before proposing a change,
run frozen install, Soldeer install, `pnpm check`, `forge fmt --check`, `forge build --sizes`
and `FOUNDRY_PROFILE=ci forge test`. Keep actual failures and tool versions in the receipt.

Use Foundry/Soldeer for Solidity. Tools currently use Node built-ins only; add TypeScript or
other dependencies when actual tooling needs them, with exact pins and a reason. Keep
dependency licenses intact and original source files marked SPDX-License-Identifier: MIT.
Ignore generated output, installed dependencies and local evidence.

Do not choose protocol module names, ABIs, storage layouts, proxy patterns, Type identity,
release schemas or deployment policy through scaffolding. Do not publish, deploy, change
repository settings or add credentials. Additional implementation scope needs the owner
and contract-design review; existing foundation approval does not reopen that scope.
