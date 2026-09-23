// V8 — Saga إنشاء حساب الطالب كما سيعمل FastAPI (DB_IMPLEMENTATION_SPEC_v1.md §5.4)
//   1. معرّف مولَّد مسبقاً (idempotency key)
//   2. Auth user عبر Admin API — خارج معاملة DB
//   3. دالة DB متحكَّم بها بـJWT المستدعي (v8_provisioning.sql)
//   4. فشل ← حذف تعويضي لـAuth user
// مفتاح service_role يُقرأ من `supabase status` ويبقى في الذاكرة فقط — لا يُطبع ولا يُكتب.
import { execSync, spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { randomUUID, randomBytes } from "node:crypto";

const here = new URL(".", import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, "$1");
const status = JSON.parse(execSync("npx supabase status -o json", { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }));
const API = status.API_URL;
const KEY = status.SERVICE_ROLE_KEY;
const DB_CONTAINER = process.env.M00_DB_CONTAINER ?? "supabase_db_SMas";

const results = [];
const record = (k, v) => { results.push([k, v]); console.log(`# ${k} = ${v}`); };
const tap = [];
const check = (ok, desc) => tap.push(`${ok ? "ok" : "not ok"} ${tap.length + 1} - ${desc}`);

async function admin(method, path, body) {
  const res = await fetch(`${API}/auth/v1/admin${path}`, {
    method,
    headers: { apikey: KEY, Authorization: `Bearer ${KEY}`, "Content-Type": "application/json" },
    body: body ? JSON.stringify(body) : undefined,
  });
  let json = null;
  try { json = await res.json(); } catch { /* 204 */ }
  return { status: res.status, json };
}

const studentId = randomUUID();
const newUser = (id) => ({
  id,
  email: `s-${id}@students.invalid`,     // معرّف Auth حتمي مشتق من المعرّف المولَّد مسبقاً
  password: randomBytes(18).toString("base64url"),
  email_confirm: true,
});

// (2) إنشاء Auth user بالمعرّف المولَّد مسبقاً
const created = await admin("POST", "/users", newUser(studentId));
record("V8e.create_status", created.status);
record("V8e.id_honored", created.json?.id === studentId);
const auth1 = created.json?.id;

// إعادة المحاولة بنفس المعرّف: هل تُكتشف ويُسترجع الحساب القائم؟
const retry = await admin("POST", "/users", newUser(studentId));
record("V8e.retry_status", retry.status);
record("V8e.retry_error_code", retry.json?.error_code ?? retry.json?.code ?? retry.json?.msg ?? "<none>");
const lookup = await admin("GET", `/users/${studentId}`);
record("V8e.lookup_by_id_status", lookup.status);

// حساب ثانٍ للمسار الفاشل
const auth2Id = randomUUID();
const created2 = await admin("POST", "/users", newUser(auth2Id));
const auth2 = created2.json?.id;
const caller = randomUUID();

// (3) جزء DB — داخل BEGIN ... ROLLBACK
const sql = ["00_harness.sql", "v8_provisioning.sql", "99_report.sql"]
  .map((f) => readFileSync(`${here}/${f}`, "utf8")).join("\n");
const q = (v) => `'${v}'`;
const psql = spawnSync("docker", [
  "exec", "-i", DB_CONTAINER, "psql", "-U", "postgres", "-d", "postgres", "-X", "-q",
  "-v", `student_id=${q(studentId)}`, "-v", `auth1=${q(auth1)}`,
  "-v", `auth2=${q(auth2)}`, "-v", `caller=${q(caller)}`,
], { input: sql, encoding: "utf8" });
process.stdout.write(psql.stdout);
if (psql.status !== 0) process.stderr.write(psql.stderr);

// (4) تعويض: حذف Auth user الخاص بالمسار الفاشل
const del = await admin("DELETE", `/users/${auth2}`);
record("V8f.compensating_delete_status", del.status);
const gone = await admin("GET", `/users/${auth2}`);
record("V8f.after_delete_lookup_status", gone.status);

// تنظيف الحساب الناجح (قاعدة البيانات أُلغيت بالـrollback)
await admin("DELETE", `/users/${auth1}`);

check(created.status === 200 && created.json?.id === studentId, "V8e: Admin API accepts a pre-generated id (deterministic identity)");
check(retry.status >= 400 && retry.status < 500, "V8e: retry with the same id is rejected, not duplicated");
check(lookup.status === 200, "V8e: existing account is retrievable by the same id (retry can resume)");
check(del.status === 200 && gone.status === 404, "V8f: compensating delete removes the Auth user");
check(psql.status === 0, "V8: DB part executed");
console.log(`1..${tap.length}\n${tap.join("\n")}`);
process.exit(tap.some((l) => l.startsWith("not ok")) ? 1 : 0);
