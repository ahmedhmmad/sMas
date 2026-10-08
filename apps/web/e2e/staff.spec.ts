// Phase 3A / 3-1 — ملف الموظف في المتصفح: مدير المدرسة ينشئ موظفاً ويكمل ملفه؛ المعلم يقرأ ولا يكتب؛ السكرتير لا يرى.
// الإخفاء في الواجهة عرض فقط: كل «ممنوع» يتجاوز الواجهة باستدعاء الـAPI مباشرة بجلسة المستخدم نفسها ويثبت رفض الخادم.
import { expect, type Page, test } from "@playwright/test";
import { clearOtp, fx, go, readOtp, staffLogin } from "./helpers";

const API = "http://127.0.0.1:8000";
const RUN = Date.now().toString(36).toUpperCase().slice(-5);
const CODE = `ZTW-E${RUN}`;

async function direct(page: Page, method: string, path: string, body?: unknown): Promise<{ status: number; json: unknown }> {
  return page.evaluate(async ({ api, method, path, body }) => {
    const key = Object.keys(localStorage).find((k) => k.endsWith("-auth-token"))!;
    const token = JSON.parse(localStorage.getItem(key)!).access_token;
    const r = await fetch(api + path, {
      method, headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    return { status: r.status, json: await r.json().catch(() => null) };
  }, { api: API, method, path, body });
}

async function reason(page: Page, testId: string, text = "e2e") {
  await page.getByTestId(testId).click();
  await page.getByTestId(`${testId}-reason`).fill(text);
  await page.getByTestId(`${testId}-confirm`).click();
}

test("school admin: creates a staff member and completes the profile through the UI", async ({ page }) => {
  test.setTimeout(90_000);
  const sa = fx().schools.SA;
  await staffLogin(page, "school.admin@dev.smas.test");
  await go(page, `/setup/schools/${sa}`);
  await page.getByTestId("open-staff").click();
  await expect(page.getByTestId("staff-list")).toBeVisible();

  await page.getByTestId("staff-new-code").fill(CODE);
  await page.getByTestId("staff-new-first_name").fill("سارة");
  await page.getByTestId("staff-new-father_name").fill("محمود");
  await page.getByTestId("staff-new-family_name").fill("نبيل");
  await page.getByTestId("staff-new-job").fill("معلمة رياضيات");
  await page.getByTestId("staff-new-email").fill(`${CODE.toLowerCase()}@example.test`);
  await page.getByTestId("staff-new-submit").click();
  await expect(page.getByTestId("staff-title")).toHaveText("سارة محمود نبيل");

  // البيانات
  await page.getByTestId("staff-edit-phone_e164").fill("+201000007777");
  await page.getByTestId("staff-edit-save").click();
  await expect(page.getByTestId("staff-edit-phone_e164")).toHaveValue("+201000007777");
  // E.164: الحقل يمنع الإرسال (عرض فقط)، والخادم يرفض حين تُتجاوز الواجهة
  await page.getByTestId("staff-edit-phone_e164").fill("0100");
  expect(await page.getByTestId("staff-edit-phone_e164").evaluate((el: HTMLInputElement) => el.validity.patternMismatch)).toBe(true);
  const staffId = new URL(page.url()).pathname.split("/").pop()!;
  expect((await direct(page, "PATCH", `/staff/${staffId}`, { phone_e164: "0100" })).status).toBe(422);
  await page.getByTestId("staff-edit-phone_e164").fill("+201000007777");

  // التخصصات والمؤهلات
  await page.getByTestId("staff-specialty-new").fill("الرياضيات");
  await page.getByTestId("staff-specialty-add").click();
  await expect(page.getByTestId("staff-specialty-الرياضيات")).toBeVisible();
  await page.getByTestId("staff-specialty-new").fill("الرياضيات");
  await page.getByTestId("staff-specialty-add").click();
  await expect(page.getByTestId("staff-specialty-error")).toHaveAttribute("data-code", "conflict");
  await page.getByTestId("staff-specialty-toggle-الرياضيات").click();
  await expect(page.getByTestId("staff-specialty-status-الرياضيات")).toHaveText("معطّل");
  await page.getByTestId("staff-qualification-degree").selectOption("master");
  await page.getByTestId("staff-qualification-field").fill("تربية");
  await page.getByTestId("staff-qualification-year").fill("2015");
  await page.getByTestId("staff-qualification-add").click();
  await expect(page.getByTestId("staff-qualifications").getByText("ماجستير — تربية")).toBeVisible();

  // الحالة: إجازة ثم عودة — بسبب
  await reason(page, "staff-leave", "إجازة مرضية");
  await expect(page.getByTestId("staff-status")).toHaveText("في إجازة");
  await reason(page, "staff-back", "عودة");
  await expect(page.getByTestId("staff-status")).toHaveText("نشط");

  // في القائمة
  await go(page, `/setup/schools/${sa}/staff`);
  await expect(page.getByTestId(`staff-row-${CODE}`)).toContainText("معلمة رياضيات");

  // المدرسة الأخرى غير موجودة له — حتى بتجاوز الواجهة
  expect((await direct(page, "GET", `/schools/${fx().schools.SB}/staff`)).status).toBe(404);
  expect((await direct(page, "POST", `/schools/${fx().schools.SB}/staff`,
    { employee_code: `${CODE}X`, first_name: "x", family_name: "x", job_title: "x", effective_from: "2026-09-01" })).status).toBe(404);
});

test("teacher: reads the school's staff (PD1) — every write is hidden and the server refuses the bypass", async ({ page }) => {
  const sa = fx().schools.SA;
  await staffLogin(page, "teacher@dev.smas.test");
  await go(page, `/setup/schools/${sa}`);
  await page.getByTestId("open-staff").click();
  await expect(page.getByTestId("staff-list")).toBeVisible();
  await expect(page.getByTestId("staff-create")).toHaveCount(0);
  const first = page.locator("[data-testid^='staff-open-']").first();
  const href = (await first.getAttribute("href"))!;
  const staffId = href.split("/").pop()!;
  await first.click();
  await expect(page.getByTestId("staff-detail")).toBeVisible();
  for (const id of ["staff-edit-save", "staff-status-card", "staff-specialty-add", "staff-qualification-add"]) {
    await expect(page.getByTestId(id)).toHaveCount(0);
  }
  expect((await direct(page, "PATCH", `/staff/${staffId}`, { first_name: "x" })).status).toBe(403);
  expect((await direct(page, "POST", `/staff/${staffId}/specialties`, { name: "x" })).status).toBe(403);
  expect((await direct(page, "POST", `/staff/${staffId}/status`, { status: "on_leave", reason: "x" })).status).toBe(403);
  expect((await direct(page, "POST", `/schools/${sa}/staff`,
    { employee_code: `${CODE}T`, first_name: "x", family_name: "x", job_title: "x", effective_from: "2026-09-01" })).status).toBe(403);
});

test("secretary: no staff link, and the API shows no staff (no staff.read)", async ({ page }) => {
  const sa = fx().schools.SA;
  await staffLogin(page, "secretary@dev.smas.test");
  await go(page, `/setup/schools/${sa}`);
  await expect(page.getByTestId("school")).toBeVisible();
  await expect(page.getByTestId("open-staff")).toHaveCount(0);
  const list = await direct(page, "GET", `/schools/${sa}/staff`);
  expect(list).toEqual({ status: 200, json: { rows: [] } });
});

// ------------------------------------------------------------------ 3-2: الحساب والدور والنطاق
test("school admin activates a new staff account; the staff member really logs in by OTP from the school host", async ({ page }) => {
  test.setTimeout(120_000);
  clearOtp();
  const sa = fx().schools.SA;
  const code = `ZTW-A${RUN}`;
  const email = `${code.toLowerCase()}@example.test`;
  await staffLogin(page, "school.admin@dev.smas.test");
  await go(page, `/setup/schools/${sa}/staff`);
  await page.getByTestId("staff-new-code").fill(code);
  await page.getByTestId("staff-new-first_name").fill("منى");
  await page.getByTestId("staff-new-family_name").fill("سالم");
  await page.getByTestId("staff-new-job").fill("معلمة علوم");
  await page.getByTestId("staff-new-email").fill(email);
  await page.getByTestId("staff-new-submit").click();
  await expect(page.getByTestId("staff-access-none")).toBeVisible();
  const staffId = new URL(page.url()).pathname.split("/").pop()!;

  // الدور الذي يتجاوز صلاحيات مدير المدرسة معروض معطَّلاً (عرض) — والخادم يرفضه حين تُتجاوز الواجهة، بلا أثر
  const roles = (await direct(page, "GET", `/staff/${staffId}/access/assignable-roles`)).json as { rows: { id: string; code: string; assignable: boolean }[] };
  const byCode = Object.fromEntries(roles.rows.map((r) => [r.code, r]));
  expect(byCode.tenant_admin.assignable).toBe(false);
  const refused = await direct(page, "POST", `/schools/${sa}/staff/${staffId}/account`, { role_id: byCode.tenant_admin.id });
  expect(refused).toEqual({ status: 403, json: { detail: "role_exceeds_authority" } });
  expect(((await direct(page, "GET", `/staff/${staffId}/access`)).json as { has_account: boolean }).has_account).toBe(false);
  // لا سياق من الجسم: مدرسة أخرى في الجسم مرفوضة شكلاً
  expect((await direct(page, "POST", `/schools/${sa}/staff/${staffId}/account`, { role_id: byCode.teacher.id, school_id: fx().schools.SB })).status).toBe(422);

  // التفعيل من الواجهة: نداء واحد
  await page.getByTestId("staff-access-role").selectOption(byCode.teacher.id);
  await page.getByTestId("staff-access-activate").click();
  await expect(page.getByTestId("staff-access-ready")).toHaveAttribute("data-can-login", "true");
  await expect(page.getByTestId("staff-access-role-teacher")).toBeVisible();
  await expect(page.locator("[data-testid^='staff-access-scope-']").first()).toBeVisible();
  await page.getByTestId("logout").click();

  // الموظف الجديد: رمز تحقق على بريده من host المدرسة
  await page.getByTestId("tab-staff").click();
  await page.getByTestId("staff-mode").click();
  await page.getByTestId("staff-email").fill(email);
  await page.getByTestId("staff-submit").click();
  await expect(page.getByTestId("staff-otp-sent")).toBeVisible();
  await page.getByTestId("staff-code").fill(await readOtp(email));
  await page.getByTestId("staff-submit").click();
  await expect(page.getByTestId("dashboard")).toBeVisible();
  await expect(page.getByTestId("nav-students")).toBeVisible();          // مفاتيح المعلم
  await expect(page.getByTestId("nav-groups")).toHaveCount(0);

  // يرى موظفي مدرسته ولا يدير الوصول: لا قسم، والخادم يرفض
  await go(page, `/setup/schools/${sa}/staff/${staffId}`);
  await expect(page.getByTestId("staff-detail")).toBeVisible();
  await expect(page.getByTestId("staff-access")).toHaveCount(0);
  expect((await direct(page, "GET", `/staff/${staffId}/access`)).status).toBe(403);
  // بلا membership.read العضوية غير مرئية ← غير موجودة (404)، لا «مرئي ومرفوض»
  expect((await direct(page, "POST", `/staff/${staffId}/access/roles/${byCode.secretary.id}`)).status).toBe(404);
  expect((await direct(page, "GET", `/schools/${fx().schools.SB}/staff`)).status).toBe(404);
});
