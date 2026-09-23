// مشغّل M00: كل ملف V داخل BEGIN ... ROLLBACK، ثم Saga V8.
// المخرجات الخام (TAP + الدليل) في spikes/m00/out/ — مستثناة من git.
import { readFileSync, readdirSync, mkdirSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";

const here = new URL(".", import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, "$1");
const DB_CONTAINER = process.env.M00_DB_CONTAINER ?? "supabase_db_SMas";
mkdirSync(`${here}/out`, { recursive: true });

const read = (f) => readFileSync(`${here}/${f}`, "utf8");
const files = readdirSync(here).filter((f) => /^v[1-7]_.*\.sql$/.test(f)).sort();
let failed = 0;

for (const f of files) {
  const r = spawnSync("docker", ["exec", "-i", DB_CONTAINER, "psql", "-U", "postgres", "-d", "postgres", "-X", "-q"],
    { input: [read("00_harness.sql"), read(f), read("99_report.sql")].join("\n"), encoding: "utf8" });
  const out = r.stdout + (r.stderr ? `\n# STDERR\n${r.stderr}` : "");
  writeFileSync(`${here}/out/${f.replace(".sql", ".tap")}`, out);
  const notOk = (out.match(/^not ok/gm) ?? []).length;
  const ok = (out.match(/^ok/gm) ?? []).length;
  const bad = r.status !== 0 || notOk > 0 || ok === 0;
  if (bad) failed++;
  console.log(`${bad ? "✗" : "✓"} ${f}  ok=${ok} not_ok=${notOk}${r.status !== 0 ? ` exit=${r.status}` : ""}`);
}

const v8 = spawnSync("node", [`${here}/v8_saga.mjs`], { encoding: "utf8" });
writeFileSync(`${here}/out/v8_saga.tap`, v8.stdout + (v8.stderr ? `\n# STDERR\n${v8.stderr}` : ""));
const v8NotOk = (v8.stdout.match(/^not ok/gm) ?? []).length;
if (v8.status !== 0 || v8NotOk > 0) failed++;
console.log(`${v8.status === 0 && v8NotOk === 0 ? "✓" : "✗"} v8_saga  not_ok=${v8NotOk} exit=${v8.status}`);

console.log(failed ? `\nM00: ${failed} ملف فشل — انظر spikes/m00/out/` : "\nM00: كل التحققات نجحت");
process.exit(failed ? 1 : 0);
