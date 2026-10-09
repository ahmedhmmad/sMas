// Phase 3A / 3-3 — التكليفات في المتصفح: مدير المدرسة يكلّف معلماً بمادة ومربياً لشعبة، يستبدل، ينهي.
// المعلم يقرأ ولا يكتب — وكل «ممنوع» يتجاوز الواجهة إلى الـAPI بجلسة المستخدم نفسها.
import { expect, type Page, test } from "@playwright/test";
import { fx, go, staffLogin } from "./helpers";

const API = "http://127.0.0.1:8000";
const RUN = Date.now().toString(36).toUpperCase().slice(-5);

async function direct<T = unknown>(page: Page, method: string, path: string, body?: unknown): Promise<{ status: number; json: T }> {
  return page.evaluate(async ({ api, method, path, body }) => {
    const key = Object.keys(localStorage).find((k) => k.endsWith("-auth-token"))!;
    const token = JSON.parse(localStorage.getItem(key)!).access_token;
    const r = await fetch(api + path, {
      method, headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    return { status: r.status, json: await r.json().catch(() => null) };
  }, { api: API, method, path, body }) as Promise<{ status: number; json: T }>;
}

test("school admin assigns, replaces and ends; the teacher only reads", async ({ page, browser }) => {
  test.setTimeout(120_000);
  const sa = fx().schools.SA;
  const section = `ZTW-${RUN}`;
  const subject = `مادة ${RUN}`;
  await staffLogin(page, "school.admin@dev.smas.test");

  // التجهيز عبر الـAPI بجلسة المدير: سنة planned، شعبة، مادة مربوطة بصفها
  const grades = (await direct<{ rows: { id: string; status: string }[] }>(page, "GET", `/schools/${sa}/grade-levels`)).json.rows;
  const grade = grades.find((g) => g.status === "active")!.id;
  const n = 2070 + (Date.now() % 900);
  const year = (await direct<{ id: string }>(page, "POST", `/schools/${sa}/academic-years`, { name: `ZTW ${RUN}`, start_date: `${n}-09-01`, end_date: `${n + 1}-06-30` })).json.id;
  expect((await direct(page, "POST", `/academic-years/${year}/sections`, { grade_level_id: grade, name: section })).status).toBe(201);
  const subjectId = (await direct<{ id: string }>(page, "POST", `/schools/${sa}/subjects`, { subject_code: `ZTW-${RUN}`, name: subject })).json.id;
  expect((await direct(page, "POST", `/academic-years/${year}/grade-subjects`, { grade_level_id: grade, subject_id: subjectId, weekly_periods: 4 })).status).toBe(201);
  const staff = (await direct<{ rows: { id: string; full_name: string; status: string }[] }>(page, "GET", `/schools/${sa}/staff`)).json.rows.filter((s) => s.status === "active");
  const [first, second] = staff;

  await go(page, `/setup/schools/${sa}/years/${year}`);
  const teach = `slot-teach-${section}-${subject}`;
  const cls = `slot-class-${section}`;
  await expect(page.getByTestId(`${teach}-current`)).toHaveText("غير مكلَّف");

  // تكليف معلم بالمادة، ومربي فصل لا يدرّس الشعبة
  await page.getByTestId(`${teach}-staff`).selectOption(first.id);
  await page.getByTestId(`${teach}-submit`).click();
  await expect(page.getByTestId(`${teach}-current`)).toContainText(first.full_name);
  await page.getByTestId(`${cls}-staff`).selectOption(second.id);
  await page.getByTestId(`${cls}-submit`).click();
  await expect(page.getByTestId(`${cls}-current`)).toContainText(second.full_name);
  await expect(page.getByTestId(`${teach}-current`)).toHaveAttribute("data-operational", "true");

  // «نشط واحد»: تجاوز الواجهة بتكليف ثانٍ للمادة نفسها ← 409
  const section_id = (await direct<{ rows: { id: string; name: string }[] }>(page, "GET", `/academic-years/${year}/sections`)).json.rows.find((s) => s.name === section)!.id;
  expect((await direct(page, "POST", `/sections/${section_id}/teaching-assignments`, { subject_id: subjectId, staff_id: second.id })).status).toBe(409);

  // الاستبدال بسبب
  await page.getByTestId(`${teach}-staff`).selectOption(second.id);
  await page.getByTestId(`${teach}-reason`).fill("نقل المعلم");
  await page.getByTestId(`${teach}-submit`).click();
  await expect(page.getByTestId(`${teach}-current`)).toContainText(second.full_name);
  const history = (await direct<{ rows: { staff_id: string; status: string }[] }>(page, "GET", `/academic-years/${year}/teaching-assignments?section_id=${section_id}`)).json.rows;
  expect(history.map((h) => `${h.staff_id === first.id ? "first" : "second"}:${h.status}`).sort()).toEqual(["first:ended", "second:active"]);

  // الإنهاء بسبب
  await page.getByTestId(`${cls}-end`).click();
  await page.getByTestId(`${cls}-end-reason`).fill("تغيير المربي");
  await page.getByTestId(`${cls}-end-confirm`).click();
  await expect(page.getByTestId(`${cls}-current`)).toHaveText("غير مكلَّف");

  // المعلم: يرى البطاقة للقراءة، بلا أي تحكم كتابة، والخادم يرفض التجاوز
  const teacherPage = await (await browser.newContext()).newPage();
  await staffLogin(teacherPage, "teacher@dev.smas.test");
  await go(teacherPage, `/setup/schools/${sa}/years/${year}`);
  await expect(teacherPage.getByTestId(`${teach}-current`)).toContainText(second.full_name);
  await expect(teacherPage.getByTestId(`${teach}-submit`)).toHaveCount(0);
  await expect(teacherPage.getByTestId(`${teach}-end`)).toHaveCount(0);
  const active = history.find((h) => h.status === "active") as unknown as { id: string };
  expect((await direct(teacherPage, "POST", `/sections/${section_id}/class-teacher`, { staff_id: first.id })).status).toBe(403);
  expect((await direct(teacherPage, "POST", `/teaching-assignments/${active.id}/end`, { effective_to: `${n}-12-01`, reason: "x" })).status).toBe(403);
  // لا سياق من الجسم
  expect((await direct(page, "POST", `/sections/${section_id}/class-teacher`, { staff_id: first.id, school_id: fx().schools.SB })).status).toBe(422);
});

// 3-5 — النصاب: الحد يضعه مدير المدرسة، والتكليف فوقه **ينجح** ثم تظهر شارة التنبيه؛ المعلم لا يرى حدود زملائه.
test("workload: a limit is a warning — assigning above it succeeds and the badge appears; colleagues' limits stay hidden", async ({ page, browser }) => {
  test.setTimeout(120_000);
  const sa = fx().schools.SA;
  const section = `ZTV-${RUN}`;
  const subject = `نصاب ${RUN}`;
  await staffLogin(page, "school.admin@dev.smas.test");

  const grades = (await direct<{ rows: { id: string; status: string }[] }>(page, "GET", `/schools/${sa}/grade-levels`)).json.rows;
  const grade = grades.find((g) => g.status === "active")!.id;
  const n = 3000 + (Date.now() % 900);
  const year = (await direct<{ id: string }>(page, "POST", `/schools/${sa}/academic-years`, { name: `ZTV ${RUN}`, start_date: `${n}-09-01`, end_date: `${n + 1}-06-30` })).json.id;
  expect((await direct(page, "POST", `/academic-years/${year}/sections`, { grade_level_id: grade, name: section })).status).toBe(201);
  const subjectId = (await direct<{ id: string }>(page, "POST", `/schools/${sa}/subjects`, { subject_code: `ZTV-${RUN}`, name: subject })).json.id;
  expect((await direct(page, "POST", `/academic-years/${year}/grade-subjects`, { grade_level_id: grade, subject_id: subjectId, weekly_periods: 6 })).status).toBe(201);
  const staff = (await direct<{ rows: { id: string; full_name: string; status: string; employee_code: string }[] }>(page, "GET", `/schools/${sa}/staff`)).json.rows
    .filter((s) => s.status === "active" && s.employee_code !== "TEACHER");
  const target = staff[0];

  await go(page, `/setup/schools/${sa}/years/${year}`);
  await expect(page.getByTestId("load-empty")).toBeVisible();

  // الحد 4 (سنة planned: بلا سبب)
  await page.getByTestId("load-staff").selectOption(target.id);
  await page.getByTestId("load-max").fill("4");
  await page.getByTestId("load-save").click();
  await expect(page.getByTestId(`load-limit-${target.employee_code}`)).toHaveText("4");
  await expect(page.getByTestId(`load-periods-${target.employee_code}`)).toContainText("0");
  await expect(page.getByTestId(`load-over-${target.employee_code}`)).toHaveCount(0);

  // تكليف بـ6 حصص فوق الحد: ينجح، ثم الشارة
  const teach = `slot-teach-${section}-${subject}`;
  await page.getByTestId(`${teach}-staff`).selectOption(target.id);
  await page.getByTestId(`${teach}-submit`).click();
  await expect(page.getByTestId(`${teach}-current`)).toContainText(target.full_name);
  await expect(page.getByTestId(`load-periods-${target.employee_code}`)).toContainText("6");
  await expect(page.getByTestId(`load-over-${target.employee_code}`)).toBeVisible();

  // إزالة الحد (حقل فارغ = null): الشارة تختفي والتكليف باقٍ
  await page.getByTestId("load-staff").selectOption(target.id);
  await page.getByTestId("load-save").click();
  await expect(page.getByTestId(`load-limit-${target.employee_code}`)).toHaveText("بلا حد");
  await expect(page.getByTestId(`load-over-${target.employee_code}`)).toHaveCount(0);
  expect((await direct(page, "PUT", `/academic-years/${year}/teacher-load-limits/${target.id}`, { max_weekly_periods: 4 })).status).toBe(200);

  // المعلم: يرى نصاب زميله (من تكليفات يقرؤها) ولا يرى حدّه؛ لا نموذج كتابة؛ والخادم يرفض التجاوز
  const teacherPage = await (await browser.newContext()).newPage();
  await staffLogin(teacherPage, "teacher@dev.smas.test");
  await go(teacherPage, `/setup/schools/${sa}/years/${year}`);
  await expect(teacherPage.getByTestId(`load-periods-${target.employee_code}`)).toContainText("6");
  await expect(teacherPage.getByTestId(`load-limit-${target.employee_code}`)).toHaveText("—");
  await expect(teacherPage.getByTestId(`load-over-${target.employee_code}`)).toHaveCount(0);
  await expect(teacherPage.getByTestId("load-form")).toHaveCount(0);
  expect((await direct(teacherPage, "PUT", `/academic-years/${year}/teacher-load-limits/${target.id}`, { max_weekly_periods: 50 })).status).toBe(403);
  // لا سياق من الجسم
  expect((await direct(page, "PUT", `/academic-years/${year}/teacher-load-limits/${target.id}`, { max_weekly_periods: 9, school_id: fx().schools.SB })).status).toBe(422);
});
