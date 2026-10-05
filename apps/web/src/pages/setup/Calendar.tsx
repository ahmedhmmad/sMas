// Phase 2B / 2B-2 — تقويم السنة: أيام الدوام، العطلات والأيام الاستثنائية، النسخ، وعرض شهري للقراءة.
// قواعد B8 (C1–C5) في قاعدة البيانات: الحقول المقفلة هنا عرض فقط، والسبب يُرسل دائماً وDB تقرر هل هو مطلوب.
import { useState } from "react";
import { useAuth } from "../../auth/AuthProvider";
import { t } from "../../i18n";
import { api } from "../../lib/api";
import { ActionError, buttonClass, Card, Field, inputClass, linkButtonClass, ReasonAction, statusText, useAction, useApi } from "./common";

type Year = { id: string; name: string; start_date: string; end_date: string; status: string };
type Weekday = { id: string; weekday: number; status: string };
type CalendarException = { id: string; kind: string; name: string; start_date: string; end_date: string; status: string };

const DAYS = [0, 1, 2, 3, 4, 5, 6];

export function Calendar({ year, others }: { year: Year; others: Year[] }) {
  const weekdays = useApi<{ rows: Weekday[] }>(`/academic-years/${year.id}/weekdays`);
  const exceptions = useApi<{ rows: CalendarException[] }>(`/academic-years/${year.id}/calendar-exceptions`);
  if (!weekdays.data || !exceptions.data) return null;   // بلا academic_year.read: لا قسم
  const active = weekdays.data.rows.filter((w) => w.status === "active").map((w) => w.weekday);
  return (
    <Card title={t("setup.calendar.title")} testId="calendar">
      <Weekdays year={year} active={active} reload={weekdays.reload} others={others} />
      <Exceptions year={year} rows={exceptions.data.rows} reload={exceptions.reload} />
      <Month year={year} active={active} rows={exceptions.data.rows} />
    </Card>
  );
}

function Weekdays({ year, active, reload, others }: { year: Year; active: number[]; reload: () => void; others: Year[] }) {
  const { can } = useAuth();
  const action = useAction(reload);
  const [days, setDays] = useState<number[]>(active);
  const [reason, setReason] = useState("");
  const [copy, setCopy] = useState({ source_year_id: "", reason: "" });
  const [created, setCreated] = useState<number | null>(null);
  // planned: حرة · active: التعريف الأول فقط (C2) · closed: لا شيء — عرض فقط، DB تقرر
  const editable = can("academic_year.update") && (year.status === "planned" || (year.status === "active" && active.length === 0));
  return (
    <div className="mb-4" data-testid="weekdays">
      <h3 className="mb-2 text-sm font-medium">{t("setup.calendar.weekdays")}</h3>
      <div className="mb-2 flex flex-wrap gap-3 text-sm">
        {DAYS.map((d) => (
          <label key={d} className="flex items-center gap-1" data-testid={`weekday-${d}`} data-active={String(active.includes(d))}>
            <input type="checkbox" data-testid={`weekday-check-${d}`} disabled={!editable} checked={days.includes(d)}
              onChange={(e) => setDays(e.target.checked ? [...days, d].sort() : days.filter((x) => x !== d))} />
            {t(`setup.calendar.day${d}`)}
          </label>
        ))}
      </div>
      {editable && (
        <form
          className="grid gap-3 sm:grid-cols-3 sm:items-end"
          onSubmit={async (e) => {
            e.preventDefault();
            if (await action.run(() => api(`/academic-years/${year.id}/weekdays`, { method: "PUT", body: { weekdays: days, reason } }))) setReason("");
          }}
        >
          <Field label={t("setup.reason")}><input className={inputClass} data-testid="weekdays-reason" required value={reason} onChange={(e) => setReason(e.target.value)} /></Field>
          <button type="submit" className={buttonClass} data-testid="weekdays-submit" disabled={action.busy || days.length === 0}>{t("setup.save")}</button>
        </form>
      )}
      {!editable && year.status === "active" && active.length > 0 && <p className="text-xs text-slate-500" data-testid="weekdays-fixed">{t("setup.calendar.weekdaysFixed")}</p>}
      {can("academic_year.update") && year.status === "planned" && others.length > 0 && (
        <form
          className="mt-3 grid gap-3 rounded border border-slate-200 p-3 sm:grid-cols-3 sm:items-end"
          data-testid="copy-weekdays"
          onSubmit={async (e) => {
            e.preventDefault();
            await action.run(async () => {
              const r = await api<{ created: number }>(`/academic-years/${year.id}/copy-weekdays`, { method: "POST", body: copy });
              setCreated(r.created);
            });
          }}
        >
          <Field label={t("setup.calendar.copySource")}>
            <select className={inputClass} data-testid="weekdays-copy-source" required value={copy.source_year_id} onChange={(e) => setCopy({ ...copy, source_year_id: e.target.value })}>
              <option value="" />
              {others.map((y) => <option key={y.id} value={y.id}>{y.name}</option>)}
            </select>
          </Field>
          <Field label={t("setup.reason")}><input className={inputClass} data-testid="weekdays-copy-reason" required value={copy.reason} onChange={(e) => setCopy({ ...copy, reason: e.target.value })} /></Field>
          <button type="submit" className={buttonClass} data-testid="weekdays-copy-submit" disabled={action.busy}>{t("setup.calendar.copy")}</button>
          {created !== null && <p className="text-sm text-emerald-700 sm:col-span-3" data-testid="weekdays-copy-result" data-created={created}>{t("setup.calendar.copied")} {created}</p>}
        </form>
      )}
      <ActionError code={action.error} testId="weekdays-error" />
    </div>
  );
}

function Exceptions({ year, rows, reload }: { year: Year; rows: CalendarException[]; reload: () => void }) {
  const { can } = useAuth();
  const action = useAction(reload);
  const blank = { kind: "holiday", name: "", start_date: "", end_date: "", reason: "" };
  const [form, setForm] = useState(blank);
  const manage = can("academic_year.update") && year.status !== "closed";
  return (
    <div className="mb-4" data-testid="calendar-exceptions">
      <h3 className="mb-2 text-sm font-medium">{t("setup.calendar.exceptions")}</h3>
      {rows.length === 0 && <p className="text-slate-500" data-testid="calendar-exceptions-empty">{t("setup.empty")}</p>}
      <ul className="mb-3 divide-y text-sm">
        {rows.map((x) => (
          <li key={x.id} className="flex flex-wrap items-center gap-4 py-2" data-testid={`exception-row-${x.name}`}>
            <span className="w-28">{t(`setup.calendar.kind_${x.kind}`)}</span>
            <span className="flex-1">{x.name}</span>
            <span dir="ltr" data-testid={`exception-dates-${x.name}`}>{x.start_date} → {x.end_date}</span>
            <span data-testid={`exception-status-${x.name}`}>{statusText(x.status)}</span>
            {manage && x.status === "active" && (
              <>
                <EndDate exception={x} year={year} busy={action.busy}
                  onSave={(end_date, reason) => action.run(() => api(`/calendar-exceptions/${x.id}`, { method: "PATCH", body: { end_date, reason } }))} />
                <ReasonAction label={t("setup.calendar.cancel")} testId={`exception-cancel-${x.name}`} busy={action.busy}
                  onConfirm={(reason) => action.run(() => api(`/calendar-exceptions/${x.id}/cancel`, { method: "POST", body: { reason } }))} />
              </>
            )}
          </li>
        ))}
      </ul>
      {manage && (
        <form
          className="grid gap-3 sm:grid-cols-6 sm:items-end"
          onSubmit={async (e) => {
            e.preventDefault();
            const body = { ...form, end_date: form.kind === "study_day" ? form.start_date : form.end_date, reason: form.reason || undefined };
            if (await action.run(() => api(`/academic-years/${year.id}/calendar-exceptions`, { method: "POST", body }))) setForm(blank);
          }}
        >
          <Field label={t("setup.calendar.kind")}>
            <select className={inputClass} data-testid="exception-kind" value={form.kind} onChange={(e) => setForm({ ...form, kind: e.target.value })}>
              {["holiday", "study_day"].map((k) => <option key={k} value={k}>{t(`setup.calendar.kind_${k}`)}</option>)}
            </select>
          </Field>
          <Field label={t("setup.name")}><input className={inputClass} data-testid="exception-name" required value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} /></Field>
          <Field label={t("setup.years.start")}>
            <input type="date" className={inputClass} data-testid="exception-start" required min={year.start_date} max={year.end_date} value={form.start_date} onChange={(e) => setForm({ ...form, start_date: e.target.value })} />
          </Field>
          <Field label={t("setup.years.end")}>
            <input type="date" className={inputClass} data-testid="exception-end" required={form.kind === "holiday"} disabled={form.kind === "study_day"}
              min={form.start_date || year.start_date} max={year.end_date} value={form.kind === "study_day" ? form.start_date : form.end_date} onChange={(e) => setForm({ ...form, end_date: e.target.value })} />
          </Field>
          <Field label={t("setup.reason")}>
            <input className={inputClass} data-testid="exception-reason" required={year.status === "active"} value={form.reason} onChange={(e) => setForm({ ...form, reason: e.target.value })} />
          </Field>
          <button type="submit" className={buttonClass} data-testid="exception-submit" disabled={action.busy}>{t("setup.calendar.add")}</button>
        </form>
      )}
      {year.status === "active" && manage && <p className="mt-2 text-xs text-slate-500">{t("setup.calendar.activeHint")}</p>}
      <ActionError code={action.error} testId="calendar-exceptions-error" />
    </div>
  );
}

function EndDate({ exception, year, busy, onSave }: {
  exception: CalendarException; year: Year; busy: boolean; onSave: (end: string, reason: string) => Promise<boolean>;
}) {
  const [open, setOpen] = useState(false);
  const [end, setEnd] = useState(exception.end_date);
  const [reason, setReason] = useState("");
  if (exception.kind !== "holiday") return null;
  if (!open) {
    return <button type="button" className={linkButtonClass} data-testid={`exception-end-${exception.name}`} onClick={() => setOpen(true)}>{t("setup.calendar.changeEnd")}</button>;
  }
  return (
    <form className="flex flex-wrap items-end gap-2" onSubmit={async (e) => { e.preventDefault(); if (await onSave(end, reason)) setOpen(false); }}>
      <Field label={t("setup.years.end")}>
        <input type="date" className={inputClass} data-testid={`exception-end-${exception.name}-date`} required min={exception.start_date} max={year.end_date} value={end} onChange={(e) => setEnd(e.target.value)} />
      </Field>
      <Field label={t("setup.reason")}>
        <input className={inputClass} data-testid={`exception-end-${exception.name}-reason`} required={year.status === "active"} value={reason} onChange={(e) => setReason(e.target.value)} />
      </Field>
      <button type="submit" className={buttonClass} data-testid={`exception-end-${exception.name}-confirm`} disabled={busy}>{t("setup.confirm")}</button>
      <button type="button" className={linkButtonClass} onClick={() => setOpen(false)}>{t("setup.cancel")}</button>
    </form>
  );
}

// عرض شهري للقراءة فقط — تلوين مشتق للعرض؛ المرجع الوحيد لـ«هل اليوم دراسي؟» هو app.is_school_day في DB (المرحلة 5)
function Month({ year, active, rows }: { year: Year; active: number[]; rows: CalendarException[] }) {
  const [month, setMonth] = useState(year.start_date.slice(0, 7));
  const [y, m] = month.split("-").map(Number);
  const first = new Date(Date.UTC(y, m - 1, 1));
  const count = new Date(Date.UTC(y, m, 0)).getUTCDate();
  const live = rows.filter((x) => x.status === "active");
  const kindOf = (iso: string): string => {
    if (iso < year.start_date || iso > year.end_date) return "outside";
    if (live.some((x) => x.kind === "study_day" && x.start_date === iso)) return "study_day";
    if (live.some((x) => x.kind === "holiday" && x.start_date <= iso && iso <= x.end_date)) return "holiday";
    return active.includes(new Date(`${iso}T00:00:00Z`).getUTCDay()) ? "school" : "rest";
  };
  const shift = (n: number) => {
    const d = new Date(Date.UTC(y, m - 1 + n, 1));
    setMonth(d.toISOString().slice(0, 7));
  };
  const color: Record<string, string> = { school: "bg-emerald-50", rest: "bg-slate-100", holiday: "bg-amber-100", study_day: "bg-sky-100", outside: "bg-white text-slate-300" };
  return (
    <div data-testid="calendar-month">
      <div className="mb-2 flex items-center gap-3 text-sm">
        <button type="button" className={linkButtonClass} data-testid="month-prev" onClick={() => shift(-1)}>{t("setup.calendar.prev")}</button>
        <span dir="ltr" data-testid="month-label">{month}</span>
        <button type="button" className={linkButtonClass} data-testid="month-next" onClick={() => shift(1)}>{t("setup.calendar.next")}</button>
      </div>
      <div className="grid grid-cols-7 gap-1 text-center text-xs">
        {DAYS.map((d) => <div key={d} className="font-medium">{t(`setup.calendar.day${d}`)}</div>)}
        {Array.from({ length: first.getUTCDay() }, (_, i) => <div key={`pad${i}`} />)}
        {Array.from({ length: count }, (_, i) => {
          const iso = `${month}-${String(i + 1).padStart(2, "0")}`;
          const k = kindOf(iso);
          return <div key={iso} className={`rounded py-1 ${color[k]}`} data-testid={`month-day-${iso}`} data-kind={k}>{i + 1}</div>;
        })}
      </div>
    </div>
  );
}
