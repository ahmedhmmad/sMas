// F3: السياق من الـhost — عرض واختيار نموذج الدخول فقط؛ لا يمنح شيئاً (يحل محل اختبار أداة السياق في F1).
import { expect, test } from "@playwright/test";
import { at, fx, HOSTS, staffLogin, studentRows } from "./helpers";

const SERVERS = /127\.0\.0\.1:(8000|54321)|localhost:(8000|54321)/;   // FastAPI و Supabase

test("unknown host: a static page — no login and no request to any server", async ({ page }) => {
  const calls: string[] = [];
  page.on("request", (r) => { if (SERVERS.test(r.url())) calls.push(r.url()); });
  for (const host of ["a.school-a.dev", "api", "www", "school-a.api"]) {
    await page.goto(at(host, "/login"));
    await expect(page.getByTestId("state-unknown-host")).toBeVisible();
    await expect(page.getByTestId("form-staff")).toHaveCount(0);
    await expect(page.getByTestId("form-admin")).toHaveCount(0);
  }
  expect(calls).toEqual([]);
});

test("platform host: the admin login only", async ({ page }) => {
  await page.goto(at(HOSTS.platform, "/login"));
  await expect(page).toHaveURL(/\/login\/admin$/);
  await expect(page.getByTestId("form-admin")).toBeVisible();
  await expect(page.getByRole("tab")).toHaveCount(0);
});

test("tenant host: staff only; school host: staff, guardian, student — each shows its host", async ({ page }) => {
  await page.goto(at(HOSTS.tenant, "/login"));
  await expect(page.getByRole("tab")).toHaveCount(1);
  await expect(page.getByTestId("tab-staff")).toBeVisible();
  await expect(page.getByTestId("login-context")).toContainText("dev");
  await page.goto(at(HOSTS.SB, "/login"));
  await expect(page.getByRole("tab")).toHaveCount(3);
  await expect(page.getByTestId("login-context")).toContainText("school-b");
});

test("context is not authorization: an SA user on the SB host gets SA data, never SB", async ({ page }) => {
  const f = fx();
  await staffLogin(page, "secretary@dev.smas.test");                                       // host المدرسة SA
  const onOwnHost = await studentRows(page);
  await staffLogin(page, "secretary@dev.smas.test", undefined, true, HOSTS.SB);           // host المدرسة SB
  await expect(page.getByTestId("context-display")).toContainText("school-b");            // العرض تغيّر
  const onOtherHost = await studentRows(page);
  expect(onOtherHost.sort()).toEqual(onOwnHost.sort());                                     // البيانات لا
  expect(onOtherHost).toContain(f.students.seed.id);
  expect(onOtherHost).not.toContain(f.students.sb.id);
  await expect(page.getByTestId("export-actions")).toHaveCount(0);
});

test("the tenant comes from the host: the same account is not found under another tenant label", async ({ page }) => {
  await staffLogin(page, "secretary@dev.smas.test", undefined, false, "school-a.other");
  await expect(page.getByTestId("login-error")).toBeVisible();                              // الرد العام نفسه
  await expect(page.getByTestId("dashboard")).toHaveCount(0);
  await staffLogin(page, "secretary@dev.smas.test", undefined, true, HOSTS.SA);            // ضابط
});

test("a session belongs to its host: another host starts signed out", async ({ page }) => {
  await staffLogin(page, "secretary@dev.smas.test");
  await page.goto(at(HOSTS.SB, "/students"));
  await expect(page.getByTestId("form-staff")).toBeVisible();
});
