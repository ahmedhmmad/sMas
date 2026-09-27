// AuthProvider: الحالة الأولى من INITIAL_SESSION، وانتهاء الجلسة (SIGNED_OUT بلا طلب المستخدم) مقابل الخروج الطوعي.
import { act, render, screen } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

type Listener = (event: string) => void;
const sb = vi.hoisted(() => ({
  listener: null as null | ((event: string) => void),
  session: null as null | { access_token: string; user: { id: string } },
}));
vi.mock("./lib/supabase", () => ({
  supabase: {
    auth: {
      getSession: async () => ({ data: { session: sb.session } }),
      onAuthStateChange: (fn: Listener) => { sb.listener = fn; return { data: { subscription: { unsubscribe: () => {} } } }; },
      signOut: async () => { sb.session = null; sb.listener?.("SIGNED_OUT"); },
    },
  },
}));
const apiMock = vi.hoisted(() => vi.fn());
vi.mock("./lib/api", () => ({ api: apiMock, ApiError: class extends Error {} }));
vi.mock("./auth/loginFlows", () => ({
  accountKind: () => "staff",
  logout: async () => { sb.session = null; sb.listener?.("SIGNED_OUT"); },
}));

import { AuthProvider, useAuth } from "./auth/AuthProvider";

function Probe() {
  const a = useAuth();
  return (
    <div>
      <span data-testid="status">{a.status}</span>
      <span data-testid="expired">{String(a.expired)}</span>
      <span data-testid="perms">{a.capabilities.permissions.join(",")}</span>
      <button type="button" data-testid="logout" onClick={() => void a.logout()} />
    </div>
  );
}

const renderProbe = () => render(<AuthProvider><Probe /></AuthProvider>);

beforeEach(() => {
  sb.listener = null;
  sb.session = { access_token: "t", user: { id: "u1" } };
  apiMock.mockReset().mockResolvedValue({ context: "tenant", permissions: ["student.read"] });
});

describe("AuthProvider", () => {
  it("loads capabilities on INITIAL_SESSION", async () => {
    renderProbe();
    await act(async () => sb.listener?.("INITIAL_SESSION"));
    expect(screen.getByTestId("status")).toHaveTextContent("ready");
    expect(screen.getByTestId("perms")).toHaveTextContent("student.read");
  });

  it("an unrequested SIGNED_OUT (expired / refresh failed) flags the session as expired", async () => {
    renderProbe();
    await act(async () => sb.listener?.("INITIAL_SESSION"));
    await act(async () => { sb.session = null; sb.listener?.("SIGNED_OUT"); });
    expect(screen.getByTestId("status")).toHaveTextContent("anonymous");
    expect(screen.getByTestId("expired")).toHaveTextContent("true");
    expect(screen.getByTestId("perms")).toHaveTextContent("");
  });

  it("a user logout is not reported as expiry", async () => {
    renderProbe();
    await act(async () => sb.listener?.("INITIAL_SESSION"));
    await act(async () => screen.getByTestId("logout").click());
    expect(screen.getByTestId("status")).toHaveTextContent("anonymous");
    expect(screen.getByTestId("expired")).toHaveTextContent("false");
  });

  it("a session without context for staff is 'unavailable' (generic, I1)", async () => {
    apiMock.mockResolvedValue({ context: null, permissions: [] });
    renderProbe();
    await act(async () => sb.listener?.("INITIAL_SESSION"));
    expect(screen.getByTestId("status")).toHaveTextContent("unavailable");
  });
});
