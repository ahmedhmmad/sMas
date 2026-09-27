// Platform Admin: الجهات عبر FastAPI (قراءة مُدقَّقة N5) — لا من PostgREST مباشرة.
import { useEffect, useState } from "react";
import { ErrorState, Forbidden, Loading } from "../components/states";
import { t } from "../i18n";
import { api, ApiError } from "../lib/api";

type Tenant = { id: string; tenant_code: string; name: string; status: string };

export function PlatformTenants() {
  const [rows, setRows] = useState<Tenant[] | null>(null);
  const [failure, setFailure] = useState<"forbidden" | "error" | null>(null);

  useEffect(() => {
    api<{ rows: Tenant[] }>("/platform/tenants")
      .then((b) => setRows(b.rows))
      .catch((e) => setFailure(e instanceof ApiError && e.status === 403 ? "forbidden" : "error"));
  }, []);

  if (failure === "forbidden") return <Forbidden />;
  if (failure) return <ErrorState />;
  if (rows === null) return <Loading />;
  return (
    <section data-testid="tenants">
      <h1 className="mb-4 text-2xl font-semibold">{t("tenants.title")}</h1>
      <table className="w-full rounded bg-white shadow-sm">
        <thead>
          <tr className="border-b text-sm text-slate-500">
            <th className="p-2 text-start">{t("tenants.code")}</th>
            <th className="p-2 text-start">{t("tenants.name")}</th>
            <th className="p-2 text-start">{t("tenants.status")}</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((r) => (
            <tr key={r.id} className="border-b" data-testid={`tenant-row-${r.tenant_code}`}>
              <td className="p-2">{r.tenant_code}</td>
              <td className="p-2">{r.name}</td>
              <td className="p-2">{r.status}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </section>
  );
}
