// Phase 2A / P2-D — التنقل حسب المفاتيح، رسائل أخطاء الـAPI، ولوحة الجاهزية (تُعرض فقط حين يعيدها الـAPI).
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, Route, Routes } from "react-router";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Capabilities } from "./auth/AuthProvider";
import { navItems } from "./components/navigation";
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
import { School } from "./pages/setup/School";
import { Year } from "./pages/setup/Year";

const SCHOOL = { id: "s1", group_id: null, school_code: "ZT1", name: "ZT One", slug: "zt-one", timezone: "Africa/Cairo",
  status: "active", is_standalone: true, guardian_first_login_mode: "A" };

function route(path: string, responses: Record<string, unknown | ApiError>) {
  apiMock.api.mockImplementation(async (p: string, init?: { method?: string; body?: unknown }) => {
    const key = `${init?.method ?? "GET"} ${p}`;
    const r = key in responses ? responses[key] : responses[p];
    if (r instanceof ApiError) throw r;
    if (r === undefined) throw new ApiError(404, "not_found");
    return r;
  });
  return render(
    <MemoryRouter initialEntries={[path]}>
      <Routes>
        <Route path="/setup/schools/:id" element={<School />} />
        <Route path="/setup/schools/:schoolId/years/:yearId" element={<Year />} />
      </Routes>
    </MemoryRouter>,
  );
}

beforeEach(() => {
  apiMock.api.mockReset();
  auth.permissions = [];
});

describe("setup navigation (display only)", () => {
  const ids = (caps: Capabilities) => navItems(caps, "staff").map((i) => i.testId);
  it("staff who read years see school setup; group readers see groups", () => {
    expect(ids({ context: "tenant", permissions: ["school.read", "academic_year.read"] })).toContain("nav-schools");
    expect(ids({ context: "tenant", permissions: ["school.read", "academic_year.read", "group.read"] })).toContain("nav-groups");
  });
  it("guardian/student/bus supervisor (school.read only): no setup items", () => {
    expect(ids({ context: "tenant", permissions: ["school.read", "student.read"] })).not.toContain("nav-schools");
  });
  it("platform context: no setup items even with the same keys", () => {
    const items = ids({ context: "platform", permissions: ["school.read", "academic_year.read", "group.read"] });
    expect(items).not.toContain("nav-schools");
    expect(items).not.toContain("nav-groups");
  });
});

describe("API error codes are translated, never raw", () => {
  it.each(["conflict", "invalid_request", "invariant_violation", "invalid_reference", "forbidden", "not_found"])("%s", (code) => {
    const text = errorText(code);
    expect(text).not.toBe(t("error.generic"));
    expect(text).not.toMatch(/23\d{3}|violates|constraint|sql/i);
  });
  it("an unknown code falls back to the generic message", () => {
    expect(errorText("23P01 exclusion_violation")).toBe(t("error.generic"));
  });
});

describe("school page", () => {
  it("readiness is shown only when the API returns it", async () => {
    auth.permissions = ["school.read"];
    route("/setup/schools/s1", {
      "/schools": { rows: [SCHOOL] },
      "/schools/s1/readiness": new ApiError(403, "forbidden"),
      "/schools/s1/academic-years": new ApiError(403, "forbidden"),
      "/schools/s1/stages": new ApiError(403, "forbidden"),
      "/schools/s1/grade-levels": new ApiError(403, "forbidden"),
    });
    await screen.findByTestId("school");
    await waitFor(() => expect(apiMock.api).toHaveBeenCalledWith("/schools/s1/readiness"));
    expect(screen.queryByTestId("readiness")).toBeNull();
    expect(screen.queryByTestId("years")).toBeNull();
  });

  it("readiness panel reflects the API checks", async () => {
    auth.permissions = ["school.read", "academic_year.read"];
    route("/setup/schools/s1", {
      "/schools": { rows: [SCHOOL] },
      "/schools/s1/readiness": { ready: false, checks: { school_active: true, active_year: true, active_section: false } },
      "/schools/s1/academic-years": { rows: [] },
      "/schools/s1/stages": { rows: [] },
      "/schools/s1/grade-levels": { rows: [] },
    });
    expect(await screen.findByTestId("readiness-state")).toHaveAttribute("data-ready", "false");
    expect(screen.getByTestId("readiness-active_section")).toHaveAttribute("data-ok", "false");
  });

  it("a school outside the visible list is not found (no disclosure)", async () => {
    route("/setup/schools/other", { "/schools": { rows: [SCHOOL] } });
    expect(await screen.findByTestId("state-not-found")).toBeInTheDocument();
  });

  it("buttons follow the keys: no edit, slug, mode or archive without them", async () => {
    auth.permissions = ["school.read"];
    route("/setup/schools/s1", { "/schools": { rows: [SCHOOL] } });
    await screen.findByTestId("school");
    for (const id of ["school-edit-save", "school-slug", "guardian-mode", "school-archive"]) expect(screen.queryByTestId(id)).toBeNull();
  });

  it("subjects (2B-1): card only with subject.read; create sends code and name only", async () => {
    auth.permissions = ["school.read", "subject.read", "subject.manage"];
    route("/setup/schools/s1", { "/schools": { rows: [SCHOOL] }, "/schools/s1/subjects": { rows: [] }, "POST /schools/s1/subjects": {} });
    await userEvent.type(await screen.findByTestId("subject-code"), "ar");
    await userEvent.type(screen.getByTestId("subject-name"), "Arabic");
    await userEvent.click(screen.getByTestId("subject-submit"));
    await waitFor(() => expect(apiMock.api).toHaveBeenCalledWith("/schools/s1/subjects", { method: "POST", body: { subject_code: "AR", name: "Arabic" } }));
  });

  it("subjects (2B-1): no card and no request without subject.read", async () => {
    auth.permissions = ["school.read"];
    route("/setup/schools/s1", { "/schools": { rows: [SCHOOL] }, "/schools/s1/subjects": { rows: [] } });
    await screen.findByTestId("school");
    expect(screen.queryByTestId("subjects")).toBeNull();
    expect(apiMock.api).not.toHaveBeenCalledWith("/schools/s1/subjects");
  });

  it("a slug conflict shows the translated message, not the database error", async () => {
    auth.permissions = ["school.read", "school.update"];
    route("/setup/schools/s1", { "/schools": { rows: [SCHOOL] }, "POST /schools/s1/slug": new ApiError(409, "conflict") });
    await userEvent.type(await screen.findByTestId("slug-new"), "school-a");
    await userEvent.type(screen.getByTestId("slug-reason"), "r");
    await userEvent.click(screen.getByTestId("slug-submit"));
    expect(await screen.findByTestId("slug-error")).toHaveTextContent(errorText("conflict"));
    expect(apiMock.api).toHaveBeenCalledWith("/schools/s1/slug", { method: "POST", body: { slug: "school-a", reason: "r" } });
  });
});

describe("year page", () => {
  const years = { rows: [
    { id: "y1", name: "2030", start_date: "2030-09-01", end_date: "2031-06-30", status: "active" },
    { id: "y2", name: "2031", start_date: "2031-09-01", end_date: "2032-06-30", status: "planned" },
  ] };
  const empty = { rows: [] };

  it("an active year sends the name only and locks its dates (display; T10 decides)", async () => {
    auth.permissions = ["academic_year.update"];
    route("/setup/schools/s1/years/y1", { "/schools/s1/academic-years": years, "/academic-years/y1/terms": empty,
      "/academic-years/y1/sections": empty, "/schools/s1/grade-levels": empty, "PATCH /academic-years/y1": {} });
    expect(await screen.findByTestId("year-edit-start")).toBeDisabled();
    await userEvent.click(screen.getByTestId("year-edit-save"));
    await waitFor(() => expect(apiMock.api).toHaveBeenCalledWith("/academic-years/y1", { method: "PATCH", body: { name: "2030" } }));
  });

  it("copy sections: offered on a planned year, one call with source and reason, result shown", async () => {
    auth.permissions = ["section.manage"];
    route("/setup/schools/s1/years/y2", { "/schools/s1/academic-years": years, "/academic-years/y2/terms": empty,
      "/academic-years/y2/sections": empty, "/schools/s1/grade-levels": empty, "POST /academic-years/y2/copy-sections": { created: 3 } });
    await userEvent.selectOptions(await screen.findByTestId("copy-source"), "y1");
    await userEvent.type(screen.getByTestId("copy-reason"), "next year");
    await userEvent.click(screen.getByTestId("copy-submit"));
    expect(await screen.findByTestId("copy-result")).toHaveAttribute("data-created", "3");
    expect(apiMock.api).toHaveBeenCalledWith("/academic-years/y2/copy-sections", { method: "POST", body: { source_year_id: "y1", reason: "next year" } });
  });

  it("grade subjects (2B-1): copy offered on a planned year, one call, result shown", async () => {
    auth.permissions = ["subject.read", "subject.manage"];
    route("/setup/schools/s1/years/y2", { "/schools/s1/academic-years": years, "/academic-years/y2/terms": empty,
      "/academic-years/y2/sections": empty, "/schools/s1/grade-levels": empty, "/schools/s1/subjects": empty,
      "/academic-years/y2/grade-subjects": empty, "POST /academic-years/y2/copy-grade-subjects": { created: 4 } });
    await userEvent.selectOptions(await screen.findByTestId("gs-copy-source"), "y1");
    await userEvent.type(screen.getByTestId("gs-copy-reason"), "next year");
    await userEvent.click(screen.getByTestId("gs-copy-submit"));
    expect(await screen.findByTestId("gs-copy-result")).toHaveAttribute("data-created", "4");
    expect(apiMock.api).toHaveBeenCalledWith("/academic-years/y2/copy-grade-subjects", { method: "POST", body: { source_year_id: "y1", reason: "next year" } });
  });

  it("grade subjects (2B-1): read-only without subject.manage; a refused conflict shows the translated message", async () => {
    auth.permissions = ["subject.read"];
    const links = { rows: [{ id: "l1", grade_level_id: "g1", subject_id: "sub1", weekly_periods: 5, counts_toward_total: true, status: "active" }] };
    route("/setup/schools/s1/years/y2", { "/schools/s1/academic-years": years, "/academic-years/y2/terms": empty,
      "/academic-years/y2/sections": empty, "/schools/s1/grade-levels": { rows: [{ id: "g1", name: "G1", status: "active" }] },
      "/schools/s1/subjects": { rows: [{ id: "sub1", subject_code: "AR", name: "Arabic", status: "active" }] }, "/academic-years/y2/grade-subjects": links });
    expect(await screen.findByTestId("gs-periods-G1-AR")).toHaveTextContent("5");
    for (const id of ["gs-submit", "gs-toggle-G1-AR", "copy-grade-subjects"]) expect(screen.queryByTestId(id)).toBeNull();
  });

  it("grade subjects (2B-1): a server refusal (T13) is shown translated", async () => {
    auth.permissions = ["subject.read", "subject.manage"];
    const links = { rows: [{ id: "l1", grade_level_id: "g1", subject_id: "sub1", weekly_periods: 5, counts_toward_total: true, status: "inactive" }] };
    route("/setup/schools/s1/years/y2", { "/schools/s1/academic-years": years, "/academic-years/y2/terms": empty,
      "/academic-years/y2/sections": empty, "/schools/s1/grade-levels": { rows: [{ id: "g1", name: "G1", status: "active" }] },
      "/schools/s1/subjects": { rows: [{ id: "sub1", subject_code: "AR", name: "Arabic", status: "inactive" }] }, "/academic-years/y2/grade-subjects": links,
      "PATCH /grade-subjects/l1": new ApiError(422, "invariant_violation") });
    await userEvent.click(await screen.findByTestId("gs-toggle-G1-AR"));
    expect(await screen.findByTestId("grade-subjects-error")).toHaveTextContent(errorText("invariant_violation"));
    expect(apiMock.api).toHaveBeenCalledWith("/grade-subjects/l1", { method: "PATCH", body: { status: "active" } });
  });

  it("calendar (2B-2): a planned year's week is saved with one PUT carrying the days and the reason", async () => {
    auth.permissions = ["academic_year.read", "academic_year.update"];
    route("/setup/schools/s1/years/y2", { "/schools/s1/academic-years": years, "/academic-years/y2/terms": empty, "/academic-years/y2/sections": empty,
      "/schools/s1/grade-levels": empty, "/academic-years/y2/weekdays": empty, "/academic-years/y2/calendar-exceptions": empty,
      "PUT /academic-years/y2/weekdays": { changed: 2, rows: [] } });
    await userEvent.click(await screen.findByTestId("weekday-check-1"));
    await userEvent.click(screen.getByTestId("weekday-check-0"));
    await userEvent.type(screen.getByTestId("weekdays-reason"), "week");
    await userEvent.click(screen.getByTestId("weekdays-submit"));
    await waitFor(() => expect(apiMock.api).toHaveBeenCalledWith("/academic-years/y2/weekdays", { method: "PUT", body: { weekdays: [0, 1], reason: "week" } }));
  });

  it("calendar (2B-2): an active year's defined week is shown fixed (display; the DB decides)", async () => {
    auth.permissions = ["academic_year.read", "academic_year.update"];
    route("/setup/schools/s1/years/y1", { "/schools/s1/academic-years": years, "/academic-years/y1/terms": empty, "/academic-years/y1/sections": empty,
      "/schools/s1/grade-levels": empty, "/academic-years/y1/weekdays": { rows: [{ id: "w0", weekday: 0, status: "active" }] },
      "/academic-years/y1/calendar-exceptions": empty });
    expect(await screen.findByTestId("weekdays-fixed")).toBeInTheDocument();
    expect(screen.getByTestId("weekday-check-0")).toBeDisabled();
    expect(screen.queryByTestId("weekdays-submit")).toBeNull();
  });

  it("calendar (2B-2): an active year with no week can define it once (C2)", async () => {
    auth.permissions = ["academic_year.read", "academic_year.update"];
    route("/setup/schools/s1/years/y1", { "/schools/s1/academic-years": years, "/academic-years/y1/terms": empty, "/academic-years/y1/sections": empty,
      "/schools/s1/grade-levels": empty, "/academic-years/y1/weekdays": empty, "/academic-years/y1/calendar-exceptions": empty });
    expect(await screen.findByTestId("weekdays-submit")).toBeInTheDocument();
    expect(screen.getByTestId("weekday-check-3")).not.toBeDisabled();
  });

  it("calendar (2B-2): adding an exception sends the reason; a refusal is shown translated", async () => {
    auth.permissions = ["academic_year.read", "academic_year.update"];
    route("/setup/schools/s1/years/y1", { "/schools/s1/academic-years": years, "/academic-years/y1/terms": empty, "/academic-years/y1/sections": empty,
      "/schools/s1/grade-levels": empty, "/academic-years/y1/weekdays": empty, "/academic-years/y1/calendar-exceptions": empty,
      "POST /academic-years/y1/calendar-exceptions": new ApiError(422, "invariant_violation") });
    await userEvent.type(await screen.findByTestId("exception-name"), "Trip");
    await userEvent.type(screen.getByTestId("exception-start"), "2030-10-01");
    await userEvent.type(screen.getByTestId("exception-end"), "2030-10-02");
    await userEvent.type(screen.getByTestId("exception-reason"), "school trip");
    await userEvent.click(screen.getByTestId("exception-submit"));
    expect(await screen.findByTestId("calendar-exceptions-error")).toHaveTextContent(errorText("invariant_violation"));
    expect(apiMock.api).toHaveBeenCalledWith("/academic-years/y1/calendar-exceptions",
      { method: "POST", body: { kind: "holiday", name: "Trip", start_date: "2030-10-01", end_date: "2030-10-02", reason: "school trip" } });
  });

  it("calendar (2B-2): read-only without academic_year.update; month view marks school days, holidays and study days", async () => {
    auth.permissions = ["academic_year.read"];
    route("/setup/schools/s1/years/y1", { "/schools/s1/academic-years": years, "/academic-years/y1/terms": empty, "/academic-years/y1/sections": empty,
      "/schools/s1/grade-levels": empty, "/academic-years/y1/weekdays": { rows: [{ id: "w0", weekday: 0, status: "active" }] },
      "/academic-years/y1/calendar-exceptions": { rows: [
        { id: "h", kind: "holiday", name: "H", start_date: "2030-09-08", end_date: "2030-09-08", status: "active" },
        { id: "s", kind: "study_day", name: "S", start_date: "2030-09-13", end_date: "2030-09-13", status: "active" },
        { id: "c", kind: "holiday", name: "C", start_date: "2030-09-15", end_date: "2030-09-15", status: "cancelled" }] } });
    expect(await screen.findByTestId("month-day-2030-09-01")).toHaveAttribute("data-kind", "school");     // الأحد
    expect(screen.getByTestId("month-day-2030-09-02")).toHaveAttribute("data-kind", "rest");
    expect(screen.getByTestId("month-day-2030-09-08")).toHaveAttribute("data-kind", "holiday");
    expect(screen.getByTestId("month-day-2030-09-13")).toHaveAttribute("data-kind", "study_day");
    expect(screen.getByTestId("month-day-2030-09-15")).toHaveAttribute("data-kind", "school");            // عطلة ملغاة
    for (const id of ["weekdays-submit", "exception-submit", "exception-cancel-H", "copy-weekdays"]) expect(screen.queryByTestId(id)).toBeNull();
  });

  it("copy sections is not offered on an active year", async () => {
    auth.permissions = ["section.manage"];
    route("/setup/schools/s1/years/y1", { "/schools/s1/academic-years": years, "/academic-years/y1/terms": empty,
      "/academic-years/y1/sections": empty, "/schools/s1/grade-levels": empty });
    await screen.findByTestId("sections");
    expect(screen.queryByTestId("copy-sections")).toBeNull();
  });
});
