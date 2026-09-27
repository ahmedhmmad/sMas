// F1.8 — E2E المتصفح على الحزمة المحلية الحقيقية: Supabase (يعمل مسبقاً) + FastAPI (uvicorn) + بناء Vite.
// صندوق OTP ملف خارج apps/web (.e2e/، خارج Git) — لا مسار HTTP يقرؤه؛ يُنظَّف في global-setup.
import { defineConfig, devices } from "@playwright/test";
import { execSync } from "node:child_process";
import { resolve } from "node:path";

export const ROOT = resolve(import.meta.dirname, "../..");
export const E2E_DIR = resolve(ROOT, ".e2e");
const WEB = "http://localhost:4173";
const API = "http://127.0.0.1:8000";

function supabaseStatus(): Record<string, string> {
  const out = execSync("npx supabase status -o env", { cwd: ROOT, encoding: "utf-8", stdio: ["ignore", "pipe", "ignore"] });
  return Object.fromEntries(
    out.split(/\r?\n/).filter((l) => l.includes("=")).map((l) => {
      const i = l.indexOf("=");
      return [l.slice(0, i).trim(), l.slice(i + 1).trim().replace(/^"|"$/g, "")];
    }),
  );
}

const s = supabaseStatus();
const python = process.env.E2E_PYTHON
  ?? resolve(ROOT, "services/api/.venv", process.platform === "win32" ? "Scripts/python.exe" : "bin/python");

export default defineConfig({
  testDir: "e2e",
  testMatch: /.*\.spec\.ts/,
  workers: 1,
  fullyParallel: false,
  timeout: 60_000,
  globalSetup: "./e2e/global-setup.ts",
  reporter: [["list"]],
  use: { baseURL: WEB, locale: "ar-EG", trace: "retain-on-failure" },
  // محلياً يمكن استعمال متصفح النظام (E2E_BROWSER_CHANNEL=msedge|chrome)؛ CI يثبّت Chromium الخاص بـPlaywright
  projects: [{ name: "chromium", use: { ...devices["Desktop Chrome"], channel: process.env.E2E_BROWSER_CHANNEL || undefined } }],
  webServer: [
    {
      command: `"${python}" -m uvicorn app.main:app --host 127.0.0.1 --port 8000`,
      cwd: resolve(ROOT, "services/api"),
      url: `${API}/health`,
      timeout: 60_000,
      env: {
        ...process.env as Record<string, string>,
        SUPABASE_URL: s.API_URL,
        API_DATABASE_URL: s.DB_URL.replace("://postgres:", "://authenticator:"),
        SUPABASE_PUBLISHABLE_KEY: s.PUBLISHABLE_KEY,
        SUPABASE_SECRET_KEY: s.SECRET_KEY,
        API_CORS_ORIGINS: WEB,
        API_OTP_SENDER: `file:${resolve(E2E_DIR, "otp.jsonl")}`,
        API_LOGIN_ATTEMPTS: "1000",                                // كل دخول E2E من 127.0.0.1
      },
    },
    {
      command: "npm run build && npm run preview",
      url: WEB,
      timeout: 120_000,
      env: {
        ...process.env as Record<string, string>,
        VITE_SUPABASE_URL: s.API_URL,
        VITE_SUPABASE_PUBLISHABLE_KEY: s.PUBLISHABLE_KEY,
        VITE_API_URL: API,
        VITE_DEV_CONTEXT: "1",                      // W2: بناء اختبار — الأداة مسموحة بتصريح صريح
        SMAS_BUILD_TARGET: "development",
      },
    },
  ],
});
