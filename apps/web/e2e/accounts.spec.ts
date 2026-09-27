// ولي الأمر A/B/C والطالب: المسار الكامل في المتصفح حتى البيانات المسموحة والممنوعة.
import { expect, test } from "@playwright/test";
import { changePassword, clearOtp, expectNotFound, fx, otpsFor, readOtp, setDevContext, studentRows } from "./helpers";

async function guardianOtp(page: import("@playwright/test").Page, phone: string, school: string) {
  await page.goto("/login");
  await setDevContext(page, "DEV", school);
  await page.getByTestId("tab-guardian").click();
  await page.getByTestId("guardian-phone").fill(phone);
  await page.getByTestId("guardian-submit").click();
  await expect(page.getByTestId("otp-sent")).toBeVisible();
}

test.beforeEach(() => clearOtp());

test("guardian A: OTP → forced password → own child only", async ({ page }) => {
  const f = fx();
  await guardianOtp(page, f.guardians.A.phone, "school-a");
  await page.getByTestId("guardian-code").fill(await readOtp(f.guardians.A.phone));
  await page.getByTestId("guardian-submit").click();
  await changePassword(page, "Web-A-Parent-1");
  await expect(page.getByTestId("nav-students")).toBeVisible();
  expect(await studentRows(page)).toEqual([f.students.seed.id]);
  await expectNotFound(page, `/students/${f.students.ss.id}`);
  // بعد الـonboarding: الدخول بكلمة المرور
  await page.getByTestId("logout").click();
  await page.getByTestId("tab-guardian").click();
  await page.getByTestId("guardian-mode").click();
  await page.getByTestId("guardian-phone").fill(f.guardians.A.phone);
  await page.getByTestId("guardian-password").fill("Web-A-Parent-1");
  await page.getByTestId("guardian-submit").click();
  await expect(page.getByTestId("dashboard")).toBeVisible();
});

test("guardian B: OTP only — open immediately, own child only", async ({ page }) => {
  const f = fx();
  await guardianOtp(page, f.guardians.B.phone, "school-b");
  await page.getByTestId("guardian-code").fill(await readOtp(f.guardians.B.phone));
  await page.getByTestId("guardian-submit").click();
  await expect(page.getByTestId("dashboard")).toBeVisible();              // بلا شاشة كلمة مرور
  expect(await studentRows(page)).toEqual([f.students.sb.id]);
  await expectNotFound(page, `/students/${f.students.seed.id}`);
});

test("guardian C: no OTP onboarding; school temporary password → forced change", async ({ page }) => {
  const f = fx();
  await guardianOtp(page, f.guardians.C.phone, "standalone");
  await page.waitForTimeout(500);
  expect(otpsFor(f.guardians.C.phone)).toEqual([]);                     // الرد نفسه، ولا رسالة
  await page.getByTestId("guardian-mode").click();
  await page.getByTestId("guardian-phone").fill(f.guardians.C.phone);
  await page.getByTestId("guardian-password").fill(f.guardians.C.temporary_password!);
  await page.getByTestId("guardian-submit").click();
  await changePassword(page, "Web-C-Parent-1");
  expect(await studentRows(page)).toEqual([f.students.ss.id]);
  await expectNotFound(page, `/students/${f.students.sb.id}`);
});

test("student: ID login → forced change → own record only", async ({ page }) => {
  const f = fx();
  await page.goto("/login");
  await page.getByTestId("tab-student").click();
  await page.getByTestId("student-identifier").fill(f.students.fresh.identifier!);
  await page.getByTestId("student-password").fill(f.students.fresh.identifier!);
  await page.getByTestId("student-submit").click();
  await expect(page.getByTestId("change-password")).toBeVisible();
  // المغلق يُعاد إلى تغيير الكلمة من أي مسار
  await page.goto("/students");
  await changePassword(page, "Web-Student-1");
  await expect(page.getByTestId("nav-students")).toBeVisible();
  expect(await studentRows(page)).toEqual([f.students.fresh.id]);
  await expectNotFound(page, `/students/${f.students.seed.id}`);
  const body = await page.content();
  expect(body).not.toMatch(/smas\.invalid|token_hash|magiclink/);
});
