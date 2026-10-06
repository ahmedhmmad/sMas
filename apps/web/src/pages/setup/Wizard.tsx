// Phase 2B / 2B-5 — معالج إعداد المدرسة: طبقة orchestration/visibility فقط (W6، B14).
// لا يكتب شيئاً بنفسه: كل خطوة تضمّن البطاقة القائمة نفسها بمساراتها. التقدّم من GET setup-progress (مشتق تحت RLS).
// سنة القياس (W1): الافتراضية من الخادم ثم **تُثبَّت في عنوان الصفحة** فلا تتغير تلقائياً أثناء الجلسة؛ لا تُخزَّن في أي مكان آخر.
import { useEffect, useState } from "react";
import { Link, useParams, useSearchParams } from "react-router";
import { NotFound } from "../../components/states";
import { t } from "../../i18n";
import { buttonClass, Card, Field, inputClass, linkButtonClass, PageState, statusText, useApi } from "./common";
import { BellSchedules } from "./BellSchedules";
import { Calendar } from "./Calendar";
import { SchoolProfile } from "./SchoolProfile";
import { Structure, Subjects, Years } from "./School";
import type { School as SchoolRow } from "./Schools";
import { GradeSubjects, Sections, Terms, YearCard } from "./Year";

type Year = { id: string; name: string; start_date: string; end_date: string; status: string };
type Step = { key: string; done: boolean; missing?: number; optional?: boolean };
type Progress = { year: { id: string; name: string; status: string } | null; steps: Step[]; setup_complete: boolean; ready_for_enrollment: boolean };

const ORDER = ["profile", "year", "calendar", "structure", "subjects", "bell", "assets", "review"];

export function Wizard() {
  const { id } = useParams();
  const [params, setParams] = useSearchParams();
  const yearParam = params.get("year");
  const schools = useApi<{ rows: SchoolRow[] }>("/schools");
  const years = useApi<{ rows: Year[] }>(`/schools/${id}/academic-years`);
  const progress = useApi<Progress>(`/schools/${id}/setup-progress${yearParam ? `?year_id=${yearParam}` : ""}`);
  const [step, setStep] = useState("profile");
  const [tick, setTick] = useState(0);   // تحديث: يعيد تركيب بطاقات الخطوة فتقرأ ما أنشأته بطاقة أخرى في الخطوة نفسها

  // W1: تثبيت السنة الافتراضية في العنوان أول ما تُعرف — بعدها لا تتغير إلا باختيار صريح
  const defaultYear = progress.data?.year?.id;
  useEffect(() => {
    if (!yearParam && defaultYear) setParams({ year: defaultYear }, { replace: true });
  }, [yearParam, defaultYear, setParams]);
  useEffect(() => { progress.reload(); years.reload(); }, [step]);   // eslint-disable-line react-hooks/exhaustive-deps

  if (!schools.data) return <PageState failure={schools.failure} />;
  const school = schools.data.rows.find((s) => s.id === id);
  if (!school) return <NotFound />;
  if (!progress.data) return <PageState failure={progress.failure} />;

  const steps = Object.fromEntries(progress.data.steps.map((s) => [s.key, s]));
  const open = (years.data?.rows ?? []).filter((y) => y.status !== "closed");
  const year = (years.data?.rows ?? []).find((y) => y.id === progress.data!.year?.id) ?? null;
  const others = (years.data?.rows ?? []).filter((y) => y.id !== year?.id);
  const index = ORDER.indexOf(step);
  const reload = () => { progress.reload(); years.reload(); setTick((n) => n + 1); };

  return (
    <section data-testid="wizard">
      <Link to={`/setup/schools/${school.id}`} className={linkButtonClass}>{t("setup.back")}</Link>
      <h1 className="mb-1 mt-2 text-2xl font-semibold">{t("setup.wizard.title")} — {school.name}</h1>
      <Field label={t("setup.wizard.year")}>
        <select className={`${inputClass} max-w-xs`} data-testid="wizard-year" value={progress.data.year?.id ?? ""}
          onChange={(e) => e.target.value && setParams({ year: e.target.value })}>
          {!progress.data.year && <option value="">—</option>}
          {open.map((y) => <option key={y.id} value={y.id}>{y.name} ({statusText(y.status)})</option>)}
        </select>
      </Field>

      <ol className="my-4 flex flex-wrap gap-2 text-sm" data-testid="wizard-steps">
        {ORDER.map((key, i) => {
          const s = steps[key];
          return (
            <li key={key}>
              <button type="button" data-testid={`wizard-step-${key}`} data-done={s ? String(s.done) : undefined} data-current={String(key === step)}
                className={`rounded border px-3 py-1 ${key === step ? "border-emerald-600 font-semibold" : "border-slate-300"} ${s?.done ? "bg-emerald-50" : ""}`}
                onClick={() => setStep(key)}>
                {s?.done ? "✓ " : `${i + 1}. `}{t(`setup.wizard.step_${key}`)}{s?.optional ? ` (${t("setup.wizard.optional")})` : ""}
              </button>
            </li>
          );
        })}
      </ol>

      {steps[step]?.missing ? <p className="mb-2 text-sm text-amber-700" data-testid="wizard-missing">{t("setup.wizard.missing")} {steps[step].missing}</p> : null}
      {!year && ["calendar", "subjects", "bell"].includes(step) && <p className="mb-2 text-sm text-amber-700" data-testid="wizard-no-year">{t("setup.wizard.noYear")}</p>}

      <div key={`${step}-${tick}`} data-testid={`wizard-body-${step}`}>
        {step === "profile" && <SchoolProfile school={school} part="profile" />}
        {step === "year" && (
          <>
            <Years school={school} />
            {year && <YearCard key={`${year.id}-${year.status}`} year={year} reload={reload} />}
            {year && <Terms year={year} />}
          </>
        )}
        {step === "calendar" && year && <Calendar year={year} others={others} />}
        {step === "structure" && (
          <>
            <Structure school={school} />
            {year && <Sections year={year} schoolId={school.id} others={others} />}
          </>
        )}
        {step === "subjects" && (
          <>
            <Subjects school={school} />
            {year && <GradeSubjects year={year} schoolId={school.id} others={others} />}
          </>
        )}
        {step === "bell" && year && <BellSchedules year={year} schoolId={school.id} others={others} />}
        {step === "assets" && <SchoolProfile school={school} part="assets" />}
        {step === "review" && <Review progress={progress.data} />}
      </div>

      <div className="mt-4 flex gap-3">
        <button type="button" className={linkButtonClass} data-testid="wizard-prev" disabled={index === 0} onClick={() => setStep(ORDER[index - 1])}>{t("setup.wizard.previous")}</button>
        <button type="button" className={buttonClass} data-testid="wizard-next" disabled={index === ORDER.length - 1} onClick={() => setStep(ORDER[index + 1])}>{t("setup.wizard.next")}</button>
        <button type="button" className={linkButtonClass} data-testid="wizard-refresh" onClick={reload}>{t("setup.wizard.refresh")}</button>
      </div>
    </section>
  );
}

function Review({ progress }: { progress: Progress }) {
  return (
    <Card title={t("setup.wizard.step_review")} testId="wizard-review">
      <ul className="mb-3 text-sm">
        {progress.steps.map((s) => (
          <li key={s.key} data-testid={`review-${s.key}`} data-done={String(s.done)}>
            {s.done ? "✓" : "✗"} {t(`setup.wizard.step_${s.key}`)}{s.optional ? ` (${t("setup.wizard.optional")})` : ""}
          </li>
        ))}
      </ul>
      <p data-testid="wizard-setup-complete" data-value={String(progress.setup_complete)}>
        {t("setup.wizard.setupComplete")}: {t(progress.setup_complete ? "setup.wizard.yes" : "setup.wizard.no")}
      </p>
      <p data-testid="wizard-ready" data-value={String(progress.ready_for_enrollment)}>
        {t("setup.wizard.readyForEnrollment")}: {t(progress.ready_for_enrollment ? "setup.wizard.yes" : "setup.wizard.no")}
      </p>
      <p className="mt-2 text-xs text-slate-500">{t("setup.wizard.independent")}</p>
    </Card>
  );
}
