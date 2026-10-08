// Phase 3A / 3-4 — بطاقة «شعبي وموادي» في لوحة الموظف: لمن يقرأ الطلاب **بالتكليف وحده** (عرض فقط — القرار في RLS).
import { render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter } from "react-router";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { t } from "./i18n";

const apiMock = vi.hoisted(() => ({ api: vi.fn() }));
vi.mock("./lib/api", async (orig) => ({ ...(await orig<typeof import("./lib/api")>()), api: apiMock.api }));
vi.mock("./lib/supabase", () => ({
  supabase: { from: () => ({ select: () => ({ eq: () => ({ maybeSingle: async () => ({ data: { display_name: "Teacher Dev" } }) }) }) }) },
}));

const auth = vi.hoisted(() => ({ context: "tenant" as "tenant" | "platform", permissions: [] as string[] }));
vi.mock("./auth/AuthProvider", async (orig) => ({
  ...(await orig<typeof import("./auth/AuthProvider")>()),
  useAuth: () => ({ status: "ready", capabilities: { context: auth.context, permissions: auth.permissions }, kind: "staff",
    userId: "u1", expired: false, refresh: vi.fn(), logout: vi.fn(), can: (p: string) => auth.permissions.includes(p) }),
}));

import { Dashboard } from "./pages/Dashboard";

const TEACHER = ["school.read", "staff.read", "student.read_assigned", "enrollment.read_assigned"];
const mount = () => render(<MemoryRouter><Dashboard /></MemoryRouter>);

beforeEach(() => {
  apiMock.api.mockReset();
  auth.context = "tenant";
  auth.permissions = [];
});

describe("my sections and subjects (3-4)", () => {
  it("lists the operational assignments the server returns: subject for teaching, a label for the class teacher", async () => {
    auth.permissions = TEACHER;
    apiMock.api.mockResolvedValue({ rows: [
      { kind: "teaching", id: "t1", school_name: "School A", academic_year_name: "2026/2027", section_name: "A", grade_level_name: "Grade 1", subject_name: "Mathematics" },
      { kind: "class_teacher", id: "c1", school_name: null, academic_year_name: "2026/2027", section_name: "B", grade_level_name: "Grade 2", subject_name: null },
    ] });
    mount();
    expect(await screen.findByTestId("my-teaching-t1")).toHaveTextContent("Grade 1 / A — Mathematics");
    expect(screen.getByTestId("my-teaching-t1")).toHaveTextContent("School A");
    expect(screen.getByTestId("my-teaching-c1")).toHaveTextContent(`Grade 2 / B — ${t("dashboard.classTeacher")}`);
    expect(apiMock.api.mock.calls.map(([p]) => p)).toEqual(["/me/teaching"]);       // طلب واحد بلا سياق ولا معرّفات
    expect(screen.getByTestId("card-nav-students")).toBeInTheDocument();            // والقائمة نفسها بالمفتاح الجديد
  });

  it("no assignment: says so — the teacher will see no student", async () => {
    auth.permissions = TEACHER;
    apiMock.api.mockResolvedValue({ rows: [] });
    mount();
    expect(await screen.findByTestId("my-teaching-empty")).toHaveTextContent(t("dashboard.myTeachingEmpty"));
  });

  it("a failed request shows the empty card, not an error page", async () => {
    auth.permissions = TEACHER;
    apiMock.api.mockRejectedValue(new Error("down"));
    mount();
    expect(await screen.findByTestId("my-teaching-empty")).toBeInTheDocument();
  });

  it("not shown — and not requested — for wide readers, for those without the key, or on the platform", async () => {
    for (const [context, permissions] of [
      ["tenant", ["school.read", "student.read", "student.read_assigned", "staff.read"]],      // المدير (N4): يملك المفتاحين
      ["tenant", ["school.read", "profile.read"]],                                             // بلا المفتاح
      ["platform", ["tenant.read", "student.read_assigned"]],
    ] as const) {
      auth.context = context;
      auth.permissions = [...permissions];
      const view = mount();
      await waitFor(() => expect(screen.getByTestId("dashboard")).toBeInTheDocument());
      expect(screen.queryByTestId("my-teaching")).toBeNull();
      view.unmount();
    }
    expect(apiMock.api).not.toHaveBeenCalled();
  });
});
