// Phase 2A — قائمة المدارس المرئية للجلسة (RLS) وإنشاء مدرسة. المجموعة تُختار من المجموعات المرئية؛
// الـTenant لا يُرسل أبداً (الخادم يشتقه).
import { useState } from "react";
import { Link } from "react-router";
import { useAuth } from "../../auth/AuthProvider";
import { t } from "../../i18n";
import { api } from "../../lib/api";
import { ActionError, buttonClass, Card, Field, inputClass, PageState, statusText, useAction, useApi } from "./common";

export type School = {
  id: string; group_id: string | null; school_code: string; name: string; slug: string; timezone: string;
  status: string; is_standalone: boolean; guardian_first_login_mode: string;
};
type Group = { id: string; group_code: string; name: string; status: string };

export function Schools() {
  const { can } = useAuth();
  const { data, failure, reload } = useApi<{ rows: School[] }>("/schools");
  const groups = useApi<{ rows: Group[] }>(can("school.create") && can("group.read") ? "/groups" : null);
  const action = useAction(reload);
  const blank = { school_code: "", name: "", slug: "", group_id: "" };
  const [form, setForm] = useState(blank);

  if (!data) return <PageState failure={failure} />;
  const activeGroups = (groups.data?.rows ?? []).filter((g) => g.status === "active");
  return (
    <section data-testid="schools">
      <h1 className="mb-4 text-2xl font-semibold">{t("setup.schools.title")}</h1>
      {can("school.create") && (
        <Card title={t("setup.schools.new")} testId="school-create">
          <form
            className="grid gap-3 sm:grid-cols-2"
            onSubmit={async (e) => {
              e.preventDefault();
              const body = { school_code: form.school_code, name: form.name, slug: form.slug, group_id: form.group_id || null };
              if (await action.run(() => api("/schools", { method: "POST", body }))) setForm(blank);
            }}
          >
            <Field label={t("setup.code")}>
              <input className={inputClass} data-testid="school-code" required pattern="[A-Z0-9][A-Z0-9_\-]{1,31}" value={form.school_code}
                onChange={(e) => setForm({ ...form, school_code: e.target.value.toUpperCase() })} />
            </Field>
            <Field label={t("setup.name")}>
              <input className={inputClass} data-testid="school-name" required value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} />
            </Field>
            <Field label={t("setup.schools.slug")}>
              <input className={inputClass} data-testid="school-slug" required dir="ltr" pattern="[a-z0-9][a-z0-9\-]{0,61}[a-z0-9]" value={form.slug}
                onChange={(e) => setForm({ ...form, slug: e.target.value.toLowerCase() })} />
            </Field>
            <Field label={t("setup.schools.group")}>
              <select className={inputClass} data-testid="school-group" value={form.group_id} onChange={(e) => setForm({ ...form, group_id: e.target.value })}>
                <option value="">{t("setup.schools.standalone")}</option>
                {activeGroups.map((g) => <option key={g.id} value={g.id}>{g.name}</option>)}
              </select>
            </Field>
            <div className="sm:col-span-2">
              <button type="submit" className={buttonClass} data-testid="school-submit" disabled={action.busy}>{t("setup.create")}</button>
            </div>
          </form>
        </Card>
      )}
      <ActionError code={action.error} />
      {data.rows.length === 0 ? (
        <p data-testid="schools-empty" className="text-slate-500">{t("setup.empty")}</p>
      ) : (
        <table className="w-full rounded bg-white shadow-sm">
          <thead>
            <tr className="border-b text-sm text-slate-500">
              <th className="p-2 text-start">{t("setup.code")}</th>
              <th className="p-2 text-start">{t("setup.name")}</th>
              <th className="p-2 text-start">{t("setup.schools.slug")}</th>
              <th className="p-2 text-start">{t("setup.status")}</th>
            </tr>
          </thead>
          <tbody>
            {data.rows.map((s) => (
              <tr key={s.id} className="border-b" data-testid={`school-row-${s.school_code}`}>
                <td className="p-2 font-mono text-sm">{s.school_code}</td>
                <td className="p-2"><Link className="text-emerald-700 underline" data-testid={`school-open-${s.school_code}`} to={`/setup/schools/${s.id}`}>{s.name}</Link></td>
                <td className="p-2 font-mono text-sm" dir="ltr">{s.slug}</td>
                <td className="p-2">{statusText(s.status)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </section>
  );
}
