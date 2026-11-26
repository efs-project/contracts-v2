// SPDX-License-Identifier: MIT
// The planning rule (tools/gas-plan.mjs, unchanged) applied to the work model of a generation that adds one list LATER
// (docs/INDEX-BUILD.md §6, step 4, part D): the example generation of step 3b, `head-authors` in a third store
// (test/harness/HeadAuthors.sol `HeadAuthorsGenesis.workModel`), whose model has no per-purpose term, so the list's
// reservation is charged on every bind-kind action. For each shape it prints the largest publication the rule plans
// under generation 1's model (gas/model.json as committed) and under the example generation's, on both schedules.
//
// Two readings of the example generation:
//   - "reservation only": only floor.workModel changes (E and K are generation 1's), which isolates what the
//     over-reservation of TAG and FOLDER statements costs;
//   - "reservation and list": also the list's own live execution gas added to E on HEAD statements (measured,
//     test/index/HeadAuthorsFloor.t.sol: E of the example generation − E of generation 1 for the same shape, the
//     constants below), so HEAD shapes carry the list's real price as well.
//
// It reads gas/model.json only and writes nothing; no gate runs it. `node tools/gas-plan-later.mjs [--json]`.
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { planner, shapes } from "./gas-plan.mjs";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");

/** HeadAuthorsGenesis.workModel(): generation 1's model plus these increments (every bind-kind action). */
export const EXAMPLE_WORK_DELTA = { freshPerBindFresh: 10, rwPerBind: 10, rwPerBindLater: 10, computePerHookEffect: 27_000 };

/** The list's live execution gas per HEAD statement (measured cold, test/index/HeadAuthorsFloor.t.sol, E of the example
 *  generation − E of generation 1, the same shape from the same state): a first statement on a new list (create file),
 *  a later statement's counter (mask / release / restore of a BOUND head), a re-bind (an edit). */
export const LIST_LIVE = {
  prague: { first: 41_683, later: 23_100, rebind: 1_149 },
  amsterdam: { first: 32_195, later: 30_712, rebind: 1_149 },
};

/** The model with the example generation's work model on both schedules (and, with `list`, the list's E per HEAD
 *  statement added to the HEAD bind constants). */
export function exampleModel(model, { list = false } = {}) {
  const m = structuredClone(model);
  for (const [schedule, p] of Object.entries(m.profiles)) {
    const wm = p.floor.workModel;
    for (const [k, v] of Object.entries(EXAMPLE_WORK_DELTA)) wm[k] += v;
    if (!list) continue;
    const l = LIST_LIVE[schedule];
    const exec = schedule === "prague" ? p.constants : p.split.executionGas;
    exec.bindHeadFresh += l.first;
    exec.bindHeadRebind += l.rebind;
  }
  return m;
}

/** The shapes of part D: four of tools/gas-plan.mjs and plain edits (PUBLISH files-child/1 form 0 with an 18-byte
 *  document, then BIND HEAD re-bind; 2 actions a unit). */
export function laterShapes(model) {
  const s = shapes(model);
  const range = (k) => [...Array(k).keys()];
  return {
    loneNegatives: s.loneNegatives,
    firstTagsDepth8New: s.firstTagsDepth8New,
    firstTagsDepth64New: s.firstTagsDepth64New,
    createFiles: s.createFiles,
    edits: {
      what: "plain edits (PUBLISH files-child/1 form 0, 64-byte header + 18-byte document, then a HEAD re-bind)", units: 2,
      of: (k) => range(k).flatMap(() => [
        { kind: "publish", shape: "files-child/1 form 0", bytes: 96 + 18, fresh: true },
        { kind: "bind", cost: "bindHeadRebind", first: false },
      ]),
    },
  };
}

export function table(model) {
  const variants = { generation1: model, exampleReservation: exampleModel(model), exampleReservationAndList: exampleModel(model, { list: true }) };
  const out = {};
  for (const schedule of Object.keys(model.profiles)) {
    out[schedule] = {};
    for (const [name, shape] of Object.entries(laterShapes(model))) {
      const row = {};
      for (const [v, m] of Object.entries(variants)) {
        const pl = planner(m, schedule);
        const max = Math.floor(m.planning.limits.maxActions / shape.units);
        const k = pl.largest(shape.of, max);
        const at = k > 0 ? pl.check(shape.of(k)) : null;
        const next = (k + 1) * shape.units <= m.planning.limits.maxActions ? pl.check(shape.of(k + 1)) : null;
        row[v] = { k, E: at?.E, V: at?.V, prefixFloor: at?.prefixFloor, next: next ? { V: next.V, E: next.E, refused: next.refused } : "maxActions" };
      }
      out[schedule][name] = row;
    }
  }
  return out;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const model = JSON.parse(readFileSync(join(root, "gas/model.json"), "utf8"));
  const t = table(model);
  if (process.argv.includes("--json")) {
    console.log(JSON.stringify(t, null, 2));
  } else {
    for (const [schedule, rows] of Object.entries(t)) {
      for (const [name, r] of Object.entries(rows)) {
        const g = r.generation1;
        const e = r.exampleReservation;
        const l = r.exampleReservationAndList;
        console.log(`${schedule.padEnd(9)} ${name.padEnd(20)} generation 1 k=${g.k} (V ${g.V}) -> example k=${e.k} (V ${e.V}), with the list's E k=${l.k} (V ${l.V}, E ${l.E})`);
      }
    }
  }
}
