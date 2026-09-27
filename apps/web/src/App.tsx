// المسارات. الحارس يوجّه حسب حالة الجلسة (عرض فقط) — كل صفحة تقرأ ما تسمح به RLS/FastAPI،
// فالمسار المكتوب يدوياً لا يمنح شيئاً (F1.4).
import { BrowserRouter, Navigate, Outlet, Route, Routes } from "react-router";
import { AuthProvider, useAuth } from "./auth/AuthProvider";
import { Layout } from "./components/Layout";
import { Loading, NotFound, Unavailable } from "./components/states";
import { AdminLogin } from "./pages/AdminLogin";
import { ChangePassword } from "./pages/ChangePassword";
import { Dashboard } from "./pages/Dashboard";
import { Login } from "./pages/Login";
import { PlatformTenants } from "./pages/PlatformTenants";
import { StudentDetail } from "./pages/StudentDetail";
import { Students } from "./pages/Students";

function Protected() {
  const { status } = useAuth();
  if (status === "loading") return <Loading />;
  if (status === "anonymous") return <Navigate to="/login" replace />;
  if (status === "pending") return <Navigate to="/password" replace />;
  if (status === "unavailable") return <Unavailable />;
  return (
    <Layout>
      <Outlet />
    </Layout>
  );
}

function PublicOnly({ children }: { children: React.ReactNode }) {
  const { status } = useAuth();
  if (status === "loading") return <Loading />;
  if (status === "ready") return <Navigate to="/" replace />;
  if (status === "pending") return <Navigate to="/password" replace />;
  return <>{children}</>;
}

function PendingOnly() {
  const { status } = useAuth();
  if (status === "loading") return <Loading />;
  if (status !== "pending") return <Navigate to="/" replace />;
  return <ChangePassword />;
}

export function AppRoutes() {
  return (
    <Routes>
      <Route path="/login" element={<PublicOnly><Login /></PublicOnly>} />
      <Route path="/login/admin" element={<PublicOnly><AdminLogin /></PublicOnly>} />
      <Route path="/password" element={<PendingOnly />} />
      <Route element={<Protected />}>
        <Route path="/" element={<Dashboard />} />
        <Route path="/students" element={<Students />} />
        <Route path="/students/:id" element={<StudentDetail />} />
        <Route path="/platform/tenants" element={<PlatformTenants />} />
        <Route path="*" element={<NotFound />} />
      </Route>
    </Routes>
  );
}

export function App() {
  return (
    <AuthProvider>
      <BrowserRouter>
        <AppRoutes />
      </BrowserRouter>
    </AuthProvider>
  );
}
