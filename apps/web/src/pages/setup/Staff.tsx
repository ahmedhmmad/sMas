// Phase 3A / 3-1 — ملف الموظف: قائمة موظفي المدرسة، الإنشاء، البيانات، الحالة، تكليفات المدارس، التخصصات، المؤهلات.
// لا تفويض هنا: الموظف يُرى بالعلاقة (تكليف نشط — H2) والقرار في الخادم وقاعدة البيانات؛ الأزرار تُخفى حسب المفاتيح (عرض فقط).
import { useState } from "react";
import { Link, useNavigate, useParams } from "react-router";
import { useAuth } from "../../auth/AuthProvider";
import { t } from "../../i18n";
import { api } from "../../lib/api";
import { ActionError, buttonClass, Card, Field, inputClass, linkButtonClass, PageState, ReasonAction, statusText, useAction, useApi } from "./common";

type StaffRow = {
  id: string; employee_code: string; full_name: string; status: string; has_account: boolean;
  assignment_id: string; job_title: string; is_primary: boolean; effective_from: string;
};
export type Staff = {
  id: string; employee_code: string; first_name: string; father_name: string | null; grandfather_name: string | null;
  family_name: string; full_name: string; national_id: string | null; phone_e164: string | null; email: string | null;
  gender: string | null; birth_date: string | null; hire_date: string | null; status: string; has_account: boolean;
};
type Assignment = { id: string; school_id: string; job_title: string; is_primary: boolean; status: string; effective_from: string; effective_to: string | null };
type Specialty = { id: string; name: string; status: string };
type Qualification = { id: string; degree: string; field: string; institution: string | null; graduation_year: number | null; status: string };

const PERSON_FIELDS = ["first_name", "father_name", "grandfather_name", "family_name", "national_id", "phone_e164", "email"] as const;
const DEGREES = ["diploma", "bachelor", "higher_diploma", "master", "doctorate", "other"];
const E164 = "\\+[1-9][0-9]{7,14}";   // عرض فقط (يمنع إرسال قيمة سيرفضها الخادم) — الخادم و CHECK هما الحكم
const today = () => new Date().toISOString().slice(0, 10);
// الحقول الفارغة لا تُرسل (الخادم يرفض النص الفارغ)؛ لا سياق ولا سلطة في الجسم
const compact = (o: Record<string, string>) => Object.fromEntries(Object.entries(o).filter(([, v]) => v.trim() !== ""));

export const staffStatusText = (status: string) => t(`setup.staff.statusLabel.${status}`);

// ------------------------------------------------------------------ القائمة
export function StaffList() {
  const { schoolId } = useParams();
  const { can } = useAuth();
  const navigate = useNavigate();
  const { data, failure, reload } = useApi<{ rows: StaffRow[] }>(`/schools/${schoolId}/staff`);
  const action = useAction(reload);
  const blank = { employee_code: "", first_name: "", father_name: "", grandfather_name: "", family_name: "", job_title: "", email: "", phone_e164: "", effective_from: today() };
  const [form, setForm] = useState(blank);

  if (!data) return <PageState failure={failure} />;
  return (
    <section data-testid="staff-list">
      <Link to={`/setup/schools/${schoolId}`} className={linkButtonClass}>{t("setup.back")}</Link>
      <h1 className="mb-4 mt-2 text-2xl font-semibold">{t("setup.staff.title")}</h1>
      {can("staff.create") && can("staff.assign") && (
        <Card title={t("setup.staff.new")} testId="staff-create">
          <form
            className="grid gap-3 sm:grid-cols-3 sm:items-end"
            onSubmit={async (e) => {
              e.preventDefault();
              let created: Staff | null = null;
              const ok = await action.run(async () => {
                created = await api<Staff>(`/schools/${schoolId}/staff`, { method: "POST", body: compact(form) });
              });
              if (ok && created) navigate(`/setup/schools/${schoolId}/staff/${(created as Staff).id}`);
            }}
          >
            <Field label={t("setup.staff.employeeCode")}>
              <input className={inputClass} data-testid="staff-new-code" dir="ltr" required maxLength={32} value={form.employee_code} onChange={(e) => setForm({ ...form, employee_code: e.target.value })} />
            </Field>
            {(["first_name", "father_name", "grandfather_name", "family_name"] as const).map((k) => (
              <Field key={k} label={t(`setup.staff.fields.${k}`)}>
                <input className={inputClass} data-testid={`staff-new-${k}`} required={k === "first_name" || k === "family_name"} maxLength={100}
                  value={form[k]} onChange={(e) => setForm({ ...form, [k]: e.target.value })} />
              </Field>
            ))}
            <Field label={t("setup.staff.jobTitle")}>
              <input className={inputClass} data-testid="staff-new-job" required maxLength={100} value={form.job_title} onChange={(e) => setForm({ ...form, job_title: e.target.value })} />
            </Field>
            <Field label={t("setup.staff.fields.email")}>
              <input className={inputClass} data-testid="staff-new-email" type="email" dir="ltr" value={form.email} onChange={(e) => setForm({ ...form, email: e.target.value })} />
            </Field>
            <Field label={t("setup.staff.fields.phone_e164")}>
              <input className={inputClass} data-testid="staff-new-phone" dir="ltr" placeholder="+20…" pattern={E164} value={form.phone_e164} onChange={(e) => setForm({ ...form, phone_e164: e.target.value })} />
            </Field>
            <Field label={t("setup.staff.effectiveFrom")}>
              <input className={inputClass} data-testid="staff-new-from" type="date" required value={form.effective_from} onChange={(e) => setForm({ ...form, effective_from: e.target.value })} />
            </Field>
            <button type="submit" className={buttonClass} data-testid="staff-new-submit" disabled={action.busy}>{t("setup.create")}</button>
          </form>
          <ActionError code={action.error} testId="staff-create-error" />
        </Card>
      )}
      {data.rows.length === 0 ? (
        <p data-testid="staff-empty" className="text-slate-500">{t("setup.empty")}</p>
      ) : (
        <ul className="divide-y rounded bg-white shadow-sm">
          {data.rows.map((s) => (
            <li key={s.id} data-testid={`staff-row-${s.employee_code}`} className="flex flex-wrap items-center gap-4 p-3">
              <span className="font-mono text-sm" dir="ltr">{s.employee_code}</span>
              <Link to={`/setup/schools/${schoolId}/staff/${s.id}`} className="flex-1 text-emerald-700 underline" data-testid={`staff-open-${s.employee_code}`}>{s.full_name}</Link>
              <span className="text-sm text-slate-600">{s.job_title}</span>
              <span className="text-sm text-slate-500" data-testid={`staff-status-${s.employee_code}`}>{staffStatusText(s.status)}</span>
              <span className="text-sm text-slate-500">{t(s.has_account ? "setup.staff.hasAccount" : "setup.staff.noAccount")}</span>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}

// ------------------------------------------------------------------ الموظف
export function StaffDetail() {
  const { schoolId, staffId } = useParams();
  const { data, failure, reload } = useApi<Staff>(`/staff/${staffId}`);
  if (!data) return <PageState failure={failure} />;
  return (
    <section data-testid="staff-detail">
      <Link to={`/setup/schools/${schoolId}/staff`} className={linkButtonClass}>{t("setup.back")}</Link>
      <h1 className="mb-1 mt-2 text-2xl font-semibold" data-testid="staff-title">{data.full_name}</h1>
      <p className="mb-4 text-sm text-slate-500">
        <span className="font-mono" dir="ltr">{data.employee_code}</span> · <span data-testid="staff-status">{staffStatusText(data.status)}</span>
      </p>
      <PersonCard staff={data} reload={reload} />
      <StatusCard staff={data} reload={reload} />
      <AccessCard staff={data} schoolId={schoolId!} />
      <AssignmentsCard staffId={data.id} />
      <SpecialtiesCard staffId={data.id} />
      <QualificationsCard staffId={data.id} />
    </section>
  );
}

function PersonCard({ staff, reload }: { staff: Staff; reload: () => void }) {
  const { can } = useAuth();
  const action = useAction(reload);
  const initial = Object.fromEntries(PERSON_FIELDS.map((k) => [k, staff[k] ?? ""])) as Record<(typeof PERSON_FIELDS)[number], string>;
  const [form, setForm] = useState(initial);
  const editable = can("staff.update") && (staff.status === "active" || staff.status === "on_leave");
  // يرسل ما تغيّر فقط؛ الحقل الذي فُرّغ لا يُمسح (لا نص فارغ في DB) — المسح قرار لاحق
  const changes = Object.fromEntries(PERSON_FIELDS.filter((k) => form[k].trim() !== "" && form[k] !== (staff[k] ?? "")).map((k) => [k, form[k].trim()]));
  return (
    <Card title={t("setup.staff.person")} testId="staff-person">
      {editable ? (
        <form
          className="grid gap-3 sm:grid-cols-3 sm:items-end"
          onSubmit={(e) => { e.preventDefault(); void action.run(() => api(`/staff/${staff.id}`, { method: "PATCH", body: changes })); }}
        >
          {PERSON_FIELDS.map((k) => (
            <Field key={k} label={t(`setup.staff.fields.${k}`)}>
              <input className={inputClass} data-testid={`staff-edit-${k}`} pattern={k === "phone_e164" ? E164 : undefined} dir={k === "email" || k === "phone_e164" || k === "national_id" ? "ltr" : undefined}
                value={form[k]} onChange={(e) => setForm({ ...form, [k]: e.target.value })} />
            </Field>
          ))}
          <button type="submit" className={buttonClass} data-testid="staff-edit-save" disabled={action.busy || Object.keys(changes).length === 0}>{t("setup.save")}</button>
        </form>
      ) : (
        <dl className="grid gap-2 text-sm sm:grid-cols-3">
          {PERSON_FIELDS.map((k) => (
            <div key={k}><dt className="text-slate-500">{t(`setup.staff.fields.${k}`)}</dt><dd data-testid={`staff-view-${k}`}>{staff[k] ?? "—"}</dd></div>
          ))}
        </dl>
      )}
      <ActionError code={action.error} testId="staff-person-error" />
    </Card>
  );
}

function StatusCard({ staff, reload }: { staff: Staff; reload: () => void }) {
  const { can } = useAuth();
  const navigate = useNavigate();
  const { schoolId } = useParams();
  const action = useAction(reload);
  const [endDate, setEndDate] = useState(today());
  if (!can("staff.update")) return null;
  const move = (status: string, extra: Record<string, string> = {}) => (reason: string) =>
    action.run(() => api(`/staff/${staff.id}/status`, { method: "POST", body: { status, reason, ...extra } }));
  return (
    <Card title={t("setup.staff.statusTitle")} testId="staff-status-card">
      <div className="flex flex-wrap items-end gap-4">
        {staff.status === "active" && (
          <ReasonAction label={t("setup.staff.toLeave")} testId="staff-leave" busy={action.busy} onConfirm={move("on_leave")} />
        )}
        {staff.status === "on_leave" && (
          <ReasonAction label={t("setup.staff.toActive")} testId="staff-back" busy={action.busy} onConfirm={move("active")} />
        )}
        {(staff.status === "active" || staff.status === "on_leave") && (
          <div className="flex flex-wrap items-end gap-2">
            <Field label={t("setup.staff.effectiveTo")}>
              <input className={inputClass} type="date" data-testid="staff-end-date" value={endDate} onChange={(e) => setEndDate(e.target.value)} />
            </Field>
            <ReasonAction label={t("setup.staff.toEnded")} testId="staff-end" busy={action.busy}
              onConfirm={async (reason) => {
                // بعد الإنهاء قد لا يبقى الموظف مرئياً (H2) — العودة إلى القائمة
                const ok = await move("ended", { effective_to: endDate })(reason);
                if (ok) navigate(`/setup/schools/${schoolId}/staff`);
                return ok;
              }} />
          </div>
        )}
      </div>
      <ActionError code={action.error} testId="staff-status-error" />
    </Card>
  );
}

function AssignmentsCard({ staffId }: { staffId: string }) {
  const { can } = useAuth();
  const { data, failure, reload } = useApi<{ rows: Assignment[] }>(`/staff/${staffId}/school-assignments`);
  const action = useAction(reload);
  const [endDate, setEndDate] = useState(today());
  if (!data) return failure ? null : <PageState failure={null} />;
  return (
    <Card title={t("setup.staff.assignments")} testId="staff-assignments">
      <ul className="divide-y text-sm">
        {data.rows.map((a) => (
          <li key={a.id} data-testid={`staff-assignment-${a.id}`} className="flex flex-wrap items-center gap-3 py-2">
            <span className="flex-1">{a.job_title}{a.is_primary ? ` · ${t("setup.staff.primary")}` : ""}</span>
            <span className="text-slate-500" dir="ltr">{a.effective_from} → {a.effective_to ?? "…"}</span>
            <span className="text-slate-500" data-testid={`staff-assignment-status-${a.id}`}>{staffStatusText(a.status)}</span>
            {can("staff.assign") && a.status === "active" && (
              <div className="flex flex-wrap items-end gap-2">
                <input className={inputClass} type="date" data-testid={`staff-assignment-end-date-${a.id}`} value={endDate} onChange={(e) => setEndDate(e.target.value)} />
                <ReasonAction label={t("setup.staff.endAssignment")} testId={`staff-assignment-end-${a.id}`} busy={action.busy}
                  onConfirm={(reason) => action.run(() => api(`/staff-assignments/${a.id}/end`, { method: "POST", body: { effective_to: endDate, reason } }))} />
              </div>
            )}
          </li>
        ))}
      </ul>
      <ActionError code={action.error} testId="staff-assignment-error" />
    </Card>
  );
}

function SpecialtiesCard({ staffId }: { staffId: string }) {
  const { can } = useAuth();
  const { data, reload } = useApi<{ rows: Specialty[] }>(`/staff/${staffId}/specialties`);
  const action = useAction(reload);
  const [name, setName] = useState("");
  if (!data) return null;
  return (
    <Card title={t("setup.staff.specialties")} testId="staff-specialties">
      {data.rows.length === 0 && <p className="text-sm text-slate-500" data-testid="staff-specialties-empty">{t("setup.empty")}</p>}
      <ul className="divide-y text-sm">
        {data.rows.map((s) => (
          <li key={s.id} data-testid={`staff-specialty-${s.name}`} className="flex items-center gap-3 py-2">
            <span className="flex-1">{s.name}</span>
            <span className="text-slate-500" data-testid={`staff-specialty-status-${s.name}`}>{statusText(s.status)}</span>
            {can("staff.update") && (
              <button type="button" className={linkButtonClass} data-testid={`staff-specialty-toggle-${s.name}`} disabled={action.busy}
                onClick={() => void action.run(() => api(`/staff-specialties/${s.id}`, { method: "PATCH", body: { status: s.status === "active" ? "inactive" : "active" } }))}>
                {t(s.status === "active" ? "setup.staff.disable" : "setup.staff.enable")}
              </button>
            )}
          </li>
        ))}
      </ul>
      {can("staff.update") && (
        <form className="mt-3 flex flex-wrap items-end gap-2"
          onSubmit={async (e) => { e.preventDefault(); if (await action.run(() => api(`/staff/${staffId}/specialties`, { method: "POST", body: { name } }))) setName(""); }}>
          <Field label={t("setup.staff.specialty")}>
            <input className={inputClass} data-testid="staff-specialty-new" required maxLength={120} value={name} onChange={(e) => setName(e.target.value)} />
          </Field>
          <button type="submit" className={buttonClass} data-testid="staff-specialty-add" disabled={action.busy}>{t("setup.create")}</button>
        </form>
      )}
      <ActionError code={action.error} testId="staff-specialty-error" />
    </Card>
  );
}

function QualificationsCard({ staffId }: { staffId: string }) {
  const { can } = useAuth();
  const { data, reload } = useApi<{ rows: Qualification[] }>(`/staff/${staffId}/qualifications`);
  const action = useAction(reload);
  const blank = { degree: "bachelor", field: "", institution: "", graduation_year: "" };
  const [form, setForm] = useState(blank);
  if (!data) return null;
  return (
    <Card title={t("setup.staff.qualifications")} testId="staff-qualifications">
      {data.rows.length === 0 && <p className="text-sm text-slate-500" data-testid="staff-qualifications-empty">{t("setup.empty")}</p>}
      <ul className="divide-y text-sm">
        {data.rows.map((q) => (
          <li key={q.id} data-testid={`staff-qualification-${q.id}`} className="flex flex-wrap items-center gap-3 py-2">
            <span className="flex-1">{t(`setup.staff.degree.${q.degree}`)} — {q.field}{q.institution ? ` (${q.institution})` : ""}</span>
            <span className="text-slate-500">{q.graduation_year ?? ""}</span>
            <span className="text-slate-500">{statusText(q.status)}</span>
            {can("staff.update") && (
              <button type="button" className={linkButtonClass} data-testid={`staff-qualification-toggle-${q.id}`} disabled={action.busy}
                onClick={() => void action.run(() => api(`/staff-qualifications/${q.id}`, { method: "PATCH", body: { status: q.status === "active" ? "inactive" : "active" } }))}>
                {t(q.status === "active" ? "setup.staff.disable" : "setup.staff.enable")}
              </button>
            )}
          </li>
        ))}
      </ul>
      {can("staff.update") && (
        <form className="mt-3 grid gap-3 sm:grid-cols-5 sm:items-end"
          onSubmit={async (e) => {
            e.preventDefault();
            const body = { degree: form.degree, ...compact({ field: form.field, institution: form.institution }),
              ...(form.graduation_year ? { graduation_year: Number(form.graduation_year) } : {}) };
            if (await action.run(() => api(`/staff/${staffId}/qualifications`, { method: "POST", body }))) setForm(blank);
          }}>
          <Field label={t("setup.staff.degreeLabel")}>
            <select className={inputClass} data-testid="staff-qualification-degree" value={form.degree} onChange={(e) => setForm({ ...form, degree: e.target.value })}>
              {DEGREES.map((d) => <option key={d} value={d}>{t(`setup.staff.degree.${d}`)}</option>)}
            </select>
          </Field>
          <Field label={t("setup.staff.field")}>
            <input className={inputClass} data-testid="staff-qualification-field" required maxLength={200} value={form.field} onChange={(e) => setForm({ ...form, field: e.target.value })} />
          </Field>
          <Field label={t("setup.staff.institution")}>
            <input className={inputClass} data-testid="staff-qualification-institution" maxLength={200} value={form.institution} onChange={(e) => setForm({ ...form, institution: e.target.value })} />
          </Field>
          <Field label={t("setup.staff.graduationYear")}>
            <input className={inputClass} data-testid="staff-qualification-year" type="number" min={1900} max={2100} value={form.graduation_year} onChange={(e) => setForm({ ...form, graduation_year: e.target.value })} />
          </Field>
          <button type="submit" className={buttonClass} data-testid="staff-qualification-add" disabled={action.busy}>{t("setup.create")}</button>
        </form>
      )}
      <ActionError code={action.error} testId="staff-qualification-error" />
    </Card>
  );
}

// ------------------------------------------------------------------ 3-2: الحساب والصلاحيات
type Access = {
  has_account: boolean; email: string | null; membership_status: string | null; can_login: boolean;
  roles: { id: string; code: string; name: string }[];
  scopes: { scope_type: string; school_id: string | null; school_code: string | null; name: string | null }[];
};
type RoleOption = { id: string; code: string; name: string; assignable: boolean };

// لا تفويض هنا: الخادم و DB (M47، سياسة النطاق، T8) يقررون؛ «قابل للإسناد» عرض فقط. المدرسة والموظف والدور أهداف في المسار.
function AccessCard({ staff, schoolId }: { staff: Staff; schoolId: string }) {
  const { can } = useAuth();
  const visible = can("membership.read");
  const { data, reload } = useApi<Access>(visible ? `/staff/${staff.id}/access` : null);
  const roles = useApi<{ rows: RoleOption[] }>(visible && can("role.assign") ? `/staff/${staff.id}/access/assignable-roles` : null);
  const action = useAction(reload);
  const [roleId, setRoleId] = useState("");
  if (!visible || !data) return null;
  const options = roles.data?.rows ?? [];
  const held = new Set(data.roles.map((r) => r.id));
  const hasSchoolScope = data.scopes.some((s) => s.school_id === schoolId);
  const picker = (testId: string, exclude: Set<string>) => (
    <select className={inputClass} data-testid={testId} required value={roleId} onChange={(e) => setRoleId(e.target.value)}>
      <option value="">{t("setup.staff.access.chooseRole")}</option>
      {options.filter((r) => !exclude.has(r.id)).map((r) => (
        <option key={r.id} value={r.id} disabled={!r.assignable}>{r.name}{r.assignable ? "" : ` — ${t("setup.staff.access.notAssignable")}`}</option>
      ))}
    </select>
  );
  return (
    <Card title={t("setup.staff.access.title")} testId="staff-access">
      {!data.has_account ? (
        <>
          <p className="mb-3 text-sm text-slate-600" data-testid="staff-access-none">{t("setup.staff.access.noAccount")}</p>
          {!staff.email && <p className="mb-3 text-sm text-amber-700" data-testid="staff-access-email-needed">{t("setup.staff.access.emailNeeded")}</p>}
          {can("membership.create") && can("role.assign") && staff.email && (
            <form className="flex flex-wrap items-end gap-2"
              onSubmit={async (e) => {
                e.preventDefault();
                if (await action.run(() => api(`/schools/${schoolId}/staff/${staff.id}/account`, { method: "POST", body: { role_id: roleId } }))) setRoleId("");
              }}>
              <Field label={t("setup.staff.access.role")}>{picker("staff-access-role", new Set())}</Field>
              <button type="submit" className={buttonClass} data-testid="staff-access-activate" disabled={action.busy}>{t("setup.staff.access.activate")}</button>
            </form>
          )}
        </>
      ) : (
        <>
          <p className="mb-3 text-sm" data-testid="staff-access-ready" data-can-login={String(data.can_login)}>
            {t(data.can_login ? "setup.staff.access.ready" : "setup.staff.access.notReady")}{" "}
            <span dir="ltr" className="font-mono">{data.email}</span>
          </p>
          <h3 className="mb-1 text-sm font-medium">{t("setup.staff.access.roles")}</h3>
          <ul className="mb-3 divide-y text-sm">
            {data.roles.map((r) => (
              <li key={r.id} data-testid={`staff-access-role-${r.code}`} className="flex flex-wrap items-center gap-3 py-2">
                <span className="flex-1">{r.name}</span>
                {can("role.assign") && (
                  <ReasonAction label={t("setup.staff.access.revoke")} testId={`staff-access-role-revoke-${r.code}`} busy={action.busy}
                    onConfirm={(reason) => action.run(() => api(`/staff/${staff.id}/access/roles/${r.id}/revoke`, { method: "POST", body: { reason } }))} />
                )}
              </li>
            ))}
          </ul>
          <h3 className="mb-1 text-sm font-medium">{t("setup.staff.access.scopes")}</h3>
          <ul className="mb-3 divide-y text-sm">
            {data.scopes.length === 0 && <li className="py-2 text-slate-500" data-testid="staff-access-no-scope">{t("setup.staff.access.noScope")}</li>}
            {data.scopes.map((s) => (
              <li key={`${s.scope_type}-${s.school_id}`} data-testid={`staff-access-scope-${s.school_code ?? s.scope_type}`} className="flex flex-wrap items-center gap-3 py-2">
                <span className="flex-1">{s.name ?? t(`setup.staff.access.scopeType.${s.scope_type}`)}</span>
                {can("scope.assign") && s.school_id === schoolId && (
                  <ReasonAction label={t("setup.staff.access.revoke")} testId="staff-access-scope-revoke" busy={action.busy}
                    onConfirm={(reason) => action.run(() => api(`/schools/${schoolId}/staff/${staff.id}/access-scope/revoke`, { method: "POST", body: { reason } }))} />
                )}
              </li>
            ))}
          </ul>
          {can("scope.assign") && !hasSchoolScope && (
            <button type="button" className={`${linkButtonClass} mb-3 block`} data-testid="staff-access-scope-grant" disabled={action.busy}
              onClick={() => void action.run(() => api(`/schools/${schoolId}/staff/${staff.id}/access-scope`, { method: "POST" }))}>
              {t("setup.staff.access.grantScope")}
            </button>
          )}
          {can("role.assign") && (
            <form className="flex flex-wrap items-end gap-2"
              onSubmit={async (e) => {
                e.preventDefault();
                if (await action.run(() => api(`/staff/${staff.id}/access/roles/${roleId}`, { method: "POST" }))) setRoleId("");
              }}>
              <Field label={t("setup.staff.access.addRole")}>{picker("staff-access-role-add", held)}</Field>
              <button type="submit" className={buttonClass} data-testid="staff-access-role-grant" disabled={action.busy}>{t("setup.staff.access.grant")}</button>
            </form>
          )}
        </>
      )}
      <ActionError code={action.error} testId="staff-access-error" />
    </Card>
  );
}
