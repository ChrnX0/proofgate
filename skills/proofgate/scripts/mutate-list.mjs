#!/usr/bin/env node
/**
 * mutate --list — a project's curated list of defects, judged against its own suite.
 *
 * Reached through `mutate.mjs --list …` (the stdin mode there is unchanged).
 *
 *   mutate.mjs --list mutations.jsonl --check                      anchors only — milliseconds, no suite
 *   mutate.mjs --list mutations.jsonl --status [--max-age-days N]  is the last verdict still about this code?
 *   mutate.mjs --list mutations.jsonl [--slice i/n] [--timeout S] -- <suite command...>
 *
 * The list is DATA, one JSON object per line (`//` lines and blanks ignored):
 *   {"file": "src/price.ts", "from": "Math.round(x)", "to": "Math.floor(x)",
 *    "hurts": "a price rounded down sells every unit a little under cost"}
 *   + "name":       optional label (defaults to `hurts`)
 *   + "equivalent": optional REASON no test can tell this from the original
 *
 * It is curated, not random, and `hurts` is required on purpose: the defect a hurried person
 * would really introduce, plus one sentence about the damage, is what makes a survivor read as
 * a hole in a rule instead of a style note. The list grows by one rule: every defect that gets
 * fixed gains a mutation, because that is the cheapest proof the test written beside the fix bites.
 *
 * Borrowed from the project that ran this the longest (a 310-entry list, a ~55 s suite); each
 * rule below is a scar of theirs, stated once here:
 *
 *  - THREE outcomes, not two. The suite passed, failed, or was NOT MEASURED (killed, timed out,
 *    command not found). "Not measured" is neither protection nor a hole, and counting it as
 *    caught — `!passed` — is how a report once declared "all 90 defects caught" from a workshop
 *    that never ran the suite. It is retried once, then reported as unmeasured, and exits 1.
 *  - Mutations run in a COPY of the tree. The working tree is never touched, so a run killed
 *    half-way cannot leave broken code behind; the worst case is a temp dir.
 *  - The copy must PROVE it can run the suite before anything is judged: an unmutated baseline
 *    that passes, and a harmless sentinel edit (a trailing newline) that must also pass. A
 *    workshop missing a file the tests read fails everything, and "everything fails" reads as
 *    "everything was caught".
 *  - An anchor that no longer occurs (stale), or occurs twice (ambiguous: `replace` would change
 *    the first and say nothing about the second), is UNMEASURED and fails the run — a rule whose
 *    mutation cannot be planted has no guard, and must say so.
 *  - `equivalent` needs a written reason, and if the suite CATCHES a mutation marked equivalent
 *    the marker is an error: otherwise the list rots into excuses for holes that got closed.
 *  - `--slice i/n` takes every n-th entry (interleaved, because lists are grouped by file and a
 *    block would collect the expensive files together). A suite of minutes times hundreds of
 *    entries does not fit a background task's ceiling; n slices together cover each entry once.
 *  - The report's arithmetic closes in every outcome: `N mutations: X caught, Y equivalent,
 *    Z survived, W not measured` is printed before any exit.
 *
 * The verdict (`.git/proofgate-mutation.json`) is bound to the list's hash and to the hash of
 * every file the list mutates — not to HEAD. A commit elsewhere does not invalidate it; a change
 * to a mutated file, or to the list, does. `--status` reads it; the `88-mutation` guard calls it.
 *
 * Exit: 0 = every mutation caught (equivalents allowed) · 1 = survivors / unmeasured / wrong
 * marker / stale anchor · 2 = usage error, red baseline, broken judge.
 */

import { spawnSync } from "node:child_process";
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";

const argv = process.argv.slice(2);
const flag = (name) => {
  const i = argv.indexOf(name);
  return i === -1 ? null : (argv[i + 1] ?? "");
};
const has = (name) => argv.includes(name);
const fail = (msg, code = 2) => {
  console.error(msg);
  process.exit(code);
};

const sep = argv.indexOf("--");
const command = sep === -1 ? [] : argv.slice(sep + 1);
const listPath = flag("--list");
if (!listPath) fail("usage: mutate.mjs --list <file.jsonl> (--check | --status | [--slice i/n] -- <suite command...>)");

const ROOT = process.cwd();
const git = (args) => spawnSync("git", args, { cwd: ROOT, encoding: "utf8" });
const blob = (path) => {
  const r = git(["hash-object", "--", path]);
  return r.status === 0 ? r.stdout.trim() : "missing";
};
const gitDir = () => {
  const r = git(["rev-parse", "--git-dir"]);
  return r.status === 0 ? resolve(ROOT, r.stdout.trim()) : ROOT;
};
const VERDICT = flag("--verdict") ?? join(gitDir(), "proofgate-mutation.json");

// ── the list ──────────────────────────────────────────────────────────────────
function readList(path) {
  let text;
  try {
    text = readFileSync(path, "utf8");
  } catch (e) {
    fail(`cannot read the mutation list ${path}: ${e.message}`);
  }
  const out = [];
  text.split("\n").forEach((raw, i) => {
    const line = raw.trim();
    if (line === "" || line.startsWith("//")) return;
    let m;
    try {
      m = JSON.parse(line);
    } catch {
      fail(`${path}:${i + 1} is not valid JSON: ${line.slice(0, 80)}`);
    }
    for (const k of ["file", "from", "to", "hurts"]) {
      if (typeof m[k] !== "string" || m[k] === "") fail(`${path}:${i + 1} needs a non-empty string "${k}"`);
    }
    if (m.from === m.to) fail(`${path}:${i + 1} "from" and "to" are identical — that plants nothing`);
    if (m.equivalent !== undefined && (typeof m.equivalent !== "string" || m.equivalent.trim() === "")) {
      fail(`${path}:${i + 1} "equivalent" needs a written reason — an unexplained marker is an excuse`);
    }
    out.push({ ...m, name: m.name || m.hurts, line: i + 1 });
  });
  if (out.length === 0) fail(`${path}: no mutations — silence is NOT green`);
  return out;
}

/** ok | obsolete (file or text gone) | ambiguous (more than once) */
function anchor(m, root = ROOT) {
  const p = join(root, m.file);
  if (!existsSync(p)) return { state: "obsolete", hits: 0 };
  const hits = readFileSync(p, "utf8").split(m.from).length - 1;
  return { state: hits === 0 ? "obsolete" : hits > 1 ? "ambiguous" : "ok", hits };
}

const entries = readList(listPath);
const listSha = blob(listPath);
const sourcesNow = () => Object.fromEntries([...new Set(entries.map((m) => m.file))].sort().map((f) => [f, blob(f)]));

// ── --check ───────────────────────────────────────────────────────────────────
if (has("--check")) {
  const bad = entries.map((m) => ({ m, a: anchor(m) })).filter(({ a }) => a.state !== "ok");
  for (const { m, a } of bad) {
    console.error(
      `${listPath}:${m.line} [${m.name}] ${a.state === "ambiguous" ? `"from" occurs ${a.hits}× in ${m.file} (must be exactly 1)` : `"from" no longer occurs in ${m.file} — the code moved`}`,
    );
  }
  if (bad.length > 0) {
    console.error(`${bad.length}/${entries.length} mutation(s) cannot be planted — the rule each protects has NO guard until the anchor is fixed.`);
    process.exit(1);
  }
  console.log(`${entries.length} mutation(s): every anchor occurs exactly once`);
  process.exit(0);
}

// ── verdict ───────────────────────────────────────────────────────────────────
function readVerdict() {
  try {
    return JSON.parse(readFileSync(VERDICT, "utf8"));
  } catch {
    return null;
  }
}

/** The slices of one complete partition (every i/n for some n), or null. */
function completePartition(v) {
  const keys = Object.keys(v.slices ?? {});
  for (const n of new Set(keys.map((k) => Number(k.split("/")[1])))) {
    const got = Array.from({ length: n }, (_, i) => `${i + 1}/${n}`);
    if (got.every((k) => k in v.slices)) return got.map((k) => ({ key: k, ...v.slices[k] }));
  }
  return null;
}

// ── --status ──────────────────────────────────────────────────────────────────
if (has("--status")) {
  const maxAge = Number(flag("--max-age-days") ?? 14);
  const v = readVerdict();
  const say = (code, text) => {
    console.log(`${code === 0 ? "✅" : "⚠️ "} mutation: ${text}`);
    process.exit(code);
  };
  if (!v) say(2, `no verdict yet for ${entries.length} mutation(s) — run: node mutate.mjs --list ${listPath} -- <your suite>`);
  if (v.list_sha !== listSha) say(2, "the list changed since the last verdict — it judged a different list; re-run");
  const now = sourcesNow();
  const moved = Object.keys(now).filter((f) => v.sources?.[f] !== now[f]);
  if (moved.length > 0) say(2, `${moved.length} mutated file(s) changed since the last verdict (${moved.slice(0, 4).join(", ")}) — re-run`);
  const part = completePartition(v);
  if (!part) say(2, `the last verdict is incomplete — slices present: ${Object.keys(v.slices ?? {}).join(", ")}; run the rest`);
  const bad = part.reduce((s, p) => s + p.survived + p.unmeasured + p.wrong_marker, 0);
  if (bad > 0) say(2, `the last verdict has ${bad} survivor/unmeasured mutation(s) — a rule the suite claims to cover and does not`);
  const oldest = Math.min(...part.map((p) => Date.parse(p.ts)));
  const age = Math.floor((Date.now() - oldest) / 86400000);
  if (!(age <= maxAge)) say(2, `the last verdict is ${age} day(s) old (limit ${maxAge}) — the suite may have drifted; re-run`);
  const total = part.reduce((s, p) => s + p.total, 0);
  say(0, `${total} mutation(s) caught or equivalent, verdict ${age}d old, covering every mutated file as it is now`);
}

// ── the run ───────────────────────────────────────────────────────────────────
if (command.length === 0) fail("no suite command: add `-- <your test command>` (or use --check / --status)");

let slice = null;
const sliceArg = flag("--slice");
if (sliceArg !== null) {
  const c = /^(\d+)\/(\d+)$/.exec(sliceArg);
  if (!c || Number(c[2]) < 1 || Number(c[1]) < 1 || Number(c[1]) > Number(c[2])) {
    // A malformed slice that fell back to the whole list would blow the ceiling in silence;
    // one that fell to an empty list would say "all caught" having judged nothing.
    fail(`--slice needs "i/n" with 1 <= i <= n, like 2/3; got "${sliceArg}"`);
  }
  slice = { i: Number(c[1]), n: Number(c[2]) };
}
const mine = slice ? entries.filter((_, idx) => idx % slice.n === slice.i - 1) : entries;
if (mine.length === 0) fail(`slice ${sliceArg} holds no mutation of the ${entries.length} in the list`);

const TIMEOUT_MS = Number(flag("--timeout") ?? 600) * 1000;

/** The suite, read as three outcomes. 126/127 are "could not execute", not "a test failed". */
function measure(dir) {
  const r = spawnSync(command[0], command.slice(1), {
    cwd: dir,
    encoding: "utf8",
    stdio: "pipe",
    timeout: TIMEOUT_MS,
    killSignal: "SIGKILL",
    env: { ...process.env, MUTATE_WORKSHOP: "1" },
    maxBuffer: 256 * 1024 * 1024,
  });
  if (r.error || r.status === null || r.status === 126 || r.status === 127) return "unmeasured";
  return r.status === 0 ? "passed" : "failed";
}
const measureTwice = (dir) => {
  const first = measure(dir);
  return first === "unmeasured" ? measure(dir) : first; // a measure that did not happen is cheap to repeat; one that finished is not
};

// The workshop: tracked + untracked-but-not-ignored files, node_modules linked not copied.
const WORK = mkdtempSync(join(tmpdir(), "proofgate-mutate-"));
process.on("exit", () => rmSync(WORK, { recursive: true, force: true }));
const listed = git(["ls-files", "-z", "--cached", "--others", "--exclude-standard"]);
if (listed.status !== 0) fail("mutate --list needs a git repository (the workshop is a copy of its files)");
for (const rel of listed.stdout.split("\0").filter(Boolean)) {
  const from = join(ROOT, rel);
  if (!existsSync(from)) continue; // tracked but deleted in the working tree
  mkdirSync(dirname(join(WORK, rel)), { recursive: true });
  cpSync(from, join(WORK, rel));
}
if (existsSync(join(ROOT, "node_modules"))) symlinkSync(join(ROOT, "node_modules"), join(WORK, "node_modules"), "dir");

process.stdout.write("workshop baseline… ");
if (measureTwice(WORK) !== "passed") {
  fail(
    "NOT GREEN — the suite does not pass in the workshop with no mutation applied.\n" +
      "Until it does, every planted defect would read as \"caught\" without the suite having been asked.\n" +
      "Usual cause: a test reads a file the copy does not carry (gitignored build output, .env, a fixture).",
  );
}
console.log("green");
process.stdout.write("workshop sentinel (a harmless trailing newline)… ");
{
  const probe = join(WORK, mine[0].file);
  if (existsSync(probe)) {
    const keep = readFileSync(probe, "utf8");
    writeFileSync(probe, keep + "\n");
    const s = measureTwice(WORK);
    writeFileSync(probe, keep);
    if (s !== "passed") fail("BROKEN JUDGE — a change that cannot matter failed the suite; everything would read as caught.");
  }
}
console.log("survived, as it must\n");

// ── judge ─────────────────────────────────────────────────────────────────────
const tally = { caught: 0, equivalent: 0, survived: 0, unmeasured: 0, wrong_marker: 0 };
const notes = [];
for (const m of mine) {
  const a = anchor(m);
  if (a.state !== "ok") {
    tally.unmeasured += 1;
    notes.push(`?  ${m.file}:${m.line} [${m.name}] ${a.state === "ambiguous" ? `"from" occurs ${a.hits}× — give it context until it is unique` : `"from" no longer occurs — update this mutation`}\n   ${m.hurts}`);
    continue;
  }
  const target = join(WORK, m.file);
  const original = readFileSync(join(ROOT, m.file), "utf8");
  writeFileSync(target, original.replace(m.from, () => m.to));
  const outcome = measureTwice(WORK);
  writeFileSync(target, original);

  if (outcome === "unmeasured") {
    tally.unmeasured += 1;
    notes.push(`NOT MEASURED  ${m.file}:${m.line} [${m.name}]\n   the suite did not finish twice (timeout, killed, command not found) — neither protection nor a hole; run again with the machine free\n   ${m.hurts}`);
  } else if (m.equivalent) {
    if (outcome === "failed") {
      tally.wrong_marker += 1;
      notes.push(`WRONG MARKER  ${m.file}:${m.line} [${m.name}]\n   marked equivalent ("${m.equivalent}") and the suite CAUGHT it — drop the marker, the rule gained a test`);
    } else tally.equivalent += 1;
  } else if (outcome === "failed") {
    tally.caught += 1;
  } else {
    tally.survived += 1;
    notes.push(`SURVIVED  ${m.file}:${m.line} [${m.name}]\n   ${m.from.slice(0, 90)}  →  ${m.to.slice(0, 90)}\n   and nobody notices: ${m.hurts}`);
  }
}

for (const n of notes) console.log(n + "\n");
// The arithmetic closes in every outcome, before any exit: a report whose lines do not add up
// sends people hunting for a verdict that was never produced.
console.log(
  `${mine.length} mutation(s)${slice ? ` (slice ${slice.i}/${slice.n} of ${entries.length})` : ""}: ` +
    `${tally.caught} caught, ${tally.equivalent} equivalent, ${tally.survived} survived, ` +
    `${tally.unmeasured} not measured${tally.wrong_marker ? `, ${tally.wrong_marker} wrong marker` : ""}.`,
);

// Record the verdict, merged with earlier slices of THE SAME list over THE SAME sources.
const sources = sourcesNow();
let v = readVerdict();
if (!v || v.list_sha !== listSha || JSON.stringify(v.sources) !== JSON.stringify(sources)) v = { list_sha: listSha, sources, slices: {} };
v.slices[`${slice ? slice.i : 1}/${slice ? slice.n : 1}`] = { ts: new Date().toISOString(), total: mine.length, ...tally };
try {
  writeFileSync(VERDICT, JSON.stringify(v, null, 1) + "\n");
} catch (e) {
  console.error(`could not record the verdict at ${VERDICT}: ${e.message}`);
}

const bad = tally.survived + tally.unmeasured + tally.wrong_marker;
if (bad > 0) {
  if (tally.survived > 0) console.log("\nGreen does not mean protected: the examples never exercise that rule.");
  if (tally.unmeasured > 0) console.log("Unmeasured is news about the list or the machine, not the suite — and until fixed, that rule has no guard.");
  process.exit(1);
}
console.log("Every planted defect was caught (equivalents aside, each with its reason).");
process.exit(0);
