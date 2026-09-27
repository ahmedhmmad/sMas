// قيد F1 (2): سياق المدرسة في الواجهة عرض فقط — تغييره في المتصفح لا يغيّر البيانات ولا يمنح صلاحية.
import { expect, test } from "@playwright/test";
import { fx, staffLogin, studentRows } from "./helpers";

test("changing the school context in the browser grants nothing", async ({ page }) => {
  const f = fx();
  await staffLogin(page, "secretary@dev.smas.test");
  const before = await studentRows(page);
  expect(before).not.toContain(f.students.ss.id);
  // مسار العبث: السياق المخزَّن في المتصفح يُشار إلى مدرسة أخرى
  await page.evaluate(() => { localStorage.setItem("smas.dev.school", "standalone"); localStorage.setItem("smas.dev.tenant", "DEV"); });
  await page.reload();
  await expect(page.getByTestId("context-display")).toContainText("standalone");   // العرض تغيّر
  const after = await studentRows(page);
  expect(after.sort()).toEqual(before.sort());                                       // البيانات لا
  expect(after).not.toContain(f.students.ss.id);
  await expect(page.getByTestId("export-actions")).toHaveCount(0);
});
