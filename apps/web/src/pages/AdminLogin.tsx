// Platform Admin و tenant_admin: بريد حقيقي عبر Supabase Auth مباشرة (هوية أصلية — قرار tenant_admin المؤجل)
import { type FormEvent, useState } from "react";
import { Link } from "react-router";
import { useAuth } from "../auth/AuthProvider";
import { loginNative } from "../auth/loginFlows";
import { t } from "../i18n";
import { Field, Submit, useSubmit } from "./Login";

export function AdminLogin() {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const { busy, error, run } = useSubmit();
  const { refresh } = useAuth();
  const submit = (e: FormEvent) => {
    e.preventDefault();
    void run(async () => {
      await loginNative(email, password);
      await refresh();                                   // الحارس يوجّه حسب الحالة
    });
  };
  return (
    <div className="mx-auto mt-16 max-w-sm rounded-lg bg-white p-6 shadow">
      <h1 className="mb-4 text-xl font-semibold">{t("login.adminTitle")}</h1>
      <form onSubmit={submit} className="space-y-4" data-testid="form-admin">
        <Field id="admin-email" labelKey="login.email" type="email" autoComplete="username" value={email} onChange={setEmail} />
        <Field id="admin-password" labelKey="login.password" type="password" autoComplete="current-password" value={password} onChange={setPassword} />
        {error && <p role="alert" data-testid="login-error" className="text-red-700">{error}</p>}
        <Submit labelKey="login.submit" busy={busy} testId="admin-submit" />
      </form>
      <Link to="/login" className="mt-6 block text-center text-sm text-slate-500">{t("login.backToLogin")}</Link>
    </div>
  );
}
