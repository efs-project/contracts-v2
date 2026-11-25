// SPDX-License-Identifier: MIT
// Media-type vectors for `files-content/1` and `files-external/1` (docs/LARGE-FILES.md "Media types"): encoded bodies
// with their release Type ids and record ids, and the grammar's verdict on a list of media strings, so an SDK's
// encoder and validator can be checked against the contracts exactly. Computed here in JS (viem's ABI encoder and
// keccak256; the grammar is `mediaTypeRefusal` in tools/deploy-plan.mjs, written from the NatSpec, not from the
// Solidity), never by Solidity. `tools/release.mjs` writes test/vectors/media.json and `pnpm release:check` fails
// when the committed file is not what the current build produces; `test/profiles/FilesMediaVectors.t.sol` asserts
// every vector against `FilesProfile.mediaTypeRefusal`, both rules, `EfsFiles` and `Keys`, so the file cannot drift.
// The Type ids are the release's (the fixture declaration key), so the file changes whenever a rule's code does.
import { sha256, stringToHex } from "viem";
import { filesContentBody, filesExternalBody, keys, mediaTypeRefusal } from "./deploy-plan.mjs";

/** The `E_FILES_REFUSED` code each rule gives a media tail (0: admitted). */
const contentCode = (hex) => ((hex.length - 2) / 2 > 255 ? 11 : mediaTypeRefusal(hex) ? 12 : 0);
const externalCode = (hex) => ((hex.length - 2) / 2 > 255 ? 8 : mediaTypeRefusal(hex) ? 9 : 0);
const name = (n, c = "a") => c.repeat(n);
const DOCX = "application/vnd.openxmlformats-officedocument.wordprocessingml.document";
const MAX = `${name(127)}/${name(127, "b")}`;

/** [label, media (a string, or hex when it has bytes outside 0x20..0x7e), note]. */
const STRINGS = [
  ["empty", "", "unknown media type: a reader falls back to the name's extension"],
  ["plain type", "image/png", ""],
  ["with a parameter", "text/html; charset=utf-8", "the canonical form: one space after ';'"],
  ["parameter without a space", "text/html;charset=utf-8", ""],
  ["vendor tree, 71 bytes", DOCX, ""],
  ["quoted parameter with spaces and uppercase", 'video/mp4; codecs="avc1.42E01E, mp4a.40.2"', "the chain never normalizes parameters: their case and spaces are kept"],
  ["x. tree with a structured suffix", "application/x.foo+json", ""],
  ["every name byte", "a0!#$&-^_.+/z9!#$&-^_.+", "RFC 6838 restricted-name characters after the first"],
  ["digits first", "3gpp/1d-interleaved-parityfec", "a name may start with a digit"],
  ["127-byte type", `${name(127)}/b`, "the longest name"],
  ["255-byte maximum", MAX, "127 + 1 + 127 bytes"],
  ["a slash after ';'", "text/plain; x=a/b", "only the first '/' (before the first ';') separates type and subtype"],
  ["trailing ';' with nothing after it", "text/plain;", "ADMITTED: everything from the first ';' is printable ASCII and is not parsed further (RFC 9110 allows an empty parameter list after ';' with optional whitespace)"],
  ["';' then spaces only", "text/plain;  ", "admitted for the same reason"],
  ["0x7e after ';'", "text/plain; a=~", "0x7e is the last admitted byte"],
  ["uppercase in the type", "Text/plain", "the chain never lowercases; an SDK must"],
  ["uppercase in the subtype", "text/HTML", "the chain never lowercases; an SDK must"],
  ["no slash", "textplain", ""],
  ["missing subtype", "text/", ""],
  ["missing type", "/plain", ""],
  ["two slashes before ';'", "text/plain/x", "'/' is not a name byte"],
  ["two slashes, no parameters", "a/b/c", ""],
  ["leading space", " text/plain", ""],
  ["space before ';'", "text/plain ; charset=utf-8", "stricter than RFC 9110 (which allows OWS before ';'): the canonical form has none"],
  ["tab before ';'", "text/plain\t; charset=utf-8", "stricter than RFC 9110 (OWS may be a tab)"],
  ["tab after ';'", "text/plain;\tcharset=utf-8", "stricter than RFC 9110: a tab is a control byte, never admitted (the gateway emits the string in a header)"],
  ["trailing space, no ';'", "text/plain ", "a space is not a name byte"],
  ["wildcard subtype", "text/*", "stricter than RFC 9110 Accept syntax: '*' is not a restricted-name byte; a descriptor names one type"],
  ["wildcard type", "*/*", "as above"],
  ["first byte not alphanumeric", "-text/plain", "a restricted-name starts with a letter or digit"],
  ["subtype starting with '+'", "text/+json", ""],
  ["a byte RFC 6838 forbids in a name", "text/pl=ain", "'=' is a token byte (RFC 9110) but not a restricted-name byte"],
  ["CR LF after ';'", "0x746578742f706c61696e3b0d0a782d783a2079", "header injection: a control byte after ';'"],
  ["NUL after ';'", "0x746578742f706c61696e3b00", ""],
  ["0x7f after ';'", "0x746578742f706c61696e3b7f", "DEL is not printable"],
  ["0x80 after ';'", "0x746578742f706c61696e3b80", "a byte at or above 0x80"],
  ["UTF-8 after ';'", "0x746578742f706c61696e3b20743dc3a9", "non-ASCII parameter values are refused (RFC 8187 encoding is the author's job)"],
  ["0xff in the subtype", "0x746578742f706cff", ""],
  ["128-byte type", `${name(128)}/b`, "one byte over the 127-byte name limit"],
  ["128-byte subtype", `a/${name(128, "b")}`, ""],
  ["256 bytes", `${name(127)}/${name(127, "b")};`, "one byte over the 255-byte limit (the length word refuses it before the grammar)"],
];

const hexOf = (m) => (m.startsWith("0x") ? m : stringToHex(m));

/** The document, for the release's Type ids (`plan.profile`). */
export function mediaVectors(plan) {
  const id = (type) => plan.profile.find((p) => p.type === type).typeId;
  const T = { content: id("files-content/1"), external: id("files-external/1"), bytes: id("files-bytes/1") };
  const doc = "0x4d656574696e672061742031303a30302e0a"; // "Meeting at 10:00.\n"
  const chunk = keys.record(T.bytes, `0x${sha256(doc).slice(2)}${doc.slice(2)}`);
  const sentinel = keys.record(T.bytes, sha256("0x"));
  const locator = "ar://bNbA3TEQVL60xlgCcqdz4ZPHFZ711cZ3hmkpGttDt_U";
  const contents = [
    ["empty media", ""], ["image/png", "image/png"], ["with a parameter", "text/html; charset=utf-8"], ["255-byte maximum", MAX],
  ].map(([label, media]) => {
    const inputs = { bytesRef: chunk, carrier: 0, length: 18, sha256: sha256(doc), media, mediaHex: stringToHex(media) };
    const body = filesContentBody(inputs);
    return { label, type: "files-content/1", inputs, body, bodyLength: (body.length - 2) / 2, typeId: T.content, recordId: keys.record(T.content, body) };
  });
  const externals = [["locator, empty media", ""], ["locator and a media type", "text/html; charset=utf-8"], ["locator and the 255-byte maximum", MAX]].map(([label, media]) => {
    const inputs = { sentinel, length: 1234, sha256: sha256(stringToHex("remote bytes")), locator, media, mediaHex: stringToHex(media) };
    const body = filesExternalBody(inputs);
    return { label, type: "files-external/1", inputs, body, bodyLength: (body.length - 2) / 2, typeId: T.external, recordId: keys.record(T.external, body) };
  });
  const rules = STRINGS.map(([label, m, note]) => {
    const hex = hexOf(m);
    const grammar = mediaTypeRefusal(hex);
    const row = { label, mediaHex: hex, length: (hex.length - 2) / 2, accepted: grammar === 0, grammarCode: grammar, contentRuleCode: contentCode(hex), externalRuleCode: externalCode(hex) };
    if (!m.startsWith("0x")) row.media = m;
    if (note) row.note = note;
    return row;
  });
  return {
    schema: "efs/vectors/media/1",
    generator: "tools/media-vectors.mjs via tools/release.mjs (viem encodeAbiParameters + keccak256; grammar from tools/deploy-plan.mjs mediaTypeRefusal)",
    spec: "docs/LARGE-FILES.md \"Media types\"; FilesProfile.mediaTypeRefusal",
    grammar: {
      empty: "admitted: the media type is unknown",
      form: "type \"/\" subtype [\";\" parameters], at most 255 bytes; the rest of the body after the head (content: 320 bytes; external: 224 + locatorLength), so no length word is stored and nothing can follow it",
      name: "RFC 6838 restricted-name, lowercase only: 1..127 bytes, first a-z or 0-9, then a-z 0-9 ! # $ & - ^ _ . +",
      parameters: "every byte from the first ';' to the end in 0x20..0x7e; not parsed further",
      grammarCodes: { 0: "admitted", 1: "longer than 255 bytes", 2: "no valid type name at the start", 3: "the type is not followed by '/'", 4: "no valid subtype name after '/'", 5: "the subtype is followed by a byte other than ';'", 6: "a byte outside 0x20..0x7e after the first ';'" },
      contentRuleCodes: { 2: "the body is shorter than the ten words (320 bytes)", 11: "the media bytes are longer than 255 (body above 575 bytes)", 12: "the media bytes are not a media type" },
      externalRuleCodes: { 5: "the body is shorter than 224 + locatorLength (or locatorLength outside 1..2,048)", 8: "the media bytes are longer than 255", 9: "the media bytes are not a media type" },
      sdk: "normalize (lowercase type and subtype) and refuse an invalid string when building the plan, so a bad media type is never an on-chain revert",
    },
    declarationKey: plan.owner,
    typeIds: { "files-bytes/1": T.bytes, "files-content/1": T.content, "files-external/1": T.external },
    encoding: [...contents, ...externals],
    rules,
  };
}

// `node tools/media-vectors.mjs` writes test/vectors/media.json alone from the current build (`pnpm release` writes it
// too, and `pnpm release:check` compares it).
if (import.meta.url === `file://${process.argv[1]}`) {
  const { writeFileSync } = await import("node:fs");
  const { join } = await import("node:path");
  const { buildPlan, root, toJSON } = await import("./deploy-plan.mjs");
  const out = join(root, "test/vectors/media.json");
  const doc = mediaVectors(await buildPlan());
  writeFileSync(out, toJSON(doc));
  console.log(`media vectors: wrote ${out} (${doc.encoding.length} encodings, ${doc.rules.length} media strings)`);
}
