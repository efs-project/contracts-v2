// SPDX-License-Identifier: MIT
// File name vectors (design §12.1, §12.1.1; `efs/vectors/names/1`): the `files-name/3` grammar's verdict on names
// (every ASCII byte alone and at the start, middle and end of a name, the trailing `.` cases, the examples of the
// rulings, Windows device names as ordinary names, the reserved `~efs` prefix, the length boundaries and the 50
// vectors of the naming experiment kept in test/profiles/FilesNameVectors.sol), with each name's role
// (`keccak256(name)`) and each admitted name's record id for the release's `files-name/3` Type id, so an SDK's name
// check can be checked against the contracts exactly. Computed here in JS (viem's keccak256; the grammar written from
// the NatSpec of `src/profiles/FilesNameRule.sol`, never from its bytecode). `tools/release.mjs` writes
// test/vectors/names.json and `pnpm release:check` compares it byte for byte; `test/profiles/NameVectors.t.sol`
// asserts every vector against `FilesName.valid`, `FilesNameRule` and `Keys`, so the file cannot drift. The Type id is
// the release's (the fixture declaration key), so the file changes whenever the rule's code does.
//
//   node tools/name-vectors.mjs [--check 1]
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { keccak256, stringToHex, toHex } from "viem";
import { keys, root } from "./deploy-plan.mjs";

const bytesOf = (hex) => Buffer.from(hex.slice(2), "hex");

/** The printable ASCII a name refuses, by the test each answers to. URI meaning: each changes what a pasted link
 *  means (`/` and `\` since `files-name/2`; `#`, `?`, `%` since `files-name/3`). A delimiter kept free for EFS URL
 *  syntax (since `files-name/3`). */
export const NAME_ASCII_URI = "/\\#?%";
export const NAME_ASCII_DELIMITERS = '<>"|:*;';
export const NAME_ASCII_REFUSED = NAME_ASCII_URI + NAME_ASCII_DELIMITERS;
const ASCII_REFUSED = new Set([...NAME_ASCII_REFUSED].map((c) => c.charCodeAt(0)));

/** One strict UTF-8 scalar at `i` (FilesName.scalar): [scalar, width], width 0 when malformed or truncated. */
function scalar(b, i) {
  const n = b.length;
  const at = (k) => (i + k < n ? b[i + k] : 0);
  const b0 = at(0), b1 = at(1);
  if (b0 < 0xc2 || b0 > 0xf4 || (b1 & 0xc0) !== 0x80) return [0, 0];
  if (b0 <= 0xdf) return i + 2 > n ? [0, 0] : [((b0 & 0x1f) << 6) | (b1 & 0x3f), 2];
  const b2 = at(2);
  if ((b2 & 0xc0) !== 0x80) return [0, 0];
  if (b0 <= 0xef) {
    if (i + 3 > n) return [0, 0];
    const v = ((b0 & 0x0f) << 12) | ((b1 & 0x3f) << 6) | (b2 & 0x3f);
    return v < 0x800 || (v >= 0xd800 && v <= 0xdfff) ? [0, 0] : [v, 3];
  }
  const b3 = at(3);
  if (i + 4 > n || (b3 & 0xc0) !== 0x80) return [0, 0];
  const u = ((b0 & 0x07) << 18) | ((b1 & 0x3f) << 12) | ((b2 & 0x3f) << 6) | (b3 & 0x3f);
  return u < 0x10000 || u > 0x10ffff ? [0, 0] : [u, 4];
}

/** `FilesName.excluded` for a multi-byte scalar. */
const excluded = (s) =>
  s <= 0x9f || s === 0xad || s === 0x61c || s === 0x180e || s === 0x200b || s === 0x200e || s === 0x200f || (s >= 0x202a && s <= 0x202e) ||
  s === 0x2028 || s === 0x2029 || (s >= 0x2060 && s <= 0x2064) || (s >= 0x2066 && s <= 0x206f) || (s >= 0xfdd0 && s <= 0xfdef) || s === 0xfeff ||
  (s >= 0xfff9 && s <= 0xfffd) || (s & 0xfffe) === 0xfffe;
/** `FilesName.whitespace`: Unicode White_Space not already excluded. */
const whitespace = (s) => s === 0x20 || s === 0xa0 || s === 0x1680 || (s >= 0x2000 && s <= 0x200a) || s === 0x202f || s === 0x205f || s === 0x3000;

/** The `files-name/3` grammar (`FilesName.valid`, hex in): "" when admitted, else the first failed check in the
 *  order `valid` runs them (informative only: the chain answers one refusal, `E_FILES_REFUSED(2)`): length,
 *  reserved-prefix, then scanning in order ascii (a control, DEL or one of `NAME_ASCII_REFUSED`), utf8 (malformed)
 *  or excluded (a refused scalar); then trailing-dot, whitespace (at either end). */
export function nameRefusal(hex) {
  const b = bytesOf(hex);
  const n = b.length;
  if (n === 0 || n > 255) return "length";
  if (n >= 4 && b[0] === 0x7e && b[1] === 0x65 && b[2] === 0x66 && b[3] === 0x73) return "reserved-prefix";
  let first = 0, last = 0;
  for (let i = 0; i < n;) {
    const c = b[i];
    let s, w;
    if (c < 0x80) {
      if (c < 0x20 || c === 0x7f || ASCII_REFUSED.has(c)) return "ascii";
      [s, w] = [c, 1];
    } else {
      [s, w] = scalar(b, i);
      if (w === 0) return "utf8";
      if (excluded(s)) return "excluded";
    }
    if (i === 0) first = s;
    last = s;
    i += w;
  }
  if (last === 0x2e) return "trailing-dot";
  if (whitespace(first) || whitespace(last)) return "whitespace";
  return "";
}

const x = (hex) => ({ hex });
const hexOf = (m) => (typeof m === "string" ? stringToHex(m) : m.hex);
const cat = (...parts) => x(`0x${parts.map((p) => hexOf(p).slice(2)).join("")}`);
const rep = (unit, k) => cat(...Array(k).fill(unit));
const byte = (c) => x(`0x${c.toString(16).padStart(2, "0")}`);
const cp = (s) => x(toHex(Buffer.from(String.fromCodePoint(s), "utf8")));

/** The naming experiment's 50 vectors, read from test/profiles/FilesNameVectors.sol (label comment, hex, verdict,
 *  role); the verdict there is `files-name/3`'s, and `files-name/2`'s where it differs is in the label. */
export function experimentVectors() {
  const sol = readFileSync(join(root, "test/profiles/FilesNameVectors.sol"), "utf8");
  const out = [];
  for (const m of sol.matchAll(/\/\/ ([^\n]+)\n\s*v\[(\d+)\] =\s*V\(\s*hex"([0-9a-f]*)",\s*(true|false),\s*(0x[0-9a-f]{64})\s*\)/g)) {
    out.push({ index: Number(m[2]), label: m[1].trim(), hex: `0x${m[3]}`, valid: m[4] === "true", role: m[5] });
  }
  if (out.length !== 50 || out.some((v, i) => v.index !== i)) throw new Error(`name vectors: expected FilesNameVectors v[0..49], parsed ${out.length}`);
  return out;
}

/** [label, name (a string, or hex), note]. */
function cases() {
  const rows = [];
  const add = (label, v, note = "") => rows.push([label, v, note]);
  // every ASCII byte alone, first, inside and last
  for (let c = 0; c < 0x80; c++) {
    const h = `0x${c.toString(16).padStart(2, "0")}`;
    add(`ASCII ${h} alone`, byte(c));
    add(`ASCII ${h} first`, cat(byte(c), "ab"));
    add(`ASCII ${h} inside`, cat("a", byte(c), "b"));
    add(`ASCII ${h} last`, cat("ab", byte(c)));
  }
  // the examples of the rulings
  for (const [n, note] of [
    ["Q&A 3.pdf", "admitted: '&' and an inner space"],
    ["logo@2x.png", "admitted"],
    ["~$Budget.xlsx", "admitted: a leading '~' and '$'"],
    ["Sale!.png", "admitted"],
    ["a&b(c)'d,e+f=g!h@i[j]k{l}m^n`o~p$q-r_s.txt", "admitted: & ( ) ' , + = ! @ [ ] { } ^ ` ~ $ - _"],
    ["a=b!c", "admitted: '=' and '!' stay; only ';' is reserved, so a parser can split parameters at ';' first"],
    ["-rf", "admitted: a leading '-'"],
    [".env", "admitted: a leading '.'"],
    ["Q&A #3.pdf", "refused: '#' (URI meaning)"],
    ["50%.txt", "refused: '%' (URI meaning)"],
    ["what?.md", "refused: '?' (URI meaning)"],
    ["100% done?.txt", "refused (URI meaning)"],
    ["a;b", "refused: ';' (a delimiter kept free)"],
    ["a:b", "refused: ':' (a delimiter kept free)"],
    ["a*b", "refused: '*' (a delimiter kept free)"],
    ["a<b", "refused: '<' (a delimiter kept free)"],
    ["a>b", "refused: '>' (a delimiter kept free)"],
    ["a|b", "refused: '|' (a delimiter kept free)"],
    ['a"b', "refused: '\"' (a delimiter kept free)"],
    ["inc.", "refused: a trailing '.' (link trimming)"],
  ]) add(`example: ${n}`, n, note);
  // a trailing `.` (link trimming: the integration owner's application, its own check)
  for (const [n, note] of [
    [".", "refused (a dot-segment)"], ["..", "refused (a dot-segment)"], ["...", "refused: ends with '.'"], ["a.", "refused"],
    ["ends.", "refused (files-name/2 admitted it)"], ["a.b", "admitted"], [".a", "admitted: a leading '.'"], [".hidden", "admitted"],
    ["a..b", "admitted: inner dots"], ["..a", "admitted"], ["a. ", "refused: a trailing space"], ["a .b", "admitted"],
  ]) add(`trailing dot: ${n}`, n, note);
  // Windows device names are ordinary names (James, 2026-11-26: "Don't refuse windows reserved names.")
  for (const n of ["con", "CON", "aux.c", "nul.txt", "COM1", "NUL .txt", "lpt9.log", "prn", "console.txt", "auxiliary", "com10"]) {
    add(`device name: ${n}`, n, "admitted: device names are not refused");
  }
  // the reserved prefix
  for (const [n, note] of [
    ["~efs", "refused"], ["~efs-control", "refused"], ["~efs.txt", "refused"], ["~ef", "admitted: shorter than the prefix"],
    ["~Efs", "admitted: the prefix is case-sensitive"], ["a~efs", "admitted: not a prefix"], ["~backup.txt", "admitted: a leading '~'"], ["~", "admitted"],
  ]) add(`prefix: ${n}`, n, note);
  // malformed UTF-8 and the excluded scalars of files-name/2 (test/profiles/FilesNameRule.t.sol), unchanged
  for (const [label, hex] of [
    ["overlong NUL", "0xc080"], ["overlong 2-byte", "0xc1bf"], ["overlong 3-byte", "0xe08080"], ["overlong below U+0800", "0xe09fbf"],
    ["overlong 4-byte", "0xf0808080"], ["overlong below U+10000", "0xf08fbfbf"], ["surrogate U+D800", "0xeda080"], ["surrogate U+DFFF", "0xedbfbf"],
    ["above U+10FFFF", "0xf4908080"], ["invalid lead F5", "0xf5808080"], ["truncated 2-byte at the end", "0x61c3"], ["truncated 3-byte at the end", "0x61e695"],
    ["truncated 4-byte at the end", "0x61f09f93"], ["a lone continuation byte", "0x61806162"],
  ]) add(`malformed: ${label}`, x(hex), "refused");
  for (const [label, hex, note] of [
    ["U+0080, a C1 control", "0xc280", "refused"], ["U+00A1", "0xc2a1", "admitted"], ["U+07FF", "0xdfbf", "admitted"], ["U+0800", "0xe0a080", "admitted"],
    ["U+E000", "0xee8080", "admitted"], ["U+10000", "0xf0908080", "admitted"], ["U+10FFFD", "0xf48fbfbd", "admitted"], ["U+10FFFF, a noncharacter", "0xf48fbfbf", "refused"],
    ["a leading NBSP", "0xc2a061", "refused"], ["a trailing ideographic space", "0x61e38080", "refused"], ["an inner ideographic space", "0x61e3808061", "admitted"],
    ["U+2028", "0x61e280a8", "refused"], ["U+2066", "0x61e281a6", "refused"], ["U+FDD0", "0x61efb790", "refused"], ["U+1FFFE", "0x61f09fbfbe", "refused"],
    ["U+FFFD", "0x61efbfbd", "refused"], ["ZWJ", "0x61e2808d62", "admitted"], ["variation selector 16", "0x61efb88f", "admitted"],
  ]) add(`scalar: ${label}`, x(hex), note);
  // lengths
  add("length 0", x("0x"), "refused");
  add("length 1", "a", "admitted");
  add("length 255", rep("a", 255), "admitted");
  add("length 256", rep("a", 256), "refused");
  add("255 bytes of CJK", rep(cp(0x754c), 85), "admitted");
  add("258 bytes of CJK", rep(cp(0x754c), 86), "refused");
  add("254 bytes and a trailing dot", cat(rep("a", 254), "."), "refused");
  return rows;
}

/** The document, for the release's Type ids (`plan.profile`). */
export function nameVectors(plan) {
  const typeId = plan.profile.find((p) => p.type === "files-name/3").typeId;
  const row = (label, v, note, extra = {}) => {
    const hex = hexOf(v);
    const reason = nameRefusal(hex);
    const r = { label, hex, length: (hex.length - 2) / 2, valid: reason === "", ruleCode: reason === "" ? 0 : 2 };
    if (typeof v === "string") r.name = v;
    if (reason) r.reason = reason;
    if (note) r.note = note;
    Object.assign(r, extra);
    r.role = keccak256(hex);
    if (r.valid) r.recordId = keys.record(typeId, hex);
    return r;
  };
  const names = cases().map(([label, v, note]) => row(label, v, note));
  const experiment = experimentVectors().map((e) => {
    const r = row(`experiment v[${e.index}]: ${e.label}`, x(e.hex), "", { experimentIndex: e.index });
    if (r.valid !== e.valid) throw new Error(`name vectors: FilesNameVectors v[${e.index}] says ${e.valid}, the grammar ${r.valid}`);
    if (r.role !== e.role) throw new Error(`name vectors: FilesNameVectors v[${e.index}] role`);
    return r;
  });
  const all = [...names, ...experiment];
  // the notes that say admitted or refused agree with the verdicts
  for (const r of all) {
    if (r.note?.startsWith("admitted") && !r.valid) throw new Error(`name vectors: ${r.label} is noted admitted`);
    if (r.note?.startsWith("refused") && r.valid) throw new Error(`name vectors: ${r.label} is noted refused`);
  }
  for (const reason of ["length", "reserved-prefix", "ascii", "utf8", "excluded", "trailing-dot", "whitespace"]) {
    if (!all.some((r) => r.reason === reason)) throw new Error(`name vectors: no name refused for ${reason}`);
  }
  return {
    schema: "efs/vectors/names/1",
    generator: "tools/name-vectors.mjs via tools/release.mjs (viem keccak256; the grammar from the NatSpec of src/profiles/FilesNameRule.sol)",
    spec: "docs/DESIGN.md §12.1, §12.1.1; FilesName.valid; FilesNameRule",
    grammar: {
      name: "1..255 bytes of strict UTF-8, byte-exact and case-sensitive (nothing normalized); no C0 control, DEL or C1 control; none of the ASCII in `asciiRefused`; none of the excluded scalars (U+2028-2029, bidi controls, pure invisibles, U+FFF9-FFFD, noncharacters); no Unicode whitespace first or last; not starting with `~efs`; not ending with '.' (so not '.' or '..')",
      rulings: [
        "James, 2026-11-26: \"? # etc shouldn't be allowed as they are literally urlencode protected params. Nothing that breaks URLs. Nothing that breaks OS file paths.\"",
        "James, 2026-11-26, later the same day (withdraws the OS-path test): \"Don't refuse windows reserved names. I only care about URI safety and us having some delimiters we can use for URL syntax\"",
      ],
      asciiRefused: NAME_ASCII_REFUSED,
      asciiRefusedBecause: {
        uriMeaning: NAME_ASCII_URI,
        delimiterKeptFree: NAME_ASCII_DELIMITERS,
        note: "URI meaning: each changes what a pasted link means ('/' and '\\' since files-name/2). Delimiter kept free: reserved for EFS URL syntax, which is not designed (only the reservations are made); ';' is reserved so a parser can split parameters at ';' first, which is why '=' and '!' stay admitted",
      },
      trailingDot: "refused for link trimming (chat apps and auto-linkers trim a full stop after a pasted link, so /docs/inc. would open /docs/inc): the integration owner's application, not James's ruling, and a check of its own; it also refuses '.' and '..', as files-name/2 did",
      admitted: "spaces inside a name, & ( ) ' , + = ! @ $ [ ] { } ^ ~ ` - _, leading dots and a leading '-'; ZWJ/ZWNJ, variation selectors and tag characters; Windows device names (CON, nul.txt) are ordinary names",
      ruleCodes: { 0: "admitted", 1: "refs present (checked before the grammar)", 2: "not a files-name/3 name" },
      reasons: { length: "empty or longer than 255 bytes", "reserved-prefix": "starts with ~efs", ascii: "a C0 control, DEL or a character of asciiRefused", utf8: "malformed UTF-8", excluded: "a C1 control or another excluded scalar", "trailing-dot": "ends with '.'", whitespace: "Unicode whitespace first or last" },
      reasonNote: "informative: the chain answers one refusal (E_FILES_REFUSED(2)); `reason` is the first failed check in the order FilesName.valid runs them (length, reserved-prefix, the scan in byte order, trailing-dot, whitespace)",
      error: "E_FILES_REFUSED(uint8 code) on a direct call; through the kernel E_REJECTED(leaf, typeId)",
      sdk: "refuse before building a plan; NFC and any case policy are the SDK's, the chain never normalizes",
      open: "Q7: two names that differ only by capitals or by Unicode normalization (Report.txt and report.txt) are two distinct names on chain (byte-exact); whether that stays so is open before any lasting deployment",
    },
    declarationKey: plan.owner,
    typeIds: { "files-name/3": typeId },
    ids: { role: "keccak256(name): the role of a FOLDER bind", record: "Keys.record(files-name/3, name)" },
    names: all,
    // the same verdicts as flat arrays (one parse each for a Solidity reader; recordId for the admitted rows)
    flat: { hex: all.map((r) => r.hex), valid: all.map((r) => r.valid), recordId: all.filter((r) => r.valid).map((r) => r.recordId) },
  };
}

// `node tools/name-vectors.mjs` writes test/vectors/names.json alone from the current build (`pnpm release` writes it
// too, and `pnpm release:check` compares it); `--check 1` compares instead and exits 1 on a difference.
if (import.meta.url === `file://${process.argv[1]}`) {
  const { writeFileSync } = await import("node:fs");
  const { buildPlan, toJSON, parseArgs } = await import("./deploy-plan.mjs");
  const o = parseArgs(process.argv.slice(2), ["check"]);
  const out = join(root, "test/vectors/names.json");
  const doc = toJSON(nameVectors(await buildPlan()));
  if (o.check && o.check !== "0") {
    if (readFileSync(out, "utf8") !== doc) {
      console.error(`name vectors: ${out} differs from this build (run \`node tools/name-vectors.mjs\`)`);
      process.exit(1);
    }
    console.log(`name vectors: ${out} matches this build`);
  } else {
    writeFileSync(out, doc);
    const parsed = JSON.parse(doc);
    console.log(`name vectors: wrote ${out} (${parsed.names.length} names, ${parsed.flat.recordId.length} admitted)`);
  }
}
