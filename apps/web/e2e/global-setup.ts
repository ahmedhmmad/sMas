// تنظيف صندوق OTP وإنشاء بيانات E2E بالمسارات الحقيقية (services/api/tests/web_e2e_fixtures.py).
import { execFileSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";

const ROOT = resolve(import.meta.dirname, "../../..");
const E2E_DIR = resolve(ROOT, ".e2e");

export default function globalSetup(): void {
  mkdirSync(E2E_DIR, { recursive: true });
  writeFileSync(resolve(E2E_DIR, "otp.jsonl"), "");
  const python = process.env.E2E_PYTHON
    ?? resolve(ROOT, "services/api/.venv", process.platform === "win32" ? "Scripts/python.exe" : "bin/python");
  execFileSync(python, ["tests/web_e2e_fixtures.py", resolve(E2E_DIR, "fixtures.json")], {
    cwd: resolve(ROOT, "services/api"), stdio: "inherit",
  });
}
