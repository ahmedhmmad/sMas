// Phase 2A / P2-D — إعداد المدرسة في المتصفح: tenant_admin من الصفر حتى «جاهزة للتسجيل»، وبقية الأدوار بحدودها.
// الإخفاء في الواجهة عرض فقط: كل اختبار «ممنوع» يتجاوز الواجهة باستدعاء الـAPI مباشرة بجلسة المستخدم نفسها
// ويثبت أن الخادم يرفض (P2-C/DB) — لا أن الزر مخفي فحسب.
import { expect, type Page, test } from "@playwright/test";
import { adminLogin, at, fx, go, HOSTS, staffLogin } from "./helpers";

const API = "http://127.0.0.1:8000";
const RUN = Date.now().toString(36).toUpperCase().slice(-5);     // رموز فريدة لكل تشغيل (لا تنظيف بين التشغيلات المحلية)
const code = (s: string) => `ZTW${s}${RUN}`;
const slug = (s: string) => `ztw-${s}-${RUN.toLowerCase()}`;

// استدعاء الـAPI مباشرة بجلسة الصفحة (تجاوز الواجهة) — يعيد رمز الحالة
async function direct(page: Page, method: string, path: string, body?: unknown): Promise<number> {
  return page.evaluate(async ({ api, method, path, body }) => {
    const key = Object.keys(localStorage).find((k) => k.endsWith("-auth-token"))!;
    const token = JSON.parse(localStorage.getItem(key)!).access_token;
    const r = await fetch(api + path, {
      method, headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    return r.status;
  }, { api: API, method, path, body });
}

async function reason(page: Page, testId: string, text = "e2e") {
  await page.getByTestId(testId).click();
  await page.getByTestId(`${testId}-reason`).fill(text);
  await page.getByTestId(`${testId}-confirm`).click();
}

test("tenant_admin: from nothing to ready_for_enrollment through the UI", async ({ page }) => {
  test.setTimeout(120_000);
  await adminLogin(page, "tenant.admin@dev.smas.test", HOSTS.tenant);
  await expect(page.getByTestId("nav-schools")).toBeVisible();
  await expect(page.getByTestId("nav-groups")).toBeVisible();

  // مجموعة
  await page.getByTestId("nav-groups").click();
  await page.getByTestId("group-code").fill(code("G"));
  await page.getByTestId("group-name").fill("مجموعة الاختبار");
  await page.getByTestId("group-submit").click();
  await expect(page.getByTestId(`group-row-${code("G")}`)).toBeVisible();
  await page.getByTestId(`group-rename-${code("G")}`).click();
  await page.getByTestId(`group-rename-input-${code("G")}`).fill("مجموعة الاختبار ٢");
  await page.getByTestId(`group-rename-save-${code("G")}`).click();
  await expect(page.getByTestId(`group-name-${code("G")}`)).toHaveText("مجموعة الاختبار ٢");

  // مدرسة داخل المجموعة
  await page.getByTestId("nav-schools").click();
  await page.getByTestId("school-code").fill(code("S"));
  await page.getByTestId("school-name").fill("مدرسة الاختبار");
  await page.getByTestId("school-slug").fill(slug("s"));
  await page.getByTestId("school-group").selectOption({ label: "مجموعة الاختبار ٢" });
  await page.getByTestId("school-submit").click();
  await page.getByTestId(`school-open-${code("S")}`).click();
  await expect(page.getByTestId("school-kind")).toHaveText("ضمن مجموعة");
  await expect(page.getByTestId("readiness-state")).toHaveAttribute("data-ready", "false");
  await expect(page.getByTestId("readiness-active_year")).toHaveAttribute("data-ok", "false");

  // البنية: مرحلة وصف
  await page.getByTestId("stage-name").fill("الابتدائية");
  await page.getByTestId("stage-seq").fill("1");
  await page.getByTestId("stage-submit").click();
  await expect(page.getByTestId("stage-row-الابتدائية")).toBeVisible();
  await page.getByTestId("grade-stage").selectOption({ label: "الابتدائية" });
  await page.getByTestId("grade-name").fill("الأول");
  await page.getByTestId("grade-seq").fill("1");
  await page.getByTestId("grade-submit").click();
  await expect(page.getByTestId("grade-row-الأول")).toBeVisible();

  // سنة، شعبة، تفعيل
  await page.getByTestId("year-name").fill("2040");
  await page.getByTestId("year-start").fill("2040-09-01");
  await page.getByTestId("year-end").fill("2041-06-30");
  await page.getByTestId("year-submit").click();
  await page.getByTestId("year-open-2040").click();
  await expect(page.getByTestId("year-state")).toHaveText("مخطط");
  await page.getByTestId("section-grade").selectOption({ label: "الأول" });
  await page.getByTestId("section-name").fill("أ");
  await page.getByTestId("section-capacity").fill("30");
  await page.getByTestId("section-submit").click();
  await expect(page.getByTestId("section-row-الأول-أ")).toBeVisible();
  await reason(page, "year-activate", "بداية العام");
  await expect(page.getByTestId("year-state")).toHaveText("نشط");
  await expect(page.getByTestId("year-edit-start")).toBeDisabled();

  // الفصول: إنشاء، تفعيل، رفض فصل نشط ثانٍ (رسالة مترجمة)، إغلاق
  for (const [name, seq, s, e] of [["الأول", "1", "2040-09-01", "2040-12-31"], ["الثاني", "2", "2041-01-05", "2041-06-20"]]) {
    await page.getByTestId("term-name").fill(name);
    await page.getByTestId("term-seq").fill(seq);
    await page.getByTestId("term-start").fill(s);
    await page.getByTestId("term-end").fill(e);
    await page.getByTestId("term-submit").click();
    await expect(page.getByTestId(`term-row-${name}`)).toBeVisible();
  }
  await reason(page, "term-activate-الأول");
  await expect(page.getByTestId("term-status-الأول")).toHaveText("نشط");
  await reason(page, "term-activate-الثاني");
  await expect(page.getByTestId("terms-error")).toHaveAttribute("data-code", "invariant_violation");
  await reason(page, "term-close-الأول");
  await expect(page.getByTestId("term-status-الأول")).toHaveText("مغلق");

  // جاهزة للتسجيل
  await go(page, page.url().replace(/\/years\/.*$/, ""));
  await expect(page.getByTestId("readiness-state")).toHaveAttribute("data-ready", "true");

  // سنة مخططة ثانية ونسخ الشعب: 1 ثم 0
  await page.getByTestId("year-name").fill("2041");
  await page.getByTestId("year-start").fill("2041-09-01");
  await page.getByTestId("year-end").fill("2042-06-30");
  await page.getByTestId("year-submit").click();
  await page.getByTestId("year-open-2041").click();
  await page.getByTestId("copy-source").selectOption({ label: "2040" });
  await page.getByTestId("copy-reason").fill("العام القادم");
  await page.getByTestId("copy-submit").click();
  await expect(page.getByTestId("copy-result")).toHaveAttribute("data-created", "1");
  await expect(page.getByTestId("section-row-الأول-أ")).toBeVisible();
  await page.getByTestId("copy-submit").click();
  await expect(page.getByTestId("copy-result")).toHaveAttribute("data-created", "0");

  // المعرّف في العنوان: تعارض مترجم، ثم تغيير ناجح
  await go(page, page.url().replace(/\/years\/.*$/, ""));
  await page.getByTestId("slug-new").fill("school-a");
  await page.getByTestId("slug-reason").fill("تجربة");
  await page.getByTestId("slug-submit").click();
  await expect(page.getByTestId("slug-error")).toHaveAttribute("data-code", "conflict");
  await page.getByTestId("slug-new").fill(slug("n"));
  await page.getByTestId("slug-submit").click();
  await expect(page.getByTestId("school-slug-value")).toHaveText(slug("n"));

  // نمط ولي الأمر
  await page.getByTestId("guardian-mode-select").selectOption("C");
  await page.getByTestId("guardian-mode-reason").fill("سياسة المدرسة");
  await page.getByTestId("guardian-mode-submit").click();
  await expect(page.getByTestId("guardian-mode-current")).toHaveText("كلمة مرور مؤقتة من المدرسة");

  // أرشفة المجموعة وفيها مدرسة نشطة ← رفض مترجم
  await page.getByTestId("nav-groups").click();
  await reason(page, `group-archive-${code("G")}`);
  await expect(page.getByTestId("action-error")).toHaveAttribute("data-code", "invariant_violation");

  // مدرسة مستقلة تُنشأ ثم تُؤرشف
  await page.getByTestId("nav-schools").click();
  await page.getByTestId("school-code").fill(code("X"));
  await page.getByTestId("school-name").fill("مدرسة مستقلة للاختبار");
  await page.getByTestId("school-slug").fill(slug("x"));
  await page.getByTestId("school-submit").click();
  await page.getByTestId(`school-open-${code("X")}`).click();
  await expect(page.getByTestId("school-kind")).toHaveText("مدرسة مستقلة");
  await reason(page, "school-archive", "إغلاق");
  await expect(page.getByTestId("school-status")).toHaveText("مؤرشف");
  await expect(page.getByTestId("school-slug")).toHaveCount(0);
});

test("group_manager: creates in its group only; no group creation", async ({ page }) => {
  await staffLogin(page, "group.manager@dev.smas.test", undefined, true, HOSTS.tenant);
  await page.getByTestId("nav-schools").click();
  await expect(page.getByTestId("school-row-SA")).toBeVisible();
  await expect(page.getByTestId("school-row-SB")).toBeVisible();
  await expect(page.getByTestId("school-row-SS")).toHaveCount(0);
  await page.getByTestId("school-code").fill(code("M"));
  await page.getByTestId("school-name").fill("مدرسة المدير");
  await page.getByTestId("school-slug").fill(slug("m"));
  await page.getByTestId("school-group").selectOption({ label: "Group A" });
  await page.getByTestId("school-submit").click();
  await expect(page.getByTestId(`school-row-${code("M")}`)).toBeVisible();
  // مستقلة: الخيار معروض، والخادم يرفض (لا نطاق Tenant)
  await page.getByTestId("school-code").fill(code("N"));
  await page.getByTestId("school-name").fill("x");
  await page.getByTestId("school-slug").fill(slug("nn"));
  await page.getByTestId("school-group").selectOption("");
  await page.getByTestId("school-submit").click();
  await expect(page.getByTestId("action-error")).toHaveAttribute("data-code", "forbidden");
  // المجموعات: قراءة بلا إنشاء ولا أرشفة
  await page.getByTestId("nav-groups").click();
  await expect(page.getByTestId("group-row-GA")).toBeVisible();
  await expect(page.getByTestId("group-create")).toHaveCount(0);
  expect(await direct(page, "POST", "/groups", { group_code: code("Q"), name: "x" })).toBe(403);
});

test("school_admin: its school only; other schools by URL are not found; bypassing the UI grants nothing", async ({ page }) => {
  const f = fx();
  await staffLogin(page, "school.admin@dev.smas.test");
  await page.getByTestId("nav-schools").click();
  await expect(page.getByTestId("school-row-SA")).toBeVisible();
  await expect(page.locator("[data-testid^='school-row-']")).toHaveCount(1);
  await expect(page.getByTestId("school-create")).toHaveCount(0);
  await page.getByTestId("school-open-SA").click();
  await expect(page.getByTestId("readiness-state")).toHaveAttribute("data-ready", "true");
  await expect(page.getByTestId("school-archive")).toHaveCount(0);          // school.archive ليس لمدير المدرسة
  await expect(page.getByTestId("guardian-mode")).toBeVisible();           // security.manage
  await go(page, `/setup/schools/${f.schools.SB}`);
  await expect(page.getByTestId("state-not-found")).toBeVisible();
  // تجاوز الواجهة: الخادم يقرر
  expect(await direct(page, "POST", "/schools", { school_code: code("B"), name: "x", slug: slug("b") })).toBe(403);
  expect(await direct(page, "PATCH", `/schools/${f.schools.SB}`, { name: "hijack" })).toBe(404);
  expect(await direct(page, "POST", `/schools/${f.schools.SB}/slug`, { slug: slug("h"), reason: "r" })).toBe(404);
  expect(await direct(page, "POST", `/schools/${f.schools.SA}/academic-years`, { name: "x", start_date: "2050-09-01", end_date: "2051-06-30", school_id: f.schools.SB })).toBe(422);
});

test("secretary: reads setup, every write control hidden, and the server refuses the bypass", async ({ page }) => {
  const f = fx();
  await staffLogin(page, "secretary@dev.smas.test");
  await page.getByTestId("nav-schools").click();
  await page.getByTestId("school-open-SA").click();
  await expect(page.getByTestId("readiness-state")).toHaveAttribute("data-ready", "true");
  for (const id of ["school-edit-save", "school-slug", "guardian-mode", "school-archive", "year-submit", "stage-submit", "grade-submit"]) {
    await expect(page.getByTestId(id)).toHaveCount(0);
  }
  await page.getByTestId("year-open-2026/2027").click();
  await expect(page.getByTestId("year-card")).toBeVisible();
  for (const id of ["year-edit-save", "year-close", "term-submit", "section-submit", "copy-sections"]) {
    await expect(page.getByTestId(id)).toHaveCount(0);
  }
  const yearId = page.url().split("/years/")[1];
  expect(await direct(page, "PATCH", `/academic-years/${yearId}`, { name: "hijack" })).toBe(403);
  expect(await direct(page, "POST", `/academic-years/${yearId}/close`, { reason: "r" })).toBe(403);
  expect(await direct(page, "PATCH", `/schools/${f.schools.SA}`, { name: "hijack" })).toBe(403);
});

test("bus_supervisor, guardian-less staff and platform admin: no setup menu, nothing behind the URL", async ({ page, browser }) => {
  const f = fx();
  await staffLogin(page, "bus.supervisor@dev.smas.test");
  await expect(page.getByTestId("nav-schools")).toHaveCount(0);
  await go(page, `/setup/schools/${f.schools.SA}`);
  await expect(page.getByTestId("school")).toBeVisible();                 // المدرسة مرئية له (school.read)…
  await expect(page.getByTestId("readiness")).toHaveCount(0);              // …والجاهزية لا (403 من الخادم)
  expect(await direct(page, "GET", `/schools/${f.schools.SA}/readiness`)).toBe(403);

  const platform = await browser.newPage();
  await adminLogin(platform, "platform@dev.smas.test", HOSTS.platform);
  await expect(platform.getByTestId("nav-schools")).toHaveCount(0);
  await go(platform, "/setup/schools");
  await expect(platform.getByTestId("schools-empty")).toBeVisible();
  expect(await direct(platform, "POST", "/schools", { school_code: code("P"), name: "x", slug: slug("p") })).toBe(403);
  await platform.close();
});

test("context is not authority: a tenant admin on a school host still sees every school", async ({ page }) => {
  await adminLogin(page, "tenant.admin@dev.smas.test", HOSTS.SA);
  await page.goto(at(HOSTS.SA, "/setup/schools"));
  for (const c of ["SA", "SB", "SS"]) await expect(page.getByTestId(`school-row-${c}`)).toBeVisible();
});
