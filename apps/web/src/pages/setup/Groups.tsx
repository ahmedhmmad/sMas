// Phase 2A — المجموعات بالحد الأدنى: قائمة، إنشاء، إعادة تسمية، أرشفة.
import { useState } from "react";
import { useAuth } from "../../auth/AuthProvider";
import { t } from "../../i18n";
import { api } from "../../lib/api";
import { ActionError, buttonClass, Card, Field, inputClass, linkButtonClass, PageState, ReasonAction, statusText, useAction, useApi } from "./common";

type Group = { id: string; group_code: string; name: string; status: string };

export function Groups() {
  const { can } = useAuth();
  const { data, failure, reload } = useApi<{ rows: Group[] }>("/groups");
  const action = useAction(reload);
  const [code, setCode] = useState("");
  const [name, setName] = useState("");
  const [renaming, setRenaming] = useState<{ id: string; name: string } | null>(null);

  if (!data) return <PageState failure={failure} />;
  return (
    <section data-testid="groups">
      <h1 className="mb-4 text-2xl font-semibold">{t("setup.groups.title")}</h1>
      {can("group.create") && (
        <Card title={t("setup.groups.new")} testId="group-create">
          <form
            className="grid gap-3 sm:grid-cols-3 sm:items-end"
            onSubmit={async (e) => {
              e.preventDefault();
              if (await action.run(() => api("/groups", { method: "POST", body: { group_code: code, name } }))) { setCode(""); setName(""); }
            }}
          >
            <Field label={t("setup.code")}>
              <input className={inputClass} data-testid="group-code" required pattern="[A-Z0-9][A-Z0-9_\-]{1,31}" value={code} onChange={(e) => setCode(e.target.value.toUpperCase())} />
            </Field>
            <Field label={t("setup.name")}>
              <input className={inputClass} data-testid="group-name" required value={name} onChange={(e) => setName(e.target.value)} />
            </Field>
            <button type="submit" className={buttonClass} data-testid="group-submit" disabled={action.busy}>{t("setup.create")}</button>
          </form>
        </Card>
      )}
      <ActionError code={action.error} />
      {data.rows.length === 0 ? (
        <p data-testid="groups-empty" className="text-slate-500">{t("setup.empty")}</p>
      ) : (
        <ul className="divide-y rounded bg-white shadow-sm">
          {data.rows.map((g) => (
            <li key={g.id} data-testid={`group-row-${g.group_code}`} className="flex flex-wrap items-center gap-4 p-3">
              <span className="font-mono text-sm">{g.group_code}</span>
              {renaming?.id === g.id ? (
                <form
                  className="flex gap-2"
                  onSubmit={async (e) => {
                    e.preventDefault();
                    if (await action.run(() => api(`/groups/${g.id}`, { method: "PATCH", body: { name: renaming.name } }))) setRenaming(null);
                  }}
                >
                  <input className={inputClass} data-testid={`group-rename-input-${g.group_code}`} required value={renaming.name} onChange={(e) => setRenaming({ id: g.id, name: e.target.value })} />
                  <button type="submit" className={buttonClass} data-testid={`group-rename-save-${g.group_code}`}>{t("setup.save")}</button>
                </form>
              ) : (
                <span className="flex-1" data-testid={`group-name-${g.group_code}`}>{g.name}</span>
              )}
              <span data-testid={`group-status-${g.group_code}`} className="text-sm text-slate-500">{statusText(g.status)}</span>
              {can("group.update") && g.status === "active" && renaming?.id !== g.id && (
                <button type="button" className={linkButtonClass} data-testid={`group-rename-${g.group_code}`} onClick={() => setRenaming({ id: g.id, name: g.name })}>
                  {t("setup.groups.rename")}
                </button>
              )}
              {can("group.archive") && g.status === "active" && (
                <ReasonAction label={t("setup.groups.archive")} testId={`group-archive-${g.group_code}`} busy={action.busy}
                  onConfirm={(reason) => action.run(() => api(`/groups/${g.id}/archive`, { method: "POST", body: { reason } }))} />
              )}
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}
