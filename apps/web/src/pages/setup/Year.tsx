// Phase 2A — سنة دراسية: التعديل حسب الحالة، التفعيل/الإغلاق، الفصول، الشعب، ونسخ الشعب إلى سنة مخططة.
// قيود الحالة في الواجهة تحسين عرض فقط (حقول معطّلة)؛ الحارسان T10/T11/T12 والدوال في الخادم هي الحكم.
import { useState } from "react";
import { Link, useParams } from "react-router";
import { useAuth } from "../../auth/AuthProvider";
import { NotFound } from "../../components/states";
import { t } from "../../i18n";
import { api } from "../../lib/api";
import { ActionError, buttonClass, Card, Field, inputClass, linkButtonClass, PageState, ReasonAction, statusText, useAction, useApi } from "./common";
import { BellSchedules } from "./BellSchedules";
import { Calendar } from "./Calendar";
import type { Subject } from "./School";

type Year = { id: string; name: string; start_date: string; end_date: string; status: string };
type Term = { id: string; name: string; sequence_no: number; start_date: string; end_date: string; status: string };
type Grade = { id: string; name: string; status: string };
type Section = { id: string; grade_level_id: string; name: string; capacity: number | null; gender_policy: string; status: string };
type GradeSubject = { id: string; grade_level_id: string; subject_id: string; weekly_periods: number; counts_toward_total: boolean; status: string };

export function Year() {
  const { schoolId, yearId } = useParams();
  const { can } = useAuth();
  const years = useApi<{ rows: Year[] }>(`/schools/${schoolId}/academic-years`);
  if (!years.data) return <PageState failure={years.failure} />;
  const year = years.data.rows.find((y) => y.id === yearId);
  if (!year) return <NotFound />;
  return (
    <section data-testid="year">
      <Link to={`/setup/schools/${schoolId}`} className={linkButtonClass}>{t("setup.back")}</Link>
      <h1 className="mb-1 mt-2 text-2xl font-semibold" data-testid="year-title">{year.name}</h1>
      <p className="mb-4 text-sm text-slate-600" data-testid="year-state">{statusText(year.status)}</p>
      <YearCard year={year} reload={years.reload} />
      <Terms year={year} />
      <Sections year={year} schoolId={schoolId!} others={years.data.rows.filter((y) => y.id !== year.id)} />
      <Calendar year={year} others={years.data.rows.filter((y) => y.id !== year.id)} />
      <BellSchedules year={year} schoolId={schoolId!} others={years.data.rows.filter((y) => y.id !== year.id)} />
      {can("subject.read") && <GradeSubjects year={year} schoolId={schoolId!} others={years.data.rows.filter((y) => y.id !== year.id)} />}
    </section>
  );
}

export function YearCard({ year, reload }: { year: Year; reload: () => void }) {
  const { can } = useAuth();
  const action = useAction(reload);
  const [form, setForm] = useState({ name: year.name, start_date: year.start_date, end_date: year.end_date });
  const datesEditable = year.status === "planned";
  return (
    <Card title={t("setup.years.title")} testId="year-card">
      {year.status === "closed" ? (
        <p className="text-sm text-slate-500" data-testid="year-closed-note">{t("setup.years.closedLocked")}</p>
      ) : can("academic_year.update") && (
        <form
          className="grid gap-3 sm:grid-cols-4 sm:items-end"
          onSubmit={(e) => {
            e.preventDefault();
            // سنة نشطة: الاسم وحده يُرسل (T10)؛ المخطط: الاسم والتواريخ
            const body = datesEditable ? form : { name: form.name };
            void action.run(() => api(`/academic-years/${year.id}`, { method: "PATCH", body }));
          }}
        >
          <Field label={t("setup.name")}><input className={inputClass} data-testid="year-edit-name" required value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} /></Field>
          <Field label={t("setup.years.start")}><input type="date" className={inputClass} data-testid="year-edit-start" disabled={!datesEditable} value={form.start_date} onChange={(e) => setForm({ ...form, start_date: e.target.value })} /></Field>
          <Field label={t("setup.years.end")}><input type="date" className={inputClass} data-testid="year-edit-end" disabled={!datesEditable} value={form.end_date} onChange={(e) => setForm({ ...form, end_date: e.target.value })} /></Field>
          <button type="submit" className={buttonClass} data-testid="year-edit-save" disabled={action.busy}>{t("setup.save")}</button>
          {!datesEditable && <p className="text-sm text-slate-500 sm:col-span-4">{t("setup.years.datesLocked")}</p>}
        </form>
      )}
      <div className="mt-3 flex flex-wrap gap-4">
        {can("academic_year.activate") && year.status === "planned" && (
          <ReasonAction label={t("setup.years.activate")} testId="year-activate" busy={action.busy}
            onConfirm={(reason) => action.run(() => api(`/academic-years/${year.id}/activate`, { method: "POST", body: { reason } }))} />
        )}
        {can("academic_year.close") && year.status === "active" && (
          <ReasonAction label={t("setup.years.close")} testId="year-close" busy={action.busy}
            onConfirm={(reason) => action.run(() => api(`/academic-years/${year.id}/close`, { method: "POST", body: { reason } }))} />
        )}
      </div>
      <ActionError code={action.error} testId="year-card-error" />
    </Card>
  );
}

export function Terms({ year }: { year: Year }) {
  const { can } = useAuth();
  const terms = useApi<{ rows: Term[] }>(`/academic-years/${year.id}/terms`);
  const action = useAction(terms.reload);
  const blank = { name: "", sequence_no: "", start_date: "", end_date: "" };
  const [form, setForm] = useState(blank);
  if (!terms.data) return null;
  const manage = can("term.manage") && year.status !== "closed";
  return (
    <Card title={t("setup.terms.title")} testId="terms">
      {terms.data.rows.length === 0 && <p className="text-slate-500" data-testid="terms-empty">{t("setup.empty")}</p>}
      <ul className="mb-3 divide-y text-sm">
        {terms.data.rows.map((term) => (
          <li key={term.id} className="flex flex-wrap items-center gap-4 py-2" data-testid={`term-row-${term.name}`}>
            <span className="w-8">{term.sequence_no}</span>
            <span className="flex-1">{term.name}</span>
            <span dir="ltr">{term.start_date} → {term.end_date}</span>
            <span data-testid={`term-status-${term.name}`}>{statusText(term.status)}</span>
            {manage && term.status === "planned" && year.status === "active" && (
              <ReasonAction label={t("setup.terms.activate")} testId={`term-activate-${term.name}`} busy={action.busy}
                onConfirm={(reason) => action.run(() => api(`/terms/${term.id}/activate`, { method: "POST", body: { reason } }))} />
            )}
            {manage && term.status === "active" && (
              <ReasonAction label={t("setup.terms.close")} testId={`term-close-${term.name}`} busy={action.busy}
                onConfirm={(reason) => action.run(() => api(`/terms/${term.id}/close`, { method: "POST", body: { reason } }))} />
            )}
          </li>
        ))}
      </ul>
      {manage && (
        <form
          className="grid gap-3 sm:grid-cols-5 sm:items-end"
          onSubmit={async (e) => {
            e.preventDefault();
            const body = { ...form, sequence_no: Number(form.sequence_no) };
            if (await action.run(() => api(`/academic-years/${year.id}/terms`, { method: "POST", body }))) setForm(blank);
          }}
        >
          <Field label={t("setup.name")}><input className={inputClass} data-testid="term-name" required value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} /></Field>
          <Field label={t("setup.terms.sequence")}><input type="number" min={1} className={inputClass} data-testid="term-seq" required value={form.sequence_no} onChange={(e) => setForm({ ...form, sequence_no: e.target.value })} /></Field>
          <Field label={t("setup.years.start")}><input type="date" className={inputClass} data-testid="term-start" required min={year.start_date} max={year.end_date} value={form.start_date} onChange={(e) => setForm({ ...form, start_date: e.target.value })} /></Field>
          <Field label={t("setup.years.end")}><input type="date" className={inputClass} data-testid="term-end" required min={form.start_date || year.start_date} max={year.end_date} value={form.end_date} onChange={(e) => setForm({ ...form, end_date: e.target.value })} /></Field>
          <button type="submit" className={buttonClass} data-testid="term-submit" disabled={action.busy}>{t("setup.terms.new")}</button>
        </form>
      )}
      <ActionError code={action.error} testId="terms-error" />
    </Card>
  );
}

export function Sections({ year, schoolId, others }: { year: Year; schoolId: string; others: Year[] }) {
  const { can } = useAuth();
  const sections = useApi<{ rows: Section[] }>(`/academic-years/${year.id}/sections`);
  const grades = useApi<{ rows: Grade[] }>(`/schools/${schoolId}/grade-levels`);
  const action = useAction(sections.reload);
  const blank = { grade_level_id: "", name: "", capacity: "", gender_policy: "mixed" };
  const [form, setForm] = useState(blank);
  const [copy, setCopy] = useState({ source_year_id: "", reason: "" });
  const [created, setCreated] = useState<number | null>(null);
  if (!sections.data) return null;
  const gradeName = (id: string) => grades.data?.rows.find((g) => g.id === id)?.name ?? "";
  const manage = can("section.manage") && year.status !== "closed";
  return (
    <Card title={t("setup.sections.title")} testId="sections">
      {sections.data.rows.length === 0 && <p className="text-slate-500" data-testid="sections-empty">{t("setup.empty")}</p>}
      <ul className="mb-3 divide-y text-sm">
        {sections.data.rows.map((s) => (
          <li key={s.id} className="flex flex-wrap items-center gap-4 py-2" data-testid={`section-row-${gradeName(s.grade_level_id)}-${s.name}`}>
            <span className="flex-1">{gradeName(s.grade_level_id)} / {s.name}</span>
            <span>{s.capacity ?? ""}</span>
            <span>{t(`setup.sections.gender_${s.gender_policy}`)}</span>
            <span data-testid={`section-status-${gradeName(s.grade_level_id)}-${s.name}`}>{statusText(s.status)}</span>
            {manage && (
              <button type="button" className={linkButtonClass} data-testid={`section-toggle-${gradeName(s.grade_level_id)}-${s.name}`} disabled={action.busy}
                onClick={() => void action.run(() => api(`/sections/${s.id}`, { method: "PATCH", body: { status: s.status === "active" ? "inactive" : "active" } }))}>
                {t(s.status === "active" ? "setup.structure.deactivate" : "setup.structure.activate")}
              </button>
            )}
          </li>
        ))}
      </ul>
      {manage && (
        <form
          className="mb-4 grid gap-3 sm:grid-cols-5 sm:items-end"
          onSubmit={async (e) => {
            e.preventDefault();
            const body = { ...form, capacity: form.capacity === "" ? null : Number(form.capacity) };
            if (await action.run(() => api(`/academic-years/${year.id}/sections`, { method: "POST", body }))) setForm(blank);
          }}
        >
          <Field label={t("setup.sections.grade")}>
            <select className={inputClass} data-testid="section-grade" required value={form.grade_level_id} onChange={(e) => setForm({ ...form, grade_level_id: e.target.value })}>
              <option value="" />
              {(grades.data?.rows ?? []).filter((g) => g.status === "active").map((g) => <option key={g.id} value={g.id}>{g.name}</option>)}
            </select>
          </Field>
          <Field label={t("setup.name")}><input className={inputClass} data-testid="section-name" required value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} /></Field>
          <Field label={t("setup.sections.capacity")}><input type="number" min={1} className={inputClass} data-testid="section-capacity" value={form.capacity} onChange={(e) => setForm({ ...form, capacity: e.target.value })} /></Field>
          <Field label={t("setup.sections.gender")}>
            <select className={inputClass} data-testid="section-gender" value={form.gender_policy} onChange={(e) => setForm({ ...form, gender_policy: e.target.value })}>
              {["mixed", "male_only", "female_only"].map((g) => <option key={g} value={g}>{t(`setup.sections.gender_${g}`)}</option>)}
            </select>
          </Field>
          <button type="submit" className={buttonClass} data-testid="section-submit" disabled={action.busy}>{t("setup.sections.new")}</button>
        </form>
      )}
      {can("section.manage") && year.status === "planned" && others.length > 0 && (
        <div data-testid="copy-sections" className="rounded border border-slate-200 p-3">
          <h3 className="mb-1 text-sm font-medium">{t("setup.sections.copyTitle")}</h3>
          <p className="mb-2 text-xs text-slate-500">{t("setup.sections.copyHint")}</p>
          <form
            className="grid gap-3 sm:grid-cols-3 sm:items-end"
            onSubmit={async (e) => {
              e.preventDefault();
              await action.run(async () => {
                const r = await api<{ created: number }>(`/academic-years/${year.id}/copy-sections`, { method: "POST", body: copy });
                setCreated(r.created);
              });
            }}
          >
            <Field label={t("setup.sections.copySource")}>
              <select className={inputClass} data-testid="copy-source" required value={copy.source_year_id} onChange={(e) => setCopy({ ...copy, source_year_id: e.target.value })}>
                <option value="" />
                {others.map((y) => <option key={y.id} value={y.id}>{y.name}</option>)}
              </select>
            </Field>
            <Field label={t("setup.reason")}><input className={inputClass} data-testid="copy-reason" required value={copy.reason} onChange={(e) => setCopy({ ...copy, reason: e.target.value })} /></Field>
            <button type="submit" className={buttonClass} data-testid="copy-submit" disabled={action.busy}>{t("setup.sections.copy")}</button>
          </form>
          {created !== null && <p className="mt-2 text-sm text-emerald-700" data-testid="copy-result" data-created={created}>{t("setup.sections.copied")} {created}</p>}
        </div>
      )}
      <ActionError code={action.error} testId="sections-error" />
    </Card>
  );
}

// Phase 2B / 2B-1 — مواد الصفوف لهذه السنة: الحصص الأسبوعية والدخول في المجموع، ونسخها إلى سنة مخططة (M40).
// السنة المغلقة للقراءة فقط (T13 هو الحكم)؛ الربط الجديد يولد active.
export function GradeSubjects({ year, schoolId, others }: { year: Year; schoolId: string; others: Year[] }) {
  const { can } = useAuth();
  const links = useApi<{ rows: GradeSubject[] }>(`/academic-years/${year.id}/grade-subjects`);
  const grades = useApi<{ rows: Grade[] }>(`/schools/${schoolId}/grade-levels`);
  const subjects = useApi<{ rows: Subject[] }>(`/schools/${schoolId}/subjects`);
  const action = useAction(links.reload);
  const blank = { grade_level_id: "", subject_id: "", weekly_periods: "", counts_toward_total: true };
  const [form, setForm] = useState(blank);
  const [copy, setCopy] = useState({ source_year_id: "", reason: "" });
  const [created, setCreated] = useState<number | null>(null);
  if (!links.data) return null;
  const gradeName = (id: string) => grades.data?.rows.find((g) => g.id === id)?.name ?? "";
  const subjectCode = (id: string) => subjects.data?.rows.find((s) => s.id === id)?.subject_code ?? "";
  const manage = can("subject.manage") && year.status !== "closed";
  return (
    <Card title={t("setup.gradeSubjects.title")} testId="grade-subjects">
      {links.data.rows.length === 0 && <p className="text-slate-500" data-testid="grade-subjects-empty">{t("setup.empty")}</p>}
      <ul className="mb-3 divide-y text-sm">
        {links.data.rows.map((l) => {
          const key = `${gradeName(l.grade_level_id)}-${subjectCode(l.subject_id)}`;
          return (
            <li key={l.id} className="flex flex-wrap items-center gap-4 py-2" data-testid={`gs-row-${key}`}>
              <span className="flex-1">{gradeName(l.grade_level_id)} / <span dir="ltr">{subjectCode(l.subject_id)}</span></span>
              <span data-testid={`gs-periods-${key}`}>{l.weekly_periods} {t("setup.gradeSubjects.perWeek")}</span>
              <span>{t(l.counts_toward_total ? "setup.gradeSubjects.inTotal" : "setup.gradeSubjects.notInTotal")}</span>
              <span data-testid={`gs-status-${key}`}>{statusText(l.status)}</span>
              {manage && (
                <button type="button" className={linkButtonClass} data-testid={`gs-toggle-${key}`} disabled={action.busy}
                  onClick={() => void action.run(() => api(`/grade-subjects/${l.id}`, { method: "PATCH", body: { status: l.status === "active" ? "inactive" : "active" } }))}>
                  {t(l.status === "active" ? "setup.structure.deactivate" : "setup.structure.activate")}
                </button>
              )}
            </li>
          );
        })}
      </ul>
      {manage && (
        <form
          className="mb-4 grid gap-3 sm:grid-cols-5 sm:items-end"
          onSubmit={async (e) => {
            e.preventDefault();
            const body = { ...form, weekly_periods: Number(form.weekly_periods) };
            if (await action.run(() => api(`/academic-years/${year.id}/grade-subjects`, { method: "POST", body }))) setForm(blank);
          }}
        >
          <Field label={t("setup.sections.grade")}>
            <select className={inputClass} data-testid="gs-grade" required value={form.grade_level_id} onChange={(e) => setForm({ ...form, grade_level_id: e.target.value })}>
              <option value="" />
              {(grades.data?.rows ?? []).filter((g) => g.status === "active").map((g) => <option key={g.id} value={g.id}>{g.name}</option>)}
            </select>
          </Field>
          <Field label={t("setup.gradeSubjects.subject")}>
            <select className={inputClass} data-testid="gs-subject" required value={form.subject_id} onChange={(e) => setForm({ ...form, subject_id: e.target.value })}>
              <option value="" />
              {(subjects.data?.rows ?? []).filter((s) => s.status === "active").map((s) => <option key={s.id} value={s.id}>{s.subject_code} — {s.name}</option>)}
            </select>
          </Field>
          <Field label={t("setup.gradeSubjects.periods")}>
            <input type="number" min={1} max={60} className={inputClass} data-testid="gs-periods" required value={form.weekly_periods} onChange={(e) => setForm({ ...form, weekly_periods: e.target.value })} />
          </Field>
          <label className="flex items-center gap-2 text-sm">
            <input type="checkbox" data-testid="gs-total" checked={form.counts_toward_total} onChange={(e) => setForm({ ...form, counts_toward_total: e.target.checked })} />
            {t("setup.gradeSubjects.inTotal")}
          </label>
          <button type="submit" className={buttonClass} data-testid="gs-submit" disabled={action.busy}>{t("setup.gradeSubjects.new")}</button>
        </form>
      )}
      {can("subject.manage") && year.status === "planned" && others.length > 0 && (
        <div data-testid="copy-grade-subjects" className="rounded border border-slate-200 p-3">
          <h3 className="mb-1 text-sm font-medium">{t("setup.gradeSubjects.copyTitle")}</h3>
          <p className="mb-2 text-xs text-slate-500">{t("setup.gradeSubjects.copyHint")}</p>
          <form
            className="grid gap-3 sm:grid-cols-3 sm:items-end"
            onSubmit={async (e) => {
              e.preventDefault();
              await action.run(async () => {
                const r = await api<{ created: number }>(`/academic-years/${year.id}/copy-grade-subjects`, { method: "POST", body: copy });
                setCreated(r.created);
              });
            }}
          >
            <Field label={t("setup.sections.copySource")}>
              <select className={inputClass} data-testid="gs-copy-source" required value={copy.source_year_id} onChange={(e) => setCopy({ ...copy, source_year_id: e.target.value })}>
                <option value="" />
                {others.map((y) => <option key={y.id} value={y.id}>{y.name}</option>)}
              </select>
            </Field>
            <Field label={t("setup.reason")}><input className={inputClass} data-testid="gs-copy-reason" required value={copy.reason} onChange={(e) => setCopy({ ...copy, reason: e.target.value })} /></Field>
            <button type="submit" className={buttonClass} data-testid="gs-copy-submit" disabled={action.busy}>{t("setup.gradeSubjects.copy")}</button>
          </form>
          {created !== null && <p className="mt-2 text-sm text-emerald-700" data-testid="gs-copy-result" data-created={created}>{t("setup.gradeSubjects.copied")} {created}</p>}
        </div>
      )}
      <ActionError code={action.error} testId="grade-subjects-error" />
    </Card>
  );
}
