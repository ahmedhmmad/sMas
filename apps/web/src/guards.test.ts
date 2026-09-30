// حراس F1 الساكنة: اكتمال فهرس الترجمة، قاعدة النصوص، وقيد السياق (school_id ليس مدخل صلاحية).
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative } from "node:path";
import { RuleTester } from "eslint";
import tsParser from "@typescript-eslint/parser";
import { describe, expect, it } from "vitest";
import noUiLiterals from "../eslint-rules/no-ui-literals.js";
import { catalogKeys, lookup } from "./i18n";

const SRC = join(__dirname);

function sources(dir = SRC): string[] {
  return readdirSync(dir).flatMap((name) => {
    const full = join(dir, name);
    if (statSync(full).isDirectory()) return sources(full);
    return /\.(ts|tsx)$/.test(name) && !/\.test\.tsx?$/.test(name) ? [full] : [];
  });
}

describe("i18n catalog", () => {
  it("every key used in the code exists in the catalog", () => {
    const used = new Set<string>();
    const patterns = [/\bt\("([\w.]+)"\)/g, /labelKey[=:]\s*"([\w.]+)"/g, /textKey="([\w.]+)"/g];
    for (const file of sources()) {
      const text = readFileSync(file, "utf-8");
      for (const re of patterns) for (const m of text.matchAll(re)) used.add(m[1]);
    }
    expect(used.size).toBeGreaterThan(20);
    const missing = [...used].filter((k) => lookup(k) === undefined);
    expect(missing).toEqual([]);
  });

  it("the catalog has no empty messages", () => {
    expect(catalogKeys().filter((k) => !lookup(k)?.trim())).toEqual([]);
  });
});

describe("context is display/login only (F1 constraint 2; F3)", () => {
  // F3: العرض (ContextLabel)، واختيار النموذج (App، Login، AdminLogin) — لا طلب يحمل السياق
  const ALLOWED = ["App.tsx", "components/ContextLabel.tsx", "pages/Login.tsx", "pages/AdminLogin.tsx", "context/appContext.ts"];
  const READS = /getSchoolContext|getTenantContext|getHostContext|parseHost/;

  it("only the display component and the login choice read the context", () => {
    const readers = sources()
      .filter((f) => READS.test(readFileSync(f, "utf-8")) && !f.endsWith("hostContext.ts"))
      .map((f) => relative(SRC, f).replaceAll("\\", "/"));
    expect(readers.sort()).toEqual(ALLOWED.sort());
  });

  it("login requests carry no tenant or school (F3: the browser's Origin is the context)", () => {
    const flows = readFileSync(join(SRC, "auth/loginFlows.ts"), "utf-8");
    expect(flows).not.toMatch(READS);
    const bodies = [...flows.matchAll(/body:\s*\{([^}]*)\}/g)].map((m) => m[1]);
    expect(bodies.length).toBeGreaterThanOrEqual(5);
    expect(bodies.filter((b) => /\b(tenant|school)\w*\s*:/.test(b))).toEqual([]);
  });

  it("no development context override remains (F3 replaced it)", () => {
    const config = ["../vite.config.ts", "../build-guard.ts", "../playwright.config.ts"].map((f) => readFileSync(join(SRC, f), "utf-8"));
    for (const text of [...sources().map((f) => readFileSync(f, "utf-8")), ...config]) {
      expect(text).not.toMatch(/VITE_DEV_CONTEXT|VITE_DEV_TENANT|VITE_DEV_SCHOOL|smas\.dev\.|localStorage\.setItem/);
    }
    expect(sources().filter((f) => f.includes("devtools"))).toEqual([]);
  });

  it("no data-fetching module touches the context", () => {
    for (const file of sources()) {
      const text = readFileSync(file, "utf-8");
      const fetchesData = /supabase\.from\(|api<[^>]*>\(\s*[`"]\/(schools|students|platform|me)/.test(text);
      const rel = relative(SRC, file).replaceAll("\\", "/");
      if (fetchesData && rel !== "pages/Dashboard.tsx") {
        expect({ file: rel, readsContext: /getSchoolContext|getTenantContext/.test(text) }).toEqual({ file: rel, readsContext: false });
      }
    }
    // Dashboard يقرأ الـprofile الذاتي ويعرض السياق — لكن لا يمرر السياق إلى الاستعلام
    const dash = readFileSync(join(SRC, "pages/Dashboard.tsx"), "utf-8");
    expect(dash).not.toMatch(/\.eq\([^)]*Context\(\)/);
  });

  it("the API client adds no tenant or school", () => {
    const client = readFileSync(join(SRC, "lib/api.ts"), "utf-8");
    expect(client).not.toMatch(/getSchoolContext|getTenantContext|school_id|tenant_id/);
  });
});

describe("no-ui-literals rule", () => {
  const tester = new RuleTester({
    languageOptions: { parser: tsParser, parserOptions: { ecmaFeatures: { jsx: true } } },
  });
  it("flags user-facing literals and ignores the rest", () => {
    tester.run("no-ui-literals", noUiLiterals as never, {
      valid: [
        { code: `const a = <div className="p-4 text-start" data-testid="x">{t("app.name")}</div>;` },
        { code: `const a = <a href="/students" aria-label={t("app.menu")}>☰</a>;` },
        { code: `const a = <input type="password" autoComplete="new-password" placeholder={t("login.email")} />;` },
        { code: `const a = <p>{row.full_name}: {count}</p>;` },
      ],
      invalid: [
        { code: `const a = <p>تسجيل الدخول</p>;`, errors: 1 },
        { code: `const a = <p>Sign in</p>;`, errors: 1 },
        { code: `const a = <input placeholder="Email" />;`, errors: 1 },
        { code: `const a = <button aria-label={"Close"} />;`, errors: 1 },
        { code: "const a = <img alt={`logo`} />;", errors: 1 },
        { code: `const a = <p title="مساعدة">{"نص"}</p>;`, errors: 2 },
      ],
    });
  });
});
