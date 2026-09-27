// الأدوار: المتصفح ← الدخول ← الواجهة الصحيحة ← المسار المحمي ← المسموح ← الممنوع (ومنه كتابة الرابط يدوياً).
import { expect, test } from "@playwright/test";
import { adminLogin, expectNotFound, fx, staffLogin, studentRows } from "./helpers";

test("platform admin: tenants (audited API), no customer data", async ({ page }) => {
  await adminLogin(page, "platform@dev.smas.test");
  await expect(page.getByTestId("dashboard-platform")).toBeVisible();
  await expect(page.getByTestId("nav-tenants")).toBeVisible();
  await expect(page.getByTestId("nav-students")).toHaveCount(0);
  await page.getByTestId("nav-tenants").click();
  await expect(page.getByTestId("tenant-row-DEV")).toBeVisible();
  // يدوياً: صفحة الطلاب — RLS لا تعطي المنصة بيانات عملاء
  await page.goto("/students");
  await expect(page.getByTestId("students-empty")).toBeVisible();
});

test("tenant_admin: every school, export, no platform route", async ({ page }) => {
  const f = fx();
  await adminLogin(page, "tenant.admin@dev.smas.test");
  await expect(page.getByTestId("nav-students")).toBeVisible();
  const rows = await studentRows(page);
  for (const s of [f.students.seed.id, f.students.sb.id, f.students.ss.id]) expect(rows).toContain(s);
  for (const code of ["SA", "SB", "SS"] as const) await expect(page.getByTestId(`export-${f.schools[code]}`)).toBeVisible();
  await page.getByTestId(`export-${f.schools.SA}`).click();
  await expect(page.getByTestId("export-message")).toBeVisible();
  await page.goto("/platform/tenants");
  await expect(page.getByTestId("state-forbidden")).toBeVisible();
});

test("group_manager: SA and SB only; a standalone-school student by URL is not found", async ({ page }) => {
  const f = fx();
  await staffLogin(page, "group.manager@dev.smas.test");
  const rows = await studentRows(page);
  expect(rows).toContain(f.students.seed.id);
  expect(rows).toContain(f.students.sb.id);
  expect(rows).not.toContain(f.students.ss.id);
  await expect(page.getByTestId(`export-${f.schools.SA}`)).toBeVisible();
  await expect(page.getByTestId(`export-${f.schools.SS}`)).toHaveCount(0);
  await expectNotFound(page, `/students/${f.students.ss.id}`);
});

test("school_admin: SA only, export SA; an SB student by URL is not found", async ({ page }) => {
  const f = fx();
  await staffLogin(page, "school.admin@dev.smas.test");
  const rows = await studentRows(page);
  expect(rows).toContain(f.students.seed.id);
  expect(rows).not.toContain(f.students.sb.id);
  await expect(page.getByTestId(`export-${f.schools.SA}`)).toBeVisible();
  await expect(page.getByTestId(`export-${f.schools.SB}`)).toHaveCount(0);
  await expectNotFound(page, `/students/${f.students.sb.id}`);
  await page.goto(`/students/${f.students.seed.id}`);
  await expect(page.getByTestId("student-detail")).toBeVisible();
});

for (const email of ["secretary@dev.smas.test", "teacher@dev.smas.test", "accountant@dev.smas.test", "counselor@dev.smas.test"]) {
  test(`${email.split("@")[0]}: reads SA students, no export action, no platform route`, async ({ page }) => {
    const f = fx();
    await staffLogin(page, email);
    const rows = await studentRows(page);
    expect(rows).toContain(f.students.seed.id);
    expect(rows).not.toContain(f.students.ss.id);
    await expect(page.getByTestId("export-actions")).toHaveCount(0);
    await page.goto("/platform/tenants");
    await expect(page.getByTestId("state-forbidden")).toBeVisible();
  });
}

test("bus_supervisor: no students menu; the page by URL shows nothing", async ({ page }) => {
  await staffLogin(page, "bus.supervisor@dev.smas.test");
  await expect(page.getByTestId("dashboard")).toBeVisible();
  await expect(page.getByTestId("nav-students")).toHaveCount(0);
  await page.goto("/students");
  await expect(page.getByTestId("students-empty")).toBeVisible();
});

test("wrong password: one generic message", async ({ page }) => {
  await staffLogin(page, "secretary@dev.smas.test", "not-the-password", false);
  await expect(page.getByTestId("login-error")).toBeVisible();
  await expect(page.getByTestId("dashboard")).toHaveCount(0);
});

test("logout returns to login and protected routes need a session again", async ({ page }) => {
  await staffLogin(page, "secretary@dev.smas.test");
  await expect(page.getByTestId("dashboard")).toBeVisible();
  await page.getByTestId("logout").click();
  await expect(page.getByTestId("form-staff")).toBeVisible();
  await page.goto("/students");
  await expect(page.getByTestId("form-staff")).toBeVisible();
});
