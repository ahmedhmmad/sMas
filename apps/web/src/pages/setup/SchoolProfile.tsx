// Phase 2B-4 — ملف المدرسة وأصولها: البيانات، الأصول النشطة وسجل نسخها، رفع نسخة جديدة، التقاعد.
// كل قرار في الخادم (E5–E8): الأزرار تُخفى حسب المفاتيح عرضاً فقط. الرابط الموقّع يُطلب عند العرض ولا يُخزَّن (60 ثانية).
import { useState } from "react";
import { useAuth } from "../../auth/AuthProvider";
import { t } from "../../i18n";
import { api, apiUpload } from "../../lib/api";
import { ActionError, buttonClass, Card, Field, inputClass, linkButtonClass, ReasonAction, statusText, useAction, useApi } from "./common";

type School = { id: string; status: string };
type Profile = { address: string | null; phone_e164: string | null; email: string | null; website: string | null; principal_display_name: string | null };
type Asset = { id: string; kind: string; signer_title: string | null; status: string; retired_at: string | null; created_at: string; width: number; height: number };

const FIELDS = ["address", "phone_e164", "email", "website", "principal_display_name"] as const;

export function SchoolProfile({ school, part = "all" }: { school: School; part?: "all" | "profile" | "assets" }) {
  const { can } = useAuth();
  const profile = useApi<Profile>(`/schools/${school.id}/profile`);
  const assets = useApi<{ rows: Asset[] }>(`/schools/${school.id}/assets`);
  if (!profile.data && !assets.data) return null;   // بلا school.read: لا قسم
  const active = school.status === "active";
  return (
    <Card title={t("setup.profile.title")} testId="school-profile">
      {part !== "assets" && profile.data && <ProfileForm school={school} profile={profile.data} editable={can("school.update") && active} reload={profile.reload} />}
      {part !== "profile" && assets.data && <Assets school={school} rows={assets.data.rows} reload={assets.reload} active={active} />}
    </Card>
  );
}

function ProfileForm({ school, profile, editable, reload }: { school: School; profile: Profile; editable: boolean; reload: () => void }) {
  const action = useAction(reload);
  const [form, setForm] = useState<Record<string, string>>(Object.fromEntries(FIELDS.map((f) => [f, profile[f] ?? ""])));
  return (
    <form
      className="mb-4 grid gap-3 sm:grid-cols-2 sm:items-end"
      data-testid="profile-form"
      onSubmit={(e) => {
        e.preventDefault();
        const body = Object.fromEntries(FIELDS.map((f) => [f, form[f].trim() === "" ? null : form[f].trim()]));
        void action.run(() => api(`/schools/${school.id}/profile`, { method: "PUT", body }));
      }}
    >
      {FIELDS.map((f) => (
        <Field key={f} label={t(`setup.profile.${f}`)}>
          <input className={inputClass} data-testid={`profile-${f}`} disabled={!editable} value={form[f]}
            dir={f === "address" || f === "principal_display_name" ? undefined : "ltr"} onChange={(e) => setForm({ ...form, [f]: e.target.value })} />
        </Field>
      ))}
      {editable && <button type="submit" className={buttonClass} data-testid="profile-save" disabled={action.busy}>{t("setup.save")}</button>}
      <ActionError code={action.error} testId="profile-error" />
    </form>
  );
}

function Assets({ school, rows, reload, active }: { school: School; rows: Asset[]; reload: () => void; active: boolean }) {
  const { can } = useAuth();
  const action = useAction(reload);
  const [preview, setPreview] = useState<Record<string, string>>({});
  // B5: الشعار school.update؛ الختم والتوقيعات security.manage — عرض فقط، الخادم يقرر
  const manages = (kind: string) => can(kind === "logo" ? "school.update" : "security.manage") && active;
  const sees = (kind: string) => kind === "logo" || can("security.manage");
  const kinds = ["logo", "stamp", "signature"].filter(manages);
  const [form, setForm] = useState({ kind: kinds[0] ?? "logo", signer_title: "", reason: "" });
  const [file, setFile] = useState<File | null>(null);
  const label = (a: Asset) => (a.kind === "signature" ? `${t("setup.profile.kind_signature")} — ${a.signer_title}` : t(`setup.profile.kind_${a.kind}`));
  const show = (a: Asset) => action.run(async () => {
    const r = await api<{ url: string }>(`/assets/${a.id}/url`);
    setPreview((p) => ({ ...p, [a.id]: r.url }));
  });
  return (
    <div data-testid="school-assets">
      <h3 className="mb-2 text-sm font-medium">{t("setup.profile.assets")}</h3>
      {rows.length === 0 && <p className="text-slate-500" data-testid="assets-empty">{t("setup.empty")}</p>}
      <ul className="mb-3 divide-y text-sm">
        {rows.map((a) => (
          <li key={a.id} className="flex flex-wrap items-center gap-3 py-2" data-testid={`asset-row-${a.id}`} data-kind={a.kind} data-status={a.status}>
            <span className="w-48">{label(a)}</span>
            <span data-testid={`asset-status-${a.id}`}>{statusText(a.status)}</span>
            <span className="text-xs text-slate-500" dir="ltr">{a.width}×{a.height}</span>
            {sees(a.kind) && (
              <button type="button" className={linkButtonClass} data-testid={`asset-preview-${a.id}`} disabled={action.busy} onClick={() => void show(a)}>
                {t("setup.profile.preview")}
              </button>
            )}
            {preview[a.id] && <img src={preview[a.id]} alt={label(a)} className="h-12 rounded border" data-testid={`asset-image-${a.id}`} />}
            {a.status === "active" && manages(a.kind) && (
              <ReasonAction label={t("setup.profile.retire")} testId={`asset-retire-${a.id}`} busy={action.busy}
                onConfirm={(reason) => action.run(() => api(`/assets/${a.id}/retire`, { method: "POST", body: { reason } }))} />
            )}
          </li>
        ))}
      </ul>
      {kinds.length > 0 && (
        <form
          className="grid gap-3 sm:grid-cols-5 sm:items-end"
          data-testid="asset-upload"
          onSubmit={async (e) => {
            e.preventDefault();
            if (!file) return;
            const body = new FormData();
            body.append("kind", form.kind);
            body.append("reason", form.reason);
            if (form.kind === "signature") body.append("signer_title", form.signer_title);
            body.append("file", file);
            if (await action.run(() => apiUpload(`/schools/${school.id}/assets`, body))) { setForm({ ...form, reason: "", signer_title: "" }); setFile(null); }
          }}
        >
          <Field label={t("setup.profile.kind")}>
            <select className={inputClass} data-testid="asset-kind" value={form.kind} onChange={(e) => setForm({ ...form, kind: e.target.value })}>
              {kinds.map((k) => <option key={k} value={k}>{t(`setup.profile.kind_${k}`)}</option>)}
            </select>
          </Field>
          {form.kind === "signature" && (
            <Field label={t("setup.profile.signer_title")}><input className={inputClass} data-testid="asset-signer" required value={form.signer_title} onChange={(e) => setForm({ ...form, signer_title: e.target.value })} /></Field>
          )}
          <Field label={t("setup.profile.file")}>
            <input type="file" accept="image/png,image/jpeg" className={inputClass} data-testid="asset-file" onChange={(e) => setFile(e.target.files?.[0] ?? null)} />
          </Field>
          <Field label={t("setup.reason")}><input className={inputClass} data-testid="asset-reason" required value={form.reason} onChange={(e) => setForm({ ...form, reason: e.target.value })} /></Field>
          <button type="submit" className={buttonClass} data-testid="asset-submit" disabled={action.busy || !file}>{t("setup.profile.upload")}</button>
          <p className="text-xs text-slate-500 sm:col-span-5">{t("setup.profile.uploadHint")}</p>
        </form>
      )}
      <ActionError code={action.error} testId="assets-error" />
    </div>
  );
}
