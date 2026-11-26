// SPDX-License-Identifier: MIT
// gas/model.json: a per-action gas model for the SDK's write planner, so a large write can be split into
// publications without one eth_estimateGas round trip per guess (eth_estimateGas stays the authority before sending).
// It runs test/integration/GasModel.t.sol with `--json -vv` under the default profile (prague, the release bytes,
// out/) and the `amsterdam` profile (EIP-8037/8038, its own out/amsterdam + cache/amsterdam so the identity build in
// out/ is never touched), reads the "model <key> frame gas" lines (and "frame state gas" under amsterdam), fits
//
//   gas(publication) = fixed + Σ cost(action)
//   cost(PUBLISH new, shape S, body n bytes) = base[S] + perWord·ceil(n/32) + perByte·n
//   cost(PUBLISH existing), cost(REUSE), cost(CREATE), cost(BIND fresh|rebind, purpose), cost(UNBIND|RELEASE, purpose),
//   cost(BIND TAG number change) (a REBIND to the same target with a new strength), cost(UNBIND TAG lone) (a first mask),
//   cost(BIND PROPERTY fresh|rebind), cost(BIND SAME fresh word|path), cost(BIND BROADER fresh), cost(UNBIND|RELEASE,
//   PROPERTY|SAME|BROADER), cost(restore SAME|BROADER), cost(WITHDRAW), plus firstWriteSurcharge once for a principal
//   that has never written
//   cost(first TAG on an n-word topic) = bindTagFresh | bindTagSecondAuthor (fresh | existing position)
//     + Σ over the n − 1 proper ancestors: tagLevel.mine{New|Existing}
//       + (fresh position or a first yes ? tagLevel.shared{New|Existing} : 0)
//
//   cost(LATER statement) by the list tiers (laterLists; tools/gas-plan.mjs laterKey): the author's list at the place
//     has ≤ 48 entries: the row, or <row>NewPlace for the first later statement at its place in the publication;
//     more, or unknown: <row>LongNewPlace (first at its place) | <row>LongSamePlace (the rest), measured at entry 1,024;
//     a re-bind never searches the list and has no tier
//
// and predicts the suite's validation composites (never fitted). Exit 1 when a validation error within the claim
// exceeds 15% (all gas, and execution gas on amsterdam; composites in state beyondClaim are reported, not bounded).
//
// The floor (design §10.4). Every measured publication is also run with the index's callbacks answered by
// `vm.mockCall` ("model <key> kernel frame gas"); the same fit of those rows is `floor.<schedule>.kernel`, the kernel's
// own execution gas. `floor` also carries the kernel's quote inputs exactly (the work model and the Realm's floor
// prices from tools/deploy-plan.mjs, the per-Type refs and digest specs the suite logs, the 63/64 rule and the
// dispatch overhead) and `planning` the rule a planner sizes a publication by (tools/gas-plan.mjs implements it).
// `ILedgerCommitments.indexFloor` prices every bind as a first statement and is an upper bound on the prefix floor only:
// a consumer plans from the model's rule.
//
// `--check 1` (`pnpm gas:model:check`, CI) writes nothing: it re-measures, refits and exits 1 when a checked profile's
// validation error exceeds 15% or when its fitted constants or measured rows differ from the committed gas/model.json
// (gas is deterministic for identical bytecode, so the comparison is exact). `--skip-amsterdam 1` checks prague only.
//
//   node tools/gas-model.mjs [--skip-amsterdam 1] [--check 1]
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { GAS_SCHEDULES, GLAMSTERDAM_FLOOR, LIMITS, WORK_MODEL, parseArgs, root, toJSON, validate } from "./deploy-plan.mjs";
import { FIXED_ANCHORS, allGasOverBoundPercent, fixedFrom, overBound as overBoundOf } from "./gas-fit.mjs";
import { historyWordAdds, laterKey } from "./gas-plan.mjs";

const o = parseArgs(process.argv.slice(2), ["skip-amsterdam", "check"]);
const CHECK = !!o.check && o.check !== "0";
const SUITE = "test/integration/GasModel.t.sol";
const LIMIT_PERCENT = 15;
/** One fresh slot's state gas on amsterdam (EIP-8037; tools/deploy-plan.mjs GAS_SCHEDULES, the single source). */
const FRESH_SLOT_STATE_GAS = GAS_SCHEDULES.amsterdam.freshSlot.stateGas;
const git = (...args) => { try { return execFileSync("git", args, { cwd: root }).toString().trim(); } catch { return null; } };

function run(profile) {
  const env = { ...process.env, FOUNDRY_PROFILE: profile };
  if (profile !== "default") Object.assign(env, { FOUNDRY_OUT: `out/${profile}`, FOUNDRY_CACHE_PATH: `cache/${profile}` });
  const r = spawnSync("perl", ["-e", "alarm 900; exec @ARGV", "forge", "test", "--match-path", SUITE, "--json", "-vv"], { cwd: root, env, encoding: "utf8", timeout: 900_000, maxBuffer: 256 << 20 });
  const start = r.stdout.indexOf("{");
  assert.ok(start >= 0, `forge test (${profile}) printed no JSON (exit ${r.status}): ${r.stderr.slice(-3000)}`);
  const json = JSON.parse(r.stdout.slice(start));
  const rows = {};
  const types = {};
  for (const result of Object.values(json)) {
    for (const [test, res] of Object.entries(result.test_results)) {
      assert.equal(res.status, "Success", `${profile}: ${test} ${res.status} ${res.reason ?? ""}`);
      for (const line of res.decoded_logs ?? []) {
        const t = line.match(/^model type (\S+) (refs|specs): (\d+)$/);
        if (t) {
          (types[t[1]] ??= {})[t[2]] = Number(t[3]);
          continue;
        }
        const m = line.match(/^model (.*?) (kernel frame gas|frame state gas|frame gas|gas): (-?\d+)$/);
        if (!m) continue;
        rows[m[1]] ??= { key: m[1], test };
        rows[m[1]][{ gas: "gas", "frame gas": "frameGas", "frame state gas": "frameStateGas", "kernel frame gas": "kernelFrameGas" }[m[2]]] = Number(m[3]);
      }
    }
  }
  assert.ok(Object.keys(types).length > 0, `${profile}: no "model type" lines (test_model_floor_types)`);
  return { rows: Object.values(rows).sort((a, b) => a.key.localeCompare(b.key)), types };
}

const words = (n) => Math.ceil(n / 32);

// The PUBLISH shapes the suite measures with their body length in bytes (GasModel.t.sol; the record bodies of
// src/lib/EfsFiles.sol). Bytes sizes fit the slopes; every other shape gets its own base.
const BYTES_SIZES = [64, 100, 1000, 1024, 4096, 8192];
const SHAPES = {
  "files-span/1": [["pub span", 96]],
  "files-content/1 carrier 0": [["pub content c0", 320]],
  "files-content/1 carrier 2": [["pub content c2", 320]],
  "files-external/1": [["pub external 40", 264], ["pub external 400", 624]],
  "files-directory/1": [["pub directory", 64]],
  "files-name/3": [["pub name 12", 12], ["pub name 200", 200]],
  "files-root/1 form 0": [["pub root f0", 164]],
  "files-root/1 form 1": [["pub root f1", 96]],
  "files-child/1 form 0": [["pub child f0", 196]],
  "files-child/1 form 1": [["pub child f1", 128]],
  "topic-word/1": [["pub topic word 12", 12], ["pub topic word 40", 40]],
  "topic/1": [["pub topic", 64]],
  "text/1": [["pub text 24", 24]],
};
const ACTIONS = {
  publishExisting: "pub existing",
  reuse: "reuse",
  create: "create",
  bindHeadFresh: "bind head fresh",
  bindHeadRebind: "bind head rebind",
  bindFolderFreshFile: "bind folder fresh file",
  bindFolderFreshDirectory: "bind folder fresh dir",
  bindFolderRebind: "bind folder rebind",
  unbindFolder: "unbind folder",
  releaseFolder: "release folder",
  restoreFolder: "restore folder",
  bindTagFresh: "bind tag fresh",
  bindTagSecondAuthor: "bind tag second author",
  bindTagNumberChange: "bind tag number change",
  unbindTagLone: "unbind tag lone",
  unbindTag: "unbind tag",
  releaseTag: "release tag",
  restoreTag: "restore tag",
  // statements about topics (design §12.5): PROPERTY (a label: labelKey("en") → an existing text/1), SAME (word page
  // to word page, or 2-word path to path) and BROADER (word page to word page); each first statement and its later
  // statements
  bindPropertyFresh: "bind property fresh",
  bindPropertyRebind: "bind property rebind",
  unbindProperty: "unbind property",
  releaseProperty: "release property",
  bindSameFreshWord: "bind same fresh word",
  bindSameFreshPath: "bind same fresh path",
  unbindSame: "unbind same",
  releaseSame: "release same",
  restoreSame: "restore same",
  bindBroaderFresh: "bind broader fresh",
  unbindBroader: "unbind broader",
  releaseBroader: "release broader",
  restoreBroader: "restore broader",
  withdraw: "withdraw",
  // the list tiers (laterLists; GasModel.t.sol section 9): TAG and FOLDER rows at a place new to the publication (their
  // single-place rows are measured at ONE topic or folder), and for every later statement that searches the author's
  // list (masks, releases, restores) the rows at entry 1,024 of a 1,025-entry list, first at its place and not
  unbindTagNewPlace: "unbind tag new place",
  releaseTagNewPlace: "release tag new place",
  restoreTagNewPlace: "restore tag new place",
  bindTagNumberChangeNewPlace: "bind tag number change new place",
  unbindFolderNewPlace: "unbind folder new place",
  releaseFolderNewPlace: "release folder new place",
  restoreFolderNewPlace: "restore folder new place",
  bindFolderRebindNewPlace: "bind folder rebind new place",
  ...Object.fromEntries(
    [["unbindTag", "unbind tag"], ["releaseTag", "release tag"], ["restoreTag", "restore tag"], ["unbindFolder", "unbind folder"], ["releaseFolder", "release folder"], ["restoreFolder", "restore folder"],
      ["unbindProperty", "unbind property"], ["releaseProperty", "release property"], ["unbindSame", "unbind same"], ["releaseSame", "release same"], ["restoreSame", "restore same"],
      ["unbindBroader", "unbind broader"], ["releaseBroader", "release broader"], ["restoreBroader", "restore broader"]]
      .flatMap(([name, key]) => [[`${name}LongNewPlace`, `${key} long new place`], [`${name}LongSamePlace`, `${key} long same place`]]),
  ),
  // the list release's later rows (GasModel.t.sol sections 4, 9 and the tier tests with `afterNo`/`newTarget`): a BIND on
  // a head that never bound (a yes after a lone no), the restore of a label, HEAD masks, releases and restores, and
  // the restore at a word-opening position that `historyWordOpen` is derived from
  bindTagAfterNo: "bind tag after no",
  bindFolderAfterNo: "bind folder after no",
  bindPropertyAfterNo: "bind property after no",
  bindSameAfterNo: "bind same after no",
  bindBroaderAfterNo: "bind broader after no",
  bindHeadAfterNo: "bind head after no",
  bindTagAfterNoNewPlace: "bind tag after no new place",
  bindFolderAfterNoNewPlace: "bind folder after no new place",
  restoreProperty: "restore property",
  unbindHead: "unbind head",
  releaseHead: "release head",
  restoreHead: "restore head",
  restoreTagAtHistoryWord: "restore tag at history word",
  ...Object.fromEntries(
    [["bindTagAfterNo", "bind tag after no"], ["bindFolderAfterNo", "bind folder after no"], ["bindPropertyAfterNo", "bind property after no"],
      ["bindSameAfterNo", "bind same after no"], ["bindBroaderAfterNo", "bind broader after no"], ["restoreProperty", "restore property"]]
      .flatMap(([name, key]) => [[`${name}LongNewPlace`, `${key} long new place`], [`${name}LongSamePlace`, `${key} long same place`]]),
  ),
};
/** Rows measured for their notes only (never constants): restores to the KEPT target, against which the new-target
 *  restore rows state their over-price (no planner can select them: the head view does not show the stored target). */
const SAME_TARGET = { restoreFolder: "restore folder same target", restoreProperty: "restore property same target", restoreHead: "restore head same target" };

/** The measured statement position of every later row (design §10.4; GasModel.t.sol): the head's revision before the
 *  measured statement, whether the binding's history list opened a word for it, and for a BIND which target it named. */
function laterRowOf(name) {
  if (name === "unbindTagLone") return null; // a first statement
  if (name === "restoreTagAtHistoryWord") return { revisionBefore: 5, opensHistoryWord: true, target: "same" };
  let m = name.match(/^(unbind|release)(Tag|Folder|Property|Same|Broader|Head)(NewPlace|LongNewPlace|LongSamePlace)?$/);
  if (m) return { revisionBefore: 1, opensHistoryWord: true, target: null };
  m = name.match(/^restore(Tag|Folder|Property|Same|Broader|Head)(NewPlace|LongNewPlace|LongSamePlace)?$/);
  if (m) return { revisionBefore: 2, opensHistoryWord: false, target: ["Folder", "Property", "Head"].includes(m[1]) ? "new" : "same" };
  if (/^bind(Tag|Folder|Property|Same|Broader|Head)AfterNo(NewPlace|LongNewPlace|LongSamePlace)?$/.test(name)) return { revisionBefore: 1, opensHistoryWord: true, target: "neverBound" };
  if (/^bindTagNumberChange(NewPlace)?$/.test(name)) return { revisionBefore: 1, opensHistoryWord: true, target: "same" };
  if (/^bind(Folder|Property|Head)Rebind(NewPlace)?$/.test(name)) return { revisionBefore: 1, opensHistoryWord: true, target: "new" };
  return null;
}
const LATER_ROWS = {
  rule: "Every later row (a statement on a head that is not UNSET) is measured at one position of its binding, stated in `rows`: `revisionBefore`, the head's revision before the measured statement (a head's revision counts every statement of its binding); `opensHistoryWord`, whether the binding's history list opened a word for it (PostingStore._append opens one when the list's count before the append, which equals the revision before, is 1 or a positive multiple of 5: the binding's 2nd, 6th, 11th, 16th statement and every fifth after); and for a BIND `target`: \"same\" (the head's stored target), \"new\" (another target, already placed elsewhere: the kernel rewrites its stored target and the target's backlink append takes a fresh word, the dearest case), \"neverBound\" (the head never bound: the kernel writes its stored target fresh), null for an UNBIND or RELEASE. A planner selects the row from the head it reads (LedgerReads.head or LedgerViews.headsAt: state, revision, targetKind) and the action alone: an UNBIND or RELEASE of a BOUND or MASKED head is unbind<P> or release<P>; a BIND on a BOUND head is a re-bind (bind<P>Rebind, or bindTagNumberChange for TAG); a BIND on a MASKED or RELEASED head is bind<P>AfterNo when targetKind == 0 (the head never bound: Head.targetKind is served as stored and is 0 exactly for a head that never bound, while Head.target is 0 for every masked or released head) and restore<P> otherwise; the list tiers (laterLists) then choose among the row and its tier constants. A statement at another position of its binding than its row's differs by the binding's history word: when its revision before opens a word (1, or a positive multiple of 5) and its row's opensHistoryWord is false, add the profile's historyWordOpen constant to E (and its floor.kernel share, which is zero, to K); when its row's opensHistoryWord is true and its revision before opens none, subtract it (symmetric; tools/gas-plan.mjs historyWordAdds, when a bind action carries `revisionBefore`; without it the row is used as it is). The history list's length before a statement is the head's revision (RealmIndex._foldBind appends one entry per statement of every kind, first statements included), and the kernel refuses a BIND, UNBIND or RELEASE whose expected revision is not the head's (E_CAS, nothing written), so a correction made from a stale revision is refused, never admitted under-priced. Nothing else is added by hand: the kernel's stored-target write of a yes after a lone no is in the AfterNo rows, and a restore to a new target's rewrite in the restore rows of FOLDER, PROPERTY and HEAD.",
  note: "historyWordOpen = restoreTagAtHistoryWord − restoreTag: a restore measured as the binding's sixth statement (revision 5 before it, a word opens) against the same restore as its third (none opens), at one topic. TAG, SAME and BROADER restores cannot name a new target (the target is the role), so their restore rows name the stored one. FOLDER, PROPERTY and HEAD restore rows name a new target already placed elsewhere, the dearest restore; a restore to the stored target is over-priced by the kernel's target rewrite (each row's `note`), and a restore to a target never placed before costs less than either (its backlink list's first entry sits in the list's head). Every restore and every yes after a lone no row is measured with its target's backlink list at a word-opening count (one entry before it, its word 0 opening), the dearest state; a planner cannot see that list, so a statement whose target's backlink list is at another count is over-priced by one fresh slot less a rewrite (prague about 17,100 gas; amsterdam about 97,920 of state gas and no execution gas). Re-binds have no tier; HEAD rows have no tiers (a file's HEAD scope list holds one entry per author, the HEAD itself, so every HEAD statement is at a list of one entry and at a place of its own).",
};
/** The list tiers (design §10.4; read by tools/gas-plan.mjs laterKey). */
const LATER_LISTS = {
  shortTierMaxEntries: 48,
  claimEntries: 1024,
  rule: "A LATER statement (a planner bind action with first false: a mask, release, restore or re-bind) is priced by its place and the author's entry count there. Its place is (purpose, subject): the author's scope list keyed by (author, purpose, subject), which holds one entry per position the author has ever stated at that subject (masked and released ones included); `entries` is that list's length (IBitmapStore.scopeHead(Keys.scope(author, purpose, subject)).count, as TopicLookupReader.entryCount(author, purpose, place, false, …) returns it). `firstAtPlace` is true when no earlier later statement of the same publication is at the same place, of any kind. Short tier (entries known and ≤ shortTierMaxEntries): the row, or <row>NewPlace for the first later statement at its place when the constants carry one. Long tier (entries > shortTierMaxEntries, or unknown): <row>LongNewPlace when first at its place, else <row>LongSamePlace, measured at entry 1,024 of a 1,025-entry list (claimEntries). A row with no <row>LongNewPlace (a re-bind: a BIND on a BOUND head, which never searches the list) has no tier: <row>NewPlace when first at its place and the constants carry one, else the row.",
  note: "Cost depends on the list's length (RealmIndex._entryIndex bisects it, one store call per probe) and on the changed entry's index (an entry from 48 up has its live bit in a word of its own); a list of at most 48 entries bounds both. A count lower than the truth (a stale read) puts a long list in the short tier and under-prices it, so treat a count older than what the planner trusts as unknown. Above claimEntries the long tier is still applied but is outside what the stated maxima cover (state beyondClaim), as the floor's documented exception is.",
};

/** The `laterRows` document without its measured notes (predict reads the positions). */
const LATER_ROWS_DOC = {
  ...LATER_ROWS,
  rows: Object.fromEntries(Object.keys(ACTIONS).map((name) => [name, laterRowOf(name)]).filter(([, v]) => v)),
};

// The per-level terms of a first tag (design §10.4): each row's k1 tags a 2-word topic and k2 a 6-word topic from the
// same state, so (k2 − k1) / LEVEL_SPAN is one level of the ancestor walk in that case.
const LEVEL_SPAN = 4;
const LEVEL_ROWS = { allNew: "tag level all new", allExisting: "tag level all existing", mineNew: "tag level mine new", mineExisting: "tag level mine existing" };

// The composites (GasModel.t.sol `test_model_validate_*`), as the planner would describe them, each in the state it
// is measured in: "listsNew" (the author's lists at the positions it touches are new), "listsExist" (the ordinary
// case), and for later statements (section 8) "acrossPlaces" (at distinct places, the author's lists short: at most 48
// entries), "acrossPlacesBitsWord" (at entry 48 of 49, alone in its bits word), "longLists" (lists of 1,025 entries,
// the floor's claim) and "beyondClaim" (4,097 entries: reported, never counted in the stated maxima or the bound).
const pub = (shape, n) => ({ publish: shape, n });
const levels = (level, n) => ({ level, n });
/** A later statement as the planner describes it (tools/gas-plan.mjs laterKey). */
const later = (cost, firstAtPlace, entries, revisionBefore) => ({ later: cost, firstAtPlace, entries, ...(revisionBefore === undefined ? {} : { revisionBefore }) });
/** k later statements `cost`, each at its own place whose list holds `entries`. */
const acrossK = (cost, k, entries) => Array.from({ length: k }, () => later(cost, true, entries));
/** k later statements `cost` at one place whose list holds `entries`. */
const oneK = (cost, k, entries) => Array.from({ length: k }, (_, i) => later(cost, i === 0, entries));
const BEYOND_CLAIM = "beyondClaim";
/** The removed-names composites (GasModel.t.sol `_sizes`): [create, withName, k] for k = 2 and the planner's largest
 *  batch of the shape on each schedule (the constants CREATE_REMOVED_* and MOVE_REMOVED_* there). */
const REMOVED_NAMES = [
  ...[[true, true, [2, 11, 12]], [true, false, [2, 13, 16]], [false, true, [2, 18, 19]], [false, false, [2, 25, 25]]]
    .flatMap(([create, withName, ks]) => [...new Set(ks)].map((k) => [create, withName, k])),
];
const VALIDATION = [
  { state: "listsNew", key: "validate create file", what: "M1 create file: CREATE, PUBLISH root form 0 (18-byte document), PUBLISH name (10 B), BIND HEAD, BIND FOLDER (first entry of a folder)",
    actions: ["create", pub("files-root/1 form 0", 82), pub("files-name/3", 10), "bindHeadFresh", "bindFolderFreshFile"] },
  { state: "listsNew", key: "validate edit", what: "edit: PUBLISH child form 0 (18-byte document), BIND HEAD rebind",
    actions: [pub("files-child/1 form 0", 114), "bindHeadRebind"] },
  { state: "listsNew", key: "validate rename move", what: "rename + move (EfsFiles.move): PUBLISH name (9 B), RELEASE FOLDER, BIND FOLDER fresh (another folder)",
    actions: [pub("files-name/3", 9), later("releaseFolder", true, 1), "bindFolderFreshFile"] },
  { state: "listsNew", key: "validate two chunks", what: "two 8,192-byte files-bytes/1 records (16,384 body bytes, the publication cap)",
    actions: [pub("files-bytes/1", 8192), pub("files-bytes/1", 8192)] },
  { state: "listsNew", key: "validate 40kb last publication", what: "last publication of a 40,000-byte file: chunk 4 (7,392 B), four spans, files-content/1 carrier 2, CREATE, root form 1, name (7 B), BIND HEAD, BIND FOLDER",
    actions: [pub("files-bytes/1", 7392), pub("files-span/1", 96), pub("files-span/1", 96), pub("files-span/1", 96), pub("files-span/1", 96), pub("files-content/1 carrier 2", 320), "create", pub("files-root/1 form 1", 96), pub("files-name/3", 7), "bindHeadFresh", "bindFolderFreshFile"] },
  { state: "listsNew", key: "validate tag 6 words all new", what: "a first tag on a fresh 6-word path: the fresh-position term plus five levels, every per-author and shared roll-up new",
    actions: ["bindTagFresh", levels("mineNew", 5), levels("sharedNew", 5)] },
  { state: "listsNew", key: "validate label new text", what: "a label with its text (EfsTopics.label): PUBLISH a new 24-byte text/1, BIND PROPERTY labelKey(\"en\") to it (a first statement)",
    actions: [pub("text/1", 24), "bindPropertyFresh"] },
  // the ordinary state: the author's lists exist (a folder that already holds one of the author's files, a file
  // already edited, a folder that already holds the author's entries, roll-ups that already hold entries)
  { state: "listsExist", key: "validate create file lists exist", what: "M1 create file in a folder that already holds one of the author's files: CREATE, PUBLISH root form 0 (18-byte document), PUBLISH name (10 B), BIND HEAD, BIND FOLDER",
    actions: ["create", pub("files-root/1 form 0", 82), pub("files-name/3", 10), "bindHeadFresh", "bindFolderFreshFile"] },
  { state: "listsExist", key: "validate edit lists exist", what: "a second edit of a file: PUBLISH child form 0 (18-byte document), BIND HEAD rebind",
    actions: [pub("files-child/1 form 0", 114), "bindHeadRebind"] },
  { state: "listsExist", key: "validate rename move lists exist", what: "rename + move into a folder that already holds the author's entries: PUBLISH name (9 B), RELEASE FOLDER, BIND FOLDER fresh",
    actions: [pub("files-name/3", 9), later("releaseFolder", true, 2), "bindFolderFreshFile"] },
  { state: "listsExist", key: "validate tag 6 words all existing", what: "a first tag on an existing 6-word path, every per-author and shared roll-up holding two entries: the fresh-position term plus five existing levels",
    actions: ["bindTagFresh", levels("mineExisting", 5), levels("sharedExisting", 5)] },
  // later statements across places and in long lists (GasModel.t.sol sections 8 and 9b)
  ...[
    ["across topics", "acrossPlaces", (c) => acrossK(c, 32, 1), true],
    ["at entry 47 across topics", "acrossPlaces", (c) => acrossK(c, 32, 48), false],
    ["at entry 48 across topics", "acrossPlacesBitsWord", (c) => acrossK(c, 32, 49), false],
    ["at entry 1024 across topics", "longLists", (c) => acrossK(c, 16, 1025), false],
    ["at entry 4096 across topics", BEYOND_CLAIM, (c) => acrossK(c, 8, 4097), false],
    ["of 32 entries of 1025 at one topic", "longLists", (c) => oneK(c, 32, 1025), false],
  ].flatMap(([what, state, of, numbers]) => [
    ["masks", "unbindTag"], ["releases", "releaseTag"], ["restores", "restoreTag"], ...(numbers ? [["number changes", "bindTagNumberChange"]] : []),
  ].map(([kind, cost]) => ({ state, key: `validate tag ${kind} ${what}`, what: `tag ${kind} ${what}${state === BEYOND_CLAIM ? " (BEYOND THE CLAIM: reported, not in the stated maxima)" : ""}`, actions: of(cost) }))),
  { state: "longLists", key: "validate tag number changes of 32 entries of 1025 at one topic", what: "tag number changes (re-binds: no tier) of 32 spread entries of a 1,025-entry list at one topic", actions: oneK("bindTagNumberChange", 32, 1025) },
  ...[
    ["across folders", "acrossPlaces", (c) => acrossK(c, 32, 1), ["masks", "releases", "re-binds", "restores"]],
    ["at entry 48 across folders", "acrossPlacesBitsWord", (c) => acrossK(c, 32, 49), ["masks", "releases", "restores"]],
    ["at entry 1024 across folders", "longLists", (c) => acrossK(c, 16, 1025), ["masks", "releases", "restores"]],
    ["of 8 entries of 1025 in one folder", "longLists", (c) => oneK(c, 8, 1025), ["masks", "releases", "re-binds", "restores"]],
  ].flatMap(([what, state, of, kinds]) => kinds.map((kind) => ({ state, key: `validate folder ${kind} ${what}`, what: `folder ${kind} ${what}`,
    actions: of({ masks: "unbindFolder", releases: "releaseFolder", "re-binds": "bindFolderRebind", restores: "restoreFolder" }[kind]) }))),
  ...[["property", "unbindProperty"], ["same", "unbindSame"], ["broader", "unbindBroader"]].map(([p, cost]) => ({ state: "longLists", key: `validate ${p} masks of 8 entries of 1025 at one topic`,
    what: `${p.toUpperCase()} masks of 8 spread entries of a 1,025-entry list at one topic`, actions: oneK(cost, 8, 1025) })),
  // the list release: a yes after a lone no, its later variants, a restore at a word-opening position, folders, HEADs
  // (GasModel.t.sol section 10)
  { state: "acrossPlaces", key: "validate tag yeses after lone noes across 32 topics of 48", what: "yeses after lone noes across 32 topics, each list 48 lone noes (count known: the short tier), each thing linked once", actions: acrossK("bindTagAfterNo", 32, 48) },
  { state: "withinClaim", key: "validate tag yeses after lone noes across 32 topics of 256", what: "yeses after lone noes across 32 topics, each list 256 lone noes (the long tier)", actions: acrossK("bindTagAfterNo", 32, 256) },
  { state: "longLists", key: "validate tag yeses after lone noes across 16 topics of 1025", what: "yeses after lone noes across 16 topics, each list 1,025 lone noes, the yes at entry 1,024", actions: acrossK("bindTagAfterNo", 16, 1025) },
  { state: "longLists", key: "validate tag yeses after lone noes of 32 entries of 1025 at one topic", what: "yeses after 32 spread lone noes of a 1,025-entry list at one topic", actions: oneK("bindTagAfterNo", 32, 1025) },
  { state: "acrossPlaces", key: "validate tag yeses after no then release across 32 topics", what: "no → release → yes across 32 topics (revision 2 before the yes: no history word; priced by bindTagAfterNo with revisionBefore 2)", actions: Array.from({ length: 32 }, () => later("bindTagAfterNo", true, 1, 2)) },
  { state: "acrossPlaces", key: "validate tag yeses after no then no across 32 topics", what: "no → no → yes across 32 topics (revision 2 before the yes)", actions: Array.from({ length: 32 }, () => later("bindTagAfterNo", true, 1, 2)) },
  { state: "acrossPlaces", key: "validate tag restores at revision 5 across 32 topics", what: "restores as the binding's sixth statement (revision 5 before them: a history word opens; restoreTag + historyWordOpen) across 32 topics", actions: Array.from({ length: 32 }, () => later("restoreTag", true, 1, 5)) },
  { state: "acrossPlaces", key: "validate folder yeses after hides across 32 folders", what: "binds after hides of entries never bound, across 32 folders holding the one hide, each file placed once elsewhere", actions: acrossK("bindFolderAfterNo", 32, 1) },
  { state: "acrossPlaces", key: "validate folder yeses after hide then release across 32 folders", what: "hide → release → bind across 32 folders (revision 2 before the bind)", actions: Array.from({ length: 32 }, () => later("bindFolderAfterNo", true, 1, 2)) },
  { state: "acrossPlaces", key: "validate folder yeses after hide then hide across 32 folders", what: "hide → hide → bind across 32 folders (revision 2 before the bind)", actions: Array.from({ length: 32 }, () => later("bindFolderAfterNo", true, 1, 2)) },
  { state: "longLists", key: "validate folder yeses after hides at entry 1024 across 16 folders", what: "binds after hides at entry 1,024 of 1,025-entry folders, across 16 folders", actions: acrossK("bindFolderAfterNo", 16, 1025) },
  { state: "longLists", key: "validate folder yeses after hides of 8 entries of 1025 in one folder", what: "binds after 8 spread hides of a 1,025-entry folder", actions: oneK("bindFolderAfterNo", 8, 1025) },
  { state: "acrossPlaces", key: "validate folder restores to new targets across 32 folders", what: "restores of hidden entries to new files already placed elsewhere, across 32 folders holding one entry", actions: acrossK("restoreFolder", 32, 1) },
  { state: "acrossPlaces", key: "validate head masks across 32 files", what: "masks of 32 files' HEADs (BOUND, revision 1)", actions: acrossK("unbindHead", 32, 1) },
  { state: "acrossPlaces", key: "validate head releases across 32 files", what: "releases of 32 files' HEADs", actions: acrossK("releaseHead", 32, 1) },
  { state: "acrossPlaces", key: "validate head restores to new revisions across 32 files", what: "restores of 32 masked HEADs to child revisions a second author's HEAD names", actions: acrossK("restoreHead", 32, 1) },
  { state: "acrossPlaces", key: "validate head yeses after lone noes across 32 files", what: "a second author's yeses after its lone noes on 32 files, naming the roots the first author's HEADs name", actions: acrossK("bindHeadAfterNo", 32, 1) },
  ...REMOVED_NAMES.flatMap(([create, withName, k]) => {
    const how = withName ? "name repeated" : "no name publish";
    const removed = Array.from({ length: k }, (_, j) => create
      ? ["create", pub("files-root/1 form 0", 82), ...(withName ? ["publishExisting"] : []), "bindHeadFresh", later("restoreFolder", j === 0, k)]
      : [...(withName ? ["publishExisting"] : []), later("releaseFolder", j === 0, k), later("restoreFolder", j === 0, k)]).flat();
    const fresh = Array.from({ length: k }, (_, j) => create
      ? ["create", pub("files-root/1 form 0", 82), ...(withName ? [pub("files-name/3", 10)] : []), "bindHeadFresh", "bindFolderFreshFile"]
      : [...(withName ? [pub("files-name/3", 10)] : []), later("releaseFolder", j === 0, k), "bindFolderFreshFile"]).flat();
    const freshHow = withName ? "name published" : "no name publish";
    return create
      ? [
        { state: "listsExist", key: `validate create ${k} files at removed names, ${how}`, what: `${k} create-file recipes at names the author removed from the root folder (the folder bind restores a RELEASED head to the new file), ${withName ? "each name PUBLISH a repeat (publishExisting)" : "no name PUBLISH"}`, actions: removed },
        { state: "listsNew", key: `validate create ${k} files at fresh names, ${freshHow}`, what: `the same ${k} create-file recipes at fresh names (an ordinary batch, for comparison), ${withName ? "each name PUBLISH new" : "the names published before"}`, actions: fresh },
      ]
      : [
        { state: "listsExist", key: `validate move ${k} files into removed names, ${how}`, what: `${k} moves into names the author removed from a folder (RELEASE at the old place, restore at the new), ${withName ? "each name PUBLISH a repeat (publishExisting)" : "no name PUBLISH"}`, actions: removed },
        { state: "listsNew", key: `validate move ${k} files to fresh names, ${freshHow}`, what: `the same ${k} moves to fresh names (an ordinary batch, for comparison), ${withName ? "each name PUBLISH new" : "the names published before"}`, actions: fresh },
      ];
  }),
  { state: "acrossPlaces", key: "validate untag a file from six topics", what: "untag one file from six topics (six RELEASEs), the author's list at each holding three entries", actions: acrossK("releaseTag", 6, 3) },
  { state: "acrossPlaces", key: "validate delete six files from three folders", what: "delete (RELEASE) six files from three folders, two from each, each folder holding four of the author's entries",
    actions: Array.from({ length: 6 }, (_, i) => later("releaseFolder", i % 2 === 0, 4)) },
];

/** Least squares y = X·β (normal equations, Gaussian elimination; tiny systems). */
function lsq(X, y) {
  const k = X[0].length;
  const A = Array.from({ length: k }, (_, i) => Array.from({ length: k + 1 }, (_, j) => (j < k ? X.reduce((s, r) => s + r[i] * r[j], 0) : X.reduce((s, r, t) => s + r[i] * y[t], 0))));
  for (let c = 0; c < k; c++) {
    let p = c;
    for (let r = c + 1; r < k; r++) if (Math.abs(A[r][c]) > Math.abs(A[p][c])) p = r;
    [A[c], A[p]] = [A[p], A[c]];
    for (let r = 0; r < k; r++) {
      if (r === c) continue;
      const f = A[r][c] / A[c][c];
      for (let j = c; j <= k; j++) A[r][j] -= f * A[c][j];
    }
  }
  return A.map((r, i) => r[k] / r[i]);
}
const round = (x) => Math.round(x);

/** Constants from one measured quantity per row (`q(row)`: prague frame gas, amsterdam total / execution / state). */
function fit(rows, q) {
  const by = Object.fromEntries(rows.map((r) => [r.key, r]));
  const get = (k) => { assert.ok(by[k], `no "model ${k}" measurement`); return q(by[k]); };
  const marginal = (key) => get(`${key} k2`) - get(`${key} k1`);
  const impliedFixed = (key) => 2 * get(`${key} k1`) - get(`${key} k2`);
  // slopes and the files-bytes/1 base from the bytes sizes
  const bytesKeys = BYTES_SIZES.map((n) => `pub bytes ${n}`);
  const [bytesBase, perWord, perByte] = lsq(BYTES_SIZES.map((n) => [1, words(n), n]), bytesKeys.map(marginal));
  const body = (n) => perWord * words(n) + perByte * n;
  const publishBase = { "files-bytes/1": bytesBase };
  const publishBaseBySize = {};
  for (const [shape, sizes] of Object.entries(SHAPES)) {
    const each = sizes.map(([key, n]) => marginal(key) - body(n));
    publishBase[shape] = each.reduce((s, x) => s + x, 0) / each.length;
    if (sizes.length > 1) publishBaseBySize[shape] = Object.fromEntries(sizes.map(([, n], i) => [n, round(each[i])]));
  }
  const action = Object.fromEntries(Object.entries(ACTIONS).map(([name, key]) => [name, marginal(key)]));
  // one history word: the same restore at a word-opening position against its row (LATER_ROWS.note)
  action.historyWordOpen = action.restoreTagAtHistoryWord - action.restoreTag;
  const sameTarget = Object.fromEntries(Object.entries(SAME_TARGET).map(([name, key]) => [name, marginal(key)]));
  // the fixed cost: 2·k1 − k2 of every k1/k2 pair is kept (fit.impliedFixedByPair), and `fixed` is their median over
  // the anchor pairs only (tools/gas-fit.mjs), so a row added later never changes the price of an existing action
  const pairs = [...bytesKeys, ...Object.values(SHAPES).flat().map(([k]) => k), ...Object.values(ACTIONS), ...Object.values(SAME_TARGET)];
  const fixedByPair = Object.fromEntries(pairs.map((k) => [k, impliedFixed(k)]));
  const fixed = fixedFrom(fixedByPair);
  const firstWriteSurcharge = get("first write fresh") - get("first write warm");
  const level = Object.fromEntries(Object.entries(LEVEL_ROWS).map(([k, key]) => [k, marginal(key) / LEVEL_SPAN]));
  const tagLevel = { mineNew: level.mineNew, mineExisting: level.mineExisting, sharedNew: level.allNew - level.mineNew, sharedExisting: level.allExisting - level.mineExisting };
  return { fixed, perWord, perByte, publishBase, action, firstWriteSurcharge, tagLevel, publishBaseBySize, fixedByPair, sameTarget };
}

function predict(c, actions) {
  let g = c.fixed;
  for (const a of actions) {
    if (typeof a === "string") g += c.action[a];
    else if (a.later) {
      const key = laterKey((k) => k in c.action, { cost: a.later, first: false, firstAtPlace: a.firstAtPlace, entries: a.entries }, LATER_LISTS);
      assert.ok(key in c.action, `no constant ${key}`);
      g += c.action[key] + historyWordAdds(LATER_ROWS_DOC, key, a.revisionBefore) * c.action.historyWordOpen;
    }
    else if (a.level) g += c.tagLevel[a.level] * a.n;
    else g += c.publishBase[a.publish] + c.perWord * words(a.n) + c.perByte * a.n;
  }
  return g;
}

const rounded = (c) => ({
  fixed: round(c.fixed),
  perWord: round(c.perWord),
  perByte: Number(c.perByte.toFixed(1)),
  publishNew: Object.fromEntries(Object.entries(c.publishBase).map(([k, v]) => [k, round(v)])),
  ...Object.fromEntries(Object.entries(c.action).map(([k, v]) => [k, round(v)])),
  firstWriteSurcharge: round(c.firstWriteSurcharge),
  tagLevel: Object.fromEntries(Object.entries(c.tagLevel).map(([k, v]) => [k, round(v)])),
});

/** The kernel's quote inputs exactly as the Realm of this schedule activates them (design §10.4). */
const FLOOR_LIMITS = {
  prague: { floorFreshGas: LIMITS.floorFreshGas, floorRewriteGas: LIMITS.floorRewriteGas, kernelTail: LIMITS.kernelTail },
  amsterdam: GLAMSTERDAM_FLOOR,
};
/** An upper bound on the gas the ingress's dispatchIndex spends before its own 63/64 check (the whole dispatch,
 *  calldata decode, encoding, CALL and acknowledgement, is 1,947 on both schedules in the -vvvv traces). */
const DISPATCH_OVERHEAD = 2000;

const FLOOR_FORMULA = [
  "The kernel's quote (LedgerIngress._foldAndQuote, work-model formula 3, docs/WORK-MODEL-V3.md) over a publication of n actions: fresh10 = workModel.freshPerPublication + Σ over PUBLISH/REUSE (freshPerRef·types[T].refs, plus freshPerPublishFresh + freshPerDigestSpec·types[T].specs when the record is new, or freshPerPublishExisting when it exists: a repeat PUBLISH or any REUSE) + Σ over rows (fresh); rw10 = rwPerPublication + rwPerPublish per PUBLISH/REUSE + Σ over rows (rw); compute = computeBase + n·computePerAction + Σ over rows (compute). Each BIND/UNBIND/RELEASE adds one row by class: (freshPerBindFirst, rwPerBindFirst, computePerBindFirst) for a first statement (a BIND or UNBIND whose author's head at the position is UNSET), (freshPerRebind, rwPerRebind, computePerRebind) for a re-bind (a BIND on a BOUND head: a new target, or the same target with a new number), and (freshPerBindLater, rwPerBindLater, computePerBindLater) for every other later statement (a mask, a release, a restore; a RELEASE always); when its purpose word equals surchargePurpose (plain equality, as the kernel compares them; a statement's purpose is never zero, so a zero surchargePurpose surcharges nothing) the surcharge row of the same class is added too (surchargeFreshFirst, surchargeRwFirst, surchargeComputeFirst; surchargeFreshRebind, surchargeRwRebind, surchargeComputeRebind; surchargeFreshLater, surchargeRwLater, surchargeComputeLater). Every WITHDRAW after the first of a publication adds the later-statement row (without the surcharge). With no principal (indexFloor) every bind-kind action adds the largest of the three rows field by field, surcharge included. freshSlots = ceil(fresh10 / 10), rewrites = ceil(rw10 / 10). The kernel refuses a work model whose reply is not 32 words or whose formulaVersion is not 3 (E_WORK_MODEL).",
  "prefixFloor P = compute + freshSlots·limits.floorFreshGas + rewrites·limits.floorRewriteGas; finalReserve F = finalComputeBase + binds·finalComputePerBind + publishes·finalComputePerPublish (binds = the BIND/UNBIND/RELEASE count, publishes = the PUBLISH/REUSE count).",
  "The checks (design §6.4, §6.5): before callback i the kernel requires its gasleft g > F + T and forwards (g − F − T)·63/64 to the ingress, which spends at most dispatchOverhead, then requires (its gasleft)·63/64 ≥ R_i = max(0, P − the callbacks' spend so far) (E_INDEX_GAS otherwise); before the final phase it requires (g − T)·63/64 ≥ F. T = limits.kernelTail.",
  "Sufficient visible execution gas (G = the gas limit less intrinsic gas and calldata): G ≥ V = max(K + ceil((ceil(P·64/63) + dispatchOverhead)·64/63), E) + ceil(F·64/63) + T, where E is the publication's execution gas and K the kernel's own share of it (callbacks excluded): at callback i the gas spent so far is at most K plus the callbacks' spend s, and R_i·(64/63)² ≥ P·(64/63)² − s, so the kernel's spend and the floor never need more than K + P·(64/63)²; the final check needs at most E + F·64/63 + T.",
  "A planner uses the model's execution estimate for E (prague: constants; amsterdam: split.executionGas) and floor.kernel (the same model fitted with the callbacks removed) for K.",
  "ILedgerCommitments.indexFloor quotes without a principal, so it prices every bind-kind action with the largest of the three rows field by field: it is an upper bound on P only, and a consumer plans from this rule, never from indexFloor.",
].join(" ");

function floorOf(rows, name, types) {
  const kernel = fit(rows, (r) => {
    assert.ok(Number.isInteger(r.kernelFrameGas), `${name}: no "model ${r.key} kernel frame gas" measurement`);
    return r.kernelFrameGas;
  });
  return {
    formula: FLOOR_FORMULA,
    quantity: "execution gas visible to the GAS opcode (on amsterdam the EIP-8037 state-gas reservoir is not visible and the cap counts execution gas only)",
    workModel: WORK_MODEL,
    limits: FLOOR_LIMITS[name],
    callGasRetained: { numerator: 63, denominator: 64 },
    dispatchOverhead: DISPATCH_OVERHEAD,
    types: Object.fromEntries(Object.entries(types).sort(([a], [b]) => a.localeCompare(b))),
    kernel: rounded(kernel),
    _kernel: kernel,
  };
}

function profile({ rows, types }, name) {
  const amsterdam = name === "amsterdam";
  const total = (r) => r.frameGas + (r.frameStateGas ?? 0);
  const c = fit(rows, total);
  const out = { quantity: amsterdam ? "frame gas + frame state gas (EIP-8037 execution + state)" : "frame gas", constants: rounded(c) };
  const sameTargetOf = (fitted) => Object.fromEntries(Object.entries(fitted.sameTarget).map(([k, v]) => [k, round(v)]));
  let ex = null;
  let st = null;
  if (amsterdam) {
    // every constant is a linear combination of measurements, so the split is the same fit on each part
    ex = fit(rows, (r) => r.frameGas);
    st = fit(rows, (r) => r.frameStateGas ?? 0);
    out.split = { executionGas: rounded(ex), stateGas: rounded(st), note: "constants = executionGas + stateGas (up to rounding); the EIP-7825 per-transaction cap (2^24) counts executionGas only" };
  }
  out._sameTarget = { all: sameTargetOf(c), ...(amsterdam ? { execution: sameTargetOf(ex) } : {}) };
  out.fit = {
    fixedAnchors: [...FIXED_ANCHORS],
    publishNewBaseBySize: Object.fromEntries(Object.entries(c.publishBaseBySize)),
    impliedFixedByPair: Object.fromEntries(Object.entries(c.fixedByPair).map(([k, v]) => [k, round(v)])),
    bytesResiduals: Object.fromEntries(BYTES_SIZES.map((n) => {
      const by = Object.fromEntries(rows.map((r) => [r.key, r]));
      const m = total(by[`pub bytes ${n} k2`]) - total(by[`pub bytes ${n} k1`]);
      return [n, round(m - (c.publishBase["files-bytes/1"] + c.perWord * words(n) + c.perByte * n))];
    })),
  };
  const floor = floorOf(rows, name, types);
  out._sameTarget.kernel = sameTargetOf(floor._kernel);
  const kernelFit = floor._kernel;
  delete floor._kernel;
  out.floor = floor;
  out.rows = rows;
  const by = Object.fromEntries(rows.map((r) => [r.key, r]));
  out.validation = VALIDATION.map((v) => {
    const m = by[v.key];
    assert.ok(m, `no "model ${v.key}" measurement`);
    const measured = total(m);
    const predicted = round(predict(c, v.actions));
    const row = { key: v.key, state: v.state, what: v.what, measured, predicted, errorPercent: Number((((predicted - measured) / measured) * 100).toFixed(2)), measuredKernelGas: m.kernelFrameGas, predictedKernelGas: round(predict(kernelFit, v.actions)), laterStatements: v.actions.filter((a) => a && typeof a === "object" && a.later).length };
    if (amsterdam) {
      row.measuredExecutionGas = m.frameGas;
      row.predictedExecutionGas = round(predict(ex, v.actions));
      row.measuredStateGas = m.frameStateGas ?? 0;
      row.predictedStateGas = round(predict(st, v.actions));
      row.executionErrorPercent = Number((((row.predictedExecutionGas - row.measuredExecutionGas) / row.measuredExecutionGas) * 100).toFixed(2));
      row.allGasOverBoundPercent = Number(allGasOverBoundPercent(row, LIMIT_PERCENT, FRESH_SLOT_STATE_GAS).toFixed(2));
    }
    return row;
  });
  // The stated maxima cover every composite within the claim; composites in state beyondClaim are reported with their
  // errors and excluded (maximaExcludeStates), as the floor excludes lists beyond its claim.
  out.maximaExcludeStates = [BEYOND_CLAIM];
  const counted = out.validation.filter((v) => !out.maximaExcludeStates.includes(v.state));
  // the largest composite error on ALL gas (prague: all gas is what the cap counts; amsterdam: execution + state gas,
  // the constants), and the composite that sets it
  const worst = (field) => counted.reduce((a, v) => (Math.abs(v[field]) > Math.abs(a[field]) ? v : a));
  // the largest UNDER-prediction (predicted below measured), as a positive percent (0 when no composite is low)
  const under = (field) => counted.reduce((a, v) => (v[field] < a[field] ? v : a));
  const underOf = (field) => { const v = under(field); return v[field] < 0 ? [Number((-v[field]).toFixed(2)), v.key] : [0, null]; };
  out.maxAbsErrorPercent = Math.abs(worst("errorPercent").errorPercent);
  out.maxAbsErrorComposite = worst("errorPercent").key;
  [out.maxUnderErrorPercent, out.maxUnderErrorComposite] = underOf("errorPercent");
  // the largest OVER-prediction on all gas (0 when no composite is high): a bound on prague, stated on amsterdam with
  // each composite's own bound (allGasOverBoundPercent)
  const over = (field) => counted.reduce((a, v) => (v[field] > a[field] ? v : a));
  const overOf = (field) => { const v = over(field); return v[field] > 0 ? [Number(v[field].toFixed(2)), v.key] : [0, null]; };
  [out.maxOverErrorPercent, out.maxOverErrorComposite] = overOf("errorPercent");
  if (amsterdam) {
    // amsterdam only: the largest composite error on EXECUTION gas (split.executionGas against the measured frame gas),
    // the figure that bounds the EIP-7825 2^24 cap condition there (the cap counts execution gas only)
    out.maxAbsExecutionErrorPercent = Math.abs(worst("executionErrorPercent").executionErrorPercent);
    out.maxAbsExecutionErrorComposite = worst("executionErrorPercent").key;
    [out.maxUnderExecutionErrorPercent, out.maxUnderExecutionErrorComposite] = underOf("executionErrorPercent");
    [out.maxOverExecutionErrorPercent, out.maxOverExecutionErrorComposite] = overOf("executionErrorPercent");
  }
  return out;
}

const TAG_LEVELS_METHOD = `a first TAG statement (either sign) on an n-word topic = bindTagFresh (no author has stated anything at the position) or bindTagSecondAuthor (the position exists; measured as a first yes, which files one place entry, so it is an upper bound for a first no there) + Σ over its n − 1 proper ancestors of tagLevel.mineNew | mineExisting (the author's scope-below list at that ancestor is empty | not) + (a fresh position, either sign, or a first yes at an existing position: every filing) tagLevel.sharedNew | sharedExisting (the place-below list at that ancestor is empty | not); a list with exactly 1 entry or a multiple of 5 takes a fresh word on its next append, so price it as new (tagLists.priceAsNew). Measured: (k2 − k1) / ${LEVEL_SPAN} of a first statement on a 2-word and on a 6-word topic from the same state (rows "tag level all new | all existing": a first tag at a fresh position; "mine new | mine existing": a first no at an existing position, which files nothing below); shared = all − mine`;
/** The planning rule (tools/gas-plan.mjs implements it; tools/release.mjs reads txGasCap and headroomPercent from here). */
const PLANNING = {
  rule: "A publication is planned when it is inside limits (1 ≤ actions ≤ maxActions, bind-kind actions ≤ maxBindsPerPublication, PUBLISH body bytes ≤ maxBodyBytesPerPublication) and max(E, V) ≤ floor(txGasCap × (100 − headroomPercent) / 100), on the schedule of the chain: E the model's execution estimate (prague: constants; amsterdam: split.executionGas), V the floor's visible-gas requirement (profiles.<schedule>.floor.formula). A shape that does not fit is split into publications before it is signed, never shortened; eth_estimateGas on the exact call stays the authority before sending, and the gas limit comes from the estimate, never from V.",
  txGasCap: 16777216,
  txGasCapRule: "EIP-7825 (on amsterdam, EIP-8037: the cap counts execution gas only)",
  headroomPercent: 15,
  headroomCovers: "the 21,000 intrinsic cost, calldata (EIP-2028/7623) and the model's own error over the validation composites in both states (the author's lists new and existing). The cap condition is tested against the under-prediction of the gas the cap counts (headroom exists to stop a plan coming out too small; an over-prediction only costs batch size): on prague all gas, profiles.prague.maxUnderErrorPercent; on amsterdam execution gas only, profiles.amsterdam.maxUnderExecutionErrorPercent. The maximum-error fields keep their meaning (maxAbsErrorPercent, and on amsterdam maxAbsExecutionErrorPercent); profiles.amsterdam.maxAbsErrorPercent is the all-gas error (execution + state gas), which bounds the publication's total against the block, never the 2^24 cap. Each figure names its composite (maxAbsErrorComposite, maxUnderErrorComposite, maxAbsExecutionErrorComposite, maxUnderExecutionErrorComposite), each is taken over the composites whose state is not in maximaExcludeStates. The under-prediction fields and the over-prediction of the gas the cap counts (profiles.prague.maxOverErrorPercent, profiles.amsterdam.maxOverExecutionErrorPercent) are at most headroomPercent; profiles.amsterdam.maxOverErrorPercent (all gas) is stated with a per-composite bound (method.maxima)",
  limits: { maxActions: LIMITS.maxActions, maxBindsPerPublication: LIMITS.maxBindsPerPublication, maxBodyBytesPerPublication: LIMITS.maxBodyBytesPerPublication },
};
/** Read by the planner with the tagLevel terms (design §10.4). */
const TAG_LISTS = {
  priceAsNew: { entries: [1], entriesMultipleOf: 5 },
  note: "A per-author (scope-below) or shared (place-below) roll-up list holding exactly one entry, or a multiple of five entries (zero included: an empty list), takes a fresh word on its next append, so price that append as new (tagLevel.mineNew or sharedNew); otherwise as existing. The fresh word costs one slot rewrite more than a new list, inside the headroom; not separately measured.",
};

const prague = profile(run("default"), "prague");
const amsterdam = o["skip-amsterdam"] ? null : profile(run("amsterdam"), "amsterdam");

/** `laterRows`: the positions, and for the new-target restore rows the measured over-price of a same-target restore. */
function laterRowsOf(profiles) {
  const rows = JSON.parse(JSON.stringify(LATER_ROWS_DOC.rows));
  for (const base of Object.keys(SAME_TARGET)) {
    const parts = Object.entries(profiles).map(([name, p]) => {
      const st = p._sameTarget;
      const d = (fitted, same) => fitted[base] - same[base];
      const all = d(p.constants, st.all);
      const kernel = d(p.floor.kernel, st.kernel);
      return name === "amsterdam"
        ? `amsterdam ${all} all gas (${d(p.split.executionGas, st.execution)} of execution), kernel share ${kernel}`
        : `${name} ${all} gas, kernel share ${kernel}`;
    });
    for (const k of Object.keys(rows).filter((k) => k === base || k.startsWith(`${base}LongNewPlace`) || k.startsWith(`${base}LongSamePlace`) || k === `${base}NewPlace`)) {
      rows[k].note = `Measured restoring to a NEW target already placed elsewhere (the dearest restore). A restore to the head's stored target costs less by the kernel's target rewrite: ${base} against the same restore to the stored target (GasModel.t.sol, "${SAME_TARGET[base]}"), ${parts.join("; ")}. A planner cannot tell the two apart (the head view does not show the stored target), so it prices every restore by this row.`;
    }
  }
  return { rule: LATER_ROWS_DOC.rule, note: LATER_ROWS_DOC.note, historyWordConstant: "historyWordOpen", rows };
}
const laterRows = laterRowsOf({ prague, ...(amsterdam ? { amsterdam } : {}) });
for (const p of [prague, amsterdam].filter(Boolean)) delete p._sameTarget;

const model = {
  schema: "efs-gas-model/1",
  note: "Planning only: predicts the gas of one native-lane ILedger.execute publication from its actions, so the SDK can split a large write into publications without an eth_estimateGas round trip per guess. eth_estimateGas stays the authority before sending. Excluded: the 21,000 intrinsic cost and calldata (EIP-2028/7623; computable from the encoded transaction), refunds (EIP-3529; not applied, so the model errs high on clears), the signed lane, guards and STAGE/COMMIT.",
  method: {
    suite: SUITE,
    prague: "FOUNDRY_PROFILE=default (evm prague, the release bytes)",
    amsterdam: amsterdam ? "FOUNDRY_PROFILE=amsterdam FOUNDRY_OUT=out/amsterdam FOUNDRY_CACHE_PATH=cache/amsterdam (solc experimental amsterdam target; never release bytes)" : "skipped",
    measurement: "vm.lastFrameGas() of the execute call frame (gasTotalUsed, and gasStateUsed under amsterdam); every account the setUp touched is cooled (vm.cool) before each measured execute, so each publication pays the cold costs of a transaction of its own; the principal has written before except in the first-write pair",
    marginal: "cost of one action = gas(k = 2) − gas(k = 1) of two publications of the same shape with distinct bodies",
    slopes: `perWord and perByte: least squares of the files-bytes/1 marginal over body sizes ${BYTES_SIZES.join(", ")} (100 and 1,000 are not word multiples, which separates the two terms); publishNew[shape] = its marginal − perWord·ceil(n/32) − perByte·n, averaged over the measured sizes (fit.publishNewBaseBySize)`,
    fixed: "median of 2·gas(k = 1) − gas(k = 2) over the anchor pairs only (fit.fixedAnchors: the pairs the model had at 899767e, frozen in tools/gas-fit.mjs), so a row added later never changes the price of an existing action; fit.impliedFixedByPair keeps the value of every pair, anchors or not (the first action of a kind in a publication pays some cold state that later ones find warm, which this single constant averages)",
    firstWriteSurcharge: "(CREATE + PUBLISH files-directory/1 as a principal's first publication ever) − (the same shape by a principal that has written once)",
    keys: "PUBLISH new: publishNew[shape] + perWord·ceil(n/32) + perByte·n, n = body bytes; FOLDER binds run FilesFinalValidator; rebind = CAS to a new target; UNBIND/RELEASE from BOUND; restore = BIND from MASKED to the kept target; PROPERTY binds are a label (labelKey(\"en\") on a word page → an existing text/1; a label with a new text is publishNew[\"text/1\"] + its body terms + bindPropertyFresh, validated by \"validate label new text\"); SAME and BROADER first statements run FilesFinalValidator's topic checks on subject and role (word page to word page; bindSameFreshPath 2-word path to path), their later statements are on word pages; WITHDRAW of one occurrence",
    tagLevels: TAG_LEVELS_METHOD,
    laterLists: "later statements are priced by laterLists (the list tiers); the tier rows are their own k1/k2 pairs (GasModel.t.sol section 9: `<row> new place` at three places whose lists hold one entry; `<row> long new place` at three places whose lists hold 1,025 entries, each statement at entry 1,024; `<row> long same place` at one place of 1,025 entries, k1 the entry at 512, k2 those at 256 and 768), never anchors, so no tier row moves `fixed` or an existing row; PROPERTY, SAME and BROADER rows are already measured at distinct subjects, so they carry no `NewPlace` row",
    maxima: "Every maximum is taken over the validation composites whose state is not in maximaExcludeStates (beyondClaim: lists over laterLists.claimEntries, the floor's documented exception). maxAbsErrorPercent is the largest |error| on all gas (the larger of maxUnderErrorPercent and maxOverErrorPercent), and on amsterdam maxAbsExecutionErrorPercent the same on execution gas; each names its composite. What tools/gas-model.mjs refuses (tools/gas-fit.mjs overBound): an UNDER-prediction above 15% anywhere (prague all gas, amsterdam all gas, amsterdam execution gas: maxUnderErrorPercent, maxUnderExecutionErrorPercent); an OVER-prediction above 15% of the gas the 2^24 cap counts (prague all gas, maxOverErrorPercent; amsterdam execution gas, maxOverExecutionErrorPercent); and on amsterdam an all-gas over-prediction above the composite's own allGasOverBoundPercent = 15 + laterStatements × freshSlot.stateGas (97,920, docs/GAS-SCHEDULES.md) × 100 / measured. That last term is the later rows' worst-case state: each is measured where its target's backlink word and its binding's history word open, which a planner cannot see, and on amsterdam one such word is a fresh slot of state gas only, so a composite whose statements open none is over-stated by up to one slot a statement. So amsterdam's maxAbsErrorPercent and maxOverErrorPercent are stated, not bounded at 15%: they bound a publication's total against the block, never the cap",
  },
  planning: PLANNING,
  tagLists: TAG_LISTS,
  laterLists: LATER_LISTS,
  laterRows,
  profiles: { prague, ...(amsterdam ? { amsterdam } : {}) },
  source: { test: SUITE, commit: git("rev-parse", "HEAD"), dirtyFiles: (git("status", "--porcelain") || "").split("\n").filter(Boolean).length, date: new Date().toISOString(), foundry: execFileSync("forge", ["--version"]).toString().split("\n")[0].trim() },
};
// the topic readers' read terms and call bounds (tools/gas-reads.mjs; a section of its own beside the profiles)
const { measureReads, checkReads } = await import("./gas-reads.mjs");
model.reads = measureReads({ amsterdam: !o["skip-amsterdam"] });
const errs = validate(JSON.parse(toJSON(model)), "efs-gas-model-1.schema.json");
assert.deepEqual(errs, [], `gas/model.json does not match its schema:\n${errs.join("\n")}`);
if (CHECK) {
  const committed = JSON.parse(readFileSync(join(root, "gas/model.json"), "utf8"));
  const stale = checkReads(committed.reads, JSON.parse(toJSON(model.reads)));
  for (const d of stale.slice(0, 8)) console.error(`gas-model --check: ${d}`);
  if (!stale.length) console.log(`gas-model --check: OK, the committed reads rows equal the measurement (${Object.keys(model.reads.schedules).join(" + ")})`);
  process.exit(check(committed) | (stale.length ? 1 : 0));
}
mkdirSync(join(root, "gas"), { recursive: true });
writeFileSync(join(root, "gas/model.json"), toJSON(model));

console.log(`gas-model: gas/model.json (prague${amsterdam ? " + amsterdam" : ""})`);
for (const [name, p] of Object.entries(model.profiles)) {
  console.log(`  ${name}: ${JSON.stringify(p.constants)}`);
  for (const v of p.validation) console.log(`    ${v.key.padEnd(32)} measured ${String(v.measured).padStart(10)} predicted ${String(v.predicted).padStart(10)} ${v.errorPercent.toFixed(2).padStart(7)}%${v.executionErrorPercent === undefined ? "" : ` (execution ${v.executionErrorPercent.toFixed(2)}%)`}`);
  console.log(`    max |error| ${p.maxAbsErrorPercent}% (${p.maxAbsErrorComposite})${p.maxAbsExecutionErrorPercent === undefined ? "" : `; execution gas ${p.maxAbsExecutionErrorPercent}% (${p.maxAbsExecutionErrorComposite})`}`);
  console.log(`    max over-prediction ${p.maxOverErrorPercent}% (${p.maxOverErrorComposite})${p.maxOverExecutionErrorPercent === undefined ? "" : `; execution gas ${p.maxOverExecutionErrorPercent}% (${p.maxOverExecutionErrorComposite})`}`);
  console.log(`    max under-prediction ${p.maxUnderErrorPercent}% (${p.maxUnderErrorComposite})${p.maxUnderExecutionErrorPercent === undefined ? "" : `; execution gas ${p.maxUnderExecutionErrorPercent}% (${p.maxUnderExecutionErrorComposite})`} (excluding ${p.maximaExcludeStates.join(", ")})`);
}
const bad = overBound(model.profiles);
if (bad.length) {
  for (const m of bad) console.error(`gas-model: ${m}`);
  process.exit(1);
}

/** The stated bound (tools/gas-fit.mjs overBound): under-predictions everywhere, over-predictions on the gas the cap
 *  counts, amsterdam all-gas over-predictions per composite at LIMIT_PERCENT plus its later statements' fresh-slot
 *  state gas. */
function overBound(profiles) {
  return overBoundOf(profiles, { limitPercent: LIMIT_PERCENT, freshSlotStateGas: FRESH_SLOT_STATE_GAS });
}

/** Paths at which `a` and `b` (parsed JSON) differ, each with both values. */
function diff(a, b, path, out) {
  if (a === b) return out;
  if (a && b && typeof a === "object" && typeof b === "object" && Array.isArray(a) === Array.isArray(b)) {
    for (const k of new Set([...Object.keys(a), ...Object.keys(b)])) diff(a[k], b[k], `${path}${Array.isArray(a) ? `[${k}]` : `.${k}`}`, out);
    return out;
  }
  out.push(`${path}: committed ${JSON.stringify(a)}, measured ${JSON.stringify(b)}`);
  return out;
}

/** --check: the error bound, and exact equality of the fitted constants and the measured rows, per checked profile. */
function check(committed) {
  const fresh = JSON.parse(toJSON(model));
  const bound = [];
  const differences = [];
  bound.push(...overBound(fresh.profiles));
  for (const [name, p] of Object.entries(fresh.profiles)) {
    const c = committed.profiles?.[name];
    if (!c) { differences.push(`profiles.${name}: absent from the committed gas/model.json`); continue; }
    for (const k of ["constants", "split", "floor", "rows"]) diff(c[k], p[k], `profiles.${name}.${k}`, differences);
  }
  for (const k of ["planning", "tagLists", "laterLists", "laterRows"]) diff(committed[k], fresh[k], k, differences);
  for (const m of bound) console.error(`gas-model --check: ${m}`);
  if (differences.length) {
    const shown = Math.min(8, differences.length);
    console.error(`gas-model --check: gas/model.json is stale (${Object.keys(fresh.profiles).join(" + ")}): ${differences.length} difference(s), the first ${shown}:`);
    for (const d of differences.slice(0, shown)) console.error(`  ${d}`);
    console.error("gas-model --check: regenerate with `pnpm run gas:model`, then `pnpm run release`");
  }
  if (bound.length || differences.length) return 1;
  const checked = Object.entries(fresh.profiles).map(([n, p]) => `${n} (${p.rows.length} rows, max |error| ${p.maxAbsErrorPercent}%)`).join(", ");
  console.log(`gas-model --check: OK, the committed gas/model.json equals the measurement: ${checked}`);
  return 0;
}
