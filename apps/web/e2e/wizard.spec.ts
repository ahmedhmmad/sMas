// Phase 2B / 2B-5 — معيار إغلاق المرحلة 2 (PLAN §5): «إعداد مدرسة كاملة من الصفر عبر الواجهة فقط».
// tenant_admin ينشئ المدرسة ثم يُكمل كل شيء عبر المعالج وحده — البطاقات القائمة نفسها داخل خطواته — حتى
// setup_complete = true و ready_for_enrollment = true. الأصول اختيارية (W3) فلا رفع هنا (Storage مستبعد في CI).
import { expect, type Page, test } from "@playwright/test";
import { adminLogin, fx, go, HOSTS, staffLogin } from "./helpers";

const API = "http://127.0.0.1:8000";
const RUN = Date.now().toString(36).toUpperCase().slice(-5);

async function direct(page: Page, method: string, path: string): Promise<number> {
  return page.evaluate(async ({ api, method, path }) => {
    const key = Object.keys(localStorage).find((k) => k.endsWith("-auth-token"))!;
    const token = JSON.parse(localStorage.getItem(key)!).access_token;
    return (await fetch(api + path, { method, headers: { Authorization: `Bearer ${token}` } })).status;
  }, { api: API, method, path });
}

async function stepDone(page: Page, key: string) {
  await page.getByTestId("wizard-refresh").click();
  await expect(page.getByTestId(`wizard-step-${key}`)).toHaveAttribute("data-done", "true");
}

test("Phase 2 criterion: a complete school from nothing, through the wizard only", async ({ page }) => {
  test.setTimeout(180_000);
  await adminLogin(page, "tenant.admin@dev.smas.test", HOSTS.tenant);
  await page.getByTestId("nav-schools").click();
  await page.getByTestId("school-code").fill(`ZTZ${RUN}`);
  await page.getByTestId("school-name").fill("مدرسة المعالج");
  await page.getByTestId("school-slug").fill(`ztz-${RUN.toLowerCase()}`);
  await page.getByTestId("school-submit").click();
  await page.getByTestId(`school-open-ZTZ${RUN}`).click();
  await page.getByTestId("open-wizard").click();
  await expect(page.getByTestId("wizard-steps")).toBeVisible();
  for (const key of ["profile", "year", "calendar", "structure", "subjects", "bell"]) {
    await expect(page.getByTestId(`wizard-step-${key}`)).toHaveAttribute("data-done", "false");
  }

  // 1 — الملف
  await page.getByTestId("profile-address").fill("القاهرة");
  await page.getByTestId("profile-phone_e164").fill("+201000000888");
  await page.getByTestId("profile-save").click();
  await stepDone(page, "profile");

  // 2 — السنة والفصل (السنة تُثبَّت في العنوان بعد ظهورها — W1)
  await page.getByTestId("wizard-step-year").click();
  await page.getByTestId("year-name").fill("2090");
  await page.getByTestId("year-start").fill("2090-09-01");
  await page.getByTestId("year-end").fill("2091-06-30");
  await page.getByTestId("year-submit").click();
  await page.getByTestId("wizard-refresh").click();
  await expect(page).toHaveURL(/year=/);
  await page.getByTestId("term-name").fill("الفصل الأول");
  await page.getByTestId("term-seq").fill("1");
  await page.getByTestId("term-start").fill("2090-09-01");
  await page.getByTestId("term-end").fill("2091-01-20");
  await page.getByTestId("term-submit").click();
  await stepDone(page, "year");

  // 3 — التقويم
  await page.getByTestId("wizard-next").click();
  for (const d of [0, 1, 2, 3, 4]) await page.getByTestId(`weekday-check-${d}`).check();
  await page.getByTestId("weekdays-reason").fill("أسبوع الدراسة");
  await page.getByTestId("weekdays-submit").click();
  await stepDone(page, "calendar");

  // 4 — المراحل والصفوف والشعب
  await page.getByTestId("wizard-next").click();
  await page.getByTestId("stage-name").fill("الابتدائية");
  await page.getByTestId("stage-seq").fill("1");
  await page.getByTestId("stage-submit").click();
  await page.getByTestId("grade-stage").selectOption({ label: "الابتدائية" });
  await page.getByTestId("grade-name").fill("الأول");
  await page.getByTestId("grade-seq").fill("1");
  await page.getByTestId("grade-submit").click();
  await page.getByTestId("wizard-refresh").click();
  await page.getByTestId("section-grade").selectOption({ label: "الأول" });
  await page.getByTestId("section-name").fill("أ");
  await page.getByTestId("section-submit").click();
  await stepDone(page, "structure");

  // 5 — المواد (لكل صف له شعب — W2)
  await page.getByTestId("wizard-next").click();
  await expect(page.getByTestId("wizard-missing")).toContainText("1");
  await page.getByTestId("subject-code").fill("AR");
  await page.getByTestId("subject-name").fill("اللغة العربية");
  await page.getByTestId("subject-submit").click();
  await page.getByTestId("wizard-refresh").click();
  await page.getByTestId("gs-grade").selectOption({ label: "الأول" });
  await page.getByTestId("gs-subject").selectOption({ label: "AR — اللغة العربية" });
  await page.getByTestId("gs-periods").fill("6");
  await page.getByTestId("gs-submit").click();
  await stepDone(page, "subjects");

  // 6 — الدوام: جدول بحصة، وإسناد الصف
  await page.getByTestId("wizard-next").click();
  await page.getByTestId("bell-schedule-name").fill("صباحية");
  await page.getByTestId("bell-schedule-submit").click();
  await page.getByTestId("bell-schedule-open-صباحية").click();
  await page.getByTestId("bell-period-day").selectOption("0");
  await page.getByTestId("bell-period-start").fill("08:00");
  await page.getByTestId("bell-period-end").fill("08:45");
  await page.getByTestId("bell-period-submit").click();
  await expect(page.getByTestId("bell-period-صباحية-0-08:00")).toBeVisible();
  await page.getByTestId("grade-bell-select-الأول").selectOption({ label: "صباحية" });
  await stepDone(page, "bell");

  // مكتمل الإعداد قبل التفعيل، وغير جاهز للتسجيل (السنة planned) — مؤشران مستقلان (W3)
  await page.getByTestId("wizard-step-review").click();
  await expect(page.getByTestId("wizard-setup-complete")).toHaveAttribute("data-value", "true");
  await expect(page.getByTestId("wizard-ready")).toHaveAttribute("data-value", "false");

  // تفعيل السنة من خطوة السنة ← جاهزة للتسجيل (تعريف 2A كما هو)
  await page.getByTestId("wizard-step-year").click();
  await page.getByTestId("year-activate").click();
  await page.getByTestId("year-activate-reason").fill("بداية العام");
  await page.getByTestId("year-activate-confirm").click();
  await page.getByTestId("wizard-step-review").click();
  await expect(page.getByTestId("wizard-setup-complete")).toHaveAttribute("data-value", "true");
  await expect(page.getByTestId("wizard-ready")).toHaveAttribute("data-value", "true");
  await expect(page.getByTestId("review-assets")).toHaveAttribute("data-done", "false");          // الأصول اختيارية
});

test("wizard boundaries: another school is not found; read-only staff see no write controls; no wizard write path", async ({ page }) => {
  const f = fx();
  await staffLogin(page, "school.admin@dev.smas.test");
  await go(page, `/setup/schools/${f.schools.SB}/wizard`);
  await expect(page.getByTestId("state-not-found")).toBeVisible();
  expect(await direct(page, "GET", `/schools/${f.schools.SB}/setup-progress`)).toBe(404);
  expect(await direct(page, "POST", `/schools/${f.schools.SA}/setup-progress`)).toBe(405);

  const secretary = await page.context().browser()!.newPage();
  await staffLogin(secretary, "secretary@dev.smas.test");
  await go(secretary, `/setup/schools/${f.schools.SA}/wizard`);
  await expect(secretary.getByTestId("wizard-steps")).toBeVisible();
  await secretary.getByTestId("wizard-step-structure").click();
  for (const id of ["stage-submit", "grade-submit", "section-submit"]) await expect(secretary.getByTestId(id)).toHaveCount(0);
  await secretary.close();
});
