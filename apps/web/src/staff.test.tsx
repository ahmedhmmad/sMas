// Phase 3A / 3-1 — ملف الموظف: الأزرار حسب المفاتيح (عرض فقط)، الطلبات بلا سياق ولا سلطة، الأخطاء بنصوص الفهرس.
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, Route, Routes } from "react-router";
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
import { School } from "./pages/setup/School";
import { StaffDetail, StaffList } from "./pages/setup/Staff";

const SCHOOL = { id: "s1", group_id: null, school_code: "ZT1", name: "ZT One", slug: "zt-one", timezone: "Africa/Cairo",
  status: "active", is_standalone: true, guardian_first_login_mode: "A" };
const STAFF = { id: "e1", employee_code: "E-1", first_name: "Sara", father_name: null, grandfather_name: null, family_name: "Nabil",
  full_name: "Sara Nabil", national_id: null, phone_e164: "+201000000001", email: "sara@example.test", gender: "female",
  birth_date: null, hire_date: null, status: "active", has_account: false };
const ROW = { id: "e1", employee_code: "E-1", full_name: "Sara Nabil", status: "active", has_account: false,
  assignment_id: "a1", job_title: "Teacher", is_primary: true, effective_from: "2026-09-01" };
const ASSIGNMENT = { id: "a1", school_id: "s1", job_title: "Teacher", is_primary: true, status: "active", effective_from: "2026-09-01", effective_to: null };

const calls = () => apiMock.api.mock.calls.map(([p, init]) => ({ path: p as string, method: (init?.method ?? "GET") as string, body: init?.body }));

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
        <Route path="/setup/schools/:schoolId/staff" element={<StaffList />} />
        <Route path="/setup/schools/:schoolId/staff/:staffId" element={<StaffDetail />} />
      </Routes>
    </MemoryRouter>,
  );
}

const detail = (extra: Record<string, unknown | ApiError> = {}) => ({
  "/staff/e1": STAFF,
  "/staff/e1/school-assignments": { rows: [ASSIGNMENT] },
  "/staff/e1/specialties": { rows: [{ id: "sp1", name: "Math", status: "active" }] },
  "/staff/e1/qualifications": { rows: [] },
  ...extra,
});

beforeEach(() => {
  apiMock.api.mockReset();
  auth.permissions = [];
});

describe("staff list", () => {
  it("the school page links to staff only with staff.read", async () => {
    auth.permissions = ["school.read"];
    route("/setup/schools/s1", { "/schools": { rows: [SCHOOL] } });
    await screen.findByTestId("school");
    expect(screen.queryByTestId("open-staff")).toBeNull();
  });

  it("lists the school's staff; no create form without staff.create + staff.assign", async () => {
    auth.permissions = ["staff.read"];
    route("/setup/schools/s1/staff", { "/schools/s1/staff": { rows: [ROW] } });
    expect(await screen.findByTestId("staff-row-E-1")).toHaveTextContent("Sara Nabil");
    expect(screen.queryByTestId("staff-create")).toBeNull();
  });

  it("create sends the person and first assignment only — no tenant, school or status in the body", async () => {
    auth.permissions = ["staff.read", "staff.create", "staff.assign"];
    route("/setup/schools/s1/staff", { "/schools/s1/staff": { rows: [] }, "POST /schools/s1/staff": STAFF, ...detail() });
    const user = userEvent.setup();
    await screen.findByTestId("staff-create");
    await user.type(screen.getByTestId("staff-new-code"), "E-1");
    await user.type(screen.getByTestId("staff-new-first_name"), "Sara");
    await user.type(screen.getByTestId("staff-new-family_name"), "Nabil");
    await user.type(screen.getByTestId("staff-new-job"), "Teacher");
    await user.click(screen.getByTestId("staff-new-submit"));
    await screen.findByTestId("staff-detail");
    const post = calls().find((c) => c.method === "POST")!;
    expect(post.path).toBe("/schools/s1/staff");
    expect(Object.keys(post.body as object).sort()).toEqual(["effective_from", "employee_code", "family_name", "first_name", "job_title"]);
  });

  it("a duplicate code shows the translated message, not the database error", async () => {
    auth.permissions = ["staff.read", "staff.create", "staff.assign"];
    route("/setup/schools/s1/staff", { "/schools/s1/staff": { rows: [] }, "POST /schools/s1/staff": new ApiError(409, "conflict") });
    const user = userEvent.setup();
    await screen.findByTestId("staff-create");
    await user.type(screen.getByTestId("staff-new-code"), "E-1");
    await user.type(screen.getByTestId("staff-new-first_name"), "S");
    await user.type(screen.getByTestId("staff-new-family_name"), "N");
    await user.type(screen.getByTestId("staff-new-job"), "T");
    await user.click(screen.getByTestId("staff-new-submit"));
    expect(await screen.findByTestId("staff-create-error")).toHaveTextContent(errorText("conflict"));
  });

  it("a school the session cannot see is not found", async () => {
    auth.permissions = ["staff.read"];
    route("/setup/schools/s9/staff", {});
    expect(await screen.findByText(t("state.notFound"))).toBeInTheDocument();
  });
});

describe("staff detail", () => {
  it("read-only with staff.read only (teacher — PD1): no edit, status, assignment or specialty actions", async () => {
    auth.permissions = ["staff.read"];
    route("/setup/schools/s1/staff/e1", detail());
    await screen.findByTestId("staff-detail");
    await screen.findByTestId("staff-specialty-Math");
    expect(screen.getByTestId("staff-view-email")).toHaveTextContent("sara@example.test");
    for (const id of ["staff-edit-save", "staff-status-card", "staff-specialty-add", "staff-specialty-toggle-Math", "staff-qualification-add",
                      "staff-assignment-end-a1"]) {
      expect(screen.queryByTestId(id)).toBeNull();
    }
  });

  it("edit sends only the changed fields", async () => {
    auth.permissions = ["staff.read", "staff.update"];
    route("/setup/schools/s1/staff/e1", detail({ "PATCH /staff/e1": STAFF }));
    const user = userEvent.setup();
    await screen.findByTestId("staff-person");
    await user.type(screen.getByTestId("staff-edit-father_name"), "Ali");
    await user.click(screen.getByTestId("staff-edit-save"));
    await waitFor(() => expect(calls().some((c) => c.method === "PATCH")).toBe(true));
    expect(calls().find((c) => c.method === "PATCH")!.body).toEqual({ father_name: "Ali" });
  });

  it("status change carries the reason; ending carries the date", async () => {
    auth.permissions = ["staff.read", "staff.update"];
    route("/setup/schools/s1/staff/e1", detail({ "POST /staff/e1/status": { id: "e1", status: "on_leave" } }));
    const user = userEvent.setup();
    await screen.findByTestId("staff-status-card");
    await user.click(screen.getByTestId("staff-leave"));
    await user.type(screen.getByTestId("staff-leave-reason"), "medical");
    await user.click(screen.getByTestId("staff-leave-confirm"));
    await waitFor(() => expect(calls().some((c) => c.path === "/staff/e1/status")).toBe(true));
    expect(calls().find((c) => c.path === "/staff/e1/status")!.body).toEqual({ status: "on_leave", reason: "medical" });
  });

  it("a refused transition is shown translated", async () => {
    auth.permissions = ["staff.read", "staff.update"];
    route("/setup/schools/s1/staff/e1", detail({ "POST /staff/e1/status": new ApiError(422, "invalid_request") }));
    const user = userEvent.setup();
    await screen.findByTestId("staff-status-card");
    await user.click(screen.getByTestId("staff-leave"));
    await user.type(screen.getByTestId("staff-leave-reason"), "x");
    await user.click(screen.getByTestId("staff-leave-confirm"));
    expect(await screen.findByTestId("staff-status-error")).toHaveTextContent(errorText("invalid_request"));
  });

  it("specialty add sends the name only; qualification add sends degree and field", async () => {
    auth.permissions = ["staff.read", "staff.update"];
    route("/setup/schools/s1/staff/e1", detail({ "POST /staff/e1/specialties": { id: "sp2" }, "POST /staff/e1/qualifications": { id: "q1" } }));
    const user = userEvent.setup();
    await screen.findByTestId("staff-specialties");
    await user.type(screen.getByTestId("staff-specialty-new"), "Physics");
    await user.click(screen.getByTestId("staff-specialty-add"));
    await waitFor(() => expect(calls().some((c) => c.path === "/staff/e1/specialties" && c.method === "POST")).toBe(true));
    expect(calls().find((c) => c.path === "/staff/e1/specialties" && c.method === "POST")!.body).toEqual({ name: "Physics" });
    await user.type(screen.getByTestId("staff-qualification-field"), "Education");
    await user.click(screen.getByTestId("staff-qualification-add"));
    await waitFor(() => expect(calls().some((c) => c.path === "/staff/e1/qualifications" && c.method === "POST")).toBe(true));
    expect(calls().find((c) => c.path === "/staff/e1/qualifications" && c.method === "POST")!.body).toEqual({ degree: "bachelor", field: "Education" });
  });

  it("ending a school assignment needs staff.assign and a reason", async () => {
    auth.permissions = ["staff.read", "staff.assign"];
    route("/setup/schools/s1/staff/e1", detail({ "POST /staff-assignments/a1/end": ASSIGNMENT }));
    const user = userEvent.setup();
    await screen.findByTestId("staff-assignment-a1");
    await user.click(screen.getByTestId("staff-assignment-end-a1"));
    await user.type(screen.getByTestId("staff-assignment-end-a1-reason"), "moved");
    await user.click(screen.getByTestId("staff-assignment-end-a1-confirm"));
    await waitFor(() => expect(calls().some((c) => c.path === "/staff-assignments/a1/end")).toBe(true));
    expect(Object.keys(calls().find((c) => c.path === "/staff-assignments/a1/end")!.body as object).sort()).toEqual(["effective_to", "reason"]);
  });

  it("a staff member outside the session's relationship is not found (no disclosure)", async () => {
    auth.permissions = ["staff.read", "staff.update"];
    route("/setup/schools/s1/staff/e9", {});
    expect(await screen.findByText(t("state.notFound"))).toBeInTheDocument();
  });
});

describe("staff access (3-2)", () => {
  const ROLES = { rows: [
    { id: "r-teacher", code: "teacher", name: "Teacher", assignable: true },
    { id: "r-ta", code: "tenant_admin", name: "Tenant admin", assignable: false },
  ] };
  const NONE = { has_account: false, email: "sara@example.test", membership_status: null, can_login: false, roles: [], scopes: [] };
  const READY = { has_account: true, email: "sara@example.test", membership_status: "active", can_login: true,
    roles: [{ id: "r-teacher", code: "teacher", name: "Teacher" }],
    scopes: [{ scope_type: "school", school_id: "s1", school_code: "ZT1", name: "ZT One" }] };
  const ADMIN = ["staff.read", "membership.read", "membership.create", "role.assign", "scope.assign"];

  it("no card and no request without membership.read (teacher, secretary)", async () => {
    auth.permissions = ["staff.read"];
    route("/setup/schools/s1/staff/e1", detail());
    await screen.findByTestId("staff-detail");
    await screen.findByTestId("staff-specialty-Math");
    expect(screen.queryByTestId("staff-access")).toBeNull();
    expect(calls().some((c) => c.path.includes("/access"))).toBe(false);
  });

  it("activation is one call: the school and staff are in the path, the body carries the role only", async () => {
    auth.permissions = ADMIN;
    route("/setup/schools/s1/staff/e1", detail({ "/staff/e1/access": NONE, "/staff/e1/access/assignable-roles": ROLES,
      "POST /schools/s1/staff/e1/account": READY }));
    const user = userEvent.setup();
    await screen.findByTestId("staff-access-none");
    await user.selectOptions(screen.getByTestId("staff-access-role"), "r-teacher");
    await user.click(screen.getByTestId("staff-access-activate"));
    await waitFor(() => expect(calls().some((c) => c.method === "POST")).toBe(true));
    const post = calls().find((c) => c.method === "POST")!;
    expect(post.path).toBe("/schools/s1/staff/e1/account");
    expect(post.body).toEqual({ role_id: "r-teacher" });
  });

  it("a role beyond the session's authority is offered disabled (display) — the server decides", async () => {
    auth.permissions = ADMIN;
    route("/setup/schools/s1/staff/e1", detail({ "/staff/e1/access": NONE, "/staff/e1/access/assignable-roles": ROLES }));
    await screen.findByTestId("staff-access-none");
    const select = await screen.findByTestId("staff-access-role");
    await waitFor(() => expect(select.querySelectorAll("option").length).toBe(3));
    const option = Array.from(select.querySelectorAll("option")).find((o) => o.value === "r-ta")!;
    expect(option.disabled).toBe(true);
  });

  it("without a registered email there is no activation form", async () => {
    auth.permissions = ADMIN;
    route("/setup/schools/s1/staff/e1", { ...detail({ "/staff/e1/access": { ...NONE, email: null }, "/staff/e1/access/assignable-roles": ROLES }),
      "/staff/e1": { ...STAFF, email: null } });
    expect(await screen.findByTestId("staff-access-email-needed")).toBeInTheDocument();
    expect(screen.queryByTestId("staff-access-activate")).toBeNull();
  });

  it("revoking a role sends the reason only; a T8 refusal is shown translated, never the keys", async () => {
    auth.permissions = ADMIN;
    route("/setup/schools/s1/staff/e1", detail({ "/staff/e1/access": READY, "/staff/e1/access/assignable-roles": ROLES,
      "POST /staff/e1/access/roles/r-teacher/revoke": new ApiError(403, "role_exceeds_authority") }));
    const user = userEvent.setup();
    expect(await screen.findByTestId("staff-access-ready")).toHaveAttribute("data-can-login", "true");
    expect(screen.getByTestId("staff-access-scope-ZT1")).toHaveTextContent("ZT One");
    await user.click(screen.getByTestId("staff-access-role-revoke-teacher"));
    await user.type(screen.getByTestId("staff-access-role-revoke-teacher-reason"), "left");
    await user.click(screen.getByTestId("staff-access-role-revoke-teacher-confirm"));
    const error = await screen.findByTestId("staff-access-error");
    expect(error).toHaveTextContent(errorText("role_exceeds_authority"));
    expect(error.textContent).not.toMatch(/T8|[a-z_]+\.[a-z_]+/);
    expect(calls().find((c) => c.path.endsWith("/revoke"))!.body).toEqual({ reason: "left" });
  });

  it("read-only with membership.read alone: no activate, grant or revoke controls", async () => {
    auth.permissions = ["staff.read", "membership.read"];
    route("/setup/schools/s1/staff/e1", detail({ "/staff/e1/access": READY }));
    await screen.findByTestId("staff-access-ready");
    for (const id of ["staff-access-role-revoke-teacher", "staff-access-scope-revoke", "staff-access-role-grant", "staff-access-scope-grant"]) {
      expect(screen.queryByTestId(id)).toBeNull();
    }
    expect(calls().some((c) => c.path.endsWith("/assignable-roles"))).toBe(false);
  });
});
