// F3: الواجهة حسب الـhost — host غير معروف لا يعرض دخولاً ولا يطلب شيئاً؛ المنصة دخول الإدارة وحده؛ الـTenant موظف
// فقط؛ المدرسة النماذج الثلاثة. عرض فقط — الخادم يرفض أي دخول خارج سياقه (pytest/E2E).
import { render, screen } from "@testing-library/react";
import { MemoryRouter } from "react-router";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { HostContext } from "./context/hostContext";

const host = vi.hoisted(() => ({ ctx: null as HostContext | null }));
vi.mock("./context/appContext", () => ({
  getHostContext: () => host.ctx,
  getTenantContext: () => (host.ctx && host.ctx.kind !== "platform" ? { label: host.ctx.tenant, source: "host" } : null),
  getSchoolContext: () => (host.ctx?.kind === "school" ? { slug: host.ctx.school, source: "host" } : null),
}));
vi.mock("./auth/AuthProvider", async (orig) => ({
  ...(await orig<typeof import("./auth/AuthProvider")>()),
  useAuth: () => ({ status: "anonymous", capabilities: { context: null, permissions: [] }, kind: null, userId: null,
                    expired: false, refresh: vi.fn(), logout: vi.fn(), can: () => false }),
}));

import { App, AppRoutes } from "./App";

const renderAt = (path: string) => render(<MemoryRouter initialEntries={[path]}><AppRoutes /></MemoryRouter>);
const tabs = () => screen.queryAllByRole("tab").map((x) => x.getAttribute("data-testid"));
let fetchSpy: ReturnType<typeof vi.spyOn>;

beforeEach(() => { fetchSpy = vi.spyOn(globalThis, "fetch"); });
afterEach(() => { fetchSpy.mockRestore(); });

describe("login by host (F3)", () => {
  it("unknown host: a static page, no login, no request to any server", () => {
    host.ctx = null;
    render(<App />);
    expect(screen.getByTestId("state-unknown-host")).toBeInTheDocument();
    expect(screen.queryByTestId("form-staff")).toBeNull();
    expect(screen.queryByTestId("form-admin")).toBeNull();
    expect(fetchSpy).not.toHaveBeenCalled();
  });

  it("platform host: /login is the admin login only", () => {
    host.ctx = { kind: "platform" };
    renderAt("/login");
    expect(screen.getByTestId("form-admin")).toBeInTheDocument();
    expect(tabs()).toEqual([]);
    expect(screen.queryByText(/./, { selector: "a[href='/login']" })).toBeNull();   // لا «عودة» إلى نموذج غير موجود
  });

  it("tenant host: staff only, and the host identifier is shown", () => {
    host.ctx = { kind: "tenant", tenant: "dev" };
    renderAt("/login");
    expect(tabs()).toEqual(["tab-staff"]);
    expect(screen.getByTestId("login-context")).toHaveTextContent("dev");
    expect(screen.getByTestId("admin-link")).toBeInTheDocument();
  });

  it("school host: staff, guardian and student, with the school identifier", () => {
    host.ctx = { kind: "school", tenant: "dev", school: "school-a" };
    renderAt("/login");
    expect(tabs()).toEqual(["tab-staff", "tab-guardian", "tab-student"]);
    expect(screen.getByTestId("login-context")).toHaveTextContent("school-a");
    expect(screen.getByTestId("login-context")).toHaveTextContent("dev");
  });
});
