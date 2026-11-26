// SPDX-License-Identifier: MIT
// The release prices like the deployed index: the work model the index answers (`workModel()`) and the Realm's floor
// prices must equal what a planner reads (deploy/plan.json, release.json `gasModel`, gas/model.json `floor`). The
// fixture's verify step compares them against a live chain (`efs-fixture.mjs verify`, "pricing"); this test checks
// the committed documents against the Solidity struct and the compiled ABI with no chain, and that a mismatch names
// its field.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { FLOOR_LIMIT_FIELDS, priceMismatches } from "../deploy-plan.mjs";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const json = (p) => JSON.parse(readFileSync(join(root, p), "utf8"));

/** The field names of `struct WorkModel` in src/interfaces/Index.sol, in declaration order. */
function solidityFields() {
  const src = readFileSync(join(root, "src/interfaces/Index.sol"), "utf8");
  const body = src.match(/struct WorkModel \{([\s\S]*?)\n\}/);
  assert.ok(body, "src/interfaces/Index.sol declares struct WorkModel");
  return [...body[1].matchAll(/^\s*(?:uint\d+|bytes32)\s+(\w+);/gm)].map((m) => m[1]);
}

test("every release document carries the WorkModel the index's ABI returns, field for field", () => {
  const fields = solidityFields();
  assert.ok(fields.includes("formulaVersion") && fields.length >= 17, `WorkModel fields: ${fields.join(", ")}`);
  const abi = json("artifacts/RealmIndex.json").abi.find((i) => i.name === "workModel");
  assert.deepEqual(abi.outputs[0].components.map((c) => c.name), fields, "artifacts/RealmIndex.json workModel() returns the Solidity struct");
  const plan = json("deploy/plan.json");
  const rel = json("release/release.json");
  const model = json("gas/model.json");
  const dep = json("release/efs-deployment.json");
  const sources = {
    "deploy/plan.json workModel": plan.workModel,
    "release/efs-deployment.json index.workModel": dep.index.workModel,
    "release.json profiles.index.workModel": rel.profiles.index.workModel,
  };
  for (const [s, sched] of Object.entries(rel.gasModel.schedules)) sources[`release.json gasModel.schedules.${s}.floor.workModel`] = sched.floor.workModel;
  for (const [s, prof] of Object.entries(model.profiles)) sources[`gas/model.json profiles.${s}.floor.workModel`] = prof.floor.workModel;
  assert.ok(Object.keys(sources).length === 7, `sources: ${Object.keys(sources).join(", ")}`);
  // the plan's work model stands in for the chain: the fixture proves the chain equals it (verify "pricing")
  assert.deepEqual(priceMismatches("workModel", fields, plan.workModel, sources), []);
  // the prague floor prices are the Realm's limits (the fixture's chains are prague-priced)
  assert.deepEqual(priceMismatches("floor.limits", FLOOR_LIMIT_FIELDS, plan.limits, {
    "release.json gasModel.schedules.prague.floor.limits": rel.gasModel.schedules.prague.floor.limits,
    "gas/model.json profiles.prague.floor.limits": model.profiles.prague.floor.limits,
  }), []);
});

test("a work-model mismatch fails and names the field", () => {
  const fields = solidityFields();
  const chain = json("deploy/plan.json").workModel;
  const changed = { ...chain, finalComputePerBind: chain.finalComputePerBind + 1 };
  assert.deepEqual(priceMismatches("workModel", fields, chain, { model: changed }), [`workModel.finalComputePerBind: chain ${chain.finalComputePerBind} != model ${chain.finalComputePerBind + 1}`]);
  const older = { ...chain, formulaVersion: 1 };
  delete older.rwPerBindLater;
  assert.deepEqual(priceMismatches("workModel", fields, chain, { model: older }), [
    `workModel.formulaVersion: chain ${chain.formulaVersion} != model 1`,
    `workModel.rwPerBindLater: chain ${chain.rwPerBindLater}, missing from model`,
  ]);
  assert.deepEqual(priceMismatches("workModel", fields, chain, { model: { ...chain, extra: 1 } }), ["workModel.extra: in model, not a field on chain"]);
  const short = { ...chain };
  delete short.finalComputePerPublish;
  assert.deepEqual(priceMismatches("workModel", fields, short, {}), ["workModel.finalComputePerPublish: the chain's reply has no such field"]);
  assert.deepEqual(priceMismatches("workModel", fields, chain, { model: undefined }), ["workModel: model has none"]);
});
