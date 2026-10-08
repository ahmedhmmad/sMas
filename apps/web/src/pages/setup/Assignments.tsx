// Phase 3A / 3-3 — التكليفات في صفحة السنة: لكل شعبة نشطة مربي فصلها، ثم موادها (من ربط المواد بصفها) ومعلم كل مادة.
// لا تفويض هنا: الخادم و DB (RLS، T17، الفهرس الفريد «نشط واحد») يقررون؛ الأزرار بـstaff.assign عرض فقط.
// «معلَّق» عرض مشتق من الخادم (operational = false): شعبة أو ربط معطَّل، أو موظف غير نشط.
import { useState } from "react";
import { useAuth } from "../../auth/AuthProvider";
import { t } from "../../i18n";
import { api } from "../../lib/api";
import { ActionError, buttonClass, Card, Field, inputClass, ReasonAction, useAction, useApi } from "./common";
import type { Subject } from "./School";

type Year = { id: string; status: string };
type Section = { id: string; grade_level_id: string; name: string; status: string };
type GradeSubject = { grade_level_id: string; subject_id: string; weekly_periods: number; status: string };
type StaffRow = { id: string; full_name: string; status: string };
type Assignment = {
  id: string; section_id: string; subject_id?: string; staff_id: string; staff_name: string | null;
  effective_from: string; operational: boolean;
};

const today = () => new Date().toISOString().slice(0, 10);
const later = (a: string, b: string) => (a > b ? a : b);

export function Assignments({ year, schoolId }: { year: Year; schoolId: string }) {
  const { can } = useAuth();
  const sections = useApi<{ rows: Section[] }>(`/academic-years/${year.id}/sections`);
  const links = useApi<{ rows: GradeSubject[] }>(can("subject.read") ? `/academic-years/${year.id}/grade-subjects` : null);
  const subjects = useApi<{ rows: Subject[] }>(can("subject.read") ? `/schools/${schoolId}/subjects` : null);
  const staff = useApi<{ rows: StaffRow[] }>(`/schools/${schoolId}/staff`);
  const teaching = useApi<{ rows: Assignment[] }>(`/academic-years/${year.id}/teaching-assignments?status=active`);
  const classes = useApi<{ rows: Assignment[] }>(`/academic-years/${year.id}/class-teachers?status=active`);
  if (!sections.data || !staff.data || !teaching.data || !classes.data) return null;

  const reload = () => { teaching.reload(); classes.reload(); };
  const writable = can("staff.assign") && year.status !== "closed";
  const people = staff.data.rows.filter((s) => s.status === "active");
  const subjectName = (id: string) => subjects.data?.rows.find((s) => s.id === id)?.name ?? "";
  const active = sections.data.rows.filter((s) => s.status === "active");
  return (
    <Card title={t("setup.assignments.title")} testId="assignments">
      {active.length === 0 && <p className="text-sm text-slate-500" data-testid="assignments-empty">{t("setup.assignments.noSections")}</p>}
      {active.map((section) => (
        <div key={section.id} data-testid={`assign-section-${section.name}`} className="mb-4 rounded border border-slate-200 p-3">
          <h3 className="mb-2 font-medium">{section.name}</h3>
          <Slot testId={`class-${section.name}`} label={t("setup.assignments.classTeacher")} year={year} writable={writable} people={people} reload={reload}
            current={classes.data!.rows.find((a) => a.section_id === section.id)}
            create={`/sections/${section.id}/class-teacher`} base="/class-teacher-assignments" />
          {(links.data?.rows ?? []).filter((l) => l.grade_level_id === section.grade_level_id && l.status === "active").map((l) => (
            <Slot key={l.subject_id} testId={`teach-${section.name}-${subjectName(l.subject_id)}`} label={subjectName(l.subject_id)} year={year}
              writable={writable} people={people} reload={reload}
              current={teaching.data!.rows.find((a) => a.section_id === section.id && a.subject_id === l.subject_id)}
              create={`/sections/${section.id}/teaching-assignments`} extra={{ subject_id: l.subject_id }} base="/teaching-assignments" />
          ))}
        </div>
      ))}
    </Card>
  );
}

function Slot({ testId, label, year, writable, people, current, create, extra, base, reload }: {
  testId: string; label: string; year: Year; writable: boolean; people: StaffRow[]; current?: Assignment;
  create: string; extra?: Record<string, string>; base: string; reload: () => void;
}) {
  const action = useAction(reload);
  const [staffId, setStaffId] = useState("");
  const [reason, setReason] = useState("");
  // السبب: إلزامي للاستبدال دائماً، وللتكليف الجديد في سنة نشطة (C3) — DB هي الحكم
  const needsReason = Boolean(current) || year.status === "active";
  const submit = async () => {
    const ok = current
      ? await action.run(() => api(`${base}/${current.id}/replace`, { method: "POST", body: { staff_id: staffId, effective_from: later(today(), current.effective_from), reason } }))
      : await action.run(() => api(create, { method: "POST", body: { ...extra, staff_id: staffId, ...(reason ? { reason } : {}) } }));
    if (ok) { setStaffId(""); setReason(""); }
  };
  return (
    <div data-testid={`slot-${testId}`} className="flex flex-wrap items-end gap-3 border-t border-slate-100 py-2 text-sm">
      <span className="w-40 font-medium">{label}</span>
      <span className="flex-1" data-testid={`slot-${testId}-current`} data-operational={current ? String(current.operational) : undefined}>
        {current ? (current.staff_name ?? "—") : t("setup.assignments.unassigned")}
        {current && !current.operational && <span className="ms-2 text-amber-700">{t("setup.assignments.suspended")}</span>}
      </span>
      {writable && (
        <form className="flex flex-wrap items-end gap-2" onSubmit={(e) => { e.preventDefault(); void submit(); }}>
          <select className={inputClass} data-testid={`slot-${testId}-staff`} required value={staffId} onChange={(e) => setStaffId(e.target.value)}>
            <option value="">{t("setup.assignments.chooseStaff")}</option>
            {people.filter((p) => p.id !== current?.staff_id).map((p) => <option key={p.id} value={p.id}>{p.full_name}</option>)}
          </select>
          {needsReason && (
            <Field label={t("setup.reason")}>
              <input className={inputClass} data-testid={`slot-${testId}-reason`} required maxLength={500} value={reason} onChange={(e) => setReason(e.target.value)} />
            </Field>
          )}
          <button type="submit" className={buttonClass} data-testid={`slot-${testId}-submit`} disabled={action.busy}>
            {t(current ? "setup.assignments.replace" : "setup.assignments.assign")}
          </button>
        </form>
      )}
      {writable && current && (
        <ReasonAction label={t("setup.assignments.end")} testId={`slot-${testId}-end`} busy={action.busy}
          onConfirm={(r) => action.run(() => api(`${base}/${current.id}/end`, { method: "POST", body: { effective_to: later(today(), current.effective_from), reason: r } }))} />
      )}
      <ActionError code={action.error} testId={`slot-${testId}-error`} />
    </div>
  );
}
