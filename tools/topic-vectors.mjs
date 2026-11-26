// SPDX-License-Identifier: MIT
// Topics vectors (design §12.5, docs/TAG-DESIGN.md §1, §8; `efs/vectors/topics/1`): the `topic-word/1` and `text/1`
// grammars' verdicts on words and texts (every refusal code, the boundaries, multi-byte cases and every class of the
// refused code points), the refused code point table itself, the ids of sample paths (1, 2, 3 and 64 words) with
// every record on the way, the PROPERTY key derivation, the three purposes and the ABI encodings of the `EfsTopics`
// builders, so an SDK's word check, id derivation and planner can be checked against the contracts exactly.
// Computed here in JS (viem's ABI encoder and keccak256; the grammars written from the NatSpec of
// `src/profiles/TopicProfile.sol`, never from its bytecode). `tools/release.mjs` writes test/vectors/topics.json and
// `pnpm release:check` compares it byte for byte; `test/profiles/TopicVectors.t.sol` asserts every vector against
// `TopicProfile`, the three rules, `EfsTopics` and `Keys`, so the file cannot drift. The Type ids are the release's
// (the fixture declaration key), so the file changes whenever a Topics rule's code does.
import { encodeAbiParameters, keccak256, pad, stringToHex, toHex } from "viem";
import { actionsHash } from "./number-vectors.mjs";
import { keys } from "./deploy-plan.mjs";

const ZERO = pad("0x", { size: 32 });
const h = (s) => keccak256(stringToHex(s));
const enc = (types, values) => encodeAbiParameters(types.map((type) => ({ type })), values);
const bytesOf = (hex) => Buffer.from(hex.slice(2), "hex");

export const PURPOSES = { TAG: h("efs/purpose/tag/1"), PROPERTY: h("efs/purpose/property/1"), SAME: h("efs/purpose/same/1"), BROADER: h("efs/purpose/broader/1") };
export const KIND = { PUBLISH: 1, BIND: 3, UNBIND: 4 };
export const CLASSES = { 1: "C1 control", 2: "bidirectional control", 3: "invisible (Cf, Zl, Zp, default-ignorable)", 4: "joiner or variation selector", 5: "noncharacter, object or replacement character", 6: "whitespace a text admits (Unicode White_Space minus ASCII, U+0085 and U+2028-2029)" };

/** The refused code points of word rule 7 (`TopicProfile.REFUSED`): [lo, hi, class, what], sorted and disjoint. */
export const REFUSED = [
  [0x80, 0x9f, 1, "C1 controls"],
  [0xa0, 0xa0, 6, "NO-BREAK SPACE"],
  [0xad, 0xad, 3, "SOFT HYPHEN"],
  [0x34f, 0x34f, 4, "COMBINING GRAPHEME JOINER"],
  [0x600, 0x605, 3, "Arabic number signs (Cf)"],
  [0x61c, 0x61c, 2, "ARABIC LETTER MARK"],
  [0x6dd, 0x6dd, 3, "ARABIC END OF AYAH (Cf)"],
  [0x70f, 0x70f, 3, "SYRIAC ABBREVIATION MARK (Cf)"],
  [0x890, 0x891, 3, "Arabic pound and piastre marks above (Cf)"],
  [0x8e2, 0x8e2, 3, "ARABIC DISPUTED END OF AYAH (Cf)"],
  [0x115f, 0x1160, 3, "Hangul choseong and jungseong fillers"],
  [0x1680, 0x1680, 6, "OGHAM SPACE MARK"],
  [0x17b4, 0x17b5, 3, "Khmer inherent vowels"],
  [0x180b, 0x180d, 4, "Mongolian free variation selectors 1-3"],
  [0x180e, 0x180e, 3, "MONGOLIAN VOWEL SEPARATOR"],
  [0x180f, 0x180f, 4, "MONGOLIAN FREE VARIATION SELECTOR FOUR"],
  [0x2000, 0x200a, 6, "EN QUAD .. HAIR SPACE"],
  [0x200b, 0x200b, 3, "ZERO WIDTH SPACE"],
  [0x200c, 0x200d, 4, "ZERO WIDTH NON-JOINER, ZERO WIDTH JOINER"],
  [0x200e, 0x200f, 2, "LEFT-TO-RIGHT MARK, RIGHT-TO-LEFT MARK"],
  [0x2028, 0x2029, 3, "LINE SEPARATOR, PARAGRAPH SEPARATOR"],
  [0x202a, 0x202e, 2, "bidi embeddings and overrides"],
  [0x202f, 0x202f, 6, "NARROW NO-BREAK SPACE"],
  [0x205f, 0x205f, 6, "MEDIUM MATHEMATICAL SPACE"],
  [0x2060, 0x2065, 3, "WORD JOINER, invisible operators, U+2065"],
  [0x2066, 0x2069, 2, "bidi isolates"],
  [0x206a, 0x206f, 3, "deprecated format characters"],
  [0x3000, 0x3000, 6, "IDEOGRAPHIC SPACE"],
  [0x3164, 0x3164, 3, "HANGUL FILLER"],
  [0xfdd0, 0xfdef, 5, "noncharacters"],
  [0xfe00, 0xfe0f, 4, "variation selectors 1-16"],
  [0xfeff, 0xfeff, 3, "ZERO WIDTH NO-BREAK SPACE (BOM)"],
  [0xffa0, 0xffa0, 3, "HALFWIDTH HANGUL FILLER"],
  [0xfff0, 0xfffb, 3, "U+FFF0-FFF8 and the interlinear annotation characters"],
  [0xfffc, 0xffff, 5, "OBJECT and REPLACEMENT CHARACTER, U+FFFE, U+FFFF"],
  [0x110bd, 0x110bd, 3, "KAITHI NUMBER SIGN (Cf)"],
  [0x110cd, 0x110cd, 3, "KAITHI NUMBER SIGN ABOVE (Cf)"],
  [0x13430, 0x1343f, 3, "Egyptian hieroglyph format controls"],
  [0x1bca0, 0x1bca3, 3, "shorthand format controls"],
  [0x1d173, 0x1d17a, 3, "musical symbol format controls"],
  ...Array.from({ length: 13 }, (_, i) => [((i + 1) << 16) | 0xfffe, ((i + 1) << 16) | 0xffff, 5, `plane ${i + 1} noncharacters`]),
  [0xe0000, 0xe00ff, 3, "tag characters and their block"],
  [0xe0100, 0xe01ef, 4, "variation selectors 17-256"],
  [0xe01f0, 0xe0fff, 3, "the rest of the default-ignorable block"],
  [0xefffe, 0xeffff, 5, "plane 14 noncharacters"],
  [0xffffe, 0xfffff, 5, "plane 15 noncharacters"],
  [0x10fffe, 0x10ffff, 5, "plane 16 noncharacters"],
];

export const refusedClass = (s) => REFUSED.find(([lo, hi]) => s >= lo && s <= hi)?.[2] ?? 0;

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

/** The ASCII a word admits: exactly these 39 characters (James, 2026-11-26: nothing that breaks URLs or OS paths). */
export const WORD_ASCII = "abcdefghijklmnopqrstuvwxyz0123456789-_.";
const WORD_OK = new Set([...WORD_ASCII].map((c) => c.charCodeAt(0)));

/** The `topic-word/1` grammar (`TopicProfile.wordRefusal`, hex in): 0 admitted, else 1 length; scanning in order
 *  2 malformed UTF-8, 3 an ASCII byte outside `WORD_ASCII` or 7 a refused scalar; then 4 the word ends with `.`
 *  (so `.` and `..` too), 9 it starts with `-`, 6 `0x` and exactly 40 lowercase hex characters. Code 5 (once a
 *  leading `~`) is unused: a `~` is code 3. Code 8 is the rule's (refs present). */
export function wordRefusal(hex) {
  const b = bytesOf(hex);
  const n = b.length;
  if (n === 0 || n > 255) return 1;
  for (let i = 0; i < n;) {
    const c = b[i];
    if (c < 0x80) {
      if (!WORD_OK.has(c)) return 3;
      i++;
    } else {
      const [s, w] = scalar(b, i);
      if (w === 0) return 2;
      if (refusedClass(s)) return 7;
      i += w;
    }
  }
  if (b[n - 1] === 0x2e) return 4;
  if (b[0] === 0x2d) return 9;
  if (n === 42 && b[0] === 0x30 && b[1] === 0x78 && [...b.subarray(2)].every((c) => (c >= 0x30 && c <= 0x39) || (c >= 0x61 && c <= 0x66))) return 6;
  return 0;
}

/** The `text/1` grammar (`TopicProfile.textRefusal`, hex in): 0 admitted, else 20 length; scanning in order 21
 *  malformed UTF-8, 22 a control character (C0, DEL, C1), 23 a bidi control, an invisible scalar or a noncharacter
 *  (classes 2, 3 and 5). */
export function textRefusal(hex) {
  const b = bytesOf(hex);
  const n = b.length;
  if (n === 0 || n > 255) return 20;
  for (let i = 0; i < n;) {
    const c = b[i];
    if (c < 0x80) {
      if (c < 0x20 || c === 0x7f) return 22;
      i++;
    } else {
      const [s, w] = scalar(b, i);
      if (w === 0) return 21;
      const k = refusedClass(s);
      if (k === 1) return 22;
      if (k === 2 || k === 3 || k === 5) return 23;
      i += w;
    }
  }
  return 0;
}

/** A value given as raw bytes (`{ hex }`); a plain string is its UTF-8. */
const x = (hex) => ({ hex });
const hexOf = (m) => (typeof m === "string" ? stringToHex(m) : m.hex);
/** UTF-8 of one scalar. */
const cp = (s) => x(toHex(Buffer.from(String.fromCodePoint(s), "utf8")));
const cat = (...parts) => x(`0x${parts.map((p) => hexOf(p).slice(2)).join("")}`);
const rep = (unit, k) => cat(...Array(k).fill(unit));

/** [label, word (a string, or hex), note]. */
const WORDS = [
  ["one ASCII letter", "a", ""],
  ["a lowercase word", "tesla", ""],
  ["digits, '-', '_' and '.' inside", "model-3_v1.0", ""],
  ["every admitted punctuation byte", "a-b_c.d", "'-', '_' and '.' are the only ASCII punctuation a word admits"],
  ["c++ is not a word", "c++", "code 3"],
  ["c# is not a word", "c#", "code 3"],
  ["a leading '-'", "-a", "code 9: it keeps -word free to mean 'not' in link syntax"],
  ["-x", "-x", "code 9"],
  ["only '-'", "-", "code 9"],
  ["--x", "--x", "code 9"],
  ["-a.", "-a.", "code 4: the trailing '.' comes before the leading '-'"],
  ["a-", "a-", "a '-' elsewhere is admitted"],
  ["a-b", "a-b", ""],
  ["x-", "x-", ""],
  ["a--b", "a--b", ""],
  ["255 ASCII bytes", rep("a", 255), "the longest word"],
  ["Latin-1 letter (2 bytes)", "café", ""],
  ["CJK, 3 bytes each", "東京", ""],
  ["255 bytes of CJK", rep(cp(0x6771), 85), ""],
  ["an emoji (4 bytes)", cp(0x1f697), ""],
  ["U+10FFFD", cp(0x10fffd), "the last scalar a word admits (U+10FFFE and U+10FFFF are noncharacters)"],
  ["tesla and a NO-BREAK SPACE", cat("tesla", cp(0xa0)), "code 7: a look-alike of tesla; every fold rule turns whitespace into _"],
  ["U+00A9 COPYRIGHT SIGN", cp(0xa9), ""],
  ["...", "...", "code 4: a word never ends with '.'"],
  [".a", ".a", "a leading '.' is admitted"],
  ["a.", "a.", "code 4"],
  ["a.b", "a.b", ""],
  ["a..b", "a..b", "inner dots are admitted"],
  ["~ first", "~a", "code 3: '~' is refused wherever it stands"],
  ["~ inside", "a~b", "code 3"],
  ["~ last", "a~", "code 3"],
  ["0x and 39 hex", cat("0x", rep("f", 39)), ""],
  ["0x and 41 hex", cat("0x", rep("f", 41)), ""],
  ["0x, 39 hex and a non-hex letter", cat("0x", rep("f", 39), "g"), ""],
  ["0y and 40 hex", cat("0y", rep("a", 40)), ""],
  ["0x alone", "0x", "the two characters 0x"],
  ["empty", x("0x"), "code 1"],
  ["256 ASCII bytes", rep("a", 256), "code 1"],
  ["255 bytes of CJK and one more byte", cat(rep(cp(0x6771), 85), "a"), "code 1"],
  ["overlong 2-byte", x("0xc080"), "code 2"],
  ["overlong 2-byte (C1)", x("0xc1bf"), ""],
  ["overlong 3-byte", x("0xe08080"), ""],
  ["overlong 4-byte", x("0xf0808080"), ""],
  ["surrogate U+D800", x("0xeda080"), ""],
  ["surrogate U+DFFF", x("0xedbfbf"), ""],
  ["above U+10FFFF", x("0xf4908080"), ""],
  ["lead byte F5", x("0xf5808080"), ""],
  ["truncated 3-byte", x("0xe282"), ""],
  ["truncated at the end", x("0x61e2"), ""],
  ["a stray continuation byte", x("0x80"), ""],
  ["a lone lead byte", x("0xc3"), ""],
  ["a lead byte then ASCII", x("0xc341"), ""],
  ["a slash", "a/b", "code 3"],
  ["only a slash", "/", ""],
  ["a backslash", "a\\b", "code 3: it reads as a path separator too"],
  ["only a backslash", "\\", ""],
  ["a space", "a b", ""],
  ["NUL", x("0x00"), ""],
  ["a tab", x("0x09"), ""],
  ["0x1f", x("0x611f"), ""],
  ["DEL", x("0x7f"), ""],
  ["uppercase first", "Tesla", ""],
  ["uppercase last", "teslA", ""],
  ["a byte refusal before a shape refusal", "A.", "code 3, not 4"],
  ["uppercase X in 0x", cat("0X", rep("a", 40)), "a byte refusal"],
  ["uppercase hex after 0x", cat("0x", rep("F", 40)), "a byte refusal"],
  ["a slash after a multi-byte scalar", cat("e", cp(0x301), "/"), ""],
  [".", ".", "code 4: '.' ends with '.' (a URL resolver also removes it as a dot-segment)"],
  ["con", "con", "a Windows device name is a word"],
  ["nul.txt", "nul.txt", ""],
  ["..", "..", "code 4"],
  ["~", "~", "code 3 (code 5 is unused)"],
  ["~efs", "~efs", "code 3"],
  ["~ then a word", "~tesla", "code 3"],
  ["an address-shaped word", "0x00112233445566778899aabbccddeeff00112233", "code 6"],
  ["40 f after 0x", cat("0x", rep("f", 40)), ""],
  ["the zero address", cat("0x", rep("0", 40)), ""],
  ["a refused scalar before a malformed byte", cat("a", cp(0x200b), x("0xc0")), "code 7: the scan stops at the first refusal"],
  ["a malformed byte before a forbidden ASCII byte", x("0xc0412f"), "code 2"],
];
// every ASCII byte as a one-byte word and between two letters (admitted, or code 3; '.' alone is code 4)
for (let c = 0; c < 0x80; c++) {
  const name = `0x${c.toString(16).padStart(2, "0")}`;
  const one = x(`0x${c.toString(16).padStart(2, "0")}`);
  WORDS.push([`ASCII ${name} alone`, one, ""]);
  WORDS.push([`ASCII ${name} inside`, cat("a", one, "b"), ""]);
}
// rule 7: the first, last and (when wider) a middle scalar of every entry of the table, each alone and inside a word
for (const [lo, hi, , what] of REFUSED) {
  const pts = [...new Set([lo, Math.floor((lo + hi) / 2), hi])];
  for (const s of pts) WORDS.push([`U+${s.toString(16).toUpperCase().padStart(4, "0")} (${what})`, cp(s), "code 7"]);
}
WORDS.push(["ZWJ inside an emoji sequence", cat(cp(0x1f468), cp(0x200d), cp(0x1f469)), "code 7: joiners are refused in a word"]);
WORDS.push(["VS16 after a symbol", cat(cp(0x2764), cp(0xfe0f)), "code 7: variation selectors are refused in a word"]);
WORDS.push(["the scalar before SOFT HYPHEN", cp(0xac), "U+00AC NOT SIGN: admitted"]);
WORDS.push(["the scalar before the noncharacter block", cp(0xfdcf), ""]);
WORDS.push(["the scalar after U+00A0", cp(0xa1), "U+00A1 INVERTED EXCLAMATION MARK: admitted"]);
WORDS.push(["the scalar before U+1680", cp(0x167f), ""]);
WORDS.push(["the scalar after U+1680", cp(0x1681), ""]);
WORDS.push(["the scalar before U+2000", cp(0x1fff), ""]);
WORDS.push(["the scalar after U+202F", cp(0x2030), "U+2030 PER MILLE SIGN: admitted"]);
WORDS.push(["the scalar before U+205F", cp(0x205e), ""]);
WORDS.push(["the scalar before U+3000", cp(0x2fff), ""]);
WORDS.push(["the scalar after U+3000", cp(0x3001), "U+3001 IDEOGRAPHIC COMMA: admitted"]);
WORDS.push(["ASCII whitespace", x("0x0a"), "code 3: U+0009-000D and U+0020 are the byte rule's (see also a tab, a space)"]);
WORDS.push(["U+000D", cat("a", x("0x0d")), "code 3"]);
WORDS.push(["the scalar after U+206F", cp(0x2070), ""]);
WORDS.push(["the scalar after U+FE0F", cp(0xfe10), ""]);
WORDS.push(["the scalar before U+E0000", cp(0xdffff - 2), ""]);
WORDS.push(["the scalar after U+E0FFF", cp(0xe1000), ""]);

/** [label, text, note]. */
const TEXTS = [
  ["a label with a slash", "AC/DC", "'/', uppercase and spaces are admitted"],
  ["a sentence", "The quick brown fox.", ""],
  ["one space", " ", ""],
  ["255 bytes", rep("x", 255), ""],
  ["CJK", "東京", ""],
  ["an emoji ZWJ sequence", cat(cp(0x1f468), cp(0x200d), cp(0x1f469)), "joiners are admitted in a text"],
  ["a variation selector", cat(cp(0x2764), cp(0xfe0f)), "variation selectors are admitted in a text"],
  ["a backslash", "C:\\x", "admitted in a text"],
  ["empty", x("0x"), "code 20"],
  ["256 bytes", rep("x", 256), "code 20"],
  ["overlong", x("0xc0af"), "code 21"],
  ["a surrogate", x("0xeda080"), "code 21"],
  ["truncated", x("0x41e2"), "code 21"],
  ["a newline", "a\nb", "code 22"],
  ["NUL", x("0x00"), "code 22"],
  ["DEL", x("0x7f"), "code 22"],
  ["a C1 control", cat("a", cp(0x85)), "code 22"],
  ["RIGHT-TO-LEFT OVERRIDE", cat("a", cp(0x202e), "b"), "code 23"],
  ["ARABIC LETTER MARK", cp(0x61c), "code 23"],
  ["ZERO WIDTH SPACE", cp(0x200b), "code 23"],
  ["SOFT HYPHEN", cp(0xad), "code 23"],
  ["BOM", cp(0xfeff), "code 23"],
  ["a tag character", cp(0xe0041), "code 23"],
  ["a control before a malformed byte", x("0x0ac0"), "code 22: the scan stops at the first refusal"],
  ["a tab", "a\tb", "code 22: U+0009-000D are C0 controls"],
  ["NEXT LINE (U+0085)", cat("a", cp(0x85), "b"), "code 22: a C1 control, whitespace or not"],
  ["LINE SEPARATOR", cat("a", cp(0x2028), "b"), "code 23: a label is one line"],
  ["PARAGRAPH SEPARATOR", cat("a", cp(0x2029), "b"), "code 23"],
  ["a noncharacter", cp(0xfdd0), "code 23: noncharacters never belong in display text"],
  ["the last of U+FDD0-FDEF", cat("a", cp(0xfdef)), "code 23"],
  ["OBJECT REPLACEMENT CHARACTER", cp(0xfffc), "code 23"],
  ["the replacement character", cp(0xfffd), "code 23"],
  ["U+FFFF", cp(0xffff), "code 23"],
  ["a plane 1 noncharacter", cat("a", cp(0x1fffe)), "code 23"],
  ["U+10FFFF", cp(0x10ffff), "code 23"],
  ["the scalar before U+FDD0", cp(0xfdcf), "admitted"],
  ["U+FFFB, before the object character", cp(0xfffb), "code 23: an interlinear annotation character (invisible)"],
  ["U+10FFFD", cp(0x10fffd), "admitted"],
];
// whitespace a word refuses and a text admits (class 6): no-break and typographic spaces, each between two letters
for (const [lo, hi, cls, what] of REFUSED) {
  if (cls !== 6) continue;
  for (const s of [...new Set([lo, hi])]) TEXTS.push([`a U+${s.toString(16).toUpperCase().padStart(4, "0")} (${what}) inside`, cat("a", cp(s), "b"), "admitted in a text"]);
}

const jsonAction = (a) => ({ ...a, expectedRevision: a.expectedRevision.toString() });
const act = (o) => ({ kind: 0, typeId: ZERO, bodyHashOrRecordId: ZERO, purpose: ZERO, subject: ZERO, role: ZERO, target: ZERO, expectedRevision: 0n, saltOrStrength: ZERO, ...o });
const publish = (typeId, body) => act({ kind: KIND.PUBLISH, typeId, bodyHashOrRecordId: keccak256(body) });
const bind = (purpose, subject, role, target, expected = 0n) => act({ kind: KIND.BIND, purpose, subject, role, target, expectedRevision: BigInt(expected) });
const word32 = (n) => pad(toHex(n), { size: 32 });

/** EfsTopics, in JS: the ids and the builders. */
export const topics = {
  wordPageId: (t, word) => keys.record(t.word, hexOf(word)),
  pathBody: (parent, page) => enc(["bytes32", "bytes32"], [parent, page]),
  childId: (t, parent, page) => keys.record(t.topic, topics.pathBody(parent, page)),
  pathId: (t, words) => words.slice(1).reduce((id, w) => topics.childId(t, id, topics.wordPageId(t, w)), topics.wordPageId(t, words[0])),
  propertyKey: (key) => keccak256(enc(["bytes32", "bytes32"], [h("efs/property-key/1"), keccak256(hexOf(key))])),
  // a label's BCP 47 tag is lowercased before its key is derived (ASCII A-Z only; EfsTopics.labelKey)
  labelKey: (language) => topics.propertyKey(`label:${topics.labelLanguage(language)}`),
  labelLanguage: (language) => language.replace(/[A-Z]/g, (c) => c.toLowerCase()),
  registerWord: (t, word) => ({ actions: [publish(t.word, hexOf(word))], bodies: [hexOf(word)] }),
  registerPath: (t, words) => {
    const actions = words.map((w) => publish(t.word, hexOf(w)));
    const bodies = words.map(hexOf);
    let id = topics.wordPageId(t, words[0]);
    for (const w of words.slice(1)) {
      const body = topics.pathBody(id, topics.wordPageId(t, w));
      actions.push(publish(t.topic, body));
      bodies.push(body);
      id = keys.record(t.topic, body);
    }
    return { actions, bodies, id };
  },
  registerChild: (t, parent, word, withPage) => {
    const body = topics.pathBody(parent, topics.wordPageId(t, word));
    const actions = [...(withPage ? [publish(t.word, hexOf(word))] : []), publish(t.topic, body)];
    const bodies = [...(withPage ? [hexOf(word)] : []), body];
    return { actions, bodies, id: keys.record(t.topic, body) };
  },
  tag: (topic, thing, expected = 0n, strength = 0) => ({ ...bind(PURPOSES.TAG, topic, thing, thing, expected), saltOrStrength: word32(strength) }),
  deny: (topic, thing, expected = 0n, strength = 0) => ({ ...bind(PURPOSES.TAG, topic, thing, ZERO, expected), kind: KIND.UNBIND, saltOrStrength: word32(strength) }),
  property: (subject, key, value, expected = 0n) => bind(PURPOSES.PROPERTY, subject, key, value, expected),
  label: (t, subject, language, text, expected = 0n) => {
    const textRecord = keys.record(t.text, hexOf(text));
    return { actions: [publish(t.text, hexOf(text)), topics.property(subject, topics.labelKey(language), textRecord, expected)], bodies: [hexOf(text), "0x"], textRecord };
  },
  same: (topic, other, expected = 0n) => bind(PURPOSES.SAME, topic, other, other, expected),
  broader: (topic, parent, expected = 0n) => bind(PURPOSES.BROADER, topic, parent, parent, expected),
};

const bodiesHash = (bodies) => keccak256(encodeAbiParameters([{ type: "bytes[]" }], [bodies]));

/** The document, for the release's Type ids (`plan.profile`). */
export function topicVectors(plan) {
  const id = (type) => plan.profile.find((p) => p.type === type).typeId;
  const t = { word: id("topic-word/1"), topic: id("topic/1"), text: id("text/1") };
  const words = WORDS.map(([label, w, note]) => {
    const hex = hexOf(w);
    const row = { label, hex, length: (hex.length - 2) / 2, code: wordRefusal(hex) };
    if (typeof w === "string") row.word = w;
    if (note) row.note = note;
    if (row.code === 0) row.pageId = keys.record(t.word, hex);
    return row;
  });
  for (const c of [1, 2, 3, 4, 6, 7, 9]) if (!words.some((w) => w.code === c)) throw new Error(`topic vectors: no word with code ${c}`);
  if (words.some((w) => w.code === 5)) throw new Error("topic vectors: code 5 is unused");
  // the ASCII rows agree with the 39 characters
  for (let c = 0; c < 0x80; c++) {
    const inside = words.find((w) => w.label === `ASCII 0x${c.toString(16).padStart(2, "0")} inside`);
    if (inside.code !== (WORD_OK.has(c) ? 0 : 3)) throw new Error(`topic vectors: ASCII 0x${c.toString(16)} inside`);
  }
  const texts = TEXTS.map(([label, v, note]) => {
    const hex = hexOf(v);
    const row = { label, hex, length: (hex.length - 2) / 2, code: textRefusal(hex) };
    if (typeof v === "string") row.text = v;
    if (note) row.note = note;
    if (row.code === 0) row.recordId = keys.record(t.text, hex);
    return row;
  });
  for (let c = 20; c <= 23; c++) if (!texts.some((x) => x.code === c)) throw new Error(`topic vectors: no text with code ${c}`);
  const deep = Array.from({ length: 64 }, (_, i) => `w${i}`);
  const paths = [["tesla"], ["cars", "tesla"], ["cars", "tesla", "model_y"], deep].map((ws) => {
    let at = topics.wordPageId(t, ws[0]);
    const records = [{ words: 1, id: at }];
    for (let i = 1; i < ws.length; i++) {
      const page = topics.wordPageId(t, ws[i]);
      const body = topics.pathBody(at, page);
      at = keys.record(t.topic, body);
      records.push({ words: i + 1, parent: records[i - 1].id, wordPage: page, body, id: at });
    }
    return { words: ws, pageIds: ws.map((w) => topics.wordPageId(t, w)), id: at, records };
  });
  const propertyKeys = ["label:en", "label:pt-br", "definition", "moved-to"].map((key) => ({ key, id: topics.propertyKey(key) }));
  // labelKey lowercases the language tag first: each input's key is its canonical (lowercased) tag's
  const labelKeys = ["en", "EN", "pt-br", "pt-BR", "PT-BR", "zh-Hant-TW"].map((language) => {
    const canonical = topics.labelLanguage(language);
    const id = topics.labelKey(language);
    if (id !== topics.propertyKey(`label:${canonical}`)) throw new Error(`labelKey(${language}) is not its canonical key`);
    return { language, canonical, id };
  });
  const cars = topics.pathId(t, ["cars"]);
  const tesla = topics.pathId(t, ["cars", "tesla"]);
  const thing = h("vectors/topics/thing");
  const home = pad("0x00000000000000000000000000000000000ba5ed", { size: 32 });
  const one = (label, builder, a) => ({ label, builder, actions: [a].map(jsonAction), bodies: ["0x"], actionsHash: actionsHash([a]), bodiesHash: bodiesHash(["0x"]) });
  const many = (label, builder, r) => ({ label, builder, actions: r.actions.map(jsonAction), bodies: r.bodies, actionsHash: actionsHash(r.actions), bodiesHash: bodiesHash(r.bodies), ...(r.id ? { id: r.id } : {}), ...(r.textRecord ? { textRecord: r.textRecord } : {}) });
  const builders = [
    many("register the word tesla", "EfsTopics.registerWord(t, \"tesla\")", { ...topics.registerWord(t, "tesla"), id: topics.wordPageId(t, "tesla") }),
    many("register /cars/tesla/model_y", "EfsTopics.registerPath(t, [\"cars\", \"tesla\", \"model_y\"])", topics.registerPath(t, ["cars", "tesla", "model_y"])),
    many("one new leaf /cars/tesla/model_3 with its page", "EfsTopics.registerChild(t, pathId(/cars/tesla), \"model_3\", true)", topics.registerChild(t, tesla, "model_3", true)),
    many("one new leaf on an existing page", "EfsTopics.registerChild(t, pathId(/cars), \"tesla\", false)", topics.registerChild(t, cars, "tesla", false)),
    one("tag a thing in /cars/tesla with +75", "EfsTopics.tag(pathId(/cars/tesla), thing, 0, 75)", topics.tag(tesla, thing, 0n, 75)),
    one("tag a home with 0", "EfsTopics.tag(home, thing, 0, 0)", topics.tag(home, thing, 0n, 0)),
    one("not this, a lone negative (-1)", "EfsTopics.deny(pathId(/cars), thing, 0, 0)", topics.deny(cars, thing, 0n, 0)),
    one("a negative change -1 -> -5 at revision 1", "EfsTopics.deny(pathId(/cars), thing, 1, 4)", topics.deny(cars, thing, 1n, 4)),
    one("a property with an address value", "EfsTopics.property(pathId(/cars), propertyKey(\"moved-to\"), home, 0)", topics.property(cars, topics.propertyKey("moved-to"), home)),
    many("label /cars/tesla in English", "EfsTopics.label(t, pathId(/cars/tesla), \"en\", \"Tesla, Inc.\", 0)", topics.label(t, tesla, "en", "Tesla, Inc.")),
    one("/cars/tesla is the same as /tesla", "EfsTopics.same(pathId(/cars/tesla), pathId(/tesla), 0)", topics.same(tesla, topics.wordPageId(t, "tesla"))),
    one("/cars/tesla is narrower than /cars", "EfsTopics.broader(pathId(/cars/tesla), pathId(/cars), 0)", topics.broader(tesla, cars)),
  ];
  return {
    schema: "efs/vectors/topics/1",
    generator: "tools/topic-vectors.mjs via tools/release.mjs (viem encodeAbiParameters + keccak256; the grammars from the NatSpec of src/profiles/TopicProfile.sol)",
    spec: "docs/DESIGN.md §12.5; docs/TAG-DESIGN.md §1, §8; TopicProfile.wordRefusal / textRefusal; EfsTopics",
    grammar: {
      word: "1..255 bytes of strict UTF-8; of ASCII only the 39 characters of `wordAscii` (a-z 0-9 - _ .); no scalar of `refused` (so no Unicode whitespace); not ending with '.' (so not '.' or '..'); not '0x' and exactly 40 of 0-9a-f",
      wordAscii: WORD_ASCII,
      wordAsciiRulings: [
        "James, 2026-11-26: \"? # etc shouldn't be allowed as they are literally urlencode protected params. Nothing that breaks URLs. Nothing that breaks OS file paths.\"",
        "James, 2026-11-26, later the same day (withdraws the OS-path test): \"Don't refuse windows reserved names. I only care about URI safety and us having some delimiters we can use for URL syntax\"",
      ],
      wordAsciiNote: "the 39 characters never need escaping in a link and leave every delimiter free. The non-ASCII side (`refused`) is unchanged and will be replaced by a generated table in a later release; Windows device names are words",
      wordTrailingDot: "code 4 refuses a word ending in '.' for link trimming (an auto-linker drops a full stop after a pasted link, so /inc. would open /inc): the tag design session's proposal, not a ruling; it also refuses '.' and '..'",
      wordCodes: { 0: "admitted", 1: "empty or longer than 255 bytes", 2: "malformed UTF-8", 3: "an ASCII byte outside the 39 of `wordAscii`", 4: "ends with '.' (so '.' and '..' too)", 9: "starts with '-'", 6: "'0x' and 40 lowercase hex characters (an address)", 7: "a refused scalar (any class of `refused`)" },
      wordCodeUnused: { 5: "once 'starts with ~'; a '~' is now code 3 wherever it stands. The number is left unused, never reused" },
      wordRuleCodes: { 8: "refs present (checked before the grammar); so the leading '-' rule is 9" },
      wordLeadingDash: "code 9 refuses a word starting with '-': it keeps -word free to mean 'not' in EFS link syntax (the founder's test that words leave delimiters free); the tag design session's default applied by the integration owner, not the founder's words. A '-' elsewhere is admitted (a-b, a-, a--b)",
      pathRuleCodes: { 10: "not exactly two refs and headers", 11: "body not exactly 64 bytes", 12: "the parent is neither topic/1 nor topic-word/1", 13: "the second ref is not a topic-word/1 record (the kernel refuses it first: E_REF code 2)" },
      text: "1..255 bytes of strict UTF-8; no C0, DEL or C1 control; no scalar of `refused` classes 2, 3 and 5; '/', '\\', U+0020, class 6 (no-break and typographic spaces), uppercase, joiners and variation selectors admitted",
      textCodes: { 0: "admitted", 20: "empty or longer than 255 bytes", 21: "malformed UTF-8", 22: "a control character (C0, DEL, C1)", 23: "a bidi control, an invisible scalar or a noncharacter (classes 2, 3, 5)" },
      textRuleCodes: { 24: "refs present (checked before the grammar)" },
      order: "the byte codes (2, 3, 7; 21, 22, 23) are the first found scanning from the start; the length code comes first and the whole-word shapes (4, then 9, then 6) last",
      error: "E_TOPIC_REFUSED(uint8 code) on a direct call; through the kernel E_REJECTED(leaf, typeId)",
      sdk: "fold (lowercase, NFC, the SDK's fold rule) and refuse before building a plan; the chain never normalizes",
    },
    refused: {
      note: "fixed at the first lasting deployment of topic-word/1; may change until then (the SDK fold rule is not confirmed). Sorted, disjoint, inclusive ranges",
      classes: CLASSES,
      entries: REFUSED.map(([lo, hi, cls, what]) => ({ lo, hi, class: cls, what })),
      packed: `0x${REFUSED.map(([lo, hi, cls]) => lo.toString(16).padStart(6, "0") + hi.toString(16).padStart(6, "0") + cls.toString(16).padStart(2, "0")).join("")}`,
    },
    declarationKey: plan.owner,
    typeIds: { "topic-word/1": t.word, "topic/1": t.topic, "text/1": t.text },
    ids: {
      record: "Keys.record(typeId, body) = keccak256(abi.encode(keccak256(\"efs/record/1\"), typeId, keccak256(body)))",
      wordPage: "Keys.record(topic-word/1, word)",
      path: "n = 1: the word page; n >= 2: Keys.record(topic/1, abi.encode(pathId(first n-1 words), wordPage(last word)))",
      propertyKey: "keccak256(abi.encode(keccak256(\"efs/property-key/1\"), keccak256(key))); a label key is propertyKey(\"label:\" ‖ the BCP 47 tag lowercased (ASCII A-Z only), so pt-BR is pt-br)",
    },
    order: "register every word page and path record before use and strictly before the first statement on it (an earlier action of the same publication counts): pages first, then the path records from two words on, then the statements",
    purposes: PURPOSES,
    words,
    texts,
    // the same verdicts as flat arrays (one parse each for a Solidity reader; pageId / recordId for the admitted rows)
    flat: {
      words: { hex: words.map((w) => w.hex), code: words.map((w) => w.code), pageId: words.filter((w) => w.code === 0).map((w) => w.pageId) },
      texts: { hex: texts.map((x) => x.hex), code: texts.map((x) => x.code), recordId: texts.filter((x) => x.code === 0).map((x) => x.recordId) },
    },
    paths,
    propertyKeys,
    labelKeys,
    inputs: { thing, home },
    builders,
  };
}

// `node tools/topic-vectors.mjs` writes test/vectors/topics.json alone from the current build (`pnpm release` writes it
// too, and `pnpm release:check` compares it).
if (import.meta.url === `file://${process.argv[1]}`) {
  const { writeFileSync } = await import("node:fs");
  const { join } = await import("node:path");
  const { buildPlan, root, toJSON } = await import("./deploy-plan.mjs");
  const out = join(root, "test/vectors/topics.json");
  const doc = topicVectors(await buildPlan());
  writeFileSync(out, toJSON(doc));
  console.log(`topic vectors: wrote ${out} (${doc.words.length} words, ${doc.texts.length} texts, ${doc.paths.length} paths, ${doc.builders.length} builders)`);
}
