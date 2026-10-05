// Phase 2B / 2B-3 — الدوام والحصص للسنة: الجداول (الفترات)، حصص كل يوم، نسخ يوم، إسناد الصفوف، النسخ من سنة أخرى.
// قواعد D1–D7 في قاعدة البيانات (منع التداخل، أيام الدوام، حالة السنة، السبب): الواجهة تعرض وتُرسل، والخادم يقرر.
// رقم الحصة الظاهر يأتي من الـAPI مشتقاً (lesson_no، D5) — لا يُحسب هنا ولا يُخزَّن.
import { useState } from "react";
import { useAuth } from "../../auth/AuthProvider";
import { t } from "../../i18n";
import { api } from "../../lib/api";
import { ActionError, buttonClass, Card, Field, inputClass, linkButtonClass, ReasonAction, statusText, useAction, useApi } from "./common";

type Year = { id: string; name: string; status: string };
type Schedule = { id: string; name: string; status: string };
type Period = { id: string; weekday: number; kind: string; name: string | null; start_time: string; end_time: string; status: string; lesson_no: number | null };
type Weekday = { weekday: number; status: string };
type Grade = { id: string; name: string; status: string };
type Assignment = { id: string; grade_level_id: string; bell_schedule_id: string };

const hm = (time: string) => time.slice(0, 5);

export function BellSchedules({ year, schoolId, others }: { year: Year; schoolId: string; others: Year[] }) {
  const { can } = useAuth();
  const schedules = useApi<{ rows: Schedule[] }>(`/academic-years/${year.id}/bell-schedules`);
  const action = useAction(schedules.reload);
  const [name, setName] = useState("");
  const [reason, setReason] = useState("");
  const [open, setOpen] = useState<string | null>(null);
  const [copy, setCopy] = useState({ source_year_id: "", reason: "" });
  const [created, setCreated] = useState<number | null>(null);
  if (!schedules.data) return null;   // بلا academic_year.read: لا قسم
  const manage = can("academic_year.update") && year.status !== "closed";
  return (
    <Card title={t("setup.bell.title")} testId="bell-schedules">
      {manage && year.status === "active" && <p className="mb-2 text-xs text-slate-500">{t("setup.bell.activeHint")}</p>}
      {schedules.data.rows.length === 0 && <p className="text-slate-500" data-testid="bell-schedules-empty">{t("setup.empty")}</p>}
      <ul className="mb-3 divide-y text-sm">
        {schedules.data.rows.map((s) => (
          <li key={s.id} className="py-2" data-testid={`bell-schedule-row-${s.name}`}>
            <div className="flex flex-wrap items-center gap-4">
              <button type="button" className={linkButtonClass} data-testid={`bell-schedule-open-${s.name}`} onClick={() => setOpen(open === s.id ? null : s.id)}>{s.name}</button>
              <span data-testid={`bell-schedule-status-${s.name}`}>{statusText(s.status)}</span>
              {manage && (
                <ReasonAction label={t(s.status === "active" ? "setup.structure.deactivate" : "setup.structure.activate")} testId={`bell-schedule-toggle-${s.name}`} busy={action.busy}
                  onConfirm={(r) => action.run(() => api(`/bell-schedules/${s.id}`, { method: "PATCH", body: { status: s.status === "active" ? "inactive" : "active", reason: r } }))} />
              )}
            </div>
            {open === s.id && <Periods schedule={s} yearId={year.id} manage={manage && s.status === "active"} active={year.status === "active"} />}
          </li>
        ))}
      </ul>
      {manage && (
        <form
          className="mb-4 grid gap-3 sm:grid-cols-3 sm:items-end"
          onSubmit={async (e) => {
            e.preventDefault();
            if (await action.run(() => api(`/academic-years/${year.id}/bell-schedules`, { method: "POST", body: { name, reason: reason || undefined } }))) { setName(""); setReason(""); }
          }}
        >
          <Field label={t("setup.bell.scheduleName")}><input className={inputClass} data-testid="bell-schedule-name" required value={name} onChange={(e) => setName(e.target.value)} /></Field>
          <Field label={t("setup.reason")}><input className={inputClass} data-testid="bell-schedule-reason" required={year.status === "active"} value={reason} onChange={(e) => setReason(e.target.value)} /></Field>
          <button type="submit" className={buttonClass} data-testid="bell-schedule-submit" disabled={action.busy}>{t("setup.bell.newSchedule")}</button>
        </form>
      )}
      <ActionError code={action.error} testId="bell-schedules-error" />
      <Assignments year={year} schoolId={schoolId} schedules={schedules.data.rows.filter((s) => s.status === "active")} manage={manage} />
      {can("academic_year.update") && year.status === "planned" && others.length > 0 && (
        <form
          className="mt-4 grid gap-3 rounded border border-slate-200 p-3 sm:grid-cols-3 sm:items-end"
          data-testid="copy-bell-schedules"
          onSubmit={async (e) => {
            e.preventDefault();
            await action.run(async () => {
              const r = await api<{ created: number }>(`/academic-years/${year.id}/copy-bell-schedules`, { method: "POST", body: copy });
              setCreated(r.created);
            });
          }}
        >
          <Field label={t("setup.bell.copySource")}>
            <select className={inputClass} data-testid="bell-copy-source" required value={copy.source_year_id} onChange={(e) => setCopy({ ...copy, source_year_id: e.target.value })}>
              <option value="" />
              {others.map((y) => <option key={y.id} value={y.id}>{y.name}</option>)}
            </select>
          </Field>
          <Field label={t("setup.reason")}><input className={inputClass} data-testid="bell-copy-reason" required value={copy.reason} onChange={(e) => setCopy({ ...copy, reason: e.target.value })} /></Field>
          <button type="submit" className={buttonClass} data-testid="bell-copy-submit" disabled={action.busy}>{t("setup.bell.copy")}</button>
          <p className="text-xs text-slate-500 sm:col-span-3">{t("setup.bell.copyHint")}</p>
          {created !== null && <p className="text-sm text-emerald-700 sm:col-span-3" data-testid="bell-copy-result" data-created={created}>{t("setup.bell.copied")} {created}</p>}
        </form>
      )}
    </Card>
  );
}

// أيام الدوام تُقرأ عند فتح الجدول (لا عند تحميل الصفحة): تعريفها في بطاقة التقويم على الصفحة نفسها يظهر هنا دون إعادة تحميل
function Periods({ schedule, yearId, manage, active }: { schedule: Schedule; yearId: string; manage: boolean; active: boolean }) {
  const periods = useApi<{ rows: Period[] }>(`/bell-schedules/${schedule.id}/periods`);
  const weekdays = useApi<{ rows: Weekday[] }>(`/academic-years/${yearId}/weekdays`);
  const days = (weekdays.data?.rows ?? []).filter((w) => w.status === "active").map((w) => w.weekday);
  const action = useAction(periods.reload);
  const blank = { weekday: String(days[0] ?? ""), kind: "lesson", name: "", start_time: "", end_time: "", reason: "" };
  const [form, setForm] = useState(blank);
  const [dup, setDup] = useState({ from: String(days[0] ?? ""), to: [] as number[], reason: "" });
  if (!periods.data || !weekdays.data) return null;
  const day = form.weekday === "" ? String(days[0] ?? "") : form.weekday;      // الافتراضي أول يوم دوام بعد التحميل
  const from = dup.from === "" ? String(days[0] ?? "") : dup.from;
  const live = periods.data.rows.filter((p) => p.status === "active");
  return (
    <div className="mt-2 rounded border border-slate-200 p-3" data-testid={`bell-periods-${schedule.name}`}>
      {days.length === 0 && <p className="text-sm text-amber-700" data-testid="bell-no-weekdays">{t("setup.bell.noWeekdays")}</p>}
      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
        {days.map((d) => (
          <div key={d} data-testid={`bell-day-${schedule.name}-${d}`}>
            <h4 className="mb-1 text-sm font-medium">{t(`setup.calendar.day${d}`)}</h4>
            <ul className="text-sm">
              {live.filter((p) => p.weekday === d).map((p) => (
                <li key={p.id} className="flex flex-wrap items-center gap-2 py-0.5" data-testid={`bell-period-${schedule.name}-${d}-${hm(p.start_time)}`}>
                  <span className="w-20" data-testid={`bell-period-label-${schedule.name}-${d}-${hm(p.start_time)}`}>
                    {p.kind === "lesson" ? `${t("setup.bell.lesson")} ${p.lesson_no}` : p.name}
                  </span>
                  <span dir="ltr">{hm(p.start_time)}–{hm(p.end_time)}</span>
                  {manage && (
                    <ReasonAction label={t("setup.bell.remove")} testId={`bell-period-remove-${schedule.name}-${d}-${hm(p.start_time)}`} busy={action.busy}
                      onConfirm={(r) => action.run(() => api(`/bell-periods/${p.id}`, { method: "PATCH", body: { status: "inactive", reason: r } }))} />
                  )}
                </li>
              ))}
            </ul>
          </div>
        ))}
      </div>
      {manage && days.length > 0 && (
        <>
          <form
            className="mt-3 grid gap-3 sm:grid-cols-7 sm:items-end"
            onSubmit={async (e) => {
              e.preventDefault();
              const body = { weekday: Number(day), kind: form.kind, name: form.name || undefined, start_time: form.start_time, end_time: form.end_time, reason: form.reason || undefined };
              if (await action.run(() => api(`/bell-schedules/${schedule.id}/periods`, { method: "POST", body }))) setForm({ ...blank, weekday: day });
            }}
          >
            <Field label={t("setup.bell.day")}>
              <select className={inputClass} data-testid="bell-period-day" value={day} onChange={(e) => setForm({ ...form, weekday: e.target.value })}>
                {days.map((d) => <option key={d} value={d}>{t(`setup.calendar.day${d}`)}</option>)}
              </select>
            </Field>
            <Field label={t("setup.calendar.kind")}>
              <select className={inputClass} data-testid="bell-period-kind" value={form.kind} onChange={(e) => setForm({ ...form, kind: e.target.value })}>
                {["lesson", "break"].map((k) => <option key={k} value={k}>{t(`setup.bell.kind_${k}`)}</option>)}
              </select>
            </Field>
            <Field label={t("setup.name")}><input className={inputClass} data-testid="bell-period-name" required={form.kind === "break"} value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} /></Field>
            <Field label={t("setup.bell.start")}><input type="time" className={inputClass} data-testid="bell-period-start" required value={form.start_time} onChange={(e) => setForm({ ...form, start_time: e.target.value })} /></Field>
            <Field label={t("setup.bell.end")}><input type="time" className={inputClass} data-testid="bell-period-end" required value={form.end_time} onChange={(e) => setForm({ ...form, end_time: e.target.value })} /></Field>
            <Field label={t("setup.reason")}><input className={inputClass} data-testid="bell-period-reason" required={active} value={form.reason} onChange={(e) => setForm({ ...form, reason: e.target.value })} /></Field>
            <button type="submit" className={buttonClass} data-testid="bell-period-submit" disabled={action.busy}>{t("setup.calendar.add")}</button>
          </form>
          <form
            className="mt-3 flex flex-wrap items-end gap-3"
            data-testid={`bell-copy-day-${schedule.name}`}
            onSubmit={async (e) => {
              e.preventDefault();
              if (await action.run(() => api(`/bell-schedules/${schedule.id}/copy-day`, { method: "POST", body: { from_weekday: Number(from), to_weekdays: dup.to, reason: dup.reason } }))) setDup({ ...dup, to: [], reason: "" });
            }}
          >
            <Field label={t("setup.bell.copyDayFrom")}>
              <select className={inputClass} data-testid="bell-copy-day-from" value={from} onChange={(e) => setDup({ ...dup, from: e.target.value, to: [] })}>
                {days.map((d) => <option key={d} value={d}>{t(`setup.calendar.day${d}`)}</option>)}
              </select>
            </Field>
            <div className="flex flex-wrap gap-2 text-sm">
              {days.filter((d) => String(d) !== from).map((d) => (
                <label key={d} className="flex items-center gap-1">
                  <input type="checkbox" data-testid={`bell-copy-day-to-${d}`} checked={dup.to.includes(d)}
                    onChange={(e) => setDup({ ...dup, to: e.target.checked ? [...dup.to, d].sort() : dup.to.filter((x) => x !== d) })} />
                  {t(`setup.calendar.day${d}`)}
                </label>
              ))}
            </div>
            <Field label={t("setup.reason")}><input className={inputClass} data-testid="bell-copy-day-reason" required value={dup.reason} onChange={(e) => setDup({ ...dup, reason: e.target.value })} /></Field>
            <button type="submit" className={buttonClass} data-testid="bell-copy-day-submit" disabled={action.busy || dup.to.length === 0}>{t("setup.bell.copyDay")}</button>
          </form>
        </>
      )}
      <ActionError code={action.error} testId={`bell-periods-error-${schedule.name}`} />
    </div>
  );
}

function Assignments({ year, schoolId, schedules, manage }: { year: Year; schoolId: string; schedules: Schedule[]; manage: boolean }) {
  const grades = useApi<{ rows: Grade[] }>(`/schools/${schoolId}/grade-levels`);
  const assignments = useApi<{ rows: Assignment[] }>(`/academic-years/${year.id}/grade-bell-schedules`);
  const action = useAction(assignments.reload);
  const [reason, setReason] = useState("");
  if (!assignments.data || !grades.data) return null;
  const current = (grade: string) => assignments.data!.rows.find((a) => a.grade_level_id === grade)?.bell_schedule_id ?? "";
  return (
    <div className="mt-4" data-testid="grade-bell-schedules">
      <h3 className="mb-2 text-sm font-medium">{t("setup.bell.assignments")}</h3>
      {manage && year.status === "active" && (
        <Field label={t("setup.reason")}><input className={inputClass} data-testid="grade-bell-reason" value={reason} onChange={(e) => setReason(e.target.value)} /></Field>
      )}
      <ul className="divide-y text-sm">
        {grades.data.rows.filter((g) => g.status === "active").map((g) => (
          <li key={g.id} className="flex flex-wrap items-center gap-4 py-1" data-testid={`grade-bell-row-${g.name}`}>
            <span className="w-32">{g.name}</span>
            <select className={inputClass + " max-w-xs"} data-testid={`grade-bell-select-${g.name}`} disabled={!manage || action.busy} value={current(g.id)}
              onChange={(e) => e.target.value && void action.run(() =>
                api(`/academic-years/${year.id}/grade-bell-schedules/${g.id}`, { method: "PUT", body: { bell_schedule_id: e.target.value, reason: reason || undefined } }))}>
              <option value="">{t("setup.bell.unassigned")}</option>
              {schedules.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
            </select>
          </li>
        ))}
      </ul>
      <ActionError code={action.error} testId="grade-bell-error" />
    </div>
  );
}
