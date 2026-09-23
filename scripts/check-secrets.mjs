// فحص أسرار بلا dependency: يمرّ على الملفات المتتبَّعة في git ويفشل عند أول سر.
// PLAN_v3.md §3.3 بند 12: service_role لا يصل للعميل ولا أسرار داخل المستودع.
import { execSync } from "node:child_process";
import { readFileSync } from "node:fs";

const files = execSync("git ls-files -z --cached --others --exclude-standard", { encoding: "utf8" })
  .split("\0")
  .filter(Boolean);

const findings = [];

for (const file of files) {
  if (/(^|\/)\.env($|\.)/.test(file) && !file.endsWith(".env.example")) {
    findings.push(`${file}: ملف .env متتبَّع`);
    continue;
  }

  let text;
  try {
    text = readFileSync(file, "utf8");
  } catch {
    continue;
  }

  if (/-----BEGIN [A-Z ]*PRIVATE KEY-----/.test(text)) {
    findings.push(`${file}: مفتاح خاص`);
  }

  if (/SUPABASE_SERVICE_ROLE_KEY\s*=\s*\S+/.test(text) && !file.endsWith(".env.example")) {
    findings.push(`${file}: قيمة SUPABASE_SERVICE_ROLE_KEY`);
  }

  // JWT يحمل role=service_role في الـpayload
  for (const [, payload] of text.matchAll(/eyJ[\w-]+\.(eyJ[\w-]+)\.[\w-]+/g)) {
    try {
      const claims = JSON.parse(Buffer.from(payload, "base64url").toString("utf8"));
      if (claims.role === "service_role") findings.push(`${file}: JWT بدور service_role`);
    } catch {
      // ليس JWT صالحاً
    }
  }
}

if (findings.length) {
  console.error("✗ أسرار في المستودع:\n  " + findings.join("\n  "));
  process.exit(1);
}
console.log(`✓ لا أسرار (${files.length} ملفاً)`);
