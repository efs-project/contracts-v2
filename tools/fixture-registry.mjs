// SPDX-License-Identifier: MIT
// The machine-wide fixture registry: one lease per running instance, one claim per port, both created atomically
// (`open(…, "wx")`), so any number of agents in any number of checkouts and repos (contracts, SDK and client
// worktrees) can start fixtures at the same instant without colliding, and can find each other's instances.
// Node built-ins only: the SDK and the client supervisor import this file directly, without viem.
//
//   import { allocate, lookup, list, release, update, gc, up, down } from "./tools/fixture-registry.mjs";
//
// Layout (tools/RELEASE.md "The registry"):
//
//   <home>/leases/<name>.json      efs-fixture-lease/1, one per instance (kind chain | gateway | ui)
//   <home>/ports/<port>.json       the port claim: which lease holds the port, and the process holding it
//   <home>/instances/<name>/       a chain instance's default state directory (pid, log, journal, documents)
//
// <home> = $EFS_FIXTURE_HOME, else ${XDG_STATE_HOME:-~/.local/state}/efs/fixtures.
//
// A record is held by a process identified by (pid, start time[, command line]) as `ps` reports them, so a reused
// pid never counts as the holder. A record whose holder is dead on this host is stale and may be broken by anyone;
// breaking is serialized by a `<record>.break` file (also created with "wx"), and the breaker re-reads the record
// under it, so a fresh record is never removed by a breaker that saw an older stale one.
import { execFileSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import { closeSync, existsSync, mkdirSync, openSync, readdirSync, readFileSync, renameSync, rmSync, statSync, unlinkSync, writeSync } from "node:fs";
import { createServer } from "node:net";
import { homedir, hostname as osHostname, userInfo } from "node:os";
import { basename, join } from "node:path";

export const LEASE_SCHEMA = "efs-fixture-lease/1";
export const PORT_SCHEMA = "efs-fixture-port/1";
export const KINDS = ["chain", "gateway", "ui"];
/** Default port range per kind. chain: 8600–8999 (above the client's proposed gateway range 8546–8599, below 9000).
 *  gateway and ui have no default: the client supervisor passes its own ranges. */
export const DEFAULT_RANGES = { chain: [8600, 8999] };
/** Someone else's anvil: never allocated, never touched. */
export const FOREIGN_PORTS = new Set([60742]);

/** Stable process exit codes of the fixture CLI (tools/RELEASE.md "Exit codes"). */
export const EXIT = { OK: 0, MISMATCH: 1, USAGE: 2, CONFLICT: 3, NOT_FOUND: 4, FAILURE: 5 };

export class FixtureError extends Error {
  /** @param {string} code  machine-readable reason, e.g. PORT_BUSY; @param {number} exitCode one of EXIT */
  constructor(code, message, exitCode = EXIT.FAILURE, details = undefined) {
    super(message);
    this.name = "FixtureError";
    this.code = code;
    this.exitCode = exitCode;
    if (details !== undefined) this.details = details;
  }
}

// ---- paths -----------------------------------------------------------------------------------------------------------

export function registryHome(env = process.env) {
  if (env.EFS_FIXTURE_HOME) return env.EFS_FIXTURE_HOME;
  return join(env.XDG_STATE_HOME || join(homedir(), ".local", "state"), "efs", "fixtures");
}
const dirs = (home) => ({ leases: join(home, "leases"), ports: join(home, "ports"), instances: join(home, "instances") });
export const leasePath = (name, home = registryHome()) => join(dirs(home).leases, `${name}.json`);
export const portPath = (port, home = registryHome()) => join(dirs(home).ports, `${port}.json`);
export const instanceDir = (name, home = registryHome()) => join(dirs(home).instances, name);

function ensureHome(home) {
  try {
    for (const d of Object.values(dirs(home))) mkdirSync(d, { recursive: true });
  } catch (e) {
    throw new FixtureError("REGISTRY_UNWRITABLE", `cannot create the fixture registry at ${home} (${e.code ?? e.message}); set EFS_FIXTURE_HOME to a writable directory shared by the agents that should see each other`, EXIT.FAILURE);
  }
}

const NAME = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;
export function assertName(name) {
  if (typeof name !== "string" || !NAME.test(name)) throw new FixtureError("BAD_NAME", `instance name ${JSON.stringify(name)} must match ${NAME} (letters, digits, . _ -; at most 64)`, EXIT.USAGE);
  return name;
}
/** `<checkout basename>-<4 hex>`: readable in `list`, unique enough per start. */
export function defaultName(checkout) {
  const base = basename(checkout).toLowerCase().replace(/[^a-z0-9._-]+/g, "-").replace(/^[^a-z0-9]+/, "").slice(0, 40) || "efs";
  return `${base}-${randomBytes(2).toString("hex")}`;
}

// ---- processes -------------------------------------------------------------------------------------------------------

/** `{pid, startTime, command}` from ps (LC_ALL=C), or null when the pid does not exist. */
export function procInfo(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return null;
  let out;
  try {
    out = execFileSync("ps", ["-p", String(pid), "-o", "lstart=", "-o", "command="], { env: { ...process.env, LC_ALL: "C", LANG: "C" }, stdio: ["ignore", "pipe", "ignore"] }).toString().trim();
  } catch { return null; }
  const m = out.match(/^(\w{3} \w{3} +\d+ \d\d:\d\d:\d\d \d{4})\s+(.*)$/s);
  return m ? { pid, startTime: m[1].replace(/ +/g, " "), command: m[2].trim() } : null;
}
/** The process recorded as `{pid, startTime[, command]}` is still that process. */
export function procMatches(rec) {
  if (!rec?.pid || !rec.startTime) return false;
  const now = procInfo(rec.pid);
  return !!now && now.startTime === rec.startTime && (!rec.command || now.command === rec.command);
}
export const self = () => procInfo(process.pid) ?? { pid: process.pid, startTime: null, command: null };

// ---- atomic files ----------------------------------------------------------------------------------------------------

const json = (x) => `${JSON.stringify(x, null, 2)}\n`;
function readJSON(path) {
  try { return { text: readFileSync(path, "utf8"), get value() { return JSON.parse(this.text); } }; } catch (e) { if (e.code === "ENOENT") return null; throw e; }
}
/** Create `path` only if it does not exist (O_CREAT|O_EXCL). */
function createExclusive(path, text) {
  let fd;
  try { fd = openSync(path, "wx", 0o644); } catch (e) { if (e.code === "EEXIST") return false; throw e; }
  try { writeSync(fd, text); } finally { closeSync(fd); }
  return true;
}
/** Replace `path` atomically (write a sibling, then rename). Only the record's holder does this. */
export function writeAtomic(path, value) {
  const tmp = `${path}.${process.pid}.${randomBytes(4).toString("hex")}.tmp`;
  const fd = openSync(tmp, "wx", 0o644);
  try { writeSync(fd, typeof value === "string" ? value : json(value)); } finally { closeSync(fd); }
  renameSync(tmp, path);
}
const BREAK_STALE_MS = 10_000;
/** Remove `path` if it still holds `seenText` and `isStale` says so, serialized by `<path>.break`. */
function breakStale(path, seenText, isStale) {
  const lock = `${path}.break`;
  if (!createExclusive(lock, json({ pid: process.pid, startTime: self().startTime, at: new Date().toISOString() }))) {
    // another breaker is at work; a breaker that died leaves its lock, which ages out
    try {
      const held = JSON.parse(readFileSync(lock, "utf8"));
      if (Date.now() - statSync(lock).mtimeMs > BREAK_STALE_MS && !procMatches(held)) unlinkSync(lock);
    } catch { /* gone already */ }
    return false;
  }
  try {
    const now = readJSON(path);
    if (!now) return true; // already gone: the caller may retry its create
    if (now.text !== seenText) return false; // replaced by a fresh record since we looked
    let value;
    try { value = JSON.parse(now.text); } catch { value = null; }
    if (!isStale(value)) return false;
    unlinkSync(path);
    return true;
  } finally { try { unlinkSync(lock); } catch { /* ignore */ } }
}
/** Create a record exclusively; a stale holder is broken once. Returns {ok, holder}. */
function claimRecord(path, value, isStale) {
  const text = json(value);
  for (let attempt = 0; attempt < 3; attempt++) {
    if (createExclusive(path, text)) return { ok: true };
    const seen = readJSON(path);
    if (!seen) continue; // released between our create and our read
    let held;
    try { held = seen.value; } catch { held = null; }
    if (!isStale(held) || !breakStale(path, seen.text, isStale)) return { ok: false, holder: held };
  }
  return { ok: false, holder: readJSON(path)?.value ?? null };
}

// ---- liveness ---------------------------------------------------------------------------------------------------------

const HOST = osHostname();
/** "live" | "dead" | "foreign-host" (a record from another machine on a shared home: never judged, never broken). */
export function liveness(rec) {
  if (!rec) return "dead";
  if (rec.hostname && rec.hostname !== HOST) return "foreign-host";
  return procMatches(rec) ? "live" : "dead";
}
const stale = (rec) => rec === null || liveness(rec) === "dead";
const decorate = (lease) => {
  const state = liveness(lease);
  return { ...lease, liveness: state, expired: !!(lease.expiresAt && Date.parse(lease.expiresAt) < Date.now()) };
};

// ---- ports ------------------------------------------------------------------------------------------------------------

function bindProbe(port, host) {
  return new Promise((resolve) => {
    const s = createServer();
    s.unref();
    s.once("error", (e) => resolve(e.code === "EAFNOSUPPORT" || e.code === "EADDRNOTAVAIL" ? "n/a" : "busy"));
    s.listen({ port, host, exclusive: true }, () => s.close(() => resolve("free")));
  });
}
/** True when anything is bound to `port`: sequential bind probes on `::`, `0.0.0.0` and `127.0.0.1`. */
export async function portBusy(port) {
  for (const host of ["::", "0.0.0.0", "127.0.0.1"]) if ((await bindProbe(port, host)) === "busy") return true;
  return false;
}
export function parseRange(r) {
  if (Array.isArray(r)) return r.map(Number);
  const m = String(r).match(/^(\d+)\s*[-:]\s*(\d+)$/);
  if (!m) throw new FixtureError("BAD_RANGE", `port range ${JSON.stringify(r)} must be LOW-HIGH`, EXIT.USAGE);
  return [Number(m[1]), Number(m[2])];
}
function assertPort(port) {
  if (!Number.isInteger(port) || port < 1024 || port > 65535) throw new FixtureError("BAD_PORT", `port ${port} must be an integer in 1024–65535`, EXIT.USAGE);
  if (FOREIGN_PORTS.has(port)) throw new FixtureError("PORT_FOREIGN", `port ${port} belongs to another anvil and is never used`, EXIT.CONFLICT);
}
function portRecord(lease, port) {
  return { schema: PORT_SCHEMA, port, name: lease.name, kind: lease.kind, pid: lease.pid, startTime: lease.startTime, command: lease.command ?? null, hostname: HOST, claimedAt: new Date().toISOString() };
}
/** Claim `port` for `lease` (an explicit port: no search). Throws CONFLICT when leased by a live process or bound. */
async function claimPort(lease, port, home, { explicit }) {
  const path = portPath(port, home);
  const r = claimRecord(path, portRecord(lease, port), stale);
  if (!r.ok) {
    if (explicit) throw new FixtureError("PORT_LEASED", `port ${port} is leased by ${r.holder?.kind ?? "?"} ${JSON.stringify(r.holder?.name)} (pid ${r.holder?.pid})`, EXIT.CONFLICT, { port, holder: r.holder });
    return false;
  }
  if (await portBusy(port)) {
    try { unlinkSync(path); } catch { /* ignore */ }
    if (explicit) throw new FixtureError("PORT_BUSY", `port ${port} is bound by a process outside the registry`, EXIT.CONFLICT, { port });
    return false;
  }
  return true;
}
/** Drop `name`'s claim on `port` (only if the claim is still that lease's). */
export function releasePort(name, port, home = registryHome()) {
  if (!port) return false;
  const path = portPath(port, home);
  const cur = readJSON(path);
  if (!cur) return false;
  let v;
  try { v = cur.value; } catch { v = null; }
  if (v && v.name !== name) return false;
  try { unlinkSync(path); return true; } catch { return false; }
}

// ---- leases -----------------------------------------------------------------------------------------------------------

/**
 * Create the lease `name` and claim a port for it, atomically against every other process using the same home.
 *
 * @param {object} o
 * @param {"chain"|"gateway"|"ui"} [o.kind="chain"]
 * @param {string} o.name            instance name (unique machine-wide across kinds)
 * @param {number} [o.port]          an explicit port: CONFLICT (exit 3) when leased by a live process or bound
 * @param {[number,number]|string} [o.range]  search range when no port is given (chain default 8600–8999)
 * @param {number[]} [o.skipPorts]   ports not to try in this search (e.g. one a child failed to bind)
 * @param {number} [o.pid=process.pid]  the process that holds the lease (update it when a child takes over)
 * @param {string} [o.host="127.0.0.1"] the bind host recorded in the lease
 * @param {number} [o.ttl]           seconds; 0 = no expiry
 * @param {object} [o.meta]          more lease fields (chainId, realmSalt, stateDir, checkout, …)
 * @param {string} [o.home]          registry home (default registryHome())
 * @returns {Promise<object>} the lease as written, with `port` and `url`
 */
export async function allocate({ kind = "chain", name, port, range, skipPorts = [], pid = process.pid, host = "127.0.0.1", ttl = null, meta = {}, home = registryHome() } = {}) {
  if (!KINDS.includes(kind)) throw new FixtureError("BAD_KIND", `lease kind ${JSON.stringify(kind)} is not one of ${KINDS.join(", ")}`, EXIT.USAGE);
  assertName(name);
  ensureHome(home);
  const holder = pid === process.pid ? self() : procInfo(pid);
  if (!holder) throw new FixtureError("NO_HOLDER", `pid ${pid} does not exist`, EXIT.USAGE);
  const startedAt = new Date().toISOString();
  const lease = {
    schema: LEASE_SCHEMA, kind, name, state: "allocating", generation: 1,
    pid: holder.pid, startTime: holder.startTime, command: pid === process.pid ? null : holder.command,
    owner: { pid: process.pid, startTime: self().startTime, user: userInfo().username },
    hostname: HOST, host, port: null, url: null,
    ttl: ttl ?? null, startedAt, expiresAt: ttl ? new Date(Date.parse(startedAt) + ttl * 1000).toISOString() : null,
    ...meta,
  };
  const lp = leasePath(name, home);
  const r = claimRecord(lp, lease, stale);
  if (!r.ok) throw new FixtureError("NAME_LEASED", `instance ${JSON.stringify(name)} is already leased (${r.holder?.kind}, pid ${r.holder?.pid}, ${liveness(r.holder)})`, EXIT.CONFLICT, { name, holder: r.holder });
  try {
    let got = null;
    if (port !== undefined && port !== null) {
      assertPort(Number(port));
      await claimPort(lease, Number(port), home, { explicit: true });
      got = Number(port);
    } else {
      const [lo, hi] = parseRange(range ?? DEFAULT_RANGES[kind] ?? (() => { throw new FixtureError("NO_RANGE", `kind ${kind} has no default port range: pass range or port`, EXIT.USAGE); })());
      const skip = new Set(skipPorts.map(Number));
      for (let p = lo; p <= hi && got === null; p++) {
        if (FOREIGN_PORTS.has(p) || skip.has(p)) continue;
        if (await claimPort(lease, p, home, { explicit: false })) got = p;
      }
      if (got === null) throw new FixtureError("NO_FREE_PORT", `no free port in ${lo}–${hi} (every port leased by a live process or bound)`, EXIT.CONFLICT, { range: [lo, hi] });
    }
    const done = { ...lease, port: got, url: `http://${host.includes(":") ? `[${host}]` : host}:${got}`, state: "allocated" };
    writeAtomic(lp, done);
    return done;
  } catch (e) {
    try { unlinkSync(lp); } catch { /* ignore */ }
    throw e;
  }
}

/** Merge `patch` into lease `name` (its holder only). A changed holder (pid/startTime/command) moves the port claim too. */
export function update(name, patch, home = registryHome()) {
  const lp = leasePath(name, home);
  const cur = readJSON(lp);
  if (!cur) throw new FixtureError("NO_INSTANCE", `no lease named ${JSON.stringify(name)}`, EXIT.NOT_FOUND);
  const next = { ...cur.value, ...patch, schema: LEASE_SCHEMA, name };
  writeAtomic(lp, next);
  if (next.port && ("pid" in patch || "startTime" in patch || "command" in patch)) {
    const pp = portPath(next.port, home);
    const claim = readJSON(pp);
    if (claim && claim.value.name === name) writeAtomic(pp, { ...claim.value, pid: next.pid, startTime: next.startTime, command: next.command ?? null });
  }
  return next;
}

/** The lease `name` with `liveness` ("live" | "dead" | "foreign-host") and `expired`, or null. */
export function lookup(name, home = registryHome()) {
  assertName(name);
  const cur = readJSON(leasePath(name, home));
  if (!cur) return null;
  try { return decorate(cur.value); } catch { return { name, schema: LEASE_SCHEMA, state: "corrupt", liveness: "dead", expired: false }; }
}

/** Every lease (optionally of one kind), oldest first, each with liveness. */
export function list({ kind, home = registryHome() } = {}) {
  const d = dirs(home).leases;
  if (!existsSync(d)) return [];
  const out = [];
  for (const f of readdirSync(d)) {
    if (!f.endsWith(".json")) continue;
    const l = lookup(f.slice(0, -5), home);
    if (l && (!kind || l.kind === kind)) out.push(l);
  }
  return out.sort((a, b) => String(a.startedAt).localeCompare(String(b.startedAt)) || a.name.localeCompare(b.name));
}

/** Remove lease `name` and its port claim. Kills nothing (a chain's `down` does that, after an identity check). */
export function release(name, home = registryHome()) {
  const l = lookup(name, home);
  if (!l) return false;
  releasePort(name, l.port, home);
  try { unlinkSync(leasePath(name, home)); } catch { /* ignore */ }
  return true;
}

/**
 * Remove every lease whose holder is dead on this host, every stale port claim, and leftover `.break`/`.tmp`
 * files. With `purge`, also delete instance state directories that no lease names. Never signals a process.
 */
export function gc({ purge = false, home = registryHome() } = {}) {
  const removed = { leases: [], ports: [], files: [], stateDirs: [] };
  const d = dirs(home);
  if (!existsSync(home)) return removed;
  for (const l of list({ home })) {
    if (l.liveness !== "dead") continue;
    const cur = readJSON(leasePath(l.name, home));
    if (cur && breakStale(leasePath(l.name, home), cur.text, stale)) {
      removed.leases.push(l.name);
      releasePort(l.name, l.port, home);
    }
  }
  if (existsSync(d.ports)) {
    for (const f of readdirSync(d.ports)) {
      const p = join(d.ports, f);
      if (f.endsWith(".json")) {
        const cur = readJSON(p);
        if (!cur) continue;
        let v;
        try { v = cur.value; } catch { v = null; }
        const leaseNow = v && lookup(v.name, home);
        const orphan = v && !leaseNow && Date.now() - statSync(p).mtimeMs > BREAK_STALE_MS; // lease gone, claim left behind
        if ((stale(v) || orphan) && breakStale(p, cur.text, () => true)) removed.ports.push(Number(f.slice(0, -5)));
      }
    }
  }
  for (const sub of [d.leases, d.ports]) {
    if (!existsSync(sub)) continue;
    for (const f of readdirSync(sub)) {
      if (!/\.(break|tmp)$/.test(f)) continue;
      const p = join(sub, f);
      try { if (Date.now() - statSync(p).mtimeMs > BREAK_STALE_MS * 6) { unlinkSync(p); removed.files.push(f); } } catch { /* ignore */ }
    }
  }
  if (purge && existsSync(d.instances)) {
    for (const n of readdirSync(d.instances)) {
      if (NAME.test(n) && !lookup(n, home)) { rmSync(join(d.instances, n), { recursive: true, force: true }); removed.stateDirs.push(n); }
    }
  }
  return removed;
}

// ---- the chain fixture (lazy: these load viem and the artifacts) -------------------------------------------------------

/** Start a chain instance: `up(options)` of tools/efs-fixture.mjs (same options as the CLI, camelCase). */
export async function up(options = {}) { return (await import("./efs-fixture.mjs")).up(options); }
/** Stop chain instance `name` (identity-checked kill of its own anvil only) and remove its lease. */
export async function down(name, options = {}) { return (await import("./efs-fixture.mjs")).down({ ...options, name }); }
/** Re-run every check of instance `name` against its chain. */
export async function verify(name, options = {}) { return (await import("./efs-fixture.mjs")).verify({ ...options, name }); }
