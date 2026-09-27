// D2 و D4 (A، C): الحساب مغلق حتى تغيير الكلمة؛ الواجهة تغيّرها بجلسة المستخدم ثم تطلب التفعيل المتحكَّم به.
// الفتح يقرره الخادم (activate_first_login) — لا الواجهة.
import { type FormEvent, useState } from "react";
import { useNavigate } from "react-router";
import { useAuth } from "../auth/AuthProvider";
import { changePasswordAndActivate } from "../auth/loginFlows";
import { t } from "../i18n";
import { Field, Submit, useSubmit } from "./Login";

export function ChangePassword() {
  const [password, setPassword] = useState("");
  const [confirm, setConfirm] = useState("");
  const { busy, error, run, setError } = useSubmit();
  const { refresh, logout } = useAuth();
  const navigate = useNavigate();
  const submit = (e: FormEvent) => {
    e.preventDefault();
    if (password !== confirm) {
      setError(t("password.mismatch"));
      return;
    }
    void run(async () => {
      await changePasswordAndActivate(password);
      await refresh();
      navigate("/", { replace: true });
    });
  };
  return (
    <div className="mx-auto mt-16 max-w-sm rounded-lg bg-white p-6 shadow" data-testid="change-password">
      <h1 className="mb-2 text-xl font-semibold">{t("password.title")}</h1>
      <p className="mb-4 text-sm text-slate-600">{t("password.hint")}</p>
      <form onSubmit={submit} className="space-y-4">
        <Field id="new-password" labelKey="password.new" type="password" autoComplete="new-password" value={password} onChange={setPassword} />
        <Field id="confirm-password" labelKey="password.confirm" type="password" autoComplete="new-password" value={confirm} onChange={setConfirm} />
        {error && <p role="alert" data-testid="password-error" className="text-red-700">{error}</p>}
        <Submit labelKey="password.submit" busy={busy} testId="password-submit" />
      </form>
      <button type="button" className="mt-4 w-full text-sm text-slate-500" onClick={() => void logout()}>{t("app.logout")}</button>
    </div>
  );
}
