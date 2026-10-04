// Phase 2A / P2-D — أدوات مشتركة لصفحات الإعداد. لا تفويض هنا: الصفحة تعرض ما يعيده الـAPI، والأزرار تُخفى
// حسب المفاتيح (عرض فقط) — القرار في الخادم (P2-C) وقاعدة البيانات.
import { type ReactNode, useCallback, useEffect, useState } from "react";
import { ErrorState, Forbidden, Loading, NotFound } from "../../components/states";
import { errorText, t } from "../../i18n";
import { api, ApiError } from "../../lib/api";

export type Failure = "notFound" | "forbidden" | "error";

const failureOf = (e: unknown): Failure =>
  e instanceof ApiError ? (e.status === 404 ? "notFound" : e.status === 403 ? "forbidden" : "error") : "error";

export function useApi<T>(path: string | null): { data: T | null; failure: Failure | null; reload: () => void } {
  const [data, setData] = useState<T | null>(null);
  const [failure, setFailure] = useState<Failure | null>(null);
  const [tick, setTick] = useState(0);
  useEffect(() => {
    if (!path) return;
    let live = true;
    api<T>(path).then((d) => live && (setData(d), setFailure(null))).catch((e) => live && setFailure(failureOf(e)));
    return () => { live = false; };
  }, [path, tick]);
  return { data, failure, reload: useCallback(() => setTick((n) => n + 1), []) };
}

export function PageState({ failure }: { failure: Failure | null }) {
  if (failure === "notFound") return <NotFound />;
  if (failure === "forbidden") return <Forbidden />;
  if (failure === "error") return <ErrorState />;
  return <Loading />;
}

// إجراء كتابة: رمز الخطأ من الـAPI يُعرض بنص الفهرس (لا تفاصيل DB)، ونجاحه يعيد تحميل الصفحة
export function useAction(after: () => void) {
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const run = async (work: () => Promise<unknown>): Promise<boolean> => {
    setBusy(true);
    setError(null);
    try {
      await work();
      after();
      return true;
    } catch (e) {
      setError(e instanceof ApiError ? e.code : "generic");
      return false;
    } finally {
      setBusy(false);
    }
  };
  return { error, busy, run };
}

export function ActionError({ code, testId = "action-error" }: { code: string | null; testId?: string }) {
  if (!code) return null;
  return <p role="alert" data-testid={testId} data-code={code} className="mt-2 text-sm text-red-700">{errorText(code)}</p>;
}

export const inputClass = "w-full rounded border border-slate-300 px-3 py-2";
export const buttonClass = "rounded bg-emerald-600 px-4 py-2 text-white disabled:opacity-50";
export const linkButtonClass = "text-sm text-emerald-700 underline disabled:opacity-50";

export function Field({ label, children }: { label: string; children: ReactNode }) {
  return (
    <label className="block text-sm">
      <span className="mb-1 block text-slate-600">{label}</span>
      {children}
    </label>
  );
}

export function Card({ title, testId, children }: { title: string; testId?: string; children: ReactNode }) {
  return (
    <section data-testid={testId} className="mb-6 rounded bg-white p-4 shadow-sm">
      <h2 className="mb-3 font-medium">{title}</h2>
      {children}
    </section>
  );
}

export const statusText = (status: string) => t(`setup.statusLabel.${status}`);

// إجراء يحتاج سبباً (أرشفة، تفعيل، إغلاق، …): زر يفتح حقل السبب ثم تأكيد
export function ReasonAction({ label, testId, busy, onConfirm }: {
  label: string; testId: string; busy?: boolean; onConfirm: (reason: string) => Promise<boolean>;
}) {
  const [open, setOpen] = useState(false);
  const [reason, setReason] = useState("");
  if (!open) {
    return <button type="button" className={linkButtonClass} data-testid={testId} onClick={() => setOpen(true)}>{label}</button>;
  }
  return (
    <form
      className="flex flex-wrap items-end gap-2"
      onSubmit={async (e) => {
        e.preventDefault();
        if (await onConfirm(reason)) { setOpen(false); setReason(""); }
      }}
    >
      <Field label={t("setup.reason")}>
        <input className={inputClass} data-testid={`${testId}-reason`} required maxLength={500} value={reason} onChange={(e) => setReason(e.target.value)} />
      </Field>
      <button type="submit" className={buttonClass} data-testid={`${testId}-confirm`} disabled={busy}>{t("setup.confirm")}</button>
      <button type="button" className={linkButtonClass} onClick={() => setOpen(false)}>{t("setup.cancel")}</button>
    </form>
  );
}
