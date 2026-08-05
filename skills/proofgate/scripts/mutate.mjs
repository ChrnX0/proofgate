#!/usr/bin/env node
/**
 * mutate — mutation as proof of test.
 *
 * A green suite proves the code passes the tests. It does NOT prove the tests
 * would catch the code being wrong. The only proof of that is to break the code
 * on purpose and check that the suite screams. A mutation that SURVIVES is a
 * test that cannot see.
 *
 * ProofGate 2.4.0 added this as a judgment-layer rule ("break the line the test
 * is supposed to protect"). This is the same rule with a runner, because the
 * discipline kept being skipped for the reason disciplines always are: doing it
 * by hand is fiddly, and a hand-rolled loop that silently does nothing looks
 * exactly like a hand-rolled loop that found nothing.
 *
 * So this one FAILS LOUD. Empty input is exit 2, not success. A baseline that is
 * already red is exit 2, not "everything died". A search string that is not
 * unique is exit 2, not a silent wrong-place edit. Survivors are exit 1 with a
 * list. The only exit 0 is "every mutation was caught".
 *
 * Usage:
 *   node mutate.mjs <source-file> -- <test command...> < mutations.jsonl
 *
 * Examples:
 *   node mutate.mjs src/pricing.ts -- npx vitest run src/pricing.test.ts < m.jsonl
 *   node mutate.mjs app/rules.py -- pytest tests/test_rules.py < m.jsonl
 *   node mutate.mjs internal/auth.go -- go test ./internal/... < m.jsonl
 *
 * Each stdin line is one JSON object; blank lines and `//` lines are ignored:
 *   {"name": "floor removed", "from": "Math.max(1, n)", "to": "n"}
 *
 * `from` must be a LITERAL substring occurring exactly once in the source. That
 * constraint is deliberate: a regex that matches in two places edits the wrong
 * one and reports a confident, meaningless result.
 *
 * The source file is always restored, including on crash or Ctrl-C.
 */

import { spawnSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";

const argv = process.argv.slice(2);
const sep = argv.indexOf("--");
const sourceArg = argv[0];
const command = sep === -1 ? [] : argv.slice(sep + 1);

if (!sourceArg || sourceArg === "--" || command.length === 0) {
  console.error("usage: node mutate.mjs <source-file> -- <test command...> < mutations.jsonl");
  process.exit(2);
}

const source = resolve(sourceArg);
let original;
try {
  original = readFileSync(source, "utf8");
} catch (e) {
  console.error(`cannot read ${sourceArg}: ${e.message}`);
  process.exit(2);
}

const mutations = readFileSync(0, "utf8")
  .split("\n")
  .map((l) => l.trim())
  .filter((l) => l.length > 0 && !l.startsWith("//"))
  .map((line, i) => {
    let parsed;
    try {
      parsed = JSON.parse(line);
    } catch {
      console.error(`stdin line ${i + 1} is not valid JSON: ${line.slice(0, 80)}`);
      process.exit(2);
    }
    if (typeof parsed.from !== "string" || typeof parsed.to !== "string") {
      console.error(`stdin line ${i + 1} needs string "from" and "to"`);
      process.exit(2);
    }
    return { name: parsed.name || `mutation ${i + 1}`, from: parsed.from, to: parsed.to };
  });

// Silence is the failure mode this tool exists to remove: a run that mutated
// nothing must never look like a run where nothing survived.
if (mutations.length === 0) {
  console.error("no mutations read from stdin — silence is NOT green");
  process.exit(2);
}

/** Restore the file no matter how we leave. */
const restore = () => {
  try {
    writeFileSync(source, original);
  } catch {
    /* nothing sensible left to do while unwinding */
  }
};
process.on("exit", restore);
for (const sig of ["SIGINT", "SIGTERM"]) {
  process.on(sig, () => {
    restore();
    process.exit(130);
  });
}

/** Runs the suite. True = PASSED. */
function suitePasses() {
  const r = spawnSync(command[0], command.slice(1), { stdio: "pipe", encoding: "utf8" });
  if (r.error) {
    console.error(`\ncannot run test command (${command[0]}): ${r.error.message}`);
    process.exit(2);
  }
  return r.status === 0;
}

// Sanity gate. Without a green baseline, "killed" might just be the suite being
// broken for an unrelated reason — and then the whole report is a lie.
process.stdout.write("baseline… ");
if (!suitePasses()) {
  console.error("FAILED — the suite is already red with no mutation applied. Fix that first.");
  process.exit(2);
}
console.log("green");

const survivors = [];
for (const m of mutations) {
  const hits = original.split(m.from).length - 1;
  if (hits !== 1) {
    console.error(`\n[${m.name}] "from" occurs ${hits}× in the source (must be exactly 1)`);
    process.exit(2);
  }
  writeFileSync(source, original.replace(m.from, m.to));
  const survived = suitePasses();
  console.log(`${survived ? "SURVIVED" : "killed  "}  ${m.name}`);
  if (survived) survivors.push(m.name);
}
restore();

console.log(`\n${mutations.length - survivors.length}/${mutations.length} killed.`);
if (survivors.length > 0) {
  console.error("\nBLIND TESTS — these mutations went unnoticed:");
  for (const n of survivors) console.error(`  - ${n}`);
  console.error("\nEach one is a rule your suite claims to cover and does not.");
  process.exit(1);
}
