// Phase 2A — مدرسة واحدة: البيانات، المعرّف في العنوان، نمط ولي الأمر، الأرشفة، الجاهزية، السنوات، البنية.
// المدرسة تُقرأ من قائمة ما تراه الجلسة؛ غيرها «غير موجودة» (لا كشف وجود).
import { useState } from "react";
import { Link, useParams } from "react-router";
import { useAuth } from "../../auth/AuthProvider";
import { NotFound } from "../../components/states";
import { t } from "../../i18n";
import { api } from "../../lib/api";
import { ActionError, buttonClass, Card, Field, inputClass, linkButtonClass, PageState, ReasonAction, statusText, useAction, useApi } from "./common";
import { SchoolProfile } from "./SchoolProfile";
import type { School as SchoolRow } from "./Schools";

type Year = { id: string; name: string; start_date: string; end_date: string; status: string };
type Stage = { id: string; name: string; sequence_no: number; status: string };
type Grade = { id: string; stage_id: string; name: string; sequence_no: number; status: string };
export type Subject = { id: string; subject_code: string; name: string; status: string };
type Readiness ={ ready: boolean; checks: { school_active: boolean; active_year: boolean; active_section: boolean } };

export function School() {
  const { id } = useParams();
  const { can } = useAuth();
  const schools = useApi<{ rows: SchoolRow[] }>("/schools");
  if (!schools.data) return <PageState failure={schools.failure} />;
  const school = schools.data.rows.find((s) => s.id === id);
  if (!school) return <NotFound />;
  return (
    <section data-testid="school">
      <Link to="/setup/schools" className={linkButtonClass}>{t("setup.back")}</Link>
      <h1 className="mb-4 mt-2 text-2xl font-semibold" data-testid="school-title">{school.name}</h1>
      <Link to={`/setup/schools/${school.id}/wizard`} className={`${linkButtonClass} mb-4 inline-block`} data-testid="open-wizard">{t("setup.wizard.open")}</Link>
      {can("staff.read") && (
        <Link to={`/setup/schools/${school.id}/staff`} className={`${linkButtonClass} mb-4 ms-4 inline-block`} data-testid="open-staff">{t("setup.staff.open")}</Link>
      )}
      <ReadinessPanel schoolId={school.id} />
      <Info school={school} reload={schools.reload} />
      <SchoolProfile school={school} />
      {can("school.update") && school.status === "active" && <SlugForm school={school} reload={schools.reload} />}
      {can("security.manage") && school.status === "active" && <GuardianMode school={school} reload={schools.reload} />}
      <Years school={school} />
      <Structure school={school} />
      {can("subject.read") && <Subjects school={school} />}
    </section>
  );
}

function ReadinessPanel({ schoolId }: { schoolId: string }) {
  // تُعرض فقط حين يعيدها الـAPI: 403 (لا صلاحية قراءة السنة/الشعبة) ← لا لوحة، لا استنتاج من الواجهة
  const { data } = useApi<Readiness>(`/schools/${schoolId}/readiness`);
  if (!data) return null;
  return (
    <Card title={t("setup.readiness.title")} testId="readiness">
      <p data-testid="readiness-state" data-ready={String(data.ready)} className={data.ready ? "text-emerald-700" : "text-amber-700"}>
        {t(data.ready ? "setup.readiness.ready" : "setup.readiness.notReady")}
      </p>
      <ul className="mt-2 text-sm">
        {(Object.keys(data.checks) as (keyof Readiness["checks"])[]).map((k) => (
          <li key={k} data-testid={`readiness-${k}`} data-ok={String(data.checks[k])}>
            {data.checks[k] ? "✓" : "✗"} {t(`setup.readiness.${k}`)}
          </li>
        ))}
      </ul>
    </Card>
  );
}

function Info({ school, reload }: { school: SchoolRow; reload: () => void }) {
  const { can } = useAuth();
  const action = useAction(reload);
  const [form, setForm] = useState({ name: school.name, timezone: school.timezone });
  const editable = can("school.update") && school.status === "active";
  return (
    <Card title={t("setup.school.info")} testId="school-info">
      <dl className="mb-3 grid gap-2 text-sm sm:grid-cols-2">
        <div><dt className="text-slate-500">{t("setup.code")}</dt><dd className="font-mono">{school.school_code}</dd></div>
        <div><dt className="text-slate-500">{t("setup.schools.slug")}</dt><dd className="font-mono" dir="ltr" data-testid="school-slug-value">{school.slug}</dd></div>
        <div><dt className="text-slate-500">{t("setup.status")}</dt><dd data-testid="school-status">{statusText(school.status)}</dd></div>
        <div><dt className="text-slate-500">{t("setup.schools.group")}</dt><dd data-testid="school-kind">{school.is_standalone ? t("setup.schools.standalone") : t("setup.schools.inGroup")}</dd></div>
      </dl>
      {editable && (
        <form
          className="grid gap-3 sm:grid-cols-3 sm:items-end"
          onSubmit={(e) => { e.preventDefault(); void action.run(() => api(`/schools/${school.id}`, { method: "PATCH", body: form })); }}
        >
          <Field label={t("setup.name")}>
            <input className={inputClass} data-testid="school-edit-name" required value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} />
          </Field>
          <Field label={t("setup.schools.timezone")}>
            <input className={inputClass} data-testid="school-edit-timezone" dir="ltr" required value={form.timezone} onChange={(e) => setForm({ ...form, timezone: e.target.value })} />
          </Field>
          <button type="submit" className={buttonClass} data-testid="school-edit-save" disabled={action.busy}>{t("setup.save")}</button>
        </form>
      )}
      {can("school.archive") && school.status === "active" && (
        <div className="mt-3">
          <ReasonAction label={t("setup.school.archive")} testId="school-archive" busy={action.busy}
            onConfirm={(reason) => action.run(() => api(`/schools/${school.id}/archive`, { method: "POST", body: { reason } }))} />
        </div>
      )}
      <ActionError code={action.error} testId="school-info-error" />
    </Card>
  );
}

function SlugForm({ school, reload }: { school: SchoolRow; reload: () => void }) {
  const action = useAction(reload);
  const [slug, setSlug] = useState("");
  const [reason, setReason] = useState("");
  return (
    <Card title={t("setup.school.slugTitle")} testId="school-slug">
      <p className="mb-3 text-sm text-amber-700">{t("setup.school.slugWarning")}</p>
      <form
        className="grid gap-3 sm:grid-cols-3 sm:items-end"
        onSubmit={async (e) => {
          e.preventDefault();
          if (await action.run(() => api(`/schools/${school.id}/slug`, { method: "POST", body: { slug, reason } }))) { setSlug(""); setReason(""); }
        }}
      >
        <Field label={t("setup.school.slugNew")}>
          <input className={inputClass} data-testid="slug-new" dir="ltr" required value={slug} onChange={(e) => setSlug(e.target.value.toLowerCase())} />
        </Field>
        <Field label={t("setup.reason")}>
          <input className={inputClass} data-testid="slug-reason" required value={reason} onChange={(e) => setReason(e.target.value)} />
        </Field>
        <button type="submit" className={buttonClass} data-testid="slug-submit" disabled={action.busy}>{t("setup.school.changeSlug")}</button>
      </form>
      <ActionError code={action.error} testId="slug-error" />
    </Card>
  );
}

function GuardianMode({ school, reload }: { school: SchoolRow; reload: () => void }) {
  const action = useAction(reload);
  const [mode, setMode] = useState(school.guardian_first_login_mode);
  const [reason, setReason] = useState("");
  return (
    <Card title={t("setup.school.guardianMode")} testId="guardian-mode">
      <form
        className="grid gap-3 sm:grid-cols-3 sm:items-end"
        onSubmit={async (e) => {
          e.preventDefault();
          if (await action.run(() => api(`/schools/${school.id}/guardian-first-login-mode`, { method: "POST", body: { mode, reason } }))) setReason("");
        }}
      >
        <Field label={t("setup.school.guardianMode")}>
          <select className={inputClass} data-testid="guardian-mode-select" value={mode} onChange={(e) => setMode(e.target.value)}>
            {["A", "B", "C"].map((m) => <option key={m} value={m}>{t(`setup.school.mode${m}`)}</option>)}
          </select>
        </Field>
        <Field label={t("setup.reason")}>
          <input className={inputClass} data-testid="guardian-mode-reason" required value={reason} onChange={(e) => setReason(e.target.value)} />
        </Field>
        <button type="submit" className={buttonClass} data-testid="guardian-mode-submit" disabled={action.busy}>{t("setup.school.setMode")}</button>
      </form>
      <p className="mt-2 text-sm text-slate-500" data-testid="guardian-mode-current">{t(`setup.school.mode${school.guardian_first_login_mode}`)}</p>
      <ActionError code={action.error} testId="guardian-mode-error" />
    </Card>
  );
}

export function Years({ school }: { school: SchoolRow }) {
  const { can } = useAuth();
  const years = useApi<{ rows: Year[] }>(`/schools/${school.id}/academic-years`);
  const action = useAction(years.reload);
  const blank = { name: "", start_date: "", end_date: "" };
  const [form, setForm] = useState(blank);
  if (!years.data) return null;   // بلا academic_year.read: لا قسم
  return (
    <Card title={t("setup.years.title")} testId="years">
      {years.data.rows.length === 0 && <p className="text-slate-500" data-testid="years-empty">{t("setup.empty")}</p>}
      <ul className="mb-3 divide-y">
        {years.data.rows.map((y) => (
          <li key={y.id} className="flex flex-wrap gap-4 py-2" data-testid={`year-row-${y.name}`}>
            <Link className="text-emerald-700 underline" data-testid={`year-open-${y.name}`} to={`/setup/schools/${school.id}/years/${y.id}`}>{y.name}</Link>
            <span className="text-sm text-slate-500" dir="ltr">{y.start_date} → {y.end_date}</span>
            <span className="text-sm" data-testid={`year-status-${y.name}`}>{statusText(y.status)}</span>
          </li>
        ))}
      </ul>
      {can("academic_year.create") && school.status === "active" && (
        <form
          className="grid gap-3 sm:grid-cols-4 sm:items-end"
          onSubmit={async (e) => { e.preventDefault(); if (await action.run(() => api(`/schools/${school.id}/academic-years`, { method: "POST", body: form }))) setForm(blank); }}
        >
          <Field label={t("setup.name")}>
            <input className={inputClass} data-testid="year-name" required value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} />
          </Field>
          <Field label={t("setup.years.start")}>
            <input type="date" className={inputClass} data-testid="year-start" required value={form.start_date} onChange={(e) => setForm({ ...form, start_date: e.target.value })} />
          </Field>
          <Field label={t("setup.years.end")}>
            <input type="date" className={inputClass} data-testid="year-end" required min={form.start_date || undefined} value={form.end_date} onChange={(e) => setForm({ ...form, end_date: e.target.value })} />
          </Field>
          <button type="submit" className={buttonClass} data-testid="year-submit" disabled={action.busy}>{t("setup.years.new")}</button>
        </form>
      )}
      <ActionError code={action.error} testId="year-error" />
    </Card>
  );
}

export function Structure({ school }: { school: SchoolRow }) {
  const { can } = useAuth();
  const stages = useApi<{ rows: Stage[] }>(`/schools/${school.id}/stages`);
  const grades = useApi<{ rows: Grade[] }>(`/schools/${school.id}/grade-levels`);
  const reload = () => { stages.reload(); grades.reload(); };
  const action = useAction(reload);
  const [stage, setStage] = useState({ name: "", sequence_no: "" });
  const [grade, setGrade] = useState({ name: "", sequence_no: "", stage_id: "" });
  if (!stages.data && !grades.data) return null;
  const toggle = (path: string, status: string) =>
    action.run(() => api(path, { method: "PATCH", body: { status: status === "active" ? "inactive" : "active" } }));
  return (
    <Card title={t("setup.structure.title")} testId="structure">
      <h3 className="mb-2 text-sm font-medium">{t("setup.structure.stages")}</h3>
      <ul className="mb-3 divide-y text-sm">
        {(stages.data?.rows ?? []).map((s) => (
          <li key={s.id} className="flex gap-4 py-1" data-testid={`stage-row-${s.name}`}>
            <span className="w-8">{s.sequence_no}</span><span className="flex-1">{s.name}</span>
            <span data-testid={`stage-status-${s.name}`}>{statusText(s.status)}</span>
            {can("stage.manage") && (
              <button type="button" className={linkButtonClass} data-testid={`stage-toggle-${s.name}`} disabled={action.busy} onClick={() => void toggle(`/stages/${s.id}`, s.status)}>
                {t(s.status === "active" ? "setup.structure.deactivate" : "setup.structure.activate")}
              </button>
            )}
          </li>
        ))}
      </ul>
      {can("stage.manage") && (
        <form
          className="mb-4 grid gap-3 sm:grid-cols-3 sm:items-end"
          onSubmit={async (e) => {
            e.preventDefault();
            if (await action.run(() => api(`/schools/${school.id}/stages`, { method: "POST", body: { name: stage.name, sequence_no: Number(stage.sequence_no) } }))) setStage({ name: "", sequence_no: "" });
          }}
        >
          <Field label={t("setup.name")}><input className={inputClass} data-testid="stage-name" required value={stage.name} onChange={(e) => setStage({ ...stage, name: e.target.value })} /></Field>
          <Field label={t("setup.structure.sequence")}><input type="number" min={1} className={inputClass} data-testid="stage-seq" required value={stage.sequence_no} onChange={(e) => setStage({ ...stage, sequence_no: e.target.value })} /></Field>
          <button type="submit" className={buttonClass} data-testid="stage-submit" disabled={action.busy}>{t("setup.structure.newStage")}</button>
        </form>
      )}
      <h3 className="mb-2 text-sm font-medium">{t("setup.structure.grades")}</h3>
      <ul className="mb-3 divide-y text-sm">
        {(grades.data?.rows ?? []).map((g) => (
          <li key={g.id} className="flex gap-4 py-1" data-testid={`grade-row-${g.name}`}>
            <span className="w-8">{g.sequence_no}</span><span className="flex-1">{g.name}</span>
            <span data-testid={`grade-status-${g.name}`}>{statusText(g.status)}</span>
            {can("grade_level.manage") && (
              <button type="button" className={linkButtonClass} data-testid={`grade-toggle-${g.name}`} disabled={action.busy} onClick={() => void toggle(`/grade-levels/${g.id}`, g.status)}>
                {t(g.status === "active" ? "setup.structure.deactivate" : "setup.structure.activate")}
              </button>
            )}
          </li>
        ))}
      </ul>
      {can("grade_level.manage") && (
        <form
          className="grid gap-3 sm:grid-cols-4 sm:items-end"
          onSubmit={async (e) => {
            e.preventDefault();
            const body = { name: grade.name, sequence_no: Number(grade.sequence_no), stage_id: grade.stage_id };
            if (await action.run(() => api(`/schools/${school.id}/grade-levels`, { method: "POST", body }))) setGrade({ name: "", sequence_no: "", stage_id: "" });
          }}
        >
          <Field label={t("setup.structure.stage")}>
            <select className={inputClass} data-testid="grade-stage" required value={grade.stage_id} onChange={(e) => setGrade({ ...grade, stage_id: e.target.value })}>
              <option value="" />
              {(stages.data?.rows ?? []).filter((s) => s.status === "active").map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
            </select>
          </Field>
          <Field label={t("setup.name")}><input className={inputClass} data-testid="grade-name" required value={grade.name} onChange={(e) => setGrade({ ...grade, name: e.target.value })} /></Field>
          <Field label={t("setup.structure.sequence")}><input type="number" min={1} className={inputClass} data-testid="grade-seq" required value={grade.sequence_no} onChange={(e) => setGrade({ ...grade, sequence_no: e.target.value })} /></Field>
          <button type="submit" className={buttonClass} data-testid="grade-submit" disabled={action.busy}>{t("setup.structure.newGrade")}</button>
        </form>
      )}
      <ActionError code={action.error} testId="structure-error" />
    </Card>
  );
}

// Phase 2B / 2B-1 — كتالوج المواد. الرمز ثابت بعد الإنشاء؛ التعطيل مرفوض في الخادم ما دامت المادة تُدرَّس في سنة غير مغلقة (T13).
export function Subjects({ school }: { school: SchoolRow }) {
  const { can } = useAuth();
  const subjects = useApi<{ rows: Subject[] }>(`/schools/${school.id}/subjects`);
  const action = useAction(subjects.reload);
  const blank = { subject_code: "", name: "" };
  const [form, setForm] = useState(blank);
  if (!subjects.data) return null;
  const manage = can("subject.manage") && school.status === "active";
  return (
    <Card title={t("setup.subjects.title")} testId="subjects">
      {subjects.data.rows.length === 0 && <p className="text-slate-500" data-testid="subjects-empty">{t("setup.empty")}</p>}
      <ul className="mb-3 divide-y text-sm">
        {subjects.data.rows.map((s) => (
          <li key={s.id} className="flex gap-4 py-1" data-testid={`subject-row-${s.subject_code}`}>
            <span className="w-24 font-mono" dir="ltr">{s.subject_code}</span><span className="flex-1">{s.name}</span>
            <span data-testid={`subject-status-${s.subject_code}`}>{statusText(s.status)}</span>
            {manage && (
              <button type="button" className={linkButtonClass} data-testid={`subject-toggle-${s.subject_code}`} disabled={action.busy}
                onClick={() => void action.run(() => api(`/subjects/${s.id}`, { method: "PATCH", body: { status: s.status === "active" ? "inactive" : "active" } }))}>
                {t(s.status === "active" ? "setup.structure.deactivate" : "setup.structure.activate")}
              </button>
            )}
          </li>
        ))}
      </ul>
      {manage && (
        <form
          className="grid gap-3 sm:grid-cols-3 sm:items-end"
          onSubmit={async (e) => {
            e.preventDefault();
            if (await action.run(() => api(`/schools/${school.id}/subjects`, { method: "POST", body: form }))) setForm(blank);
          }}
        >
          <Field label={t("setup.code")}>
            <input className={inputClass} data-testid="subject-code" dir="ltr" required value={form.subject_code} onChange={(e) => setForm({ ...form, subject_code: e.target.value.toUpperCase() })} />
          </Field>
          <Field label={t("setup.name")}><input className={inputClass} data-testid="subject-name" required value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} /></Field>
          <button type="submit" className={buttonClass} data-testid="subject-submit" disabled={action.busy}>{t("setup.subjects.new")}</button>
        </form>
      )}
      <ActionError code={action.error} testId="subjects-error" />
    </Card>
  );
}
