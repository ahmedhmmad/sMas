// F1.5 — الدخول بالمسارات الحقيقية (F2). الرسائل رموز الخادم مترجمة؛ الموقوف والمقفل والخاطئ رسالة واحدة (I1).
import { type FormEvent, useState } from "react";
import { Link, useNavigate } from "react-router";
import { useAuth } from "../auth/AuthProvider";
import {
  loginGuardianPassword, loginStaff, loginStudent, requestGuardianCode, verifyGuardianCode,
} from "../auth/loginFlows";
import { getSchoolContext, getTenantContext, setDevContext } from "../context/appContext";
import { errorText, t } from "../i18n";
import { ApiError } from "../lib/api";

type Tab = "staff" | "guardian" | "student";

export function Field(props: { id: string; labelKey: string; type?: string; value: string; onChange: (v: string) => void; autoComplete?: string }) {
  return (
    <label className="block" htmlFor={props.id}>
      <span className="mb-1 block text-sm text-slate-700">{t(props.labelKey)}</span>
      <input
        id={props.id}
        data-testid={props.id}
        type={props.type ?? "text"}
        autoComplete={props.autoComplete}
        value={props.value}
        onChange={(e) => props.onChange(e.target.value)}
        className="w-full rounded border border-slate-300 px-3 py-2"
      />
    </label>
  );
}

export function Submit({ labelKey, busy, testId }: { labelKey: string; busy: boolean; testId: string }) {
  return (
    <button type="submit" disabled={busy} data-testid={testId} className="w-full rounded bg-emerald-600 py-2 text-white disabled:opacity-50">
      {t(labelKey)}
    </button>
  );
}

export function useSubmit() {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const run = async (action: () => Promise<void>) => {
    setBusy(true);
    setError(null);
    try {
      await action();
    } catch (e) {
      setError(errorText(e instanceof ApiError ? e.code : "generic"));
    } finally {
      setBusy(false);
    }
  };
  return { busy, error, run, setError };
}

function StaffForm({ done }: { done: () => void }) {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const { busy, error, run } = useSubmit();
  const submit = (e: FormEvent) => {
    e.preventDefault();
    void run(async () => { await loginStaff(email, password); done(); });
  };
  return (
    <form onSubmit={submit} className="space-y-4" data-testid="form-staff">
      <Field id="staff-email" labelKey="login.email" type="email" autoComplete="username" value={email} onChange={setEmail} />
      <Field id="staff-password" labelKey="login.password" type="password" autoComplete="current-password" value={password} onChange={setPassword} />
      {error && <p role="alert" data-testid="login-error" className="text-red-700">{error}</p>}
      <Submit labelKey="login.submit" busy={busy} testId="staff-submit" />
    </form>
  );
}

function GuardianForm({ done }: { done: () => void }) {
  const [phone, setPhone] = useState("");
  const [code, setCode] = useState("");
  const [password, setPassword] = useState("");
  const [mode, setMode] = useState<"otp" | "password">("otp");
  const [sent, setSent] = useState(false);
  const { busy, error, run } = useSubmit();
  const submit = (e: FormEvent) => {
    e.preventDefault();
    if (mode === "password") void run(async () => { await loginGuardianPassword(phone, password); done(); });
    else if (!sent) void run(async () => { await requestGuardianCode(phone); setSent(true); });
    else void run(async () => { await verifyGuardianCode(phone, code); done(); });
  };
  return (
    <form onSubmit={submit} className="space-y-4" data-testid="form-guardian">
      <Field id="guardian-phone" labelKey="login.phone" type="tel" autoComplete="tel" value={phone} onChange={setPhone} />
      {mode === "otp" && sent && (
        <>
          <p data-testid="otp-sent" className="text-sm text-slate-600">{t("login.codeSent")}</p>
          <Field id="guardian-code" labelKey="login.code" autoComplete="one-time-code" value={code} onChange={setCode} />
        </>
      )}
      {mode === "password" && (
        <Field id="guardian-password" labelKey="login.password" type="password" autoComplete="current-password" value={password} onChange={setPassword} />
      )}
      {error && <p role="alert" data-testid="login-error" className="text-red-700">{error}</p>}
      <Submit labelKey={mode === "password" ? "login.submit" : sent ? "login.verify" : "login.sendCode"} busy={busy} testId="guardian-submit" />
      <button
        type="button"
        data-testid="guardian-mode"
        className="w-full text-sm text-emerald-700"
        onClick={() => { setMode(mode === "otp" ? "password" : "otp"); setSent(false); }}
      >
        {t(mode === "otp" ? "login.usePassword" : "login.useOtp")}
      </button>
    </form>
  );
}

function StudentForm({ done }: { done: () => void }) {
  const [identifier, setIdentifier] = useState("");
  const [password, setPassword] = useState("");
  const { busy, error, run } = useSubmit();
  const submit = (e: FormEvent) => {
    e.preventDefault();
    void run(async () => { await loginStudent(identifier, password); done(); });
  };
  return (
    <form onSubmit={submit} className="space-y-4" data-testid="form-student">
      <Field id="student-identifier" labelKey="login.identifier" autoComplete="username" value={identifier} onChange={setIdentifier} />
      <Field id="student-password" labelKey="login.password" type="password" autoComplete="current-password" value={password} onChange={setPassword} />
      {error && <p role="alert" data-testid="login-error" className="text-red-700">{error}</p>}
      <Submit labelKey="login.submit" busy={busy} testId="student-submit" />
    </form>
  );
}

// أداة تطوير مؤقتة (F3 يزيلها): سياق العرض وطلبات الدخول فقط
function DevContext() {
  const [tenant, setTenant] = useState(getTenantContext().code);
  const [school, setSchool] = useState(getSchoolContext().slug);
  return (
    <details className="mt-6 text-sm text-slate-500" data-testid="dev-context">
      <summary>{t("app.devContext")}</summary>
      <div className="mt-2 grid gap-2">
        <Field id="dev-tenant" labelKey="context.tenantCode" value={tenant} onChange={setTenant} />
        <Field id="dev-school" labelKey="context.schoolSlug" value={school} onChange={setSchool} />
        <button type="button" data-testid="dev-apply" className="rounded border px-3 py-1" onClick={() => setDevContext(tenant, school)}>
          {t("context.apply")}
        </button>
      </div>
    </details>
  );
}

export function Login() {
  const [tab, setTab] = useState<Tab>("staff");
  const { refresh, expired } = useAuth();
  const navigate = useNavigate();
  const done = () => void refresh().then(() => navigate("/", { replace: true }));
  const tabs: Tab[] = ["staff", "guardian", "student"];
  const labels: Record<Tab, string> = { staff: "login.tabStaff", guardian: "login.tabGuardian", student: "login.tabStudent" };
  return (
    <div className="mx-auto mt-16 max-w-sm rounded-lg bg-white p-6 shadow">
      <h1 className="mb-4 text-xl font-semibold">{t("login.title")}</h1>
      {expired && <p data-testid="session-expired" className="mb-4 text-amber-700">{t("login.expired")}</p>}
      <div role="tablist" className="mb-6 grid grid-cols-3 gap-1">
        {tabs.map((x) => (
          <button
            key={x} type="button" role="tab" aria-selected={tab === x} data-testid={`tab-${x}`}
            onClick={() => setTab(x)}
            className={`rounded py-2 ${tab === x ? "bg-emerald-600 text-white" : "bg-slate-100"}`}
          >
            {t(labels[x])}
          </button>
        ))}
      </div>
      {tab === "staff" && <StaffForm done={done} />}
      {tab === "guardian" && <GuardianForm done={done} />}
      {tab === "student" && <StudentForm done={done} />}
      <Link to="/login/admin" data-testid="admin-link" className="mt-6 block text-center text-sm text-slate-500">
        {t("login.admin")}
      </Link>
      <DevContext />
    </div>
  );
}
