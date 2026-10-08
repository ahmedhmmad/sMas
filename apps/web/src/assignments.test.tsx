// Phase 3A / 3-3 — بطاقة التكليفات: الأزرار بـstaff.assign (عرض فقط)، الطلبات بلا سياق، «معلَّق» من الخادم، الأخطاء مترجمة.
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { errorText, t } from "./i18n";

const apiMock = vi.hoisted(() => ({ api: vi.fn() }));
vi.mock("./lib/api", async (orig) => ({ ...(await orig<typeof import("./lib/api")>()), api: apiMock.api }));

const auth = vi.hoisted(() => ({ permissions: [] as string[] }));
vi.mock("./auth/AuthProvider", async (orig) => ({
  ...(await orig<typeof import("./auth/AuthProvider")>()),
  useAuth: () => ({ status: "ready", capabilities: { context: "tenant", permissions: auth.permissions }, kind: "staff",
    userId: "u1", expired: false, refresh: vi.fn(), logout: vi.fn(), can: (p: string) => auth.permissions.includes(p) }),
}));

import { ApiError } from "./lib/api";
import { Assignments } from "./pages/setup/Assignments";

const BASE: Record<string, unknown> = {
  "/academic-years/y1/sections": { rows: [
    { id: "sec1", grade_level_id: "g1", name: "A", status: "active" },
    { id: "sec2", grade_level_id: "g1", name: "Off", status: "inactive" },
  ] },
  "/academic-years/y1/grade-subjects": { rows: [
    { grade_level_id: "g1", subject_id: "ar", weekly_periods: 5, status: "active" },
    { grade_level_id: "g1", subject_id: "ma", weekly_periods: 4, status: "active" },
    { grade_level_id: "g1", subject_id: "old", weekly_periods: 1, status: "inactive" },
  ] },
  "/schools/s1/subjects": { rows: [
    { id: "ar", subject_code: "AR", name: "Arabic", status: "active" }, { id: "ma", subject_code: "MA", name: "Math", status: "active" },
    { id: "old", subject_code: "OLD", name: "Old", status: "inactive" },
  ] },
  "/schools/s1/staff": { rows: [
    { id: "e1", full_name: "Sara Nabil", status: "active" }, { id: "e2", full_name: "Omar Adel", status: "active" },
    { id: "e3", full_name: "On Leave", status: "on_leave" },
  ] },
  "/academic-years/y1/teaching-assignments?status=active": { rows: [
    { id: "t1", section_id: "sec1", subject_id: "ar", staff_id: "e1", staff_name: "Sara Nabil", effective_from: "2020-09-01", operational: true },
  ] },
  "/academic-years/y1/class-teachers?status=active": { rows: [] },
};
const READ = ["staff.read", "subject.read"];
const WRITE = [...READ, "staff.assign"];

const calls = () => apiMock.api.mock.calls.map(([p, init]) => ({ path: p as string, method: (init?.method ?? "GET") as string, body: init?.body }));

function mount(status: string, responses: Record<string, unknown | ApiError> = {}) {
  const all = { ...BASE, ...responses };
  apiMock.api.mockImplementation(async (p: string, init?: { method?: string }) => {
    const key = `${init?.method ?? "GET"} ${p}`;
    const r = key in all ? all[key] : all[p];
    if (r instanceof ApiError) throw r;
    if (r === undefined) throw new ApiError(404, "not_found");
    return r;
  });
  return render(<Assignments year={{ id: "y1", status }} schoolId="s1" />);
}

beforeEach(() => {
  apiMock.api.mockReset();
  auth.permissions = [];
});

describe("assignments card (3-3)", () => {
  it("lists active sections with their active grade subjects and the current teacher", async () => {
    auth.permissions = READ;
    mount("planned");
    expect(await screen.findByTestId("slot-teach-A-Arabic-current")).toHaveTextContent("Sara Nabil");
    expect(screen.getByTestId("slot-teach-A-Math-current")).toHaveTextContent(t("setup.assignments.unassigned"));
    expect(screen.getByTestId("slot-class-A-current")).toHaveTextContent(t("setup.assignments.unassigned"));
    expect(screen.queryByTestId("assign-section-Off")).toBeNull();          // شعبة معطَّلة
    expect(screen.queryByTestId("slot-teach-A-Old")).toBeNull();            // ربط معطَّل
  });

  it("read-only without staff.assign, and in a closed year even with it", async () => {
    auth.permissions = READ;
    const first = mount("planned");
    await screen.findByTestId("slot-class-A");
    expect(screen.queryByTestId("slot-class-A-submit")).toBeNull();
    first.unmount();
    auth.permissions = WRITE;
    mount("closed");
    await screen.findByTestId("slot-class-A");
    expect(screen.queryByTestId("slot-class-A-submit")).toBeNull();
    expect(screen.queryByTestId("slot-teach-A-Arabic-end")).toBeNull();
  });

  it("assign sends the subject and staff only — the section is in the path; staff on leave are not offered", async () => {
    auth.permissions = WRITE;
    mount("planned", { "POST /sections/sec1/teaching-assignments": { id: "t2" } });
    const user = userEvent.setup();
    const select = await screen.findByTestId("slot-teach-A-Math-staff");
    expect(Array.from(select.querySelectorAll("option")).map((o) => o.textContent)).not.toContain("On Leave");
    expect(screen.queryByTestId("slot-teach-A-Math-reason")).toBeNull();     // سنة planned: بلا سبب
    await user.selectOptions(select, "e2");
    await user.click(screen.getByTestId("slot-teach-A-Math-submit"));
    await waitFor(() => expect(calls().some((c) => c.method === "POST")).toBe(true));
    const post = calls().find((c) => c.method === "POST")!;
    expect(post.path).toBe("/sections/sec1/teaching-assignments");
    expect(post.body).toEqual({ subject_id: "ma", staff_id: "e2" });
  });

  it("an active year asks for a reason; the class teacher body has no subject", async () => {
    auth.permissions = WRITE;
    mount("active", { "POST /sections/sec1/class-teacher": { id: "c1" } });
    const user = userEvent.setup();
    await user.selectOptions(await screen.findByTestId("slot-class-A-staff"), "e2");
    await user.type(screen.getByTestId("slot-class-A-reason"), "mid-year");
    await user.click(screen.getByTestId("slot-class-A-submit"));
    await waitFor(() => expect(calls().some((c) => c.method === "POST")).toBe(true));
    expect(calls().find((c) => c.method === "POST")!.body).toEqual({ staff_id: "e2", reason: "mid-year" });
  });

  it("replace is one call with the new staff, a date and the reason; the current teacher is not offered", async () => {
    auth.permissions = WRITE;
    mount("planned", { "POST /teaching-assignments/t1/replace": { id: "t3" } });
    const user = userEvent.setup();
    const select = await screen.findByTestId("slot-teach-A-Arabic-staff");
    expect(Array.from(select.querySelectorAll("option")).map((o) => o.value)).not.toContain("e1");
    await user.selectOptions(select, "e2");
    await user.type(screen.getByTestId("slot-teach-A-Arabic-reason"), "transfer");
    await user.click(screen.getByTestId("slot-teach-A-Arabic-submit"));
    await waitFor(() => expect(calls().some((c) => c.path.endsWith("/replace"))).toBe(true));
    const body = calls().find((c) => c.path.endsWith("/replace"))!.body as Record<string, string>;
    expect(Object.keys(body).sort()).toEqual(["effective_from", "reason", "staff_id"]);
    expect([body.staff_id, body.reason]).toEqual(["e2", "transfer"]);
  });

  it("a lost race (409) and a guard refusal (422) are shown translated", async () => {
    auth.permissions = WRITE;
    mount("planned", { "POST /sections/sec1/teaching-assignments": new ApiError(409, "conflict") });
    const user = userEvent.setup();
    await user.selectOptions(await screen.findByTestId("slot-teach-A-Math-staff"), "e2");
    await user.click(screen.getByTestId("slot-teach-A-Math-submit"));
    expect(await screen.findByTestId("slot-teach-A-Math-error")).toHaveTextContent(errorText("conflict"));
  });

  it("a suspended assignment is marked from the server's flag", async () => {
    auth.permissions = READ;
    mount("planned", { "/academic-years/y1/teaching-assignments?status=active": { rows: [
      { id: "t1", section_id: "sec1", subject_id: "ar", staff_id: "e3", staff_name: "On Leave", effective_from: "2020-09-01", operational: false },
    ] } });
    const current = await screen.findByTestId("slot-teach-A-Arabic-current");
    expect(current).toHaveAttribute("data-operational", "false");
    expect(current).toHaveTextContent(t("setup.assignments.suspended"));
  });
});
