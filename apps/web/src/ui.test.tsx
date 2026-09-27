// اختبارات المكونات الحساسة: التنقل حسب المفاتيح، الحارس، نماذج الدخول، OTP، تغيير كلمة المرور.
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { AuthStatus, Capabilities } from "./auth/AuthProvider";
import { navItems } from "./components/navigation";
import { t } from "./i18n";
import { ApiError } from "./lib/api";

const flows = vi.hoisted(() => ({
  loginStaff: vi.fn(), loginStudent: vi.fn(), requestGuardianCode: vi.fn(), verifyGuardianCode: vi.fn(),
  loginGuardianPassword: vi.fn(), loginNative: vi.fn(), changePasswordAndActivate: vi.fn(), logout: vi.fn(),
  accountKind: vi.fn(() => null),
}));
vi.mock("./auth/loginFlows", () => flows);

const auth = vi.hoisted(() => ({ state: { status: "anonymous" as AuthStatus, capabilities: { context: null, permissions: [] } as Capabilities } }));
vi.mock("./auth/AuthProvider", async (orig) => ({
  ...(await orig<typeof import("./auth/AuthProvider")>()),
  useAuth: () => ({
    ...auth.state, kind: null, userId: "u1", expired: false,
    refresh: vi.fn(async () => {}), logout: vi.fn(async () => {}),
    can: (p: string) => auth.state.capabilities.permissions.includes(p),
  }),
}));

import { AppRoutes } from "./App";
import { statusFor } from "./auth/AuthProvider";

const renderAt = (path: string) => render(<MemoryRouter initialEntries={[path]}><AppRoutes /></MemoryRouter>);

beforeEach(() => {
  Object.values(flows).forEach((f) => f.mockReset());
  auth.state = { status: "anonymous", capabilities: { context: null, permissions: [] } };
});

// ---------------- التنقل (عرض فقط) ----------------
describe("navigation by capabilities", () => {
  const tenant = (p: string[]): Capabilities => ({ context: "tenant", permissions: p });
  const ids = (caps: Capabilities, kind: Parameters<typeof navItems>[1] = "staff") => navItems(caps, kind).map((i) => i.testId);

  it("platform admin: tenants, no students", () => {
    expect(ids({ context: "platform", permissions: ["tenant.read", "school.read"] }, "native")).toEqual(["nav-dashboard", "nav-tenants"]);
  });
  it("staff with student.read: students", () => {
    expect(ids(tenant(["school.read", "student.read"]))).toEqual(["nav-dashboard", "nav-students"]);
  });
  it("bus_supervisor (no student.read): dashboard only", () => {
    expect(ids(tenant(["school.read", "profile.read"]))).toEqual(["nav-dashboard"]);
  });
  it("guardian and student labels", () => {
    expect(navItems(tenant(["student.read"]), "guardian")[1].labelKey).toBe("nav.myChildren");
    expect(navItems(tenant(["student.read"]), "student")[1].labelKey).toBe("nav.myProfile");
  });
  it("tenant.read in tenant context is not the platform menu", () => {
    expect(ids(tenant(["tenant.read", "student.read"]))).not.toContain("nav-tenants");
  });
  it("no context (pending/suspended): nothing beyond the dashboard", () => {
    expect(ids({ context: null, permissions: [] })).toEqual(["nav-dashboard"]);
  });
  it("status: pending for student/guardian, unavailable otherwise", () => {
    expect(statusFor({ context: null, permissions: [] }, "student")).toBe("pending");
    expect(statusFor({ context: null, permissions: [] }, "guardian")).toBe("pending");
    expect(statusFor({ context: null, permissions: [] }, "staff")).toBe("unavailable");
    expect(statusFor({ context: "tenant", permissions: [] }, "student")).toBe("ready");
  });
});

// ---------------- الحارس ----------------
describe("route guard", () => {
  it("anonymous → login", () => {
    renderAt("/students");
    expect(screen.getByTestId("form-staff")).toBeInTheDocument();
  });
  it("pending → forced password change, from any route", () => {
    auth.state = { status: "pending", capabilities: { context: null, permissions: [] } };
    renderAt("/students");
    expect(screen.getByTestId("change-password")).toBeInTheDocument();
  });
  it("unavailable → generic message (no reason disclosed)", () => {
    auth.state = { status: "unavailable", capabilities: { context: null, permissions: [] } };
    renderAt("/");
    expect(screen.getByTestId("state-unavailable")).toBeInTheDocument();
  });
  it("ready + unknown route → not found inside the shell", () => {
    auth.state = { status: "ready", capabilities: { context: "tenant", permissions: [] } };
    renderAt("/nope");
    expect(screen.getByTestId("state-not-found")).toBeInTheDocument();
    expect(screen.getByTestId("nav")).toBeInTheDocument();
  });
});

// ---------------- نماذج الدخول ----------------
describe("login forms", () => {
  it("staff: submits email + password; shows the server's code translated", async () => {
    flows.loginStaff.mockRejectedValueOnce(new ApiError(401, "invalid_credentials"));
    renderAt("/login");
    await userEvent.type(screen.getByTestId("staff-email"), "secretary@dev.smas.test");
    await userEvent.type(screen.getByTestId("staff-password"), "x");
    await userEvent.click(screen.getByTestId("staff-submit"));
    expect(flows.loginStaff).toHaveBeenCalledWith("secretary@dev.smas.test", "x");
    expect(await screen.findByTestId("login-error")).toHaveTextContent(t("error.invalid_credentials"));
  });

  it("rate limit (429) shows its own message", async () => {
    flows.loginStudent.mockRejectedValueOnce(new ApiError(429, "too_many_attempts"));
    renderAt("/login");
    await userEvent.click(screen.getByTestId("tab-student"));
    await userEvent.type(screen.getByTestId("student-identifier"), "TMP-2026-000001");
    await userEvent.type(screen.getByTestId("student-password"), "TMP-2026-000001");
    await userEvent.click(screen.getByTestId("student-submit"));
    expect(flows.loginStudent).toHaveBeenCalledWith("TMP-2026-000001", "TMP-2026-000001");
    expect(await screen.findByTestId("login-error")).toHaveTextContent(t("error.too_many_attempts"));
  });

  it("guardian OTP: send code → code field → verify", async () => {
    flows.requestGuardianCode.mockResolvedValueOnce(undefined);
    flows.verifyGuardianCode.mockResolvedValueOnce(undefined);
    renderAt("/login");
    await userEvent.click(screen.getByTestId("tab-guardian"));
    await userEvent.type(screen.getByTestId("guardian-phone"), "+201000000001");
    expect(screen.queryByTestId("guardian-code")).not.toBeInTheDocument();
    await userEvent.click(screen.getByTestId("guardian-submit"));
    expect(flows.requestGuardianCode).toHaveBeenCalledWith("+201000000001");
    expect(await screen.findByTestId("otp-sent")).toBeInTheDocument();
    await userEvent.type(screen.getByTestId("guardian-code"), "123456");
    await userEvent.click(screen.getByTestId("guardian-submit"));
    await waitFor(() => expect(flows.verifyGuardianCode).toHaveBeenCalledWith("+201000000001", "123456"));
  });

  it("guardian password mode after onboarding", async () => {
    flows.loginGuardianPassword.mockResolvedValueOnce(undefined);
    renderAt("/login");
    await userEvent.click(screen.getByTestId("tab-guardian"));
    await userEvent.click(screen.getByTestId("guardian-mode"));
    await userEvent.type(screen.getByTestId("guardian-phone"), "+201000000001");
    await userEvent.type(screen.getByTestId("guardian-password"), "Mine-1234");
    await userEvent.click(screen.getByTestId("guardian-submit"));
    await waitFor(() => expect(flows.loginGuardianPassword).toHaveBeenCalledWith("+201000000001", "Mine-1234"));
    expect(flows.requestGuardianCode).not.toHaveBeenCalled();
  });

  it("the login page never shows synthetic identities or tokens", () => {
    renderAt("/login");
    expect(document.body.textContent).not.toMatch(/smas\.invalid|token_hash|magiclink/);
  });
});

// ---------------- تغيير كلمة المرور ----------------
describe("forced password change", () => {
  beforeEach(() => { auth.state = { status: "pending", capabilities: { context: null, permissions: [] } }; });

  it("mismatch is caught before any call", async () => {
    renderAt("/password");
    await userEvent.type(screen.getByTestId("new-password"), "Mine-1234");
    await userEvent.type(screen.getByTestId("confirm-password"), "Mine-9999");
    await userEvent.click(screen.getByTestId("password-submit"));
    expect(screen.getByTestId("password-error")).toHaveTextContent(t("password.mismatch"));
    expect(flows.changePasswordAndActivate).not.toHaveBeenCalled();
  });

  it("weak/same password shows the translated server code", async () => {
    flows.changePasswordAndActivate.mockRejectedValueOnce(new ApiError(422, "weak_password"));
    renderAt("/password");
    await userEvent.type(screen.getByTestId("new-password"), "123");
    await userEvent.type(screen.getByTestId("confirm-password"), "123");
    await userEvent.click(screen.getByTestId("password-submit"));
    expect(await screen.findByTestId("password-error")).toHaveTextContent(t("error.weak_password"));
  });

  it("success changes then activates", async () => {
    flows.changePasswordAndActivate.mockResolvedValueOnce(undefined);
    renderAt("/password");
    await userEvent.type(screen.getByTestId("new-password"), "Mine-1234");
    await userEvent.type(screen.getByTestId("confirm-password"), "Mine-1234");
    await userEvent.click(screen.getByTestId("password-submit"));
    await waitFor(() => expect(flows.changePasswordAndActivate).toHaveBeenCalledWith("Mine-1234"));
  });
});
