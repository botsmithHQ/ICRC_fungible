// Reads the vitest JSON report of pic/icrc85-counterproof.sh (the ICRC-85 "off"
// guards run against ledgers built with ICRC-85 ON) and passes only if every
// guard went red ON ITS ICRC-85 ASSERTION.
//
// A guard that passes against a sharing ledger proves nothing, so it fails the
// check. So does a guard that fails for another reason (a missing wasm, a
// trap in setup, a timeout): that red is not the counterproof. A guard that
// was renamed or removed, and any test in these files whose title reads like
// a new guard but is not listed here, also fail it: the list must be updated
// on purpose.
//
// Usage: node pic/icrc85-counterproof-check.mjs <vitest-report.json>
import { readFileSync } from 'node:fs';
import { basename } from 'node:path';

// `expectNoGrowth` in icrc85_off*.test.ts: "<what>: stream <ns> sent cycles: expected N to be M".
const SENT_CYCLES = /^AssertionError: .*stream .* sent cycles: expected \d+ to be \+?\d+/;
// timertool_upgrade.test.ts: the collector streams that end in "@ <ledger id>" must be [].
const LEDGER_STREAMS = /^AssertionError: expected \[ .*org\.icdevs\.icrc85.* \] to deeply equal \[\]/;

const GUARDS = [
  ['icrc85_off.test.ts', 'a fresh ledger sends nothing, on any stream', SENT_CYCLES],
  ['icrc85_off.test.ts', 'a share queued by the baseline sends nothing after the upgrade', SENT_CYCLES],
  ['icrc85_off.test.ts', 'new archives send nothing, the first and the next', SENT_CYCLES],
  ['icrc85_off.test.ts', 'an archive created by the baseline pays until upgradeArchive, then stops and keeps its blocks', SENT_CYCLES],
  ['icrc85_off.test.ts', 'an archive created with the switch null stops after upgradeArchiveWith(?true): true wins', SENT_CYCLES],
  ['icrc85_off_mixin.test.ts', 'a fresh ledger sends nothing, on any stream', SENT_CYCLES],
  ['icrc85_off_mixin.test.ts', 'a share queued by the paying mixin sends nothing after the upgrade', SENT_CYCLES],
  ['icrc85_off_mixin.test.ts', 'new archives send nothing, the first and the next', SENT_CYCLES],
  ['timertool_upgrade.test.ts', 'ICRC-85 stays off: after the re-arm, the queued share actions pay nothing', LEDGER_STREAMS],
];
// Titles that read like a guard. Every match must be in GUARDS.
const LOOKS_LIKE_GUARD = /sends? nothing|pays? nothing|stays off|icrc-?85.*off/i;

const report = JSON.parse(readFileSync(process.argv[2], 'utf8'));
const results = new Map();
for (const file of report.testResults) {
  const name = basename(file.name);
  if (file.status === 'failed' && file.assertionResults.length === 0) {
    console.error(`::error::${name} did not run: ${file.message.split('\n')[0]}`);
  }
  for (const t of file.assertionResults) results.set(`${name} | ${t.title}`, { name, ...t });
}

let ok = true;
const fail = (msg) => { ok = false; console.error(`::error::${msg}`); };

for (const [file, title, expected] of GUARDS) {
  const key = `${file} | ${title}`;
  const t = results.get(key);
  if (!t) { fail(`guard not found (renamed? removed? file not run?): ${key}`); continue; }
  const first = (t.failureMessages[0] ?? '').split('\n')[0];
  if (t.status === 'passed') fail(`guard PASSED against an ICRC-85-on ledger: ${key}`);
  else if (t.status !== 'failed') fail(`guard did not run (${t.status}): ${key}`);
  else if (!expected.test(first)) fail(`guard red for the wrong reason: ${key}\n    ${first}`);
  else console.log(`RED as expected  ${key}\n    ${first}`);
}

const listed = new Set(GUARDS.map(([f, t]) => `${f} | ${t}`));
const filesRun = new Set(GUARDS.map(([f]) => f));
for (const [key, t] of results) {
  if (listed.has(key) || !filesRun.has(t.name)) continue;
  if (LOOKS_LIKE_GUARD.test(t.title)) fail(`test looks like an ICRC-85 guard but is not in GUARDS: ${key}`);
  else console.log(`(not a guard, ${t.status})  ${key}`);
}

console.log(ok ? `\nICRC-85 counterproof OK: ${GUARDS.length} guards red on their ICRC-85 assertion.` : '\nICRC-85 counterproof FAILED.');
process.exit(ok ? 0 : 1);
