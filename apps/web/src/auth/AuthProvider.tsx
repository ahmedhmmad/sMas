// حالة المصادقة في الواجهة — عرض فقط؛ القرار الأمني في الخادم وRLS.
//
//   loading      ← قراءة الجلسة
//   anonymous    ← بلا جلسة (أو انتهت: expired)
//   pending      ← جلسة بلا سياق لطالب/ولي أمر: تغيير كلمة المرور أولاً (D2، D4 A/C)
//   unavailable  ← جلسة بلا سياق لغيرهم (موقوف…) — رسالة عامة (I1: لا تمييز)
//   ready        ← سياق tenant أو platform + مفاتيح الصلاحيات (M28) لإظهار العناصر
import { createContext, type ReactNode, useCallback, useContext, useEffect, useRef, useState } from "react";
import { api } from "../lib/api";
import { supabase } from "../lib/supabase";
import { accountKind, type AccountKind, logout as doLogout } from "./loginFlows";

export type Capabilities = { context: "tenant" | "platform" | null; permissions: string[] };
export type AuthStatus = "loading" | "anonymous" | "pending" | "unavailable" | "ready";

type AuthState = {
  status: AuthStatus;
  capabilities: Capabilities;
  kind: AccountKind | null;
  userId: string | null;
  expired: boolean;
  refresh: () => Promise<void>;
  logout: () => Promise<void>;
  can: (permission: string) => boolean;
};

const EMPTY: Capabilities = { context: null, permissions: [] };
const AuthContext = createContext<AuthState | null>(null);

export function statusFor(caps: Capabilities, kind: AccountKind | null): AuthStatus {
  if (caps.context) return "ready";
  return kind === "student" || kind === "guardian" ? "pending" : "unavailable";
}

export function AuthProvider({ children }: { children: ReactNode }) {
  const [status, setStatus] = useState<AuthStatus>("loading");
  const [capabilities, setCapabilities] = useState<Capabilities>(EMPTY);
  const [userId, setUserId] = useState<string | null>(null);
  const [expired, setExpired] = useState(false);
  const explicitLogout = useRef(false);

  const load = useCallback(async () => {
    const { data } = await supabase.auth.getSession();
    if (!data.session) {
      setCapabilities(EMPTY);
      setUserId(null);
      setStatus("anonymous");
      return;
    }
    setUserId(data.session.user.id);
    try {
      const caps = await api<Capabilities>("/me/capabilities");
      setCapabilities(caps);
      setStatus(statusFor(caps, accountKind()));
    } catch {
      setCapabilities(EMPTY);
      setStatus("unavailable");
    }
  }, []);

  useEffect(() => {
    // INITIAL_SESSION يصل عند الاشتراك: تحميل الحالة الأولى من الحدث نفسه لا من جسم الـeffect
    const { data } = supabase.auth.onAuthStateChange((event) => {
      if (event === "INITIAL_SESSION") {
        void load();
      } else if (event === "SIGNED_OUT") {
        if (!explicitLogout.current) setExpired(true);          // انتهاء/فشل التجديد — لا خروج بطلب المستخدم
        explicitLogout.current = false;
        setCapabilities(EMPTY);
        setUserId(null);
        setStatus("anonymous");
      } else if (event === "SIGNED_IN") {
        setExpired(false);
        void load();
      }
    });
    return () => data.subscription.unsubscribe();
  }, [load]);

  const logout = useCallback(async () => {
    explicitLogout.current = true;
    await doLogout();
  }, []);

  const can = useCallback((permission: string) => capabilities.permissions.includes(permission), [capabilities]);

  return (
    <AuthContext.Provider value={{ status, capabilities, kind: accountKind(), userId, expired, refresh: load, logout, can }}>
      {children}
    </AuthContext.Provider>
  );
}

export function useAuth(): AuthState {
  const value = useContext(AuthContext);
  if (!value) throw new Error("useAuth outside AuthProvider");
  return value;
}
